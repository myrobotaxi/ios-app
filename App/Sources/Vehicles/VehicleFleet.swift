import DesignSystem
import Observation

// MARK: - VehicleFleet seam (MYR-201 deliverable 2)
//
// The M1↔M2 seam for the OWNER'S FLEET as a whole — the fleet list plus each
// vehicle's telemetry source and command executor. `OwnerHomeState` owns the
// selection + sheet detent and delegates the data itself to a `VehicleFleet`.
// Two conformers, chosen at ONE composition point (`TelemetryComposition`,
// wired in `RootView`):
//
//   • `SimulatedVehicleFleet` — the M1 default: `VehicleFixtures.vehicles`, one
//     `SimulatedVehicleTelemetrySource` + `SimulatedVehicleCommandExecutor`
//     each. No network — the M1 demo keeps working offline (CLAUDE.md
//     "M1 is simulated").
//   • `LiveVehicleFleet` — the M2 live path: REST `vehicles()` for the fleet
//     list, a `TelemetrySocket` subscription for the selected vehicle, mapped
//     through `VehicleContractMapping`.
//
// Keeping the seam at the fleet (not scattering `if live` across screens) is
// what lets `HomeScreen`/`MapHeader` stay identical between sim and live.
@MainActor
protocol VehicleFleet: AnyObject, Observable {
    /// The fleet rows for the switcher + selection. Empty until a live load
    /// completes; always populated for the simulated fleet.
    var vehicles: [Vehicle] { get }

    /// True while the live fleet is still fetching its list / first snapshot —
    /// drives the screen's subtle connecting state. Always false for sim.
    var isConnecting: Bool { get }

    /// A subtle, non-dramatic status line when the fleet can't be shown
    /// (e.g. auth required, backend unreachable) — `nil` when all is well.
    /// Design minimalism: surfaced quietly, never as an error dialog.
    var statusMessage: String? { get }

    func telemetry(at index: Int) -> any VehicleTelemetrySource
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor

    /// The drive-history feed for a vehicle (MYR-203): fixtures for the
    /// simulated fleet, a cursor-paginated live feed for the live fleet. Held by
    /// the fleet (not the screen) so pagination survives a tab switch.
    func drivesFeed(at index: Int) -> any DrivesFeed

    /// The design badge state for a row (driving/parked/charging/offline).
    func badgeStatus(at index: Int) -> MRTVehicleStatus

    /// Begin producing data (sim: start every ticker; live: load the fleet +
    /// connect the socket). Idempotent.
    func start()
    /// Stop producing data and release the connection. Idempotent.
    func stop()

    /// The user switched the active vehicle in the switcher — the live fleet
    /// narrows its socket subscription to `index`; sim ignores it (all tick).
    func setActive(index: Int)

    /// Scene lifecycle hooks, forwarded to the Kit socket (no-ops for sim).
    func handleForeground()
    func handleBackground()

    /// Drop a vehicle from the fleet after an authoritative backend teardown
    /// (MYR-258, §7.12): the car is gone from the app, so it leaves the switcher +
    /// the Settings list at once. The live fleet releases that vehicle's live
    /// source/executor/feed; the simulated fleet has no live teardown backend and
    /// ignores it (default no-op below).
    func remove(vehicleID: String)

    /// MYR-315 (§7.15) — ask the server for a newer read of one vehicle, waking it
    /// if the budget allows, then bring the resulting state down the NORMAL
    /// telemetry pipeline (the §7.15 response carries only a timestamp). Throws the
    /// typed `RestError` so the caller can fold `vehicle_asleep` / `rate_limited`
    /// onto honest copy. The simulated fleet has no server to ask and its fixtures
    /// are definitionally current, so it reports `.unsupported` (default below) and
    /// the stamp never renders there anyway.
    func refreshVehicle(at index: Int) async throws -> VehicleRefreshOutcome
}

extension VehicleFleet {
    /// Default: no removal (the simulated fleet's fixture list is immutable — the
    /// live teardown flow is a live-path affordance only, MYR-258/228).
    func remove(vehicleID: String) {}

    /// Default: nothing to refresh (simulated + every DEBUG capture fleet).
    func refreshVehicle(at index: Int) async throws -> VehicleRefreshOutcome { .unsupported }
}

// MARK: - SimulatedVehicleFleet (M1 default)

/// The fixture-backed fleet — the exact behavior `OwnerHomeState` shipped in
/// M1 (MYR-167), now behind the seam. One simulated source + executor per
/// `VehicleFixtures.vehicles` row, keyed by array index (stable — the fixtures
/// never mutate at runtime).
@Observable
@MainActor
final class SimulatedVehicleFleet: VehicleFleet {
    let vehicles: [Vehicle] = VehicleFixtures.vehicles

    private let sources: [any VehicleTelemetrySource]
    private let executors: [any VehicleCommandExecutor]
    /// One shared fixture feed — the M1 history is the same `DriveFixtures.drives`
    /// regardless of the selected vehicle (matches the M1 demo).
    private let sharedDrivesFeed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    init() {
        sources = VehicleFixtures.vehicles.map { SimulatedVehicleTelemetrySource(activity: $0.activity) }
        executors = VehicleFixtures.vehicles.map {
            SimulatedVehicleCommandExecutor(driving: $0.activity.isDriving, plate: $0.plate)
        }
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource { sources[index] }
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executors[index] }
    func drivesFeed(at index: Int) -> any DrivesFeed { sharedDrivesFeed }

    func badgeStatus(at index: Int) -> MRTVehicleStatus {
        vehicles[index].activity.isDriving ? .driving : .parked
    }

    func start() { sources.forEach { $0.start() } }
    func stop() { sources.forEach { $0.stop() } }

    // Every simulated source ticks independently (M1 behavior — switching
    // vehicles shows already-ticking telemetry), so there's no active-only
    // subscription to narrow.
    func setActive(index: Int) {}
    func handleForeground() {}
    func handleBackground() {}
}
