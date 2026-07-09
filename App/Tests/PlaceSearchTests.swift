import CoreLocation
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-211 — place-search seam + RidePlace mapping (no network)
//
// Covers the pure/simulated surfaces: the `SimulatedPlaceSearch` filter stays
// byte-identical to the pre-MYR-211 inline predicate, and `RidePlaceMapper`'s
// category→icon table, straight-line distance, and saved-first ordering. The
// live `MKLocalSearchCompleter`/`MKLocalSearch` path needs MapKit's network
// backend, so it's verified by the orchestrator's live pass, not here.
@MainActor
final class PlaceSearchTests: XCTestCase {

    private let center = DriveFixtures.home

    // MARK: SimulatedPlaceSearch (byte-identical fixture filter)

    func testSimulatedFilterMatchesFixtureSubstring() {
        let search = SimulatedPlaceSearch()
        search.update(query: "fer", regionCenter: center) // the `searchFiltered` scene query
        XCTAssertEqual(search.results?.map(\.id), ["ferry"])
    }

    func testSimulatedEmptyQueryClearsToDefaultSections() {
        let search = SimulatedPlaceSearch()
        search.update(query: "fer", regionCenter: center)
        search.update(query: "", regionCenter: center)
        XCTAssertNil(search.results) // nil ⇒ show Saved/Recent/Nearby
    }

    func testSimulatedNoMatchIsEmptyResults() {
        // The documented client bug: "Shops" filters the SF fixtures to nothing.
        // Sim keeps this byte-identical (LivePlaceSearch is the real-world fix).
        let search = SimulatedPlaceSearch()
        search.update(query: "Shops", regionCenter: center)
        XCTAssertEqual(search.results, []) // [] ⇒ "No results"
    }

    // MARK: RidePlaceMapper — category → icon

    func testIconTableMapsKnownCategories() {
        XCTAssertEqual(RidePlaceMapper.icon(for: .airport), "airplane")
        XCTAssertEqual(RidePlaceMapper.icon(for: .cafe), "cup.and.saucer.fill")
        XCTAssertEqual(RidePlaceMapper.icon(for: .restaurant), "fork.knife")
        XCTAssertEqual(RidePlaceMapper.icon(for: .park), "leaf.fill")
        XCTAssertEqual(RidePlaceMapper.icon(for: .fitnessCenter), "figure.run")
    }

    func testIconFallsBackToMappin() {
        XCTAssertEqual(RidePlaceMapper.icon(for: nil), "mappin")
        XCTAssertEqual(RidePlaceMapper.icon(for: .foodMarket), "fork.knife")
        // A category with no bespoke glyph takes the generic pin.
        XCTAssertEqual(RidePlaceMapper.icon(for: .postOffice), "mappin")
    }

    // MARK: RidePlaceMapper — distance

    func testStraightLineMilesZeroForSamePoint() {
        XCTAssertEqual(RidePlaceMapper.straightLineMiles(from: center, to: center), 0, accuracy: 0.0001)
    }

    func testStraightLineMilesOneDegreeLatitude() {
        // 1° of latitude ≈ 69.05 miles anywhere on Earth.
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 1, longitude: 0)
        XCTAssertEqual(RidePlaceMapper.straightLineMiles(from: a, to: b), 69.05, accuracy: 0.5)
    }

    // MARK: RidePlaceMapper — MKMapItem → RidePlace

    func testRidePlaceCarriesCoordinateSubtitleAndMiles() {
        let dest = CLLocationCoordinate2D(latitude: center.latitude + 1, longitude: center.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        let place = RidePlaceMapper.ridePlace(from: item, title: "Blue Bottle", subtitle: "66 Mint St", regionCenter: center)

        XCTAssertEqual(place.label, "Blue Bottle")
        XCTAssertEqual(place.subtitle, "66 Mint St")
        XCTAssertEqual(place.coordinate.latitude, dest.latitude, accuracy: 0.0001)
        XCTAssertEqual(place.minutes, 0) // v1: no per-result routing; row hides "0 min"
        XCTAssertEqual(place.miles, 69.05, accuracy: 0.5)
    }

    func testRidePlaceEmptySubtitleBecomesNil() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: center))
        let place = RidePlaceMapper.ridePlace(from: item, title: "Somewhere", subtitle: "", regionCenter: center)
        XCTAssertNil(place.subtitle)
    }

    // MARK: RidePlaceMapper — saved places rank first

    func testMatchingSavedPlacesFiltersSavedNotRecent() {
        let matches = RidePlaceMapper.matchingSavedPlaces(query: "equinox")
        XCTAssertEqual(matches.map(\.id), ["gym"]) // from savedPlaces, not recentPlaces
    }

    func testMatchingSavedPlacesEmptyForNoMatchOrEmptyQuery() {
        XCTAssertTrue(RidePlaceMapper.matchingSavedPlaces(query: "").isEmpty)
        XCTAssertTrue(RidePlaceMapper.matchingSavedPlaces(query: "zzzznowhere").isEmpty)
    }
}
