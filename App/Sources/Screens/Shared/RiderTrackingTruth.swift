import CoreLocation
import Foundation

// MARK: - RiderTrackingTruth (MYR-472) — the ETA is measured, and the past is fixed
//
// External beta, build 202608030843. Two testers, two cars, two rides, one
// signature. James, riding to Too Thai, across four submissions:
//
//     7:10 PM   10 min · 4.1 mi away   Pickup 7:10 PM · Picked up   Drop-off 7:20 PM
//     7:16 PM   10 min · 4.1 mi away   Pickup 7:16 PM · Picked up   Drop-off 7:26 PM
//     7:17 PM   10 min · 4.1 mi away   Pickup 7:17 PM · Picked up   Drop-off 7:27 PM
//     7:20 PM   10 min · 4.1 mi away   Pickup 7:20 PM · Picked up   Drop-off 7:30 PM
//
// Aarthi's ride to Aritzia reproduces it at a different constant (14 min /
// 5.7 mi) across three more frames, and her arrival summary is stamped
// **ARRIVED — 7:58 PM** while the 7:57 frame promised fourteen more minutes.
// *"why does it say 14min when we're at destination"*.
//
// TWO DEFECTS, AND THEY ARE DIFFERENT KINDS OF WRONG.
//
// **1 · THE NUMBER NEVER MOVES, BECAUSE NOTHING BEHIND IT IS MEASURED.** The
// tracking sheet's remaining time and distance are `(1 - trackProgress) ×` a
// duration fixed at booking. `trackProgress` is the SIMULATED ticker: on the live
// path `LiveRideRequestService` seeds it once (`enrouteSeedProgress`) and nothing
// ever advances it, because v1 live has no progress stream. So the whole
// expression collapses to a constant — `destination.minutes`, the `TripEstimate`
// closed form computed from the straight-line distance before the car moved — and
// it is re-rendered, unchanged, for the entire ride. The ride slides along in
// front of the ETA instead of consuming it.
//
// **2 · "PICKED UP 7:20 PM" IS A CLAIM ABOUT THE PAST, AND IT WAS BEING
// REWRITTEN.** `pickupClock` is `RideRequestClock.fromNow(minutes: 0)` once the
// ride is past pickup — i.e. literally the wall clock at render time, every
// frame, for a boarding that happened once and is over. The drop-off clock is
// then `now + <the constant>`, which is why the two move together in lockstep and
// why the interval between them never shrinks. **Nothing here was stale; it was
// being freshly recomputed with `now` substituted for the trip's origin**, which
// is also why no freshness gate (MYR-401 / MYR-409) would ever have caught it —
// the value is brand new on every tick.
//
// THE TWO FIXES THE ISSUE ASKS FOR, AND WHERE EACH ONE LANDS.
//
//  1. **ANCHOR THE ORIGIN ONCE.** The trip's start already exists and is already
//     stamped exactly once, on the observed transition into `enroute`, with a
//     no-restamp rule and a revert path: MYR-414's `RideTripSpan.observing` →
//     `RideRequestRecord.enrouteObservedAt`. It is the anchor, verbatim. Nothing
//     new is stamped and no second definition of "when the ride started" is
//     introduced — the summary's trip tile and the itinerary's pickup row are now
//     two readings of ONE instant, so they can never disagree about a ride.
//     **A ride adopted mid-flight genuinely has no anchor** (MYR-396 / MYR-402's
//     cold-launch and foreground re-reads arrive already `enroute`), and that case
//     renders the calm unknown dash rather than the moment the app launched —
//     MYR-414's honest gap, respected rather than papered over.
//  2. **MEASURE THE REMAINDER AGAINST THE ROUTE.** The car's live fix is
//     projected onto the active leg's road polyline and the unconsumed length is
//     the distance left; the app's one speed model turns it into minutes. The
//     inputs are the ones MYR-460 and MYR-458 already put on this surface — the
//     fix off the telemetry socket, the polyline out of `RideRouteStore` — so
//     this costs no fetch and no new plumbing.
//
// WHY MINUTES COME FROM `TripEstimate.averageSpeedMph` AND NOT FROM THE CAR'S
// SPEED. An instantaneous speed is zero at every red light, which makes the ETA
// infinite at exactly the moments a rider is most likely to look at it. The flat
// average is the estimator this whole app already uses for pickup ETAs
// (`RiderPickupETA`), so the tracking sheet now quotes the same model as the
// sheet the rider booked from. **`detourFactor` is deliberately NOT applied**: it
// exists to inflate a straight line into a road distance, and this distance IS
// the road — applying it would add 30% to a number measured off the roads
// themselves.
//
// WHAT WOULD BE BETTER, AND IS NOT AVAILABLE. The car's OWN nav ETA is on the
// wire (`VehicleState.etaMinutes`) and is a routed duration with live traffic in
// it, which beats any closed form. It does not reach this surface:
// `SharedViewerState.riderNavMinutesToArrival` is `nil` on every path today (the
// v1 rider gap MYR-270 recorded), and MYR-409 has an open finding that `navFresh`
// is a row stamp rather than a reading stamp, so a client adopting it would need
// that fixed first. Recorded, not attempted here.
//
// THE SIMULATED PATH IS UNTOUCHED BY CONSTRUCTION. Every value here is optional
// and `nil` on the simulated path, where the `trackProgress` ticker is a real
// model of a car that really is moving; the sheet falls back to exactly the
// derivations it has always used, so `trackingLeg1` / `trackingLeg2` /
// `trackingArriving` are byte-identical.

