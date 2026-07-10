import SwiftUI
import DesignSystem

// MARK: - ModeChooserScreen (MYR-224 — owner/rider view chooser)
//
// A light, client-approved chooser shown once on the live signed-in path when
// no view mode is stored yet (after a fresh Sign in with Apple, or a first
// silent resume for a session that predates this choice). It is a VIEW choice,
// not a capability gate: "View my vehicles" opens the owner shell (which shows
// its own empty state if the account owns nothing) and "Request rides" opens
// the rider shell — either is valid for any account.
//
// APPROVED DEVIATION, DESIGN-SYSTEM PIECES ONLY: this screen has no prototype
// counterpart, but every element is reused verbatim from the existing
// first-run onboarding chooser (`EmptyScreen`, design/app/screens.jsx:253-296,
// Handoff §5.1): the same `OnboardingGoldWash` band, `HexLogo`, heading type
// scale, and — crucially — the same `ChoiceCard` (icon tile 46 / radius 20 /
// gold-emphasized primary), now shared from `Screens/Shared/ChoiceCard.swift`.
// No new tokens, colors, or primitives are introduced.
struct ModeChooserScreen: View {
    let profile: UserProfile
    let onChoose: (ViewMode) -> Void

    /// "Welcome, {First}" when a name is known, else a calm generic — never
    /// "Welcome, " + empty (same rule as the rider greeting).
    private var heading: String {
        if let first = profile.firstName { return "Welcome, \(first)" }
        return "Welcome"
    }

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            OnboardingGoldWash(height: 380) // mirrors EmptyScreen (screens.jsx:261)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HexLogo(size: 58, glow: true)
                    .padding(.bottom, 30)
                Text(heading)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 9)
                Text("How do you want to use MyRoboTaxi today?")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .lineSpacing(14 * 0.5) // line-height 1.5
                    .frame(maxWidth: 268)
                    .padding(.bottom, 34)

                VStack(spacing: 13) {
                    ChoiceCard(
                        primary: true,
                        icon: "car.fill",
                        title: "View my vehicles",
                        subtitle: "Track, control, and share the Teslas on your account.",
                        action: { onChoose(.owner) }
                    )
                    ChoiceCard(
                        primary: false,
                        icon: "person.fill",
                        title: "Request rides",
                        subtitle: "Book and follow rides in a Tesla you can access.",
                        action: { onChoose(.rider) }
                    )
                }
            }
            .padding(.horizontal, 28) // jsx padding: '0 28px'
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ModeChooserScreen(profile: UserProfile(id: "u1", name: "Thomas Nandola", email: "thomas@myrobotaxi.app")) { _ in }
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
