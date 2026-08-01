import CoreLocation
import DesignSystem
import Foundation
import MapKit
import Observation

// MARK: - RideRouteProvider seam (MYR-177)
//
// Real road geometry for the two live-tracking legs (car → pickup, pickup →
// destination). CLIENT-APPROVED TEMP source: `AppleRideRouteProvider`
// (MKDirections, automobile) until the backend's Tesla route polyline (§7.4,
// arrives with dispatch/lifecycle work) is wired — so the seam is designed for
// a `TeslaRideRouteProvider` to slot in later WITHOUT touching the tracking
// screen: everything above this protocol consumes `[CLLocationCoordinate2D]`
// and never knows the source.
//
// The contract is deliberately total: a provider ALWAYS returns a usable
// polyline — a straight `[from, to]` fallback on any failure (no directions,
// throttled, offline) — so the screen never has to special-case a missing
// route. Sim/tests inject `StraightLineRideRouteProvider` (no network); the
// live app composes `AppleRideRouteProvider`.
protocol RideRouteProvider: Sendable {
    /// A road polyline from `from` to `to`. Never empty; degrades to
    /// `[from, to]` if a real route can't be produced.
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]
}

/// The offline default (sim, previews, tests): the straight segment. No
/// network — keeps the simulated tracking scenes deterministic and the unit
/// tests hermetic (CLAUDE.md "No fixtures/network on the sim path").
struct StraightLineRideRouteProvider: RideRouteProvider {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        [from, to]
    }
}

