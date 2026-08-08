import CoreLocation
import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-472 — the ETA that never counted down, and the pickup that kept moving
//
// External beta, build 202608030843. Two testers, two cars, two rides, one
// signature: the headline froze at the booking estimate for the whole trip, and
// the pickup timestamp tracked the wall clock exactly, with drop-off always the
// same fixed interval after it.
//
// The two halves are asserted separately because they are different kinds of
// wrong. The remainder was a CONSTANT with nothing measuring it; the pickup
// clock was a FACT ABOUT THE PAST being recomputed from `now`.
final class RiderTrackingTruthTests: XCTestCase {

    /// ~1.6 km of straight road due east, as four vertices — enough to be REAL
    /// geometry (MYR-293's `count > 2`) and simple enough that every distance
    /// below is checkable by hand.
    private let route: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4200),
        CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4150),
        CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4100),
        CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4050),
    ]

    private var routeMiles: Double { RideRouteGeometry.lengthMiles(route) }

    // MARK: The measurement

    func testTheWholeRouteIsLeftWhenTheCarIsAtItsStart() throws {
        let meters = try XCTUnwrap(RideRouteGeometry.remainingMeters(from: route[0], along: route))
        XCTAssertEqual(meters, RideRouteGeometry.lengthMeters(route), accuracy: 1)
    }

    func testNothingIsLeftWhenTheCarIsAtTheDestination() throws {
        let meters = try XCTUnwrap(RideRouteGeometry.remainingMeters(from: route[3], along: route))
        XCTAssertEqual(meters, 0, accuracy: 1)
    }

    /// The car is projected ONTO the route rather than snapped to a vertex — a car
    /// half a segment past the last one must not report that whole segment as
    /// still ahead of it.
    func testTheCarIsProjectedOntoTheSegmentItIsHalfwayAlong() throws {
        // Halfway along the FIRST of three equal segments, so 2.5 of 3 remain.
        // Snapping to the nearest vertex would answer either 3/3 or 2/3, and the
        // difference is a whole city block of ETA.
        let midway = CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4175)
        let meters = try XCTUnwrap(RideRouteGeometry.remainingMeters(from: midway, along: route))
        XCTAssertEqual(meters, RideRouteGeometry.lengthMeters(route) * (2.5 / 3.0), accuracy: 5)
    }

    /// **THE DEFECT.** The remainder must SHRINK as the car moves. The pre-MYR-472
    /// derivation is `(1 - trackProgress) × <fixed duration>` and `trackProgress`
    /// never advances on the live path, so the number it produced was identical at
    /// every one of the tester's seven frames.
    func testTheRemainderShrinksAsTheCarMovesAlongTheRoute() throws {
        let start = try XCTUnwrap(RiderLegRemaining.measure(carPosition: route[0], route: route))
        let quarter = try XCTUnwrap(RiderLegRemaining.measure(carPosition: route[1], route: route))
        let half = try XCTUnwrap(RiderLegRemaining.measure(carPosition: route[2], route: route))
        let done = try XCTUnwrap(RiderLegRemaining.measure(carPosition: route[3], route: route))

        XCTAssertGreaterThan(start.miles, quarter.miles)
        XCTAssertGreaterThan(quarter.miles, half.miles)
        XCTAssertGreaterThan(half.miles, done.miles)
        XCTAssertEqual(done.miles, 0, accuracy: 0.01)
        XCTAssertEqual(done.minutes, 0, "a car at the door has no minutes left")

        XCTAssertGreaterThanOrEqual(start.minutes, quarter.minutes)
        XCTAssertGreaterThanOrEqual(quarter.minutes, half.minutes)
    }

    /// The distance is the ROAD's own length, so the straight-line detour factor
    /// must not be applied on top of it — that would inflate a measured road
    /// distance by 30%.
    func testTheMilesAreTheRoutesOwnLengthWithNoDetourInflation() throws {
        let start = try XCTUnwrap(RiderLegRemaining.measure(carPosition: route[0], route: route))
        XCTAssertEqual(start.miles, routeMiles, accuracy: 0.01)
        XCTAssertNotEqual(
            start.miles, routeMiles * TripEstimate.detourFactor, accuracy: 0.01,
            "detourFactor turns a straight line into a road; this already IS the road"
        )
        XCTAssertEqual(
            start.minutes,
            max(0, Int((routeMiles / TripEstimate.averageSpeedMph * 60).rounded())),
            "the app's one speed model, not a second estimator"
        )
    }

    // MARK: What is refused rather than guessed

    /// MYR-293's predicate, enforced on the input. The provider's straight
    /// `[from, to]` degradation is exactly the shape whose length was being passed
    /// off as a trip distance in MYR-414, and measuring it here would reintroduce
    /// that with a moving number instead of a frozen one.
    func testAStraightTwoPointFallbackIsNeverMeasured() {
        let fallback = [route[0], route[3]]
        XCTAssertNil(RiderLegRemaining.measure(carPosition: route[0], route: fallback))
    }

    func testNoFixMeansNoMeasurement() {
        XCTAssertNil(RiderLegRemaining.measure(carPosition: nil, route: route))
    }

    /// A projection is defined for ANY point, however far away, so without a bound
    /// a car on the far side of town reports a small remainder because that is
    /// where it happens to project.
    func testACarNowhereNearTheRouteIsNotMeasuredAgainstIt() {
        let elsewhere = CLLocationCoordinate2D(latitude: 37.9000, longitude: -122.4200)
        XCTAssertNil(RiderLegRemaining.measure(carPosition: elsewhere, route: route))

        // …but ordinary GPS error and a route drawn down the parallel street are
        // still measured, or the hero would blink out on a healthy ride.
        let slightlyOff = CLLocationCoordinate2D(latitude: 37.7802, longitude: -122.4150)
        XCTAssertNotNil(RiderLegRemaining.measure(carPosition: slightlyOff, route: route))
    }

    // MARK: The hero gate

    /// On the live path a number with nothing behind it is the whole of this
    /// issue, so an unmeasurable remainder renders no hero at all. MYR-449's live
    /// report is already on the same sheet saying why the car has gone quiet.
    func testTheHeroIsWithheldOnLiveWhenTheRemainderCannotBeMeasured() {
        let unmeasurable = RiderTrackingTruth(pickupAnchor: Date(), remaining: nil)
        XCTAssertFalse(RiderTrackingTruth.showsHero(unmeasurable, otherwise: true))

        let measured = RiderTrackingTruth(
            pickupAnchor: Date(),
            remaining: RiderLegRemaining(miles: 2.0, minutes: 5)
        )
        XCTAssertTrue(RiderTrackingTruth.showsHero(measured, otherwise: true))
        XCTAssertFalse(
            RiderTrackingTruth.showsHero(measured, otherwise: false),
            "a measurement does not overrule MYR-393's pre-motion withholding"
        )
    }

    /// The simulated path keeps its own answer, untouched — the `trackProgress`
    /// ticker is a real model of a car that really is moving, and every tracking
    /// capture depends on it.
    func testTheSimulatedPathKeepsItsOwnHeroDecision() {
        XCTAssertTrue(RiderTrackingTruth.showsHero(nil, otherwise: true))
        XCTAssertFalse(RiderTrackingTruth.showsHero(nil, otherwise: false))
    }

    // MARK: The pickup clock

    /// **THE SECOND DEFECT.** "Picked up 7:20 PM" is a claim about a boarding that
    /// happened once. Rendered from `now`, it read 7:10 / 7:16 / 7:17 / 7:20 across
    /// four submissions of one ride. Two readings ten minutes apart must produce
    /// the SAME string.
    func testTheAnchoredPickupClockDoesNotMoveWithTheWallClock() {
        let anchor = Date(timeIntervalSince1970: 1_775_000_000)
        let truth = RiderTrackingTruth(
            pickupAnchor: anchor,
            remaining: RiderLegRemaining(miles: 2.0, minutes: 5)
        )
        let early = RiderTrackingTruth.pickupClockText(
            truth, atPickup: true, minutesToPickup: 0, now: anchor.addingTimeInterval(60)
        )
        let late = RiderTrackingTruth.pickupClockText(
            truth, atPickup: true, minutesToPickup: 0, now: anchor.addingTimeInterval(600)
        )
        XCTAssertEqual(early, late)
        XCTAssertEqual(early, RideRequestClock.at(anchor))
    }

    /// MYR-414's honest gap, respected: a ride adopted mid-flight has no observed
    /// start, and stamping it with the moment the app launched would be the same
    /// fabrication in a quieter place.
    func testARideThisProcessDidNotSeeStartHasNoPickupTimeToShow() {
        let truth = RiderTrackingTruth(pickupAnchor: nil, remaining: nil)
        XCTAssertEqual(
            RiderTrackingTruth.pickupClockText(truth, atPickup: true, minutesToPickup: 0),
            RidePickupETADisplay.unknownClock
        )
    }

    /// Before pickup the row is a FORECAST, and a forecast moving with the clock is
    /// correct — the fix must not freeze the half that was never wrong.
    func testThePreviousPickupRowIsStillAForecastAndStillMoves() {
        let anchor = Date(timeIntervalSince1970: 1_775_000_000)
        let truth = RiderTrackingTruth(
            pickupAnchor: nil,
            remaining: RiderLegRemaining(miles: 2.0, minutes: 5)
        )
        let now = RiderTrackingTruth.pickupClockText(truth, atPickup: false, minutesToPickup: 5, now: anchor)
        XCTAssertEqual(now, RideRequestClock.at(anchor.addingTimeInterval(300)))

        let later = RiderTrackingTruth.pickupClockText(
            truth, atPickup: false, minutesToPickup: 5, now: anchor.addingTimeInterval(600)
        )
        XCTAssertNotEqual(now, later, "an ETA ten minutes later is a different time of day")
    }

    /// The simulated arm is byte-identical to the pre-MYR-472 rendering: past
    /// pickup with no live truth, the clock is the wall clock, exactly as
    /// `fromNow(0)` produced it.
    func testTheSimulatedPickupClockIsUnchanged() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        XCTAssertEqual(
            RiderTrackingTruth.pickupClockText(nil, atPickup: true, minutesToPickup: 0, now: now),
            RideRequestClock.at(now)
        )
    }
}
