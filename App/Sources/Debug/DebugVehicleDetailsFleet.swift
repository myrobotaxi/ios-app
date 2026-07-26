#if DEBUG
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugVehicleDetailsFleet (MYR-279 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that boots the REAL owner Home sheet with a live-like
// snapshot so the vehicle-details section can be captured full-frame in the
// simulator without a live backend (the live path is auth-gated and
// non-deterministic). It renders the ACTUAL `VehicleControls`, driven by the
// SAME `VehicleContractMapping` the production live path uses — so the capture
// shows exactly what a real snapshot would render:
//
//   • Make/model = "2026 Model Y Performance" (composed from the snapshot's
//     year + model + trim — the client's bare "Model" bug, fixed).
//   • VIN = the full (owner-masked) VIN from the snapshot.
//   • Software = the Tesla software version from the snapshot.
//   • Color = HONEST empty ("— Unavailable") — onboarding doesn't write it yet
//     (MYR-283); we never fabricate a color.
//   • Tire pressure = HONEST "Available after your next drive" (TPMS is
//     uncontracted; a live-mapped row carries no fixture pressures).
//
// Release builds never compile this file; it is reachable ONLY via the
// `ownerVehicleDetails` debug scene, so the normal `ownerHome` scene (and every
// other path) is untouched and the simulated drift-gate stays identical.
@Observable
@MainActor
final class DebugVehicleDetailsFleet: VehicleFleet {
    let vehicles: [Vehicle]
    private let source: DebugDetailsTelemetrySource
    private let executor: LiveVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    init() {
        // A live-like snapshot: full model/year/trim, full VIN + software version,
        // and a BLANK color (onboarding gap, MYR-283). Streaming/online so the
        // footer honestly reads "Live".
        let state = Self.detailsState()
        let summary = VehicleSummary(
            vehicleId: "debug-mdy",
            name: "Model Y",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3456",
            status: .parked,
            chargeLevel: 71,
            estimatedRange: 193,
            lastUpdated: state.lastUpdated,
            role: .owner
        )
        // The REAL production mapping: the details rows read exactly what live
        // would render (composed model, snapshot VIN/software, honest color, no
        // fixture tires).
        vehicles = [VehicleContractMapping.vehicle(summary: summary, state: state)]
        source = DebugDetailsTelemetrySource(snapshot: VehicleContractMapping.snapshot(from: state))

        let exec = LiveVehicleCommandExecutor(
            vehicleID: summary.vehicleId,
            sender: DebugDetailsNoopSender(),
            driving: false,
            plate: VehicleContractMapping.plateDisplay(vinLast4: summary.vinLast4)
        )
        exec.reconcile(from: state)
        executor = exec
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource { source }
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executor }
    func drivesFeed(at index: Int) -> any DrivesFeed { feed }
    func badgeStatus(at index: Int) -> MRTVehicleStatus { .parked }

    func start() {}
    func stop() {}
    func setActive(index: Int) {}
    func handleForeground() {}
    func handleBackground() {}

    /// A parked, streaming `VehicleState` carrying the MYR-279 detail fields.
    static func detailsState() -> VehicleState {
        let iso = ISO8601DateFormatter().string(from: Date())
        return VehicleState(
            vehicleId: "debug-mdy",
            name: "Model Y",
            model: "Model Y",
            year: 2026,
            color: "",                       // onboarding gap → honest empty (MYR-283)
            vin: "7SAYGDEE9RA123456",        // full (owner-masked) VIN
            softwareVersion: "2026.14.3",
            trim: "Performance",             // → "2026 Model Y Performance"
            status: .parked,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center · Lot B",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 71,
            estimatedRange: 193,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            lastUpdated: iso
        )
    }
}

// MARK: - DebugDetailsTelemetrySource

/// Holds one fixed live-mapped snapshot for the screenshot (streaming/online so
/// the freshness footer honestly reads "Live").
@Observable
@MainActor
private final class DebugDetailsTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot
    init(snapshot: VehicleTelemetrySnapshot) { self.snapshot = snapshot }
    func start() {}
    func stop() {}
}

// MARK: - DebugDetailsNoopSender

/// Satisfies the executor's `sender` dependency; never actually invoked (the
/// screenshot path only reconciles, it doesn't send commands).
private struct DebugDetailsNoopSender: VehicleCommandSending {
    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        VehicleCommandResult(status: "ok", command: "noop", vin: nil)
    }
}
#endif
