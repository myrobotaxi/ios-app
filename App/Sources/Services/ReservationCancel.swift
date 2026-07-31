import Foundation
import MyRoboTaxiKit
import os

// MARK: - What happens when a reservation cancel does not go through (MYR-381)
//
// TestFlight r14, build 202607310508. The client tried to withdraw ONE reservation
// (`ce528c30…`, plain `accepted`, pre-due) from BOTH roles and neither worked:
// the rider's ScheduledRideSheet answered "Couldn't cancel that ride" and the
// owner's Drives → Upcoming X answered "Couldn't cancel that reservation" —
// behind a ✓, over copy that says the opposite.
//
// WHAT THE BYTES WERE. `ReservationCancelWireTests` drives the PRODUCTION
// `LiveRiderScheduledRides` / `LiveUpcomingReservations` over a real `RestClient`
// against a recording transport and asserts the request that comes out:
// `POST /api/ride-requests/{the server's own ride id}/cancel` and `…/decline`,
// no query, no body, one Bearer header. The id is `RideRequest.id` verbatim from
// the same list the row was built from, and both action paths are already pinned
// at the Kit boundary (`RideRequestEndpointTests`). Nothing about the request was
// wrong, and MYR-376/377's tests could not have said so either way: every one of
// them stubbed the SOURCE seam, above the two implementations that compose the
// call.
//
// SO THE SERVER REFUSED, AND THE CLIENT THREW THE ANSWER AWAY. Both stores caught
// `Error` and collapsed every possible cause — a 409 on a ride that had moved on,
// a 403, a 404, a dropped connection — into one sentence with no reason in it and
// no record anywhere. That is why this defect arrived unreproducible: the app knew
// exactly what the server said and kept it to itself.
//
// This file is the fix for THAT, and it is shared by both roles because both had
// the same hole:
//
//  1. **The failure is CLASSIFIED** (`ReservationCancelFailure`) — refused (the
//     server answered) vs unreachable (it did not) — and the two get different,
//     honest sentences, because they need different things from the person
//     reading them.
//  2. **The refusal is RECONCILED, not just reported** (`ReservationCancelOutcome`).
//     A cancel is refused most often because the ride is no longer cancellable —
//     it dispatched, it was declined, someone else ended it — and in that case the
//     re-read that both stores already perform comes back WITHOUT the row. A ride
//     that is gone is not a failure to report: the rider asked for it to be over
//     and it is over. Only a refusal with the reservation STILL STANDING is worth
//     a toast.
//  3. **The reason is RECORDED** (`ReservationCancelLog`). Status and error code
//     go to os_log at `error` level in RELEASE builds too, so the next TestFlight
//     round names the refusal in one `log show` instead of another day of guessing.
//     The ride id rides along as PRIVATE (the default) — a status code is
//     diagnostics, an id is somebody's ride.

/// Why a cancel/decline did not happen — the two things that are genuinely
/// different from where the user is standing.
enum ReservationCancelFailure: Equatable, Sendable {
    /// The server answered, and the answer was no. `status` is the HTTP status;
    /// `code` is the §4.1 envelope code when the body carried one.
    case refused(status: Int, code: String?)
    /// No answer at all — transport, timeout, an unreadable response. Nothing is
    /// known about the reservation, which is exactly what the copy must say.
    case unreachable

    /// Fold whatever the Kit threw into the two cases. `RestError.http` is the
    /// only shape that proves the server ANSWERED; everything else (transport,
    /// decoding, an invalid response, a cancelled task) means the round trip did
    /// not complete, and a client that reports those as a refusal is asserting
    /// something it cannot know.
    ///
    /// `rideActive` counts as refused: it is a real 409 with a real body.
    static func classify(_ error: any Error) -> ReservationCancelFailure {
        switch error as? RestError {
        case .http(let status, let code, _, _):
            return .refused(status: status, code: code?.rawValue)
        case .rideActive:
            return .refused(status: 409, code: "ride_active")
        default:
            return .unreachable
        }
    }

