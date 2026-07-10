import CoreLocation
@testable import MyRoboTaxi
import Observation
import XCTest

// MARK: - MYR-211 addendum — user-location pickup + region biasing (fake CL)
//
// Drives `SharedViewerState`'s location-dependent logic through a fake
// `UserLocationProviding` (authorized / denied / late-fix), with no real
// `CLLocationManager`. Asserts the created ride carries the provider's real
// coordinate, and that region biasing / pin-drop degrade to fixtures in sim.

/// Fake location backend — mutable so a test can flip authorization or deliver a
/// late fix and re-read the derived surfaces.
@Observable
@MainActor
private final class FakeUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var authorized: Bool
    var label: String

    init(coordinate: CLLocationCoordinate2D? = nil, authorized: Bool = true, label: String = "Current location") {
        self.coordinate = coordinate
        self.authorized = authorized
        self.label = label
    }

    private(set) var refreshCount = 0

    var currentLocationLabel: String { label }
    var showsUserLocationDot: Bool { authorized }
    func start() {}
    func stop() {}
    func refresh() { refreshCount += 1 }
}

@MainActor
final class RiderLocationTests: XCTestCase {

    private let dallas = CLLocationCoordinate2D(latitude: 33.0762, longitude: -96.8083)

    private func makeState(userLocation: any UserLocationProviding, isLive: Bool = true) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: userLocation,
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: isLive
        )
        return SharedViewerState(seams: seams)
    }

    // MARK: destination select routes through pin-drop (MYR-211 defect B)

    func testSelectDestinationRoutesThroughPinDropInLive() {
        // Live + authorized with a real fix: selecting a destination must NOT
        // bypass pin-drop (the merged-PR defect) — it lands on the pin-drop
        // phase, returning to Review, with no pickup pre-set.
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: true, label: "Main St"))
        state.selectDestination(RideRequestFixtures.recentPlaces[0])
        XCTAssertEqual(state.sheetPhase, .pinDrop(returnTo: .review))
        XCTAssertEqual(state.pinReturn, .review)
        XCTAssertNil(state.draftPickup) // pin-drop confirm sets it, not selection
        XCTAssertEqual(state.draftDestination?.id, RideRequestFixtures.recentPlaces[0].id)
    }

    func testSelectDestinationSkipsPinDropOnlyWhenPickupAlreadySet() {
        // The one shortcut that stays: a pickup already confirmed → straight to
        // Review (the rider set it via an earlier pin-drop).
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: true))
        state.draftPickup = RideRequestFixtures.savedPlaces[0]
        state.selectDestination(RideRequestFixtures.recentPlaces[0])
        XCTAssertEqual(state.sheetPhase, .review)
    }

    // MARK: region biasing priority (user → vehicle → fixture)

    func testRegionBiasesToUserLocationWhenAvailable() {
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: true))
        XCTAssertEqual(state.mapRegionCenter.latitude, dallas.latitude, accuracy: 0.0001)
    }

    func testRegionFallsBackToFixtureWhenNoLiveSources() {
        // Sim: no user fix, no live vehicle locator ⇒ the SF fixture region,
        // byte-identical to the pre-MYR-211 `centerOverride`.
        let state = makeState(userLocation: SimulatedUserLocation(), isLive: false)
        XCTAssertEqual(state.mapRegionCenter.latitude, DriveFixtures.home.latitude, accuracy: 0.0001)
    }

    // MARK: pin-drop coordinate/label degrade to fixtures in sim

    func testPinDropUsesFixturesInSim() {
        let state = makeState(userLocation: SimulatedUserLocation(), isLive: false)
        XCTAssertEqual(state.pinDropCoordinate.latitude, DriveFixtures.financialDistrict.latitude, accuracy: 0.0001)
        XCTAssertEqual(state.pinDropLabel, RideRequestFixtures.pinSpots[0])
    }

    func testPinDropUsesRealRegionInLive() {
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: true, label: "Elm St"))
        XCTAssertEqual(state.pinDropCoordinate.latitude, dallas.latitude, accuracy: 0.0001)
        XCTAssertEqual(state.pinDropLabel, "Elm St")
    }
}
