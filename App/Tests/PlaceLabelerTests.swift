import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-204 deliverable 3 — place labeling ladder
//
// Layer (a) saved-place proximity (~150 m) is pure/deterministic and covered
// here. Layer (b) reverse geocoding is exercised only via its timeout degrade
// (a ~1 ms timeout forces the fallback), so these tests never hit the network.
final class PlaceLabelerTests: XCTestCase {

    // RideRequestFixtures.savedPlaces: Home 37.7871,-122.3971; Work 37.7955,-122.3937.
    private let home = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)

    private func labeler(timeout: Duration = .milliseconds(1)) -> PlaceLabeler {
        PlaceLabeler(savedPlaces: RideRequestFixtures.savedPlaces, proximityMeters: 150, geocodeTimeout: timeout)
    }

    func testNearestSavedPlaceMatchesWithinRadius() async {
        // ~55 m north of Home (0.0005° lat ≈ 55 m).
        let near = CLLocationCoordinate2D(latitude: home.latitude + 0.0005, longitude: home.longitude)
        let match = await labeler().nearestSavedPlace(to: near)
        XCTAssertEqual(match?.label, "Home")
    }

    func testNearestSavedPlaceNilWhenBeyondRadius() async {
        // Dallas, TX — nowhere near the SF saved places.
        let far = CLLocationCoordinate2D(latitude: 32.9925, longitude: -96.7942)
        let match = await labeler().nearestSavedPlace(to: far)
        XCTAssertNil(match)
    }

    func testLabelReturnsSavedNameBeforeAnyGeocode() async {
        let near = CLLocationCoordinate2D(latitude: home.latitude + 0.0004, longitude: home.longitude)
        let label = await labeler().label(for: near, fallback: "742 Evergreen Terrace", cacheKey: "d1|start")
        XCTAssertEqual(label, "Home", "saved-place match short-circuits geocoding")
    }

    func testLabelFallsBackToAddressWhenGeocodeTimesOut() async {
        // A coordinate with no saved match; the ~1 ms timeout forces layer (c).
        let far = CLLocationCoordinate2D(latitude: 32.9925, longitude: -96.7942)
        let label = await labeler().label(for: far, fallback: "4222 Stratus Way, Frisco", cacheKey: "d2|end")
        XCTAssertEqual(label, "4222 Stratus Way, Frisco")
    }

    func testNameFromNilPlacemarkIsNil() {
        XCTAssertNil(PlaceLabeler.name(from: nil))
    }
}
