#if DEBUG
import CoreLocation
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugDrivingNavigationFleet (MYR-294 — drift-gate / screenshot only)
//
// The two DRIVING states the prototype has no hero for, and that no simulated
// scene can reach: a car driving with NO active navigation, and a car whose
// navigation is live but whose destination NAME has not arrived yet.
//
// Both are live-path-only BY CONSTRUCTION. Every fixture trip is
// `.destination(name:city:address:)` — `VehicleFixtures.cybercabTrip` carries the
// prototype's own "Pescadero · Duarte's Tavern" literals — so `ownerHome` and
// every other simulated owner scene renders the navigating hero exactly as it
// always has and is byte-identical. Reaching either state for real needs a car
// genuinely in motion behind a real auth session, which is neither deterministic
// nor available headlessly.
//
// What the capture shows is the SHIPPING resolution, not a hand-set flag. Each
// arm injects a live-shaped `VehicleState` whose navigation fields are exactly
// what the wire would carry, and lets the production
// `VehicleContractMapping.navigation(from:)` classify it — so the scene exercises
// the atomic-group predicate this issue is about. A capture that seeded
// `DrivingNavigation` directly would prove only that the enum renders.
@Observable
@MainActor
final class DebugDrivingNavigationFleet: VehicleFleet {
    /// Which arm this fleet is standing up.
    enum Condition {
        /// The client's *"When no navigation, state just shows navigating"*: the
        /// nav atomic group is entirely null (FR-2.3's cleared state).
        case noNavigation
        /// The client's *"Taking a long time to populate destination name even
        /// though route appeared"*: Tesla decoded the RouteLine and the server has
        /// the ETA and the destination coordinates, but `DestinationName` — which
        /// Tesla emits independently — has not landed. Up to ~60s of every real
        /// trip looks like this.
        case resolvingDestination
    }

    let vehicles: [Vehicle]
    private let source: DebugDrivingTelemetrySource
    private let executor: SimulatedVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    init(condition: Condition) {
        let state = Self.state(for: condition)
        let summary = VehicleSummary(
            vehicleId: "debug-driving-nav",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3456",
            status: .driving,
            chargeLevel: 64,
            estimatedRange: 174,
            lastUpdated: state.lastUpdated,
            role: .owner,
            licensePlate: nil
        )
        vehicles = [VehicleContractMapping.vehicle(summary: summary, state: state)]
        source = DebugDrivingTelemetrySource(snapshot: VehicleContractMapping.snapshot(from: state))
        executor = SimulatedVehicleCommandExecutor(driving: true, plate: "")
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource { source }
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executor }
    func drivesFeed(at index: Int) -> any DrivesFeed { feed }
    func badgeStatus(at index: Int) -> MRTVehicleStatus { .driving }

    func start() {}
    func stop() {}
    func setActive(index: Int) {}
    func handleForeground() {}
    func handleBackground() {}
    func refreshVehicle(at index: Int) async throws -> VehicleRefreshOutcome { .refreshed }

    /// A live-shaped driving `VehicleState`. The two arms differ ONLY in their
    /// navigation-group members — everything else (position, speed, battery,
    /// cabin, odometer) is identical — so the pair of captures is a clean
    /// before/after of exactly what this issue changed.
    static func state(for condition: Condition) -> VehicleState {
        var state = VehicleState(
            vehicleId: "debug-driving-nav",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            status: .driving,
            speed: 38,
            heading: 214,
            latitude: 37.7749,
            longitude: -122.4194,
            // The car's CURRENT place — not a nav field, always present while
            // driving, and what the honest hero shows in the destination's slot.
            locationName: "Market St \u{00B7} San Francisco",
            locationAddress: "798 Market St, San Francisco",
            gearPosition: .d,
            chargeLevel: 64,
            estimatedRange: 174,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            lastUpdated: ISO8601DateFormatter().string(from: Date())
        )
        switch condition {
        case .noNavigation:
            // Nothing to set: every navigation member stays nil, which is the
            // contract's own "no active navigation". Stated rather than left
            // implicit, because the whole scene is about this being the state.
            break
        case .resolvingDestination:
            state.navRouteCoordinates = Self.routeLine
            state.destinationLatitude = 37.8087
            state.destinationLongitude = -122.4098
            state.originLatitude = 37.7749
            state.originLongitude = -122.4194
            state.etaMinutes = 12
            // MUST be less than `routeLine`'s own length (~2.4 mi), or
            // `tripProgress` clamps to 0 and the hero honestly drops the progress
            // bar — a real behaviour, but not the one this scene is for. A capture
            // built from inconsistent wire values photographs the wrong branch and
            // looks entirely plausible doing it.
            state.tripDistanceRemaining = 1.6
            // `destinationName` and `destinationAddress` are deliberately LEFT
            // NIL — that is the whole condition.
        }
        return state
    }

    /// A short decoded RouteLine, in the wire's own `[longitude, latitude]`
    /// (GeoJSON/Mapbox) order — Market St up toward Fisherman's Wharf.
    static let routeLine: [[Double]] = [
        [-122.4194, 37.7749], [-122.4152, 37.7833], [-122.4119, 37.7912],
        [-122.4098, 37.8010], [-122.4098, 37.8087],
    ]
}

// MARK: - DebugDrivingTelemetrySource

/// Holds one fixed live-mapped driving snapshot so the hero holds still for a
/// screenshot (no ticking progress, no advancing clock).
@Observable
@MainActor
private final class DebugDrivingTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot
    init(snapshot: VehicleTelemetrySnapshot) { self.snapshot = snapshot }
    func start() {}
    func stop() {}
}
#endif
