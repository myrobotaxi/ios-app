import SwiftUI
import DesignSystem

// MARK: - The endings (MYR-366 — CLIENT-DIRECTED)
//
// The client asked for "animated visuals in the end to demonstrate how to unpair
// the tesla virtual key, etc anything else manual required". There are exactly
// two such things and both are the OWNER's, because both live inside Tesla:
//
//   (a) the enrolled VIRTUAL KEY, which sits on the car's own touchscreen. §7.12
//       states `automatable: false` — there is no Fleet API call and no deep link
//       for removing it, so instructions are the entire capability any client
//       has here, which is precisely why they are worth drawing rather than
//       listing.
//   (b) the OAuth GRANT in the owner's Tesla account. Only Tesla can revoke a
//       third-party grant and only the account holder can ask it to.
//
// A RIDER has neither: nothing of theirs was ever enrolled in a car and they
// never authorized Tesla. Their ending says so and stops — "Your account is
// deleted. Nothing remains." An "optional next steps" section with nothing in it
// would be the MYR-347 empty-section defect on a screen someone reads once.
//
// **Every illustration is pure SwiftUI shapes on the token palette — no assets.**
// They are also per-frame `TimelineView(.animation)` renders rather than
// `offset`-animated masked layers, which is MYR-326/MYR-337's lesson: a masked
// band can composite once and never re-render, looking motionless both in stills
// and in reality.
//
// **Reduce Motion renders the static END-STATE frame** — the key gone, the toggle
// off. The end state is what the reader has to recognise on their own screen, so
// it is the honest still.

// MARK: - Owner ending

struct OwnerOffboardingEnding: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(OffboardingCopy.ownerEndingTitle)
                        .mrtTextStyle(.screenTitle)
                        .foregroundStyle(Color.mrtText)
                    Text(OffboardingCopy.ownerEndingSubtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)

                    manualStep(.virtualKey, index: 1) { VirtualKeyRemovalIllustration() }
                        .padding(.top, 26)
                    manualStep(.appAccess, index: 2) { AppAccessRevokeIllustration() }
                        .padding(.top, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.top, MRTMetrics.shareHeaderTop)
                .padding(.bottom, 22)
            }
            MRTButton(OffboardingCopy.doneLabel, variant: .gold, action: onDone)
                .accessibilityIdentifier("mrt.offboardingDone")
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityIdentifier("mrt.ownerOffboardingEnding")
    }

    /// One numbered manual step: its illustration, then the client's own caption
    /// (title + literal menu path) beneath it.
    private func manualStep<Illustration: View>(
        _ step: ManualOffboardingStep,
        index: Int,
        @ViewBuilder illustration: () -> Illustration
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.mrtGoldBadgeFill)
                    Text("\(index)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtGold)
                }
                .frame(width: 22, height: 22)
                Text(step.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            illustration()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 11)

            Text(step.path)
                .font(.system(size: 12))
                .foregroundStyle(Color.mrtTextSec)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index). \(step.caption)")
    }
}

// MARK: - Rider ending

/// No manual steps exist for a rider, so the ending is the one true sentence and
/// the way out. The hero is the same drawn gold check the stepper's circles use,
/// at hero scale.
struct RiderOffboardingEnding: View {
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    private static let heroDiameter: CGFloat = 86

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Color.mrtGoldBadgeFill)
                Circle()
                    .strokeBorder(Color.mrtGoldBorderQuiet, lineWidth: 1.5)
                MRTCheckDrawShape()
                    .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                    .stroke(
                        Color.mrtGold,
                        style: StrokeStyle(
                            lineWidth: MRTCheckDrawShape.lineWidth(at: 46),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: 46, height: 46)
                    .animation(.easeOut(duration: 0.5).delay(0.12), value: drawn)
            }
            .frame(width: Self.heroDiameter, height: Self.heroDiameter)
            .padding(.bottom, 26)

            Text(OffboardingCopy.riderEndingTitle)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Color.mrtText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text(OffboardingCopy.riderEndingSubtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
            MRTButton(OffboardingCopy.doneLabel, variant: .gold, action: onDone)
                .accessibilityIdentifier("mrt.offboardingDone")
                .padding(.bottom, 34)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { drawn = true }
        .accessibilityIdentifier("mrt.riderOffboardingEnding")
    }
}

