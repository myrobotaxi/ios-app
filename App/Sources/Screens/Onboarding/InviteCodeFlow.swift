import SwiftUI
import DesignSystem
import MyRoboTaxiKit

// MARK: - Enter Invite Code — rider join (MYR-165 — Handoff §5.3,
// design/app/onboarding.jsx:407-538)
//
// entry → validating → joined. Six cells backed by a hidden text field with
// an animated caret; the active cell gets a gold ring; a rejected code
// shakes (`mrtShake`). "Use sample code →" fills RBO246. On the 6th
// character a ~1.3s validating spinner runs, then JoinedSuccess blooms in.
//
// MYR-184 — the code check is now REAL (`POST /api/invites/redeem`, §7.5.5).
// Two defects this closes, both of which shipped because `RootView` never passed
// the `validate` seam at all, leaving its `{ _ in true }` default in place:
//
//   (1) EVERY six characters "joined" on the live path — the shake affordance
//       built for a rejected code was unreachable by construction.
//   (2) The success screen then celebrated `InviteHostFixture` — "Alex's Model Y
//       · Roommate" — a person and a car that exist nowhere (MYR-228 fix (b)).
//
// The success screen is now built from `RedeemShareInviteResponse`: the server's
// `ownerFirstName` and the real granted vehicles. The simulated catalog keeps the
// prototype's forgiving check and the fixture host, so SIM is pixel-identical.
//
// `returning` (launched from rider Settings): CTA reads "Done" and the
// caller routes back to Settings instead of the tutorial (jsx app.jsx:98-101).
struct InviteCodeFlow: View {
    let onComplete: () -> Void
    let onCancel: () -> Void
    var returning = false
    /// The §7.5.5 redeem seam. Defaults to the SIMULATED catalog — the
    /// prototype's forgiving "any 6 chars joins" (jsx:421) plus the fixture host
    /// — so previews and every DEBUG scene behave exactly as before.
    var redeem: (String) async throws -> RedeemedShare = { code in
        try await SimulatedSharedVehicleCatalog().redeem(code: code)
    }
    /// MYR-184 DEBUG capture hook — fill and submit the sample code on appear.
    /// Headless tooling cannot type six characters into the hidden field, and
    /// the redeem refusals + the real success screen have no other capture
    /// route. Always `false` outside the two sharing scenes.
    var autoSubmitsSampleCode = false

    private enum Phase {
        case entry, validating, joined
    }

    private static let length = 6
    private static let sample = "RBO246" // jsx:409

    @State private var code = ""
    @State private var phase: Phase = .entry
    @State private var shakes = 0
    /// The joined host, built from the redeem response. `nil` until the code is
    /// accepted — there is no host to name before then.
    @State private var joined: RedeemedShare?
    /// A refusal that is NOT "wrong code": the rate limit, "you already have
    /// access", or an unreachable server. Rendered as a quiet line under the
    /// cells, because the shake alone would say "wrong code" — which would be
    /// false, and would send the rider off to ask for a new one.
    @State private var refusal: ShareRedemptionFailure?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.mrtBg
            OnboardingGoldWash()

