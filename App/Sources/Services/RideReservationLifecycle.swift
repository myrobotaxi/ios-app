import Foundation
import MyRobotaxiContracts

// MARK: - A reservation is DORMANT between accept and dispatch (MYR-376 / MYR-377)
//
// THE DEFECT, from TestFlight r13 (build 202607310302). The client scheduled a
// ride for the NEXT DAY (Sat Aug 1, 12:00 PM), accepted it as the owner, and his
// Vehicle tab immediately showed the LIVE DISPATCH CARD — "En route to pickup ·
// Thomas" over a tappable "Picked up" — for a car that was parked in his
// driveway, a day early, with `dispatch_status` still NULL. He tapped Picked up,
// which the server took, and the ride sat on "Picked up · waiting for Thomas to
// start" forever. His verbatim summary of the other half: *"Rider flow is
// completely broken."*
//
// THE MODEL, and it is one sentence: **between the owner's ACCEPT and the ride's
// DUE MOMENT, a reservation is dormant, and nobody may act on it except to cancel
// or decline it.** The backend's reservation sweeper is what normally ends
// dormancy — at due time it stamps `dispatchedAt`, resolves `dispatchStatus`,
// pushes leg-1 navigation into the car and sends the rider's `ride.due`
// notification. Before that the ride exists and is confirmed and is not
// happening; after it, it is a live ride exactly like an instant one, with no
// special cases anywhere downstream.
//
// DORMANCY IS TIME-BOUNDED, NOT DISPATCH-ONLY, and that second clause is
// load-bearing. The server's own predicate (§7.8) lets a scheduled ride be picked
// up when `dispatch_status = 'sent'` **OR** `scheduledFor <= now`: a pre-due
// pick-up is refused, and at or past the due moment MANUAL PROCEED is the
// documented recovery for a dispatch that failed or never ran. If the client
// gated on `dispatchedAt` alone it would reproduce the original defect with the
// sign flipped — a reservation whose sweeper never fired would stay dormant
// forever, the owner would never get a card, and a rider would stand at the kerb
// beside a car nobody could dispatch. So the gates below take a `now`, and every
// caller passes the real clock.
//
// WHY THESE ARE CLIENT-SIDE PREDICATES AND NOT JUST A SERVER GATE. A parallel
// backend change adds the `409` that refuses a pick-up before dispatch, and this
// file does not depend on it landing: the owner must not be OFFERED the button in
// the first place, and the rider must not have a day-early tracking map to look
// at. A server gate answers "was that legal"; these predicates answer "what is
// this ride right now", which is the question every surface here is asking.
//
// EVERYTHING IS PURE. The two pipelines, four screens, the Live Activity state
// machine and the Drives → Upcoming filter all read the SAME functions, so
// "dormant" cannot come to mean two different things on two surfaces — which is
// exactly what the defect looked like from the outside (the owner's card said the
// ride was running while the rider's map said nothing was).
enum RideReservation {

    // MARK: Dispatch

    /// Has the server DISPATCHED this ride?
    ///
    /// The two fields resolve together — the sweeper (and, for an instant ride,
    /// the accept handler) stamps `dispatchedAt` as its exactly-once latch and
    /// records the push's outcome in `dispatchStatus` — so EITHER being present is
    /// evidence. The check is deliberately "did dispatch happen", not "did it
    /// succeed": `failed` (the virtual key is unpaired, Tesla refused) and
    /// `skipped` (the server-side kill-switch was off) both mean the sweeper RAN
    /// and the ride is now the owner's to drive. Treating those as still-dormant
    /// would hide the dispatch card from an owner whose car simply did not take
    /// the navigation push — the one case where they most need to act manually.
    static func isDispatched(dispatchStatus: DispatchStatus?, dispatchedAt: Date?) -> Bool {
        dispatchedAt != nil || dispatchStatus != nil
    }