// MARK: - The COMPACT manual steps (MYR-366 — vehicle-removal parity)

/// The same two manual steps, as INFORMATION rather than ceremony.
///
/// Removing your LAST/only car leaves exactly the state deleting the account
/// leaves: the MyRoboTaxi key still enrolled on that car's touchscreen, and
/// MyRoboTaxi still holding a grant in your Tesla account. MYR-258's confirm said
/// so in prose ("Two owner-only steps … come next") and then the post-teardown
/// sheet listed the server's own steps — so the owner learned what was coming
/// AFTER deciding. This puts the two steps in the confirm, where the decision is.
///
/// It is deliberately NOT the animated version. A confirm dialog is a question,
/// and a looping animation inside one competes with the buttons for the eye; the
/// full ceremony belongs on the screen the owner lands on when there is nothing
/// left to decide. Both read `ManualOffboardingStep`, so the menu paths are one
/// fact in one place (`AccountOffboardingTests` pins that the compact rows and
/// the ceremony's captions are composed from the same strings).
struct CompactManualOffboardingSteps: View {
    var steps: [ManualOffboardingStep] = ManualOffboardingStep.both

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ManualOffboardingStep.compactHeading)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: step.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mrtTextSec)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.mrtText)
                        Text(step.path)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.mrtTextSec)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
        .accessibilityIdentifier("mrt.compactManualSteps")
    }
}

// MARK: - Illustration timing
//
// Both loops share ONE period so the two cards read as one instruction rather
// than two clocks, and the client's own "~3s, subtle" is that period.

enum ManualStepIllustration {
    static let loopPeriod: Double = 3.0
    /// Card geometry, shared so the two illustrations are the same size and the
    /// two cards cannot end up different heights.
    static let width: CGFloat = 214
    static let height: CGFloat = 118
    static let radius: CGFloat = 12

    /// The loop's normalised position at wall-clock `t`.
    static func phase(_ t: TimeInterval) -> Double {
        t.truncatingRemainder(dividingBy: loopPeriod) / loopPeriod
    }

    /// A smooth 0→1 ramp across `[from, to]`, clamped outside it. The one
    /// interpolation both illustrations are built from, so their motion curves
    /// match.
    static func ramp(_ p: Double, from: Double, to: Double) -> Double {
        guard to > from else { return p >= to ? 1 : 0 }
        let x = min(max((p - from) / (to - from), 0), 1)
        // smoothstep — the eye tracks an eased move and reads a linear one as a
        // slide-in-a-slot.
        return x * x * (3 - 2 * x)
    }

    /// The stage the surrounding chrome sits on.
    static func stage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: width, height: height)
            .background(Color.mrtBg, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - (a) The car touchscreen losing the MyRoboTaxi key

/// A stylised car touchscreen: a left icon rail, a "Locks" panel, and three key
/// rows. The MyRoboTaxi row highlights, then slides right and fades out — which
/// is what the reader will do with their thumb on the real screen.
struct VirtualKeyRemovalIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // The static END-STATE frame: the key is gone.
            frame(highlight: 0, slide: 1, fade: 0)
        } else {
            TimelineView(.animation) { context in
                let p = ManualStepIllustration.phase(context.date.timeIntervalSinceReferenceDate)
                // 0.00–0.28 rest · 0.28–0.42 highlight · 0.42–0.66 slide out
                // 0.66–0.88 hold empty · 0.88–1.00 fade back for the next loop
                let highlight = ManualStepIllustration.ramp(p, from: 0.28, to: 0.42)
                    * (1 - ManualStepIllustration.ramp(p, from: 0.42, to: 0.60))
                let slide = ManualStepIllustration.ramp(p, from: 0.42, to: 0.66)
                let out = ManualStepIllustration.ramp(p, from: 0.44, to: 0.62)
                let back = ManualStepIllustration.ramp(p, from: 0.88, to: 1.0)
                frame(highlight: highlight, slide: slide, fade: max(1 - out, back))
            }
        }
    }

    private func frame(highlight: Double, slide: Double, fade: Double) -> some View {
        ManualStepIllustration.stage {
            HStack(spacing: 0) {
                iconRail
                VStack(alignment: .leading, spacing: 6) {
                    panelTitle
                    keyRow(label: 18, isSubject: false, highlight: 0, slide: 0, fade: 1)
                    keyRow(label: 34, isSubject: true, highlight: highlight, slide: slide, fade: fade)
                    keyRow(label: 22, isSubject: false, highlight: 0, slide: 0, fade: 1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
    }

    /// The car UI's left rail — three glyph tiles, no meaning beyond "this is a
    /// car screen and not a phone".
    private var iconRail: some View {
        VStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(index == 1 ? Color.mrtGoldBadgeFill : Color.mrtElevated)
                    .frame(width: 14, height: 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.leading, 10)
        .frame(width: 34, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline)
        }
    }

    private var panelTitle: some View {
        Text("Locks")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Color.mrtTextMuted)
            .padding(.bottom, 1)
    }

    /// One key row. `label` is the width of its stand-in name bar; the SUBJECT row
    /// carries the gold key glyph and the "MyRoboTaxi" name in full, because it is
    /// the one the reader has to find.
    private func keyRow(label: CGFloat, isSubject: Bool, highlight: Double, slide: Double, fade: Double) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isSubject ? Color.mrtGold : Color.mrtTextMuted.opacity(0.5))
                .frame(width: 9, height: 5)
            if isSubject {
                Text("MyRoboTaxi")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.mrtTextMuted.opacity(0.35))
                    .frame(width: label, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSubject ? Color.mrtGoldBadgeFill.opacity(0.5 + 0.5 * highlight) : Color.mrtSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSubject ? Color.mrtGold.opacity(0.25 + 0.65 * highlight) : Color.mrtBorder,
                    lineWidth: MRTMetrics.hairline + (isSubject ? highlight : 0)
                )
        )
        .offset(x: slide * 74)
        .opacity(fade)
    }
}

