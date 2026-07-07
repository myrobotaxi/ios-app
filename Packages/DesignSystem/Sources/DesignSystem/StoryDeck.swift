import SwiftUI

// MARK: - StoryDeck (tutorials.jsx:290-352) — paged story-card engine
//
// A reusable "Things/Linear style" paged tutorial engine: a floating hero
// vignette (built from real DesignSystem primitives by the caller) + big
// title + body + page dots + an outline-static CTA. One deck powers both
// `OwnerTutorial` and `RiderTutorial` (MYR-166, App/Sources/Screens/Tutorials).
//
// iOS mapping (Handoff §5.4 / ds/ds-data.jsx MOTION_TOKENS "Story slide"):
// `TabView(.page)` for the native directional swipe/slide (mrtStoryInL/R).
// Reduce Motion → a custom crossfade pager (no directional slide), and the
// vignette's `mrtVigFloat` bob is skipped entirely (CLAUDE.md "Honor Reduce
// Motion").

/// One page of a `StoryDeck` — a hero vignette + title + body
/// (tutorials.jsx `OwnerTutorial`/`RiderTutorial` `cards` arrays).
public struct StoryCard {
    public let title: String
    public let body: String
    public let visual: AnyView

    public init(title: String, body: String, @ViewBuilder visual: () -> some View) {
        self.title = title
        self.body = body
        self.visual = AnyView(visual())
    }
}

public struct StoryDeck: View {
    private let cards: [StoryCard]
    private let kicker: String
    private let cta: String
    private let onDone: () -> Void

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - cards: the deck's pages, in order.
    ///   - kicker: the small uppercase gold label next to the brand mark
    ///     (tutorials.jsx `kicker` prop — "Getting started" / "Welcome aboard").
    ///   - cta: the last card's button label (tutorials.jsx `cta` prop,
    ///     default `"Get Started"` — OwnerTutorial uses "Go to my car",
    ///     RiderTutorial "Start riding"). Every other card reads "Continue".
    ///   - onDone: fired by Skip, or by the CTA on the last card.
    public init(cards: [StoryCard], kicker: String, cta: String = "Get Started", onDone: @escaping () -> Void) {
        self.cards = cards
        self.kicker = kicker
        self.cta = cta
        self.onDone = onDone
    }

    private var isLast: Bool { index == cards.count - 1 }

    public var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            MRTGoldWash()

            VStack(spacing: 0) {
                pager
                    .frame(maxHeight: .infinity)

                dots
                    .padding(.top, 6)
                    .padding(.bottom, 20)

                MRTButton(isLast ? cta : "Continue", variant: .outlineStatic) {
                    advance()
                }
            }
            .padding(.top, MRTMetrics.storyContentTop)
            .padding(.bottom, MRTMetrics.storyContentBottom)
            .padding(.horizontal, MRTMetrics.onboardingGutter)

            // Kicker — brand mark + uppercase gold label (tutorials.jsx:320).
            HStack(spacing: 10) {
                HexLogo(size: 24)
                Text(kicker)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.mrtGold)
            }
            .padding(.top, MRTMetrics.storyKickerTop)
            .padding(.leading, MRTMetrics.storyKickerGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Skip — hidden on the last card (tutorials.jsx:317 `{!last && …}`).
            if !isLast {
                MRTTopAction(label: "Skip", action: onDone)
            }
        }
        // The gold wash must reach the very top edge, behind the status bar
        // (matches AddTeslaFlow/InviteCodeFlow/EmptyScreen — Handoff's
        // radial-gradient(140% 100% at 50% -20%, …) is anchored above the
        // visible frame, so a safe-area-constrained wash clips its brightest
        // point and leaves a flat black band under the status bar).
        .ignoresSafeArea(.container)
    }

    // MARK: Pager

    @ViewBuilder private var pager: some View {
        if reduceMotion {
            // Static vignette, crossfade transition — no directional slide.
            ZStack {
                pageContent(cards[index])
                    .id(index)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: index)
            .contentShape(Rectangle())
            .gesture(swipeGesture)
        } else {
            TabView(selection: $index) {
                ForEach(cards.indices, id: \.self) { i in
                    pageContent(cards[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func pageContent(_ card: StoryCard) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card.visual
                .modifier(VignetteFloat())
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Text(card.title)
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.6)
                    .lineSpacing(3)
                    .foregroundStyle(Color.mrtText)
                Text(card.body)
                    .font(.system(size: 15))
                    .lineSpacing(8)
                    .foregroundStyle(Color.mrtTextSec)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    // MARK: Dots (tutorials.jsx:342-347)

    private var dots: some View {
        HStack(spacing: MRTMetrics.storyDotGap) {
            ForEach(cards.indices, id: \.self) { i in
                Button {
                    goTo(i)
                } label: {
                    Capsule()
                        .fill(i == index ? Color.mrtGold : Color.mrtText.opacity(0.2))
                        .frame(
                            width: i == index ? MRTMetrics.storyDotActiveWidth : MRTMetrics.storyDotSize,
                            height: MRTMetrics.storyDotSize
                        )
                }
                .buttonStyle(.plain)
                .frame(minWidth: MRTMetrics.minTapTarget, minHeight: MRTMetrics.minTapTarget)
                .contentShape(Rectangle())
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
    }

    // MARK: Swipe (Reduce Motion pager only — TabView handles its own swipe)

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                if value.translation.width < -46 {
                    goTo(index + 1)
                } else if value.translation.width > 46 {
                    goTo(index - 1)
                }
            }
    }

    // MARK: Navigation (tutorials.jsx `go`/`next`)

    private func goTo(_ n: Int) {
        guard n >= 0, n < cards.count else { return }
        if reduceMotion {
            index = n
        } else {
            withAnimation(.easeOut(duration: 0.3)) { index = n }
        }
    }

    private func advance() {
        if isLast { onDone() } else { goTo(index + 1) }
    }
}

/// `mrtVigFloat` (tutorials.jsx:310): translateY 0 → -9 → 0, 4s ease-in-out
/// infinite — a 2s-each-way autoreverse. Reduce Motion → static (decorative
/// loop, CLAUDE.md "Honor Reduce Motion").
private struct VignetteFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floated = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .offset(y: floated ? -9 : 0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                        floated = true
                    }
                }
        }
    }
}
