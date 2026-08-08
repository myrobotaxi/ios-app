import CoreLocation
import DesignSystem
import MyRobotaxiContracts
import MyRoboTaxiKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-460 — the marker moves between fixes, and it tells the truth about it
//
// Two rules, tested as pure functions of two fixes and a clock:
//
//   1. Between two ~1Hz fixes the glyph GLIDES, over the interval actually
//      observed between them, so a rider sees a car driving instead of a car
//      teleporting once a second.
//   2. It is rendering ONLY. The raw fix stays the fact; Reduce Motion gets the
//      raw fix and nothing else; a stale gap does not become a long journey.

final class TrackingMarkerInterpolationTests: XCTestCase {

    private let a = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
    private let b = CLLocationCoordinate2D(latitude: 37.7920, longitude: -122.3999)

    // MARK: the tween

    func testTheMarkerIsPartWayBetweenTwoFixesPartWayThroughTheInterval() {
        let mid = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: 0.5, interval: 1.0, reduceMotion: false)
        XCTAssertEqual(mid.latitude, (a.latitude + b.latitude) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid.longitude, (a.longitude + b.longitude) / 2, accuracy: 1e-9)
    }

    func testTheTweenStartsAtTheOldFixAndEndsExactlyOnTheNewOne() {
        let start = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: 0, interval: 1.0, reduceMotion: false)
        XCTAssertEqual(start.latitude, a.latitude, accuracy: 1e-12)
        let end = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: 1.0, interval: 1.0, reduceMotion: false)
        XCTAssertEqual(end.latitude, b.latitude, accuracy: 1e-12)
        XCTAssertEqual(end.longitude, b.longitude, accuracy: 1e-12,
                       "the glyph must LAND on the fix — an interpolation that only approaches it drifts off the road")
    }

    func testItIsClampedPastTheIntervalAndNeverOvershoots() {
        // A fix that is late leaves the tween finished, not extrapolating forward
        // into a position the car has never reported.
        let late = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: 30, interval: 1.0, reduceMotion: false)
        XCTAssertEqual(late.latitude, b.latitude, accuracy: 1e-12)
        XCTAssertEqual(late.longitude, b.longitude, accuracy: 1e-12)
    }

    func testItIsMonotonicAcrossTheInterval() {
        var previous = -Double.infinity
        for step in 0...20 {
            let t = Double(step) / 20
            let c = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: t, interval: 1.0, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(c.latitude, previous, "the marker never moves backwards mid-tween")
            previous = c.latitude
        }
    }

    // MARK: honesty

    func testReduceMotionJumpsToTheRawFix() {
        let c = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: 0.01, interval: 1.0, reduceMotion: true)
        XCTAssertEqual(c.latitude, b.latitude, accuracy: 1e-12)
        XCTAssertEqual(c.longitude, b.longitude, accuracy: 1e-12,
                       "Reduce Motion is a request not to be shown movement, and the tween is movement we invented")
    }

    func testAStaleGapDoesNotBecomeALongJourney() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let after40s = previous.addingTimeInterval(40)
        let interval = TrackingMarkerInterpolation.interval(previousFixAt: previous, now: after40s)
        XCTAssertEqual(interval, TrackingMarkerInterpolation.maxInterval, accuracy: 1e-9,
                       "a car that went quiet for 40s must not spend 40s gliding to where it already is")
    }

    func testABurstOfFixesCannotProduceAZeroLengthTween() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let interval = TrackingMarkerInterpolation.interval(previousFixAt: previous, now: previous.addingTimeInterval(0.001))
        XCTAssertEqual(interval, TrackingMarkerInterpolation.minInterval, accuracy: 1e-9)
    }

    func testTheFirstFixOfASessionUsesTheDefaultInterval() {
        XCTAssertEqual(
            TrackingMarkerInterpolation.interval(previousFixAt: nil, now: Date()),
            TrackingMarkerInterpolation.defaultInterval, accuracy: 1e-9
        )
    }

    func testTheMeasuredIntervalIsUsedWhenItIsOrdinary() {
        let previous = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            TrackingMarkerInterpolation.interval(previousFixAt: previous, now: previous.addingTimeInterval(1.4)),
            // 1e-6, not 1e-9: `Date` round-tripping an interval loses a little
            // precision (measured 1.399999976 back out of 1.4), and this test is
            // about the gap being passed THROUGH rather than about float exactness.
            1.4, accuracy: 1e-6,
            "the tween lasts as long as the gap actually observed — a 1.4s gap is not padded to 1s or stretched to 3"
        )
    }

    // MARK: edges

    func testLongitudeTweensTheShortWayAcrossTheAntimeridian() {
        let west = CLLocationCoordinate2D(latitude: 0, longitude: 179.9)
        let east = CLLocationCoordinate2D(latitude: 0, longitude: -179.9)
        let mid = TrackingMarkerInterpolation.coordinate(from: west, to: east, elapsed: 0.5, interval: 1.0, reduceMotion: false)
        XCTAssertEqual(abs(mid.longitude), 180, accuracy: 1e-6,
                       "0.2° apart across the line is a 0.2° move, not a 359.8° flight round the planet")
    }

    func testADegenerateIntervalResolvesToTheNewFix() {
        let c = TrackingMarkerInterpolation.coordinate(from: a, to: b, elapsed: 0.5, interval: 0, reduceMotion: false)
        XCTAssertEqual(c.latitude, b.latitude, accuracy: 1e-12)
    }

    func testNonFiniteFixesResolveToTheTarget() {
        let bad = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        let c = TrackingMarkerInterpolation.coordinate(from: bad, to: b, elapsed: 0.5, interval: 1, reduceMotion: false)
        XCTAssertEqual(c.latitude, b.latitude, accuracy: 1e-12)
    }

    func testAnUnchangedFixIsRecognisedAsTheSamePlace() {
        XCTAssertTrue(TrackingMarkerInterpolation.isSamePlace(a, a))
        XCTAssertFalse(TrackingMarkerInterpolation.isSamePlace(a, b),
                       "a device re-reporting the same coordinate must not restart a tween that already arrived")
    }

    func testTheTickRateIsFastEnoughToReadAsMotion() {
        // Below ~15Hz a tween is visibly stepped, which is the teleport this
        // feature removes wearing a smaller step size.
        XCTAssertLessThanOrEqual(TrackingMarkerInterpolation.tickInterval, 1.0 / 15.0)
    }
}

