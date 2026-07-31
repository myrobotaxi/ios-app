import Foundation
import MyRobotaxiContracts

// MARK: - Every word the Live Activity says (MYR-172)
//
// ALL COPY IS THE CLIENT'S. The server sends the status ENUM and never prose —
// "so wording can change in an app update without a server deploy"
// (live-activity.schema.json). This is the one place that wording lives, for both
// the lock-screen card and the Dynamic Island, and it is pure: no SwiftUI, no
// ActivityKit, so the app's unit tests can assert on it directly even though
// neither presentation can be instantiated in a test.

enum RideActivityCopy {
    /// What to call the car when the wire's `vehicleName` is the empty string.
    ///
    /// The schema is explicit that an unnamed car arrives as `""` rather than as an
    /// absent key, "in which case the client renders its own generic fallback
    /// rather than a blank". Trimming first because a name of only spaces is the
    /// same situation wearing a disguise, and a lock screen reading "  is on its
    /// way" is the failure this exists to prevent.
    static let genericVehicleName = "Your Tesla"

    static func vehicleDisplayName(_ wireName: String) -> String {
        let trimmed = wireName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? genericVehicleName : trimmed
    }

    /// The UPPERCASE kicker — the status word, in the design kit's label grammar
    /// (10–12pt / 500 / tracking +1.2, uppercase).
    ///
    /// `requested` says "REQUESTED" even though v1 never starts an Activity before
    /// `accepted`: a server push can legitimately move an Activity's status
    /// backwards to it in a race, and a kicker with a hole in it renders as an
    /// empty band rather than as nothing.
    static func kicker(for status: LiveActivityRideStatus) -> String {
        switch status {
        case .requested: return "Requested"
        case .accepted: return "On the way"
        case .arrived: return "Arrived"
        case .enroute: return "In ride"
        case .completed: return "Dropped off"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .reservationExpired: return "Reservation expired"
        // A status this build has never heard of. "Ride" is deliberately bland:
        // the alternative is guessing, and a confident wrong word on a lock screen
        // is worse than a vague right one.
        case .unrecognized: return "Ride"
        }
    }

    /// The supporting sentence under the kicker, naming the car and — where it is
    /// true — where it is going.
    ///
    /// The destination is NOT repeated on the terminal states: "Dropped off at
    /// Home" is right, but "Cancelled · to Home" reads as though something is
    /// still heading there.
    static func headline(for status: LiveActivityRideStatus, vehicleName: String, destination: String) -> String {
        let car = vehicleDisplayName(vehicleName)
        let place = destination.trimmingCharacters(in: .whitespacesAndNewlines)

        switch status {
        case .accepted:
            return "\(car) is coming to pick you up"
        case .arrived:
            return "\(car) is here"
        case .enroute:
            return place.isEmpty ? "\(car) is taking you there" : "\(car) → \(place)"
        case .completed:
            return place.isEmpty ? "You've arrived" : "You've arrived at \(place)"
        case .declined:
            return "\(car) can't take this ride"
        case .cancelled:
            return "This ride was cancelled"
        case .reservationExpired:
            // The one status with no ride-row twin. The sweeper gave up, so the
            // honest thing is to say the reservation lapsed rather than leave the
            // rider reading "on its way" about a car that is not coming.
            return "\(car) didn't make it in time"
        case .requested:
            return "Waiting for \(car)"
        case .unrecognized:
            return car
        }
    }

    /// The label above the ETA countdown.
    ///
    /// It changes with the leg because the number means two different things:
    /// before pickup it is when the car reaches the RIDER, after pickup it is when
    /// the rider reaches the DESTINATION. One label for both would be wrong half
    /// the time.
    static func etaLabel(for status: LiveActivityRideStatus) -> String {
        switch status {
        case .enroute: return "Arrive"
        default: return "Pickup"
        }
    }

    /// Whether a countdown may be shown at all for this status.
    ///
    /// A terminal ride has no future arrival, so even if a stale `eta` is still
    /// sitting in the content state it must not be counted down — that is the
    /// "never a confident stale ETA" rule (MYR-194) applied to the state rather
    /// than to the clock.
    static func showsCountdown(for status: LiveActivityRideStatus) -> Bool {
        switch status {
        case .accepted, .arrived, .enroute, .requested: return true
        case .completed, .declined, .cancelled, .reservationExpired: return false
        case .unrecognized: return false
        }
    }

    // MARK: - Staleness

    /// What the card says INSTEAD of a countdown once ActivityKit marks the content
    /// stale.
    ///
    /// MYR-194's staleness policy is "honest — the Activity renders 'as of X min
    /// ago' when updates lapse; never a confident stale ETA". So the ETA is not
    /// dimmed, it is REPLACED: a greyed-out "4 min" is still a number a rider will
    /// read as the answer, and the whole point is that we no longer know the
    /// answer.
    static let staleTitle = "Not updating"

    /// The "as of" line when there is no instant to date it from.
    ///
    /// The card normally renders staleness as "As of {relative}" using SwiftUI's
    /// self-updating relative style, which keeps counting while the screen is
    /// asleep and nothing is repainting. That needs a reference instant, and the
    /// only one the content state carries is the ETA — which is exactly the field
    /// that may be absent. So this is the arm for "stale, and we never had a time
    /// to be stale relative to": it claims nothing rather than inventing a
    /// duration.
    static let staleFallbackSubtitle = "Waiting for an update"
}
