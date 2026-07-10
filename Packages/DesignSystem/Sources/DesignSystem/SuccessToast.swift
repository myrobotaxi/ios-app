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
    ///
    /// `systemImage`/`tint` default to the success look (gold checkmark + gold
    /// hairline), so every existing caller renders byte-identically. A calm
    /// non-success notice (e.g. MYR-220's session/connection retry) passes a
    /// muted glyph + tint to reuse this SAME pill without a dramatic error UI.
    func mrtSuccessToast(
        isPresented: Binding<Bool>,
        message: String,
        systemImage: String = "checkmark",
        tint: Color = .mrtGold,
        bottomOffset: CGFloat = MRTMetrics.toastBottomOffset
    ) -> some View {
        modifier(MRTSuccessToastModifier(
            isPresented: isPresented,
            message: message,
            systemImage: systemImage,
            tint: tint,
            bottomOffset: bottomOffset
        ))
    }
}

private struct MRTSuccessToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let systemImage: String
    let tint: Color
    let bottomOffset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Auto-dismiss delay (Handoff §7: ~2.8s).
    private static let dwell: UInt64 = 2_800_000_000

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isPresented {
                MRTSuccessToastPill(message: message, systemImage: systemImage, tint: tint)
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
    var systemImage: String = "checkmark"
    var tint: Color = .mrtGold

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mrtText)
                .lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.mrtToastSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(tint, lineWidth: MRTMetrics.hairline))
        .accessibilityElement(children: .combine)
    }
}
