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
    /// MYR-332 — the TALLEST stop, the physical screen less
    /// ``MRTMetrics/sheetTallTopClearance``. Opt-in per sheet
    /// (`allowsTallDetent`); a sheet that does not offer it clamps this to
    /// ``half``, so nothing that has only ever known peek/half can be driven
    /// somewhere it has no height for.
    case tall
}

/// The draggable home-map sheet (components.jsx `BottomSheet`): drag anywhere
/// on the sheet between peek and half; release projects the throw from its
/// release velocity and snaps to the nearest detent with
/// `.spring(response: 0.42, dampingFraction: 0.86)` (Handoff §8 sheet snap).
///
/// ROUND 4 (MYR-236): the public API is unchanged (detent binding, peekHeight,
/// halfHeight(Fraction), content) but the drag is now the UIKit-layer
/// `PanSheet` engine — three SwiftUI-gesture rounds (r1 physics, r2 activation,
/// r3 transform-not-layout) each passed the M-series sim and each shipped
/// still-janky at 120 Hz on the client's device, because SwiftUI did per-frame
/// work no matter how the tracking was expressed. `PanSheet` drives a `CALayer`
/// translation directly from a `UIPanGestureRecognizer` (zero SwiftUI work per
/// frame) and adds the interruptible settle + inner-scroll handoff a SwiftUI
/// gesture cannot express (see `PanSheet.swift`'s header). The pure decision
/// math still lives in `SheetPhysics`; this view only maps peek/half ↔ the
/// engine's detent index and hosts the content + grab handle.
///
/// Place it inside the container it should measure (it fills its parent and
/// bottom-aligns itself), e.g. layered over the map in a `ZStack`. Keep any
/// floating tab bar *outside* that container, mirroring the prototype's
/// `navHeight` offset. Programmatic detent changes animate to the new resting
/// height. The inner `ScrollView` no longer needs `.scrollDisabled(peek)` — the
/// engine's handoff pins the offset while the sheet owns the pan below max
/// detent, and lets it scroll at max detent (MYR-236 round 4).
public struct MRTDetentSheet<Content: View>: View {
    @Binding private var detent: MRTSheetDetent
    private let peekHeight: CGFloat
    private let halfHeight: CGFloat?
    private let halfHeightFraction: CGFloat
    private let content: Content
    /// MYR-236 round 5.3 — when non-nil, the sheet hosts two crossfade layers
    /// (peek/low + expanded/high) that the engine cross-dissolves by drag
    /// progress, over an always-opaque base wash, instead of the single
    /// `content`. `nil` for the single-content path (ButtonShowcase).
    private let crossfade: OwnerCrossfade?
    /// MYR-332 — offer the third, TALL detent above `half`. Opt-in: every other
    /// consumer keeps exactly the peek↔half pair it has always had.
    private let allowsTallDetent: Bool
    /// MYR-332 — reports the sheet's RESOLVED detent heights (ascending, points
    /// from the physical bottom edge) whenever the geometry produces a new set.
    /// The owner map reads it so its `bottomContentInset` can follow the sheet up
    /// to the tall detent (`half` is measured but deliberately unused there — see
    /// `HomeScreen.mapBottomInset`). Same reporting shape as `RiderTrackingSheet`.
    private let onResolvedHeights: (([CGFloat]) -> Void)?

