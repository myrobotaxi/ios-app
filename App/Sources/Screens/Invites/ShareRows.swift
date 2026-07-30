import SwiftUI
import DesignSystem

// MARK: - Shared viewer/pending rows (MYR-170)
//
// `ViewerRow` shipped as the shared row of `InvitesScreen` (screens.jsx:1264-1274)
// and `SettingsScreen` (screens.jsx:1601-1611) — factored once (CLAUDE.md
// "Reuse, don't fork") rather than duplicated per screen.
//
// MYR-347 moved the SHARE TAB to `ShareRosterViews` (client-directed redesign
// into iOS grouped-list grammar), so this file is now `SettingsScreen`'s alone
// and is deliberately left untouched by that redesign — Settings is being
// restyled separately (MYR-354) and must not inherit a half-migrated row.
// `PendingRow` went with the move: it had exactly one consumer, the Share tab's
// Pending list, which no longer exists in that shape.

/// One row of the Viewers / "Shared with" list — avatar, name, permission
/// label, and a pill "Revoke" button.
struct ViewerRow: View {
    let viewer: Viewer
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: viewer.name, online: viewer.online)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewer.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                Text(viewer.perm)
                    .font(.system(size: 11))
                    .tracking(0.2)
                    .foregroundStyle(Color.mrtTextMuted)
            }
            Spacer(minLength: 0)
            RevokePillButton(action: onRevoke)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.vertical, 12)
    }
}

/// The transparent, hairline-bordered "Revoke" pill (screens.jsx:1273,1610).
struct RevokePillButton: View {
    var title: String = "Revoke"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minHeight: MRTMetrics.minTapTarget - 14)
                .overlay(Capsule().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
