import SwiftUI
import MapKit
import CoreLocation
import UIKit
import DesignSystem

// MARK: - ExpandedRouteMap (MYR-327 — tap the map, look at the route)
//
// The client's ask (TestFlight, ADFCbiKq28): "Would be nice to click into the
// map and interact with the route by zoom in and out to look at it." Their
// screenshot is the Drive Summary hero — a 268pt band with
// `interactionModes: []` — so the route is visible but literally untouchable.
//
// This is the shared expanded surface both host maps push: a full-bleed
// interactive `Map` that renders EXACTLY the map content its host already
// draws (the host passes its own `@MapContentBuilder`, so there is one route/
// pin/marker recipe per surface, not a fork), fitted once to the route and
// then handed entirely to the user's fingers.
//
// CAMERA CONTRACT (MYR-222): on this surface the USER owns the camera. There
// are exactly TWO programmatic writes in the whole view's life —
//   1. the initial fit, written once on appear (`ExpandedRouteCamera.seat`),
//   2. an explicit recenter tap (`ExpandedRouteCamera.recenter`).
// Nothing else writes. In particular a streaming car fix / a route polyline
// arriving CANNOT re-fit the camera: `seat` returns `nil` forever after the
// first call, so the write count is bounded by 1 + (recenter taps) regardless
// of fix rate. That is what makes the MYR-222 loop class structurally
// impossible here rather than merely tuned away.

/// The expanded viewer's camera owner — the same ledger-based ownership
/// discipline as `TrackingCameraController`/`PinDropCameraController`, reduced
/// to the two writes this surface is allowed (see the contract above). Pure
/// enough to unit-test without mounting a map (`ExpandedRouteCameraTests`).
@MainActor
@Observable
final class ExpandedRouteCamera {

    enum Phase: Equatable {
        /// Nothing written yet — the initial fit has not been issued.
        case unseated
        /// The initial fit (or a recenter) is the camera's current framing.
        case fitted
        /// The user panned/pinched — we are a passenger until they recenter.
        case userControlled
    }

    struct Write: Equatable {
        var region: MKCoordinateRegion
        var animated: Bool

        static func == (lhs: Write, rhs: Write) -> Bool {
            lhs.animated == rhs.animated
                && lhs.region.center.latitude == rhs.region.center.latitude
                && lhs.region.center.longitude == rhs.region.center.longitude
                && lhs.region.span.latitudeDelta == rhs.region.span.latitudeDelta
                && lhs.region.span.longitudeDelta == rhs.region.span.longitudeDelta
        }
    }

    private(set) var phase: Phase = .unseated
    private var ledger = CameraSettleLedger()
    private let paddingFactor: Double
    /// The centre of our most recent write — see `cameraSettled`'s layout-churn
    /// rule.
    private var lastWrittenCenter: CLLocationCoordinate2D?

    init(paddingFactor: Double = MRTMetrics.expandedRouteFitPadding) {
        self.paddingFactor = paddingFactor
    }

