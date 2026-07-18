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

    /// The fleet backend (simulated fixtures or live Kit). Internal to the app
    /// module — screens read the projected accessors below, not the fleet.
    let fleet: any VehicleFleet

    /// M1 default: the fixture-backed simulated fleet (no network).
    public init() {
        self.fleet = SimulatedVehicleFleet()
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
