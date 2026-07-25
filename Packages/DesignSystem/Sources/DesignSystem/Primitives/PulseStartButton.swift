import SwiftUI

// MARK: - PulseStartButton (MYR-270, part B — the rider "Start ride" CTA)
//
// The rider's "Start ride" moment (arrived → enroute) is a CIRCULAR pulsing CTA:
// a round gold core with concentric expanding pulse rings (a radar look), the
// sacred gold accent reserved for real actionable moments. It COMPOSES the two
// existing gold-CTA idioms rather than inventing a third:
//   • the expanding-ring animation of `PulseDot` (scale up + fade to 0 on a 2s
//     ease-out loop) — here two staggered rings for the radar feel;
//   • the gold `outline-draw`/`mrt-gold-pulse` label breathe (gold → #F0D27A with
//     a soft glow) on the core wordmark.
// Tokens only (no hardcoded hex). HONORS Reduce Motion: no expanding rings and no
// breathe — a single STATIC gold ring around the solid gold core (mirroring
// `PulseDot` / the `mrt-gold-pulse` reduced fallback). Min 44pt tap target (the
// core is far larger). A11y: one button labeled "Start ride".
public struct PulseStartButton: View {
    private let title: String
    private let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring1 = false
    @State private var ring2 = false
    @State private var breathing = false

    /// Solid gold core diameter; the expanding rings scale beyond it (the
    /// surrounding frame reserves room so they never clip against sibling content).
    private let coreSize: CGFloat = 92
    private var reservedSize: CGFloat { coreSize * 1.75 }

    public init(_ title: String = "START", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if reduceMotion {
                    // Reduce Motion → ONE static ring, no expansion (PulseDot / the
                    // mrt-gold-pulse reduced fallback).
                    Circle()
                        .stroke(Color.mrtGold.opacity(0.5), lineWidth: 2)
                        .frame(width: coreSize + 22, height: coreSize + 22)
                } else {
                    ring(active: ring1)
                    ring(active: ring2)
                }
                core
            }
            .frame(width: reservedSize, height: reservedSize)
            .contentShape(Circle())
        }
        .buttonStyle(MRTPressScaleButtonStyle())
        .accessibilityLabel("Start ride")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { ring1 = true }
            // Stagger the second ring by half the period for the radar cadence.
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false).delay(1)) { ring2 = true }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
        }
    }

    /// One expanding radar ring — gold, scaling 1 → 1.7 while fading 0.6 → 0
    /// (the `mrt-pulse-ring` shape, applied to a hairline stroke).
    private func ring(active: Bool) -> some View {
        Circle()
            .stroke(Color.mrtGold, lineWidth: 2)
            .frame(width: coreSize, height: coreSize)
            .scaleEffect(active ? 1.7 : 1)
            .opacity(active ? 0 : 0.6)
    }

    /// The solid gold core + breathing wordmark (dark-on-gold), with the gold glow.
    private var core: some View {
        Circle()
            .fill(Color.mrtGold)
            .frame(width: coreSize, height: coreSize)
            .overlay(
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.mrtGoldButtonLabel)
            )
            .shadow(color: .mrtGoldGlow, radius: reduceMotion ? 8 : (breathing ? 18 : 8))
    }
}
