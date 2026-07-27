import DesignSystem
import Observation

// MARK: - Owner home state (MYR-167; fleet seam MYR-201)
//
// Lives above the owner tab switch (app.jsx's `vehicleIdx`/`sheet` are
// App-level state, not HomeScreen-local — screens.jsx:369 HomeScreen just
// receives them as props) so the selected vehicle, sheet detent, and each
// vehicle's ticking telemetry survive switching to Drives/Share/Settings and
// back to Vehicle.
//
// MYR-201 moved the DATA (the fleet list + per-vehicle telemetry/command) behind
// the `VehicleFleet` seam: this object keeps the view-facing selection + detent,
// and delegates everything else to its injected fleet — `SimulatedVehicleFleet`
// (M1 default, offline) or `LiveVehicleFleet` (production telemetry). The choice
// is made at one composition point (`TelemetryComposition`, wired in `RootView`).

@Observable
@MainActor
public final class OwnerHomeState {
    public var selectedVehicleIndex: Int = 0
    public var sheetDetent: MRTSheetDetent = .peek

    /// MYR-292 — the id of the `completed` ride whose "Dropped off ✓" confirmation
    /// the owner has already seen (auto-dismissed after a beat, or acknowledged on a
    /// previous visit to Home). Read through
    /// `OwnerRideStatusLine.dispatchCardVisible`.
    ///
    /// It lives HERE, on the owner-scoped observable, and not in `HomeScreen`
    /// `@State`, for the same reason `selectedVehicleIndex`/`sheetDetent` do:
    /// `HomeScreen` is constructed inside a `switch ownerTab` branch of `RootView`,
    /// so a trip to Drives/Share/Settings DESTROYS the view. With the flag per-mount
    /// the acknowledgement was forgotten on every tab switch — the shared
    /// `rideRequestService.activeRequest` still held the `.completed` ride, so the
    /// banner came back and re-armed its auto-dismiss (MYR-292 defect 1) — and an
    /// auto-dismiss that landed AFTER the owner left wrote into torn-down `@State`
    /// storage and was lost entirely.
    ///
    /// Owner-local: this never touches the shared `activeRequest`, so the rider's
    /// Ride Summary is unaffected (MYR-267).
    public var acknowledgedCompletedRideID: String?

    /// The fleet backend (simulated fixtures or live Kit). Internal to the app
    /// module — screens read the projected accessors below, not the fleet.
    let fleet: any VehicleFleet

    /// M1 default: the fixture-backed simulated fleet (no network).
    public init() {
        self.fleet = SimulatedVehicleFleet()
        #if DEBUG
        // Drift-gate: boot resting at half / on a chosen vehicle for the
        // at-rest captures only.
        if DebugScene.initialOwnerDetentHalf { self.sheetDetent = .half }
        if let index = DebugScene.initialOwnerVehicleIndex { self.selectedVehicleIndex = index }
        #endif
    }

    /// Live / injected fleet (used by `TelemetryComposition` and tests).
    init(fleet: any VehicleFleet) {
        self.fleet = fleet
    }

    // MARK: Projected fleet accessors

    /// The fleet rows for the switcher. Empty while a live fleet is still
    /// loading (`isConnecting`).
    public var vehicles: [Vehicle] { fleet.vehicles }

    /// True while the live fleet is connecting (list load / first snapshot).
    /// Always false for the simulated fleet.
    public var isConnecting: Bool { fleet.isConnecting }

    /// A subtle status line when the fleet can't be shown (auth/unreachable),
    /// else `nil`. Design minimalism — surfaced quietly.
    public var statusMessage: String? { fleet.statusMessage }

    private var hasSelection: Bool { vehicles.indices.contains(selectedVehicleIndex) }

    /// The selected vehicle, or `nil` when the fleet has no rows yet (live,
    /// mid-connect). Non-nil for every simulated selection.
    public var selectedVehicle: Vehicle? {
        hasSelection ? vehicles[selectedVehicleIndex] : nil
    }

    public var selectedTelemetry: (any VehicleTelemetrySource)? {
        hasSelection ? fleet.telemetry(at: selectedVehicleIndex) : nil
    }

