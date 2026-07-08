import SwiftUI
import DesignSystem

// MARK: - RouteSentToast (MYR-171, design/app/ride-request.jsx RouteSentToast
// 1426-1453)
//
// Top-anchored confirmation banner shown after the owner accepts an incoming
// request. Deliberately its own small view rather than DesignSystem's
// `mrtSuccessToast` (SuccessToast.swift): different copy shape (title +
// secondary line vs. one line), a leading icon-circle instead of an inline
// checkmark, bottom- vs. top-anchored placement, and a different auto-dismiss
// window (`RideRequestTiming.toastAutoDismissDuration`, 4.2s, vs. that
// component's fixed ~2.8s) — see this issue's spec for why these aren't the
// same component.
struct RouteSentToast: View {
    /// `nil` hides the toast. `HomeScreen` owns this binding and clears it
    /// itself after the auto-dismiss `Task.sleep` below completes.
    @Binding var content: RouteSentToastContent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let content {
                pill(content)
                    .transition(
                        reduceMotion
                            ? AnyTransition.opacity
                            : AnyTransition.move(edge: .top).combined(with: .opacity)
                    )
                    .task(id: content) {
                        try? await Task.sleep(nanoseconds: UInt64(RideRequestTiming.toastAutoDismissDuration * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self.content = nil
                    }
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.3) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.42), // mrt-sched-up-ish
            value: content
        )
        .padding(.horizontal, 14)
        .padding(.top, MRTMetrics.routeSentToastTop)
        // Physical-edge offset, not safe-area relative — CLAUDE.md
        // "Full-bleed geometry" (MYR-196), same posture as `MapHeader`'s
        // `mapHeaderTop`.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private func pill(_ content: RouteSentToastContent) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.mrtGold.opacity(0.18))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Color.mrtGold.opacity(0.33), lineWidth: MRTMetrics.hairline))
                .overlay(
                    Image(systemName: content.isScheduled ? "calendar" : "paperplane.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mrtGold)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                Text(content.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.mrtDialogCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.mrtGold.opacity(0.27), lineWidth: MRTMetrics.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

/// `RouteSentToast`'s content — three copy variants per this issue's spec
/// (now/no-passenger, now/passenger, scheduled), built by `HomeScreen` at the
/// moment the owner's accept choreography completes.
struct RouteSentToastContent: Equatable {
    let title: String
    let subtitle: String
    let isScheduled: Bool
}

#Preview {
    ZStack {
        Color.mrtBg.ignoresSafeArea()
        RouteSentToast(content: .constant(
            RouteSentToastContent(
                title: "Destination sent to Cybercab",
                subtitle: "Heading to Ferry Building \u{00B7} 6 min",
                isScheduled: false
            )
        ))
    }
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