/// The client-approved TEMP live source: Apple Maps driving directions. On any
/// failure it returns the straight `[from, to]` fallback, so callers are never
/// left without a route.
struct AppleRideRouteProvider: RideRouteProvider {
    /// MKDirections can HANG (or sit in Apple's per-device throttle) far past
    /// UX patience — the client hit an endless loading sweep. The fetch races
    /// this deadline; losing it degrades to the straight fallback like any
    /// other failure (a later retry can still upgrade the route).
    static let deadline: Duration = .seconds(8)

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.transportType = .automobile
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        let directions = MKDirections(request: request)
        let response = await withTaskGroup(of: MKDirections.Response?.self) { group -> MKDirections.Response? in
            group.addTask { try? await directions.calculate() }
            group.addTask {
                try? await Task.sleep(for: Self.deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            directions.cancel()
            return first
        }
        guard let polyline = response?.routes.first?.polyline else {
            return [from, to]
        }
        let count = polyline.pointCount
        guard count > 1 else { return [from, to] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }
}

// MARK: - What counts as a ROUTE (MYR-237 client rule, named once — MYR-293)

/// The client's standing rule, as one predicate: **a straight line is not a
/// route.** `RideRouteProvider` is deliberately TOTAL — it always answers with a
/// polyline, degrading to the straight `[from, to]` pair on any failure — so the
/// honesty decision is not "did the fetch succeed" but "is what came back real
/// road geometry".
///
/// MYR-237 shipped this predicate inline on the rider's review map
/// (`RideRequestRouteMap.isRealRoute`) and MYR-293 found the two OWNER surfaces
/// drawing straight 2-point lines with no predicate at all — the owner's leg-1
/// tracking route and the incoming-request card's mini-map. It lives here now so
/// every surface that can draw a ride route spells the rule the same way, and a
/// new one cannot quietly invent a looser test.
///
/// **Two points is the tell, not a heuristic.** MKDirections returns a decoded
/// `MKPolyline` whose vertices follow the roads; a real automobile route between
/// two distinct places has never been two points. The only two-point polylines in
/// this app are the ones the provider synthesizes itself when it has nothing.
enum RideRoutePolyline {
    /// Real road geometry (many vertices) — safe to draw as a route.
    static func isReal(_ route: [CLLocationCoordinate2D]) -> Bool { route.count > 2 }

    /// The polyline a surface may DRAW: the route itself when it is real, and
    /// EMPTY otherwise. Callers render nothing (pins only) for the empty case
    /// rather than etching the provider's straight fallback.
    static func drawable(_ route: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        isReal(route) ? route : []
    }
}

// MARK: - MYR-395 — a lineless route map has to SAY which kind of lineless it is

/// What a route surface KNOWS about its road geometry, and therefore what it is
/// allowed to say.
///
/// r16, the client: *"Looks like your route etch update broke the line from being
/// drawn: this is a major regression."* His screenshot is the Review sheet for a
/// 1,049 mi Grayslake IL → Galleria Dallas trip: the camera fitted across half the
/// country, the pickup's glow head breathing, and **no line and no words**.
///
/// Nothing had broken. `MYR-237`'s honesty rule was working exactly as designed —
/// MKDirections had answered with the straight `[from, to]` fallback,
/// ``RideRoutePolyline/isReal(_:)`` refused it, and the map correctly drew nothing
/// rather than passing a straight line off as a route. **The defect is that the
/// refusal was silent.** A map that declines to draw looks identical to a map that
/// failed to draw, and the rider has no way to tell which they are looking at.
///
/// So the two lineless states are told apart HERE, once, and each carries its own
/// sentence:
///
/// - ``resolving`` — the fetch has not answered for this pair yet. The existing
///   MYR-327 "Finding route…" grammar, which `ExpandedRouteMap` has shown since
///   that issue; the two literals are asserted equal so the app cannot grow a
///   second dialect for one state.
/// - ``unavailable`` — the fetch ANSWERED and what came back is not road geometry.
///   Says so, in the repo's own honest-degradation grammar ("Can't reach your
///   vehicles right now", "Can't reach {car} right now"). The store keeps retrying
///   on its cooldown underneath, so the line can still arrive; the copy is a
///   statement about now, never a dead end.
/// - ``road`` — real geometry. No caption at all, so every surface that HAS a
///   route is byte-identical to before this issue.
///
/// **`resolving` and `unavailable` are not one boolean.** They were, in effect,
/// before this issue: `reviewRouteLoading` was `reviewRealRoute == nil`, which goes
/// FALSE the moment the fallback lands — so the one signal the surface had said
/// "not loading" about a map with nothing on it. That is MYR-343/MYR-386's lesson
/// for the fourth time: situations told apart by fewer arms than they have, so one
/// always borrows another's surface.
enum RideRouteAvailability: Equatable {
    /// No answer yet for this pickup/destination pair.
    case resolving
    /// Real road geometry — draw it, say nothing.
    case road
    /// Answered, and the answer was not a route.
    case unavailable

    /// The ONE rule, over the ONE fact a caller has: the store's answer for this
    /// pair (`nil` while the fetch is still in flight).
    static func resolve(fetched: [CLLocationCoordinate2D]?) -> RideRouteAvailability {
        guard let fetched else { return .resolving }
        return RideRoutePolyline.isReal(fetched) ? .road : .unavailable
    }

    /// MYR-327's existing wording, verbatim. Named here so `ExpandedRouteMap` and
    /// the request preview cannot drift apart (`RideRouteAvailabilityTests` pins it).
    static let resolvingCaption = "Finding route\u{2026}"
    /// The honest settled-failure line. Deliberately "right now": the store retries
    /// on `fallbackRetryCooldown`, so this is not a permanent verdict and must not
    /// read like one — and deliberately not an error, a spinner or a retry button,
    /// because a rider cannot act on it and something is already re-asking.
    static let unavailableCaption = "Can't find a route right now"

    /// What the map says while it is not drawing a line. `nil` for ``road`` — the
    /// whole reason every existing capture is unchanged.
    var caption: String? {
        switch self {
        case .road: return nil
        case .resolving: return Self.resolvingCaption
        case .unavailable: return Self.unavailableCaption
        }
    }
}

// MARK: - MYR-390 — the etch's memory belongs to the ROUTE, not to a mounted view
//
// r15 clip: on the destination-selected search sheet the route is fully etched
// and breathing; tapping "Continue" to the "Schedule with Lunar" sheet made the
// drawn route VANISH for ~0.5s and then replay its 1.6s etch from zero. Same
// trip, same camera, same 248-point polyline — the map's own `onChange(of:
// replayKey)` snapped `etchProgress` back to 0 and put the presentation back in
// `.etching`, whose map content is `EmptyMapContent()`. The route fact was never
// touched: the VIEW forgot.
//
// A pass that must happen "once per route" cannot remember that inside the view
// that draws it, because a step transition re-runs that view's whole lifecycle.
// The memory moves next to the fact it is about.

/// Identity of a drawn route, for the purpose of "has this already been etched?".
///
/// **The two ENDPOINTS, and deliberately not the point count.** MYR-237's
/// `routeKey` (which still drives the camera re-fit and the pass restart) leads
/// with `route.count`, and that is correct for *"the geometry under me changed"*
/// — the straight `[pickup, destination]` placeholder being replaced by 248
/// points of road is a real change and must re-fit and re-draw. It is the wrong
/// key for *"is this the same trip"*: a refetch that returns one more vertex is
/// the same trip, and keying the etch memory on the count would replay the whole
/// pass over it.
///
/// Quantized to 1e-6 degrees (~0.1 m) so a float round-trip through a cache
/// cannot mint a second identity for one route. The endpoints are the pickup
/// anchor and the destination, which is exactly what MYR-389's
/// `previewPickupAnchor` exists to hold still against a jittering GPS fix — a
/// live coordinate must never reach this (MYR-237's standing trap).
struct RouteEtchIdentity: Hashable, Sendable {
    private let key: String

    /// `nil` for anything that cannot be drawn as a line — a route with fewer
    /// than two points has no etch to remember.
    init?(_ route: [CLLocationCoordinate2D]) {
        guard route.count > 1, let first = route.first, let last = route.last else { return nil }
        key = String(
            format: "%.6f,%.6f|%.6f,%.6f",
            first.latitude, first.longitude, last.latitude, last.longitude
        )
    }
}

/// How far the etch has got, per route identity — the state MYR-237 kept in
/// `RideRequestRouteMap.etchProgress` alone.
///
/// Deliberately **not** `@Observable`: nothing renders from it directly. It is
/// read once, inside `restartPresentation()`, at the moment the presentation is
/// decided; an observable ledger would invalidate the very view whose animation
/// it is recording. It is a plain reference type so the route map can write into
/// the instance the state owns without a binding.
@MainActor
final class RouteEtchLedger {
    private var progressByRoute: [RouteEtchIdentity: Double] = [:]

    init() {}

    /// 0 for a route this ledger has never seen — which is what makes a genuinely
    /// new trip etch from zero without anyone deciding that it should.
    func progress(for identity: RouteEtchIdentity?) -> Double {
        guard let identity else { return 0 }
        return progressByRoute[identity] ?? 0
    }

    /// MONOTONIC: an etch that was interrupted half-way can only ever be topped
    /// up by a later pass, never rewound by one. Without that, a restart landing
    /// while a completed route was still crossfading could record its own 0 over
    /// the 1 that is already true on screen.
    func record(_ identity: RouteEtchIdentity?, progress: Double) {
        guard let identity, progress.isFinite else { return }
        let clamped = min(1, max(0, progress))
        progressByRoute[identity] = max(progressByRoute[identity] ?? 0, clamped)
    }

    /// The draft trip ended (MYR-389's `discardDraftTrip`). A rider who walked
    /// away and started again is starting a NEW trip even if they retype the same
    /// destination, and a new trip etches.
    func forget() { progressByRoute.removeAll() }
}

/// How a route preview should OPEN, as one pure function of four facts.
///
/// This is the rule the MYR-390 defect broke, written where it can be asserted:
/// `RideRequestRouteMap` used to derive it inline and then let a `replayKey`
/// `onChange` overwrite the answer on every sheet transition. Both halves are
/// now this expression, so a step flip and a first arrival ask exactly the same
/// question and can only ever disagree about the ANSWER — `etchedProgress`.
enum RouteEtchPresentation {
    /// The four ways a preview can open. `.settling` is not here on purpose: it
    /// is a stage the etch pass drives itself into, never a state a route can be
    /// re-entered at.
    enum Opening: Equatable {
        /// No real road route yet — breathe the head at the pickup, draw no line.
        case loading
        /// Play the 1.6s pass from `progress`.
        case etching
        /// Already etched: the settled route is drawn IMMEDIATELY and only the
        /// whole-line breathing glow starts. This is the arm the defect could not
        /// reach.
        case pulsing
        /// Static map-space route, no motion (Booking, Summary, Reduce Motion).
        case settled
        /// MYR-395 — no line AND no motion.
        ///
        /// Two situations land here and both were previously wrong:
        /// • A surface that does not etch (Booking, Summary, Reduce Motion) with
        ///   no road geometry. It used to fall through to ``settled``, whose whole
        ///   job is to draw the line WHOLE — so the straight `[pickup,
        ///   destination]` fallback rendered on the Booking sheet as a 949-mile
        ///   gold line across five states. ``loading`` would be the other wrong
        ///   answer: Booking is deliberately static and Reduce Motion is a promise.
        /// • ANY surface whose fetch has ANSWERED and not with a route. ``loading``
        ///   breathes the etch head as a working cue, and nothing is working — that
        ///   is the client's own frame, a map that looked busy forever.
        case lineless

        /// Whether this opening puts the WHOLE line on screen. The MYR-395
        /// invariant is stated against this rather than against a case list, so a
        /// future opening has to answer the question rather than be forgotten by
        /// a test that enumerates two names.
        var drawsWholeLine: Bool {
            switch self {
            case .pulsing, .settled: return true
            case .loading, .etching, .lineless: return false
            }
        }
    }

    struct Resolution: Equatable {
        let opening: Opening
        /// What the overlay's trim should read the instant it mounts.
        let progress: Double
    }

    /// - Parameters:
    ///   - availability: MYR-395 — what the surface knows about its geometry.
    ///     This REPLACES the `isRealRoute: Bool` MYR-390 took. The bool could not
    ///     tell the two lineless states apart, so the one that had already failed
    ///     kept breathing MYR-237's "working" head at the pickup — which is
    ///     precisely the frame the client read as a broken map.
    ///   - etchedProgress: this route identity's entry in the `RouteEtchLedger` —
    ///     0 for a route nobody has drawn yet.
    static func resolve(
        etch: Bool,
        reduceMotion: Bool,
        availability: RideRouteAvailability,
        etchedProgress: Double
    ) -> Resolution {
        let settled = min(1, max(0, etchedProgress.isFinite ? etchedProgress : 0))
        // MYR-395 — GEOMETRY IS ASKED ABOUT FIRST, AND THE ORDER IS HALF THE FIX.
        //
        // MYR-390 asked second, below the `etch` guard, which reads as harmless:
        // "a straight fallback is never etched". But the arm above it does not
        // etch either — it draws the line WHOLE — so `etch: false` skipped the
        // question altogether and Booking rendered the provider's straight
        // `[pickup, destination]` fallback as a gold route across five states
        // (reproduced: `MRT_SCENE=booking MRT_ROUTE_UNAVAILABLE=1`). Reduce Motion
        // took that same arm, so the no-straight-lines rule was also off for every
        // rider who turns motion down. **A guard placed below one of the two
        // branches it is about only guards one of them.**
        switch availability {
        case .resolving:
            // A fetch is genuinely running. An etching surface breathes MYR-237's
            // head where the laser will start; a static one holds still. Neither
            // draws a line.
            return Resolution(opening: etch && !reduceMotion ? .loading : .lineless, progress: 0)
        case .unavailable:
            // The fetch ANSWERED, and not with a route. Nothing is in flight, so
            // nothing may look busy — on ANY surface, whatever its motion setting.
            // The caller states this in words (`RideRouteAvailability.caption`);
            // the map's job is to stop pretending.
            return Resolution(opening: .lineless, progress: 0)
        case .road:
            break
        }
        // Booking / Summary / Reduce Motion: the map-space route is drawn whole
        // and nothing animates. It is FULLY DRAWN either way, so a static
        // presentation arriving over a finished etch is seamless.
        guard etch, !reduceMotion else { return Resolution(opening: .settled, progress: settled) }
        // MYR-390: this route has already been etched, so it opens drawn.
        guard settled < 1 else { return Resolution(opening: .pulsing, progress: 1) }
        return Resolution(opening: .etching, progress: 0)
    }
}

// MARK: - Route geometry (pure, unit-tested — MYR-177 deviation logic)

enum RideRouteGeometry {
    /// Planar (Mercator-meters) distance from `point` to segment `a`–`b`.
    static func distanceMeters(from point: CLLocationCoordinate2D, segmentStart a: CLLocationCoordinate2D, segmentEnd b: CLLocationCoordinate2D) -> Double {
        let p = MKMapPoint(point), pa = MKMapPoint(a), pb = MKMapPoint(b)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return pa.distance(to: p) }
        // Projection parameter of p onto the segment, clamped to the segment;
        // `MKMapPoint.distance` returns meters directly.
        var t = ((p.x - pa.x) * dx + (p.y - pa.y) * dy) / lenSq
        t = min(1, max(0, t))
        let proj = MKMapPoint(x: pa.x + t * dx, y: pa.y + t * dy)
        return proj.distance(to: p)
    }

    /// Shortest distance (meters) from `point` to the polyline. `.infinity`
    /// for an empty polyline, the point-distance for a single vertex.
    static func distanceFromPolyline(_ point: CLLocationCoordinate2D, polyline: [CLLocationCoordinate2D]) -> Double {
        guard let first = polyline.first else { return .infinity }
        guard polyline.count > 1 else { return MKMapPoint(point).distance(to: MKMapPoint(first)) }
        var best = Double.infinity
        for i in 0..<(polyline.count - 1) {
            best = min(best, distanceMeters(from: point, segmentStart: polyline[i], segmentEnd: polyline[i + 1]))
        }
        return best
    }

    /// Whether the leg-1 route (car → pickup) must be refetched: the car has
    /// strayed farther than `thresholdMeters` from the cached polyline (took a
    /// different road). Distance-from-polyline, never a timer (MYR-177).
    static func shouldRefetch(carPosition: CLLocationCoordinate2D, cachedRoute: [CLLocationCoordinate2D], thresholdMeters: Double) -> Bool {
        guard !cachedRoute.isEmpty else { return true }
        return distanceFromPolyline(carPosition, polyline: cachedRoute) > thresholdMeters
    }
}

// MARK: - RideRouteStore (MYR-177 — per-leg cache + deviation-driven refresh)
//
// Owns the two leg polylines for one active ride. Pickup and destination are
// FIXED per ride, so leg 2 (pickup → destination) is fetched exactly once. The
// car origin moves, so leg 1 (car → pickup) is fetched on entry and refetched
// ONLY when the car deviates materially from the cached route
// (`RideRouteGeometry.shouldRefetch`) — never per fix. Straight-line fallback
// is inherited from the provider. Injected (sim = straight-line, live = Apple),
// so tests script it with no network.
@Observable
@MainActor
final class RideRouteStore {
    /// Car → pickup (leg 1). Empty until the first fetch resolves.
    private(set) var leg1: [CLLocationCoordinate2D] = []
    /// Pickup → destination (leg 2). Empty until the first fetch resolves.
    private(set) var leg2: [CLLocationCoordinate2D] = []