    /// The fit, as a PURE function of the route (MYR-334).
    ///
    /// It takes no view height and touches no instance state, which is the whole
    /// point: the view can compute it in `init` and hand the `Map` its FINAL
    /// camera before MapKit's first frame, instead of letting MapKit frame the
    /// content itself (`.automatic`) and then re-framing it from `onAppear` —
    /// mid-open-transition, with a tile round-trip thrown away. See the view's
    /// `init` and `AnyTransition.mrtRouteExpand`.
    ///
    /// The chrome bands are NOT compensated here: they are the map's own
    /// `.safeAreaPadding`, and MapKit fits a `.region` into the unobstructed
    /// band itself (MYR-237). Compensating twice is what rendered the route
    /// half-size and high on the route-preview map.
    nonisolated static func fitRegion(
        for coordinates: [CLLocationCoordinate2D],
        paddingFactor: Double = MRTMetrics.expandedRouteFitPadding
    ) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        return VehicleRoute.fittedRegion(
            for: coordinates,
            paddingFactor: paddingFactor,
            minimumSpanDelta: MRTMetrics.expandedRouteMinSpanDelta
        )
    }

    /// The ONE automatic write: fit the route on first appearance. Returns
    /// `nil` on every subsequent call — a new car fix, a leg flip, or the real
    /// polyline replacing a fallback can never yank the camera back, at any fix
    /// rate. Also `nil` for a routeless / not-yet-laid-out input (nothing honest
    /// to frame yet — the fit stays OWED, see `cameraSettled`).
    func seat(fitCoords: [CLLocationCoordinate2D], viewHeight: CGFloat) -> Write? {
        guard phase == .unseated, viewHeight > 0,
              let region = Self.fitRegion(for: fitCoords, paddingFactor: paddingFactor) else { return nil }
        phase = .fitted
        ledger.clear()
        // The settle that lands our own write is stretched by MapKit's aspect
        // fitting in ways we cannot predict exactly; excuse one.
        ledger.grantFreePass()
        return record(region, animated: false)
    }

    /// The explicit recenter tap — the only other programmatic write, and only
    /// ever in response to a touch.
    func recenter(fitCoords: [CLLocationCoordinate2D], viewHeight: CGFloat) -> Write? {
        guard viewHeight > 0,
              let region = Self.fitRegion(for: fitCoords, paddingFactor: paddingFactor) else { return nil }
        phase = .fitted
        ledger.clear()
        ledger.grantFreePass()
        return record(region, animated: true)
    }

    /// The user's finger moved the map (gesture recognizer — not settle
    /// inference), so the recenter affordance appears and stays until used.
    func userGestureBegan() {
        guard phase != .userControlled else { return }
        phase = .userControlled
        ledger.clear()
    }

    /// Classify a camera settle: `true` = one of OUR two writes (ignore),
    /// `false` = the user moved the map (surface the recenter affordance).
    /// Same token ledger every other camera owner in the app uses.
    ///
    /// The `.unseated` guard is load-bearing (device/simulator finding): MapKit
    /// settles its own `.automatic` content framing BEFORE SwiftUI runs the view's
    /// `onAppear`, so the very first settles arrive with the initial fit still
    /// owed. Those are layout, not fingers — classifying them as a gesture is what
    /// made the first cut render at `.automatic`'s tight content fit and offer a
    /// recenter button nobody had asked for.
    func cameraSettled(center: CLLocationCoordinate2D, latitudeDelta: Double) -> Bool {
        guard phase != .unseated else { return true }
        guard phase != .userControlled else { return false }
        if ledger.classifySettle(center: center, latitudeDelta: latitudeDelta) { return true }
        // MapKit keeps re-settling the SAME camera as its ornament/attribution
        // layout converges: the span drifts a few percent per settle (observed
        // 0.0542 → 0.0483 on this surface, just past the ledger's 10% duplicate
        // window) while the centre stays pinned to our written target to ~1e-13°.
        // No finger produces that. A real pinch/drag is caught by the gesture
        // recognizers BEFORE any settle lands (`userGestureBegan`), so this
        // backstop only has to avoid false positives — and a settle sitting
        // exactly on our own fit's centre is layout, not a gesture.
        if let target = lastWrittenCenter, Self.isCentre(center, pinnedTo: target, spanDelta: latitudeDelta) {
            return true
        }
        phase = .userControlled
        ledger.clear()
        return false
    }

    /// Whether a settle's centre is indistinguishable from a written target —
    /// the ledger's own centre tolerance shape (floor + a fraction of the span),
    /// reused so the two classifications can't drift apart. Pure + static.
    static func isCentre(_ centre: CLLocationCoordinate2D, pinnedTo target: CLLocationCoordinate2D, spanDelta: Double) -> Bool {
        let tolerance = max(
            CameraSettleLedger.centerToleranceFloor,
            spanDelta * CameraSettleLedger.centerToleranceFraction
        )
        return abs(centre.latitude - target.latitude) <= tolerance
            && abs(centre.longitude - target.longitude) <= tolerance
    }

    /// Whether the recenter affordance should be offered — i.e. the user has
    /// taken the camera somewhere other than the route fit.
    var showsRecenter: Bool { phase == .userControlled }

    /// Book a write of `fitRegion`'s output: remember its centre and register the
    /// settle it will produce.
    ///
    /// That settle is GROWN relative to what we wrote (by `1/visibleFraction`,
    /// ~1.36× on a phone), because the chrome bands are the map's own
    /// `.safeAreaPadding` and MapKit fits our region into the band between them.
    /// It shares its CENTRE exactly, though, because that band is symmetric —
    /// and a same-centre, ≤4× settle is inside `CameraSettleLedger`'s window, so
    /// the fit's own settle still classifies as programmatic and no recenter is
    /// offered on a camera nobody touched.
    private func record(_ region: MKCoordinateRegion, animated: Bool) -> Write {
        lastWrittenCenter = region.center
        ledger.expect(center: region.center, spanDelta: region.span.latitudeDelta)
        return Write(region: region, animated: animated)
    }
}

