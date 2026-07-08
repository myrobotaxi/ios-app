import SwiftUI
import DesignSystem

// MARK: - Tab placeholder (MYR-167 deliverable 6; generalized in MYR-170 for
// the rider tab shell)
//
// Owner Share/Settings shipped in MYR-170 (`InvitesScreen`/`SettingsScreen`);
// Drives shipped in MYR-169 (`DrivesScreen`). The rider shell's Live Map /
// Ride History tabs shipped in MYR-191 (`SharedViewerScreen`/
// `RideHistoryScreen`) — no `RootView` call site uses this placeholder
// anymore, but it's kept as the generic fallback for any future tab screen
// that isn't built yet, and its `tab`/`tabs` API (rather than assuming the
// owner shell) is what MYR-191's screens followed.
struct PlaceholderScreen: View {
    let icon: String
    let title: String
    @Binding var tab: String
    var tabs: [MRTTab] = MRTTab.ownerTabs

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(Color.mrtTextMuted)
                    .frame(width: 64, height: 64)
                    .background(Color.mrtText.opacity(0.04), in: Circle())
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                Text("Coming soon")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextSec)
            }
        }
        // Full-bleed geometry (CLAUDE.md "Hard rules"): pin `BottomNav` 26pt
        // from the PHYSICAL bottom edge via the shared `mrtBottomNav` helper
        // — see `HomeScreen.swift`'s header comment (review finding #1 +
        // MYR-196 punch-list #3).
        .mrtBottomNav(selection: $tab, tabs: tabs)
    }
}