    /// The two owner crossfade layers, type-erased (two different content
    /// shapes living side by side in one surface — see `PanSheetCrossfade`).
    struct OwnerCrossfade {
        let low: AnyView
        let high: AnyView
    }

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
        self.crossfade = nil
        self.allowsTallDetent = false
        self.onResolvedHeights = nil
    }

    /// Internal designated init used by the crossfade convenience init below.
    init(
        detent: Binding<MRTSheetDetent>,
        peekHeight: CGFloat,
        halfHeight: CGFloat?,
        halfHeightFraction: CGFloat,
        content: Content,
        crossfade: OwnerCrossfade?,
        allowsTallDetent: Bool = false,
        onResolvedHeights: (([CGFloat]) -> Void)? = nil
    ) {
        _detent = detent
        self.peekHeight = peekHeight
        self.halfHeight = halfHeight
        self.halfHeightFraction = halfHeightFraction
        self.content = content
        self.crossfade = crossfade
        self.allowsTallDetent = allowsTallDetent
        self.onResolvedHeights = onResolvedHeights
    }

    /// peek ↔ 0, half ↔ 1, tall ↔ 2 — the engine works in detent indices. A
    /// sheet without a tall detent clamps `.tall` to the top index it does have,
    /// so the binding can never select a height that isn't there.
    private func selectionIndex(count: Int) -> Binding<Int> {
        Binding(
            get: {
                switch detent {
                case .peek: return 0
                case .half: return min(1, count - 1)
                case .tall: return count - 1
                }
            },
            set: { index in
                switch index {
                case 0: detent = .peek
                case 1: detent = .half
                default: detent = .tall
                }
            }
        )
    }

    /// The ascending detent heights this sheet offers for a given container.
    /// `screenHeight` is the PHYSICAL screen height (the container's bottom edge
    /// is flush with it — see `.ignoresSafeArea(edges: .bottom)` below), which is
    /// what the tall detent's top clearance is measured against.
    private func detentHeights(containerHeight: CGFloat, screenHeight: CGFloat) -> [CGFloat] {
        let half = halfHeight ?? containerHeight * halfHeightFraction
        // `.isFinite` guard (MYR-227): never let a stray NaN/∞ detent reach the
        // engine's layout math.
        let safeHalf = half.isFinite && half > peekHeight ? half : peekHeight + 1
        guard allowsTallDetent,
              let tall = MRTMetrics.sheetTallHeight(screenHeight: screenHeight, halfHeight: safeHalf)
        else { return [peekHeight, safeHalf] }
        return [peekHeight, safeHalf, tall]
    }

    public var body: some View {
        GeometryReader { geo in
            // The container runs flush to the PHYSICAL bottom edge (the
            // `.ignoresSafeArea(edges: .bottom)` below), so its bottom in GLOBAL
            // coordinates IS the screen's bottom — i.e. the screen height. Read
            // that way rather than from `UIScreen` so the sheet stays correct in
            // any host (previews, the showcase) and needs no UIKit import here.
            let screenHeight = geo.frame(in: .global).maxY
            let detents = detentHeights(containerHeight: geo.size.height, screenHeight: screenHeight)
            Group {
            #if canImport(UIKit)
            if let crossfade {
                // MYR-236 round 5.3 — two-layer crossfade (mirrors the rider
                // idle↔search sheet). The base is the always-opaque sheet wash +
                // the stationary grab handle; the two layers ride over it with
                // engine-driven alphas. The high layer carries the scrollable
                // dense content, so the engine's scroll handoff discovers ITS
                // ScrollView (base + low have none).
                PanSheet(
                    detentHeights: detents,
                    selection: selectionIndex(count: detents.count),
                    reduceMotion: reduceMotion,
                    accessibilityIdentifier: "mrt.detentSheet",
                    accessibilityLabel: "Sheet",
                    crossfade: PanSheetCrossfade(
                        low: { crossfadeLayer(crossfade.low, scrollBottomReserve: scrollBottomReserve(detents)) },
                        high: { crossfadeLayer(crossfade.high, scrollBottomReserve: scrollBottomReserve(detents)) }
                    ),
                    // MYR-332 — the expanded layer is fully faded in at HALF; the
                    // tall detent only reveals more of that same layer, so the
                    // crossfade must NOT stretch across it (peek/half stay
                    // byte-identical to the two-detent sheet).
                    progressUpperDetentIndex: 1
                ) {
                    baseWash(surfaceHeight: detents[detents.count - 1])
                }
            } else {
                PanSheet(
                    detentHeights: detents,
                    selection: selectionIndex(count: detents.count),
                    reduceMotion: reduceMotion,
                    accessibilityIdentifier: "mrt.detentSheet",
                    accessibilityLabel: "Sheet"
                ) {
                    sheetSurface(surfaceHeight: detents[detents.count - 1])
                }
            }
            #else
            sheetSurface(surfaceHeight: detents[detents.count - 1])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            #endif
            }
            // MYR-332 — publish the resolved detent geometry so the host can
            // re-anchor chrome off it (the owner map's `bottomContentInset`).
            .preference(key: MRTDetentHeightsKey.self, value: detents)
        }
        .onPreferenceChange(MRTDetentHeightsKey.self) { heights in
            guard !heights.isEmpty else { return }
            onResolvedHeights?(heights)
        }
        // Full-bleed geometry (CLAUDE.md "Hard rules"): components.jsx
        // `BottomSheet` is called with `navHeight={0}` (screens.jsx:429) —
        // the sheet surface always runs flush to the screen's PHYSICAL bottom
        // edge; any floating nav bar is a sibling anchored independently on
        // top of it (see `mrtBottomNav`), not something this sheet insets for
        // (MYR-196 punch-list #2).
        .ignoresSafeArea(edges: .bottom)
    }

    /// The hosted surface — grab handle + content, top-aligned so the handle
    /// leads (the engine lays it out once at `half` + overshoot pad). The
    /// accessibility adjustable action keeps keyboard/VoiceOver detent control
    /// working: setting `detent` drives the engine's programmatic settle.
    @ViewBuilder
    private func sheetSurface(surfaceHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            grabHandle
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: surfaceHeight + 48) // matches the engine's surface height (max detent + overshoot pad)
        .frame(maxWidth: .infinity)
        .mrtSurface(.sheet, fill: .mrtBgSecondary)
    }

    /// The grab handle + its VoiceOver adjustable-detent action, shared by the
    /// single-content surface and the crossfade base. MYR-332: increment walks
    /// peek → half → tall (and decrement back) on a sheet that offers the tall
    /// detent, so the new stop is reachable without a finger; on every other
    /// sheet the pair is exactly as before.
    private var grabHandle: some View {
        MRTGrabHandle()
            .contentShape(Rectangle().inset(by: -12))
            .accessibilityLabel("Sheet handle")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    detent = (detent == .half && allowsTallDetent) ? .tall : .half
                case .decrement:
                    detent = detent == .tall ? .half : .peek
                @unknown default: break
                }
            }
    }

    // MARK: MYR-236 round 5.3 — crossfade base + layers

    /// The always-opaque base for the crossfade sheet: the sheet wash spanning
    /// the full envelope (incl. the overshoot pad, so an upward rubber-band
    /// never leaks the map beneath the lifted sheet) + the stationary grab
    /// handle. The two crossfade layers ride OVER this with driven alphas.
    @ViewBuilder
    private func baseWash(surfaceHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            grabHandle
            Spacer(minLength: 0)
        }
        .frame(height: surfaceHeight + 48)
        .frame(maxWidth: .infinity)
        .mrtSurface(.sheet, fill: .mrtBgSecondary)
    }

    /// Wraps a crossfade layer so its content begins beneath the base's
    /// stationary grab handle (reserving `sheetGrabHandleHeight` at the top) and
    /// top-aligns within the surface envelope. The layer background is
    /// transparent — the base wash shows through — so the peek layer contributes
    /// ONLY the summary and the expanded layer ONLY the dense content.
    ///
    /// `scrollBottomReserve` is a CONTENT margin (never a frame change — the layer
    /// must keep filling the whole envelope or a mid-drag frame would show bare
    /// wash below its content). See ``scrollBottomReserve(_:)``.
    @ViewBuilder
    private func crossfadeLayer(_ layer: AnyView, scrollBottomReserve: CGFloat) -> some View {
        layer
            .padding(.top, MRTMetrics.sheetGrabHandleHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentMargins(.bottom, scrollBottomReserve, for: .scrollContent)
    }

    /// MYR-332 — how far the expanded layer's SCROLL CONTENT must stop short of
    /// the surface envelope's bottom.
    ///
    /// The engine lays the surface out once at the TALLEST detent plus an
    /// overshoot pad, and the hosted layer fills it. Adding the tall detent
    /// therefore grew the scroll VIEWPORT by `tall − half` — and a viewport whose
    /// bottom hangs that far below the screen means scrolling to the end parks the
    /// last rows off-screen, unreachable. (The two-detent sheet had the same
    /// effect at 48pt, harmlessly absorbed by the content's own 100pt bottom
    /// padding; 300+ is not absorbable.)
    ///
    /// The reserve is exactly the growth, so at peek and half the scroll content
    /// ends where it ended before this issue — byte-identical, including the
    /// `MRT_OWNER_SCROLL=bottom` captures that rest against the content's end —
    /// and at TALL it is zero, leaving the same 48pt overshoot the half detent
    /// used to have. Zero (i.e. nothing at all changes) whenever the sheet has no
    /// tall detent.
    private func scrollBottomReserve(_ detents: [CGFloat]) -> CGFloat {
        guard detents.count > 2, detent != .tall else { return 0 }
        return max(0, detents[2] - detents[1])
    }
}