// MARK: - MYR-460 — the driver, and the law it must not break

@MainActor
final class TrackingMarkerMotionDriverTests: XCTestCase {

    private let a = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
    private let b = CLLocationCoordinate2D(latitude: 37.7920, longitude: -122.3999)

    func testTheFirstFixIsPlacedRatherThanAnimatedIn() {
        let m = TrackingMarkerMotion()
        m.ingest(a)
        XCTAssertEqual(m.rendered?.latitude, a.latitude,
                       "there is no earlier position to come from; animating in would show the car arriving from nowhere")
    }

    func testLosingThePositionWithdrawsTheMarkerRatherThanLeavingItSomewhere() {
        let m = TrackingMarkerMotion()
        m.ingest(a)
        m.ingest(nil)
        XCTAssertNil(m.rendered, "MYR-393: the marker is the freshest position we hold, or it is not drawn")
    }

    func testReduceMotionRendersTheRawFixImmediately() throws {
        let m = TrackingMarkerMotion()
        m.reduceMotion = true
        let start = Date(timeIntervalSince1970: 1_000)
        m.ingest(a, now: start)
        m.ingest(b, now: start.addingTimeInterval(1))
        let rendered = try XCTUnwrap(m.rendered)
        XCTAssertEqual(rendered.latitude, b.latitude, accuracy: 1e-12,
                       "no tween at all — the honest jump, taken the moment the fix lands")
        XCTAssertEqual(rendered.longitude, b.longitude, accuracy: 1e-12)
    }

    func testATweenBeginsAtTheOldPositionRatherThanSnappingForward() throws {
        let m = TrackingMarkerMotion()
        let start = Date(timeIntervalSince1970: 1_000)
        m.ingest(a, now: start)
        m.ingest(b, now: start.addingTimeInterval(1))
        // Sampled synchronously, before the ticker has run: the glyph is still
        // where it was, and will be carried across rather than jumped.
        XCTAssertEqual(try XCTUnwrap(m.rendered).latitude, a.latitude, accuracy: 1e-12)
    }
}

