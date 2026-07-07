import SwiftUI

// MARK: - Shared gold wash + top ghost action
//
// Promoted from the onboarding-only `OnboardingGoldWash`/`OnboardingTopAction`
// (MYR-165) so StoryDeck (MYR-166) can reuse the identical brand wash and
// Skip/Cancel affordance instead of forking a second copy (CLAUDE.md "reuse,
// don't fork"). `App/Sources/Screens/Onboarding/OnboardingChrome.swift` now
// typealiases its onboarding-named symbols to these.

/// Brand gold wash shared by every onboarding + tutorial surface
/// (onboarding.jsx:10-13; EmptyScreen uses the 380pt variant, screens.jsx:261;
/// StoryDeck uses the 360pt default, tutorials.jsx:314 `<GoldWash/>`):
/// radial-gradient(140% 100% at 50% -20%, goldGlow3 0%, transparent 65%).
public struct MRTGoldWash: View {
    public var height: CGFloat

    public init(height: CGFloat = 360) {
        self.height = height
    }

    public var body: some View {
        RadialGradient(
            stops: [
                .init(color: .mrtGoldGlowSoft, location: 0),
                .init(color: Color.mrtGoldGlowSoft.opacity(0), location: 0.65),
            ],
            center: UnitPoint(x: 0.5, y: -0.2),
            startRadius: 0,
            endRadius: height
        )
        // rx = 140% of width vs ry = height ⇒ stretch x around the gradient
        // center to make the CSS ellipse (same approach as SignInScreen).
        .scaleEffect(x: 1.48, y: 1, anchor: UnitPoint(x: 0.5, y: -0.2))
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// Small ghost "Skip / Cancel" affordance, top-right (onboarding.jsx:16-24;
/// top 82, right 20, 15/500 textSec; tutorials.jsx:317 `<TopAction label="Skip"
/// onClick={onDone}/>`). Padded out to the 44pt hit target.
public struct MRTTopAction: View {
    public let label: String
    public let action: () -> Void

    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .padding(6)
                .frame(minWidth: MRTMetrics.minTapTarget, minHeight: MRTMetrics.minTapTarget)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, MRTMetrics.onboardingTopActionTop - 6)
        .padding(.trailing, 20 - 6)
    }
}
