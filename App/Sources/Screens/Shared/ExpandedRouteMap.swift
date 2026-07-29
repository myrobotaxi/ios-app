import SwiftUI
import MapKit
import CoreLocation
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

    /// The ONE automatic write: fit the route on first appearance. Returns
    /// `nil` on every subsequent call — a new car fix, a leg flip, or the real
    /// polyline replacing a fallback can never yank the camera back, at any fix
    /// rate. Also `nil` for a routeless / not-yet-laid-out input (nothing honest
    /// to frame yet — the fit stays OWED, see `cameraSettled`).
    func seat(fitCoords: [CLLocationCoordinate2D], viewHeight: CGFloat) -> Write? {
        guard phase == .unseated, !fitCoords.isEmpty, viewHeight > 0 else { return nil }
        phase = .fitted
        ledger.clear()
        // The settle that lands our own write is stretched by MapKit's aspect
        // fitting in ways we cannot predict exactly; excuse one.
        ledger.grantFreePass()
        return write(fitCoords: fitCoords, viewHeight: viewHeight, animated: false)
    }

    /// The explicit recenter tap — the only other programmatic write, and only
    /// ever in response to a touch.
    func recenter(fitCoords: [CLLocationCoordinate2D], viewHeight: CGFloat) -> Write? {
        guard !fitCoords.isEmpty, viewHeight > 0 else { return nil }
        phase = .fitted
        ledger.clear()
        ledger.grantFreePass()
        return write(fitCoords: fitCoords, viewHeight: viewHeight, animated: true)
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

    /// The fit itself — the route's box, padded, then grown so it lands in the
    /// band BETWEEN the header chip and the recenter button rather than running
    /// under both (the same `insetRegion` compensation the tracking leg fit uses,
    /// applied to a takeover whose chrome floats over the map).
    private func write(fitCoords: [CLLocationCoordinate2D], viewHeight: CGFloat, animated: Bool) -> Write {
        let region = VehicleRoute.fittedRegion(
            for: fitCoords,
            paddingFactor: paddingFactor,
            bottomInset: MRTMetrics.expandedRouteFitBottomInset,
            viewHeight: viewHeight,
            topInset: MRTMetrics.expandedRouteFitTopInset,
            minimumSpanDelta: MRTMetrics.expandedRouteMinSpanDelta
        )
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
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var liveCameraRegion = LiveCameraRegionBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The fit needs the map's FULL-BLEED height: the chrome floats over the
        // map, so its insets are distances from the PHYSICAL edges (MYR-196).
        //
        // This `ignoresSafeArea` is the surface's ONE full-bleed declaration.
        // Nesting a second one on a child (the recenter button had one) expands
        // that child PAST the already-full-bleed parent by the inset again — it
        // still draws, but the overhanging part is outside the parent's bounds
        // and SwiftUI drops its taps. That is why the recenter chip rendered,
        // reported itself hittable, and did nothing.
        GeometryReader { geo in
            mapSurface(viewHeight: geo.size.height)
        }
        .ignoresSafeArea()
    }

    private func mapSurface(viewHeight: CGFloat) -> some View {
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

            topScrim
            header
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
    /// hero already lays over its map.
    private var topScrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.mrtDsScrimTop, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: MRTMetrics.expandedRouteScrimHeight)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
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
        .padding(.top, MRTMetrics.expandedRouteChromeTop)
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
    /// Expand/collapse grammar for the route viewer — Handoff §8's sheet snap
    /// (`.42s cubic-bezier(.32,.72,0,1)`) expressed as a grow-from-the-inline-map
    /// scale + fade, so opening reads as the small map becoming the big one.
    /// Reduce Motion collapses it to a plain cross-fade at the app's standard
    /// 0.2s ease-out (the same fallback every animated rider surface uses).
    static func mrtRouteExpand(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: MRTMetrics.expandedRouteEnterScale).combined(with: .opacity)
    }
}

extension Animation {
    /// The curve paired with `mrtRouteExpand`.
    static func mrtRouteExpand(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .timingCurve(0.32, 0.72, 0, 1, duration: 0.42) // Handoff §8 sheet snap
    }
}
