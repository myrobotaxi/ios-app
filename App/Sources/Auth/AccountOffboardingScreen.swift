import SwiftUI
import DesignSystem

// MARK: - The visual offboarding flow (MYR-366 — CLIENT-DIRECTED)
//
// The full-screen surface that REPLACED MYR-355's second confirm dialog. See
// `AccountOffboarding.swift` for the client's words, the honesty gate and the
// state machine; this file is the render.
//
// It is one screen with three faces, and which one is up is a pure function of
// `OffboardingStepperState`:
//
//   • the STEPPER while the teardown runs (and while it has failed, with the
//     failure treatment beneath it),
//   • the OWNER's "Two steps only you can do" ending, and
//   • the RIDER's check-hero ending.
//
// Nothing here can dismiss itself except the two endings' `Done` and the failure
// treatment's "Not now". By the time this screen is up the `DELETE` is in flight
// and there is nothing to cancel — an interactive dismiss would only hide a
// running teardown, which is the opposite of what the client asked this screen to
// be for.

struct AccountOffboardingScreen: View {
    let flow: AccountDeletionFlow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Held so the completed stepper is READ before the ending replaces it — the
    /// last check landing is the moment the whole screen exists to show.
    @State private var showsEnding = false

    /// How long the completed stepper is held before the ending crossfades in.
    /// Longer than one check beat, so the final checkmark is seen finishing rather
    /// than glimpsed being replaced.
    static let endingHold: Double = 0.9
    static let endingCrossfade: Double = 0.32

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            if showsEnding {
                ending
                    .transition(.opacity)
            } else {
                stepperPage
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: Self.endingCrossfade),
            value: showsEnding
        )
        // The ONE `DELETE` starts when the screen appears, together with the
        // narration — see `AccountDeletionFlow.runOffboarding`.
        .task { await flow.runOffboarding() }
        // The stepper completing is the ONLY route to an ending, and it is
        // server-gated by construction (`isComplete` needs the `204`).
        .task(id: flow.stepper.isComplete) {
            guard flow.stepper.isComplete else {
                showsEnding = false
                return
            }
            try? await Task.sleep(for: .seconds(Self.endingHold))
            guard !Task.isCancelled else { return }
            showsEnding = true
        }
        .accessibilityIdentifier("mrt.offboardingScreen")
    }

    // MARK: The stepper page

    private var stepperPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OffboardingSequence.title)
                .mrtTextStyle(.screenTitle)
                .foregroundStyle(Color.mrtText)
            Text(OffboardingSequence.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.top, 6)

            OffboardingStepper(steps: flow.offboardingSteps, state: flow.stepper)
                .padding(.top, 34)

            if flow.stepper.hasFailed {
                failureTreatment
                    .padding(.top, 30)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.shareHeaderTop)
        .padding(.bottom, 34)
        // Full-bleed geometry (MYR-196): `shareHeaderTop` is a distance from the
        // PHYSICAL top edge, exactly as every other screen heading in this app.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The standard destructive-failure treatment, in this screen's own shape:
    /// MYR-355's LOCKED notice copy, then the retry the endpoint's re-runnability
    /// makes safe, then the way back to a Settings screen the user is STILL
    /// SIGNED IN to.
    private var failureTreatment: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mrtDialogRed)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(OffboardingCopy.failureTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.mrtText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(OffboardingCopy.failureBody)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .padding(.bottom, 14)

            MRTButton(OffboardingCopy.retryLabel, variant: .gold) {
                Task { await flow.retryOffboarding() }
            }
            .accessibilityIdentifier("mrt.offboardingRetry")
            .padding(.bottom, 8)
            MRTButton(OffboardingCopy.failureDismissLabel, variant: .outlineMuted) {
                flow.dismissAfterFailure()
            }
        }
        .accessibilityIdentifier("mrt.offboardingFailure")
    }

    // MARK: The endings

    @ViewBuilder private var ending: some View {
        if flow.role == .owner {
            OwnerOffboardingEnding { flow.finish() }
        } else {
            RiderOffboardingEnding { flow.finish() }
        }
    }
}

// MARK: - The vertical stepper

