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
/// `riderLabel` is deliberately a RESOLVED label rather than the wire's raw
/// `requesterName`, so the MYR-228 no-fabricated-name rule is enforced at the point
/// the value is built instead of at each place it is read — see
/// ``LiveUpcomingReservations/reservation(from:)``.
struct UpcomingReservation: Identifiable, Equatable, Sendable {
    /// The SERVER's ride id — the id `POST /api/ride-requests/{id}/decline` takes.
    let id: String
    /// The rider's display name, or `IncomingRequestDisplay.neutralRole` when the
    /// wire carried none. Never a persona, never a fabricated initial.
    let riderLabel: String
    /// The pickup instant (`scheduledFor`). A reservation with no parseable one is
    /// not represented at all — see the mapping.
    let scheduledFor: Date
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
            collected.append(contentsOf: page.items.compactMap(Self.reservation(from:)))
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
    /// Two deliberate drops, both honest rather than defensive:
    ///  • a record the mapping refuses (a terminal/cancelled status) is not a
    ///    reservation this pause can strand;
    ///  • a row with no parseable `scheduledFor` cannot be stated as a pickup TIME,
    ///    and the whole line is "Pickup {when} — {who}". A line with a blank when is
    ///    worse than one fewer line, and the server's own predicate is
    ///    `scheduled_for` being non-null and future, so this is a shape it does not
    ///    emit.
    static func reservation(from wire: MyRobotaxiContracts.RideRequest) -> UpcomingReservation? {
        guard let record = RideRequestContractMapping.record(from: wire),
              let scheduledFor = wire.scheduledFor.flatMap(RideRequestContractMapping.parseISO)
        else { return nil }
        // `isLive: true` unconditionally, and that is correct rather than a shortcut:
        // this type only ever holds WIRE records. It routes the name through
        // `IncomingRequestDisplay` instead of reading `requesterName` directly so
        // the trim/empty rule and the "Shared viewer" fallback stay in ONE place
        // (MYR-228 / MYR-264) — a nameless reservation renders honestly here for the
        // same reason the incoming card does.
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: nil)
        return UpcomingReservation(id: wire.id, riderLabel: display.riderLabel, scheduledFor: scheduledFor)
    }
}
