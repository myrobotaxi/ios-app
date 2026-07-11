import SwiftUI

// MARK: - Bottom sheets (Handoff §7 + components.jsx `BottomSheet`)
//
// Two distinct interaction models, so two views (deliberate split):
//
//   • `mrtConfigSheet` — a MODAL config sheet (send-invite, vehicle detail):
//     scrim + slide-up presentation, top-corner radius 26, grab handle,
//     optional close ✕. Dismissed by scrim tap / the ✕ / the binding.
//
//   • `MRTDetentSheet` — the PERSISTENT draggable home-map sheet
//     (components.jsx `BottomSheet`): no scrim, lives in the screen layout,
//     drags between a peek height (260) and a half detent (~50% of its
//     container), snapping with .spring(response: 0.42, dampingFraction: 0.86).
//
// One view could not serve both cleanly: the config sheet is presentation
// (transient, modal, backdrop, no detents) while the detent sheet is layout
// (permanent, draggable, measures its container) — merging them would force
// every call site through unused knobs.

// MARK: - Grab handle (shared)

/// 36×4 rounded handle on elevated gray (components.jsx BottomSheet).
struct MRTGrabHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.mrtElevated)
            .frame(width: 36, height: 4)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Config sheet (modal)

public extension View {
    /// Presents a modal MyRoboTaxi config bottom sheet (Handoff §7 —
    /// send-invite, vehicle detail). Apply at the screen root so the scrim
    /// covers the whole screen.
    func mrtConfigSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        showsCloseButton: Bool = true,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MRTConfigSheetModifier(
            isPresented: isPresented,
            showsCloseButton: showsCloseButton,
            sheetContent: content
        ))
    }
}

private struct MRTConfigSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let showsCloseButton: Bool
    @ViewBuilder let sheetContent: () -> SheetContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .bottom) {
                if isPresented {
                    Color.mrtScrim
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { isPresented = false }
                        .accessibilityHidden(true)
                    sheet
                        .transition(
                            reduceMotion
                                ? AnyTransition.opacity
                                : AnyTransition.move(edge: .bottom)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.34, dampingFraction: 0.9), // mrt-sched-up ~.34s
                value: isPresented
            )
        }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            MRTGrabHandle()
            sheetContent()
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .background {
            // The shape ignores the bottom safe area so the fill runs under
            // the home indicator while content stays inside it.
            UnevenRoundedRectangle(
                topLeadingRadius: MRTMetrics.configSheetRadius,
                topTrailingRadius: MRTMetrics.configSheetRadius,
                style: .continuous
            )
            .fill(Color.mrtBgSecondary)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: MRTMetrics.configSheetRadius,
                    topTrailingRadius: MRTMetrics.configSheetRadius,
                    style: .continuous
                )
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .topTrailing) {
            if showsCloseButton { closeButton }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var closeButton: some View {
        Button {
            isPresented = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mrtTextSec)
                .frame(width: 30, height: 30)
                .background(Color.mrtElevated, in: Circle())
                // 44pt hit target around the 30pt visual.
                .contentShape(Circle().inset(by: -7))
        }
        .padding(.top, 14)
        .padding(.trailing, 14)
        .accessibilityLabel("Close")
    }
}

