import DesignSystem
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - LiveVehicleTelemetrySource (MYR-201 deliverable 1)
//
// The App-side adapter that fulfills the `VehicleTelemetrySource` seam
// (VehicleTelemetry.swift) with REAL data from `MyRoboTaxiKit`. It wraps the
// Kit's `@Observable LiveVehicleState` bridge — which already accumulates the
// REST cold snapshot + live `vehicle_update` deltas and mirrors the socket's
// connection/data state — and projects its `VehicleState` onto the app's
// `VehicleTelemetrySnapshot` via the pure `VehicleContractMapping`.
//
// `HomeScreen`/`HomeSheetContent` never change: they read `snapshot` exactly as
// they do for `SimulatedVehicleTelemetrySource`. The extra live-only surface
// (`liveState`, `badgeStatus`, `connectionState`) is read by the fleet + screen
// to build the fleet row and the graceful connecting/offline states.
//
// Observation note (mirrors `VehicleTelemetrySource`'s doc comment): reads of
// `liveState.state` / `.connectionState` inside these computed properties are
// tracked by `@Observable` on the concrete `LiveVehicleState`, so a SwiftUI body
// that reads `source.snapshot` re-renders when the live state changes — even
// through the `any VehicleTelemetrySource` existential.
@Observable
@MainActor
final class LiveVehicleTelemetrySource: VehicleTelemetrySource {
    /// The Kit bridge for this one vehicle. Owns the subscribe/fold lifecycle.
    let liveState: LiveVehicleState

    init(liveState: LiveVehicleState) {
        self.liveState = liveState
    }

    /// The accumulated live `VehicleState`, or `nil` until the first snapshot
    /// arrives. Retained across disconnects (NFR-3.12/3.13), so the UI keeps
    /// showing last-known values.
    var state: VehicleState? { liveState.state }

    /// Transport health, mirrored from the socket — drives the screen's subtle
    /// connecting indicator (deliverable 3).
    var connectionState: ConnectionState { liveState.connectionState }

    /// The design badge state for this vehicle (driving/parked/charging/offline),
    /// folded from the live wire `status`. Neutral `offline` before any snapshot.
    var badgeStatus: MRTVehicleStatus {
        guard let state else { return .offline }
        return VehicleContractMapping.badgeStatus(from: state.status)
    }

    // MARK: VehicleTelemetrySource

    /// The per-tick hero snapshot. Before the first live snapshot arrives, emit a
    /// neutral placeholder (parked, zeros) so the hero renders a calm connecting
    /// state rather than crashing or flashing stale fixture data.
    var snapshot: VehicleTelemetrySnapshot {
        guard let state else { return Self.placeholder }
        return VehicleContractMapping.snapshot(from: state)
    }

    func start() { liveState.start() }
    func stop() { liveState.stop() }

    static let placeholder = VehicleTelemetrySnapshot(
        status: .parked,
        progress: 0,
        speedMPH: 0,
        batteryPercent: 0,
        etaMinutes: 0
    )
}
