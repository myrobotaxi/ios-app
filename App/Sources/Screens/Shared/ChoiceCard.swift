import SwiftUI
import DesignSystem

// MARK: - ChoiceCard (MYR-165 onboarding path card; shared by MYR-224)
//
// One self-describing path card (design/app/screens.jsx:268-292): icon tile 46
// + title/subtitle + chevron, radius 20; the primary card is gold-emphasized.
// Extracted from `EmptyScreen` (its original home) so the MYR-224 owner/rider
// mode chooser reuses the EXACT same card anatomy rather than forking it — the
// chooser is an approved new screen, but every piece it draws is this existing,
// pure-token component.
struct ChoiceCard: View {
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
