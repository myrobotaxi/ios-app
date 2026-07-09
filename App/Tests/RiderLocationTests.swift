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

    var currentPickupCoordinate: CLLocationCoordinate2D? { authorized ? coordinate : nil }
    var currentLocationLabel: String { label }
    var showsUserLocationDot: Bool { authorized }
    func start() {}
    func stop() {}
}

@MainActor
final class RiderLocationTests: XCTestCase {

    private let dallas = CLLocationCoordinate2D(latitude: 33.0762, longitude: -96.8083)

    private func makeState(userLocation: any UserLocationProviding, isLive: Bool = true) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: userLocation,
            liveVehicleLocator: nil,
            isLive: isLive
        )
        return SharedViewerState(seams: seams)
    }

    // MARK: currentLocationPickup availability

    func testAuthorizedWithFixOffersCurrentLocationPickup() {
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: true, label: "Main St"))
        let pickup = state.currentLocationPickup()
        XCTAssertEqual(pickup?.id, SharedViewerState.currentLocationPickupID)
        XCTAssertEqual(pickup?.label, "Main St")
        XCTAssertEqual(pickup?.coordinate.latitude ?? 0, dallas.latitude, accuracy: 0.0001)
    }

    func testDeniedOffersNoCurrentLocationPickup() {
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: false))
        XCTAssertNil(state.currentLocationPickup()) // ⇒ caller routes to Set-on-map
    }

    func testLateFixTransitionsFromNoPickupToPickup() {
        let fake = FakeUserLocation(coordinate: nil, authorized: true) // authorized, no fix yet
        let state = makeState(userLocation: fake)
        XCTAssertNil(state.currentLocationPickup())
        fake.coordinate = dallas // fix arrives
        XCTAssertEqual(state.currentLocationPickup()?.coordinate.latitude ?? 0, dallas.latitude, accuracy: 0.0001)
    }

    // MARK: pickup resolves to the provider coordinate at request time

    func testResolvedPickupCarriesFreshProviderCoordinate() {
        let fake = FakeUserLocation(coordinate: dallas, authorized: true, label: "5th & Main")
        let state = makeState(userLocation: fake)
        // A sentinel pickup captured earlier with a stale coordinate…
        let stale = RidePlace(
            id: SharedViewerState.currentLocationPickupID,
            label: "Current location", subtitle: nil, miles: 0, minutes: 0,
            icon: "location.fill", coordinate: DriveFixtures.financialDistrict
        )
        // …re-resolves to the freshest device fix (the created ride's pickup).
        let moved = CLLocationCoordinate2D(latitude: 33.10, longitude: -96.80)
        fake.coordinate = moved
        let resolved = state.resolvedPickup(stale)
        XCTAssertEqual(resolved.coordinate.latitude, moved.latitude, accuracy: 0.0001)
        XCTAssertEqual(resolved.coordinate.longitude, moved.longitude, accuracy: 0.0001)
        XCTAssertEqual(resolved.label, "5th & Main")
    }

    func testResolvedPickupPassesThroughNonSentinelUnchanged() {
        let state = makeState(userLocation: FakeUserLocation(coordinate: dallas, authorized: true))
        let saved = RideRequestFixtures.savedPlaces[0] // "Home", a real saved place
        let resolved = state.resolvedPickup(saved)
        XCTAssertEqual(resolved, saved) // untouched — not a current-location sentinel
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
