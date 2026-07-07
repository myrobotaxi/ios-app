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

// MARK: Choice card

/// One self-describing path card (screens.jsx:268-292): icon tile 46 +
/// title/sub + chevron, radius 20; the primary card is gold-emphasized.
private struct ChoiceCard: View {
    let primary: Bool
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                iconTile
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .lineSpacing(12.5 * 0.4) // line-height 1.4
                        .foregroundStyle(Color.mrtTextSec)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primary ? Color.mrtGold : .mrtTextMuted)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 17)
            .padding(.horizontal, 18)
            .background(cardFill, in: shape)
            .overlay(
                shape.strokeBorder(
                    primary ? Color.mrtGoldCellBorder : .mrtGoldBorderQuiet,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    /// primary: linear-gradient(150deg, gold1c, gold0a); quiet: white 0.035.
    private var cardFill: AnyShapeStyle {
        if primary {
            AnyShapeStyle(LinearGradient(
                colors: [.mrtGoldCardTint, .mrtGoldCardTintFaint],
                startPoint: Self.gradientStart150,
                endPoint: Self.gradientEnd150
            ))
        } else {
            AnyShapeStyle(Color.mrtText.opacity(0.035))
        }
    }

    // CSS linear-gradient(150deg): dx = sin(150°)/2, dy = -cos(150°)/2.
    static let gradientStart150 = UnitPoint(x: 0.5 - 0.25, y: 0.5 - 0.4330)
    static let gradientEnd150 = UnitPoint(x: 0.5 + 0.25, y: 0.5 + 0.4330)

    /// Icon tile 46, radius 14 (screens.jsx:275-278).
    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(primary ? Color.mrtGoldIconTile : Color.mrtText.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        primary ? Color.mrtGoldBorderSoft : .mrtBorder,
                        lineWidth: MRTMetrics.hairline
                    )
            )
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium)) // SFIcon 22
                    .foregroundStyle(primary ? Color.mrtGold : .mrtTextSec)
            )
            .frame(width: 46, height: 46)
    }
}

#Preview {
    EmptyScreen(onAdd: {}, onInvite: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