// MARK: - MYR-460 — the heading finally reaches the map
//
// The tester's second sentence, as a data-flow test: `VehicleState.heading` has
// always been on the wire and folded by the merger, and it died at the rider's
// projection, which folds `activity` alone. These pin the hop that was missing
// and the gate it had to be given.

final class RiderVehicleProjectionHeadingTests: XCTestCase {

    private func state(lat: Double, lon: Double, heading: Int) -> VehicleState {
        var s = VehicleStateBaseline.forDeltaSeed(vehicleId: "veh_1")
        s.latitude = lat
        s.longitude = lon
        s.heading = heading
        return s
    }

    func testTheCarsOwnCompassBearingReachesTheProjection() {
        XCTAssertEqual(RiderVehicleProjection.heading(from: state(lat: 37.78, lon: -122.39, heading: 217)), 217)
    }

    func testEveryCompassBearingSurvivesVerbatim() {
        for degrees in stride(from: 0, through: 359, by: 17) {
            XCTAssertEqual(
                RiderVehicleProjection.heading(from: state(lat: 37.78, lon: -122.39, heading: degrees)),
                Double(degrees),
                "the projection must not round, clamp or re-origin the bearing — 0 is north and the car's word is final"
            )
        }
    }

    func testNoFixMeansNoHeading() {
        // §2.3's (0,0) sentinel means the car reported no position, and the
        // contract's gps group is atomic — so the `heading: 0` sitting in the
        // delta-seed baseline is "nothing reported", not "due north".
        XCTAssertNil(RiderVehicleProjection.heading(from: state(lat: 0, lon: 0, heading: 0)),
                     "a heading without a fix would render as a confident north on a car that has said nothing")
        XCTAssertNil(RiderVehicleProjection.heading(from: nil))
    }

    func testTheHeadingGateIsExactlyTheCoordinateGate() {
        // The glyph's position and its rotation must never come from different
        // evidence: whenever one is available so is the other.
        let cases = [
            state(lat: 0, lon: 0, heading: 90),
            state(lat: 37.78, lon: -122.39, heading: 90),
            state(lat: 0, lon: -122.39, heading: 90),
        ]
        for s in cases {
            XCTAssertEqual(
                RiderVehicleProjection.heading(from: s) == nil,
                RiderVehicleProjection.coordinate(from: s) == nil,
                "position and rotation are two halves of one claim about where the car is"
            )
        }
    }

    func testHeadingIsNotFoldedOntoTheCatalogRow() {
        // The projection's standing rule (MYR-336): telemetry may write POSITION
        // and STATUS onto the vehicle and nothing else. Heading is read straight
        // off the state by the map, and must not have quietly become a `Vehicle`
        // field on the way.
        let vehicle = VehicleFixtures.vehicles[0]
        let folded = RiderVehicleProjection.apply(state(lat: 37.78, lon: -122.39, heading: 217), to: vehicle)
        XCTAssertEqual(folded.name, vehicle.name)
        XCTAssertEqual(folded.vin, vehicle.vin)
        XCTAssertEqual(folded.plate, vehicle.plate)
    }
}

// MARK: - MYR-460 — a full turn never spins the wrong way
//
// `HeadingMathTests` pins the shortest-arc rule; this pins it over a real
// sequence of telemetry bearings, which is the shape the defect would take on
// screen: one wrong-way spin in a lap of the compass.

final class TrackingHeadingSweepTests: XCTestCase {

    func testDrivingAFullCircleNeverTurnsMoreThan180AtOnce() {
        var displayed: Double = 0
        // A car going round a roundabout and out the other side, crossing 0° twice.
        let bearings: [Double] = [10, 80, 170, 260, 350, 5, 95, 185, 275, 359, 2, 45]
        for bearing in bearings {
            let next = HeadingMath.unwrapped(from: displayed, to: bearing)
            XCTAssertLessThanOrEqual(abs(next - displayed), 180.0 + 1e-9,
                                     "a 359° → 2° change is a 3° turn; taking 357° the other way is the bug")
            displayed = next
        }
        // And the continuous angle still resolves to the final bearing.
        XCTAssertEqual(((displayed.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360), 45, accuracy: 1e-9)
    }
}
