import SwiftUI

// MARK: - PairStepper (MYR-165 — Handoff §5.2, design/app/onboarding.jsx:29-58)
//
// The 4-step pairing progress tracker: Sign in · Linked · Virtual key ·
// Paired. Done steps fill `goldDeep` with a dark checkmark; the active step
// gets a goldDeep ring + halo and a `goldDeepSoft` numeral; upcoming steps
// are faint white. Steps animate `.3s ease` on change (jsx `transition`).
//
// Reusable per MYR-163's original scope: screens place it themselves
// (onboarding sits it at `MRTMetrics.pairStepperTop`, inset
// `MRTMetrics.pairStepperGutter`).
public struct PairStepper: View {
    /// The canonical pairing steps (onboarding.jsx:30).
    public static let defaultSteps = ["Sign in", "Linked", "Virtual key", "Paired"]

    private let step: Int
    private let steps: [String]

    /// - Parameters:
    ///   - step: index of the active step; every index below is done.
    ///   - steps: labels, defaulting to the pairing flow's four.
    public init(step: Int, steps: [String] = PairStepper.defaultSteps) {
        self.step = step
        self.steps = steps
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(steps.indices, id: \.self) { index in
                column(index: index)
                if index < steps.count - 1 {
                    connector(done: index < step)
                }
            }
        }
        // CSS `transition: all .3s ease` on circles + connectors.
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.3), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: Pieces

    /// One step: 26pt circle over a 9.5pt label, column width 46 (jsx:38-51).
    private func column(index: Int) -> some View {
        let done = index < step
        let active = index == step
        return VStack(spacing: 8) {
            circle(index: index, done: done, active: active)
            Text(steps[index])
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.2)
                .multilineTextAlignment(.center)
                .lineSpacing(9.5 * 0.15) // line-height 1.15
                .foregroundStyle(done || active ? Color.mrtGoldDeepSoft : .mrtTextMuted)
        }
        .frame(width: 46)
    }

    private func circle(index: Int, done: Bool, active: Bool) -> some View {
        ZStack {
            // box-shadow 0 0 0 4px rgba(140,110,42,0.12) — halo outside the
            // ring; overflows the 26pt frame without affecting layout.
            if active {
                Circle()
                    .fill(Color.mrtGoldDeepHalo)
                    .frame(width: 34, height: 34)
            }
            Circle()
                .fill(fill(done: done, active: active))
                .strokeBorder(
                    done || active ? Color.mrtGoldDeep : Color.mrtText.opacity(0.18),
                    lineWidth: 1.5
                )
                .frame(width: 26, height: 26)
            if done {
                // SFIcon "checkmark" 14, #1c1505, weight 2.4 (jsx:46)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mrtGoldDeepButtonLabel)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit() // jsx fontNum
                    .foregroundStyle(active ? Color.mrtGoldDeepSoft : .mrtTextMuted)
            }
        }
        .frame(width: 26, height: 26)
    }

    private func fill(done: Bool, active: Bool) -> Color {
        if done { return .mrtGoldDeep }
        if active { return .mrtGoldDeepActiveFill }
        return Color.mrtText.opacity(0.05)
    }

    /// Connector line: flex-1, 1.5pt tall, top-aligned at 12.5 so it bisects
    /// the 26pt circles (jsx:53-54).
    private func connector(done: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(done ? Color.mrtGoldDeep : Color.mrtText.opacity(0.12))
            .frame(height: 1.5)
            .frame(maxWidth: .infinity)
            .padding(.top, 12.5)
    }

    private var accessibilityDescription: String {
        let clamped = min(max(step, 0), steps.count - 1)
        return "Step \(clamped + 1) of \(steps.count): \(steps[clamped])"
    }
}

#Preview {
    VStack(spacing: 32) {
        PairStepper(step: 0)
        PairStepper(step: 1)
        PairStepper(step: 2)
        PairStepper(step: 3)
    }
    .padding(28)
    .background(Color.mrtBg)
    .preferredColorScheme(.dark)
}
