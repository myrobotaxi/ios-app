import SwiftUI
import DesignSystem

/// Temporary debug screen proving out the DesignSystem package: color
/// swatches, the type scale, and both surface looks. Replaced by real screens
/// in MYR-162+; the drift gate can screenshot this in the meantime.
struct TokenShowcase: View {
    @AppStorage(SurfaceLook.storageKey) private var lookRaw = SurfaceLook.flat.rawValue
    @Environment(\.mrtSurfaceLook) private var look

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MRTMetrics.cardGap * 2) {
                Text("Design Tokens")
                    .mrtTextStyle(.screenTitle)
                    .foregroundStyle(Color.mrtText)

                lookPicker
                surfaceSection
                typeSection
                colorSection
            }
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.vertical, MRTMetrics.pageGutter)
        }
        .background(Color.mrtBg.ignoresSafeArea())
    }

    // MARK: Look toggle (persisted)

    private var lookPicker: some View {
        Picker("Look", selection: $lookRaw) {
            ForEach(SurfaceLook.allCases) { look in
                Text(look.displayName).tag(look.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: MRTMetrics.minTapTarget)
    }

    // MARK: Surfaces

    private var surfaceSection: some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            sectionHeader("Surfaces — \(look.displayName)")

            VStack(alignment: .leading, spacing: 4) {
                Text("Card").mrtTextStyle(.sectionTitle).foregroundStyle(Color.mrtText)
                Text("radius \(Int(look.cardRadius))pt · \(look.rendersGlass ? "native glass" : "solid + hairline")")
                    .mrtTextStyle(.bodySmall)
                    .foregroundStyle(Color.mrtTextSec)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MRTMetrics.pageGutter * 0.75)
            .mrtSurface(.card)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sheet").mrtTextStyle(.sectionTitle).foregroundStyle(Color.mrtText)
                Text("radius \(Int(look.sheetRadius))pt")
                    .mrtTextStyle(.bodySmall)
                    .foregroundStyle(Color.mrtTextSec)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MRTMetrics.pageGutter * 0.75)
            .mrtSurface(.sheet)

            Text("Control surface")
                .mrtTextStyle(.body)
                .foregroundStyle(Color.mrtGold)
                .frame(maxWidth: .infinity, minHeight: MRTMetrics.minTapTarget)
                .mrtSurface(.control)
        }
    }

    // MARK: Type scale

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            sectionHeader("Type Scale")

            VStack(alignment: .leading, spacing: 10) {
                Text("Screen Title 28/600").mrtTextStyle(.screenTitle)
                Text("88%").mrtTextStyle(.heroNumber(size: 40)).foregroundStyle(Color.mrtGold)
                Text("Section Title 18/600").mrtTextStyle(.sectionTitle)
                Text("Body 15/400 — the quick brown cybercab jumps the median.")
                    .mrtTextStyle(.body).foregroundStyle(Color.mrtTextSec)
                Text("Label 11/500 uppercase").mrtTextStyle(.label()).foregroundStyle(Color.mrtTextMuted)
                Text("Tab 10/500").mrtTextStyle(.tab).foregroundStyle(Color.mrtTextMuted)
            }
            .foregroundStyle(Color.mrtText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MRTMetrics.pageGutter * 0.75)
            .mrtSurface(.card)
        }
    }

    // MARK: Colors

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            sectionHeader("Colors")
            swatchGrid
        }
    }

    private var swatches: [(String, Color)] {
        [
            ("bg", .mrtBg), ("bgSecondary", .mrtBgSecondary), ("surface", .mrtSurface),
            ("surfaceHov", .mrtSurfaceHov), ("elevated", .mrtElevated),
            ("text", .mrtText), ("textSec", .mrtTextSec), ("textMuted", .mrtTextMuted),
            ("gold", .mrtGold), ("goldLight", .mrtGoldLight), ("goldDark", .mrtGoldDark),
            ("goldDeep", .mrtGoldDeep), ("goldDeepSoft", .mrtGoldDeepSoft),
            ("goldGlow", .mrtGoldGlow), ("goldGlowSoft", .mrtGoldGlowSoft),
            ("driving", .mrtDriving), ("parked", .mrtParked), ("charging", .mrtCharging),
            ("offline", .mrtOffline), ("batLow", .mrtBatLow), ("dialogRed", .mrtDialogRed),
            ("border", .mrtBorder), ("borderSubtle", .mrtBorderSubtle),
        ]
    }

    private var swatchGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: MRTMetrics.cardGap)], spacing: MRTMetrics.cardGap) {
            ForEach(swatches, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                        .fill(color)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                        )
                    Text(name)
                        .mrtTextStyle(.label(size: 10))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .mrtTextStyle(.label())
            .foregroundStyle(Color.mrtGold)
    }
}

#Preview {
    TokenShowcase()
        .preferredColorScheme(.dark)
}
