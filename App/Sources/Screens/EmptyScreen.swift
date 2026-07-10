import SwiftUI
import DesignSystem

// MARK: - Empty state (MYR-165 — Handoff §5.1, design/app/screens.jsx:253-296)
//
// First run, straight after sign-in. Gold wash + brand mark + "Welcome to
// MyRoboTaxi", then two self-describing choice cards:
//   · Add your Tesla — emphasized (gold-tinted fill, solid gold border,
//     gold car icon) → AddTeslaFlow
//   · Join with an invite code — quiet matching card, person icon
//     → InviteCodeFlow
struct EmptyScreen: View {
    let onAdd: () -> Void
    let onInvite: () -> Void

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            OnboardingGoldWash(height: 380) // screens.jsx:261
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HexLogo(size: 58, glow: true)
                    .padding(.bottom, 30)
                Text("Welcome to MyRoboTaxi")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 9)
                Text("How would you like to get started?")
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
                        title: "Add your Tesla",
                        subtitle: "Link your vehicle to drive, track, and share it.",
                        action: onAdd
                    )
                    ChoiceCard(
                        primary: false,
                        icon: "person.fill",
                        title: "Join with an invite code",
                        subtitle: "Ride in a Tesla someone has shared with you.",
                        action: onInvite
                    )
                }
            }
            .padding(.horizontal, 28) // jsx padding: '0 28px'
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// The `ChoiceCard` used above lives in `Screens/Shared/ChoiceCard.swift` — it is
// shared with the MYR-224 mode chooser rather than forked.

#Preview {
    EmptyScreen(onAdd: {}, onInvite: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
