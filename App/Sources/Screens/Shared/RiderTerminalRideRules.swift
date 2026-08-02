import Foundation

// MARK: - What a TERMINAL ride may still drive on the rider's map (MYR-381)
//
// A declined ride does not leave the rider's active slot: the `DeclinedNotice` is
// built from that record, so `LiveRideRequestService` keeps it (`cancelled` is the
// one status that erases — MYR-172's note). That retention is correct and it is
// also why two of r14's defects were the same defect: every surface that reached
// for `activeRequest` got a ride that had ENDED and treated it as one that had not.
//
//  • The rider Live Map kept ETCHING the dead ride's leg — the client's 1,000-mile
//    Illinois → Dallas polyline behind the idle sheet.
//  • The Ride declined / Dismiss | Rebook card CAME BACK after it was dismissed,
//    because the dismissal wrote a view-scoped flag while the record that raises
//    the card was still there to raise it again on the next appearance.
//
// Both rules live here, pure and side-effect-free, for the reason MYR-294 gives:
// three situations told apart by one flag means one of them always borrows
// another's surface. `SharedViewerScreen` reads them; the tests drive them directly.

/// May this ride's geometry be drawn?
enum RiderRouteLifetime {
    /// `false` for exactly one status: **`.declined`** — the ride that never
    /// happened. A route is a claim about a journey, and the client's screenshots
    /// are that claim made about a refusal: a 1,000-mile line across four states,
    /// drawn in the route's own gold, for a ride the owner had said no to. This is
    /// MYR-237's "no straight lines ever" pointed at TIME rather than at shape —
    /// real road geometry for a ride nobody is taking is exactly as false as a
    /// fabricated line for a ride they are.
    ///
    /// **`.completed` KEEPS ITS ROUTE, deliberately.** That map is ABOUT the ride
    /// that just happened: the tracking sheet holds the leg through the drop-off
    /// and hands it to the Ride Summary, whose hero is that very polyline. Ending
    /// it at `completed` would blank the map at the exact moment it is the subject
    /// — and would drop the tracking map onto its `[financialDistrict,
    /// embarcaderoCenter]` fallback pair for the frame between `completed` and the
    /// summary. The completed ride's route is released with the SLOT instead (see
    /// `SharedViewerScreen.releaseRouteIfSlotEmpty`), which is also the only signal
    /// a CANCELLED ride ever gives.
    ///
    /// Written as an exhaustive switch rather than `!= .declined` so a status added
    /// later has to be classified rather than defaulting into drawing.
    static func bearsRoute(status: RideRequestStatus) -> Bool {
        switch status {
        case .pending, .accepted, .arrived, .enroute, .completed: return true
        case .declined: return false
        }
    }
}

/// MYR-233 criterion 4, as a pure rule (MYR-402).
///
/// It lived as a `switch` inside `SharedViewerScreen.syncRiderOwnsActiveRide`, which
/// is fine until the question is asked by a test — and MYR-402 is a defect about
/// what happens the moment this answer goes from `true` to `false`, so the answer
/// had to become something a test can compute without mounting a view. It sits here
/// beside the other two terminal-ride rules because it is the third one: what a
/// terminal ride may still SUPPRESS.
enum RiderOwnRideException {
    /// Does this rider hold an OPEN ride — one whose car must never read Busy to
    /// them (`FleetUnavailability.busy` only; see `LiveFleetMemberMapping`)?
    ///
    /// `nil` is FALSE and is the case MYR-402 turns on: `LiveRideRequestService`
    /// maps the wire's `cancelled` to no status at all and empties the slot
    /// (MYR-172's erasure), so a cancelled ride reaches this rule as an absence.
    ///
    /// Exhaustive rather than a set membership test, so a status added later has to
    /// be classified rather than defaulting into holding the exception open.
    static func holdsOpenRide(status: RideRequestStatus?) -> Bool {
        switch status {
        case .pending, .accepted, .arrived, .enroute: return true
        case .completed, .declined, .none: return false
        }
    }
}