/// A measured remainder along one leg of the trip.
struct RiderLegRemaining: Equatable, Sendable {
    /// Road miles from the car's projected place on the route to the leg's end.
    let miles: Double
    /// Those miles at the app's one average speed, floored at 0. A leg that
    /// rounds to zero is a car that has arrived, and the sheet's own `"<1 min"`
    /// grammar renders it.
    let minutes: Int

    /// How far off the polyline a fix may sit and still be measured against it.
    ///
    /// A projection is defined for any point, however far away, so without a
    /// bound a car on the far side of town would be reported as "0.3 mi away"
    /// because that is where it happens to project. 400m is generous enough to
    /// absorb the ordinary reasons a real fix is not on the drawn line — GPS
    /// error, a route MKDirections drew down the parallel street, a car in the
    /// pickup's car park — and tight enough that a genuinely different journey
    /// fails it. Past it we hold NO measurement, which is the honest answer and
    /// the one the sheet renders as a withheld hero rather than a wrong number.
    static let offRouteToleranceMeters: Double = 400

    /// Measure what is left of `route` from `carPosition`.
    ///
    /// `nil` — meaning "not measurable, say nothing" — for any of: no fix, a
    /// polyline that is not real road geometry (MYR-293's predicate, so the
    /// straight `[from, to]` fallback can never be measured as a trip), or a fix
    /// that lands further than ``offRouteToleranceMeters`` from the line.
    static func measure(carPosition: CLLocationCoordinate2D?, route: [CLLocationCoordinate2D]) -> RiderLegRemaining? {
        guard let carPosition, RideRoutePolyline.isReal(route) else { return nil }
        guard RideRouteGeometry.distanceFromPolyline(carPosition, polyline: route) <= offRouteToleranceMeters else {
            return nil
        }
        guard let meters = RideRouteGeometry.remainingMeters(from: carPosition, along: route) else { return nil }
        let miles = meters / 1609.344
        let minutes = max(0, Int((miles / TripEstimate.averageSpeedMph * 60).rounded()))
        return RiderLegRemaining(miles: miles, minutes: minutes)
    }
}

/// What the LIVE path knows about this ride's clock, resolved once per frame by
/// `SharedViewerScreen` and read by both layers of the tracking sheet.
///
/// The whole value is `nil` on the simulated path — an ABSENCE rather than an
/// `isLive` branch inside the view (the MYR-385 / MYR-402 pattern), so there is
/// no conditional in the sheet that can be written backwards and every fixture
/// capture takes the pre-MYR-472 derivation without asking.
struct RiderTrackingTruth: Equatable, Sendable {
    /// The instant this device observed the ride go `enroute`
    /// (`RideRequestRecord.enrouteObservedAt`) — the ONE anchor for "Picked up at".
    /// `nil` for a ride adopted mid-flight, which renders the unknown dash.
    let pickupAnchor: Date?
    /// The measured remainder of the leg the rider is on, or `nil` when it cannot
    /// be measured from a live fix against a real route.
    let remaining: RiderLegRemaining?

    init(pickupAnchor: Date?, remaining: RiderLegRemaining?) {
        self.pickupAnchor = pickupAnchor
        self.remaining = remaining
    }

    /// Whether the sheet may render a minutes/miles hero at all.
    ///
    /// `truth == nil` (simulated) keeps the caller's own decision. On live the
    /// answer is the measurement's existence and nothing else: MYR-472's defect is
    /// precisely a number rendered with nothing behind it, so the arm that has
    /// nothing behind it must render no number. The rider is not left guessing —
    /// MYR-449's `RiderTrackingLiveReport` already says why the car has gone
    /// quiet, on the same sheet, in the same frame.
    static func showsHero(_ truth: RiderTrackingTruth?, otherwise fallback: Bool) -> Bool {
        guard let truth else { return fallback }
        return truth.remaining != nil && fallback
    }

    /// The pickup stop's clock string.
    ///
    /// It lives here rather than inside `RideRequestTrackingContent` because it is
    /// the rule MYR-472 got wrong, and a rule inside a `View`'s private computed
    /// property is one no test can drive. Three arms:
    ///
    ///  • **Before pickup** — a FORECAST, and moving with the clock is what a
    ///    forecast does. `now + minutesToPickup`, where those minutes are a
    ///    measured remainder on live and the ticker's in SIM.
    ///  • **After pickup, simulated** — `fromNow(0)`, byte-for-byte the
    ///    pre-MYR-472 rendering, so every fixture capture is unchanged.
    ///  • **After pickup, live** — the ANCHOR, or the calm dash for a ride this
    ///    process did not observe start. Never `now`: the boarding happened once.
    static func pickupClockText(
        _ truth: RiderTrackingTruth?,
        atPickup: Bool,
        minutesToPickup: Int,
        now: Date = Date()
    ) -> String {
        guard atPickup else {
            return RideRequestClock.at(now.addingTimeInterval(TimeInterval(minutesToPickup) * 60))
        }
        guard let truth else { return RideRequestClock.at(now) }
        guard let anchor = truth.pickupAnchor else { return RidePickupETADisplay.unknownClock }
        return RideRequestClock.at(anchor)
    }
}
