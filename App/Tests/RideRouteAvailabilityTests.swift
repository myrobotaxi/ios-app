import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-395 — a lineless route map has to say WHICH kind of lineless
//
// r16, the client, on the Review sheet for a 1,049 mi Grayslake IL → Galleria
// Dallas trip: *"Looks like your route etch update broke the line from being
// drawn: this is a major regression."*
//
// TRIAGE, before any of this was written. Three candidates were on the table and
// two are ruled out by evidence, not by reading:
//
//   (a) A MYR-390 `RouteEtchLedger` regression — the identity marked seen and the
//       presentation resolved at full progress over geometry that never arrived.
//       RULED OUT on the surface he photographed: `resolve` consults the ledger
//       only AFTER the geometry question, so an etching surface with no real route
//       can never open drawn. Confirmed on device-shaped evidence too — the same
//       949-mile pair etches correctly end to end on a networked simulator with
//       the ledger live (`MRT_SCENE=reviewLongDistance`). The ledger DID have a
//       hole on the OTHER arm (`etch: false`), which
//       `RouteEtchContinuityTests.testNoPresentationDrawsAWholeLineOverARouteThatIsNotOne`
//       now forbids — but that arm draws a straight line, it does not withhold one.
//   (b) MKDirections legitimately failing on a 1,000-mile request, with MYR-237's
//       honest no-line fallback doing its job. **THIS ONE.** Measured directly:
//       MKDirections answers that exact pair in ~1.0s with 7,348 vertices, so it
//       is not a distance limit — but any failure of it (throttle, offline, the 8s
//       deadline) lands on the straight `[from, to]` fallback, `isReal` refuses it,
//       and the map draws nothing. Reproduced pixel-for-pixel against his
//       screenshot with `MRT_SCENE=reviewLongDistance MRT_ROUTE_UNAVAILABLE=1`.
//   (c) The fallback-retry cooldown starving. RULED OUT: `SharedViewerScreen`'s
//       `.task(id: routePreviewActive)` re-asks every 6s against the store's 8s
//       cooldown, so a retry does land (~12s effective) and a route that becomes
//       available still arrives. Slow, never starved.
//
// **So nothing computed a wrong answer, and the surface was still broken.** The
// refusal to draw was correct and completely silent, on a map fitted across half
// the United States with one dot on it. A map that DECLINES to draw and a map that
// FAILED to draw are the same picture.
//
// `RideRouteAvailability` is the third arm the surface never had. Before it, the
// one signal was `reviewRouteLoading == (reviewRealRoute == nil)`, which goes
// FALSE the instant the fallback lands — so the screen simultaneously showed
// nothing and reported "not loading". MYR-343 / MYR-386's lesson again: situations
// told apart by fewer arms than they have.
final class RideRouteAvailabilityTests: XCTestCase {

    private let a = CLLocationCoordinate2D(latitude: 42.3444, longitude: -88.0417)   // Grayslake IL
    private let b = CLLocationCoordinate2D(latitude: 32.9308, longitude: -96.8206)   // Galleria Dallas

    private func road(vertices: Int) -> [CLLocationCoordinate2D] {
        (0..<vertices).map { i in
            let t = Double(i) / Double(vertices - 1)
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            )
        }
    }

    /// The three states, from the ONE fact a caller has: the store's answer for
    /// this pair, `nil` while in flight.
    func testTheThreeStatesComeFromTheStoresAnswerAlone() {
        XCTAssertEqual(RideRouteAvailability.resolve(fetched: nil), .resolving)
        XCTAssertEqual(RideRouteAvailability.resolve(fetched: [a, b]), .unavailable,
                       "the provider's own straight degradation is an ANSWER, and it is not a route")
        XCTAssertEqual(RideRouteAvailability.resolve(fetched: road(vertices: 3)), .road)
        XCTAssertEqual(RideRouteAvailability.resolve(fetched: road(vertices: 7348)), .road,
                       "the client's own pair: MKDirections answers it with 7,348 vertices")
    }

    /// Degenerate answers are answers, and they are not routes. A one-point or
    /// empty polyline reaching a surface must not be read as "still working" — the
    /// distinction is "did the fetch come back", and it did.
    func testADegenerateAnswerIsUnavailableAndNotResolving() {
        XCTAssertEqual(RideRouteAvailability.resolve(fetched: []), .unavailable)
        XCTAssertEqual(RideRouteAvailability.resolve(fetched: [a]), .unavailable)
    }

    /// **The whole point of the issue**: the two lineless states SAY something,
    /// and a real route says nothing (which is what keeps every existing capture
    /// byte-identical).
    func testEveryLinelessStateHasSomethingToSayAndARouteDoesNot() {
        XCTAssertNil(RideRouteAvailability.road.caption)
        for availability in [RideRouteAvailability.resolving, .unavailable] {
            let caption = availability.caption
            XCTAssertNotNil(caption, "\(availability): a map with no line must not be silent")
            XCTAssertFalse(caption!.isEmpty)
        }
        XCTAssertNotEqual(
            RideRouteAvailability.resolving.caption, RideRouteAvailability.unavailable.caption,
            "and the two must not say the SAME thing — 'still looking' and 'stopped finding' are different news"
        )
    }

    /// The in-flight wording is MYR-327's, not a second dialect. `ExpandedRouteMap`
    /// has rendered `"Finding route…"` since that issue for exactly this state;
    /// two literals for one state is how an app comes to describe one situation
    /// two ways depending on which surface you reached it from.
    func testTheInFlightCaptionIsTheGrammarTheAppAlreadyUses() {
        XCTAssertEqual(RideRouteAvailability.resolvingCaption, "Finding route\u{2026}")
        XCTAssertEqual(RideRouteAvailability.resolving.caption, RideRouteAvailability.resolvingCaption)
    }

    /// The settled-failure wording follows the repo's own honest-degradation
    /// grammar ("Can't reach your vehicles right now", "Can't reach {car} right
    /// now"). **"Right now" is load-bearing**: the store keeps retrying on its
    /// cooldown, so this must not read as a permanent verdict — and it must not
    /// promise a retry button either, because there isn't one and a rider cannot
    /// act on this.
    func testTheSettledFailureSaysSoWithoutClaimingItIsPermanent() {
        let caption = RideRouteAvailability.unavailableCaption
        XCTAssertEqual(caption, "Can't find a route right now")
        XCTAssertTrue(caption.hasSuffix("right now"))
        XCTAssertFalse(caption.lowercased().contains("error"))
        XCTAssertFalse(caption.lowercased().contains("retry"))
        XCTAssertFalse(caption.lowercased().contains("failed"))
    }

    /// `isReal` stays the ONE predicate underneath all of this (MYR-293). This
    /// layer must not grow a second, looser test for what counts as a route.
    func testAvailabilityIsBuiltOnTheOnePredicateAndNotASecondOne() {
        for vertices in 2...12 {
            let route = road(vertices: vertices)
            let expected: RideRouteAvailability = RideRoutePolyline.isReal(route) ? .road : .unavailable
            XCTAssertEqual(RideRouteAvailability.resolve(fetched: route), expected, "vertices=\(vertices)")
        }
    }
}
