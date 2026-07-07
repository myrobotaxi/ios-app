import SwiftUI
import DesignSystem

// MARK: - Enter Invite Code — rider join (MYR-165 — Handoff §5.3,
// design/app/onboarding.jsx:407-538)
//
// entry → validating → joined. Six cells backed by a hidden text field with
// an animated caret; the active cell gets a gold ring; a rejected code
// shakes (`mrtShake`). "Use sample code →" fills RBO246. On the 6th
// character a ~1.3s validating spinner runs, then JoinedSuccess blooms in.
//
// M1 validation mirrors the prototype ("forgiving: any 6 chars joins",
// jsx:421) via the injectable `validate` closure — the backend invite check
// slots in there later; a `false` result plays the shake.
//
// `returning` (launched from rider Settings): CTA reads "Done" and the
// caller routes back to Settings instead of the tutorial (jsx app.jsx:98-101).
struct InviteCodeFlow: View {
    let onComplete: () -> Void
    let onCancel: () -> Void
    var returning = false
    /// Invite-code validator seam. M1: always true, like the prototype.
    var validate: (String) async -> Bool = { _ in true }

    private enum Phase {
        case entry, validating, joined
    }

    private static let length = 6
    private static let sample = "RBO246" // jsx:409

    @State private var code = ""
    @State private var phase: Phase = .entry
    @State private var shakes = 0
    @FocusState private var fieldFocused: Bool
    private let host = InviteHostFixture()

    var body: some View {
        ZStack {
            Color.mrtBg
            OnboardingGoldWash()

            if phase == .joined {
                JoinedSuccessView(
                    host: host,
                    cta: returning ? "Done" : "Continue", // jsx:493
                    onContinue: onComplete
                )
            } else {
                entryContent
            }

            if phase == .entry {
                OnboardingTopAction(label: "Cancel", action: onCancel)
            }
        }
        // jsx positions everything from the physical screen edges; keep the
        // keyboard safe-area region so the cells lift above the keyboard.
        .ignoresSafeArea(.container)
    }

    // MARK: Entry + validating (jsx:440-489)

    private var entryContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HexLogo(size: 60, glow: true)
                    .padding(.bottom, 26)
                Text("Enter invite code")
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 12)
                Text("Ask the vehicle's owner for their 6-character code to join and request rides.")
                    .font(.system(size: 14))
                    .lineSpacing(14 * 0.55)
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(.bottom, 40)

            cells
                .modifier(Shake(trigger: shakes))
                .background(hiddenField)

            if phase == .validating {
                HStack(spacing: 10) {
                    SpinnerRing(
                        diameter: 18,
                        lineWidth: 2,
                        trackColor: .mrtGoldRing,
                        color: .mrtGold,
                        period: 0.8
                    )
                    Text("Verifying code…")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.mrtTextSec)
                }
                .padding(.top, 26)
            }

            Spacer(minLength: 0)

            Button {
                useSampleCode()
            } label: {
                Text("Use sample code →")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mrtGold)
                    .padding(10)
                    .frame(minHeight: MRTMetrics.minTapTarget)
            }
            .disabled(phase != .entry)
            .opacity(phase == .entry ? 1 : 0.4)
        }
        .padding(.top, 132)
        .padding(.horizontal, MRTMetrics.onboardingGutter)
        .padding(.bottom, 38)
        .mrtFadeUp(duration: 0.4)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
        .task {
            // jsx:416 — focus after the entrance settles (350ms).
            try? await Task.sleep(for: .milliseconds(350))
            fieldFocused = true
        }
    }

    private var cells: some View {
        HStack(spacing: 9) {
            ForEach(0..<Self.length, id: \.self) { index in
                CodeCell(
                    character: index < code.count
                        ? String(Array(code)[index])
                        : nil,
                    active: index == code.count && phase == .entry
                )
            }
        }
    }

    /// The hidden input backing the cells (jsx:470-473) — invisible, but
    /// focused so the system keyboard drives `code`.
    private var hiddenField: some View {
        TextField("", text: $code)
            .focused($fieldFocused)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .disabled(phase != .entry)
            .opacity(0)
            .frame(width: 1, height: 1)
            .accessibilityLabel("Invite code")
            .onChange(of: code) { _, newValue in
                // jsx:426-430 — uppercase, alphanumeric, clamp to 6, auto-submit.
                let cleaned = String(
                    newValue.uppercased().unicodeScalars
                        .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
                        .prefix(Self.length)
                        .map(Character.init)
                )
                if cleaned != newValue { code = cleaned }
                if cleaned.count == Self.length { submit(cleaned) }
            }
    }

    private func useSampleCode() {
        code = Self.sample
        // (submit fires from onChange; jsx adds a 200ms beat for the fill
        // to read before the spinner — folded into the same path here.)
    }

    private func submit(_ value: String) {
        guard phase == .entry else { return }
        phase = .validating
        fieldFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1300)) // jsx:420-423
            if await validate(value) {
                phase = .joined
            } else {
                // mrtShake — unreachable with the M1 always-accept validator,
                // matching the prototype; wired for the real backend check.
                phase = .entry
                shakes += 1
                code = ""
                fieldFocused = true
            }
        }
    }
}