    public var selectedCommandExecutor: (any VehicleCommandExecutor)? {
        hasSelection ? fleet.commandExecutor(at: selectedVehicleIndex) : nil
    }

    /// The drive-history feed for the selected vehicle (MYR-203) — fixtures for
    /// the simulated fleet, the live cursor-paginated feed for the live fleet.
    /// The fleet guards an out-of-range index (live fleet mid-connect) with a
    /// detached empty feed, so this is safe before a selection exists.
    var selectedDrivesFeed: any DrivesFeed {
        fleet.drivesFeed(at: hasSelection ? selectedVehicleIndex : 0)
    }

    /// The design badge state (driving/parked/charging/offline) for the selected
    /// vehicle — `parked` neutral when there's no selection yet.
    public var selectedBadgeStatus: MRTVehicleStatus {
        hasSelection ? fleet.badgeStatus(at: selectedVehicleIndex) : .parked
    }

    /// MYR-277 — the fleet row index for a vehicle id, or `nil` when it isn't in
    /// the loaded fleet (a sim fixture ride's fleet id, or a live ride whose
    /// vehicle isn't loaded).
    func vehicleIndex(forID id: String) -> Int? {
        vehicles.firstIndex { $0.id == id }
    }

    /// MYR-277 C — the live badge status of the TARGET vehicle of an incoming
    /// request (joined by id), so the owner sheet can honestly gate Accept when the
    /// car is in_service/offline. `nil` when the vehicle isn't in the loaded fleet.
    func badgeStatus(forVehicleID id: String) -> MRTVehicleStatus? {
        vehicleIndex(forID: id).map { fleet.badgeStatus(at: $0) }
    }

    /// MYR-277 A2 — the telemetry source of the TARGET vehicle (for its live
    /// position, used to estimate the car→pickup leg). `nil` when not in the fleet.
    func telemetry(forVehicleID id: String) -> (any VehicleTelemetrySource)? {
        vehicleIndex(forID: id).map { fleet.telemetry(at: $0) }
    }

    // MARK: Lifecycle

    public func startTelemetry() {
        fleet.start()
        fleet.setActive(index: selectedVehicleIndex)
    }

    public func stopTelemetry() {
        fleet.stop()
    }

    /// Call when the switcher selection changes so the live fleet narrows its
    /// socket subscription to the new vehicle (no-op for sim).
    public func setActiveVehicle() {
        fleet.setActive(index: selectedVehicleIndex)
    }

    /// MYR-258 (§7.12) — drop a vehicle after its authoritative backend teardown.
    /// Delegates to the fleet (which releases the live source + re-narrows its own
    /// active subscription) and clamps the view-facing selection so the switcher /
    /// Settings list never point past the shortened fleet. Live-path only — the
    /// simulated fleet ignores removal (default no-op).
    public func removeVehicle(id: String) {
        fleet.remove(vehicleID: id)
        if !vehicles.indices.contains(selectedVehicleIndex) {
            selectedVehicleIndex = max(0, vehicles.count - 1)
        }
    }

    public func handleForeground() { fleet.handleForeground() }
    public func handleBackground() { fleet.handleBackground() }
}

// MARK: - Read-only linked-vehicles source (MYR-243)
//
// The narrow READ surface the Settings "Tesla Account" section consumes on the
// LIVE path: the owner's real vehicles from the authoritative fleet REST list,
// plus the honest connecting/notice signals — and nothing else. No mutation:
// set-primary / unlink have no backend contract (MYR-228), so the live section
// is display-only. `OwnerHomeState` already holds the started fleet for the
// owner shell, so Settings reads the SAME list that drives Home rather than a
// second fetch. `nil` on the sim / DEBUG path keeps the fixture-backed
// `OwnerVehiclesState` section pixel-identical (MYR-228 rule).
@MainActor
protocol LinkedVehiclesReading: AnyObject, Observable {
    var vehicles: [Vehicle] { get }
    var isConnecting: Bool { get }
    var statusMessage: String? { get }
}

extension OwnerHomeState: LinkedVehiclesReading {}
