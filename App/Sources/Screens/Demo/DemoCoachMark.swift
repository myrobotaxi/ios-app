import SwiftUI
import DesignSystem

// MARK: - MYR-428 — the coach-mark layer
//
// THE LAYER OVERLAYS AND DOES NOT MODIFY. Not one line of `HomeScreen`,
// `SharedViewerScreen`, `RideRequestSearchContent` or the pickup surfaces changes
// to support this, which is a fence requirement (MYR-379 is editing those files
// in parallel) and independently the right shape: a walkthrough that had to
// thread an anchor through every screen it tours would make the tour a property
// of the screens rather than of the tour.
//
// That has one honest consequence, recorded rather than glossed: **the caption is
// placed in a BAND, not pinned to a measured element frame.** A precise ring
// around the real control would need the control to publish its frame, which is
// the modification just ruled out. So each step declares which half of the screen
// its subject lives in and the caption takes the OTHER half — the control the
// step names is never underneath the card that names it, which is the property
// that actually matters. `DemoCoachMarkPlacementTests` pins the pairing.
//
// TWO THINGS THIS DELIBERATELY DOES NOT DO:
//
//  • **NO SPOTLIGHT CUTOUT.** The obvious implementation is a full-screen scrim
//    with the highlight punched out by `blendMode(.destinationOut)` over a
//    `compositingGroup()`. Both walkthroughs run over a hosted `MKMapView`, and
//    MYR-339 is this repo's most expensive lesson about exactly that: a blend
//    mode with no backdrop to read resolves source-over against a UIKit-hosted
//    map, *and a screenshot cannot catch it* because flattening the layer tree
//    for a still is a pass in which the backdrop IS available. The client had to
//    photograph his phone. The rule that issue left behind — never let an effect
//    needing a backdrop read stand between the user and a hosted map — is
//    followed here by having no such effect at all.
//  • **NO DIMMING OF THE TOURED HALF.** The scrim is confined to the caption's
//    own band, so the control the tester is being asked to tap is at full
//    contrast. Dimming the subject of a coach mark to focus attention on it is
//    self-defeating, and over a dark map at these token alphas it reads as the
//    app having gone unresponsive.

/// Which half of the screen a step's subject occupies. The caption takes the
/// other one.
public enum DemoCaptionPlacement: Equatable, Sendable {
    /// Subject is in the lower half (a sheet, a CTA, the tab bar) → caption on top.
    case top
    /// Subject is in the upper half (the map hero, the incoming card, the dispatch
    /// banner) → caption at the bottom.
    case bottom

    /// Where each anchor's subject actually is. Derived from the screens' own
    /// layout grammar rather than guessed: the owner dispatch card sits at
    /// `OwnerMapTopChrome.dispatchCardTop` (112) and the incoming card is top
    /// chrome, so both are upper; the rider sheet, both tab bars and the owner
    /// vehicle sheet are bottom chrome (`mrtBottomNav`, the sheet detents).
    public static func forAnchor(_ anchor: DemoAnchor) -> DemoCaptionPlacement {
        switch anchor {
        case .ownerVehicleHero: return .top
        case .ownerIncomingCard: return .bottom
        case .ownerAcceptButton: return .bottom
        case .ownerDispatchCard: return .bottom
        case .ownerDispatchAction: return .bottom
        case .ownerTabBar: return .top
        case .riderSearchBar: return .top
        case .riderDestinationList: return .top
        case .riderRequestButton: return .top
        case .riderTrackingSheet: return .top
        case .riderSummaryCard: return .top
        case .riderTabBar: return .top
        }
    }
}

// MARK: - Runtime

/// The walkthrough as it is being played. Holds the cursor and nothing else —
/// what a step MEANS is `FirstRunDemoScript`'s, and what the underlying ride is
/// doing is the simulated service's.
@Observable
@MainActor
public final class FirstRunDemoRun {
    public let role: FirstRunDemoRole
    public let steps: [FirstRunDemoStep]
    public private(set) var index: Int = 0
    /// Set once, by whichever exit fired. The host observes it, marks the flag and
    /// leaves — one place, so completing and skipping cannot diverge.
    public private(set) var isFinished = false

    public init(role: FirstRunDemoRole) {
        self.role = role
        self.steps = FirstRunDemoScript.steps(for: role)
    }

    public var step: FirstRunDemoStep { steps[min(index, steps.count - 1)] }
    public var isLastStep: Bool { index >= steps.count - 1 }
    public var progress: String { "\(index + 1) of \(steps.count)" }

    /// Move on. The last step's advance finishes the walkthrough.
    public func advance() {
        guard !isFinished else { return }
        if isLastStep {
            isFinished = true
        } else {
            index += 1
        }
    }

