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
///   1. **1:1 tracking** — the finger drives `sheetHeight` inside an
///      animation-disabled transaction, so the surface never lags/fights.
///   2. **Rubber-banding** past either detent (`SheetPhysics.rubberBand`),
///      not a hard clamp.
///   3. **Velocity-projected release** (`SheetPhysics.projection` +
///      `nearestDetent`) — a fast flick crosses detents on small displacement.
///   4. **Interruptible** — a new grab reads the sheet's *live* laid-out
///      height and picks up from there, so there is no jump mid-settle. The
///      live height is tracked in a plain reference (`SheetLiveHeight`) that
///      the background reader mutates every frame **without invalidating the
///      view** — MYR-236 round 2: routing it through `@State` made every drag
///      frame run two full layout passes (write height → layout → preference →
///      write live-height → layout again). That feedback loop is free on an
///      M-series simulator and drops frames at 120 Hz on device — the exact
///      "sticky/glitchy" the client reported that round 1 could not measure.
///   5. **Inner-scroll handoff** — the whole sheet drags while the inner
///      content isn't scrollable (peek); a `ScrollView` caller keeps its own
///      `.scrollDisabled(detent == .peek)`, so at half the body scrolls and
///      the handle still collapses it (matching the prototype's handle-drag).
///   6. **Reduce Motion** snaps without spring theatrics.
///
/// Place it inside the container it should measure (it fills its parent and
/// bottom-aligns itself), e.g. layered over the map in a `ZStack`. Keep any
/// floating tab bar *outside* that container or inset the container's bottom,
/// mirroring the prototype's `navHeight` offset.
///
/// Programmatic detent changes animate to the new resting height.
public struct MRTDetentSheet<Content: View>: View {
    @Binding private var detent: MRTSheetDetent
    private let peekHeight: CGFloat
    private let halfHeight: CGFloat?
    private let halfHeightFraction: CGFloat
    private let content: Content

    /// The rendered sheet height — the single source of truth. `nil` until the
    /// first layout resolves the resting height (avoids sizing to 0 on the
    /// first frame).
    @State private var sheetHeight: CGFloat?
    /// The sheet's *actual* laid-out height, tracked every frame in a plain
    /// reference so updating it never re-invalidates `body` (see requirement 4
    /// above). Read on a fresh grab for jump-free interruption.
    @State private var live = SheetLiveHeight()
    /// Resting height captured at drag start; `nil` when not dragging.
    @State private var dragAnchor: CGFloat?
    /// The height requested by the *previous* drag frame — the harness compares
    /// it against the height that actually rendered this frame to measure
    /// tracking lag (MYR-236 round 2 measurement harness).
    @State private var lastRequested: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Harness (MYR-236 round 2): count body/layout evaluations — the
            // per-drag-frame layout cost. DEBUG + trace-flag only.
            let _ = MRTSheetTrace.bodyTick()
            let half = halfHeight ?? geo.size.height * halfHeightFraction
            let resting = detent == .peek ? peekHeight : half
            // `.isFinite` guard before layout (MYR-227): never let a stray
            // NaN/∞ reach `.frame(height:)`.
            let rawHeight = sheetHeight ?? resting
            let height = rawHeight.isFinite ? max(0, rawHeight) : resting

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
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .mrtSurface(.sheet, fill: .mrtBgSecondary)
            // Whole-sheet drag: the handle AND the body both grab the sheet.
            // At half the inner `ScrollView` (caller-owned, `.scrollDisabled`
            // off) wins for body touches, so this yields to scrolling there;
            // the handle strip lives outside that scroll view and always drags.
            .contentShape(Rectangle())
            .gesture(dragGesture(peek: peekHeight, half: half))
            // Harness hook (MYR-236): the sheet element the XCUITest drags and
            // reads the frame of. `children: .contain` makes the sized surface
            // a single queryable element whose frame IS the sheet's visible
            // height (not a full-screen wrapper) while the handle's adjustable
            // action stays reachable as a contained child.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mrt.detentSheet")
            // Track the true laid-out height (interpolated during the spring)
            // into `live` — a plain ref, so this does NOT invalidate `body`.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetLiveHeightKey.self, value: proxy.size.height)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(SheetLiveHeightKey.self) { [live] in live.height = $0 }
            .onAppear { if sheetHeight == nil { sheetHeight = resting } }
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
                    let anchor = live.height > 0 ? live.height : (sheetHeight ?? peek)
                    dragAnchor = anchor
                    lastRequested = anchor
                    setHeight(anchor, animated: false)
                    MRTSheetTrace.log("grab @\(Int(anchor))")
                }
                let raw = (dragAnchor ?? peek) + (-value.translation.height)
                // 1:1 tracking with logarithmic overscroll past either detent.
                let banded = SheetPhysics.rubberBand(raw, lowerBound: peek, upperBound: half)
                // Harness sample (MYR-236): the height the PREVIOUS frame asked
                // for vs. the height that actually rendered this frame
                // (`live.height`). For a true 1:1 animation-disabled drag these
                // match within rounding; an inherited spring on the height
                // would make `rendered` lag `requested` by many points.
                MRTSheetTrace.sample(requested: lastRequested, rendered: live.height)
                lastRequested = banded
                setHeight(banded, animated: false)
            }
            .onEnded { value in
                let releaseHeight = live.height > 0 ? live.height : (sheetHeight ?? peek)
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
                // the detent. By the time `.onChange(of: detent)` fires,
                // `sheetHeight` already equals the resting height, so
                // `settleToRestingIfNeeded` no-ops — no redundant second
                // `withAnimation` fighting this one (MYR-236 round 2).
                setHeight(target == .peek ? peek : half, animated: true)
                detent = target
            }
    }

    /// Programmatic detent change (accessibility) — commit + settle.
    private func setDetent(_ target: MRTSheetDetent, peek: CGFloat, half: CGFloat) {
        setHeight(target == .peek ? peek : half, animated: true)
        detent = target
    }

    /// Animate to `resting` unless the sheet is already settling there (the
    /// drag's own `onEnded` handles that case) or a drag is active.
    private func settleToRestingIfNeeded(_ resting: CGFloat) {
        guard dragAnchor == nil else { return }
        guard let current = sheetHeight, current != resting else { return }
        setHeight(resting, animated: true)
    }

    private func setHeight(_ value: CGFloat, animated: Bool) {
        let safe = value.isFinite ? value : (sheetHeight ?? peekHeight)
        if animated {
            withAnimation(settleAnimation) { sheetHeight = safe }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { sheetHeight = safe }
        }
    }
}

/// Holds the sheet's last laid-out height as a plain reference so the
/// background `GeometryReader` can refresh it every frame **without**
/// invalidating the view — the fix for the per-frame layout feedback loop that
/// made dragging janky on device (MYR-236 round 2). Read on a fresh grab for
/// jump-free interruption.
final class SheetLiveHeight {
    var height: CGFloat = 0
}

/// Reports the sheet's live (interpolated) laid-out height so a re-grab can
/// read the true current position.
private struct SheetLiveHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
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
        // layout-cost metric (round-1 ≈2/frame, fixed ≈1/frame).
        logger.notice("S req=\(Int(requested.rounded()), privacy: .public) rendered=\(Int(rendered.rounded()), privacy: .public) body=\(bodyEvals, privacy: .public)")
        #endif
    }
}