    @ObservationIgnored private let provider: RideRouteProvider
    @ObservationIgnored private let deviationThresholdMeters: Double
    @ObservationIgnored private var leg2Key: String?
    /// When the last leg-2 fetch for `leg2Key` STARTED — the retry cooldown
    /// clock for a fallback (2-point) result (MYR-237: a throttled MKDirections
    /// must not lock the straight fallback in forever).
    @ObservationIgnored private var leg2AttemptAt: Date?
    @ObservationIgnored private var leg1Origin: CLLocationCoordinate2D?
    /// The PICKUP the cached `leg1` was fetched against (MYR-293). Leg 1's origin
    /// moves with the car, so the pair key `leg2` uses would never match; its
    /// identity is the destination alone. Without it a dispatch handed to a
    /// different pickup would keep drawing the previous ride's road geometry —
    /// real road geometry, to the wrong place, which is worse than a straight line.
    @ObservationIgnored private var leg1Pickup: String?
    /// When the last leg-1 attempt for `leg1Pickup` STARTED — the same fallback
    /// retry clock `leg2AttemptAt` is (MYR-293). Leg 1 could previously rely on
    /// the car's own deviation to force a retry, but a car driving straight down
    /// the fallback line never deviates from it, so a throttled first fetch left
    /// the owner map with pins and nothing to bring the route back.
    @ObservationIgnored private var leg1AttemptAt: Date?
    @ObservationIgnored private var leg1Task: Task<Void, Never>?
    @ObservationIgnored private var leg2Task: Task<Void, Never>?

