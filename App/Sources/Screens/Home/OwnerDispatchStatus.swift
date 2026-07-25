import SwiftUI
import DesignSystem

// MARK: - Owner ride-aware dispatch status (MYR-265)
//
// The owner's Live Map used to show only `Vehicle.activity`/telemetry once a ride
// was dispatched — a generic "Driving to …" with ZERO ride/leg/rider awareness.
// MYR-265 makes the owner track the ride they accepted and its LIVE leg: the
// shared `RideRequestService.activeRequest.status` is folded from every
// `ride_status_changed` WS unicast the owner receives (see
// `LiveRideRequestService.integrate`), so as the rider boards (`accepted →
// enroute`) and the drive ends (`→ completed`) this status line updates in place.
//
// `OwnerRideStatusLine` is a PURE resolver (no SwiftUI) so the three status lines
// are unit-testable, and `OwnerDispatchBanner` renders them tokens-only. Both take
// REAL data only (MYR-228): the rider name resolves through the SAME gated
// `IncomingRequestDisplay` the incoming sheet/accept toast use (real wire name on
// live, fixture "Sam" in sim), and every field falls back to a NEUTRAL phrasing
// when absent — never a fabricated persona.

enum OwnerRideStatusLine {
    /// The single status line for the owner's active dispatched ride, or `nil` for
    /// a non-active status (`pending` shows the incoming sheet; `declined` shows
    /// nothing). Neutral fallbacks when the rider name / drop-off label is absent.
    ///  • `accepted` (leg 1) → "En route to pickup · picking up <Name>"
    ///  • `enroute`  (leg 2) → "<Name> aboard · heading to <dropoff>"
    ///  • `completed`        → "Dropped off ✓"
    static func text(status: RideRequestStatus, riderName: String?, dropoffLabel: String?) -> String? {
        let name = cleaned(riderName)
        switch status {
        case .accepted:
            return name.map { "En route to pickup \u{00B7} picking up \($0)" } ?? "En route to pickup"
        case .enroute:
            let drop = cleaned(dropoffLabel)
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

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The compact top-of-map status pill for an active dispatched ride. Same capsule
/// recipe as the `MapHeader` vehicle chip (fill + hairline + shadow, tokens-only),
/// pinned just below the switcher. Shown ONLY while a ride is dispatched, so the
/// plain owner Home (`ownerHome` drift-gate scene, no active ride) is unaffected.
struct OwnerDispatchBanner: View {
    let line: String
    let isComplete: Bool

    var body: some View {
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
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
    }
}
