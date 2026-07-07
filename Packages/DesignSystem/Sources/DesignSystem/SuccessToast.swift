import SwiftUI

// MARK: - MRTSuccessToast — bottom success pill (Handoff §7)
//
// Used by: access revoked, invite sent, invite resent. A #22221f pill with a
// gold hairline border, gold checkmark + message, bottom-anchored above the
// tab bar (default offset 116). Slides up (mrt-sched-up) and auto-dismisses
// after ~2.8s.

public extension View {
    /// Presents the shared success toast over this view. Apply at the screen
    /// root; `bottomOffset` positions the pill above the floating tab bar.
    func mrtSuccessToast(
        isPresented: Binding<Bool>,
        message: String,
        bottomOffset: CGFloat = MRTMetrics.toastBottomOffset
    ) -> some View {
        modifier(MRTSuccessToastModifier(
            isPresented: isPresented,
            message: message,
            bottomOffset: bottomOffset
        ))
    }
}

private struct MRTSuccessToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let bottomOffset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Auto-dismiss delay (Handoff §7: ~2.8s).
    private static let dwell: UInt64 = 2_800_000_000

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isPresented {
                MRTSuccessToastPill(message: message)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.bottom, bottomOffset)
                    .transition(
                        reduceMotion
                            ? AnyTransition.opacity
                            : AnyTransition.move(edge: .bottom).combined(with: .opacity)
                    )
                    .task {
                        try? await Task.sleep(nanoseconds: Self.dwell)
                        if !Task.isCancelled { isPresented = false }
                    }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPresented)
    }
}

private struct MRTSuccessToastPill: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mrtGold)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mrtText)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.mrtToastSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtGold, lineWidth: MRTMetrics.hairline))
        .accessibilityElement(children: .combine)
    }
}