    static func isDispatched(_ record: RideRequestRecord) -> Bool {
        isDispatched(dispatchStatus: record.dispatchStatus, dispatchedAt: record.dispatchedAt)
    }

    // MARK: The record-level model

    /// Does this record describe a RESERVATION (a ride booked for later) rather
    /// than an on-demand one? Reads `input.schedule`, which is present iff the
    /// wire carried a `scheduledFor` — the same fact every existing scheduled
    /// branch in this app already keys on.
    static func isReservation(_ record: RideRequestRecord) -> Bool {
        record.input.schedule != nil
    }

    /// Has this reservation's DUE MOMENT arrived?
    ///
    /// `false` when the instant is unknown, and that is the deliberate reading of
    /// an absence rather than a defensive one: "we do not know when this ride is"
    /// is not evidence that its moment has come. It is also what keeps the
    /// SIMULATED path exactly as it was — a simulated record carries the picker's
    /// display strings and no absolute instant, so a reservation accepted in the
    /// simulator stays reserved into Drives → Upcoming and never grows a dispatch
    /// card, which is what every existing scene photographs.
    static func isPastDue(_ record: RideRequestRecord, now: Date) -> Bool {
        guard let scheduledFor = record.scheduledFor else { return false }
        return scheduledFor <= now
    }

    /// **DORMANT** — a reservation that exists but is not happening yet.
    ///
    /// `true` for a reservation that is still `requested` (nobody has answered
    /// it), or `accepted` while it is BOTH undispatched AND still in the future.
    /// `false` the moment the sweeper stamps the latch, `false` once the due
    /// moment passes (the server's manual-proceed window — see the file header),
    /// and `false` for every status beyond it (`arrived`, `enroute`, `completed`):
    /// a ride cannot have reached those without having gone live, and a status
    /// that says the rider is aboard outranks a missing optional field either way.
    ///
    /// A `requested` reservation stays dormant past its due moment on purpose.
    /// Nobody accepted it, so there is nothing to proceed WITH; the server expires
    /// it, and until then the honest client answer is that it never happened.
    ///
    /// `false` for an INSTANT ride at every status: dormancy is a thing that only
    /// happens to reservations, so an implementation that forgets the
    /// `isReservation` guard would silently freeze the whole instant flow.
    static func isDormant(_ record: RideRequestRecord, now: Date = Date()) -> Bool {
        guard isReservation(record) else { return false }
        switch record.status {
        case .pending:
            return true
        case .accepted:
            return !isDispatched(record) && !isPastDue(record, now: now)
        case .arrived, .enroute, .completed, .declined:
            return false
        }
    }

    /// **LIVE** — this ride is happening now, so every live-ride surface (the
    /// owner's dispatch card, the rider's tracking sheet, the Live Activity)
    /// applies to it unchanged.
    ///
    /// The exact complement of `isDormant` for a non-terminal ride, written as
    /// its own function because the surfaces that consume it read better in the
    /// positive and because a `!` in front of a predicate is the easiest thing in
    /// the world to drop in a refactor.
    static func isLiveRide(_ record: RideRequestRecord, now: Date = Date()) -> Bool {
        !isDormant(record, now: now)
    }

    // MARK: The wire-level model