// MARK: - Crossfade owner-sheet initializer (MYR-236 round 5.3)

public extension MRTDetentSheet where Content == EmptyView {
    /// Two-layer crossfade sheet (the owner Live Map, `HomeScreen`): the `peek`
    /// layer (summary hero only) and the `expanded` layer (the full dense,
    /// scrollable content) are hosted SIMULTANEOUSLY and cross-dissolved by the
    /// drag progress at the UIKit layer — controls fade in from the first pixel
    /// of drag, with no reserve band and no gap that snaps shut at settle
    /// (MYR-236 round 5.3, mirroring `RiderIdleSearchSheet`). Render the SAME
    /// summary at the top of both layers so the crossfade reads as a stationary
    /// summary. The single-content `init` remains for other sheets.
    init<Peek: View, Expanded: View>(
        detent: Binding<MRTSheetDetent>,
        peekHeight: CGFloat = MRTMetrics.sheetPeekHeight,
        halfHeight: CGFloat? = nil,
        halfHeightFraction: CGFloat = 0.5,
        /// MYR-332 — offer the third, TALL detent above `half`.
        allowsTallDetent: Bool = false,
        /// MYR-332 — resolved detent heights, ascending (see the stored property).
        onResolvedHeights: (([CGFloat]) -> Void)? = nil,
        @ViewBuilder peek: () -> Peek,
        @ViewBuilder expanded: () -> Expanded
    ) {
        self.init(
            detent: detent,
            peekHeight: peekHeight,
            halfHeight: halfHeight,
            halfHeightFraction: halfHeightFraction,
            content: EmptyView(),
            crossfade: OwnerCrossfade(low: AnyView(peek()), high: AnyView(expanded())),
            allowsTallDetent: allowsTallDetent,
            onResolvedHeights: onResolvedHeights
        )
    }
}

// MARK: - Resolved detent geometry (MYR-332)

/// Publishes ``MRTDetentSheet``'s resolved detent heights to its host, so chrome
/// anchored off the sheet (the owner map's `bottomContentInset`) can follow it
/// without re-deriving the geometry. Ascending, points from the physical bottom.
private struct MRTDetentHeightsKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        let next = nextValue()
        if !next.isEmpty { value = next }
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
        // layout-cost metric.
        logger.notice("S req=\(Int(requested.rounded()), privacy: .public) rendered=\(Int(rendered.rounded()), privacy: .public) body=\(bodyEvals, privacy: .public)")
        #endif
    }
}
