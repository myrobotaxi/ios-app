import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-216 — rider-flow polish round 4
//
// Four client-QA polish items, each with its load-bearing logic extracted as a
// pure function so it's unit-testable without mounting SwiftUI / hitting a real
// geocoder:
//   1. post-selection sheet collapse  (RideRequestSearchContent.proceedRegionHeight)
//   2. pin-drop back affordance        (SharedViewerState.returnFromPinDropToSearch)
//   3. pin-on-fix + label pipeline     (SharedViewerState.resolvedLabelSurvivesSettle,
//                                       LivePinLabeler.label(from:snappedLocation:pin:);
//                                       the MYR-216 pinOnFixCorrection was replaced by
//                                       PinDropCameraController in MYR-217 — see
//                                       PinDropCameraOwnershipTests)
//   4. route-preview sheet inset       (VehicleRoute.insetRegion / fittedRegion)

// MARK: deliverable 1 — post-selection collapse

final class SearchSheetCollapseTests: XCTestCase {
    // Once a destination is chosen the proceed region HUGS its content (nil) in
    // BOTH modes — the collapse. Locks in the both-modes-hug guarantee (the
    // regression would be re-pinning live to the stable typing envelope).
    func testProceedRegionHugsContentInBothModes() {
        XCTAssertNil(RideRequestSearchContent.proceedRegionHeight(isLive: true),
                     "live sheet collapses onto the CTA (no fixed height)")
        XCTAssertNil(RideRequestSearchContent.proceedRegionHeight(isLive: false),
                     "sim sheet collapses onto the CTA (unchanged from MYR-200 hug)")
    }

    // The typing envelope is untouched by the collapse (no per-keystroke jump).
    func testTypingEnvelopeStillStableInLive() {
        let header: CGFloat = 180
        let empty = RideRequestSearchContent.scrollRegionHeight(isLive: true, headerHeight: header, resultsHeight: 0)
        let full = RideRequestSearchContent.scrollRegionHeight(isLive: true, headerHeight: header, resultsHeight: 9999)
        XCTAssertEqual(empty, full, "typing height stays stable — collapse only applies once chosen")
    }
}

// MARK: deliverable 2 — pin-drop back vs. cancel

@MainActor
final class PinDropBackAffordanceTests: XCTestCase {
    private func makeState() -> SharedViewerState {
        let state = SharedViewerState() // simulated seams
        state.draftDestination = RideRequestFixtures.recentPlaces[0]
        state.sheetPhase = .pinDrop(returnTo: .review)
        return state
    }

    // Back → search, destination RETAINED (CTA state), no pickup confirmed.
    func testBackReturnsToSearchKeepingDestination() {
        let state = makeState()
        state.returnFromPinDropToSearch()
        XCTAssertEqual(state.sheetPhase, .search)
        XCTAssertEqual(state.draftDestination?.id, RideRequestFixtures.recentPlaces[0].id,
                       "destination is retained so search reopens in its CTA state")
        XCTAssertNil(state.draftPickup, "back does not confirm a pickup")
    }

    // Cancel (resetDraftToIdle) ABANDONS to idle, clearing the draft — genuinely
    // distinct from back (which stays in the flow on search).
    func testCancelAbandonsToIdleClearingDraft() {
        let state = makeState()
        state.resetDraftToIdle()
        XCTAssertEqual(state.sheetPhase, .idle)
        XCTAssertNil(state.draftDestination, "cancel clears the whole draft")
    }
}

// MARK: deliverable 3 — pin-on-fix entry correction
//
// MYR-217 REPLACED the MYR-216 in-place one-shot (`VehicleMapView
// .pinOnFixCorrection`, deleted) with the single camera owner: its
// `span: context.region.span` write was the four-round recurrence (a stale
// wide pre-entry settle hijacked it and re-asserted the wide span at entry).
// The fix-under-glyph seating behavior — including the (fix − glyph) delta
// shift these tests used to pin — now lives in `PinDropCameraController` and
// is covered, against the REAL entry interleaving, by
// `PinDropCameraOwnershipTests`.

// MARK: deliverable 3b — staleness guard

@MainActor
final class PinLabelStalenessGuardTests: XCTestCase {
    private let pin = CLLocationCoordinate2D(latitude: 33.086, longitude: -96.851)

    func testResolvedLabelSurvivesAShortSettle() {
        // ~33m away (< 40m) — the resolved street is still roughly valid, keep it.
        let near = CLLocationCoordinate2D(latitude: pin.latitude + 0.0003, longitude: pin.longitude)
        XCTAssertTrue(SharedViewerState.resolvedLabelSurvivesSettle(previousCoordinate: pin, newCenter: near))
    }

    func testResolvedLabelDropsBeyondTheStalenessRadius() {
        // ~55m away (> 40m) — resolved for somewhere else now, must drop to neutral.
        let far = CLLocationCoordinate2D(latitude: pin.latitude + 0.0005, longitude: pin.longitude)
        XCTAssertFalse(SharedViewerState.resolvedLabelSurvivesSettle(previousCoordinate: pin, newCenter: far))
    }

    func testNoPriorResolutionNeverSurvives() {
        XCTAssertFalse(SharedViewerState.resolvedLabelSurvivesSettle(previousCoordinate: nil, newCenter: pin))
    }
}

