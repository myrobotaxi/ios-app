import SwiftUI
import DesignSystem

// MARK: - MYR-352 — "No rides available right now"
//
// THE CLIENT'S ASK (TestFlight, Jul 30, ANjB2tBe… in feedback_shots9): *"If no
// owner vehicles available with ride share enabled we need to display a banner
// saying no rides available right now. Kind of like the Tesla Robotaxi app. We
// can do it as a sleek banner above the search bar."*
//
// The gap it closes: MYR-341 already SUPPRESSES the idle placeholder's "A ride is
// N min away" whenever the car is unavailable, on the honest reasoning that a car
// in a service bay is not N minutes away at any distance. Correct — and silent.
// The rider was left with a bare "Where to?" over a fleet that cannot take a
// single request, and the first thing that told them otherwise was a Review sheet
// two taps later. This banner is the WHY the placeholder deliberately does not
// say, stated up front where the ask begins.
//
// THREE rules, all of which fall out of not over-claiming:
//
//  • **It needs a non-empty vehicle set.** "No rides available" about NO vehicles
//    is a different (and already-handled) situation — MYR-343's `.empty` shell,
//    which sends the rider to redeem an invite code. Rendering this banner there
//    would answer a question the rider never asked with a fact that isn't the one
//    they need.
//  • **ONE requestable vehicle cancels it.** The predicate is "no vehicle can take
//    an instant request", not "the watched vehicle can't" — a rider whose second
//    car is free has rides available, whatever the first one is doing.
//  • **Scheduling is stated only when it is genuinely open.** MYR-313 keeps
//    reservations open against `inService` / `offline` (and the contract keeps them
//    outside the `busy` index), while §7.18 refuses them against a `paused` car on
//    all three enforcement layers. So the second line is derived from
//    `FleetUnavailability.offersScheduling` — the shipping predicate — and a fleet
//    that is entirely paused gets NO second line rather than a longer walk to the
//    same `409 vehicle_unavailable`.
//
// LIVE-PATH-ONLY BY CONSTRUCTION, and therefore drift-gate-neutral: every
// `FleetMember` fixture carries `unavailability == nil`, and `SharedViewerState
// .liveFleetMembers` resolves to an empty list in SIM (it is gated on the same
// `isLiveLocation` seam `liveFleetMember` is). Every simulated boot and every
// pre-existing DEBUG scene therefore takes the `nil` branch before any copy is
// composed, exactly as `RiderIdlePlaceholder.items(resolvesLiveETA:)` does.

/// What the idle banner says. A value, so the whole copy matrix is testable
/// without mounting a view.
public struct RiderIdleAvailability: Equatable {
    /// The headline — reason-specific for a single vehicle, generic for a fleet.
    public let headline: String
    /// The second line, or `nil` when scheduling is not an honest offer.
    public let detail: String?
}

public enum RiderIdleAvailabilityBanner {

    /// The multi-vehicle headline — the client's own words.
    ///
    /// Generic ON PURPOSE past one vehicle: with two cars out for two different
    /// reasons there is no single true sentence, and picking one car's reason to
    /// stand for the fleet would be a claim about the other. (Two cars out for the
    /// SAME reason is a real case where a specific line would read better; it is
    /// deliberately not special-cased, because "all of them happen to be in
    /// service" is a coincidence the copy would be asserting as a pattern.)
    public static let genericHeadline = "No rides available right now"

    /// The second line. A statement of what is still possible, not a CTA — the
    /// affordance it points at is the search bar directly below, which stays
    /// exactly where it is. MYR-233's "never a dead end" rule, at idle.
    public static let schedulingDetail = "You can still schedule a pickup."

    /// The tail of the single-vehicle headline. Kept as one constant so the
    /// sentence's shape is visible in one place next to the clause it follows.
    public static let singleVehicleTail = " \u{2014} no rides right now"