            if phase == .joined, let joined {
                JoinedSuccessView(
                    joined: joined,
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

            // MYR-184 — the refusals that are NOT "wrong code". The shake +
            // clear is the right affordance for a code that does not grant
            // anything; it is the WRONG one for a rate limit (nothing is wrong
            // with the code, and retyping it burns another of the 10/minute) and
            // for "you already have access" (they are already in). Those keep the
            // entry intact and say what happened, once, quietly.
            if let refusal, phase == .entry {
                Text(refusal.riderMessage)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 26)
                    .transition(.opacity)
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
            if autoSubmitsSampleCode, phase == .entry, code.isEmpty {
                useSampleCode() // submit fires from `onChange`, exactly as a tap would
            }
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
        refusal = nil
        fieldFocused = false
        Task { @MainActor in
            // jsx:420-423 — the deliberate ~1.3s "Verifying code…" beat. Run it
            // CONCURRENTLY with the real call rather than before it, so a slow
            // server does not add 1.3s on top of its own latency and a fast one
            // still gets the full beat.
            async let beat: Void = Task.sleep(for: .milliseconds(1300))
            let result: Result<RedeemedShare, Error>
            do { result = .success(try await redeem(value)) }
            catch { result = .failure(error) }
            _ = try? await beat

            switch result {
            case .success(let share):
                joined = share
                phase = .joined
            case .failure(let error):
                // Everything non-`RestError` (including a stubbed thrower) folds
                // onto the same catalog; `.unavailable` is the honest default for
                // "we could not ask", never a verdict on the code.
                let failure = (error as? ShareRedemptionFailure) ?? .unavailable
                phase = .entry
                if failure.clearsEntry {
                    // The prototype's `mrtShake` — finally reachable.
                    shakes += 1
                    code = ""
                    refusal = nil
                } else {
                    refusal = failure
                }
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
    /// MYR-184 — built from the §7.5.5 response, not `InviteHostFixture`. The
    /// simulated catalog still returns the fixture's values, so SIM renders the
    /// same pixels; on live these are the server's `ownerFirstName` and the real
    /// granted vehicles.
    let joined: RedeemedShare
    let cta: String
    let onContinue: () -> Void

    private var owner: String { joined.ownerFirstName }
    private var first: SharedVehicleGrant? { joined.grants.first }

    /// "{Owner}'s {Vehicle}" — the ONE place the app has both halves of that
    /// phrase on the live path (§7.5.5 is the only endpoint carrying an owner
    /// name; the §7.0 catalog rows do not). Composed through
    /// `SharedVehicleTitle`, which will NOT double the owner when the nickname
    /// already names them ("Alex's Model 3" must not become "Alex's Alex's…").
    private var hostTitle: String {
        SharedVehicleTitle.compose(owner: owner, vehicle: first?.vehicleName ?? "")
    }

    /// The line under "You're in". The prototype's is "You can now ride in
    /// {owner}'s Tesla." — which is FALSE below the `rides` tier, and false in
    /// exactly the way §7.8 would then 403. It says what this grant is instead.
    private var joinedSubtitle: String {
        guard let first, first.tier != nil, !first.grantsRides else {
            return "You can now ride in \(owner)'s Tesla."
        }
        return "You can now watch \(owner)'s Tesla."
    }

    /// The card's sub-line. SIM keeps the prototype's "{relationship} · {model}".
    /// LIVE has no relationship on the wire, so it names what the grant actually
    /// is — the access tier — plus the remaining cars on a multi-vehicle invite,
    /// which is real information the rider needs and the fixture never had.
    private var hostSubtitle: String {
        guard let first else { return "Shared with you" }
        if let relationship = first.relationship {
            return "\(relationship) \u{00B7} \(first.accessLabel)"
        }
        let extra = joined.grants.count - 1
        guard extra > 0 else { return first.accessLabel }
        return "\(first.accessLabel) \u{00B7} +\(extra) more \(extra == 1 ? "vehicle" : "vehicles")"
    }

    /// The check line under the divider. It used to promise rides unconditionally
    /// ("You can request rides and watch the live map."), which is FALSE below the
    /// `rides` tier — the very promise §7.8 would then 403. It now says what this
    /// grant carries.
    private var capabilityLine: String {
        guard let first, first.tier != nil else {
            return "You can request rides and watch the live map."
        }
        if first.grantsRides { return "You can request rides and watch the live map." }
        if first.grantsHistory { return "You can watch the live map and see past trips." }
        return "You can watch the live map."
    }

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
                Text(joinedSubtitle)
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
                Avatar(name: owner, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hostTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text(hostSubtitle)
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
                Text(capabilityLine)
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