    /// The persistent Skip. Ends the walkthrough wherever it stands — and marks
    /// the flag, because the host's finish handler does not ask which exit fired
    /// (see `FirstRunDemo.swift`, rule 2).
    public func skip() {
        isFinished = true
    }

    /// The tester tapped the real control this step is pointing at.
    public func handleTargetTapped() {
        guard case .tapTarget = step.advance else { return }
        advance()
    }

    /// The simulated ride reached a status. Advances only the step that was
    /// waiting for exactly this one, so a status arriving early or twice cannot
    /// skip a step — the MYR-414 restamp trap, pointed at a cursor.
    public func handleRideStatus(_ status: DemoRideStatus) {
        guard case .rideStatus(let awaited) = step.advance, awaited == status else { return }
        advance()
    }
}

// MARK: - The overlay

/// The caption card, the persistent Skip, and the progress dots.
public struct DemoCoachMarkOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let run: FirstRunDemoRun

    /// See the `.padding(.top:)` note below — this is the owner map's own
    /// below-the-switcher constant, not a second opinion about it.
    static let topChromeClearance = OwnerMapTopChrome.dispatchCardTop

    public init(run: FirstRunDemoRun) {
        self.run = run
    }

    private var placement: DemoCaptionPlacement {
        DemoCaptionPlacement.forAnchor(run.step.anchor)
    }

    public var body: some View {
        // The tester must be able to reach the real control underneath, so the
        // layer is an empty full-bleed frame that takes no touches, and only the
        // card itself is hit-testable.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .overlay(alignment: placement == .top ? .top : .bottom) { card }
            .animation(
                reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.32),
                value: run.index
            )
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(run.step.title)
                .mrtTextStyle(.sectionTitle)
                .foregroundStyle(Color.mrtText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(run.step.body)
                .mrtTextStyle(.bodySmall)
                .foregroundStyle(Color.mrtTextSec)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            footer
                .padding(.top, 14)
        }
        .padding(16)
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        // A TOP-placed caption has to clear the map's own top chrome — the
        // `MapHeader` vehicle switcher, whose chip bottom edge sits at 100 from
        // the physical edge (top 60 + a 40pt chip, MYR-332's own arithmetic). The
        // first owner capture put the card straight over it. The number is
        // DERIVED, not chosen: it is `OwnerMapTopChrome.dispatchCardTop`, the
        // constant this app already uses for "a card that floats below the chip",
        // so the walkthrough's card and the dispatch card share one answer and a
        // change to the chrome moves both. MYR-419's lesson, one surface over.
        .padding(.top, placement == .top ? Self.topChromeClearance : 18)
        .padding(.bottom, placement == .bottom ? 18 : 0)
        .accessibilityIdentifier(run.step.accessibilityID)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(FirstRunDemoScript.kicker(for: run.role).uppercased())
                .mrtTextStyle(.label(size: 11))
                .kerning(0.6)
                .foregroundStyle(Color.mrtGold)
            Spacer(minLength: 8)
            Text(run.progress)
                .mrtTextStyle(.label(size: 11))
                .monospacedDigit()
                .foregroundStyle(Color.mrtTextSec)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            // The MANDATORY persistent Skip. Present on EVERY step including the
            // last — a deliberate deviation from the prototype's `StoryDeck`,
            // which hides Skip on its final card (tutorials.jsx:296,
            // `{!last && <TopAction label="Skip"/>}`). On a deck the last card's
            // CTA is itself the way out, so hiding Skip costs nothing; here the
            // last step can be a control the tester has to find, and a
            // walkthrough with no exit is the thing the rule exists to prevent.
            Button(action: run.skip) {
                Text("Skip")
                    .mrtTextStyle(.label(size: 15))
                    .foregroundStyle(Color.mrtTextSec)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mrt.demo.skip")

            Spacer(minLength: 0)

            dots

            Spacer(minLength: 0)

            // `.tapTarget` and `.rideStatus` steps carry NO advance button: the
            // real control (or the ride itself) is the only way on, which is what
            // makes this a demo rather than a slideshow. The trailing slot keeps
            // its width so the dots do not jump between step kinds.
            if case .next = run.step.advance {
                Button(action: run.advance) {
                    Text(run.isLastStep
                         ? FirstRunDemoScript.finishLabel(for: run.role)
                         : run.step.nextLabel)
                        .mrtTextStyle(.label(size: 15))
                        .foregroundStyle(Color.mrtGold)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mrt.demo.next")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Array(run.steps.indices), id: \.self) { i in
                Capsule(style: .continuous)
                    // The deck's own dot pair (StoryDeck.swift:158), so the two
                    // first-run surfaces read as one grammar during the changeover.
                    .fill(i == run.index ? Color.mrtGold : Color.mrtText.opacity(0.2))
                    .frame(width: i == run.index ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
