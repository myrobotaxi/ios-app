import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Upcoming reservations for one vehicle (MYR-360)
//
// The input to the ride-share pause warning: what an owner is about to strand.
//
// THE DEFECT THIS EXISTS FOR. An owner pauses ride sharing on a car that already
// carries an ACCEPTED FUTURE RESERVATION. The server does not cancel it — it HOLDS
// the reservation at due time and expires it 30 minutes later — so the rider learns
// nobody is coming half an hour AFTER their pickup time. Nothing about that is
// recoverable by then, and nothing on the owner's screen said it would happen.
//
// The fix is entirely on the common path: read the reservations BEFORE committing
// the pause, and let the owner decide with them in front of them. That read is what
// this file is.

/// ONE upcoming reservation, reduced to the three facts the warning states: which
/// ride to decline, when it was booked for, and who booked it.
///
/// `riderFirstName` is deliberately a CLEANED optional rather than the wire's raw
/// `requesterName`, so the MYR-228 no-fabricated-name rule is enforced at the point
/// the value is built instead of at each place it is read — see
/// ``LiveUpcomingReservations/reservation(from:)``.
struct UpcomingReservation: Identifiable, Equatable, Sendable {
    /// The SERVER's ride id — the id `POST /api/ride-requests/{id}/decline` takes.
    let id: String
    /// The rider's server-resolved FIRST name, or `nil` when the wire genuinely
    /// carried none. Never a persona, never a fabricated initial — the caller
    /// renders the honest `RideSharePauseDialog.unnamedRider` fallback for `nil`.
    let riderFirstName: String?
    /// The pickup instant (`scheduledFor`). A reservation with no parseable one is
    /// not represented at all — see the mapping.
    let scheduledFor: Date
    /// MYR-376 — which car this reservation is against. The pause dialog never
    /// needed it (it asks about ONE vehicle by construction); Drives → Upcoming
    /// does, because a row has to name the car it is about.
    let vehicleID: String
    /// MYR-376 — the whole mapped record, so a second consumer does not re-read the
    /// same wire row a second way.
    ///
    /// This type began as the three facts the pause DIALOG states. Drives →
    /// Upcoming needs the destination, the trip estimate and the day/time strings
    /// as well, and every one of them is already computed by
    /// `RideRequestContractMapping.record(from:)` on the way past. Carrying the
    /// record is strictly cheaper than a second mapping and — more to the point —
    /// makes it impossible for the two owner surfaces to disagree about one ride.
    ///
    /// OPTIONAL, and the default below is what says why: the pause dialog's three
    /// facts are the type's contract, and the record is an ADDITION for one
    /// consumer. A test (or a future caller) that only cares about the dialog
    /// should not have to construct a whole ride to say so.
    let record: RideRequestRecord?

    init(
        id: String,
        riderFirstName: String?,
        scheduledFor: Date,
        vehicleID: String = "",
        record: RideRequestRecord? = nil
    ) {
        self.id = id
        self.riderFirstName = riderFirstName
        self.scheduledFor = scheduledFor
        self.vehicleID = vehicleID
        self.record = record
    }
}

/// The seam the pause warning reads and writes through.
///
/// Narrow on purpose: the warning needs exactly one read (the vehicle's upcoming
/// reservations) and one write (decline one of them), and nothing else about the
/// ride-request pipeline. Keeping it to those two keeps `HomeScreen`'s new
/// dependency to a protocol a test can implement in six lines, and keeps this
/// feature off `RideRequestService`, whose two role-scoped pipelines (MYR-325) have
/// nothing to do with an owner's availability switch.
protocol UpcomingReservationSource: Sendable {
    /// The owner's ACCEPTED, strictly-FUTURE reservations for `vehicleID`, SOONEST
    /// FIRST. An unknown/unowned vehicle answers an empty list, not an error.
    func upcomingReservations(vehicleID: String) async throws -> [UpcomingReservation]
    /// `accepted → declined` for a SCHEDULED ride. Fires the rider's lifecycle push
    /// immediately, which is the whole point: the rider learns now instead of 30
    /// minutes after the pickup they were counting on.
    func decline(reservationID: String) async throws
}

