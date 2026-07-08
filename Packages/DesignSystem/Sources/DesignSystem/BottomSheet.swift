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

/// The draggable home-map sheet (components.jsx `BottomSheet`): drag the
/// handle between peek and half; release snaps to the nearest detent with
/// `.spring(response: 0.42, dampingFraction: 0.86)` (Handoff §8 sheet snap).
///
/// Place it inside the container it should measure (it fills its parent and
/// bottom-aligns itself), e.g. layered over the map in a `ZStack`. Keep any
/// floating tab bar *outside* that container or inset the container's bottom,
/// mirroring the prototype's `navHeight` offset. Content scrolling is the
/// caller's concern (wrap in `ScrollView` for the half state).
///
/// Programmatic detent changes animate if the caller wraps them in
/// `withAnimation`.
public struct MRTDetentSheet<Content: View>: View {
    @Binding private var detent: MRTSheetDetent
    private let peekHeight: CGFloat
    private let halfHeight: CGFloat?
    private let halfHeightFraction: CGFloat
    private let content: Content

    /// Live drag delta in points (positive = taller than the resting detent).
    @State private var dragOffset: CGFloat = 0
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

    public var body: some View {
        GeometryReader { geo in
            let half = halfHeight ?? geo.size.height * halfHeightFraction
            let base = detent == .peek ? peekHeight : half
            // Rubber-band 30pt past either detent, like the prototype.
            let height = min(half + 30, max(peekHeight - 30, base + dragOffset))
            VStack(spacing: 0) {
                MRTGrabHandle()
                    // The 20pt handle strip drags; expand to a 44pt hit band.
                    .contentShape(Rectangle().inset(by: -12))
                    .gesture(dragGesture(peek: peekHeight, half: half, base: base))
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
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .mrtSurface(.sheet, fill: .mrtBgSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func dragGesture(peek: CGFloat, half: CGFloat, base: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragOffset = -value.translation.height
            }
            .onEnded { value in
                // Snap to the detent nearest the projected height.
                let projected = base - value.predictedEndTranslation.height
                let target: MRTSheetDetent = projected > (peek + half) / 2 ? .half : .peek
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: 0.2)
                        : .spring(response: 0.42, dampingFraction: 0.86)
                ) {
                    detent = target
                    dragOffset = 0
                }
            }
    }
}