// MARK: - Code cell (jsx:455-468)

/// One 44×56 character cell. Filled → gold-tinted; active → gold border,
/// focus ring, and a blinking caret (`mrtCaretBlink` 1s steps).
private struct CodeCell: View {
    let character: String?
    let active: Bool

    var body: some View {
        ZStack {
            if let character {
                Text(character)
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit() // jsx fontNum
                    .foregroundStyle(Color.mrtText)
            } else if active {
                BlinkingCaret()
            }
        }
        .frame(width: 44, height: 56)
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(border, lineWidth: 1))
        .background {
            // box-shadow 0 0 0 3px rgba(201,168,76,0.12)
            if active {
                shape.inset(by: -3).fill(Color.mrtGoldFocusRing)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: active) // transition .18s
        .animation(.easeInOut(duration: 0.18), value: character)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
    }

    private var fill: Color {
        character != nil ? .mrtGoldCellFill : Color.mrtText.opacity(0.04)
    }

    private var border: Color {
        if active { return .mrtGold }
        if character != nil { return .mrtGoldCellBorder }
        return Color.mrtText.opacity(0.12)
    }
}

/// `mrtCaretBlink` (jsx:474): 2×26 gold bar, 1s steps(1) blink.
/// Reduce Motion → steady caret.
private struct BlinkingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            bar
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                bar.opacity(on ? 1 : 0)
            }
        }
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.mrtGold)
            .frame(width: 2, height: 26)
    }
}

/// `mrtShake` (jsx:435): translateX 0 → -7 → 7 → -7 → 7 → 0 over 0.4s.
/// Reduce Motion → no shake (validation feedback stays visible via state).
private struct Shake: ViewModifier {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
                    view.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(0, duration: 0.0001)
                        LinearKeyframe(-7, duration: 0.08)
                        LinearKeyframe(7, duration: 0.08)
                        LinearKeyframe(-7, duration: 0.08)
                        LinearKeyframe(7, duration: 0.08)
                        LinearKeyframe(0, duration: 0.08)
                    }
                }
        }
    }
}

// MARK: - Joined success (jsx:497-538)

/// Gold bloom + check pop + "You're in", then the host card rises in.
private struct JoinedSuccessView: View {
    let host: InviteHostFixture
    let cta: String
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                SuccessBloom(diameter: 280) // jsx:503 — 280 here vs 300 paired
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                SuccessCheckBadge()
                    .padding(.bottom, 26)
                Text("You're in")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 8)
                    .mrtFadeUp(delay: 0.15)
                Text("You can now ride in \(host.owner)'s Tesla.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 30)
                    .mrtFadeUp(delay: 0.25)
                hostCard
                    .modifier(CardRise(after: 0.42)) // jsx:499 setTimeout 420
                Spacer(minLength: 0)

                MRTButton(cta, variant: .outlineStatic, action: onContinue)
                    .mrtFadeUp(delay: 0.5)
            }
            .padding(.top, 150)
            .padding(.horizontal, MRTMetrics.onboardingGutter)
            .padding(.bottom, 38)
        }
        .clipped()
    }

    private var hostCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Avatar(name: host.owner, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(host.owner)'s \(host.name)")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text("\(host.relationship) · \(host.model)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "car.fill")
                    .font(.system(size: 20, weight: .medium)) // SFIcon 22
                    .foregroundStyle(Color.mrtGold)
            }
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold)) // SFIcon 13 / weight 2.4
                    .foregroundStyle(Color.mrtDriving)
                Text("You can request rides and watch the live map.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mrtTextSec)
                Spacer(minLength: 0)
            }
            .padding(.top, 13)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtText.opacity(0.08)).frame(height: MRTMetrics.hairline)
            }
            .padding(.top, 14)
        }
        .padding(18)
        .modifier(SuccessCardBackground())
    }
}

#Preview("First run") {
    InviteCodeFlow(onComplete: {}, onCancel: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}

#Preview("Returning") {
    InviteCodeFlow(onComplete: {}, onCancel: {}, returning: true)
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