// MARK: - The view

/// A full-bleed, user-driven map over the host surface's own route content.
///
/// `content` is the host's existing `@MapContentBuilder` verbatim — the Drive
/// Summary hero's polyline + endpoint dots, or the tracking map's two legs +
/// pins + heading marker — so the expanded view can never drift from the inline
/// one it expanded FROM.
struct ExpandedRouteMap<Content: MapContent>: View {
    /// Headline over the map (the trip the route belongs to).
    let title: String
    /// Optional second line (times, leg phase, …). Never fabricated by this view.
    var subtitle: String?
    /// The coordinates the initial fit + recenter frame.
    let fitCoordinates: [CLLocationCoordinate2D]
    /// MYR-327 honesty: the host is still resolving a REAL road polyline (the
    /// straight endpoint fallback is what's drawn meanwhile). Renders a calm
    /// "Finding route…" line rather than letting the placeholder pass as the route.
    var routeIsResolving: Bool = false
    let onClose: () -> Void
    @MapContentBuilder var content: () -> Content

    @State private var camera = ExpandedRouteCamera()
    @State private var cameraPosition: MapCameraPosition
    @State private var liveCameraRegion = LiveCameraRegionBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// MYR-334 — the map is born already framed.
    ///
    /// The shipped MYR-327 cut started at `.automatic` and wrote the fit from
    /// `onAppear`, i.e. one layout pass INTO the open transition. MapKit
    /// therefore framed the content itself, requested tiles for that framing,
    /// then threw them away when our fit landed — and the frame capture shows
    /// exactly that: ~6 frames of an untiled slate holding nothing but the
    /// polyline, followed by a hard tile pop, all inside the animation. Seeding
    /// `cameraPosition` here means MapKit's very FIRST layout is the final one:
    /// one framing, one tile request, no re-frame mid-flight.
    ///
    /// `onAppear` still calls `seat` (below) — it writes this same region, which
    /// is a no-op for MapKit, and it is what registers the ledger expectation.
    /// A routeless / not-yet-resolved input falls back to `.automatic` exactly
    /// as before, and the existing `onChange(of:)` net seats it when geometry
    /// arrives.
    init(
        title: String,
        subtitle: String? = nil,
        fitCoordinates: [CLLocationCoordinate2D],
        routeIsResolving: Bool = false,
        onClose: @escaping () -> Void,
        @MapContentBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.fitCoordinates = fitCoordinates
        self.routeIsResolving = routeIsResolving
        self.onClose = onClose
        self.content = content
        _cameraPosition = State(
            initialValue: ExpandedRouteCamera.fitRegion(for: fitCoordinates)
                .map { MapCameraPosition.region($0) } ?? .automatic
        )
    }

    var body: some View {
        // The chrome floats over the map, so its offsets are distances from the
        // PHYSICAL edges (MYR-196) — with the MYR-334 caveat that a physical
        // offset must still clear the system's own top band, which is what
        // `safeAreaTop` is read for.
        //
        // This `ignoresSafeArea` is the surface's ONE full-bleed declaration.
        // Nesting a second one on a child (the recenter button had one) expands
        // that child PAST the already-full-bleed parent by the inset again — it
        // still draws, but the overhanging part is outside the parent's bounds
        // and SwiftUI drops its taps. That is why the recenter chip rendered,
        // reported itself hittable, and did nothing.
        GeometryReader { geo in
            mapSurface(
                viewHeight: geo.size.height,
                // Whichever is larger: SwiftUI's reported inset, or the window's
                // own. A `GeometryReader` under `ignoresSafeArea` can report
                // `.zero` here depending on how the host stacked its overlays,
                // and "the header must clear the Dynamic Island" is not a rule
                // that may quietly degrade to 0 on one host.
                safeAreaTop: max(geo.safeAreaInsets.top, Self.windowSafeAreaInsets.top)
            )
        }
        .ignoresSafeArea()
    }

