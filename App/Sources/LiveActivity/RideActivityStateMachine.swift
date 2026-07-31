import Foundation
import MyRobotaxiContracts

// MARK: - When the Live Activity starts, changes and ends (MYR-172)
//
// PURE, and deliberately so. ActivityKit cannot be exercised in a unit test —
// `Activity.request` needs a real host process with a real widget extension — so
// everything worth asserting about the LIFECYCLE lives here, as a function of
// (what we last did, what the ride looks like now). The side-effecting half is
// `RideActivityCoordinator`, which does no deciding of its own.
//
// This is the same split `PushPermissionMoment.decide` uses for the MYR-186
// prompt: a pure decision beside a thin performer.

/// What the app currently has on the rider's lock screen.
///
/// The live case carries the LAST CONTENT STATE, which is not bookkeeping — it is
/// what makes an honest ending possible. When a ride is CANCELLED remotely the
/// rider's `activeRequest` is set to `nil` outright (`LiveRideRequestService
/// .integrate` maps the wire's `cancelled` to no status at all and erases the
/// record), so at the moment we most need to write a final frame there is no
/// record left to build one from. Holding the last frame means the Activity can
/// still end saying "Cancelled" with the right car and the right destination,
/// instead of blanking or lingering.
enum RideActivityPhase: Equatable {
    case idle
    case live(rideID: String, state: RideActivityAttributes.ContentState)

    var rideID: String? {
        if case .live(let id, _) = self { return id }
        return nil
    }

    var state: RideActivityAttributes.ContentState? {
        if case .live(_, let state) = self { return state }
        return nil
    }
}

/// How long the final frame stays on the lock screen (MYR-194 decision 5).
enum RideActivityDismissal: Equatable {
    /// Take it down as soon as the system allows. For endings the rider did not
    /// get anything out of — declined, cancelled, a lapsed reservation. There is
    /// no arrival to admire and leaving the card up is clutter about a
    /// non-event.
    case immediate

    /// Leave the final frame up for a while. For `completed` ONLY: the arrival
    /// state IS the payoff, and a rider who put their phone down during the last
    /// minute of the ride should still find "You've arrived at Home" when they
    /// pick it up.
    case linger(TimeInterval)

    /// ~15 minutes, per MYR-194 ("~15 min linger for completed so the rider sees
    /// the arrival state").
    static let completedLinger = RideActivityDismissal.linger(15 * 60)
}

/// The one thing to do about the Activity this tick.
enum RideActivityAction: Equatable {
    case none
    case start(rideID: String, state: RideActivityAttributes.ContentState)
    case update(rideID: String, state: RideActivityAttributes.ContentState)
    case end(rideID: String, state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal)
    /// The rider's live ride was replaced by a DIFFERENT one (the first ended or
    /// was erased while the app was away, and a new one is already open). One
    /// action rather than an end followed by a start, so the coordinator cannot
    /// interleave a token registration between the two and register the new ride's
    /// token against the old Activity.
    case restart(
        endingRideID: String,
        endingState: RideActivityAttributes.ContentState,
        rideID: String,
        state: RideActivityAttributes.ContentState
    )
}

enum RideActivityStateMachine {
    /// Decide what to do, given what we last did and what the rider's ride looks
    /// like now.
    ///
    /// `record` is the rider's `activeRequest` — `nil` meaning the rider holds no
    /// open ride at all, which is a genuine and load-bearing input rather than a
    /// missing one.
    static func action(
        phase: RideActivityPhase,
        record: RideRequestRecord?,
        vehicleName: String
    ) -> RideActivityAction {
        switch phase {
        case .idle:
            guard let record, let state = startState(for: record, vehicleName: vehicleName) else {
                return .none
            }
            return .start(rideID: record.id, state: state)

        case .live(let liveID, let lastState):
            guard let record else {
                // The record was ERASED. In this app that means cancelled: the wire's
                // `cancelled` maps to no app status, so `integrate` nils the record
                // rather than folding a `.cancelled` onto it. Ending on the last known
                // frame with the status corrected is the honest reading — the ride is
                // over and it did not complete.
                return .end(
                    rideID: liveID,
                    state: lastState.with(status: .cancelled),
                    dismissal: .immediate
                )
            }

            guard record.id == liveID else {
                // A different ride is open than the one on the lock screen. End the
                // old one; start the new one if it is startable, otherwise just end.
                let endingState = lastState.with(status: .cancelled)
                guard let next = startState(for: record, vehicleName: vehicleName) else {
                    return .end(rideID: liveID, state: endingState, dismissal: .immediate)
                }
                return .restart(
                    endingRideID: liveID,
                    endingState: endingState,
                    rideID: record.id,
                    state: next
                )
            }

            let current = contentState(for: record, vehicleName: vehicleName, previous: lastState)

            if let dismissal = dismissal(for: record.status) {
                return .end(rideID: liveID, state: current, dismissal: dismissal)
            }

            // Only speak when something actually changed. The coordinator is driven
            // by `.onChange` on the whole record, which fires for `trackProgress`
            // ticks the Activity does not carry — and every no-op `update` would
            // spend part of the rider's ActivityKit budget saying nothing.
            return current == lastState ? .none : .update(rideID: liveID, state: current)
        }
    }