    /// THE predicate + copy, in one pure function.
    ///
    /// - Parameter members: the rider's resolved vehicle set, already mapped
    ///   through the shipping `LiveFleetMemberMapping` (so `unavailability` is the
    ///   MYR-233/342 predicate's own answer, never re-derived here).
    /// - Returns: the banner, or `nil` when there is nothing honest to say —
    ///   an empty set, or any vehicle that can take a request right now.
    public static func banner(members: [FleetMember]) -> RiderIdleAvailability? {
        guard !members.isEmpty else { return nil }
        // `unavailability == nil` is the ONE requestable value (MYR-233). One is
        // enough to cancel the banner outright.
        guard !members.contains(where: { $0.unavailability == nil }) else { return nil }

        let reasons = members.compactMap(\.unavailability)
        // Guaranteed non-empty by the two guards above, but derived rather than
        // force-unwrapped so a future change cannot make this a crash.
        guard !reasons.isEmpty else { return nil }

        let headline: String
        if members.count == 1, let only = members.first, let reason = only.unavailability {
            // `owner` is the vehicle's own nickname on the live path ("Lunar") —
            // MYR-212's naming, the same field Review's helper line and vehicle row
            // title use, so the rider reads one name for one car everywhere.
            headline = "\(only.owner) \(reason.riderClause)\(singleVehicleTail)"
        } else {
            headline = genericHeadline
        }

        return RiderIdleAvailability(
            headline: headline,
            detail: reasons.contains(where: \.offersScheduling) ? schedulingDetail : nil
        )
    }
}

// MARK: - The banner's height, reported to the sheet

/// MYR-352 — the banner's own measured height, so the idle card can reserve
/// exactly what it costs. `0` (the default) whenever no banner is rendered, which
/// is every simulated boot and every pre-existing DEBUG scene.
///
/// The banner is measured rather than pinned to a constant because its height is
/// genuinely not knowable in advance: the headline wraps to two lines for the
/// longer reasons (`"Lunar has paused ride requests — no rides right now"` wraps
/// even at 393pt) and the second line is conditional, so the cost depends on the
/// reason, the vehicle's name and the device width. This is MYR-345's rule — a
/// live-only line brings exactly its own room — where the room can only be known
/// by asking the line.
///
/// The banner is also the ONLY thing in this card that is safe to measure. The
/// card itself ends in a greedy `Spacer(minLength: 0)`, so measuring IT reports
/// back whatever the engine proposed; adopting that as the detent ratchets the
/// sheet upward every layout pass (observed: the sheet ran away and the screen
/// went black). The banner has no such feedback edge — its height is a pure
/// function of its copy and the available width.
struct RiderIdleBannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - The banner

/// The muted banner that sits directly above the idle sheet's search bar.
///
/// DESIGN: this is the ABSENCE of an action, so it is muted end to end and
/// carries **no gold** — gold is the sacred "actionable moment" accent
/// (CLAUDE.md), and the search bar 14pt below it is already wearing it. The
/// container is `watchOnlyNotice`'s recipe verbatim (the same sheet's existing
/// muted-notice grammar, in the same slot, at the same 16/13 padding, the same
/// `controlRadius`, the same `mrtText @0.025` fill and the same STATIC
/// `mrtBorder` hairline — no `MRTTraceBorder`, no `mrtSearchGlow`), so the sheet
/// grows one more line of the language it already speaks rather than a new one.
/// The leading 6pt `mrtTextMuted` dot is the Review vehicle row's own
/// unavailable-state dot at its own size — the rider already reads that dot as
/// "not available", and reusing it costs no new vocabulary.
struct RiderIdleAvailabilityBannerView: View {
    let availability: RiderIdleAvailability

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            // Nudged onto the headline's optical centre — the dot is 6pt in a
            // ~17pt line box, and top-aligning the row (so a wrapped headline
            // stays left-flush) would otherwise strand it at the cap line.
            Circle()
                .fill(Color.mrtTextMuted)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(availability.headline)
                    .font(.system(size: 14, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = availability.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        // MYR-352 — report the banner's own height so the idle detent can grow by
        // exactly what it costs. The banner is the ONLY safe thing to measure in
        // this card: its height is a pure function of its copy and the available
        // width, with no feedback edge back to the sheet's own size (the card
        // itself ends in a greedy `Spacer` and would ratchet — see
        // `RiderIdleSearchSheet.measuredBannerHeight`).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RiderIdleBannerHeightKey.self, value: proxy.size.height)
            }
        )
        .background(
            Color.mrtText.opacity(0.025),
            in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mrt.rider.noRidesBanner")
    }
}
