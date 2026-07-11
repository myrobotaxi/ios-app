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
    @ObservationIgnored private var leg1Origin: CLLocationCoordinate2D?
    @ObservationIgnored private var leg1Task: Task<Void, Never>?
    @ObservationIgnored private var leg2Task: Task<Void, Never>?

    init(provider: RideRouteProvider, deviationThresholdMeters: Double = MRTMetrics.rideRouteDeviationThresholdMeters) {
        self.provider = provider
        self.deviationThresholdMeters = deviationThresholdMeters
    }

    private static func key(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f|%.6f,%.6f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Fetch the pickup → destination route ONCE per (pickup, destination) pair
    /// (both are fixed for the ride). Cheap to call on every fix — a no-op once
    /// the pair is cached. Needed in BOTH legs (drawn dimmed in leg 1, solid in
    /// leg 2), so the caller reconciles it in either leg.
    func ensureLeg2(pickup: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) {
        let l2Key = Self.key(pickup, destination)
        guard leg2Key != l2Key else { return }
        leg2Key = l2Key
        leg2Task?.cancel()
        leg2Task = Task { [weak self, provider] in
            let route = await provider.route(from: pickup, to: destination)
            guard !Task.isCancelled else { return }
            self?.leg2 = route
        }
    }

    /// (Re)fetch the car → pickup route on first entry or a MATERIAL deviation
    /// (the car took a different road — `RideRouteGeometry.shouldRefetch`),
    /// never on a timer. Called only while heading to pickup (leg 1).
    func ensureLeg1(carPosition: CLLocationCoordinate2D, pickup: CLLocationCoordinate2D) {
        let needsLeg1 = leg1.isEmpty
            || RideRouteGeometry.shouldRefetch(carPosition: carPosition, cachedRoute: leg1, thresholdMeters: deviationThresholdMeters)
        guard needsLeg1, leg1Task == nil else { return }
        leg1Origin = carPosition
        leg1Task = Task { [weak self, provider] in
            let route = await provider.route(from: carPosition, to: pickup)
            guard !Task.isCancelled else { return }
            self?.leg1 = route
            self?.leg1Task = nil
        }
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
        leg1Origin = nil; leg2Key = nil
    }
}