/// MYR-424 — what a FRAME may apply on its own, when its refetch does not answer.
///
/// `LiveRideRequestService.applyRemote` deliberately ignores the status a
/// `ride_status_changed` frame carries and refetches the full record instead: the
/// frame is summary-only (see `RideRequestEvent`), and folding a summary would
/// drop the places, the identity and the dispatch latch. That is the right rule
/// for the happy path and it has one hole — `guard let ride = try? await
/// api.rideRequest(id:) else { return }`. A frame that ARRIVED is then thrown away
/// whole because one GET failed, and the transition it announced is lost for the
/// rest of the session; nothing re-asks while the app stays foreground.
///
/// This rule is the narrowest possible patch on that hole: a frame may apply its
/// own status ONLY when that status ENDS the ride. The reasoning is asymmetric on
/// purpose.
///  • An intermediate status (`accepted`, `arrived`, `enroute`) drives surfaces
///    that need the refetched record to be honest — the tracking sheet's leg, the
///    pickup place, the dispatch latch. Half of one is worse than none, and the
///    next frame or the due-refetch will carry it anyway.
///  • A TERMINAL status needs nothing but itself. "This ride is over" is the whole
///    payload, every surface that reads it reads only the status, and it is the
///    one transition with no next frame behind it to try again. A ride that
///    cannot end is precisely r20's stuck pill.
///
/// `cancelled` is excluded even though it is terminal: it is mapped to an ERASURE
/// of the slot (`integrate`'s `guard let mapped … else`), and erasing a rider's
/// record on the strength of a failed read is a far worse mistake than a stale
/// one. Unknown wire values are excluded for the same reason — this build cannot
/// know whether they end anything.
///
/// Keyed on the raw wire string rather than a contracts enum because the two
/// payload types carry their own nested `Status`; the strings are the stable
/// cross-surface contract (`RideStatusChangedPayload.status`: "Member order
/// identical to ride-request.schema.json $defs.RideRequestStatus … so raw wire
/// values are interchangeable across surfaces").
enum RideFrameTerminalStatus {
    /// The app status a frame carrying `wire` may apply WITHOUT a refetch, or
    /// `nil` when the frame must wait for the record.
    static func applicable(wire: String?) -> RideRequestStatus? {
        switch wire {
        case "declined": return .declined
        case "completed": return .completed
        default: return nil
        }
    }
}

/// Should the Ride-declined card be on screen?
///
/// MYR-306 filed the `.declined` acknowledgment variant on 2026-07-27 and it never
/// shipped; r14 is where it became user-visible. The precedent it is built on is
/// MYR-292's `.completed` one, which is why the acknowledgement is an ID on the
/// ROLE-SCOPED observable rather than a `Bool` in the view: `SharedViewerScreen`
/// is rebuilt by `RootView`'s own `switch`, so a flag in `@State` is forgotten by
/// the next tab switch — and the record that raises the card is still there to
/// raise it again, which is precisely what the client saw.
///
/// Keying on the RIDE ID (not a bare flag) is what makes the dismissal both
/// permanent and narrow: the NEXT declined ride is a different id, so it raises a
/// fresh card, however many times this one is re-folded by a due-refetch, a
/// foreground refetch, a WS frame or a mount reconciliation.
enum RiderDeclinedNotice {
    /// - Parameters:
    ///   - status: the held record's status.
    ///   - rideID: the held record's id. A record with no server id yet cannot have
    ///     been declined, so `nil` never raises.
    ///   - acknowledgedID: the id the rider has already dismissed (or rebooked from).
    static func shouldRaise(status: RideRequestStatus, rideID: String?, acknowledgedID: String?) -> Bool {
        guard status == .declined, let rideID else { return false }
        return rideID != acknowledgedID
    }
}
