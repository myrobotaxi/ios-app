import SwiftUI
import os

// MARK: - Detent sheet (persistent peek ↔ half) — components.jsx `BottomSheet`
//
// Split out of `BottomSheet.swift` (MYR-236 round 2): the config sheet and the
// draggable detent sheet are two unrelated interaction models, and keeping
// them together pushed the file past the 300-line rule. This file owns the
// draggable model; `BottomSheet.swift` owns the modal config sheet.

public enum MRTSheetDetent: Sendable, Equatable {
    /// Resting height (260 by default).
    case peek
    /// ~50% of the sheet's container (or an explicit `halfHeight`).
    case half
}

/// The draggable home-map sheet (components.jsx `BottomSheet`): drag anywhere
/// on the sheet between peek and half; release projects the throw from its
/// release velocity and snaps to the nearest detent with
/// `.spring(response: 0.42, dampingFraction: 0.86)` (Handoff §8 sheet snap).
///
/// Fluid-drag contract (MYR-236 — all decision math lives in `SheetPhysics`):
///   1. **1:1 tracking** — the finger drives the sheet inside an
///      animation-disabled transaction, so the surface never lags/fights.
///   2. **Rubber-banding** past either detent (`SheetPhysics.rubberBand`).
///   3. **Velocity-projected release** (`SheetPhysics.projection` +
///      `nearestDetent`) — a fast flick crosses detents on small displacement.
///   4. **Interruptible** — a new grab picks the sheet up from its *live*
///      on-screen position mid-settle (no jump).
///   5. **Inner-scroll handoff** — a `ScrollView` caller keeps its own
///      `.scrollDisabled(detent == .peek)`.
///   6. **Reduce Motion** snaps without spring theatrics.
///
/// ROUND 3 (MYR-236): the drag no longer drives `.frame(height:)`. Rounds 1–2
/// tuned the gesture/state plumbing, but every drag frame still re-LAID-OUT
/// the whole sheet subtree (a height change reflows the content `ScrollView`)
/// and re-rasterized the shadowed rounded surface at its new size — free on an
/// M-series simulator, dropped frames at 120 Hz on device. Now the surface is
/// laid out ONCE at its tallest size (`half` + an overshoot pad, bottom-
/// anchored with the pad hanging off-screen) and the finger drives a pure Y
/// **translation** (`SheetSlideEffect`): per-frame cost is a transform update
/// — no layout, no shadow re-render. This is how UIKit's own sheets track.
/// The effect also mirrors the interpolated on-screen position every rendered
/// frame into a plain (non-invalidating) ref, which keeps mid-settle re-grabs
/// jump-free without round 2's GeometryReader/preference plumbing.
///
/// Place it inside the container it should measure (it fills its parent and
/// bottom-aligns itself), e.g. layered over the map in a `ZStack`. Keep any
/// floating tab bar *outside* that container, mirroring the prototype's
/// `navHeight` offset. Programmatic detent changes animate to the new resting
/// height.
public struct MRTDetentSheet<Content: View>: View {
    @Binding private var detent: MRTSheetDetent
    private let peekHeight: CGFloat
    private let halfHeight: CGFloat?
    private let halfHeightFraction: CGFloat
    private let content: Content

    /// The visible height the sheet is being ASKED to show — the single source
    /// of truth the translation derives from. `nil` until first layout resolves
    /// the resting height (avoids flashing from 0 on the first frame).
    @State private var visibleHeight: CGFloat?
    /// The sheet's *actual* on-screen visible height, refreshed every rendered
    /// frame by `SheetSlideEffect` (including mid-spring interpolated frames)
    /// without invalidating `body`. Read on a fresh grab for jump-free
    /// interruption (requirement 4).
    @State private var live = SheetLiveMotion()
    /// Visible height captured at drag start; `nil` when not dragging.
    @State private var dragAnchor: CGFloat?
    /// The height requested by the *previous* drag frame — the harness compares
    /// it against the height actually rendered this frame to measure tracking
    /// lag (MYR-236 measurement harness).
    @State private var lastRequested: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Extra surface laid out below the screen's bottom edge so an upward
    /// rubber-band overshoot (≤30pt, `SheetPhysics.rubberBand`'s dimension)
    /// never reveals a gap under the lifted sheet.
    private static var overshootPad: CGFloat { 48 }

    public init(
        detent: Binding<MRTSheetDetent>,
        peekHeight: CGFloat = MRTMetrics.sheetPeekHeight,
        halfHeight: CGFloat? = nil,
        /// Fraction of the container height used for the half detent when
        /// `halfHeight` is nil. Default 0.5; the Live Map screen passes
        /// `MRTMetrics.homeHalfHeightFraction` (0.58, screens.jsx:401).
        halfHeightFraction: CGFloat = 0.5,
        @ViewBuilder content: () -> Content
    ) {
        _detent = detent
        self.peekHeight = peekHeight
        self.halfHeight = halfHeight
        self.halfHeightFraction = halfHeightFraction
        self.content = content()
    }

