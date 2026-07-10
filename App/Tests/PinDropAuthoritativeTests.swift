import CoreLocation
import MapKit
@testable import MyRoboTaxi
import Observation
import XCTest

// MARK: - MYR-212 defects 1 & 2 — authoritative pin (map-center follow, label)

/// Fake location backend that records `refresh()` calls (defect 2).
@Observable
@MainActor
private final class FakeUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var label: String
    private(set) var refreshCount = 0

    init(coordinate: CLLocationCoordinate2D? = nil, label: String = "Current location") {
        self.coordinate = coordinate
        self.label = label
    }

    var currentLocationLabel: String { label }
    var showsUserLocationDot: Bool { true }
    func start() {}
    func stop() {}
    func refresh() { refreshCount += 1 }
}

/// Fake reverse geocoder — returns a canned street label for any coordinate.
@MainActor
private final class FakePinLabeler: RidePinLabeling {
    var stub: String?
    init(stub: String?) { self.stub = stub }
    func label(for coordinate: CLLocationCoordinate2D) async -> String? { stub }
}

@MainActor
final class PinDropAuthoritativeTests: XCTestCase {

    private let deviceFix = CLLocationCoordinate2D(latitude: 33.0762, longitude: -96.8083)
    private let dragged = CLLocationCoordinate2D(latitude: 33.0901, longitude: -96.8514)

    private func makeState(
        userLocation: any UserLocationProviding,
        pinLabeler: any RidePinLabeling,
        isLive: Bool = true
    ) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: userLocation,
            liveVehicleLocator: nil,
            pinLabeler: pinLabeler,
            isLive: isLive
        )
        return SharedViewerState(seams: seams)
    }

    // MARK: defect 1 — the dragged map center IS the confirmed pickup

    func testDraggedCenterBecomesTheConfirmedPickupCoordinate() async {
        let state = makeState(
            userLocation: FakeUserLocation(coordinate: deviceFix),
            pinLabeler: FakePinLabeler(stub: "1200 Grandscape Blvd")
        )
        // Before any drag: the pin opens on the freshest region (device fix).
        XCTAssertEqual(state.pinDropCoordinate.latitude, deviceFix.latitude, accuracy: 0.0001)

        // The rider drags the map; it settles somewhere else.
        state.pinDropCameraSettled(at: dragged)
        XCTAssertEqual(state.pinDropCoordinate.latitude, dragged.latitude, accuracy: 0.0001)
        XCTAssertEqual(state.pinDropCoordinate.longitude, dragged.longitude, accuracy: 0.0001)

        // The debounced reverse-geocode upgrades the label to a street address.
        await eventually { state.pinDropLabel == "1200 Grandscape Blvd" }
    }

    func testConfirmedPinFlowsIntoTheDraftPickupAndTripEstimate() async {
        let state = makeState(
            userLocation: FakeUserLocation(coordinate: deviceFix),
            pinLabeler: FakePinLabeler(stub: "1200 Grandscape Blvd")
        )
        // A live destination with no estimate yet (minutes == 0).
        let destination = RidePlace(id: "live|bell", label: "Bell Southstone Yards", subtitle: nil,
                                    miles: 0, minutes: 0, icon: "mappin",
                                    coordinate: CLLocationCoordinate2D(latitude: 33.15, longitude: -96.82))
        state.draftDestination = destination
        state.pinDropCameraSettled(at: dragged)
        await eventually { state.pinDropLabel == "1200 Grandscape Blvd" }

        // Emulate PinDropContent.confirm(): the confirmed pin is the draft pickup.
        state.draftPickup = RidePlace(id: "pin", label: state.pinDropLabel, subtitle: nil,
                                      miles: 0, minutes: 0, icon: "mappin.circle.fill",
                                      coordinate: state.pinDropCoordinate)
        state.enterReview()

        let pickup = try! XCTUnwrap(state.draftPickup)
        XCTAssertEqual(pickup.coordinate.latitude, dragged.latitude, accuracy: 0.0001)
        XCTAssertEqual(pickup.label, "1200 Grandscape Blvd")
        // The estimate was computed once from the dragged pickup → live dest.
        XCTAssertGreaterThan(state.draftDestination?.minutes ?? 0, 0)
        XCTAssertGreaterThan(state.draftDestination?.miles ?? 0, 0)
        XCTAssertEqual(state.sheetPhase, .review)
    }

    // MARK: defect 2 — pin-drop entry forces a fresh fix + re-seeds

    func testEnterPinDropRequestsAFreshFixAndClearsPriorSettle() {
        let location = FakeUserLocation(coordinate: deviceFix)
        let state = makeState(userLocation: location, pinLabeler: FakePinLabeler(stub: nil))
        state.pinDropCameraSettled(at: dragged) // a stale settle from a prior visit
        state.enterPinDrop()
        XCTAssertEqual(location.refreshCount, 1, "a fresh device fix is requested on entry")
        // Prior settle cleared → pin re-seeds from the region center (device fix).
        XCTAssertEqual(state.pinDropCoordinate.latitude, deviceFix.latitude, accuracy: 0.0001)
    }

    // MARK: sim stays byte-identical

    func testSimIgnoresCameraSettleAndKeepsFixtures() {
        let state = makeState(userLocation: SimulatedUserLocation(),
                              pinLabeler: SimulatedPinLabeler(), isLive: false)
        state.pinDropCameraSettled(at: dragged)
        XCTAssertEqual(state.pinDropCoordinate.latitude, DriveFixtures.financialDistrict.latitude, accuracy: 0.0001)
        XCTAssertEqual(state.pinDropLabel, RideRequestFixtures.pinSpots[0])
    }

    // MARK: street-first label ladder (defect 1 — never a bare city)

    func testLadderPrefersStreetAddressThenNeverBareCity() {
        typealias F = LivePinLabeler.Fields
        XCTAssertEqual(LivePinLabeler.streetLabel(from: F(subThoroughfare: "1200", thoroughfare: "Grandscape Blvd",
                                                          locality: "Frisco")), "1200 Grandscape Blvd")
        XCTAssertEqual(LivePinLabeler.streetLabel(from: F(thoroughfare: "Grandscape Blvd", locality: "Frisco")), "Grandscape Blvd")
        XCTAssertEqual(LivePinLabeler.streetLabel(from: F(areasOfInterest: ["Grandscape"], locality: "Frisco")), "Grandscape")
        XCTAssertEqual(LivePinLabeler.streetLabel(from: F(subLocality: "Rincon Hill", locality: "Frisco")), "Rincon Hill")
        // Only a city is known → nil (the caller keeps "Current location").
        XCTAssertNil(LivePinLabeler.streetLabel(from: F(name: "Frisco", locality: "Frisco")))
        XCTAssertNil(LivePinLabeler.streetLabel(from: F(locality: "Frisco")))
    }

    // MARK: -

    private func eventually(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true")
    }
}

