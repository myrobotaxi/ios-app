import SwiftUI
import DesignSystem

// MARK: - Owner tab placeholder (MYR-167 deliverable 6)
//
// Share/Settings each get their own build issue next (Drives shipped in
// MYR-169 — see `DrivesScreen`); screens.jsx gives every owner screen
// (`DrivesScreen`, `InvitesScreen`, `SettingsScreen`) its own
// `<BottomNav current={nav} onChange={setNav}/>` render (app.jsx:110-115)
// rather than a shared wrapper — this mirrors that so `HomeScreen` isn't a
// special case.
struct PlaceholderScreen: View {
    let icon: String
    let title: String
    @Binding var ownerTab: String

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
        .mrtBottomNav(selection: $ownerTab)
    }
}
