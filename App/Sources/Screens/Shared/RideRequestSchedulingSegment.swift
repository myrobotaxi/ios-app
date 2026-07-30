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
//  • **The predicate is the idle banner's, not a second one.** The segment is
//    raised by exactly `RiderIdleAvailabilityBanner.banner(members:)` being
//    non-nil, so the bar, the banner and the segment can never contradict each
//    other. Re-deriving the predicate here would be a second place for it to
//    drift, which is what MYR-352 factored `FleetUnavailability.riderClause` out
//    to prevent.
//
//    **MYR-363b — the COPY is where the two surfaces deliberately part.** MYR-361
//    took the banner's headline verbatim, so a single-vehicle fleet put the car's
//    own name under a dimmed chip: "Lunar is in service — no rides right now".
//    CLIENT-DIRECTED: the segment caption is now the GENERIC
//    `RiderIdleAvailabilityBanner.genericHeadline` in every case, and **the
//    vehicle-named reason lives only on the idle banner**. The two surfaces are
//    answering different questions — the banner explains a fleet the rider is
//    looking at, while this caption explains why one chip of two is not offered —
//    and a car's name is an answer to the first, not the second. The generic line
//    is also the one sentence that stays true as the set changes underneath a
//    LATCHED value (below), which the named one does not.
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
    /// The honest line under a disabled "Now". MYR-363b (client-directed): always
    /// the GENERIC `RiderIdleAvailabilityBanner.genericHeadline`, never the
    /// vehicle-named single-car sentence — that one belongs to the idle banner
    /// alone. `nil` whenever "Now" is offered.
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
        guard RiderIdleAvailabilityBanner.banner(members: members) != nil else {
            return .unconstrained
        }
        // …and scheduling has to actually be open, or there is no better default to
        // move to. A paused-only fleet lands here.
        guard members.compactMap(\.unavailability).contains(where: \.offersScheduling) else {
            return .unconstrained
        }
        // MYR-363b — the GENERIC line, for a fleet of any size. See the header.
        return RideSchedulingAvailability(
            defaultsToSchedule: true,
            nowCaption: RiderIdleAvailabilityBanner.genericHeadline
        )
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

// MARK: - MYR-363b — the prompt the default was missing
//
// MYR-361 moved the SELECTION to Schedule when nothing can take an instant
// request, and stopped there. So the rider arrived on a sheet reading **Schedule**
// with no time behind it, picked a destination, and got a "Continue" that walks
// them to a Review whose CTA is gated — the dead end MYR-233 exists to prevent,
// reached by a different road. The segment said what would happen and nothing ever
// asked for the one input that makes it possible.
//
// So: when the segment DEFAULTED to Schedule (nobody chose it) and the rider picks
// a destination with no time set, the schedule card opens ITSELF, once.
//
// FIVE conditions, and each one is a way of not nagging:
//
//  • **`defaultsToSchedule`** — the DEFAULT, not the selection. A rider who tapped
//    Schedule on an available fleet already opened the card with that tap; opening
//    it again on their next action would be the app pressing a button twice.
//  • **No committed schedule.** A time already chosen is the answer this prompt
//    exists to collect.
//  • **The card is not already up** (the MYR-233 `opensScheduleOnSearch` route
//    lands exactly here, and MYR-353's auto-focus hazard points the same way).
//  • **ONE SHOT PER DRAFT.** `alreadyPrompted` latches the moment the card opens,
//    so an explicit dismissal is FINAL: the rider said no, and re-opening on their
//    next destination would be the same modal twice for the same reason. It resets
//    only when the draft does (`resetDraftToIdle`), i.e. a genuinely new request.
//  • It presents through `openScheduleCard()` like every other entry, so MYR-353's
//    keyboard rule and MYR-316's floor reconciliation are the SHIPPING ones rather
//    than a second copy — a prompt that raised itself over a live first responder
//    would recreate the exact defect MYR-353 fixed, and this is the one entry point
//    the rider did not ask for.
enum RideScheduleDefaultPrompt {

    /// Whether picking a destination should open the schedule card by itself.
    ///
    /// - Parameters:
    ///   - availability: the LATCHED entry-time fact — `defaultsToSchedule` is the
    ///     "nobody chose this" signal, and the ONLY one there is.
    ///   - hasSchedule: `viewerState.draftSchedule != nil`.
    ///   - cardOpen: the picker is already presented.
    ///   - alreadyPrompted: this draft has already had its one shot.
    static func shouldOpen(
        availability: RideSchedulingAvailability,
        hasSchedule: Bool,
        cardOpen: Bool,
        alreadyPrompted: Bool
    ) -> Bool {
        availability.defaultsToSchedule && !hasSchedule && !cardOpen && !alreadyPrompted
    }
}
