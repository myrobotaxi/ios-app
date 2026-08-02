import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-414 — the rider's post-ride summary may only claim what it holds
//
// The client, r17: *"this screen at the end is not connected to real data."*
// Three stat tiles and a hero polyline, none of them derived from the ride.
//
// These pin the two pure rules the fix rests on — `RideTripSpan` (what a trip's
// duration IS, given a wire that has no start instant) and
// `RideSummaryPresentation` (which tiles, which line, which sections) — plus the
// polyline-length arithmetic the distance tile is measured with.
//
// The SIM arm is asserted as hard as the live one, because "no fixtures on the
// live path" cuts both ways: the drift-gate scenes depend on the prototype's
// illustration being rendered EXACTLY as it was.
final class RideSummaryHonestyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: RideTripSpan.observing — when a trip start may be stamped

    /// The transition, and only the transition. This is the rider's own "Start
    /// ride" tap and the frame that follows it.
    func testTheEnrouteTransitionStampsTheTripStart() {
        XCTAssertEqual(
            RideTripSpan.observing(previous: .arrived, next: .enroute, held: nil, now: t0),
            t0
        )
        XCTAssertEqual(
            RideTripSpan.observing(previous: .accepted, next: .enroute, held: nil, now: t0),
            t0,
            "an owner-driven jump straight to enroute is still a transition this device saw"
        )
    }

    /// **The restamp guard.** A refetch, a re-delivered `ride_status_changed`
    /// frame and a foreground reconcile all fold `enroute` onto an `enroute`
    /// record. Restamping on each would walk the start forward and shrink the trip
    /// toward zero — a bug that gets WORSE the longer the ride and the flakier the
    /// connection, and which no single-fold test would see.
    func testAnInstantAlreadyHeldIsNeverRestamped() {
        let later = t0.addingTimeInterval(600)
        for next in [RideRequestStatus.enroute, .completed, .arrived] {
            XCTAssertEqual(
                RideTripSpan.observing(previous: .enroute, next: next, held: t0, now: later),
                t0,
                "\(next) must carry the held instant through unchanged"
            )
        }
    }

    /// **The honest gap.** A ride whose first sighting is already `enroute` — the
    /// force-quit / cold-adoption case — has no observable start, and none of the
    /// folds that follow can manufacture one.
    func testARideFirstSeenEnrouteHasNoTripStart() {
        XCTAssertNil(RideTripSpan.observing(previous: nil, next: .enroute, held: nil, now: t0),
                     "a first sighting observed no transition")
        XCTAssertNil(RideTripSpan.observing(previous: .enroute, next: .enroute, held: nil, now: t0),
                     "and re-folding the same status is not one either")
        XCTAssertNil(RideTripSpan.observing(previous: .enroute, next: .completed, held: nil, now: t0),
                     "nor is the completion that follows it")
    }

    /// Nothing but `enroute` starts a trip. Written as a sweep so a status added
    /// later has to be considered rather than silently joining the stampers.
    func testNoOtherStatusStampsATripStart() {
        for next in [RideRequestStatus.pending, .accepted, .arrived, .completed, .declined] {
            XCTAssertNil(
                RideTripSpan.observing(previous: .accepted, next: next, held: nil, now: t0),
                "\(next) is not the moment the car left the kerb"
            )
        }
    }

    // MARK: RideTripSpan.minutes — what the span is worth saying

    func testTheSpanIsTheMinutesBetweenTheTwoInstants() {
        XCTAssertEqual(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0.addingTimeInterval(14 * 60)), 14)
        XCTAssertEqual(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0.addingTimeInterval(31)), 1,
                       "31s is the first thing worth calling a minute")
    }

    /// Rounding is to the NEAREST minute, and the boundary is asserted from both
    /// sides so a `floor`/`ceil` swap cannot pass.
    func testTheSpanRoundsToTheNearestMinute() {
        XCTAssertEqual(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0.addingTimeInterval(89)), 1)
        XCTAssertEqual(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0.addingTimeInterval(91)), 2)
    }

    /// Every way the span is NOT derivable, each of which would otherwise render a
    /// number: a missing end, a missing start, a completion BEFORE the start
    /// (clock skew, or a `completedAt` belonging to an earlier attempt), and a span
    /// that rounds to zero — MYR-395's rule that an unmeasurable duration renders
    /// no line rather than "0 min".
    func testAnUnderivableSpanIsNilRatherThanZero() {
        XCTAssertNil(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: nil))
        XCTAssertNil(RideTripSpan.minutes(enrouteObservedAt: nil, completedAt: t0))
        XCTAssertNil(RideTripSpan.minutes(enrouteObservedAt: nil, completedAt: nil))
        XCTAssertNil(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0.addingTimeInterval(-300)),
                     "a completion before the start is not a negative trip, it is no trip")
        XCTAssertNil(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0),
                     "a zero span renders nothing, never \"0 min\"")
        XCTAssertNil(RideTripSpan.minutes(enrouteObservedAt: t0, completedAt: t0.addingTimeInterval(20)))
    }

    // MARK: The SIM arm — the prototype's illustration, unchanged

    /// The drift-gate contract, stated as an assertion: on the simulated path this
    /// screen renders exactly what it rendered before MYR-414 — three tiles off the
    /// destination's quoted estimate, the tip section, and a drawn line.
    func testTheSimulatedPathIsTheProtoypesIllustrationVerbatim() {
        let p = RideSummaryPresentation.resolve(
            isLive: false,
            estimateMinutes: 32,
            estimateMiles: 14.2,
            // Deliberately supplied AND deliberately ignored: a simulated record
            // that somehow carried live instants must not change this page.
            tripMinutes: 14,
            roadRouteMiles: 12.8,
            completedAt: t0,
            now: t0
        )
        XCTAssertEqual(p.tiles, [.trip(minutes: 32), .fsdMiles(14.2), .autonomous(percent: 100)])
        XCTAssertTrue(p.offersTip, "the prototype's joke card is the SIM's to keep")
        XCTAssertTrue(p.drawsRouteLine)
        XCTAssertEqual(p.arrivedAt, t0, "the eyebrow keeps its \"now\" stamp in SIM")
    }

    // MARK: The LIVE arm — a tile IFF its datum exists

    func testTheLivePathRendersTheMeasuredTripAndTheRoadDistance() {
        let p = live(tripMinutes: 14, roadRouteMiles: 12.84)
        // MYR-422 — the strip is the prototype's THREE slots (a fourth tile does not
        // fit the page: `RideSummaryStripLayoutTests`), so the measured distance
        // rides the hero caption instead of a tile. Both facts are asserted together
        // because they are one fact.
        XCTAssertEqual(p.tiles, [.trip(minutes: 14), .fsdMiles(nil), .autonomous(percent: nil)])
        XCTAssertEqual(p.heroDistanceMiles, 12.84)
        XCTAssertTrue(p.drawsRouteLine)
    }

    /// **THE LIVE STRIP IS NEVER MORE THAN THREE TILES**, whatever the inputs — the
    /// client's "keep the layout stable", and the page's own width budget.
    func testTheLiveStripNeverExceedsThePrototypesThreeSlots() {
        for trip in [nil, 14] as [Int?] {
            for miles in [nil, 12.8] as [Double?] {
                XCTAssertLessThanOrEqual(live(tripMinutes: trip, roadRouteMiles: miles).tiles.count, 3)
            }
        }
    }

    /// **THE MEASURED DISTANCE AND THE DRAWN LINE ARE ONE FACT** — MYR-414's
    /// invariant, unchanged by the move off the strip: the page can never measure a
    /// route it will not draw, or draw one it will not measure.
    func testTheHeroDistanceAndTheHeroLineAreRefusedTogether() {
        for miles in [nil, 12.8] as [Double?] {
            let p = live(tripMinutes: 14, roadRouteMiles: miles)
            XCTAssertEqual(p.drawsRouteLine, p.heroDistanceMiles != nil)
        }
    }

    /// And SIM's caption is the prototype's "from {pickup}" alone.
    func testTheSimulatedHeroCaptionCarriesNoDistance() {
        let p = RideSummaryPresentation.resolve(
            isLive: false, estimateMinutes: 32, estimateMiles: 14.2,
            tripMinutes: 14, roadRouteMiles: 12.8, completedAt: t0, now: t0
        )
        XCTAssertNil(p.heroDistanceMiles, "the drift-gate capture's caption may not grow a suffix")
    }

    // MARK: MYR-422 — the two placeholders, and what they may never become

    /// **THE CLIENT'S DECISION, SUPERSEDING MYR-414's OMISSION.** The FSD MILES and
    /// AUTONOMOUS tiles are back on every live resolution — the row keeps its shape
    /// — and they are back carrying NOTHING.
    func testTheLivePathAlwaysRendersBothPlaceholderTiles() {
        for trip in [nil, 14] as [Int?] {
            for miles in [nil, 12.8] as [Double?] {
                let tiles = live(tripMinutes: trip, roadRouteMiles: miles).tiles
                XCTAssertEqual(tiles.suffix(2), [.fsdMiles(nil), .autonomous(percent: nil)],
                               "the placeholders trail the real tiles, whatever the real tiles are")
            }
        }
    }

    /// **The two fabrications are still unreachable on live, whatever the inputs** —
    /// MYR-414's guarantee, restated now that the tiles carry an associated value
    /// rather than being absent. Swept across the whole matrix rather than asserted
    /// once, because the way this regresses is a single arm being written to "fall
    /// back" to the estimate, or to the joined DRIVE's own `fsdMiles` (which
    /// describes the whole drive, approach leg included — see `Tile.fsdMiles`).
    func testNoLiveResolutionCanProduceAnFSDOrAutonomyNUMBER() {
        for trip in [nil, 14] as [Int?] {
            for miles in [nil, 12.8] as [Double?] {
                for tile in live(tripMinutes: trip, roadRouteMiles: miles).tiles {
                    switch tile {
                    case let .fsdMiles(value):
                        XCTAssertNil(value, "FSD miles needs a window-scoped drive record, not the trip's distance")
                    case let .autonomous(percent):
                        XCTAssertNil(percent, "100% autonomous is a claim about a drive this app has no record of")
                    case .trip:
                        break
                    }
                }
            }
        }
    }

    /// The SIM literal is the PROTOTYPE's, and it is the only number either of those
    /// two tiles can carry anywhere in the app.
    func testTheAutonomyLiteralBelongsToTheSimulatedArmAlone() {
        XCTAssertEqual(RideSummaryPresentation.prototypeAutonomousPercent, 100)
        let sim = RideSummaryPresentation.resolve(
            isLive: false, estimateMinutes: 32, estimateMiles: 14.2,
            tripMinutes: nil, roadRouteMiles: nil, completedAt: nil, now: t0
        )
        XCTAssertTrue(sim.tiles.contains(.autonomous(percent: 100)))
    }

    /// The estimate is not a fallback for anything on live. This is the actual
    /// defect: `destination.minutes` / `destination.miles` re-labelled after the
    /// fact as what the ride took.
    func testTheQuotedEstimateNeverReachesTheLivePath() {
        let p = RideSummaryPresentation.resolve(
            isLive: true,
            estimateMinutes: 35,
            estimateMiles: 14.2,
            tripMinutes: nil,
            roadRouteMiles: nil,
            completedAt: nil,
            now: t0
        )
        // MYR-422: the row still renders — as two dashes. Nothing derivable is now
        // stated as "we do not know these", which is the client's decision, and the
        // one thing it may never become is the estimate wearing the trip's label.
        XCTAssertEqual(p.tiles, [.fsdMiles(nil), .autonomous(percent: nil)])
        XCTAssertFalse(p.tiles.contains(.trip(minutes: 35)))
        XCTAssertNil(p.heroDistanceMiles, "and the quoted 14.2 mi never becomes the hero's measurement")
    }

    func testAMissingTripSpanDropsOnlyTheTripTile() {
        let p = live(tripMinutes: nil, roadRouteMiles: 12.8)
        XCTAssertEqual(p.tiles, [.fsdMiles(nil), .autonomous(percent: nil)])
        XCTAssertEqual(p.heroDistanceMiles, 12.8, "the route was still measured")
    }

    /// **No road route means no distance AND no line, from the same fact.** The
    /// two cannot disagree: a summary drawing a route it will not measure (or
    /// measuring one it will not draw) would be the pre-MYR-414 screen in one
    /// direction or the other.
    func testNoRoadRouteMeansNoDistanceAndNoLine() {
        let p = live(tripMinutes: 14, roadRouteMiles: nil)
        XCTAssertEqual(p.tiles, [.trip(minutes: 14), .fsdMiles(nil), .autonomous(percent: nil)])
        XCTAssertNil(p.heroDistanceMiles)
        XCTAssertFalse(p.drawsRouteLine, "MYR-293: pins are a fact, a route we do not hold is not")
    }

    func testTheTipSectionIsNeverOfferedOnLive() {
        for trip in [nil, 14] as [Int?] {
            for miles in [nil, 12.8] as [Double?] {
                XCTAssertFalse(live(tripMinutes: trip, roadRouteMiles: miles).offersTip,
                               "it goes nowhere, and it says \"driver\" on a driverless product")
            }
        }
    }

    /// The eyebrow's clock is the ride's completion instant, and its absence is an
    /// absence — never the moment the view happened to be composed.
    func testTheArrivedStampIsTheRidesOwnInstant() {
        XCTAssertEqual(live(tripMinutes: 14, roadRouteMiles: 12.8, completedAt: t0).arrivedAt, t0)
        XCTAssertNil(live(tripMinutes: nil, roadRouteMiles: nil, completedAt: nil).arrivedAt)
    }

    /// The ORDER is fixed, and the placeholders stay in the prototype's own slots
    /// when the trip tile drops out — a dash must not slide into the leading slot
    /// and inherit the trip's meaning at a glance.
    func testTileOrderIsStable() {
        XCTAssertEqual(live(tripMinutes: 9, roadRouteMiles: 3.1).tiles.first, .trip(minutes: 9))
        XCTAssertEqual(
            live(tripMinutes: nil, roadRouteMiles: 3.1).tiles,
            [.fsdMiles(nil), .autonomous(percent: nil)]
        )
    }

    // MARK: The distance itself

    /// The polyline's length is the sum of its segments — the distance ALONG the
    /// roads, which for any real route is longer than the straight line between its
    /// ends. That difference is the whole reason the straight fallback may not be
    /// measured: a ~1.6 mi great-circle hop is ~2 mi of driving here.
    func testThePolylineLengthFollowsTheRoadAndNotTheCrow() {
        let straight = [
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            CLLocationCoordinate2D(latitude: 37.7949, longitude: -122.4194)
        ]
        let dogleg = [
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4094),
            CLLocationCoordinate2D(latitude: 37.7949, longitude: -122.4094),
            CLLocationCoordinate2D(latitude: 37.7949, longitude: -122.4194)
        ]
        let straightMiles = RideRouteGeometry.lengthMiles(straight)
        XCTAssertEqual(straightMiles, 1.381, accuracy: 0.01, "0.02° of latitude ≈ 1.38 mi")
        XCTAssertGreaterThan(RideRouteGeometry.lengthMiles(dogleg), straightMiles * 1.5,
                             "every vertex adds real driving")
    }

    func testADegeneratePolylineHasNoLength() {
        XCTAssertEqual(RideRouteGeometry.lengthMiles([]), 0)
        XCTAssertEqual(RideRouteGeometry.lengthMiles([CLLocationCoordinate2D(latitude: 1, longitude: 1)]), 0)
    }

    /// `RideRoutePolyline.isReal` is the gate the distance tile's input is filtered
    /// through, and it is the SAME predicate the line is drawn from — asserted here
    /// so the summary's two consumers of "do we have a route" cannot drift apart.
    func testTheRealnessPredicateRefusesTheStraightFallback() {
        let pair = [
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)
        ]
        XCTAssertFalse(RideRoutePolyline.isReal(pair),
                       "two points is what the provider returns when it has nothing")
        XCTAssertTrue(RideRoutePolyline.isReal(pair + [CLLocationCoordinate2D(latitude: 37.7, longitude: -122.4)]))
    }

    // MARK: helper

    private func live(
        tripMinutes: Int?,
        roadRouteMiles: Double?,
        completedAt: Date? = nil
    ) -> RideSummaryPresentation {
        RideSummaryPresentation.resolve(
            isLive: true,
            estimateMinutes: 35,
            estimateMiles: 14.2,
            tripMinutes: tripMinutes,
            roadRouteMiles: roadRouteMiles,
            completedAt: completedAt,
            now: t0
        )
    }
}
