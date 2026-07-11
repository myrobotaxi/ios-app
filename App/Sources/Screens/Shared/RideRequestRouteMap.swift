import SwiftUI
import MapKit
import DesignSystem

// MARK: - RideRequestRouteMap (MYR-171)
//
// Small satellite `Map` for the ride-request flow's Review/Booking/Tracking/
// Summary phases. `VehicleMapView` (MYR-167) has no content-injection seam
// and is scoped to `SharedViewerState.vehicle`'s own telemetry — not the
// fleet member + pickup/destination pair the rider is actively requesting —
// so this is its own small `Map` rather than a fork of that file (CLAUDE.md
// "Reuse, don't fork": the pieces reused below are `MapPolyline`/
// `Annotation`/`MRTEndpointDot`/`VehicleRoute`, the same primitives
// `ScheduledRideSheet`'s `RideRouteMap` already uses for its own preview
// map, not `VehicleMapView` itself).
struct RideRequestRouteMap: View {
    let route: [CLLocationCoordinate2D]
    /// `nil` — Review/Booking: draw the full route solid gold (no live trip
    /// yet, matches ride-request.jsx's static review/pending route line).
    /// `0...1` — Tracking/Summary: split into travelled (bright) vs. full
    /// dim, per `RouteLine`'s recipe (Packages/DesignSystem RouteLine.swift).
    var progress: Double?
    /// Draws a moving marker at `progress` along the route — Tracking only.
    var showVehicle: Bool = false
    /// MYR-216 deliverable 4: points the phase's bottom sheet covers (+ margin).
    /// The route camera fits the route into the UNOBSTRUCTED area above the sheet
    /// so both endpoints + the full polyline clear it. `0` (default) keeps the
    /// plain full-frame fit for non-inset callers.
    ///
    /// MYR-223 deliverable 2: this same value ALSO drives `.safeAreaPadding
    /// (.bottom:)`, so MapKit's legally-required attribution/legal label sits
    /// just above the sheet instead of hidden behind it (parity with
    /// `VehicleMapView`'s idle/search/pin-drop map). `safeAreaPadding` repositions
    /// only the map ornaments — it does NOT reframe the camera (the route fit is
    /// still the `position` region above) — so the polyline framing is
    /// unchanged; only the attribution moves.
    var bottomInset: CGFloat = 0
    /// MYR-237 — when a REAL Apple Maps route (many points) is present and Reduce
    /// Motion is off, the gold polyline is LASER-ETCHED on: a hot white-gold
    /// leading head (the CTA outline-draw's brightest trace stop `mrtGoldTraceBright`
    /// cored with `mrtGoldTrace` and a wide `mrtGoldGlow` bloom — the SAME
    /// gold-trace stroke the "Request {Car}" button animates) travels pickup →
    /// destination, drawing onto the bare map and leaving the settled gold route
    /// behind it. Off (default) — Booking/Summary — the route renders
    /// settled/static, unchanged. The straight `[pickup, destination]` fallback
    /// (2 points) is never etched.
    var etch: Bool = false
    /// MYR-237 — the real route is still being fetched from MKDirections (the
    /// caller's leg-2 cache is empty for this pickup/destination). While true the
    /// map draws NO line (client: "straight line should not be the loading
    /// placeholder") — just the etch head's glow breathing at the pickup as the
    /// working cue; when the real route lands the etch draws it. Ignored unless
    /// `etch` is set.
    var loading: Bool = false
    /// MYR-237 — identity of the PAGE hosting this preview (the sheet phase).
    /// When it changes (Search → Review, Review → back to Search, …) the etch
    /// REPLAYS (client: "if I leave a page and came back we should re-draw the
    /// line with the etch"), with the camera re-fit written instantly first.
    var replayKey: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: MYR-237 etch mechanics
    //
    // WHY A SCREEN-SPACE OVERLAY: two rounds tried to animate the etch by
    // re-evaluating the `Map`'s own content per frame (KeyframeAnimator, then a
    // TimelineView clock). MapKit's SwiftUI bridge COALESCES content updates, so
    // the per-frame `MapPolyline` prefixes never rendered as motion — the route
    // "just popped in" (client-confirmed, twice). The etch therefore does not
    // touch map content at all: it draws in a plain SwiftUI overlay `Shape`
    // whose trim endpoints are `animatableData` — interpolated by the render
    // loop at full frame rate, immune to Map content coalescing. The map is
    // non-interactive (`interactionModes: []`) and this view is the camera's
    /// only writer, so the screen-space projection cannot be invalidated by a
    // gesture mid-etch; the camera is written with animations DISABLED before a
    // pass arms, so the projection is taken from a settled frame.
    //
    // The settled route (and everything outside the 1.6s pass) stays in MAP
    // space (`MapPolyline`), so nothing ever drifts off the roads afterwards.

