import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-217 deliverable 2 — pickup-point labeling, industry-style
//
// The label ladder (see `PickupPointLabeler.swift`'s research record): a named
// POI at the pin's doorstep > the guarded reverse-geocode street/address >
// "Near {POI}" for the label-unknown case > neutral. FREE-PIN decision: the
// ladder only ever returns a STRING — labeling can never move the pickup
// coordinate (the wire coordinate stays exactly the glyph's MapProxy ground
// truth, `SharedViewerState.pinDropCoordinate`).

@MainActor
final class PickupPointLabelTests: XCTestCase {

    private let pin = CLLocationCoordinate2D(latitude: 33.086114, longitude: -96.851844)

    /// A POI offset ~`meters` north of the pin (111km per degree latitude).
    private func poi(_ name: String, metersAway: Double) -> PickupPOI {
        PickupPOI(name: name, coordinate: CLLocationCoordinate2D(
            latitude: pin.latitude + metersAway / 111_000.0,
            longitude: pin.longitude
        ))
    }

    // MARK: rung 1 — a doorstep POI outranks the parcel address

    func testDoorstepPOIBeatsGeocodeAddress() {
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin,
            pois: [poi("Starbucks", metersAway: 12)],
            geocodeLabel: "4555 Warwick Ln"
        )
        XCTAssertEqual(label, "Starbucks",
                       "a named place at the pin beats a (possibly parcel-snapped) address")
    }

    func testNearestOfSeveralPOIsWins() {
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin,
            pois: [poi("Whole Foods", metersAway: 25), poi("Starbucks", metersAway: 8)],
            geocodeLabel: nil
        )
        XCTAssertEqual(label, "Starbucks")
    }

    // MARK: rung 2 — beyond the doorstep radius the guarded geocode wins

    func testGeocodeWinsOverAPOIAcrossTheStreet() {
        // 45m: a storefront across the street must not claim the pin.
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin,
            pois: [poi("Starbucks", metersAway: 45)],
            geocodeLabel: "1200 Grandscape Blvd"
        )
        XCTAssertEqual(label, "1200 Grandscape Blvd")
    }

    func testGeocodeAloneLabels() {
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin, pois: [], geocodeLabel: "Town and Country Blvd")
        XCTAssertEqual(label, "Town and Country Blvd")
    }

    // MARK: rung 3 — label-unknown with a nearby named place → "Near X"
    //
    // The client's suburb mid-block case: the geocode ladder (rightly) refuses
    // ZIP/city/far-parcel labels, and pre-MYR-217 the pin fell to the bare
    // neutral. A recognizably-close named place is more honest and more useful.

    func testNearSemanticsWhenGeocodeHasNothingPrecise() {
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin,
            pois: [poi("Grandscape", metersAway: 60)],
            geocodeLabel: nil
        )
        XCTAssertEqual(label, "Near Grandscape")
    }

    func testNearSemanticsNeverClaimsTheDoorstepName() {
        // 60m is "Near Grandscape", NEVER bare "Grandscape" — the pin is not
        // at the place, and the label must not imply it is.
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin, pois: [poi("Grandscape", metersAway: 60)], geocodeLabel: nil)
        XCTAssertNotEqual(label, "Grandscape")
    }

    // MARK: rung 4 — neutral

    func testFarPOIOnlyIsNeutral() {
        // 90m: beyond the "near" radius — the neutral label is the honest one.
        let label = LivePickupPointLabeler.bestLabel(
            pin: pin, pois: [poi("Stonebriar Centre", metersAway: 90)], geocodeLabel: nil)
        XCTAssertNil(label, "nothing close and nothing precise → caller shows the neutral")
    }

    func testNothingAtAllIsNeutral() {
        XCTAssertNil(LivePickupPointLabeler.bestLabel(pin: pin, pois: [], geocodeLabel: nil))
    }

    // MARK: threshold sanity — tuned against the geocode far-parcel guard

    func testThresholdOrdering() {
        // doorstep < far-parcel guard (50m, `LivePinLabeler.label`) < near —
        // so a doorstep POI outranks parcel addresses, a guarded address
        // outranks across-the-street POIs, and "Near X" only fills the gap.
        XCTAssertLessThan(LivePickupPointLabeler.poiAtMeters, 50)
        XCTAssertGreaterThan(LivePickupPointLabeler.poiNearMeters, 50)
        XCTAssertLessThanOrEqual(LivePickupPointLabeler.poiNearMeters,
                                 Double(LivePickupPointLabeler.poiQueryRadiusMeters),
                                 "the query radius must cover the near radius")
    }

    // MARK: the composed labeler (async seams, no MapKit)

    func testComposedLabelerRunsTheLadder() async {
        let labeler = LivePickupPointLabeler(
            pois: { center, _ in
                [PickupPOI(name: "Starbucks", coordinate: center)] // at the pin
            },
            geocode: LivePinLabeler(resolve: { _ in
                LivePinLabeler.GeocodeResult(
                    fields: .init(subThoroughfare: "4555", thoroughfare: "Warwick Ln"),
                    snappedLocation: nil)
            })
        )
        let label = await labeler.label(for: pin)
        XCTAssertEqual(label, "Starbucks")
    }

    func testComposedLabelerFallsToGeocodeWhenNoPOIs() async {
        let labeler = LivePickupPointLabeler(
            pois: { _, _ in [] },
            geocode: LivePinLabeler(resolve: { _ in
                LivePinLabeler.GeocodeResult(
                    fields: .init(thoroughfare: "Town and Country Blvd"),
                    snappedLocation: nil)
            })
        )
        let label = await labeler.label(for: pin)
        XCTAssertEqual(label, "Town and Country Blvd")
    }
}