    /// Did the server answer at all? The discriminator the copy and the log both
    /// turn on.
    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }
}

/// What the surface should DO once the cancel has been attempted and the list
/// re-read. Pure, so both roles resolve it identically and it is asserted rather
/// than reasoned about.
enum ReservationCancelOutcome: Equatable, Sendable {
    /// The reservation is gone. Close the sheet, say nothing — this is what the
    /// person asked for, whoever ended it.
    case cancelled
    /// The reservation is still standing and the server would not release it.
    /// This sentence is the whole of what the surface says.
    case refused(notice: String)

    /// - Parameters:
    ///   - failure: `nil` when the mutation returned 2xx.
    ///   - stillHeld: does the RE-READ still list this reservation? A read that
    ///     did not answer must pass `true` — "I could not check" is not evidence
    ///     the ride is gone, and reporting a cancel that may not have happened is
    ///     the one outcome with a person standing at a kerb at the end of it.
    ///   - copy: the role's own two sentences.
    static func resolve(
        failure: ReservationCancelFailure?,
        stillHeld: Bool,
        copy: ReservationCancelCopy
    ) -> ReservationCancelOutcome {
        guard let failure else { return .cancelled }
        // THE RECONCILE. A refusal whose reservation has since left the list is
        // not something to tell anyone about: the most common refusal by far is a
        // `409` on a ride that dispatched, was declined, or was ended from the
        // other side, and in every one of those the list is the honest answer and
        // it agrees with the tap.
        guard stillHeld else { return .cancelled }
        switch failure {
        case .refused: return .refused(notice: copy.refused)
        case .unreachable: return .refused(notice: copy.unreachable)
        }
    }
}

/// The two sentences a role says. Held as a value rather than switched on inside
/// the resolver so the resolver has no idea which role it is serving — and so the
/// copy is assertable next to the rule that chooses it.
struct ReservationCancelCopy: Equatable, Sendable {
    /// The server answered no, and the reservation is still there.
    let refused: String
    /// Nothing answered. The reservation's fate is UNKNOWN, and the sentence says
    /// so rather than claiming a failure — "couldn't cancel" would be a statement
    /// about the server we did not hear from.
    let unreachable: String

    /// The RIDER, on `ScheduledRideSheet`. Deliberately names NO gesture: this tab
    /// has no pull-to-refresh, and a sentence that invents one is a second defect
    /// wearing an apology. The list has already been re-read by the time this is
    /// shown — the row standing IS the rest of the message.
    static let rider = ReservationCancelCopy(
        refused: "That ride can\u{2019}t be cancelled right now",
        unreachable: "Couldn\u{2019}t reach the server \u{00B7} the ride is still booked"
    )
    /// The OWNER, on Drives → Upcoming.
    static let owner = ReservationCancelCopy(
        refused: "That reservation can\u{2019}t be cancelled right now",
        unreachable: "Couldn\u{2019}t reach the server \u{00B7} the reservation stands"
    )
}

/// The receipt. `error` level so it survives the default log level on a device,
/// and RELEASE-compiled on purpose: the whole reason this defect cost a round is
/// that a TestFlight build knew the answer and wrote it nowhere.
enum ReservationCancelLog {
    private static let log = Logger(subsystem: "app.myrobotaxi.ios", category: "rides")

    /// - Parameter action: `"cancel"` (rider) or `"decline"` (owner) — the ACTION
    ///   path that was refused, so the line names the endpoint without printing a
    ///   URL that carries an id.
    static func record(_ failure: ReservationCancelFailure, action: String, rideID: String) {
        switch failure {
        case .refused(let status, let code):
            log.error("""
            reservation \(action, privacy: .public) refused \
            status=\(status, privacy: .public) code=\(code ?? "-", privacy: .public) ride=\(rideID)
            """)
        case .unreachable:
            log.error("reservation \(action, privacy: .public) unreachable ride=\(rideID)")
        }
    }
}