    /// Snap spring — Handoff §8 "Sheet snap `.spring(response:0.42,
    /// dampingFraction:0.86)`". SwiftUI springs are interruptible, so a grab
    /// mid-flight blends in without gating the gesture.
    private var settleAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    public var body: some View {
        GeometryReader { geo in
            // Harness (MYR-236): count body evaluations. DEBUG + trace-flag only.
            let _ = MRTSheetTrace.bodyTick()
            let half = halfHeight ?? geo.size.height * halfHeightFraction
            let resting = detent == .peek ? peekHeight : half
            // Fixed layout size — NEVER changes during a drag (round 3).
            let surfaceHeight = half + Self.overshootPad
            // `.isFinite` guard before rendering (MYR-227): never let a stray
            // NaN/∞ reach layout or the transform.
            let rawVisible = visibleHeight ?? resting
            let visible = rawVisible.isFinite ? max(0, rawVisible) : resting

            VStack(spacing: 0) {
                MRTGrabHandle()
                    .contentShape(Rectangle().inset(by: -12))
                    .accessibilityLabel("Sheet handle")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: setDetent(.half, peek: peekHeight, half: half)
                        case .decrement: setDetent(.peek, peek: peekHeight, half: half)
                        @unknown default: break
                        }
                    }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: surfaceHeight)
            .frame(maxWidth: .infinity)
            .mrtSurface(.sheet, fill: .mrtBgSecondary)
            // Whole-sheet drag: the handle AND the body both grab the sheet.
            // At half the inner `ScrollView` (caller-owned, `.scrollDisabled`
            // off) wins for body touches, so this yields to scrolling there;
            // the handle strip lives outside that scroll view and always drags.
            .contentShape(Rectangle())
            .gesture(dragGesture(peek: peekHeight, half: half))
            // Harness hook (MYR-236): the sheet element the XCUITest drags and
            // reads the frame of. Its `minY` tracks the visible top edge (the
            // translation moves the accessibility frame); its height is the
            // constant `surfaceHeight`, the below-screen part clipped.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mrt.detentSheet")
            // The drag/settle translation (round 3): render-only, no layout.
            .modifier(SheetSlideEffect(
                offsetY: surfaceHeight - visible, surfaceHeight: surfaceHeight, live: live
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onAppear { if visibleHeight == nil { visibleHeight = resting } }
            // External detent flips (accessibility action) and peek-height
            // changes (driving↔parked) animate to the new resting height —
            // skipped while dragging or when the sheet is already there (the
            // drag's own `onEnded` committed it first).
            .onChange(of: detent) { settleToRestingIfNeeded(resting) }
            .onChange(of: resting) { settleToRestingIfNeeded(resting) }
        }
        // Full-bleed geometry (CLAUDE.md "Hard rules"): components.jsx
        // `BottomSheet` is called with `navHeight={0}` (screens.jsx:429) —
        // the sheet surface always runs flush to the screen's PHYSICAL bottom
        // edge; any floating nav bar is a sibling anchored independently on
        // top of it (see `mrtBottomNav`), not something this sheet insets for
        // (MYR-196 punch-list #2).
        .ignoresSafeArea(edges: .bottom)
    }

