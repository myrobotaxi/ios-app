import SwiftUI
import DesignSystem

// MARK: - SharedNoVehiclesScreen (MYR-184)
//
// The rider Live Map with ZERO shared vehicles — a state that simply did not
// exist before this issue, because `SharedViewerState.vehicle` defaulted to
// `VehicleFixtures.vehicles[0]` with no live gate at all (MYR-228 fix (c)). A
// signed-in rider who had redeemed nothing watched a map for "Cybercab": a car
// on nobody's account, with a fixture route, ticking fixture telemetry.
//
// The honest render is this: no map, because there is nothing to map. The copy
// MIRRORS `SharedSettingsScreen`'s empty row verbatim ("Enter an invite code to
// ride someone's Tesla.") so the two places a rider can discover this say the
// same sentence, and the CTA routes to the same `InviteCodeFlow` that row's
// "Enter invite code" does.
//
// Renders its own `BottomNav` with `MRTTab.sharedTabs`, like every other rider
// screen — the rider keeps their tabs; only the map's content is missing.
struct SharedNoVehiclesScreen: View {
    @Binding var sharedTab: String
    let onEnterCode: () -> Void

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack {
                    Circle().fill(Color.mrtElevated)
                    Image(systemName: "car.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                .frame(width: 64, height: 64)
                .padding(.bottom, 22)

                Text("No vehicles shared with you yet")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 8)

                // Byte-identical to `SharedSettingsScreen.emptySharedRow`'s
                // second line — one sentence, said the same way in both places.
                Text("Enter an invite code to ride someone\u{2019}s Tesla.")
                    .font(.system(size: 14))
                    .lineSpacing(14 * 0.45)
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 268)
                    .padding(.bottom, 28)

                MRTButton("Enter invite code", fullWidth: false, action: onEnterCode)
                    .frame(width: 220)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MRTMetrics.pageGutter)
            // Clear the floating nav so the CTA never sits under it.
            .padding(.bottom, MRTMetrics.shareContentBottomPadding)
        }
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
    }
}

#Preview {
    SharedNoVehiclesScreen(sharedTab: .constant("shared"), onEnterCode: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