// MARK: - Detent sheet (persistent peek ↔ half)

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
///      height (measured via a background reader that reflects the in-flight
///      spring) and picks up from there, so there is no jump mid-settle.
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
    /// The sheet's *actual* laid-out height, measured every frame — reflects
    /// the interpolated value while the settle spring is in flight, so a
    /// re-grab can pick the sheet up from exactly where it is (interruptible,
    /// no jump).
    @State private var liveHeight: CGFloat = 0
    /// Resting height captured at drag start; `nil` when not dragging.
    @State private var dragAnchor: CGFloat?
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
            // Measure the true laid-out height (interpolated during the
            // spring) so a re-grab is jump-free.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetLiveHeightKey.self, value: proxy.size.height)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(SheetLiveHeightKey.self) { liveHeight = $0 }
            .onAppear { if sheetHeight == nil { sheetHeight = resting } }
            // External detent flips (accessibility action) and peek-height
            // changes (driving↔parked) animate to the new resting height —
            // but skip when a drag just committed the same target (its own
            // `onEnded` already ran the settle), keyed on `sheetHeight`
            // already equalling the resting value.
            .onChange(of: detent) { settleToRestingIfNeeded(resting) }
            .onChange(of: resting) { settleToRestingIfNeeded(resting) }
        }
        // Full-bleed geometry (CLAUDE.md "Hard rules"): components.jsx
        // `BottomSheet` is called with `navHeight={0}` (screens.jsx:429) —
        // the sheet surface itself always runs flush to the screen's
        // PHYSICAL bottom edge; any floating nav bar is a sibling anchored
        // independently on top of it (see `mrtBottomNav`), not something
        // this sheet insets for. Without this, the surrounding
        // safe-area-inset container stopped the sheet ~34pt short of the
        // physical bottom, exposing a band of map (and MapKit's legal
        // attribution label) below it (MYR-196 punch-list #2).
        .ignoresSafeArea(edges: .bottom)
    }

    private func dragGesture(peek: CGFloat, half: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragAnchor == nil {
                    // Pick the sheet up from wherever it visually is right now
                    // — including mid-settle — and freeze the in-flight spring
                    // at that position (no jump, requirement 4).
                    let anchor = liveHeight > 0 ? liveHeight : (sheetHeight ?? peek)
                    dragAnchor = anchor
                    setHeight(anchor, animated: false)
                    #if DEBUG
                    MRTSheetTrace.log("grab @\(Int(anchor))")
                    #endif
                }
                let raw = (dragAnchor ?? peek) + (-value.translation.height)
                // 1:1 tracking with logarithmic overscroll past either detent.
                let banded = SheetPhysics.rubberBand(raw, lowerBound: peek, upperBound: half)
                setHeight(banded, animated: false)
            }
            .onEnded { value in
                let releaseHeight = liveHeight > 0 ? liveHeight : (sheetHeight ?? peek)
                // Project the throw from release VELOCITY (up = positive), then
                // snap to the detent nearest the projected endpoint — a fast
                // flick crosses detents even on small displacement.
                let projected = releaseHeight + SheetPhysics.projection(velocity: -value.velocity.height)
                let target = SheetPhysics.nearestDetent(
                    toProjectedHeight: projected, peekHeight: peek, halfHeight: half
                )
                #if DEBUG
                MRTSheetTrace.log("release @\(Int(releaseHeight)) proj \(Int(projected)) → \(target == .peek ? "peek" : "half")")
                #endif
                dragAnchor = nil
                detent = target
                setHeight(target == .peek ? peek : half, animated: true)
            }
    }

    /// Programmatic detent change (accessibility) — commit + settle.
    private func setDetent(_ target: MRTSheetDetent, peek: CGFloat, half: CGFloat) {
        detent = target
        setHeight(target == .peek ? peek : half, animated: true)
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

/// Reports the sheet's live (interpolated) laid-out height up to the sheet
/// view so a re-grab can read the true current position.
private struct SheetLiveHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

#if DEBUG
import os

/// DEBUG-only drag trace (MYR-236) — mirrors the camera-trace convention
/// (`VehicleMapView.mrtCameraTrace`). Off unless `MRT_SHEET_TRACE=1`, so it
/// never spams the drift-gate log streams. Release builds don't compile it.
enum MRTSheetTrace {
    private static let enabled = ProcessInfo.processInfo.environment["MRT_SHEET_TRACE"] == "1"
    private static let logger = Logger(subsystem: "app.myrobotaxi.ios", category: "sheet")
    static func log(_ message: String) {
        guard enabled else { return }
        logger.info("\(message, privacy: .public)")
    }
}
#endif
