import Foundation

// MARK: - MYR-361 — the Now/Schedule segment tells the truth about the fleet
//
// THE CLIENT'S REPORT (TestFlight, Jul 30, build 202607300926, AKwpPQIV…):
// *"Even though no car is available right now it's still allowing me to request a
// ride right now. Vs defaulting to scheduling."* — and, on the schedule card
// (AFYmN2g8…): *"scheduled should be selected instead of now."*
//
// Both are the same missing rule. MYR-352 taught the IDLE sheet to say "Lunar is
// in service — no rides right now / You can still schedule a pickup", and the
// rider tapped straight past it into a Search sheet whose segment still read
// **Now** — the one thing the sentence they had just read said was impossible.
// The segment was a pure function of `draftSchedule` alone, so it had no way to
// know.
//
// This is that decision, as a value, so the whole matrix is testable without
// mounting SwiftUI (the `RideRequestCTAGate` / `RiderIdleAvailabilityBanner`
// precedent).
//
// FOUR rules, and every one of them is about not over-claiming:
//
//  • **The predicate is the idle banner's, not a second one.** `nowCaption` IS
//    `RiderIdleAvailabilityBanner.banner(members:)`'s headline, verbatim — the
//    rider reads the same sentence on the idle sheet and under the disabled Now
//    chip, so the two surfaces cannot contradict each other. Re-deriving the copy
//    here would be a second place for the grammar to drift, which is exactly what
//    MYR-352 factored `FleetUnavailability.riderClause` out to prevent.
//  • **A PAUSED-only fleet changes nothing.** `paused` gates the instant CTA and
//    offers no scheduling either (MYR-342, rest-api.md §7.18 refuses reservations
//    on all three enforcement layers). Defaulting the segment to Schedule there
//    would point the rider at a picker whose every slot ends in the same
//    `409 vehicle_unavailable` — a longer walk to the same dead end, which is the
//    precise thing `FleetUnavailability.offersScheduling` exists to prevent. Both
//    paths already gate honestly at Review, and the idle banner already said so
//    without a second line. So the segment is left exactly as it was: **the
//    absence of a good option is not a reason to fabricate a pick.**
//  • **SIM and a not-yet-loaded list are unconstrained.** `SharedViewerState
//    .liveFleetMembers` is empty on the simulated path and before `GET
//    /api/vehicles` lands, and an empty set resolves to `.unconstrained` — so every
//    simulated boot and every pre-existing DEBUG scene renders the segment
//    byte-identically, exactly as MYR-352's banner does.
//  • **It is latched at sheet ENTRY, never re-read per frame.** See
//    `RideSchedulingAvailability` below.

/// The entry-time availability fact behind the segment's default.
///
/// LATCHED, deliberately. `SharedViewerState.liveFleetMembers` is a computed
/// property over a list that is refetched and a telemetry-fed availability flag
/// that can flip mid-sheet; reading it per frame would let the segment jump under
/// the rider's thumb — and worse, re-enable a "Now" they had already been told was
/// unavailable, between the frame they aimed at and the frame they hit. The
/// resolution therefore runs once per arrival at Search (`onAppear` and the
/// idle→search phase change) and holds until the next arrival.
struct RideSchedulingAvailability: Equatable {
    /// True only when NOTHING in the rider's set can take an instant request AND
    /// scheduling is genuinely open. The one condition that moves the default.
    let defaultsToSchedule: Bool
    /// The honest line under a disabled "Now" — the idle banner's own headline.
    /// `nil` whenever "Now" is offered.
    let nowCaption: String?

    /// Nothing known against instant rides: the segment behaves exactly as it did
    /// before this issue. The value for SIM, for an unloaded list, for a fleet with
    /// one free car, and for a fleet that is only PAUSED.
    static let unconstrained = RideSchedulingAvailability(defaultsToSchedule: false, nowCaption: nil)

    /// - Parameter members: the rider's resolved vehicle set, already mapped
    ///   through the shipping `LiveFleetMemberMapping` — so `unavailability` is the
    ///   MYR-233/342 predicate's own answer and is never re-derived here.
    static func resolve(members: [FleetMember]) -> RideSchedulingAvailability {
        // The SET predicate, borrowed whole: non-empty, and no member requestable.
        // One free car cancels it outright, an empty set says nothing at all.
        guard let banner = RiderIdleAvailabilityBanner.banner(members: members) else {
            return .unconstrained
        }
        // …and scheduling has to actually be open, or there is no better default to
        // move to. A paused-only fleet lands here.
        guard members.compactMap(\.unavailability).contains(where: \.offersScheduling) else {
            return .unconstrained
        }
        return RideSchedulingAvailability(defaultsToSchedule: true, nowCaption: banner.headline)
    }
}

/// What the Now/Schedule segment renders.
///
/// ONE source, in the order facts outrank each other: a committed schedule beats
/// an open picker beats the entry-time default. There is no parallel "which chip is
/// lit" state anywhere — the client's *"scheduled should be selected instead of
/// now"* was exactly the symptom of the segment knowing only about `draftSchedule`
/// while a schedule was visibly being chosen a few points below it.
struct RideRequestSchedulingSegment: Equatable {
    enum Selection: Equatable { case now, schedule }

    let selection: Selection
    /// False → the "Now" chip renders dimmed and untappable, with `nowCaption`
    /// directly beneath it.
    let nowEnabled: Bool
    /// The reason, or `nil` when "Now" is offered.
    let nowCaption: String?

    /// - Parameters:
    ///   - availability: the LATCHED entry-time fact.
    ///   - hasSchedule: `viewerState.draftSchedule != nil` — the strongest fact
    ///     there is, and the one the rest of the flow (`RideRequestCTAGate
    ///     .isScheduled`, `RideRequestContractMapping.scheduledFor`) already reads.
    ///   - cardOpen: the schedule slide-up card is presented. A rider standing in
    ///     the picker IS scheduling, whether or not they have committed a slot yet;
    ///     leaving "Now" lit underneath it is the contradiction the client
    ///     photographed. Cancelling the card (no commit) falls straight back to
    ///     whatever the other two facts say — nothing is remembered, so a cancel
    ///     restores "Now" whenever "Now" is available.
    static func resolve(
        availability: RideSchedulingAvailability,
        hasSchedule: Bool,
        cardOpen: Bool
    ) -> RideRequestSchedulingSegment {
        let nowEnabled = !availability.defaultsToSchedule
        let selection: Selection = (hasSchedule || cardOpen || !nowEnabled) ? .schedule : .now
        return RideRequestSchedulingSegment(
            selection: selection,
            nowEnabled: nowEnabled,
            nowCaption: nowEnabled ? nil : availability.nowCaption
        )
    }
}