    private func dragGesture(peek: CGFloat, half: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragAnchor == nil {
                    // Pick the sheet up from wherever it visually is right now
                    // — including mid-settle — and freeze the in-flight spring
                    // at that position (no jump, requirement 4).
                    let anchor = live.visibleHeight > 0 ? live.visibleHeight : (visibleHeight ?? peek)
                    dragAnchor = anchor
                    lastRequested = anchor
                    setVisible(anchor, animated: false)
                    MRTSheetTrace.log("grab @\(Int(anchor))")
                }
                let raw = (dragAnchor ?? peek) + (-value.translation.height)
                // 1:1 tracking with logarithmic overscroll past either detent.
                let banded = SheetPhysics.rubberBand(raw, lowerBound: peek, upperBound: half)
                // Harness sample (MYR-236): the height the PREVIOUS frame asked
                // for vs. the height that actually rendered this frame. For a
                // true 1:1 animation-disabled drag these match within rounding.
                MRTSheetTrace.sample(requested: lastRequested, rendered: live.visibleHeight)
                lastRequested = banded
                setVisible(banded, animated: false)
            }
            .onEnded { value in
                let releaseHeight = live.visibleHeight > 0 ? live.visibleHeight : (visibleHeight ?? peek)
                // Project the throw from release VELOCITY (up = positive), then
                // snap to the detent nearest the projected endpoint — a fast
                // flick crosses detents even on small displacement.
                let projected = releaseHeight + SheetPhysics.projection(velocity: -value.velocity.height)
                let target = SheetPhysics.nearestDetent(
                    toProjectedHeight: projected, peekHeight: peek, halfHeight: half
                )
                MRTSheetTrace.log("release @\(Int(releaseHeight)) proj \(Int(projected)) → \(target == .peek ? "peek" : "half")")
                dragAnchor = nil
                // Settle FIRST (state jumps to the resting value), THEN commit
                // the detent — by the time `.onChange(of: detent)` fires the
                // sheet is already settling there, so `settleToRestingIfNeeded`
                // no-ops (no redundant second `withAnimation`, round 2).
                setVisible(target == .peek ? peek : half, animated: true)
                detent = target
            }
    }

    /// Programmatic detent change (accessibility) — commit + settle.
    private func setDetent(_ target: MRTSheetDetent, peek: CGFloat, half: CGFloat) {
        setVisible(target == .peek ? peek : half, animated: true)
        detent = target
    }

    /// Animate to `resting` unless the sheet is already settling there (the
    /// drag's own `onEnded` handles that case) or a drag is active.
    private func settleToRestingIfNeeded(_ resting: CGFloat) {
        guard dragAnchor == nil else { return }
        guard let current = visibleHeight, current != resting else { return }
        setVisible(resting, animated: true)
    }

    private func setVisible(_ value: CGFloat, animated: Bool) {
        let safe = value.isFinite ? value : (visibleHeight ?? peekHeight)
        if animated {
            withAnimation(settleAnimation) { visibleHeight = safe }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { visibleHeight = safe }
        }
    }
}

/// The round-3 drag/settle motor: a pure Y translation (`GeometryEffect`, so
/// hit-testing and the accessibility frame move with the pixels) whose
/// `animatableData` is the offset — during a settle spring SwiftUI feeds it
/// the *interpolated* offset every rendered frame, which `effectValue`
/// mirrors into `live` (a plain ref, no view invalidation). That live value
/// is the sheet's true on-screen position, read on a fresh grab (requirement
/// 4) and by the measurement harness.
struct SheetSlideEffect: GeometryEffect {
    var offsetY: CGFloat
    let surfaceHeight: CGFloat
    let live: SheetLiveMotion

    var animatableData: CGFloat {
        get { offsetY }
        set { offsetY = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dy = offsetY.isFinite ? offsetY : 0
        live.visibleHeight = surfaceHeight - dy
        return ProjectionTransform(CGAffineTransform(translationX: 0, y: dy))
    }
}

/// Holds the sheet's live on-screen visible height as a plain reference so
/// `SheetSlideEffect` can refresh it every rendered frame **without**
/// invalidating the view (the round-2 lesson: routing per-frame tracking
/// through `@State` doubles the layout work and drops frames on device).
final class SheetLiveMotion {
    var visibleHeight: CGFloat = 0
}

// MARK: - Drag trace + measurement harness hook (MYR-236)

/// DEBUG-only drag trace — mirrors the camera-trace convention
/// (`VehicleMapView.mrtCameraTrace`). Off unless `MRT_SHEET_TRACE=1`, so it
/// never spams the drift-gate log streams. Release builds compile it to no-ops
/// (the `#if DEBUG` body is stripped), so shipping carries no cost.
enum MRTSheetTrace {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["MRT_SHEET_TRACE"] == "1"
    private static let logger = Logger(subsystem: "app.myrobotaxi.ios", category: "sheet")
    /// Count of `MRTDetentSheet.body` evaluations — the per-frame layout-cost
    /// proxy the harness diffs across a drag (fewer = fluider on device).
    private static var bodyEvals = 0
    #endif

    /// Bumped once per `body` evaluation (see `MRTDetentSheet.body`).
    static func bodyTick() {
        #if DEBUG
        guard enabled else { return }
        bodyEvals += 1
        #endif
    }

    static func log(_ message: String) {
        #if DEBUG
        guard enabled else { return }
        logger.info("\(message, privacy: .public)")
        #endif
    }

    /// One `(requested, rendered)` height sample per drag frame. The harness
    /// (`SheetFeelUITests`) drives a slow drag, then parses these lines from
    /// the device/sim log to compute the max tracking error objectively.
    static func sample(requested: CGFloat, rendered: CGFloat) {
        #if DEBUG
        guard enabled else { return }
        // `.notice` (default level) so `log show` captures it without `--info`.
        // `body=` is the running body-eval count — its per-sample delta is the
        // layout-cost metric.
        logger.notice("S req=\(Int(requested.rounded()), privacy: .public) rendered=\(Int(rendered.rounded()), privacy: .public) body=\(bodyEvals, privacy: .public)")
        #endif
    }
}
