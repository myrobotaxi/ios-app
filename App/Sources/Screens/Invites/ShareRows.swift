import SwiftUI
import DesignSystem

// MARK: - Shared viewer/pending rows (MYR-170)
//
// `ViewerRow` is byte-identical between `InvitesScreen` (screens.jsx:1264-1274)
// and `SettingsScreen` (screens.jsx:1601-1611) — factored once (CLAUDE.md
// "Reuse, don't fork") rather than duplicated per screen. `PendingRow` is
// InvitesScreen-only.

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

/// One row of the Pending list — avatar, name, "email · sent" caption, plus
/// gold "Resend" and muted "Cancel" text actions (screens.jsx:1276-1286).
struct PendingRow: View {
    let invite: PendingInvite
    let onResend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: invite.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                // `Text(verbatim:)` — a `Text("...\(invite.email)...")`
                // string-interpolation literal gets Markdown-parsed and
                // auto-links the email-shaped run in the accent color,
                // ignoring `.foregroundStyle` (see InvitesScreen's
                // `emailRow` comment).
                Text(verbatim: "\(invite.email) \u{00B7} \(invite.sent)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            Spacer(minLength: 0)
            textButton("Resend", color: .mrtGold, action: onResend)
            textButton("Cancel", color: .mrtTextMuted, action: onCancel)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.vertical, 12)
    }

    private func textButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .padding(6)
                .frame(minWidth: MRTMetrics.minTapTarget - 14, minHeight: MRTMetrics.minTapTarget - 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
