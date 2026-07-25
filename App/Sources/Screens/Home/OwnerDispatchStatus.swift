import SwiftUI
import DesignSystem

// MARK: - Owner ride-aware dispatch status + actions (MYR-270 — owner-driven
// dispatch v2)
//
// The owner's Live Map tracks the ride they accepted and its LIVE state: the
// shared `RideRequestService.activeRequest.status` is folded from every
// `ride_status_changed` WS unicast the owner receives (see
// `LiveRideRequestService.integrate`), so as the owner confirms pickup
// (`accepted → arrived`), the rider starts (`arrived → enroute`) and the owner
// drops off (`→ completed`), this surface updates in place. The owner drives two
// of those transitions directly from here: "Picked up" during `accepted`, and
// "Dropped off" during `enroute`.
//
// `OwnerRideStatusLine` is a PURE resolver (no SwiftUI) so the status lines are
// unit-testable, and `OwnerDispatchCard` renders them tokens-only. Both take REAL
// data only (MYR-228): the rider name resolves through the SAME gated
// `IncomingRequestDisplay` the incoming sheet/accept toast use (real wire name on
// live, fixture "Sam" in sim), and every field falls back to a NEUTRAL phrasing
// when absent — never a fabricated persona.

enum OwnerRideStatusLine {
    /// The single status line for the owner's active dispatched ride, or `nil` for
    /// a non-active status (`pending` shows the incoming sheet; `declined` shows
    /// nothing). Neutral fallbacks when the rider name / drop-off label is absent.
    ///  • `accepted` (leg 1) → "En route to pickup · <Name>"
    ///  • `arrived`          → "Picked up · waiting for <Name> to start"
    ///  • `enroute`  (leg 2) → "<Name> aboard · heading to <dropoff>"
    ///  • `enroute` + ETA≤2  → "Arriving at <dropoff>"
    ///  • `completed`        → "Dropped off ✓"
    static func text(status: RideRequestStatus, riderName: String?, dropoffLabel: String?, arriving: Bool = false) -> String? {
        let name = cleaned(riderName)
        let drop = cleaned(dropoffLabel)
        switch status {
        case .accepted:
            return name.map { "En route to pickup \u{00B7} \($0)" } ?? "En route to pickup"
        case .arrived:
            return name.map { "Picked up \u{00B7} waiting for \($0) to start" } ?? "Picked up \u{00B7} waiting to start"
        case .enroute:
            if arriving {
                return drop.map { "Arriving at \($0)" } ?? "Arriving"
            }
            switch (name, drop) {
            case let (name?, drop?): return "\(name) aboard \u{00B7} heading to \(drop)"
            case let (name?, nil): return "\(name) aboard"
            case let (nil, drop?): return "Heading to \(drop)"
            case (nil, nil): return "Rider aboard"
            }
        case .completed:
            return "Dropped off \u{2713}"
        case .pending, .declined:
            return nil
        }
    }

    /// The owner's action CTA title for the current dispatched state, or `nil` when
    /// there is nothing for the owner to do (`arrived` — awaiting the rider's Start;
    /// and `completed`). Pure so the accepted→"Picked up" / enroute→"Dropped off"
    /// gating is unit-testable.
    static func actionTitle(for status: RideRequestStatus) -> String? {
        switch status {
        case .accepted: return "Picked up"
        case .enroute: return "Dropped off"
        case .arrived, .completed, .pending, .declined: return nil
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The owner's action for the current dispatched state — a title + handler the
/// card renders as a gold CTA. `nil` when there is nothing to do.
struct OwnerDispatchAction {
    let title: String
    let handler: () -> Void
}

/// The top-of-map dispatch card for an active dispatched ride: a status pill (same
/// capsule recipe as the `MapHeader` vehicle chip — fill + hairline + shadow,
/// tokens-only) plus, when the owner can act, a gold CTA button beneath it
/// ("Picked up" during accepted, "Dropped off" during enroute). Shown ONLY while a
/// ride is dispatched, so the plain owner Home (`ownerHome` drift-gate scene, no
/// active ride) is unaffected.
struct OwnerDispatchCard: View {
    let line: String
    let isComplete: Bool
    /// The owner's CTA for this state, or `nil` (arrived / completed → status only).
    var action: OwnerDispatchAction?
    /// Disables the CTA for the frame it is tapped (double-tap guard) — cleared by
    /// the caller on the next status change (MYR-265 review: reset the in-flight
    /// latch on status change so a re-shown button is tappable again).
    var actionDisabled: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            statusPill
            if let action {
                MRTButton(action.title, variant: .gold, size: .sm, fullWidth: true, action: action.handler)
                    .disabled(actionDisabled)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 24)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isComplete ? Color.mrtTextSec : Color.mrtGold)
                .frame(width: 7, height: 7)
                .shadow(color: isComplete ? .clear : .mrtGoldGlow, radius: 4)
            Text(line)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color.mrtText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: MRTMetrics.minTapTarget)
        .background(Color.mrtMapChipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
    }
}
