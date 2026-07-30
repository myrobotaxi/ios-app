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

// MARK: - SharedVehiclesUnreachableScreen (MYR-343)
//
// The rider's vehicle list did not answer, and nothing about this account is
// known yet. Deliberately NOT `SharedNoVehiclesScreen`: "no vehicles shared with
// you yet" is a CLAIM about the account, and one failed fetch does not support
// it — the same reasoning `LiveSharedVehicleCatalog.load` already applies when it
// leaves the last-known grants standing rather than emptying the list.
//
// And deliberately not a skeleton either (MYR-326: loading ≠ unavailable). There
// is nothing in flight behind this screen; a shimmering placeholder would promise
// content that is not coming.
//
// NO RETRY BUTTON, by the same MYR-326 ruling that governs the owner's cold-read
// timeout: recovery is the low-friction one the app already has — a resume
// re-asks (`RootView`'s scenePhase handler), and a successful list clears this by
// itself. The copy mirrors `ColdSnapshotLoad.unreachableMessage`'s grammar
// ("Can't reach … right now"), pluralized because at this point the app does not
// know which — or how many — vehicles it was reaching for.
struct SharedVehiclesUnreachableScreen: View {
    @Binding var sharedTab: String

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack {
                    Circle().fill(Color.mrtElevated)
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                .frame(width: 64, height: 64)
                .padding(.bottom, 22)

                Text("Can\u{2019}t reach your vehicles right now")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 268)
                    .padding(.bottom, 8)

                Text("We\u{2019}ll try again when you come back.")
                    .font(.system(size: 14))
                    .lineSpacing(14 * 0.45)
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 268)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MRTMetrics.pageGutter)
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

#Preview("Unreachable") {
    SharedVehiclesUnreachableScreen(sharedTab: .constant("shared"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
