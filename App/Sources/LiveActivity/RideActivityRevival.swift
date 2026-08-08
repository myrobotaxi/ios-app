import Foundation

// MARK: - A card that is GONE can only come back from the app (MYR-479)
//
// MYR-405 gave the launch/foreground pass two arms: ADOPT the card that is already
// on the lock screen for this ride, and REAP every card that is not this account's
// live ride. Both arms are about Activities that EXIST. Neither has anything to say
// about the case this issue is named for — **a live ride with no Activity at all.**
//
// That state is not exotic and it has three ordinary routes into it:
//
//  • **The client ended the card itself on a `409 reservation_expired`.** §7.21's
//    409-means-end-now (MYR-172) is right for a ride that really is terminal, and
//    until telemetry PR #381 the server raised it for rides that were merely PAST
//    THEIR RESERVED TIME while `accepted`, `arrived` or `enroute`. The client
//    obeyed: `flushPendingRegistration`'s conflict arm ended the Activity and
//    released the row. The server half is fixed — the refusal is now scoped to
//    rides still at `accepted` — but every rider whose card that took down is left
//    with a live ride and a blank lock screen, and **nothing on the server can put
//    it back**: APNs can update or end an Activity, it cannot create one.
//  • **This process's memory outlived the card.** `standDownIfTheSystemEndedTheHeldCard`
//    only stands down when the restore list still MENTIONS the ride — "absence is
//    deliberately not evidence", which is correct mid-restore and is what makes a
//    settled absence unreadable. So a card removed while the app was away leaves
//    `phase` naming it for ever, `action` answers `.update`, and the app spends the
//    rest of the ride writing frames into a card that is not there.
//  • **Live Activities were switched off and back on**, or the per-app concurrent
//    limit refused the original `Activity.request` (`performStart` treats a refusal
//    as ordinary and leaves `phase` at `.idle`, which is right — and leaves nothing
//    to retry it).
//
// ─────────────────────────────────────────────────────────────────────────────
// **WHAT IS ALREADY TRUE, STATED PLAINLY SO THIS ARM IS NOT CREDITED WITH IT.**
// A COLD LAUNCH into a live ride with an empty restore list already started a card:
// `handleLaunchOrForeground` finishes by calling `handleRideChange`, which over a
// `.idle` phase answers `.start`. That path is unchanged and this arm agrees with
// it. What the arm adds is the ability to reach the same answer when `phase` is NOT
// idle (route 2, which no existing path can recover from) and to state the rule
// where it can be asserted instead of leaving it as a consequence of two other
// rules meeting.
// ─────────────────────────────────────────────────────────────────────────────

/// What the launch/foreground pass must do about a live ride with no card.
enum RideActivityRevival: Equatable {
    /// Nothing: either the ride is not one that may hold a card, or a card for it is
    /// already on screen (adoption's job), or the rider swiped this ride away.
    case none

    /// Start a FRESH Activity for this ride. The id is the RECORD's — which after a
    /// relaunch is the SERVER's — so the new card is stamped with, and registers
    /// under, the id §7.21 expects (MYR-415/416).
    case start(rideID: String)
}

extension RideActivityStateMachine {

    /// Does this live ride need a card started for it?
    ///
    /// Pure, and deliberately given the whole account rather than a ride id: the
    /// eligibility question is `mayStartActivity`'s, and `RideActivityLiveRide`
    /// cannot answer it. `resolve()` returns `.live` for a COMPLETED ride on purpose
    /// (MYR-425 — it is still the ride the lingering arrival card is about), so an
    /// arm that keyed on the reconciliation's `liveRide` alone would put a fresh
    /// "You've arrived" card on the lock screen five minutes after a ride ended,
    /// which is `startState`'s own "announcing something that finished before it
    /// appeared".
    ///
    /// `dismissedRideIDs` is the MYR-405 finality set and it is consulted through
    /// `identity`, exactly as `action` and `performStart` consult it: a swipe is only
    /// ever recorded under the CARD's id and this ride's id is the SERVER's after a
    /// relaunch. **The finality set is not weakened by this arm** — see
    /// `testALegTransitionDoesNotReEarnACardAfterASwipe` and the PR's own note.
    ///
    /// **An `.ended` card still counts as a card**, which is why the test is
    /// `isOnScreenAndOurs`'s complement rather than "the list does not mention it".
    /// An `.ended` Activity is living out a dismissal policy and may still be visible
    /// (MYR-405's own reason for skipping it in the reaper); starting a second one
    /// beside it is the duplicate-banner defect this feature spent an issue removing.
    /// It leaves the list on its own, and the next foreground revives then.
    static func revival(
        snapshots: [RideActivitySnapshot],
        account: RideActivityAccountRide,
        dismissedRideIDs: Set<String> = [],
        identity: RideActivityRideIdentity = .unmapped,
        now: Date = Date()
    ) -> RideActivityRevival {
        // A read taken before the ride pipeline answered is not evidence about
        // anything — the same third arm the reaper needed (MYR-405), pointed the
        // other way. Starting a card on an `.unresolved` reading would put one up
        // for a ride the account may not hold.
        guard case .live(let rideID) = account.resolve(now: now),
              let record = account.record,
              mayStartActivity(for: record, now: now)
        else { return .none }

        guard !identity.anyIdentity(of: rideID, isIn: dismissedRideIDs) else { return .none }

        let alreadyHasACard = snapshots.contains {
            $0.lifecycle != .dismissed
                && identity.namesTheSameRide(activityRideID: $0.rideID, as: rideID)
        }
        guard !alreadyHasACard else { return .none }

        return .start(rideID: rideID)
    }
}