    // MARK: - Start eligibility

    /// The content state to START from, or `nil` when this ride must not open an
    /// Activity at all.
    private static func startState(
        for record: RideRequestRecord,
        vehicleName: String
    ) -> RideActivityAttributes.ContentState? {
        // A SCHEDULED ride is not a live ride, even once the owner has accepted it.
        // MYR-313 lets a reservation be accepted days ahead, so an Activity started
        // here would sit on the lock screen until Saturday. This mirrors
        // `SharedViewerScreen.reconciledPhase`, which gates the tracking sheet on
        // exactly `!hasSchedule` — the two must agree, or the rider gets a lock
        // screen about a ride the app itself is not tracking. (What a scheduled
        // ride does at DISPATCH time is MYR-313's handoff and is out of v1 scope.)
        guard record.input.schedule == nil else { return nil }

        switch record.status {
        case .accepted, .arrived, .enroute:
            // `arrived`/`enroute` start too, not just `accepted`. The app adopts a
            // rider's already-open ride on cold launch (MYR-230), so a rider who
            // force-quit mid-ride and reopened the app would otherwise get no
            // Activity for the rest of the trip.
            return contentState(for: record, vehicleName: vehicleName, previous: nil)

        case .pending:
            // "start at ACCEPTED — a pending request is the app's job" (MYR-172). A
            // request nobody has answered has nothing to count down and no car
            // assigned; the app's own pending pill is the right surface for it.
            return nil

        case .completed, .declined:
            // Already over. Starting an Activity in order to immediately end it
            // would put a card on the lock screen announcing something that
            // finished before it appeared.
            return nil
        }
    }

    /// The dismissal policy for a terminal status, or `nil` if the ride is still
    /// running.
    private static func dismissal(for status: RideRequestStatus) -> RideActivityDismissal? {
        switch status {
        case .completed: return .completedLinger
        case .declined: return .immediate
        case .pending, .accepted, .arrived, .enroute: return nil
        }
    }

    // MARK: - Content

    /// Build the content state the CLIENT would show for this record.
    ///
    /// The client is the BACKSTOP, not the author: server pushes are the truth
    /// (MYR-194 decision 2), and everything here is either locally certain (the
    /// status, from the rider's own service) or inherited from the last thing the
    /// server said (`vehicleName`, `eta`).
    static func contentState(
        for record: RideRequestRecord,
        vehicleName: String,
        previous: RideActivityAttributes.ContentState?
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: wireStatus(for: record.status),
            // NO LOCALLY COMPUTED ETA, EVER. The app knows a
            // `destination.minutes` estimate and could trivially turn it into an
            // instant — and that is exactly the "invented number" the schema
            // forbids ("never null, never zero, never a guess"). The contract's ETA
            // is the CAR'S OWN carried navigation ETA, which only the server has.
            // So a locally-started Activity opens with NO countdown and gains one
            // when the first push lands, seconds later. An honest blank beats a
            // plausible number that is not the car's.
            //
            // Carrying the PREVIOUS eta forward is not a guess: it is still the
            // last instant the car itself reported, and an instant does not decay.
            eta: previous?.eta,
            // Likewise the name: the wire's `vehicleName` is authoritative, so once
            // a push has supplied one it outranks whatever the client resolved from
            // its own fleet list.
            vehicleName: previous?.vehicleName.isEmpty == false
                ? (previous?.vehicleName ?? vehicleName)
                : vehicleName,
            destination: record.input.destination.label
        )
    }

    /// The app's own ride status → the contract's Live Activity status.
    ///
    /// Total and explicit. There is no `cancelled` arm because the app has no
    /// `cancelled` status to map FROM — the wire's `cancelled` is an erasure
    /// client-side, handled above by the `record == nil` branch.
    static func wireStatus(for status: RideRequestStatus) -> LiveActivityRideStatus {
        switch status {
        case .pending: return .requested
        case .accepted: return .accepted
        case .arrived: return .arrived
        case .enroute: return .enroute
        case .completed: return .completed
        case .declined: return .declined
        }
    }
}

extension RideActivityAttributes.ContentState {
    /// A copy with the status replaced, used to correct the last known frame into
    /// a final one when the ride was erased rather than transitioned.
    func with(status newStatus: LiveActivityRideStatus) -> Self {
        var copy = self
        copy.status = newStatus
        return copy
    }
}
