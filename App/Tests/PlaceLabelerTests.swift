import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-204/MYR-208 — place labeling ladder
//
// Layer (a) saved-place proximity (~150 m) and the pairwise city rule are
// pure/deterministic and covered here. The reverse geocode is exercised only
// via its timeout degrade (a ~1 ms timeout forces the fallback), so these
// tests never hit the network.
final class PlaceLabelerTests: XCTestCase {

    private typealias Endpoint = PlaceLabeler.ResolvedEndpoint

    // RideRequestFixtures.savedPlaces: Home 37.7871,-122.3971; Work 37.7955,-122.3937.
    private let home = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
    private let dallas = CLLocationCoordinate2D(latitude: 32.9925, longitude: -96.7942)

    private func labeler(timeout: Duration = .milliseconds(1)) -> PlaceLabeler {
        PlaceLabeler(savedPlaces: RideRequestFixtures.savedPlaces, proximityMeters: 150, geocodeTimeout: timeout)
    }

    // MARK: Layer (a) — saved places

    func testNearestSavedPlaceMatchesWithinRadius() async {
        // ~55 m north of Home (0.0005° lat ≈ 55 m).
        let near = CLLocationCoordinate2D(latitude: home.latitude + 0.0005, longitude: home.longitude)
        let match = await labeler().nearestSavedPlace(to: near)
        XCTAssertEqual(match?.label, "Home")
    }

    func testNearestSavedPlaceNilWhenBeyondRadius() async {
        let match = await labeler().nearestSavedPlace(to: dallas)
        XCTAssertNil(match)
    }

    func testResolveEndpointUsesSavedNameBeforeAnyGeocode() async {
        let near = CLLocationCoordinate2D(latitude: home.latitude + 0.0004, longitude: home.longitude)
        let resolved = await labeler().resolveEndpoint(near)
        XCTAssertEqual(resolved.specific, "Home", "saved-place match short-circuits geocoding")
    }

    // MARK: Pairwise city rule (pure)

    func testDifferentCitiesRenderCityFallback() {
        // The Frisco → Dallas live drive: no POI/neighborhood at either end.
        let pair = PlaceLabeler.pairLabels(
            start: Endpoint(specific: nil, locality: "Frisco"),
            end: Endpoint(specific: nil, locality: "Dallas"),
            fallbacks: ("4222 Stratus Way, Frisco", "17817 Davenport Road, Dallas")
        )
        XCTAssertEqual(pair.start, "Frisco")
        XCTAssertEqual(pair.end, "Dallas")
    }

    func testSameCityNeverRendersCityCity() {
        // The client-QA bug: an intra-Dallas drive must not show "Dallas → Dallas";
        // it degrades to street-only addresses instead.
        let pair = PlaceLabeler.pairLabels(
            start: Endpoint(specific: nil, locality: "Dallas"),
            end: Endpoint(specific: nil, locality: "Dallas"),
            fallbacks: ("3000 Knox Street, Dallas", "2520 Inwood Road, Dallas")
        )
        XCTAssertEqual(pair.start, "3000 Knox Street")
        XCTAssertEqual(pair.end, "2520 Inwood Road")
    }

    func testNeighborhoodBeatsCityIntraCity() {
        let pair = PlaceLabeler.pairLabels(
            start: Endpoint(specific: "Highland Park", locality: "Dallas"),
            end: Endpoint(specific: "Oak Lawn", locality: "Dallas"),
            fallbacks: ("3000 Knox Street, Dallas", "2520 Inwood Road, Dallas")
        )
        XCTAssertEqual(pair.start, "Highland Park")
        XCTAssertEqual(pair.end, "Oak Lawn")
    }

    func testMixedSpecificAndCityAcrossCities() {
        // One side resolves a POI, the other only a (different) city.
        let pair = PlaceLabeler.pairLabels(
            start: Endpoint(specific: "Klyde Warren Park", locality: "Dallas"),
            end: Endpoint(specific: nil, locality: "Frisco"),
            fallbacks: ("2012 Woodall Rodgers Freeway, Dallas", "4222 Stratus Way, Frisco")
        )
        XCTAssertEqual(pair.start, "Klyde Warren Park")
        XCTAssertEqual(pair.end, "Frisco")
    }

    func testUnknownCitiesKeepFullFallbackAddresses() {
        // Two failed geocodes (nil localities) are UNKNOWN, not "same city" —
        // the full trimmed addresses (street, city) are kept for context.
        let pair = PlaceLabeler.pairLabels(
            start: Endpoint(specific: nil, locality: nil),
            end: Endpoint(specific: nil, locality: nil),
            fallbacks: ("4222 Stratus Way, Frisco", "17817 Davenport Road, Dallas")
        )
        XCTAssertEqual(pair.start, "4222 Stratus Way, Frisco")
        XCTAssertEqual(pair.end, "17817 Davenport Road, Dallas")
    }

    func testOneKnownCityAgainstUnknownRendersCity() {
        // nil vs "Dallas" counts as differing — the known city still labels its side.
        let pair = PlaceLabeler.pairLabels(
            start: Endpoint(specific: nil, locality: nil),
            end: Endpoint(specific: nil, locality: "Dallas"),
            fallbacks: ("4222 Stratus Way, Frisco", "17817 Davenport Road, Dallas")
        )
        XCTAssertEqual(pair.start, "4222 Stratus Way, Frisco")
        XCTAssertEqual(pair.end, "Dallas")
    }

    // MARK: Street-only helper

    func testStreetOnlyTrimsAtFirstComma() {
        XCTAssertEqual(PlaceLabeler.streetOnly("4222 Stratus Way, Frisco"), "4222 Stratus Way")
        XCTAssertEqual(PlaceLabeler.streetOnly("Ferry Building"), "Ferry Building", "comma-less labels pass through")
    }

    // MARK: Geocode timeout degrade (no network)

    func testLabelsFallBackToAddressesWhenGeocodeTimesOut() async {
        // No saved match at either end; the ~1 ms timeout forces layer (d).
        let start = CLLocationCoordinate2D(latitude: 33.0861, longitude: -96.8518)
        let labels = await labeler().labels(
            start: start,
            end: dallas,
            fallbacks: ("4222 Stratus Way, Frisco", "17817 Davenport Road, Dallas"),
            driveID: "d2"
        )
        XCTAssertEqual(labels.start, "4222 Stratus Way, Frisco")
        XCTAssertEqual(labels.end, "17817 Davenport Road, Dallas")
    }

    func testEndpointFromNilPlacemarkIsEmpty() {
        XCTAssertEqual(PlaceLabeler.endpoint(from: nil), PlaceLabeler.ResolvedEndpoint(specific: nil, locality: nil))
    }
}