    /// Etch pace: ~1.6s ease-in-out — sleek, sub-2s, per the client's "roughly
    /// the CTA outline's pace". Runs once per route arrival; replays on route
    /// change ("Change trip"). DEBUG-only `MRT_ETCH_SECONDS` slows the trace for
    /// drift-gate captures; never compiled into Release.
    private static var etchDuration: TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MRT_ETCH_SECONDS"],
           let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        return 1.6
    }
    /// The bright leading head's length as a fraction of the total route length.
    /// SHORT on purpose — a laser tip, not a crawling body (client: "it
    /// shouldn't etch like a snake, it should etch like a bright laser head").
    private static let etchHeadFraction: CGFloat = 0.05
    /// The overlay → settled-map crossfade once the pass completes.
    private static let settleFade: TimeInterval = 0.25
    /// The settled-route SHINE loop (client: "the route should pulse the same
    /// shine/glow as the etch laser head and the Request from {Owner} button
    /// outline animation glow"): one bright window travels the route per
    /// period — 2.6s, the EXACT loop period of the CTA `MRTTraceBorder` conic
    /// trace, with the same trace stops. Runs only while the Review screen's
    /// etch presentation is active; Booking/Summary stay static.
    private static let pulsePeriod: TimeInterval = 2.6

    /// How the route is presented right now. `.etching`/`.pulsing` draw the
    /// motion in screen space; everything else is plain map-space content.
    private enum RoutePhase: Equatable {
        case loading      // straight placeholder + sweeping pulse overlay
        case etching      // screen-space animated etch pass
        case settling     // etch done: overlay trail crossfading into the map route
        case pulsing      // settled map route + whole-line breathing glow
        case settled      // map-space settled gold route, no motion
    }

    @State private var phase: RoutePhase = .settled
    /// The single animated value: the etch head's position along the route.
    /// Driven 0 → 1 by `withAnimation`; the overlay shapes interpolate their
    /// trim endpoints from it (never sampled in body mid-flight).
    @State private var etchProgress: CGFloat = 0
    /// The settled route's whole-line breathing glow intensity (0.15 ⇄ 1,
    /// autoreversing — "pulse glow all as one").
    @State private var glowPulse: CGFloat = 0.15
    /// Bumped per pass so the `.task(id:)` driving a pass restarts cleanly on
    /// route change and cancels on disappear.
    @State private var etchRun = 0
    /// The overlay's fade-out at the end of the pass (crossfade to map-space).
    @State private var overlayOpacity: Double = 1
    /// Bumped on every map camera-change event so the overlay's screen-space
    /// projection re-evaluates — a late camera commit can never leave the
    /// trace projected from a stale frame (the v2 displaced-etch bug).
    @State private var projectionEpoch = 0
    /// The camera — a real `position` binding (not `initialPosition`) so a new
    /// route's fit replaces the straight placeholder's without remounting the
    /// map. This view is the binding's ONLY writer and the map is
    /// non-interactive (`interactionModes: []`), so the single-camera-owner
    /// discipline holds — no other writer exists for this map instance.
    @State private var camera: MapCameraPosition = .automatic

    /// A REAL MKDirections route (many road points) vs. the straight
    /// `[pickup, destination]` fallback/placeholder (exactly 2). Only a real
    /// route etches.
    private var isRealRoute: Bool { route.count > 2 }

    /// Identity of the current route — re-fits + replays the etch when it
    /// changes (the real route arriving, or a new trip via "Change trip").
    private var routeKey: String {
        guard let first = route.first, let last = route.last else { return "empty" }
        return "\(route.count)|\(first.latitude),\(first.longitude)|\(last.latitude),\(last.longitude)"
    }

    var body: some View {
        // The fit needs the map's height to know what fraction the sheet covers
        // (MYR-216 d4). `GeometryReader` reports the full-bleed height (the
        // caller applies `.ignoresSafeArea()`). `MapReader` supplies the
        // map-space → screen-space projection for the etch overlay.
        GeometryReader { geo in
            MapReader { proxy in
                Map(position: $camera, interactionModes: []) {
                    // Suppresses MapKit's own auto-drawn "Origin"/"Destination"
                    // title labels — see `VehicleMapView`'s identical call
                    // (MYR-167 review finding #3).
                    mapContent.annotationTitles(.hidden)
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                // MYR-223 d2: keep the MapKit attribution just above the phase's
                // bottom chrome (same mechanism as `VehicleMapView`). No-op when
                // `bottomInset` is 0 (the Summary full-screen takeover).
                //
                // MYR-237 fit fix (the MYR-212 trap, again): under
                // `.safeAreaPadding` MapKit ALREADY fits a `.region` camera into
                // the UNOBSTRUCTED band — so the old `insetRegion` span-grow/
                // south-shift double-compensated for the sheet and the route
                // rendered half-size and high. The sheet (bottom) AND the
                // status-bar strip (top) are both expressed as safe-area padding
                // here, and the camera gets a PLAIN padded fit below.
                .safeAreaPadding(.bottom, bottomInset)
                .safeAreaPadding(.top, bottomInset > 0 ? MRTMetrics.trackingFitTopInset : 0)
                .preferredColorScheme(.dark)
                .allowsHitTesting(false)
                .overlay { routeOverlay(proxy: proxy) }
            }
            .onAppear {
                camera = .region(fittedRegion(height: geo.size.height))
                restartPresentation()
            }
            .onChange(of: routeKey) { _, _ in
                // The real route arrived (straight → road geometry) or the trip
                // changed. The camera fit is written with animations DISABLED so
                // the etch overlay projects from a settled frame — a mid-glide
                // projection would draw the trace displaced from the roads.
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    camera = .region(fittedRegion(height: geo.size.height))
                }
                restartPresentation()
            }
            .onMapCameraChange(frequency: .continuous) { _ in
                projectionEpoch &+= 1
            }
            .onChange(of: replayKey) { _, _ in
                // A page change under the same route (Search → Review → back):
                // re-fit for the new sheet inset instantly, then REPLAY the
                // presentation (etch again on etch pages, settle on Booking).
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    camera = .region(fittedRegion(height: geo.size.height))
                }
                restartPresentation()
            }
            .task(id: etchRun) { await runPass() }
        }
    }

    /// The camera fit for the current route. Review/Booking (`bottomInset > 0`)
    /// use the tracking map's snug padding (`trackingLegFitPadding`) and a PLAIN
    /// region — the sheet + status-bar band are expressed as safe-area padding on
    /// the map, and MapKit fits a `.region` camera into the unobstructed band
    /// natively (MYR-212 semantics; adding `insetRegion` on top of that
    /// double-compensates and shrinks the route — the first cut's wrong fit).
    /// Summary (`bottomInset == 0`) keeps the legacy full-frame hero fit,
    /// byte-identical.
    private func fittedRegion(height: CGFloat) -> MKCoordinateRegion {
        if bottomInset > 0 {
            return VehicleRoute.fittedRegion(
                for: route,
                paddingFactor: MRTMetrics.trackingLegFitPadding
            )
        }
        return VehicleRoute.fittedRegion(
            for: route, paddingFactor: 1.7, bottomInset: bottomInset, viewHeight: height
        )
    }

    // MARK: Pass lifecycle

    /// Decide the presentation for the CURRENT route and (re)start its pass.
    private func restartPresentation() {
        etchProgress = 0
        overlayOpacity = 1
        glowPulse = 0
        if etch, !reduceMotion, isRealRoute {
            phase = .etching
        } else if etch, !reduceMotion {
            // No real road route yet — in flight, throttled, or failed. NEVER
            // draw the straight fallback in etch mode (client rule): breathe
            // the head at the pickup until the caller's retry lands a route.
            phase = .loading
        } else {
            phase = .settled
        }
        etchRun += 1
    }

    /// Drives one pass for the current phase. Runs under `.task(id: etchRun)`,
    /// so a route change restarts it and disappearing cancels it.
    private func runPass() async {
        switch phase {
        case .settled:
            return
        case .loading:
            // Two frames so the projection is on screen before the breathing
            // arms (animating a value set in the same transaction as its first
            // render can skip the animation).
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled, phase == .loading else { return }
            withAnimation(.easeInOut(duration: Self.pulsePeriod / 2).repeatForever(autoreverses: true)) {
                glowPulse = 1
            }
        case .etching:
            // Two frames for the (animation-disabled) camera write to land so
            // the overlay projects from the settled frame.
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled, phase == .etching else { return }
            withAnimation(.easeInOut(duration: Self.etchDuration)) {
                etchProgress = 1
            }
            try? await Task.sleep(for: .seconds(Self.etchDuration))
            guard !Task.isCancelled, phase == .etching else { return }
            // SMOOTH handoff (client: "the pulsing should ease in smoothly
            // not blocky/glitchy or harsh"): (1) crossfade the fully drawn
            // overlay trail (head bloom included) into the identical map-space
            // settled route beneath it, then (2) begin the whole-line breathing
            // glow FROM ZERO so the first breath eases in from nothing.
            phase = .settling
            withAnimation(.easeOut(duration: Self.settleFade)) {
                overlayOpacity = 0
            }
            try? await Task.sleep(for: .seconds(Self.settleFade))
            guard !Task.isCancelled, phase == .settling else { return }
            phase = .pulsing
            overlayOpacity = 1
            glowPulse = 0
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled, phase == .pulsing else { return }
            withAnimation(.easeInOut(duration: Self.pulsePeriod / 2).repeatForever(autoreverses: true)) {
                glowPulse = 1
            }
        case .settling, .pulsing:
            // Reached only via `.etching` above (restartPresentation never
            // starts here); the sequence is already driving itself.
            return
        }
    }

    // MARK: Map-space content (everything except the 1.6s etch pass)

    @MapContentBuilder
    private var mapContent: some MapContent {
        if route.count > 1 {
            if let progress {
                // Tracking/Summary travelled-vs-full split (MYR-171) — unchanged.
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtGold.opacity(0.3), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                let travelled = VehicleRoute.travelledCoordinates(along: route, progress: progress)
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            } else {
                switch phase {
                case .etching:
                    // The screen-space overlay owns the visuals for the pass;
                    // drawing the map-space route too would pre-reveal it.
                    EmptyMapContent()
                case .loading:
                    // NO line while the route is in flight (client rule); the
                    // overlay breathes the etch head at the pickup instead.
                    EmptyMapContent()
                case .settling, .pulsing, .settled:
                    // Settled solid route: the etch's final state (with the
                    // shine loop above it in `.pulsing`), Booking's static real
                    // route, Summary, Reduce-Motion static settle, and the
                    // straight fallback.
                    MapPolyline(coordinates: route)
                        .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: route)
                        .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        if let origin = route.first {
            Annotation("Origin", coordinate: origin) { MRTEndpointDot(color: .mrtDriving, size: 11) }
        }
        // MYR-237 (client): the destination dot appears only once the etch has
        // ARRIVED there — never before (`.loading`/`.etching` hide it; the
        // laser reaching the endpoint is the reveal). Tracking/Summary
        // (`progress != nil`) and every static presentation keep it always-on.
        if let destination = route.last, route.count > 1,
           progress != nil || phase == .pulsing || phase == .settled {
            Annotation("Destination", coordinate: destination) { EtchRevealDot() }
        }
        if showVehicle, let progress {
            let position = VehicleRoute.position(along: route, progress: progress)
            Annotation("Vehicle", coordinate: position.coordinate) {
                Circle()
                    .fill(Color.mrtGold)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.mrtText, lineWidth: 1.5))
                    .shadow(color: .mrtGoldGlow, radius: 6)
            }
        }
    }

    // MARK: Screen-space etch / sweep overlay

    /// The animated pass, drawn ABOVE the map in screen space. Projection goes
    /// through GLOBAL coordinates re-anchored to the overlay's own frame —
    /// `.local` under `.safeAreaPadding` resolves to the PADDED space and
    /// displaced the whole trace off the roads (v2 QA) — and is re-evaluated on
    /// every camera-change event (`projectionEpoch`) so it can never go stale
    /// against a late camera commit. A failed projection falls back to no
    /// overlay — the map-space settled route still renders, so degradation is
    /// honest, never blank.
    @ViewBuilder
    private func routeOverlay(proxy: MapProxy) -> some View {
        if phase != .settled, route.count > 1 {
            GeometryReader { overlayGeo in
                let origin = overlayGeo.frame(in: .global).origin
                let projected = route.compactMap { coordinate -> CGPoint? in
                    guard let g = proxy.convert(coordinate, to: .global) else { return nil }
                    let p = CGPoint(x: g.x - origin.x, y: g.y - origin.y)
                    return p.x.isFinite && p.y.isFinite ? p : nil
                }
                overlayLayers(points: projected)
            }
        }
    }

    @ViewBuilder
    private func overlayLayers(points: [CGPoint]) -> some View {
        // Reading `projectionEpoch` makes camera-change events re-evaluate the
        // projection WITHOUT changing view identity (an identity change would
        // interrupt an in-flight etch interpolation).
        let _ = projectionEpoch
        if points.count == route.count {
            Group {
                switch phase {
                case .etching, .settling:
                    // `.settling`: the finished trail (head included) fading out
                    // over the identical map-space settled route beneath it.
                    RouteEtchTrace(points: points, progress: etchProgress, headFraction: Self.etchHeadFraction)
                case .pulsing:
                    RouteGlowPulse(points: points, intensity: glowPulse)
                case .loading:
                    // The etch head, idling at the pickup, breathing while
                    // MKDirections works — no line yet.
                    HeadIdlePulse(points: points, intensity: glowPulse)
                case .settled:
                    EmptyView()
                }
            }
            .opacity(overlayOpacity)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - TrimmedPolylineShape — the animatable etch primitive (MYR-237)

/// A polyline in screen space, stroked only between the `from`…`to` fractions
/// of its length. BOTH endpoints are `animatableData`, so a `withAnimation`
/// that moves them renders as true frame-interpolated motion — this is the
/// mechanism that survives MapKit's content-update coalescing (see the
/// RideRequestRouteMap "WHY A SCREEN-SPACE OVERLAY" note). `Path.trimmedPath`
/// is arc-length parameterized (CAShapeLayer semantics), matching the
/// length-fraction contract pinned by RouteEtchGeometryTests.
struct TrimmedPolylineShape: Shape {
    var points: [CGPoint]
    var from: CGFloat
    var to: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(from, to) }
        set { from = newValue.first; to = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }
        var path = Path()
        path.addLines(points)
        // MYR-227 rule: clamp every animator-driven value finite before it
        // reaches geometry.
        let f = from.isFinite ? min(1, max(0, from)) : 0
        let t = to.isFinite ? min(1, max(0, to)) : 1
        guard t > f else { return Path() }
        return path.trimmedPath(from: f, to: t)
    }
}