    /// The key window's safe-area insets — the system band the header has to
    /// clear, read from UIKit because it is a property of the DEVICE, not of
    /// whatever SwiftUI container this overlay happens to be nested in.
    private static var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?
            .safeAreaInsets ?? .zero
    }

    /// Where the header row actually sits: the prototype-language physical
    /// offset, floored so it never collides with the status bar / Dynamic
    /// Island (MYR-334 — the client's clipped "Frisco → Plano").
    private func headerTop(safeAreaTop: CGFloat) -> CGFloat {
        max(MRTMetrics.expandedRouteChromeTop, safeAreaTop + MRTMetrics.expandedRouteChromeSafeGap)
    }

    private func mapSurface(viewHeight: CGFloat, safeAreaTop: CGFloat) -> some View {
        ZStack {
            Color.mrtBg

            // NOTE: no `annotationTitles` opinion here — each host's builder
            // already carries its own (the Drive hero shows "Origin"/
            // "Destination"; the tracking map hides them), and the expanded
            // view must render exactly what the inline map renders.
            Map(position: $cameraPosition) {
                content()
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            // MYR-334 — the chrome bands, declared to MapKit rather than
            // pre-compensated into the written region (MYR-237's rule, and the
            // same mechanism `VehicleMapView`/`TrackingMapView` already use).
            // Two things follow, both of them the point:
            //   1. the legally-required Apple Maps + "Legal" attribution renders
            //      ABOVE the reserved band instead of into the home-indicator
            //      strip, where the physical bottom edge was clipping it;
            //   2. MapKit fits our plain `.region` into the unobstructed band
            //      itself, so there is exactly ONE compensation, not two.
            // The map itself is untouched — `safeAreaPadding` grows the inset,
            // it does not shrink the edge-to-edge render, so this stays
            // full-bleed.
            .safeAreaPadding(.top, MRTMetrics.expandedRouteFitTopInset)
            .safeAreaPadding(.bottom, MRTMetrics.expandedRouteFitBottomInset)
            .preferredColorScheme(.dark)
            .onMapCameraChange(frequency: .continuous) { context in
                liveCameraRegion.region = context.region
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let ours = camera.cameraSettled(
                    center: context.region.center,
                    latitudeDelta: context.region.span.latitudeDelta
                )
                mrtCameraTrace(
                    "settle expandedRoute center=\(context.region.center.latitude),\(context.region.center.longitude) latDelta=\(context.region.span.latitudeDelta) classified=\(ours ? "programmatic (token)" : "user → recenter offered")"
                )
            }
            // A gesture dethrones the fit immediately — never wait for the
            // settle inference (MYR-222 discipline).
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in handleUserGesture() })
            .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.02).onChanged { _ in handleUserGesture() })

            topScrim(headerTop: headerTop(safeAreaTop: safeAreaTop))
            header(headerTop: headerTop(safeAreaTop: safeAreaTop))
            recenterButton(viewHeight: viewHeight)
        }
        .onAppear { seatIfNeeded(viewHeight: viewHeight) }
        // A zero/late first layout (the overlay is inserted mid-transition) must
        // not cost the fit — re-offer it until a real height exists. `seat` is
        // idempotent, so this can only ever write once.
        .onChange(of: viewHeight) { _, height in seatIfNeeded(viewHeight: height) }
    }

    /// The ONE automatic write in this view's entire life (see the camera
    /// contract at the top of this file).
    private func seatIfNeeded(viewHeight: CGFloat) {
        if let write = camera.seat(fitCoords: fitCoordinates, viewHeight: viewHeight) { apply(write) }
    }

    // MARK: Chrome

    /// Legibility wash under the header — the same top scrim the Drive Summary
    /// hero already lays over its map. Grows with the header's own offset so the
    /// wash still runs out below the last line of the title (MYR-334).
    private func topScrim(headerTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.mrtDsScrimTop, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: MRTMetrics.expandedRouteScrimHeight + headerTop - MRTMetrics.expandedRouteChromeTop)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func header(headerTop: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                    .frame(
                        width: MRTMetrics.expandedRouteButtonSize,
                        height: MRTMetrics.expandedRouteButtonSize
                    )
                    .background(Color.mrtDsFloatingNavFill, in: Circle())
                    .overlay(Circle().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
                    // ≥44pt hit target around the 38pt visual (same expansion
                    // the Drive Summary floating nav uses).
                    .contentShape(
                        Circle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.expandedRouteButtonSize) / 2)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close route view")

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextSec)
                        .lineLimit(1)
                }
                // Honest, never a spinner over a fabricated line: the straight
                // endpoint fallback under this caption is NOT the route yet.
                if routeIsResolving {
                    Text("Finding route…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextMuted)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, headerTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The SAME recenter affordance the idle / tracking maps use — appears only
    /// once the user has moved the camera off the fit, and re-frames the route.
    private func recenterButton(viewHeight: CGFloat) -> some View {
        FloatingMapButton(
            bottom: MRTMetrics.expandedRouteRecenterBottom,
            hidden: !camera.showsRecenter,
            systemImage: "arrow.up.left.and.arrow.down.right",
            accessibilityLabel: "Fit the whole route"
        ) {
            // Traced alongside the writes so the camera probe shows the tap AND
            // its consequence, not just the consequence.
            mrtCameraTrace("tap recenter expandedRoute coords=\(fitCoordinates.count) viewHeight=\(viewHeight)")
            if let write = camera.recenter(fitCoords: fitCoordinates, viewHeight: viewHeight) { apply(write) }
        }
    }

    // MARK: Camera plumbing

    private func apply(_ write: ExpandedRouteCamera.Write) {
        mrtCameraTrace(
            "WRITE expandedRoute center=\(write.region.center.latitude),\(write.region.center.longitude) span=\(write.region.span.latitudeDelta) animated=\(write.animated)"
        )
        if write.animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.45)) { cameraPosition = .region(write.region) }
        } else {
            cameraPosition = .region(write.region)
        }
    }

    private func handleUserGesture() {
        guard !camera.showsRecenter else { return }
        mrtCameraTrace("gesture user pan/zoom on expandedRoute → user owns camera")
        camera.userGestureBegan()
        // Kill any in-flight programmatic glide so it can't slide back over the
        // user's drag (MYR-222) — pin the camera at its current visual region.
        if let current = liveCameraRegion.region {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { cameraPosition = .region(current) }
        }
    }
}

