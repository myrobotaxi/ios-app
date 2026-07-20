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

    /// peek ↔ index 0, half ↔ index 1 — the engine works in detent indices.
    private var selectionIndex: Binding<Int> {
        Binding(
            get: { detent == .peek ? 0 : 1 },
            set: { detent = $0 == 0 ? .peek : .half }
        )
    }

    public var body: some View {
        GeometryReader { geo in
            let half = halfHeight ?? geo.size.height * halfHeightFraction
            // `.isFinite` guard (MYR-227): never let a stray NaN/∞ detent reach
            // the engine's layout math.
            let safeHalf = half.isFinite && half > peekHeight ? half : peekHeight + 1
            #if canImport(UIKit)
            PanSheet(
                detentHeights: [peekHeight, safeHalf],
                selection: selectionIndex,
                reduceMotion: reduceMotion,
                accessibilityIdentifier: "mrt.detentSheet",
                accessibilityLabel: "Sheet"
            ) {
                sheetSurface(half: safeHalf)
            }
            #else
            sheetSurface(half: safeHalf)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            #endif
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
    private func sheetSurface(half: CGFloat) -> some View {
        VStack(spacing: 0) {
            MRTGrabHandle()
                .contentShape(Rectangle().inset(by: -12))
                .accessibilityLabel("Sheet handle")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: detent = .half
                    case .decrement: detent = .peek
                    @unknown default: break
                    }
                }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: half + 48) // matches the engine's surface height (max detent + overshoot pad)
        .frame(maxWidth: .infinity)
        .mrtSurface(.sheet, fill: .mrtBgSecondary)
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
