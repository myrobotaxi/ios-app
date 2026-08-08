import SwiftUI
import DesignSystem
import MyRoboTaxiKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Enter Invite Code — rider join (MYR-165 — Handoff §5.3,
// design/app/onboarding.jsx:407-538)
//
// entry → validating → joined. Six cells backed by a hidden text field with
// an animated caret; the active cell gets a gold ring; a rejected code
// shakes (`mrtShake`). "Use sample code →" fills RBO246 — DEBUG BUILDS ONLY,
// see the gate at its own call site below. On the 6th
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
    /// MYR-346 — a code handed in from OUTSIDE the field, by a
    /// `https://myrobotaxi.app/join/{CODE}` universal link. Already sanitised
    /// (`InviteLink.sanitize` — upper-case `[A-Z0-9]`, exactly six) by the time
    /// it gets here; this screen re-cleans it anyway through the same `onChange`
    /// every keystroke goes through, so there is no second sanitiser to keep in
    /// step.
    ///
    /// This is the ENTIRE external entry point into this screen's entry state,
    /// on purpose. It sets `code` and lets the existing `onChange` do the rest —
    /// the clean, the clamp, and the auto-submit on the 6th character are all
    /// the shipping ones, so a link redeems by exactly the path a rider's
    /// thumb does. Nothing about the cell input, the hidden field, or `submit`
    /// is reachable from outside, which is what keeps this mergeable alongside
    /// MYR-344's work inside those internals.
    var prefilledCode: String?

    private enum Phase {
        case entry, validating, joined
    }

    private static let length = InviteCodeEntry.length
    #if DEBUG
    private static let sample = "RBO246" // jsx:409
    #endif

    @State private var code = ""
    @State private var phase: Phase = .entry
    @State private var shakes = 0
    /// A paste that carried no code at all. Quiet, one line, in the same slot the
    /// non-shake refusals use — never a shake, because nothing was rejected.
    @State private var pasteNotice: String?
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
                // MYR-344 — the long-press route. The cells are the thing that
                // LOOKS like a text field, so they are where a rider long-presses
                // expecting the system Paste item; the field actually backing them
                // is 1×1 and invisible, so iOS's own edit menu can never be
                // summoned on it. Reading the pasteboard here is explicit intent
                // (the rider tapped an item that says Paste), which is the bar
                // iOS's own paste prompt is asking about.
                .contextMenu {
                    Button {
                        pasteFromPasteboard()
                    } label: {
                        Label("Paste code", systemImage: "doc.on.clipboard")
                    }
                    .disabled(phase != .entry)
                }

            pasteAffordance

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
            } else if let pasteNotice, phase == .entry {
                // MYR-344 — the same quiet treatment, for the same reason: a
                // pasteboard holding a phone number is not a rejected code, so it
                // must not shake or clear anything.
                Text(pasteNotice)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 26)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            // The prototype's dev affordance (jsx:409), and DEBUG-ONLY now.
            // It was UNGATED: its only condition was `phase != .entry`, so
            // every external TestFlight rider was shown a gold button that
            // fires a REAL `POST /api/invites/redeem` for the fixture code
            // against whatever backend the build points at — somebody else's
            // sample invite, redeemed by a stranger, on the live path.
            //
            // A release build does not compile it AT ALL, which is the guard:
            // there is no runtime flag to get backwards. The two capture scenes
            // reach the same fill through `autoSubmitsSampleCode` below (also
            // DEBUG-only), so every DEBUG scene is byte-identical.
            #if DEBUG
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
            .accessibilityIdentifier("mrt.invite.useSampleCode")
            #endif
        }
        .padding(.top, 132)
        .padding(.horizontal, MRTMetrics.onboardingGutter)
        .padding(.bottom, 38)
        .mrtFadeUp(duration: 0.4)
        // "Tap anywhere to focus the hidden field" — jsx:470's whole-screen tap
        // target. MYR-344 moved it BEHIND the content instead of in front of it:
        // as a foreground `.contentShape` + `.onTapGesture` it was the screen's
        // gesture recognizer and it swallowed taps aimed at the UIKit-hosted paste
        // control inside it (observed: the control drew, and every tap on it did
        // nothing). Behind the content, a tap still falls through every
        // non-interactive Text to reach it, and interactive children get their
        // taps first.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
        }
        // Keyed on `prefilledCode` (universal links) so a SECOND join link
        // arriving while this screen is up re-prefills it. With no link the id
        // is `nil` and this runs exactly once on appear, as `.task` did.
        .task(id: prefilledCode) {
            // jsx:416 — focus after the entrance settles (350ms).
            try? await Task.sleep(for: .milliseconds(350))
            fieldFocused = true
            guard phase == .entry else { return }
            if let prefilledCode {
                prefill(prefilledCode)
            } else {
                // DEBUG-only with the affordance it stands in for. Written as a
                // nested `if` rather than an `else if` because a bare `else if`
                // is not a complete statement and cannot be wrapped in `#if`.
                #if DEBUG
                if autoSubmitsSampleCode, code.isEmpty {
                    useSampleCode() // submit fires from `onChange`, exactly as a tap would
                }
                #endif
            }
        }
    }

    // MARK: Paste (MYR-344)

    /// The keyboard-height affordance: a system **`UIPasteControl`** (SwiftUI's
    /// `PasteButton` is exactly that control), which hands the payload over on its
    /// own tap with NO paste prompt at all — the strongest form of "user intent"
    /// iOS offers, and the reason this is not a hand-rolled button that reads
    /// `UIPasteboard.general.string` behind the rider's back.
    ///
    /// It is shown for the whole of `.entry` and gated on NOTHING ELSE. The
    /// obvious-looking alternative — draw it only when the pasteboard holds a
    /// candidate — cannot be built honestly: the only contents-blind probe iOS
    /// offers is `UIPasteboard.hasStrings`, and **`hasStrings` is `true` for an
    /// EMPTY string item** (measured: a freshly-cleared pasteboard still reports
    /// text), so the probe cost a pasteboard touch, made the screen's rendering
    /// depend on ambient clipboard state — the drift captures moved with the host
    /// machine's clipboard — and did not actually answer the question. Anything
    /// that WOULD answer it is a read without intent. So the app never touches the
    /// pasteboard at all, and a paste carrying no code is answered by
    /// `pasteNotice` after the fact, which is the honest place for that answer.
    ///
    /// Deliberate DEVIATION from the prototype, which has no paste affordance
    /// anywhere (onboarding.jsx:440-489 is keystrokes only): the prototype was
    /// never handed a code by text message. Tinted to the gold accent and directly
    /// under the cells, above the keyboard, so it is in the same glance as the
    /// thing it fills.
    @ViewBuilder
    private var pasteAffordance: some View {
        if phase == .entry {
            PasteButton(payloadType: String.self) { strings in
                guard let first = strings.first else { return }
                Task { @MainActor in acceptPasted(first) }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .tint(Color.mrtGold)
            .frame(minHeight: MRTMetrics.minTapTarget)
            .padding(.top, 24)
            .accessibilityIdentifier("mrt.invite.pasteCode")
            .transition(.opacity)
        }
    }

    /// The long-press route's read. Reached only from the "Paste code" menu item,
    /// so the read is the rider's own request; iOS may show its paste prompt on
    /// top of it, which is the correct place for that question to be asked.
    private func pasteFromPasteboard() {
        #if canImport(UIKit)
        guard phase == .entry else { return }
        acceptPasted(UIPasteboard.general.string ?? "")
        #endif
    }

    /// Everything pasted lands here, from either route.
    ///
    /// `InviteCodeEntry.extractCode` finds the candidate — "code: rbo246!" and
    /// the whole share message both resolve to RBO246 — and a COMPLETE one then
    /// submits exactly as the 6th keystroke does, rather than sitting in the cells
    /// waiting for a button that does not exist. The one wrinkle: re-pasting the
    /// code already in the cells writes no CHANGE, so `onChange` never fires and
    /// the auto-submit has to be made here.
    private func acceptPasted(_ raw: String) {
        guard phase == .entry else { return }
        let cleaned = InviteCodeEntry.extractCode(from: raw)
        guard !cleaned.isEmpty else {
            pasteNotice = "That doesn\u{2019}t look like an invite code."
            return
        }
        pasteNotice = nil
        refusal = nil
        if code == cleaned {
            if InviteCodeEntry.isComplete(cleaned) { submit(cleaned) }
        } else {
            code = cleaned // `onChange` clamps + auto-submits, exactly as typing does
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
                // MYR-344 — the rule itself moved to `InviteCodeEntry` so the
                // paste routes cannot sanitize differently than typing does.
                let cleaned = InviteCodeEntry.sanitize(newValue)
                if cleaned != newValue { code = cleaned }
                if InviteCodeEntry.isComplete(cleaned) { submit(cleaned) }
            }
    }

    #if DEBUG
    private func useSampleCode() {
        code = Self.sample
        // (submit fires from onChange; jsx adds a 200ms beat for the fill
        // to read before the spinner — folded into the same path here.)
    }
    #endif

    /// MYR-346 — seat a code that came from a universal link. Deliberately the
    /// same one-line shape as `useSampleCode`: assign, and let `onChange` clean,
    /// clamp and auto-submit. Assigning a value equal to what is already there
    /// fires no `onChange`, so re-delivering the same link is a genuine no-op
    /// rather than a second redeem against the 10-per-minute limit.
    private func prefill(_ value: String) {
        code = value
    }

    private func submit(_ value: String) {
        guard phase == .entry else { return }
        phase = .validating
        refusal = nil
        pasteNotice = nil
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
    /// MYR-369 — the HISTORY rung is gone from this ladder, with the tier it
    /// described. The drives surfaces are owner-only now and no share grant opens
    /// them, so "…and see past trips" was a promise no value of the wire can keep
    /// — and unlike the pre-MYR-184 rides promise, it would have been unreachable
    /// rather than merely wrong, since `live_history` is never emitted. Two rungs
    /// remain, matching the two presets the composer can now send.
    private var capabilityLine: String {
        guard let first, first.tier != nil else {
            return "You can request rides and watch the live map."
        }
        return first.grantsRides
            ? "You can request rides and watch the live map."
            : "You can watch the live map."
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