// MARK: - Expand affordance + presentation grammar (MYR-327)

/// The "open the route full-screen" chip. One definition so the Drive Summary
/// hero and the rider tracking map offer the identical mark (and the identical
/// ≥44pt target), rather than each rolling its own.
struct ExpandRouteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mrtText)
                .frame(
                    width: MRTMetrics.expandedRouteButtonSize,
                    height: MRTMetrics.expandedRouteButtonSize
                )
                .background(Color.mrtDsFloatingNavFill, in: Circle())
                .overlay(Circle().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
                .contentShape(
                    Circle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.expandedRouteButtonSize) / 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand the route")
    }
}

extension AnyTransition {
    /// Expand/collapse grammar for the route viewer — a pure OPACITY cross-fade,
    /// in both the normal and the Reduce Motion branch.
    ///
    /// MYR-334, client: "the drive map opening up is a bit glitchy, needs to be
    /// smooth" — device-only, which is the tell. The shipped MYR-327 cut opened
    /// with `.scale(0.94).combined(with: .opacity)`, and a *changing* scale over
    /// a live `MKMapView` is the expensive kind of animation: MapKit re-renders
    /// its vector tiles at the new scale every frame, and the combined opacity
    /// forces the whole full-screen map to composite off-screen as a group while
    /// it does. The simulator absorbs that on a Mac GPU; a 3× 6.9" panel does
    /// not. Opacity alone is one blend of an already-rendered layer — the map's
    /// geometry never changes, so nothing re-rasterises.
    ///
    /// This is the standing lesson applied to a takeover rather than to a drag:
    /// lay the surface out ONCE at its final size and animate a compositing
    /// property, never per-frame geometry. (The scale had a second cost too: at
    /// 0.94 a full-bleed takeover leaves a 3% border of the screen it came from
    /// visible for the whole transition — the drive-summary chrome peeking round
    /// the corners of the client's mid-transition screenshot.)
    ///
    /// The other half of "smooth" is not in the transition at all: see
    /// `ExpandedRouteMap.init`, which hands the `Map` its final camera before
    /// MapKit's first frame so no re-framing happens inside the animation.
    static func mrtRouteExpand(reduceMotion _: Bool) -> AnyTransition { .opacity }
}

extension Animation {
    /// The curve paired with `mrtRouteExpand` — Handoff §8's sheet-snap curve at
    /// the app's existing overlay duration (`mrt-sched-up`, 0.3s). Reduce Motion
    /// keeps the standard 0.2s ease-out every animated rider surface falls back
    /// to.
    static func mrtRouteExpand(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .timingCurve(0.32, 0.72, 0, 1, duration: MRTMetrics.expandedRouteFadeDuration)
    }
}
