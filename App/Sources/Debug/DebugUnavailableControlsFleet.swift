#if DEBUG
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugUnavailableControlsFleet (MYR-260 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that boots the REAL owner Home sheet into the honest
// unknown / stale controls state so the new copy can be captured full-frame in
// the simulator without a live backend (the live path is auth-gated and
// non-deterministic). It renders the ACTUAL `VehicleControls`, not a hand-built
// mock, driven by the production `LiveVehicleCommandExecutor`:
//
//   • Lock + Trunk are KNOWN (owner-confirmed) but the snapshot's `lastUpdated`
//     is 2h old and the car is NOT streaming → they show their value with the
//     bounded stale qualifier ("Synced 2h ago" / "Open · 2h ago").
//   • Climate + Charge are UNKNOWN on a reachable-but-offline snapshot → they
//     show the honest "— Unavailable" (not a perpetual "— Syncing").
//
// Release builds never compile this file; it is reachable ONLY via the
// `ownerControlsUnavailable` debug scene, so the normal `ownerHome` scene (and
// every other path) is untouched and the simulated drift-gate stays identical.
@Observable
@MainActor
final class DebugUnavailableControlsFleet: VehicleFleet {
    let vehicles: [Vehicle]
    private let source: DebugStaticTelemetrySource
    private let executor: LiveVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    init() {
        // Reuse the parked "Daily" fixture row so the parked hero renders exactly
        // as it does everywhere else — only the freshness/known-state differs.
        let vehicle = VehicleFixtures.vehicles[1]
        vehicles = [vehicle]

        // A read from 2h ago, from a car that is NOT streaming (offline).
        let readAt = Date().addingTimeInterval(-2 * 3600)
        source = DebugStaticTelemetrySource(lastUpdated: readAt)

        // The production executor, seeded via the SAME reconcile path a real
        // snapshot uses: Lock + Trunk present (→ known), Climate + Charge absent
        // (→ honest unknown). No sender is ever called (reconcile is local).
        let exec = LiveVehicleCommandExecutor(
            vehicleID: vehicle.id,
            sender: DebugNoopCommandSender(),
            driving: false,
            plate: vehicle.plate
        )
        exec.reconcile(from: DebugStaticTelemetrySource.knownLockTrunkState(lastUpdated: readAt))
        executor = exec
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource { source }
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executor }
    func drivesFeed(at index: Int) -> any DrivesFeed { feed }
    func badgeStatus(at index: Int) -> MRTVehicleStatus { .offline }

    func start() {}
    func stop() {}
    func setActive(index: Int) {}
    func handleForeground() {}
    func handleBackground() {}
}

// MARK: - DebugStaticTelemetrySource

/// A fixed snapshot for the screenshot: a reachable-but-NOT-streaming parked car
/// whose read time is old. `interiorTempF`/odometer stay `nil` (honest-unknown,
/// as an offline car's REST read may omit them).
@Observable
@MainActor
final class DebugStaticTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot

    init(lastUpdated: Date) {
        snapshot = VehicleTelemetrySnapshot(
            status: .parked,
            progress: 0,
            speedMPH: 0,
            batteryPercent: 62,
            etaMinutes: 0,
            interiorTempF: nil,
            exteriorTempF: nil,
            odometerMiles: nil,
            fsdMilesSinceReset: nil,
            lastUpdated: lastUpdated,
            isStreaming: false
        )
    }

    func start() {}
    func stop() {}

    /// A minimal `VehicleState` carrying ONLY lock + trunk so `reconcile` marks
    /// exactly those two fields known (Climate/Charge stay honestly unknown).
    static func knownLockTrunkState(lastUpdated: Date) -> VehicleState {
        let iso = ISO8601DateFormatter().string(from: lastUpdated)
        return VehicleState(
            vehicleId: "debug",
            name: "Daily",
            model: "Model 3 LR",
            year: 2024,
            color: "Pearl White",
            status: .offline,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center · Lot B",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            chargeLevel: 62,
            estimatedRange: 190,
            interiorTemp: 0,
            exteriorTemp: 0,
            odometerMiles: 20481,
            fsdMilesSinceReset: 12,
            locked: true,      // → Lock known (stale)
            trunkOpen: true,   // → Trunk known + OPEN (the safety case, stale)
            lastUpdated: iso
        )
    }
}

// MARK: - DebugNoopCommandSender

/// Satisfies the executor's `sender` dependency; never actually invoked (the
/// screenshot path only reconciles, it doesn't send commands).
private struct DebugNoopCommandSender: VehicleCommandSending {
    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        VehicleCommandResult(status: "ok", command: "noop", vin: nil)
    }
}
#endif