// MARK: - MYR-212 round 2 — pin coordinate is exactly under the glyph

/// Unit-tests the pure projection that maps the map's reported region onto the
/// coordinate under the fixed pin GLYPH (screen fraction 0.36), instead of the
/// region center (0.5) that sits under the sheet. The full-bleed / center-at-0.5
/// model is validated visually at the drift gate (there is no headless MKMapView
/// to settle a real region — the documented UI-level assertion gap); this covers
/// the load-bearing math: direction + magnitude.
final class PinDropProjectionTests: XCTestCase {

    private let center = CLLocationCoordinate2D(latitude: 33.10, longitude: -96.80)

    func testGlyphAboveCenterShiftsCoordinateNorthByTheSpanFraction() {
        let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        let coord = PinDropProjection.coordinate(regionCenter: center, span: span, pinScreenFraction: 0.36)

        // Glyph at 0.36 is above center (0.5) → 0.14 of the span north.
        XCTAssertEqual(coord.latitude, center.latitude + 0.14 * 0.02, accuracy: 1e-9)
        // Horizontally centered → longitude is unchanged.
        XCTAssertEqual(coord.longitude, center.longitude, accuracy: 1e-12)
        // Sanity: at a ~0.02° span this is ~150m north — the very error round 1 left.
        XCTAssertGreaterThan(coord.latitude, center.latitude)
    }

    func testGlyphAtCenterIsANoOp() {
        let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        let coord = PinDropProjection.coordinate(regionCenter: center, span: span, pinScreenFraction: 0.5)
        XCTAssertEqual(coord.latitude, center.latitude, accuracy: 1e-12)
        XCTAssertEqual(coord.longitude, center.longitude, accuracy: 1e-12)
    }

    func testOffsetScalesLinearlyWithZoom() {
        let tight = PinDropProjection.coordinate(regionCenter: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01), pinScreenFraction: 0.36)
        let wide = PinDropProjection.coordinate(regionCenter: center, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02), pinScreenFraction: 0.36)
        let tightOffset = tight.latitude - center.latitude
        let wideOffset = wide.latitude - center.latitude
        // Double the span → double the coordinate offset for the same glyph.
        XCTAssertEqual(wideOffset, tightOffset * 2, accuracy: 1e-9)
    }
}
