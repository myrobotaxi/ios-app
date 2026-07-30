#if DEBUG
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugClimateModeFleet (MYR-274 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that boots the REAL owner Home sheet with a live-like
// snapshot so the climate Auto/Cool/Heat SEGMENT can be captured full-frame in
// the simulator without a live backend (the live path is auth-gated and
// non-deterministic). It renders the ACTUAL `ClimateSection`, driven by the
// production `LiveVehicleCommandExecutor` seeded via the SAME `reconcile` path a
// real snapshot uses — so the capture shows exactly what a real car reports:
//
//   • `.auto`    — the car reports `hvacAutoMode == On`   → the segment lights **Auto**.
//   • `.cool`    — `hvacAutoMode == Override` + AC on      → the segment lights **Cool**
//                  (honest DISPLAY-ONLY; per MYR-274 tapping it sends nothing).
//   • `.unknown` — climate is ON but the mode field is ABSENT → the segment lights
//                  NOTHING (honest-unknown), never the seeded `.auto`.
//
// Every other cabin field is reconciled to a real value so the card reads as a
// populated live sheet and the ONLY thing that varies across the three captures
// is the mode segment. No sender is ever invoked (reconcile is purely local).
//
// Release builds never compile this file; it is reachable ONLY via the
// `ownerClimateAuto` / `ownerClimateManual` / `ownerClimateUnknown` debug scenes,
// so the normal `ownerHome` scene (and every other path) is untouched and the
// simulated drift-gate stays identical.
enum DebugClimateVariant { case auto, cool, unknown }

@Observable
@MainActor
final class DebugClimateModeFleet: VehicleFleet {
    let vehicles: [Vehicle]
    private let source: DebugClimateTelemetrySource
    private let executor: LiveVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    init(variant: DebugClimateVariant) {
        // Vehicle 0 (Cybercab, ventilated) — the climate hero renders exactly as
        // it does everywhere else; only the mode segment differs across variants.
        let vehicle = VehicleFixtures.vehicles[0]
        vehicles = [vehicle]

        let readAt = Date()
        source = DebugClimateTelemetrySource(lastUpdated: readAt)

        let exec = LiveVehicleCommandExecutor(
            vehicleID: vehicle.id,
            sender: DebugClimateNoopSender(),
            plateEndpoint: DebugPlateEndpoint(),
            // MYR-316 — never exercised in these scenes (none is in service), but
            // the seam is required; the stub keeps the executor total.
            serviceWindowEndpoint: DebugServiceWindowEndpoint(),
            // MYR-342 — the §7.18 seam. These scenes never flip the switch, so it
            // is only here to keep the executor's seam total; the row itself is
            // live-only and none of them render it.
            rideShareEndpoint: DebugRideShareEndpoint(),
            driving: false,
            plate: vehicle.plate
        )
        exec.reconcile(from: Self.climateState(variant: variant, lastUpdated: readAt))
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

    /// A parked, streaming `VehicleState` with a fully-populated cabin so the
    /// climate card reads as live; only the HVAC mode fields vary per variant.
    static func climateState(variant: DebugClimateVariant, lastUpdated: Date) -> VehicleState {
        let iso = ISO8601DateFormatter().string(from: lastUpdated)
        let mode: VehicleState.HvacAutoMode?
        let ac: Bool?
        switch variant {
        case .auto:    mode = .on;       ac = nil   // On → Auto
        case .cool:    mode = .override; ac = true  // Override + AC → Cool
        case .unknown: mode = nil;       ac = nil   // absent → honest-unknown
        }
        return VehicleState(
            vehicleId: "debug-climate",
            name: "Cybercab",
            model: "Cybercab",
            year: 2026,
            color: "Mercury Silver",
            status: .parked,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center · Lot B",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 71,
            estimatedRange: 210,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 20481,
            fsdMilesSinceReset: 128,
            locked: true,
            isClimateOn: true,          // climate ON → the segment (onContent) renders
            fanSpeed: 3,
            driverTempSetting: 70,
            hvacAutoMode: mode,
            hvacAcEnabled: ac,
            seatHeaterLeft: 2,
            seatHeaterRight: 0,
            seatCoolerLeft: 0,
            seatCoolerRight: 0,
            chargePortDoorOpen: false,
            trunkOpen: false,
            mediaPlaybackStatus: .paused,
            mediaVolume: 5.5,
            lastUpdated: iso
        )
    }
}

// MARK: - DebugClimateTelemetrySource

/// A fixed streaming snapshot for the screenshot: a parked, online car whose
/// interior/exterior temps populate the segment header ("Interior 68° · Outside
/// 61°") and whose footer honestly reads "Live".
@Observable
@MainActor
final class DebugClimateTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot

    init(lastUpdated: Date) {
        snapshot = VehicleTelemetrySnapshot(
            status: .parked,
            progress: 0,
            speedMPH: 0,
            batteryPercent: 71,
            etaMinutes: 0,
            interiorTempF: 68,
            exteriorTempF: 61,
            odometerMiles: 20481,
            fsdMilesSinceReset: 128,
            lastUpdated: lastUpdated,
            isStreaming: true
        )
    }

    func start() {}
    func stop() {}
}

// MARK: - DebugClimateNoopSender

/// Satisfies the executor's `sender` dependency; never actually invoked (the
/// screenshot path only reconciles, it doesn't send commands).
private struct DebugClimateNoopSender: VehicleCommandSending {
    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        VehicleCommandResult(status: "ok", command: "noop", vin: nil)
    }
}
#endif
