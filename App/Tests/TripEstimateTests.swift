import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-212 deliverable 5 — trip estimate (pure, no network)

final class TripEstimateTests: XCTestCase {

    private let downtownDallas = CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)
    private let frisco = CLLocationCoordinate2D(latitude: 33.1507, longitude: -96.8236)

    func testEstimateProducesDetourInflatedMilesAndSpeedBasedMinutes() {
        let straight = TripEstimate.straightLineMiles(from: downtownDallas, to: frisco)
        let est = TripEstimate.estimate(from: downtownDallas, to: frisco)
        // Miles are the straight line inflated by the detour factor.
        XCTAssertEqual(est.miles, straight * TripEstimate.detourFactor, accuracy: 0.001)
        // Minutes derive from the flat average speed.
        let expectedMinutes = max(1, Int((est.miles / TripEstimate.averageSpeedMph * 60).rounded()))
        XCTAssertEqual(est.minutes, expectedMinutes)
        XCTAssertGreaterThan(est.miles, 20) // ~25mi straight → ~33mi detoured
    }

    func testMinutesNeverZeroForAVeryShortHop() {
        let a = CLLocationCoordinate2D(latitude: 33.0, longitude: -96.85)
        let b = CLLocationCoordinate2D(latitude: 33.0005, longitude: -96.85) // ~50m
        XCTAssertEqual(TripEstimate.estimate(from: a, to: b).minutes, 1)
    }

    func testAppliedComputesWhenDestinationHasNoEstimate() {
        // A live search / pin destination carries minutes == 0.
        let dest = RidePlace(id: "live|x", label: "Bell Southstone Yards", subtitle: nil,
                             miles: 0, minutes: 0, icon: "mappin", coordinate: frisco)
        let out = TripEstimate.applied(to: dest, pickup: downtownDallas)
        XCTAssertGreaterThan(out.minutes, 0)
        XCTAssertGreaterThan(out.miles, 0)
        XCTAssertEqual(out.label, "Bell Southstone Yards") // identity preserved
        XCTAssertEqual(out.coordinate.latitude, frisco.latitude, accuracy: 0.0001)
    }

    func testAppliedLeavesFixtureDestinationsUntouched() {
        // A fixture destination already carries miles/minutes → never re-estimated
        // (this is what keeps the simulated flow pixel-identical).
        let fixture = RideRequestFixtures.recentPlaces[0] // Tartine — 3.1 mi / 14 min
        let out = TripEstimate.applied(to: fixture, pickup: downtownDallas)
        XCTAssertEqual(out.minutes, fixture.minutes)
        XCTAssertEqual(out.miles, fixture.miles, accuracy: 0.0001)
    }
}