/// A glowing HEAD DOT at a length-fraction along the polyline — the client's
/// reference look (a live-ticker chart head): a near-white hot point inside a
/// soft warm gold bloom. Implemented as an animatable `Shape` so the dot
/// travels ALONG the polyline as `progress` interpolates (a `.position`
/// modifier would cut straight across the map between body evaluations).
struct PolylineHeadDot: Shape {
    var points: [CGPoint]
    var progress: CGFloat
    var radius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = progress.isFinite ? min(1, max(0, progress)) : 1
        guard let center = Self.point(along: points, fraction: p) else { return Path() }
        guard center.x.isFinite, center.y.isFinite else { return Path() }
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// The point at `fraction` of the polyline's cumulative length (pure —
    /// pinned by RouteEtchGeometryTests).
    static func point(along points: [CGPoint], fraction: CGFloat) -> CGPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1, fraction > 0 else { return first }
        var lengths: [CGFloat] = [0]
        var total: CGFloat = 0
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x, dy = points[i].y - points[i - 1].y
            total += (dx * dx + dy * dy).squareRoot()
            lengths.append(total)
        }
        guard total > 0 else { return first }
        let target = min(1, max(0, fraction)) * total
        for i in 1..<points.count where lengths[i] >= target {
            let segment = lengths[i] - lengths[i - 1]
            let t = segment > 0 ? (target - lengths[i - 1]) / segment : 0
            return CGPoint(
                x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                y: points[i - 1].y + (points[i].y - points[i - 1].y) * t
            )
        }
        return points.last
    }
}