    /// The cooldown THIS store applies before re-asking for a leg whose last
    /// answer was the straight fallback. Defaults to `fallbackRetryCooldown`;
    /// injectable so tests can exercise the retry without an 8-second sleep —
    /// the same reason `deviationThresholdMeters` is a parameter.
    @ObservationIgnored private let retryCooldown: TimeInterval

    init(
        provider: RideRouteProvider,
        deviationThresholdMeters: Double = MRTMetrics.rideRouteDeviationThresholdMeters,
        fallbackRetryCooldown: TimeInterval = RideRouteStore.fallbackRetryCooldown
    ) {
        self.provider = provider
        self.deviationThresholdMeters = deviationThresholdMeters
        self.retryCooldown = fallbackRetryCooldown
    }

    private static func key(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f|%.6f,%.6f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Fetch the pickup → destination route ONCE per (pickup, destination) pair
    /// (both are fixed for the ride). Cheap to call on every fix — a no-op once
    /// the pair is cached. Needed in BOTH legs (drawn dimmed in leg 1, solid in
    /// leg 2), so the caller reconciles it in either leg.
    /// Retry cooldown for a fallback leg-2 result (throttled/failed
    /// MKDirections): a repeat `ensureLeg2` for the SAME pair refetches after
    /// this long, so the straight fallback is never permanent (MYR-237).
    static let fallbackRetryCooldown: TimeInterval = 8

    func ensureLeg2(pickup: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) {
        let l2Key = Self.key(pickup, destination)
        if leg2Key == l2Key {
            // Same pair: done if a REAL route is cached or a fetch is running;
            // a cached 2-point fallback retries after the cooldown.
            guard leg2Task == nil, leg2.count <= 2 else { return }
            if let last = leg2AttemptAt, Date().timeIntervalSince(last) < retryCooldown { return }
        }
        leg2Key = l2Key
        leg2AttemptAt = Date()
        leg2Task?.cancel()
        leg2Task = Task { [weak self, provider] in
            let route = await provider.route(from: pickup, to: destination)
            guard !Task.isCancelled else { return }
            self?.leg2 = route
            self?.leg2Task = nil
        }
    }

    /// (Re)fetch the car → pickup route on first entry or a MATERIAL deviation
    /// (the car took a different road — `RideRouteGeometry.shouldRefetch`),
    /// never on a timer. Called only while heading to pickup (leg 1).
    ///
    /// MYR-293 adds the two guards leg 2 already had. (1) A NEW PICKUP drops the
    /// cached polyline immediately, so nothing can render a prior ride's route
    /// under a new destination while the refetch is in flight. (2) A cached
    /// 2-POINT fallback — MKDirections throttled, offline, or failed — retries
    /// after `fallbackRetryCooldown`, because the caller now draws NOTHING for a
    /// fallback (the client's no-straight-lines rule) and deviation alone cannot
    /// be relied on to bring the route back: a car following the fallback line
    /// never strays from it.
    func ensureLeg1(carPosition: CLLocationCoordinate2D, pickup: CLLocationCoordinate2D) {
        let key = Self.key(pickup, pickup)
        if leg1Pickup != key {
            // A different pickup entirely: this cache is about another ride.
            leg1Task?.cancel(); leg1Task = nil
            leg1 = []
            leg1Pickup = key
            leg1AttemptAt = nil
        }
        let deviated = !leg1.isEmpty
            && RideRouteGeometry.shouldRefetch(carPosition: carPosition, cachedRoute: leg1, thresholdMeters: deviationThresholdMeters)
        // A cached fallback is not a route — retry it on the cooldown, exactly as
        // `ensureLeg2` does for the same shape of result.
        let retriesFallback = !leg1.isEmpty
            && !RideRoutePolyline.isReal(leg1)
            && (leg1AttemptAt.map { Date().timeIntervalSince($0) >= retryCooldown } ?? true)
        guard leg1.isEmpty || deviated || retriesFallback, leg1Task == nil else { return }
        leg1Origin = carPosition
        leg1AttemptAt = Date()
        leg1Task = Task { [weak self, provider] in
            let route = await provider.route(from: carPosition, to: pickup)
            guard !Task.isCancelled else { return }
            self?.leg1 = route
            self?.leg1Task = nil
        }
    }

    /// The car → pickup polyline IFF it is currently cached for EXACTLY this
    /// pickup (else `nil`) — the leg-1 twin of ``leg2Route(pickup:destination:)``,
    /// and for the same reason: the store outlives one ride, so a caller must be
    /// able to tell "no route yet" from "a route to somewhere else". Returns the
    /// straight fallback too; the caller decides whether it is real enough to draw
    /// (`RideRoutePolyline`).
    func leg1Route(pickup: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        guard leg1Pickup == Self.key(pickup, pickup), leg1.count > 1 else { return nil }
        return leg1
    }

    /// The pickup → destination polyline IFF it is currently cached for EXACTLY
    /// this pair (else `nil`). Matches on the same requested-coordinate key
    /// `ensureLeg2` fetches by — no snapping tolerance — so a caller (the MYR-237
    /// review etch) can avoid drawing a STALE prior-trip route under a new
    /// pickup/destination while the new fetch is still in flight (the store only
    /// `reset()`s on Tracking exit, so `leg2` can hold a previous trip's polyline
    /// across a "Change trip"). Returns the straight `[from, to]` fallback too
    /// (the provider's honest degradation) — the caller decides whether a
    /// 2-point route is "real" enough to etch.
    func leg2Route(pickup: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        guard leg2Key == Self.key(pickup, destination), leg2.count > 1 else { return nil }
        return leg2
    }

    /// Drop all cached routes and cancel in-flight fetches (ride ended / screen
    /// released).
    func reset() {
        leg1Task?.cancel(); leg1Task = nil
        leg2Task?.cancel(); leg2Task = nil
        leg1 = []; leg2 = []
        leg1Origin = nil; leg1Pickup = nil; leg1AttemptAt = nil
        leg2Key = nil; leg2AttemptAt = nil
    }
}
