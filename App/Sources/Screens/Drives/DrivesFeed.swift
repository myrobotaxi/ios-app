import Observation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DrivesFeed seam (MYR-203)
//
// The M1↔M2 seam for the OWNER'S DRIVE HISTORY. `DrivesScreen` renders the same
// grouped rows / Drive Summary push regardless of source; the two conformers are
// chosen by the fleet (`VehicleFleet.drivesFeed(at:)`), which is itself chosen at
// the one `TelemetryComposition` point:
//
//   • `SimulatedDrivesFeed` — the M1 default: `DriveFixtures.drives`, no network,
//     no pagination (CLAUDE.md "M1 is simulated"). One shared instance per fleet.
//   • `LiveDrivesFeed` — the M2 live path: cursor-paginated REST
//     `drives(vehicleID:cursor:)` (rest-api.md §7.2), mapped through
//     `DriveContractMapping`, with a `drive_ended`-driven first-page refresh
//     (FR-9.2). One instance per vehicle so pagination survives tab switches.
@MainActor
protocol DrivesFeed: AnyObject, Observable {
    /// The history rows, newest first. Fixtures for sim; the accumulated live
    /// pages for live (empty until the first page loads).
    var drives: [Drive] { get }
    /// True while a page fetch is in flight (drives the paging spinner). Always
    /// false for sim.
    var isLoading: Bool { get }
    /// A subtle status line when the FIRST page can't be loaded (auth/unreachable)
    /// — nil when all is well or once any rows exist. Design minimalism.
    var statusMessage: String? { get }
    /// True iff a further page exists (contract `hasMore`). Always false for sim.
    var hasMore: Bool { get }

    /// Load the first page once (idempotent). No-op for sim.
    func loadInitial()
    /// Fetch the next page if one exists and none is in flight. No-op for sim.
    func loadMore()
    /// Re-fetch the first page (a `drive_ended` arrived). No-op for sim.
    func refresh()
    /// The row for `id` (the tap-through target for Drive Summary), or nil.
    func drive(id: String) -> Drive?
}

// MARK: - SimulatedDrivesFeed (M1 default)

@Observable
@MainActor
final class SimulatedDrivesFeed: DrivesFeed {
    let drives: [Drive] = DriveFixtures.drives
    var isLoading: Bool { false }
    var statusMessage: String? { nil }
    var hasMore: Bool { false }

    func loadInitial() {}
    func loadMore() {}
    func refresh() {}
    func drive(id: String) -> Drive? { DriveFixtures.drive(id: id) }
}

// MARK: - LiveDrivesFeed (M2 live)

@Observable
@MainActor
final class LiveDrivesFeed: DrivesFeed {
    private let rest: RestClient
    private let vehicleID: String

    private(set) var drives: [Drive] = []
    private(set) var isLoading = false
    private(set) var statusMessage: String?
    private(set) var hasMore = false

    private var nextCursor: String?
    private var loadedOnce = false
    private var task: Task<Void, Never>?
    /// Fast id→row lookup for the Drive Summary tap-through (the summary carries
    /// everything the detail screen renders, so no per-tap detail fetch).
    private var index: [String: Drive] = [:]

    init(rest: RestClient, vehicleID: String) {
        self.rest = rest
        self.vehicleID = vehicleID
    }

    func loadInitial() {
        guard !loadedOnce else { return }
        loadedOnce = true
        load(reset: true)
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        load(reset: false)
    }

    /// FR-9.2 — a `drive_ended` frame arrived: reload page 1 so the just-completed
    /// drive appears at the head of the list. rest-api.md §7.2 permits prepending
    /// the synthesized summary instead; a page-1 refresh is the simpler, correct
    /// realization of "the drive appears without the consumer re-deriving it."
    func refresh() {
        loadedOnce = true
        load(reset: true)
    }

    func drive(id: String) -> Drive? { index[id] }

    private func load(reset: Bool) {
        if reset { task?.cancel() } else if isLoading { return }
        isLoading = true
        if reset { statusMessage = nil }
        let cursor = reset ? nil : nextCursor
        let rest = self.rest
        let vehicleID = self.vehicleID
        task = Task { [weak self] in
            do {
                let page = try await rest.drives(vehicleID: vehicleID, cursor: cursor)
                guard !Task.isCancelled else { return }
                self?.apply(page, reset: reset)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(error)
            }
        }
    }

    private func apply(_ page: DrivesListResponse, reset: Bool) {
        let mapped = page.items.map { DriveContractMapping.appDrive(from: $0) }
        if reset {
            drives = mapped
            index = Dictionary(mapped.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            // Append, de-duplicating on id in case a new head-of-list drive
            // shifted the page boundary between requests (retention/new-drive
            // race, rest-api.md §7.2 Retention).
            for drive in mapped where index[drive.id] == nil {
                drives.append(drive)
                index[drive.id] = drive
            }
        }
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        isLoading = false
        statusMessage = nil
    }

    private func applyFailure(_ error: Error) {
        isLoading = false
        // Only surface the quiet status line when there's nothing to show; a
        // failed *paging* fetch leaves the existing rows intact and silent.
        if drives.isEmpty {
            statusMessage = LiveVehicleFleet.message(for: error)
        }
    }
}