// MARK: deliverable 3c.2 — distance guard

@MainActor
final class PinLabelDistanceGuardTests: XCTestCase {
    typealias F = LivePinLabeler.Fields
    private let pin = CLLocationCoordinate2D(latitude: 33.0, longitude: -96.0)
    private func offset(_ metersLat: Double) -> CLLocationCoordinate2D {
        // ~111m per 0.001° latitude.
        CLLocationCoordinate2D(latitude: pin.latitude + metersLat / 111_000.0, longitude: pin.longitude)
    }

    // The exact client evidence: a house-numbered parcel snapped ~110m away on a
    // DIFFERENT road → never show that house address; degrade to neutral (nil).
    func testFarHouseNumberedParcelDegradesToNeutral() {
        let fields = F(subThoroughfare: "4555", thoroughfare: "Warwick Ln")
        let label = LivePinLabeler.label(from: fields, snappedLocation: offset(110), pin: pin)
        XCTAssertNil(label, "a far parcel's house number is never presented")
    }

    // A far STREET-level result (no house number) is likelier the road itself →
    // show the bare street name.
    func testFarStreetLevelResultShowsBareStreet() {
        let fields = F(thoroughfare: "Town and Country Blvd")
        let label = LivePinLabeler.label(from: fields, snappedLocation: offset(110), pin: pin)
        XCTAssertEqual(label, "Town and Country Blvd")
    }

    // Near results run the full street-first ladder (house number included).
    func testNearResultRunsFullLadder() {
        let fields = F(subThoroughfare: "1200", thoroughfare: "Grandscape Blvd")
        let label = LivePinLabeler.label(from: fields, snappedLocation: offset(5), pin: pin)
        XCTAssertEqual(label, "1200 Grandscape Blvd")
    }

    // No snapped location to judge → trust the ladder (never blocks a good label).
    func testNoSnappedLocationRunsLadder() {
        let fields = F(subThoroughfare: "1200", thoroughfare: "Grandscape Blvd")
        let label = LivePinLabeler.label(from: fields, snappedLocation: nil, pin: pin)
        XCTAssertEqual(label, "1200 Grandscape Blvd")
    }

    // Far, and no street at all (only a POI/name) → neutral (nil).
    func testFarWithNoStreetIsNeutral() {
        let fields = F(name: "Stonebriar Centre")
        let label = LivePinLabeler.label(from: fields, snappedLocation: offset(110), pin: pin)
        XCTAssertNil(label)
    }
}

// MARK: deliverable 4 — route-preview sheet inset

final class RouteMapInsetTests: XCTestCase {
    // Frisco-ish pickup → destination pair.
    private let route = [
        CLLocationCoordinate2D(latitude: 33.00, longitude: -96.00),
        CLLocationCoordinate2D(latitude: 33.05, longitude: -96.05),
    ]

    func testInsetShiftsCenterSouthAndGrowsSpan() {
        let plain = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7)
        let inset = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7, bottomInset: 400, viewHeight: 800)
        XCTAssertLessThan(inset.center.latitude, plain.center.latitude, "center shifts south to lift the route above the sheet")
        XCTAssertGreaterThan(inset.span.latitudeDelta, plain.span.latitudeDelta, "latitude span grows to make room for the covered strip")
        XCTAssertGreaterThan(inset.span.longitudeDelta, plain.span.longitudeDelta, "longitude grows proportionally (never clips an endpoint)")
    }

    func testBothEndpointsClearTheSheet() {
        let bottomInset: CGFloat = 400, viewHeight: CGFloat = 800
        let region = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7, bottomInset: bottomInset, viewHeight: viewHeight)
        let viewBottomLat = region.center.latitude - region.span.latitudeDelta / 2
        let viewTopLat = region.center.latitude + region.span.latitudeDelta / 2
        // The sheet covers the bottom `bottomInset/viewHeight` fraction — its top
        // edge in latitude terms:
        let sheetTopLat = viewBottomLat + (Double(bottomInset) / Double(viewHeight)) * region.span.latitudeDelta

        let southEndpoint = 33.00, northEndpoint = 33.05
        XCTAssertGreaterThan(southEndpoint, sheetTopLat, "the near (south) endpoint sits ABOVE the sheet's top edge")
        XCTAssertLessThan(northEndpoint, viewTopLat, "the far (north) endpoint is within the visible top")
        XCTAssertGreaterThan(southEndpoint, viewBottomLat)
    }

    func testZeroInsetIsUnchanged() {
        let plain = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7)
        let zero = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7, bottomInset: 0, viewHeight: 800)
        XCTAssertEqual(plain.center.latitude, zero.center.latitude, accuracy: 1e-12)
        XCTAssertEqual(plain.span.latitudeDelta, zero.span.latitudeDelta, accuracy: 1e-12)
    }

    func testDegenerateInsetLargerThanViewIsNoOp() {
        let plain = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7)
        let bad = VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7, bottomInset: 900, viewHeight: 800)
        XCTAssertEqual(plain.center.latitude, bad.center.latitude, accuracy: 1e-12, "inset ≥ view height is ignored")
    }
}