/// The live implementation — the Kit's REST surface, mapped by the SHIPPING
/// contract mapping rather than by a second reading of the same JSON.
struct LiveUpcomingReservations: UpcomingReservationSource {
    let api: any RideRequestAPI

    /// The page size asked for. The contract's own default; there is no reason to
    /// ask for more on the first page than the endpoint volunteers.
    static let pageLimit = 20
    /// How many pages are followed before the read stops.
    ///
    /// The list has to be COMPLETE for "Decline it and pause" to mean what it says
    /// — declining the first 20 of 25 and pausing would strand five riders by the
    /// exact mechanism this issue exists to prevent — so the read follows
    /// `nextCursor`. It is bounded anyway, because an unbounded client loop over a
    /// server-supplied cursor is a hang waiting for a server bug, and 100 future
    /// reservations on one car is already far outside anything this product
    /// produces.
    static let maxPages = 5

    func upcomingReservations(vehicleID: String) async throws -> [UpcomingReservation] {
        var collected: [UpcomingReservation] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let page = try await api.upcomingReservations(
                vehicleID: vehicleID,
                cursor: cursor,
                limit: Self.pageLimit
            )
            collected.append(contentsOf: page.items.compactMap { Self.reservation(from: $0) })
            guard page.hasMore, let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return collected
    }

    func decline(reservationID: String) async throws {
        _ = try await api.declineRideRequest(id: reservationID)
    }

    /// Wire → warning input, through the REAL mapping both owner surfaces already
    /// use, so a reservation named in this dialog is named exactly as the incoming
    /// card would name it.
    ///
    /// Three deliberate drops, all honest rather than defensive:
    ///  • a record the mapping refuses (a terminal/cancelled status) is not a
    ///    reservation this pause can strand;
    ///  • a row with no parseable `scheduledFor` cannot be stated as a pickup TIME,
    ///    and the day-and-time stamp is the row's whole primary line. A row with a
    ///    blank stamp over a name is worse than one fewer row, and the server's own
    ///    predicate is `scheduled_for` being non-null and future, so this is a shape
    ///    it does not emit.
    ///  • **MYR-376 — a reservation that is no longer UPCOMING.** The predicate is
    ///    `RideReservation.isUpcomingReservation`: accepted, scheduled, and NOT yet
    ///    dispatched. The client's own screenshot is the reason it exists — his ride
    ///    had reached `arrived`, with a passenger in the car, and Drives → Upcoming
    ///    still listed it as something that had not happened yet, offering an X that
    ///    the server refuses at that status. It matters for the pause warning too:
    ///    "you are about to strand this rider" is false about a rider who is already
    ///    aboard, and the endpoint's own future-only predicate is not something the
    ///    client should assume rather than check.
    static func reservation(
        from wire: MyRobotaxiContracts.RideRequest,
        now: Date = Date()
    ) -> UpcomingReservation? {
        guard RideReservation.isUpcomingReservation(wire, now: now),
              let record = RideRequestContractMapping.record(from: wire),
              let scheduledFor = wire.scheduledFor.flatMap(RideRequestContractMapping.parseISO)
        else { return nil }
        // `isLive: true` unconditionally, and that is correct rather than a shortcut:
        // this type only ever holds WIRE records. The name is taken through
        // `IncomingRequestDisplay.riderName` — the OPTIONAL, cleaned form — so the
        // trim/empty rule lives in ONE place (MYR-228 / MYR-264) and a nameless
        // reservation stays honestly nameless here.
        //
        // Deliberately NOT `.riderLabel`, whose fallback is now MYR-355's
        // "Former rider". That is the right answer on the incoming card — an
        // absent live `requesterName` means the account was deleted — but it is
        // the wrong answer in a list of pickups the owner is deciding whether to
        // DECLINE. A row saying "Former rider" would tell the owner this
        // reservation no longer has a passenger, which if true means the row
        // should not be in the list at all; the client cannot make that call (the
        // deletion sweep is the server's), so it keeps the dialog's neutral
        // plain-English fallback and lets the server's own list stand.
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: nil)
        return UpcomingReservation(
            id: wire.id,
            riderFirstName: display.riderName,
            scheduledFor: scheduledFor,
            vehicleID: wire.vehicleId,
            record: record
        )
    }
}