/// The etch pass: the settled gold route laid down behind a traveling GLOW
/// POINT (client reference: a live-ticker head — near-white hot dot in a soft
/// warm bloom; "a bright laser head", never a snake). One `progress` value
/// drives trail and head in lockstep through the same interpolation.
private struct RouteEtchTrace: View {
    let points: [CGPoint]
    var progress: CGFloat
    let headFraction: CGFloat

    var body: some View {
        ZStack {
            // The settled route left behind the head — identical strokes to
            // the map-space settled route so the handoff is seamless.
            TrimmedPolylineShape(points: points, from: 0, to: progress)
                .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            TrimmedPolylineShape(points: points, from: 0, to: progress)
                .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            // The glowing head point: wide soft bloom → tight glow → hot core.
            PolylineHeadDot(points: points, progress: progress, radius: 26)
                .fill(Color.mrtGold.opacity(0.35))
                .blur(radius: 16)
            PolylineHeadDot(points: points, progress: progress, radius: 11)
                .fill(Color.mrtGoldTrace.opacity(0.7))
                .blur(radius: 6)
            PolylineHeadDot(points: points, progress: progress, radius: 4.5)
                .fill(Color.mrtGoldTraceBright)
                .shadow(color: .mrtGoldTraceBright.opacity(0.9), radius: 3)
        }
    }
}

