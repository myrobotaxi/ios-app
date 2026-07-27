import SwiftUI
import DesignSystem

// MARK: - Command-notice surfaces (MYR-301)
//
// The client's TestFlight report was "Charge port not opening." The app HAD an
// honest answer — `permission_denied` → "Reconnect Tesla for charging access" —
// but it rendered inside the ~80pt quick tile, where a 35-character sentence has
// ~54pt of room at the one uniform 11pt sub size MYR-281 established. The owner
// saw "Reconnec…", and even the full sentence would have been a dead end: there
// was no way to act on it.
//
// The fix keeps MYR-281's uniform sub intact and splits the notice in two:
//
//   • the TILE sub shows `notice.tileText` — a short token that FITS on one line
//     at 11pt (measured in `VehicleCommandNoticeTests`), so nothing ellipsizes
//     and non-notice subs are untouched;
//   • `VehicleCommandNoticeRow` — a full-width row directly under the tiles —
//     carries the FULL `notice.message` plus the fix.
//
// The row deliberately reuses the ONE grammar the prototype already has for
// "something is off, here is the one-tap fix": the Climate-off row
// (design/app/vehicle-controls.jsx:309-325, ported in `ClimateSection.offContent`)
// — 44pt icon disc + title + sub + trailing gold pill. The prototype has no
// error/notice/banner component anywhere in vehicle-controls.jsx (verified
// against the design mirror), and `DeclinedNotice`'s alarm-red card
// (ride-request.jsx:1038) is an overlay for a dead-ended flow, not an inline
// state inside a controls stack — so this is the closest in-file precedent, and
// it keeps the surface quiet, which is the prototype's stated stance on
// degraded state ("dim and label", never alarm).

/// The full-width notice row shown beneath the quick tiles for a control whose
/// last command failed. One row per affected tile (in tile order); in practice
/// there is at most one.
struct VehicleCommandNoticeRow: View {
    let key: VehicleControlKey
    let notice: VehicleCommandNotice
    /// The Tesla re-link route (nil when the host didn't provide one). Present
    /// only for notices that carry an `action`.
    var onAction: (() -> Void)?

    private var showsAction: Bool { notice.action != nil && onAction != nil }

    var body: some View {
        HStack(spacing: 14) {
            if let icon = key.tileIcon {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mrtTextMuted)
                    .frame(width: 44, height: 44)
                    .background(Color.mrtControlSegmentTrack, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(key.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                // The FULL notice, with room to wrap — this is the sentence the
                // tile could never hold.
                Text(notice.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsAction, let action = notice.action {
                Button {
                    onAction?()
                } label: {
                    Text(action.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.mrtGoldButtonLabel)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        // 44pt tap target (CLAUDE.md) — the pill's own 8pt
                        // vertical padding leaves it ~33pt tall, so the frame
                        // enforces the minimum without changing the pill's paint.
                        .padding(.vertical, 8)
                        .background(Color.mrtGold, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .mrtSurface(.card, fill: .mrtElevated, radius: MRTMetrics.vehicleControlsSectionRadius)
        .padding(.top, 10)
    }
}

/// The compact in-place notice line used by controls that already have a
/// full-width row of their own (seat rows, media transport). It renders the FULL
/// message — those surfaces have the width the tiles lack — and becomes a
/// 44pt tap target routing to the fix when the notice carries one.
struct VehicleCommandNoticeLine: View {
    let notice: VehicleCommandNotice
    var alignment: HorizontalAlignment = .leading
    var onAction: (() -> Void)?

    private var frameAlignment: Alignment { alignment == .center ? .center : .leading }

    var body: some View {
        if let action = notice.action, let onAction {
            Button(action: onAction) {
                HStack(spacing: 6) {
                    Text(notice.message)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.mrtTextSec)
                    Text(action.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.mrtGold)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.mrtGold)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: frameAlignment)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // Unchanged from MYR-249: a quiet, compact line. Never rendered on
            // the simulated path (`uiState` is always `.idle` there), so the M1 /
            // drift-gate scenes stay pixel-identical.
            Text(notice.message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }
}
