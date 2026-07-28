#if DEBUG
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugFreshnessFleet (MYR-315 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that boots the REAL owner Home sheet against a car that has
// been OFFLINE for hours, so the freshness stamp's stale state — the whole point
// of MYR-315 — is capturable full-frame in the simulator. It cannot be reached any
// other way: a simulated snapshot carries no freshness signals at all (by design,
// MYR-260), and the live path needs a real account plus a car that actually went
// to sleep, which is neither deterministic nor available headlessly.
//
// The snapshot travels the PRODUCTION `VehicleContractMapping`, so `isStreaming`
// is derived from the real wire `status` (`.offline` → false) and `lastUpdated`
// from the real RFC3339 parse. The stamp the capture shows is therefore the one
// the shipping resolver produced, not a hand-set string.
//
// Release builds never compile this file; it is reachable only via the
// `ownerFreshnessStale` / `ownerFreshnessWaking` scenes, so every other owner path
// — `ownerHome` included — is untouched and the simulated drift gate stays
// byte-identical.
@Observable
@MainActor
final class DebugFreshnessFleet: VehicleFleet {
    let vehicles: [Vehicle]
    private let source: DebugFreshnessTelemetrySource
    private let executor: SimulatedVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    /// How long ago the car was last heard from. 7h is the client's own reported
    /// case ("Synced 7h ago"), and it is comfortably past
    /// `VehicleControlFreshness.staleThreshold`, so the stamp is genuinely stale
    /// and a tap genuinely wakes rather than acknowledging.
    static let staleInterval: TimeInterval = 7 * 3600

    init() {
        let state = Self.staleState()
        let summary = VehicleSummary(
            vehicleId: "debug-freshness",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3456",
            // OFFLINE is what makes the mapped `isStreaming` false — the condition
            // the stamp reports on. A parked car streams, and would honestly read
            // "Live".
            status: .offline,
            chargeLevel: 64,
            estimatedRange: 174,
            lastUpdated: state.lastUpdated,
            role: .owner,
            licensePlate: nil
        )
        vehicles = [VehicleContractMapping.vehicle(summary: summary, state: state)]
        source = DebugFreshnessTelemetrySource(snapshot: VehicleContractMapping.snapshot(from: state))
        executor = SimulatedVehicleCommandExecutor(driving: false, plate: "")
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

    /// A tap in the capture scene must not hang on a network call that can never
    /// resolve, and must not silently succeed either (which would clear the stale
    /// stamp mid-screenshot). It reports the honest asleep failure — the same
    /// typed 503 a real wake-budget-exhausted refresh returns.
    func refreshVehicle(at index: Int) async throws -> VehicleRefreshOutcome {
        throw RestError.http(
            status: 503,
            code: ErrorPayload.Code(rawValue: "vehicle_asleep"),
            message: nil,
            subCode: nil
        )
    }

    /// A parked-then-offline `VehicleState` whose `lastUpdated` is hours old — the
    /// exact shape a car that went to sleep leaves behind.
    static func staleState() -> VehicleState {
        let readAt = Date().addingTimeInterval(-staleInterval)
        return VehicleState(
            vehicleId: "debug-freshness",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vin: "7SAYGDEE9RA123456",
            softwareVersion: "2026.14.3",
            trim: "Performance",
            status: .offline,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center \u{00B7} Lot B",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 64,
            estimatedRange: 174,
            interiorTemp: 58,
            exteriorTemp: 55,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            lastUpdated: ISO8601DateFormatter().string(from: readAt)
        )
    }
}

// MARK: - DebugFreshnessTelemetrySource

/// Holds one fixed live-mapped snapshot (offline, hours-old read time) so the
/// stamp resolves its stale branch and holds still for a screenshot.
@Observable
@MainActor
private final class DebugFreshnessTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot
    init(snapshot: VehicleTelemetrySnapshot) { self.snapshot = snapshot }
    func start() {}
    func stop() {}
}
#endif