/// The destination endpoint, popping in as the etch's laser head arrives at it
/// (spring scale+fade) — its insertion is the etch-completion reveal. Static
/// presentations mount it already settled on first render (the pop plays only
/// when the annotation is inserted mid-scene, i.e. at etch completion).
private struct EtchRevealDot: View {
    @State private var shown = false

    var body: some View {
        MRTEndpointDot(color: .mrtGold, size: 13)
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    shown = true
                }
            }
    }
}

/// The settled route's whole-line breathing glow (client: "after the initial
/// etch the route line should just glow… pulse glow all as one"): the etch
/// head's warm bloom, applied to the ENTIRE route at once, breathing 0.15 ⇄ 1
/// on the CTA trace's 2.6s round trip. Sits above the map-space settled gold,
/// so at minimum intensity the route is simply the settled line.
private struct RouteGlowPulse: View {
    let points: [CGPoint]
    var intensity: CGFloat

    var body: some View {
        ZStack {
            TrimmedPolylineShape(points: points, from: 0, to: 1)
                .stroke(Color.mrtGold.opacity(0.5), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                .blur(radius: 9)
            TrimmedPolylineShape(points: points, from: 0, to: 1)
                .stroke(Color.mrtGoldTrace.opacity(0.75), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .blur(radius: 2.5)
            TrimmedPolylineShape(points: points, from: 0, to: 1)
                .stroke(Color.mrtGoldTraceBright.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .opacity(Double(intensity.isFinite ? min(1, max(0, intensity)) : 1))
    }
}

/// The etch head idling at the PICKUP while MKDirections is in flight — the
/// same glow point the etch travels with, breathing gently in place (no line
/// is drawn while loading; client rule). Uses `PolylineHeadDot` at fraction 0
/// so the loading cue and the etch head are literally the same mark.
private struct HeadIdlePulse: View {
    let points: [CGPoint]
    var intensity: CGFloat

    var body: some View {
        ZStack {
            PolylineHeadDot(points: points, progress: 0, radius: 20)
                .fill(Color.mrtGold.opacity(0.30))
                .blur(radius: 14)
            PolylineHeadDot(points: points, progress: 0, radius: 9)
                .fill(Color.mrtGoldTrace.opacity(0.65))
                .blur(radius: 5)
            PolylineHeadDot(points: points, progress: 0, radius: 3.5)
                .fill(Color.mrtGoldTraceBright)
        }
        .opacity(0.35 + 0.65 * Double(intensity.isFinite ? min(1, max(0, intensity)) : 1))
    }
}