    /// **ADOPTABLE** — may this wire ride take the rider's single ACTIVE slot?
    ///
    /// Renamed from `isOpenInstant` (MYR-230), because it is no longer a question
    /// about instant rides only and the old name asserted the very thing MYR-377
    /// had to change. The rule in full:
    ///
    ///  • Terminal (`completed` / `declined` / `cancelled` / unrecognized) — never.
    ///  • An INSTANT ride in any open state — yes, unchanged. This is the set the
    ///    server's own `uq_go_ride_requests_active_instant_rider` index covers
    ///    (rest-api.md §7.8, migration 0004), and the `409 ride_active` semantics
    ///    built on it are instant-only and are NOT touched by this issue.
    ///  • A RESERVATION — only once it has GONE LIVE: `arrived`/`enroute`, or
    ///    `accepted` AND (dispatched OR past due).
    ///
    /// The last clause is the whole point. Adopting a DORMANT reservation would
    /// park tomorrow's ride in the slot that owns the rider's map, replacing the
    /// idle "Where to?" surface with a tracking view of a car that is not coming
    /// for another eighteen hours — and, because the slot holds one ride, would
    /// also lock the rider out of booking anything today. Its `OR past due` half
    /// is the mirror image: a reservation whose sweeper never ran is still the
    /// ride the rider is standing outside waiting for.
    static func isAdoptableLiveRide(
        _ ride: MyRobotaxiContracts.RideRequest,
        now: Date = Date()
    ) -> Bool {
        guard let scheduledFor = ride.scheduledFor.flatMap(RideRequestContractMapping.parseISO) else {
            guard ride.scheduledFor == nil else {
                // A reservation whose instant will not parse. It is not an instant
                // ride and its due moment is unknowable, so the only honest reading
                // is the dispatch latch alone.
                return ride.status == .arrived || ride.status == .enroute
                    || (ride.status == .accepted && isDispatched(
                        dispatchStatus: ride.dispatchStatus,
                        dispatchedAt: ride.dispatchedAt.flatMap(RideRequestContractMapping.parseISO)
                    ))
            }
            // Instant: the pre-existing open-state set, byte for byte.
            switch ride.status {
            case .requested, .accepted, .enroute, .arrived: return true
            default: return false
            }
        }
        switch ride.status {
        case .arrived, .enroute:
            return true
        case .accepted:
            return isDispatched(
                dispatchStatus: ride.dispatchStatus,
                dispatchedAt: ride.dispatchedAt.flatMap(RideRequestContractMapping.parseISO)
            ) || scheduledFor <= now
        default:
            // `requested` — accepted by nobody, so dormant by definition, however
            // long ago its moment was.
            return false
        }
    }

    /// **UPCOMING** — does this wire ride belong in the owner's Drives → Upcoming
    /// list, i.e. is it a reservation the owner has confirmed and the server has
    /// not yet dispatched?
    ///
    /// The exact inverse of `isAdoptableLiveRide` over accepted reservations, and
    /// the filter the client's own screenshot needed: his `arrived` ride — a ride
    /// with a passenger in it — was still listed as something that had not happened
    /// yet. A row in "Upcoming" is a promise about the future; the moment the ride
    /// goes live it stops being one and the dispatch card owns it instead. That
    /// includes a PAST-DUE reservation whose sweeper never ran: the owner's job
    /// there is to proceed manually, not to read about it in a list of plans.
    static func isUpcomingReservation(
        _ ride: MyRobotaxiContracts.RideRequest,
        now: Date = Date()
    ) -> Bool {
        guard ride.scheduledFor != nil, ride.status == .accepted else { return false }
        return !isAdoptableLiveRide(ride, now: now)
    }

    // MARK: The due moment

    /// When this held record stops being dormant, or `nil` when it is not a
    /// dormant reservation (nothing to wait for) or carries no parseable instant.
    ///
    /// Used to arm ONE refetch per held dormant ride — see
    /// `LiveRideRequestService.armDueRefetch`. Not a poll: the client already
    /// knows the wall-clock moment the server will act, so it can sleep until then
    /// and ask once.
    ///
    /// The refetch is what makes the TIME-BOUNDED half of dormancy visible.
    /// Nothing re-renders SwiftUI because a wall clock passed a threshold, so the
    /// gates would flip only on the next unrelated state change; sleeping to the
    /// instant and folding an authoritative record is what turns "the moment
    /// arrived" into a frame on screen.
    static func dueInstant(_ record: RideRequestRecord, now: Date = Date()) -> Date? {
        guard isDormant(record, now: now), let scheduledFor = record.scheduledFor else { return nil }
        return scheduledFor
    }
}