// MARK: - (b) The Tesla app revoking MyRoboTaxi's access

/// A stylised third-party-apps list whose MyRoboTaxi row has its access switch
/// turned off. Same period, same stage, so the pair reads as one sequence.
struct AppAccessRevokeIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // The static END-STATE frame: access off.
            frame(on: 0)
        } else {
            TimelineView(.animation) { context in
                let p = ManualStepIllustration.phase(context.date.timeIntervalSinceReferenceDate)
                // 0.00–0.32 on · 0.32–0.52 flip off · 0.52–0.88 off · 0.88–1.00 back on
                let off = ManualStepIllustration.ramp(p, from: 0.32, to: 0.52)
                let backOn = ManualStepIllustration.ramp(p, from: 0.88, to: 1.0)
                frame(on: max(1 - off, backOn))
            }
        }
    }

    private func frame(on: Double) -> some View {
        ManualStepIllustration.stage {
            VStack(alignment: .leading, spacing: 6) {
                Text("Third-Party Apps")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.bottom, 1)
                appRow(isSubject: false, nameWidth: 42, on: 1)
                appRow(isSubject: true, nameWidth: 0, on: on)
                appRow(isSubject: false, nameWidth: 30, on: 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appRow(isSubject: Bool, nameWidth: CGFloat, on: Double) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSubject ? Color.mrtGoldBadgeFill : Color.mrtElevated)
                .frame(width: 14, height: 14)
            if isSubject {
                Text("MyRoboTaxi")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.mrtTextMuted.opacity(0.35))
                    .frame(width: nameWidth, height: 5)
            }
            Spacer(minLength: 0)
            miniToggle(on: isSubject ? on : 1, isSubject: isSubject)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSubject ? Color.mrtGoldBadgeFill.opacity(0.5) : Color.mrtSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSubject ? Color.mrtGoldBorderQuiet : Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
    }

    /// A drawn switch, not `MRTToggle` — this is an ILLUSTRATION of Tesla's UI,
    /// and using the app's own interactive control here would claim the reader can
    /// flip it from this screen.
    private func miniToggle(on: Double, isSubject: Bool) -> some View {
        let width: CGFloat = 26
        let height: CGFloat = 15
        let knob: CGFloat = 11
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(
                    isSubject
                        ? Color.mrtGold.opacity(0.22 + 0.55 * on)
                        : Color.mrtElevated
                )
            Circle()
                .fill(isSubject && on > 0.5 ? Color.mrtGold : Color.mrtTextMuted)
                .frame(width: knob, height: knob)
                .offset(x: 2 + (width - knob - 4) * on)
        }
        .frame(width: width, height: height)
    }
}