/// One circle + label per step, connected by a hairline spine.
///
/// Every circle's appearance is derived from `OffboardingStepperState` and
/// nothing else, so the honesty gate cannot be bypassed by a view: there is no
/// "mark this done" call site to get wrong.
struct OffboardingStepper: View {
    let steps: [String]
    let state: OffboardingStepperState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                row(index: index, label: label)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mrt.offboardingStepper")
    }

    private func row(index: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                OffboardingStepCircle(status: status(of: index))
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(labelColor(for: status(of: index)))
                Spacer(minLength: 0)
            }
            .frame(minHeight: OffboardingMotion.ringDiameter)
            if index < steps.count - 1 {
                spine(filled: state.checkedCount > index + 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(index: index, label: label))
    }

    /// The connector between one circle's bottom and the next one's top. It fills
    /// GOLD only when the step BELOW it has checked, so the spine never runs ahead
    /// of the checkmarks it connects.
    private func spine(filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(filled ? Color.mrtGold : Color.mrtBorder)
            .frame(width: 1.5, height: OffboardingMotion.rowSpacing)
            .padding(.leading, OffboardingMotion.ringDiameter / 2 - 0.75)
            .animation(.easeOut(duration: OffboardingMotion.outlineDrawDuration), value: filled)
    }

    private func status(of index: Int) -> OffboardingStepStatus {
        if index < state.checkedCount { return .done }
        if index == state.failedIndex { return .failed }
        if index == state.activeIndex { return .active }
        return .pending
    }

    private func labelColor(for status: OffboardingStepStatus) -> Color {
        switch status {
        case .done, .active: return .mrtText
        case .failed: return .mrtDialogRed
        case .pending: return .mrtTextMuted
        }
    }

    private func accessibilityLabel(index: Int, label: String) -> String {
        switch status(of: index) {
        case .done: return "\(label). Done."
        case .active: return "\(label). In progress."
        case .failed: return "\(label). Didn\u{2019}t finish."
        case .pending: return "\(label). Waiting."
        }
    }
}

enum OffboardingStepStatus: Equatable {
    case pending
    case active
    case done
    case failed
}

// MARK: - One circle

/// The circle that animates to a gold checkmark.
///
/// The motion is the design kit's own two-part grammar and nothing invented: the
/// ring OUTLINE-DRAWS from 12 o'clock (`Circle().trim`, the same construction
/// `RouteEtchTrace` and the FSD ring use at their own scales), and then the check
/// CHECK-DRAWS inside it (`MRTCheckDrawShape`, i.e. `mrtCheckDraw`'s
/// stroke-dashoffset, onboarding.jsx:225). 0.22 + 0.18 = the client's 0.4s per
/// step; the stagger between steps is the narration's own interval, so the beats
/// never overlap.
///
/// **Reduce Motion boots each check straight to its settled state** — no ring
/// draw, no check draw, exactly as `DriveCelebration` and `LinkedTransitionView`
/// do.
struct OffboardingStepCircle: View {
    let status: OffboardingStepStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0

    private var diameter: CGFloat { OffboardingMotion.ringDiameter }

    var body: some View {
        ZStack {
            switch status {
            case .pending:
                Circle()
                    .strokeBorder(Color.mrtBorder, lineWidth: OffboardingMotion.ringLineWidth)
            case .active:
                // The step in flight. The same gold `SpinnerRing` every other
                // in-flight wait in this app uses, at the circle's own diameter —
                // including the LAST step while the `204` has not landed, which is
                // the honesty gate made visible.
                SpinnerRing(
                    diameter: diameter,
                    lineWidth: OffboardingMotion.ringLineWidth,
                    trackColor: .mrtBorder,
                    color: .mrtGold,
                    period: 0.8
                )
            case .done:
                Circle().fill(Color.mrtGoldBadgeFill)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Color.mrtGold, style: StrokeStyle(lineWidth: OffboardingMotion.ringLineWidth, lineCap: .round))
                    // Trim starts at 3 o'clock; the design's rings all draw from
                    // the top (the FSD ring's glint lands at 12 o'clock).
                    .rotationEffect(.degrees(-90))
                MRTCheckDrawShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(
                        Color.mrtGold,
                        style: StrokeStyle(
                            lineWidth: MRTCheckDrawShape.lineWidth(at: diameter * 0.62),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: diameter * 0.62, height: diameter * 0.62)
            case .failed:
                Circle().fill(Color.mrtDangerFillSoft)
                Circle().strokeBorder(Color.mrtDialogRed, lineWidth: OffboardingMotion.ringLineWidth)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.mrtDialogRed)
            }
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: status, initial: true) { _, newValue in
            guard newValue == .done else {
                ringProgress = 0
                checkProgress = 0
                return
            }
            guard !reduceMotion else {
                ringProgress = 1
                checkProgress = 1
                return
            }
            withAnimation(.easeOut(duration: OffboardingMotion.outlineDrawDuration)) {
                ringProgress = 1
            }
            withAnimation(
                .easeOut(duration: OffboardingMotion.checkDrawDuration)
                    .delay(OffboardingMotion.outlineDrawDuration)
            ) {
                checkProgress = 1
            }
        }
    }
}
