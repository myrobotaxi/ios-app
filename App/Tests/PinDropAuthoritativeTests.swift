import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import Observation
import SwiftUI
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

    // MARK: MYR-213 — `name` must never leak a ZIP / bare number (the client bug)

    func testLadderRejectsPostalCodeAndBareNumberNames() {
        typealias F = LivePinLabeler.Fields
        // The exact client degradation: mid-block point, no street, name == ZIP.
        XCTAssertNil(LivePinLabeler.streetLabel(from: F(name: "75034", locality: "Frisco", postalCode: "75034")))
        // A lone house number with no street is not a pickup spot either.
        XCTAssertNil(LivePinLabeler.streetLabel(from: F(name: "4220", locality: "Frisco")))
        // ZIP+4 form.
        XCTAssertNil(LivePinLabeler.streetLabel(from: F(name: "75034-1234", locality: "Frisco", postalCode: "75034-1234")))
        // A real named place still passes.
        XCTAssertEqual(LivePinLabeler.streetLabel(from: F(name: "Stonebriar Centre", locality: "Frisco", postalCode: "75034")), "Stonebriar Centre")
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

// MARK: - MYR-213 round 3 — glyph screen point is the single source of truth

/// Round 3 deletes the round-2 assumed-fraction `PinDropProjection` (the model
/// the client evidence disproved) in favour of a live `MapProxy.convert` of the
/// glyph's real rendered point — which needs a laid-out map and so is validated
/// empirically in-simulator at the drift gate, not by a unit test. What CAN be
/// pinned in a unit test is the load-bearing invariant that survives: the glyph's
/// `.position` and the coordinate readout use the ONE `pinGlyphPoint` — so they
/// can never desync — and the street-level zoom choice.
final class PinDropGlyphPointTests: XCTestCase {

    func testGlyphPointIsHorizontallyCenteredAtTheRestingFraction() {
        let size = CGSize(width: 393, height: 852)
        let point = VehicleMapView.pinGlyphPoint(in: size)
        // Horizontally centered (x = the region-center longitude on screen).
        XCTAssertEqual(point.x, size.width / 2, accuracy: 1e-9)
        // Vertically at the tuned resting fraction — the SAME value the overlay
        // draws at and the proxy converts from (one source of truth).
        XCTAssertEqual(point.y, size.height * MRTMetrics.ridePinDropGlyphScreenFraction, accuracy: 1e-9)
    }

    func testGlyphPointScalesWithTheMapSize() {
        // Whatever full-bleed size the map reports, the point stays at the same
        // fraction — so glyph and coordinate track together across devices.
        let small = VehicleMapView.pinGlyphPoint(in: CGSize(width: 200, height: 400))
        let large = VehicleMapView.pinGlyphPoint(in: CGSize(width: 400, height: 800))
        XCTAssertEqual(large.x, small.x * 2, accuracy: 1e-9)
        XCTAssertEqual(large.y, small.y * 2, accuracy: 1e-9)
    }

    func testStreetLevelSpanIsTighterThanTheOverviewAndInRange() {
        // The pin-drop opens street-level (a few blocks), never the miles-wide
        // overview the client's round-2 capture showed.
        XCTAssertLessThan(MRTMetrics.pinDropStreetSpanDelta, MRTMetrics.mapRegionSpanDelta)
        // ~0.003–0.005° ≈ 330–550m viewport — the documented street-level band.
        XCTAssertGreaterThanOrEqual(MRTMetrics.pinDropStreetSpanDelta, 0.003)
        XCTAssertLessThanOrEqual(MRTMetrics.pinDropStreetSpanDelta, 0.005)
    }
}
