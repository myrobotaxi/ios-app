import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-201 deliverable 5 — adapter mapping tests
//
// Contracts fixture → view model, incl. the open-enum `unrecognized` arms and
// the `offline` badge. Pure Swift-value transforms — no network.
final class VehicleContractMappingTests: XCTestCase {

    // MARK: Status → design badge

    func testBadgeStatusCoversEveryKnownWireStatus() {
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.driving), .driving)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.parked), .parked)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.charging), .charging)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.offline), .offline)
    }

    func testBadgeStatusInServiceFallsBackToNeutralParked() {
        // No shipped in-service badge — the calm stationary fallback.
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.inService), .parked)
    }

    func testBadgeStatusUnrecognizedFallsBackToNeutralOffline() {
        // Forward-compat wire value from a newer contracts build (MYR-195).
        XCTAssertEqual(
            VehicleContractMapping.badgeStatus(from: VehicleState.Status.unrecognized("teleporting")),
            .offline
        )
    }

    func testSummaryBadgeStatusMatchesStateMapping() {
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.offline), .offline)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.charging), .charging)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.inService), .parked)
        XCTAssertEqual(
            VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.unrecognized("x")),
            .offline
        )
    }

    // MARK: VehicleState → snapshot

    func testDrivingSnapshotMapsSpeedBatteryEta() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState(chargeLevel: 68, speed: 64, etaMinutes: 42))
        XCTAssertEqual(snapshot.status, .driving)
        XCTAssertEqual(snapshot.speedMPH, 64)
        XCTAssertEqual(snapshot.batteryPercent, 68)
        XCTAssertEqual(snapshot.etaMinutes, 42)
        XCTAssertGreaterThan(snapshot.progress, 0)
        XCTAssertLessThanOrEqual(snapshot.progress, 1)
    }

    func testParkedSnapshotZeroesMotionFields() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.parkedState(chargeLevel: 82))
        XCTAssertEqual(snapshot.status, .parked)
        XCTAssertEqual(snapshot.speedMPH, 0)
        XCTAssertEqual(snapshot.progress, 0)
        XCTAssertEqual(snapshot.etaMinutes, 0)
        XCTAssertEqual(snapshot.batteryPercent, 82)
    }

    func testChargingIsStationaryHero() {
        // Charging is not "driving" — the hero renders the stationary/parked
        // layout even though the badge says Charging.
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.parkedState(status: .charging))
        XCTAssertEqual(snapshot.status, .parked)
        XCTAssertEqual(snapshot.progress, 0)
    }

    func testOfflineStateMapsToParkedSnapshotButOfflineBadge() {
        let state = Contracts.parkedState(status: .offline)
        XCTAssertEqual(VehicleContractMapping.snapshot(from: state).status, .parked)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: state.status), .offline)
    }

    func testSnapshotClampsOutOfRangeChargeAndSpeed() {
        var state = Contracts.drivingState()
        state.chargeLevel = 130
        state.speed = -5
        let high = VehicleContractMapping.snapshot(from: state)
        XCTAssertEqual(high.batteryPercent, 100)
        XCTAssertEqual(high.speedMPH, 0)

        state.chargeLevel = -20
        XCTAssertEqual(VehicleContractMapping.snapshot(from: state).batteryPercent, 0)
    }

    func testMissingEtaDefaultsToZero() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState(etaMinutes: nil))
        XCTAssertEqual(snapshot.etaMinutes, 0)
    }

    // MARK: tripProgress

    func testTripProgressFromDistanceRemaining() {
        // ~48mi total route; ~6mi remaining → well past halfway.
        let nearEnd = VehicleContractMapping.tripProgress(from: Contracts.drivingState(tripDistanceRemaining: 3))
        let midway = VehicleContractMapping.tripProgress(from: Contracts.drivingState(tripDistanceRemaining: 30))
        XCTAssertGreaterThan(nearEnd, midway)
        XCTAssertTrue((0...1).contains(nearEnd))
        XCTAssertTrue((0...1).contains(midway))
    }

    func testTripProgressZeroWhenNoDistance() {
        XCTAssertEqual(VehicleContractMapping.tripProgress(from: Contracts.drivingState(tripDistanceRemaining: nil)), 0)
    }

    // MARK: VehicleState → activity

    func testDrivingActivityBuildsTripFromNavGroup() {
        guard case .driving(let trip) = VehicleContractMapping.activity(from: Contracts.drivingState()) else {
            return XCTFail("expected driving activity")
        }
        XCTAssertEqual(trip.destinationName, "Duarte's Tavern")
        XCTAssertEqual(trip.destinationCity, "Pescadero")   // city component of the address
        XCTAssertEqual(trip.originLabel, "Home")
        XCTAssertEqual(trip.route.count, 2)
        // GeoJSON [lon, lat] decoded to (lat, lon).
        XCTAssertEqual(trip.route.first?.latitude ?? 0, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(trip.route.first?.longitude ?? 0, -122.4194, accuracy: 0.0001)
    }

    func testParkedActivityBuildsLocationAtCurrentPosition() {
        guard case .parked(let loc) = VehicleContractMapping.activity(from: Contracts.parkedState()) else {
            return XCTFail("expected parked activity")
        }
        XCTAssertEqual(loc.label, "Embarcadero Center · Lot B")
        XCTAssertEqual(loc.coordinate.latitude, 37.7955, accuracy: 0.0001)
        XCTAssertEqual(loc.coordinate.longitude, -122.3937, accuracy: 0.0001)
    }

    func testDrivingActivityFallsBackToOriginDestinationWhenNoRoute() {
        var state = Contracts.drivingState()
        state.navRouteCoordinates = nil // Tesla hasn't decoded a RouteLine yet
        guard case .driving(let trip) = VehicleContractMapping.activity(from: state) else {
            return XCTFail("expected driving activity")
        }
        // current position + destination coordinate → a 2-point straight route.
        XCTAssertEqual(trip.route.count, 2)
    }

    func testParkedActivityLabelFallsBackWhenGeocodeMissing() {
        var state = Contracts.parkedState()
        state.locationName = ""
        state.locationAddress = ""
        guard case .parked(let loc) = VehicleContractMapping.activity(from: state) else {
            return XCTFail("expected parked activity")
        }
        XCTAssertEqual(loc.label, "Location unavailable")
    }

    // MARK: Summary + state → Vehicle row

    func testVehicleRowFromSummaryComposesModelPlateColor() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary())
        XCTAssertEqual(vehicle.id, "v2")
        XCTAssertEqual(vehicle.name, "Daily")
        XCTAssertEqual(vehicle.model, "2024 Model 3 LR")
        XCTAssertEqual(vehicle.colorName, "Pearl White")
        XCTAssertEqual(vehicle.plate, "VIN ····9417")
    }

    func testVehicleRowPlateEmptyWhenVinUnknown() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(vinLast4: ""))
        XCTAssertEqual(vehicle.plate, "")
    }

    func testVehicleRowUsesPlaceholderActivityBeforeSnapshot() {
        // No live state yet → a parked "Locating…" placeholder for a parked row.
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(status: .parked))
        guard case .parked(let loc) = vehicle.activity else { return XCTFail("expected parked placeholder") }
        XCTAssertEqual(loc.label, "Locating…")
    }

    func testUnrecognizedSummaryStatusGetsParkedPlaceholderActivity() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(status: .unrecognized("cruising")))
        if case .driving = vehicle.activity { XCTFail("unrecognized should not render the driving hero") }
    }

    func testVehicleRowFoldsLiveStateActivityOverPlaceholder() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(status: .parked), state: Contracts.drivingState())
        guard case .driving(let trip) = vehicle.activity else {
            return XCTFail("live driving state should upgrade the row to a driving activity")
        }
        XCTAssertEqual(trip.destinationName, "Duarte's Tavern")
    }

    func testBadgeStatusForSummaryPrefersLiveState() {
        // Summary says parked, live snapshot says charging → badge tracks live.
        let badge = VehicleContractMapping.badgeStatus(
            forSummary: Contracts.summary(status: .parked),
            state: Contracts.parkedState(status: .charging)
        )
        XCTAssertEqual(badge, .charging)
    }

    // MARK: Helpers

    func testModelLabelOmitsYearWhenZero() {
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 0, model: "Cybercab"), "Cybercab")
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 2026, model: "Cybercab"), "2026 Cybercab")
    }

    func testRouteCoordinatesDropMalformedPairs() {
        let coords = VehicleContractMapping.routeCoordinates(from: [[-122.4, 37.7], [1.0], [-121.9, 37.3]])
        XCTAssertEqual(coords.count, 2)
    }

    func testCityComponentPicksSecondToLast() {
        XCTAssertEqual(VehicleContractMapping.cityComponent(from: "202 Stage Rd, Pescadero, CA"), "Pescadero")
        XCTAssertEqual(VehicleContractMapping.cityComponent(from: "Somewhere"), "Somewhere")
        XCTAssertNil(VehicleContractMapping.cityComponent(from: ""))
    }

    // MARK: LiveVehicleTelemetrySource placeholder

    func testLiveSourcePlaceholderIsCalmParkedZero() {
        let placeholder = LiveVehicleTelemetrySource.placeholder
        XCTAssertEqual(placeholder.status, .parked)
        XCTAssertEqual(placeholder.speedMPH, 0)
        XCTAssertEqual(placeholder.progress, 0)
        XCTAssertEqual(placeholder.batteryPercent, 0)
    }
}
