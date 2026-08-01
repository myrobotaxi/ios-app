import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-390 — one etch per route, not one per page
//
// r15 clip (the same recording MYR-389 came from): the route is fully etched and
// breathing on the destination-selected search sheet; tapping "Continue" to the
// "Schedule with Lunar" sheet makes the drawn line VANISH for ~0.5s and then
// replay its 1.6s etch from zero. Same trip, same camera, no refetch.
//
// The on-simulator trace posted to the issue ruled out the two suspects that
// would have been the route's fault and named the third: only the VIEW reset.
// `SharedViewerScreen` passed `replayKey: String(describing: sheetPhase)` into
// `RideRequestRouteMap`, whose `onChange(of: replayKey)` called
// `restartPresentation()` — snapping `etchProgress` to 0 and putting the
// presentation back in `.etching`, whose map content is `EmptyMapContent()`.
// The 0.5s "vanish" IS that empty content; the surviving "pickup glow dot" is
// the etch head at progress 0.
//
// These pin the three facts that make it impossible now. `RouteEtchContinuity
// UITests` proves the same thing on the REAL transition, because a pure test can
// show the rule is right and only a launch can show the screen consults it.
@MainActor
final class RouteEtchContinuityTests: XCTestCase {

    // A real 4-point road-shaped route: San Francisco → SFO, the sample pair
    // every rider scene uses.
    private let pickup = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let destination = CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)

    private func road(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        vertices: Int = 4
    ) -> [CLLocationCoordinate2D] {
        precondition(vertices >= 2)
        return (0..<vertices).map { i in
            let t = Double(i) / Double(vertices - 1)
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                // Bowed off the straight line so this reads as geometry, not a fallback.
                longitude: a.longitude + (b.longitude - a.longitude) * t + (t * (1 - t)) * 0.01
            )
        }
    }

    // MARK: (a) The route's identity does not change when the PAGE does

    /// The trace's finding 1, as a property: `routeKey` was byte-identical either
    /// side of the flip and never fired an `onChange`. The etch memory therefore
    /// has to be keyed on something with that same stability — the two endpoints.
    func testTheSameRouteHasTheSameIdentityWhicheverPageIsAskingA() {
        let route = road(from: pickup, to: destination)
        XCTAssertEqual(
            RouteEtchIdentity(route), RouteEtchIdentity(route),
            "one route, asked about twice, is one identity"
        )
    }

    /// **The point-count trap, stated.** MYR-237's `routeKey` leads with
    /// `route.count`, which is right for "re-fit the camera, the geometry
    /// changed" and wrong for "is this the same trip": MKDirections legitimately
    /// answers the same pair with a different vertex count (a refetch, a
    /// re-route around the same two ends), and an etch keyed on the count would
    /// replay the whole 1.6s pass over it. The endpoints are the trip.
    func testAVertexCountChangeIsNotANewRouteIdentity() {
        let coarse = road(from: pickup, to: destination, vertices: 4)
        let dense = road(from: pickup, to: destination, vertices: 248)
        XCTAssertNotEqual(coarse.count, dense.count, "precondition: two different vertex counts")
        XCTAssertEqual(
            RouteEtchIdentity(coarse), RouteEtchIdentity(dense),
            "same pickup, same destination — the same trip, however many points describe it"
        )
    }

    /// And the other direction, which is what keeps a genuinely new trip honest.
    func testADifferentDestinationIsADifferentRoute() {
        let a = road(from: pickup, to: destination)
        let b = road(from: pickup, to: CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783))
        XCTAssertNotEqual(RouteEtchIdentity(a), RouteEtchIdentity(b))
    }

    /// A route with nothing to draw has no etch to remember, and asking the
    /// ledger about it must not invent one.
    func testAnUndrawableRouteHasNoIdentity() {
        XCTAssertNil(RouteEtchIdentity([]))
        XCTAssertNil(RouteEtchIdentity([pickup]))
        XCTAssertEqual(RouteEtchLedger().progress(for: RouteEtchIdentity([])), 0)
    }

    /// The trace's finding 2: the flip calls `ensureLeg2` once and it takes the
    /// cache-hit early return — same key, nothing in flight, MKDirections not
    /// re-asked. Pinned through the shipping store so "the flip does not refetch"
    /// is a property of the cache rather than of the timing on the day.
    func testThePhaseFlipDoesNotRefetchTheRoute() async {
        let provider = ScriptedEtchRouteProvider()
        let store = RideRouteStore(provider: provider)

        store.ensureLeg2(pickup: pickup, destination: destination)   // Search's preview
        await waitUntil { store.leg2.count > 1 }
        XCTAssertTrue(RideRoutePolyline.isReal(store.leg2), "precondition: a real route landed")
        let drawnOnSearch = store.leg2

        store.ensureLeg2(pickup: pickup, destination: destination)   // Review, on the flip
        await Task.yield()

        let calls = await provider.count()
        XCTAssertEqual(calls, 1, "the flip must be a cache hit — MKDirections is not re-asked")
        XCTAssertEqual(
            RouteEtchIdentity(store.leg2), RouteEtchIdentity(drawnOnSearch),
            "and the geometry under the rider is the same route it was a frame ago"
        )
    }

    // MARK: (b) The etch's progress survives the flip

    /// The defect, as the rule that now forbids it. A first arrival etches; the
    /// SAME route asked again — a re-mounted overlay, a new page, a re-decided
    /// presentation — opens `.pulsing` at FULL progress, so the settled map-space
    /// line is on screen from the first frame and nothing collapses.
    func testARouteThatHasBeenEtchedOpensFullyDrawnB() {
        let ledger = RouteEtchLedger()
        let identity = RouteEtchIdentity(road(from: pickup, to: destination))

        let first = RouteEtchPresentation.resolve(
            etch: true, reduceMotion: false, availability: .road,
            etchedProgress: ledger.progress(for: identity)
        )
        XCTAssertEqual(first, .init(opening: .etching, progress: 0), "the first arrival etches from zero")

        // What `runPass` records when the 1.6s pass completes.
        ledger.record(identity, progress: 1)

        let afterFlip = RouteEtchPresentation.resolve(
            etch: true, reduceMotion: false, availability: .road,
            etchedProgress: ledger.progress(for: identity)
        )
        XCTAssertEqual(
            afterFlip, .init(opening: .pulsing, progress: 1),
            "the flip must open on the settled route — .etching here is the 0.5s vanish the client filmed"
        )
    }

    /// The ledger is where that survives, and it is keyed by the ROUTE. A second
    /// consumer asking about the same trip gets the same answer without having
    /// watched the animation — which is the whole reason the state cannot live in
    /// the overlay.
    func testTheLedgerAnswersForTheROUTENotForTheAsker() {
        let ledger = RouteEtchLedger()
        let coarse = RouteEtchIdentity(road(from: pickup, to: destination, vertices: 4))
        let dense = RouteEtchIdentity(road(from: pickup, to: destination, vertices: 248))
        ledger.record(coarse, progress: 1)
        XCTAssertEqual(ledger.progress(for: dense), 1, "one trip, one etch")
    }

    /// MONOTONIC. A restart landing while a completed route is still crossfading
    /// must not be able to record its own 0 over the 1 that is true on screen.
    func testRecordedProgressOnlyEverGoesUp() {
        let ledger = RouteEtchLedger()
        let identity = RouteEtchIdentity(road(from: pickup, to: destination))
        ledger.record(identity, progress: 1)
        ledger.record(identity, progress: 0)
        XCTAssertEqual(ledger.progress(for: identity), 1)
        ledger.record(identity, progress: .nan)
        ledger.record(identity, progress: 4)
        XCTAssertEqual(ledger.progress(for: identity), 1, "clamped and finite — MYR-227's rule")
    }

    /// Booking turns the etch OFF, and that arm is now reached by `onChange(of:
    /// etch)` rather than incidentally by the phase string changing. Whatever the
    /// ledger says, Booking settles STATIC — and because `.settled` draws the
    /// whole map-space route, arriving there over a finished etch is seamless
    /// rather than a second collapse.
    func testBookingSettlesStaticOverAFinishedEtch() {
        let resolved = RouteEtchPresentation.resolve(
            etch: false, reduceMotion: false, availability: .road, etchedProgress: 1
        )
        XCTAssertEqual(resolved.opening, .settled)
    }

    /// Reduce Motion is unchanged by all of this: no pass, no glow, the route
    /// simply drawn.
    func testReduceMotionStillSettlesWhateverTheLedgerHolds() {
        for etched in [0.0, 1.0] {
            XCTAssertEqual(
                RouteEtchPresentation.resolve(
                    etch: true, reduceMotion: true, availability: .road, etchedProgress: etched
                ).opening,
                .settled
            )
        }
    }

    /// The straight `[pickup, destination]` fallback is never etched and never
    /// remembered as etched (MYR-237's client rule, MYR-293's one predicate).
    ///
    /// MYR-395 — the OPENING moved from `.loading` to `.lineless` here, because
    /// `.unavailable` means the fetch answered: nothing is running, so nothing may
    /// breathe. `.resolving` is the arm that still gets `.loading`, asserted below.
    func testTheStraightFallbackIsNeverEtched() {
        XCTAssertEqual(
            RouteEtchPresentation.resolve(
                etch: true, reduceMotion: false, availability: .unavailable, etchedProgress: 1
            ),
            .init(opening: .lineless, progress: 0),
            "a straight line is not a route, so there is nothing to have drawn"
        )
    }

    // MARK: MYR-395 — no presentation may draw a line for a route that is not one

    /// **THE INVARIANT, and the defect it forbids.**
    ///
    /// r16, the client, on a 1,049 mi Grayslake IL → Galleria Dallas booking:
    /// *"Looks like your route etch update broke the line from being drawn: this
    /// is a major regression."*
    ///
    /// The ledger was NOT the cause on the surface he photographed — but the arm
    /// this test sweeps is real, and it is the one the issue named: MYR-390 put
    /// the realness guard BELOW the `etch` guard, and the branch above it draws
    /// the line WHOLE. So `etch: false` (the Booking sheet) and `reduceMotion:
    /// true` (any rider with motion turned down) skipped the geometry question
    /// entirely, took `.settled`, and rendered the provider's straight fallback as
    /// a 949-mile gold route across five states. Reproduced before the fix with
    /// `MRT_SCENE=booking MRT_ROUTE_UNAVAILABLE=1`.
    ///
    /// Stated against `Opening.drawsWholeLine` rather than against a list of two
    /// case names, so an opening added later has to answer the question instead of
    /// being quietly outside a test that enumerates `.pulsing` and `.settled`.
    func testNoPresentationDrawsAWholeLineOverARouteThatIsNotOne() {
        for availability in [RideRouteAvailability.resolving, .unavailable] {
            for etch in [true, false] {
                for reduceMotion in [true, false] {
                    // Every ledger value, including the FULL one MYR-390 records
                    // when a pass completes — the "identity marked seen" case.
                    for etched in [0.0, 0.5, 1.0] {
                        let resolved = RouteEtchPresentation.resolve(
                            etch: etch, reduceMotion: reduceMotion,
                            availability: availability, etchedProgress: etched
                        )
                        let label = "availability=\(availability) etch=\(etch) rm=\(reduceMotion) etched=\(etched)"
                        XCTAssertFalse(
                            resolved.opening.drawsWholeLine,
                            "\(label): a straight fallback was presented as a drawn route"
                        )
                        XCTAssertEqual(
                            resolved.progress, 0,
                            "\(label): a route nobody can draw has no progress to open at"
                        )
                    }
                }
            }
        }
    }

    /// The two lineless states differ in MOTION and only in motion, and getting
    /// that backwards is what made the client's map look busy forever.
    ///
    /// `.resolving` genuinely has a fetch running, so an etching surface breathes
    /// MYR-237's head where the laser will start. `.unavailable` has finished
    /// failing, so nothing anywhere may animate about it — that head is a claim
    /// that work is in progress.
    func testOnlyAnInFlightFetchIsAllowedToLookBusy() {
        XCTAssertEqual(
            RouteEtchPresentation.resolve(
                etch: true, reduceMotion: false, availability: .resolving, etchedProgress: 0
            ).opening,
            .loading,
            "MKDirections is working — the etch head breathes at the pickup"
        )
        XCTAssertEqual(
            RouteEtchPresentation.resolve(
                etch: true, reduceMotion: false, availability: .unavailable, etchedProgress: 0
            ).opening,
            .lineless,
            "MKDirections answered and it was not a route — nothing is working, so nothing breathes"
        )
        // A static surface never breathes for either reason.
        for availability in [RideRouteAvailability.resolving, .unavailable] {
            XCTAssertEqual(
                RouteEtchPresentation.resolve(
                    etch: false, reduceMotion: false, availability: availability, etchedProgress: 0
                ).opening,
                .lineless,
                "Booking is static: it draws no line and it does not animate about one"
            )
            XCTAssertEqual(
                RouteEtchPresentation.resolve(
                    etch: true, reduceMotion: true, availability: availability, etchedProgress: 0
                ).opening,
                .lineless,
                "Reduce Motion is a promise, and it outranks the working cue"
            )
        }
    }

    /// A REAL route is untouched by the reordering — all four MYR-390 arms still
    /// resolve exactly as they did, which is what keeps every route capture
    /// byte-identical.
    func testARealRouteResolvesExactlyAsItDidBeforeTheGuardMoved() {
        XCTAssertEqual(
            RouteEtchPresentation.resolve(etch: true, reduceMotion: false, availability: .road, etchedProgress: 0),
            .init(opening: .etching, progress: 0)
        )
        XCTAssertEqual(
            RouteEtchPresentation.resolve(etch: true, reduceMotion: false, availability: .road, etchedProgress: 1),
            .init(opening: .pulsing, progress: 1)
        )
        XCTAssertEqual(
            RouteEtchPresentation.resolve(etch: false, reduceMotion: false, availability: .road, etchedProgress: 0.4),
            .init(opening: .settled, progress: 0.4)
        )
        XCTAssertEqual(
            RouteEtchPresentation.resolve(etch: true, reduceMotion: true, availability: .road, etchedProgress: 1),
            .init(opening: .settled, progress: 1)
        )
    }

    // MARK: (c) A genuinely new trip still etches from zero

    /// MYR-389's reset defines when a route legitimately restarts, and MYR-390
    /// does not weaken it. A NEW destination gets a new identity, so it etches
    /// without anyone deciding that it should.
    func testANewDestinationEtchesFromZeroC() {
        let ledger = RouteEtchLedger()
        ledger.record(RouteEtchIdentity(road(from: pickup, to: destination)), progress: 1)

        let newTrip = RouteEtchIdentity(
            road(from: pickup, to: CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783))
        )
        XCTAssertEqual(
            RouteEtchPresentation.resolve(
                etch: true, reduceMotion: false, availability: .road,
                etchedProgress: ledger.progress(for: newTrip)
            ),
            .init(opening: .etching, progress: 0)
        )
    }

    /// The case identity alone cannot see: the rider abandoned a trip and started
    /// an IDENTICAL one. `discardDraftTrip` is MYR-389's one list of what a draft
    /// is, and whether this trip's route has been drawn is on it — so the second
    /// attempt is a new trip by every measure in that method, and it draws itself
    /// again.
    func testDiscardingTheDraftForgetsTheEtchC() {
        let state = makeState()
        let identity = RouteEtchIdentity(road(from: pickup, to: destination))
        state.routeEtchLedger.record(identity, progress: 1)
        XCTAssertEqual(state.routeEtchLedger.progress(for: identity), 1, "precondition")

        state.enterSearchFromIdle() // the idle map's "Where to?" — MYR-389's door

        XCTAssertEqual(
            state.routeEtchLedger.progress(for: identity), 0,
            "a trip started from the idle map is a new trip, and a new trip etches"
        )
    }

    // MARK: Support

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: Int = 200) async {
        for _ in 0..<timeout {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeState() -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: EtchTestUserLocation(coordinate: pickup),
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: false
        )
        return SharedViewerState(seams: seams)
    }
}

/// A no-network provider returning a 4-point road-shaped polyline, counting
/// calls — the same scripted-seam discipline `RideRouteTests` uses.
private actor ScriptedEtchRouteProvider: RideRouteProvider {
    private(set) var callCount = 0

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        callCount += 1
        return (0..<4).map { i in
            let t = Double(i) / 3
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * t,
                longitude: from.longitude + (to.longitude - from.longitude) * t + (t * (1 - t)) * 0.01
            )
        }
    }

    func count() -> Int { callCount }
}

private final class EtchTestUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { true }
    func start() {}
    func stop() {}
    func refresh() {}
}
