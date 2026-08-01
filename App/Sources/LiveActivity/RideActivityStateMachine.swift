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

    /// **FIVE MINUTES** — a client decision on 2026-07-31 that SUPERSEDES MYR-194's
    /// "~15 min linger for completed" (MYR-405): *"when ride is complete we should
    /// clear banners after 5min or if new ride begins or user dismisses."*
    ///
    /// This is a CLIENT-SIDE END POLICY and has nothing to do with the server's
    /// APNs expiration, whose 24h floor came up in the MYR-398 review. That number
    /// governs how long APNs will keep TRYING to deliver a push; this one governs
    /// how long the rider's own phone keeps a finished ride's card on the lock
    /// screen. Conflating them would either throw away pushes the server still
    /// wants delivered or leave yesterday's arrival on this morning's lock screen.
    ///
    /// The clock starts when the ending frame is written (`uiPolicy` resolves
    /// `.after(now + interval)`), i.e. at the moment the completed card renders —
    /// which is what the client asked for.
    static let completedLinger = RideActivityDismissal.linger(5 * 60)
}

/// What the app knows about the ACCOUNT's own live ride at reconcile time
/// (MYR-405).
///
/// `.unresolved` is a real third arm rather than a missing value, and leaving it
/// out is how the reaper would have eaten the card it exists to protect. On a cold
/// launch the rider's own ride list (§7.8) has not answered yet, so a `nil` record
/// means "we have not asked", NOT "this rider has no ride" — and reaping on that
/// reading would take a live ride's Activity off the lock screen every time the
/// phone launched with no signal. It is MYR-326's "loading ≠ unavailable" and
/// MYR-343's "three situations told apart by one boolean", pointed at the lock
/// screen.
enum RideActivityLiveRide: Equatable {
    /// The ride pipeline has not answered yet. Nothing may be reaped and nothing
    /// may be adopted on this evidence.
    case unresolved
    /// The pipeline answered: this account holds no live ride at all. Every
    /// Activity still on screen is therefore an orphan.
    case none
    /// The pipeline answered: this ride is live right now.
    case live(rideID: String)

    var rideID: String? {
        if case .live(let id) = self { return id }
        return nil
    }
}

/// The account's own ride as the app can currently state it (MYR-405).
///
/// Two fields because `record == nil` is ambiguous and the ambiguity is what makes
/// the reaper dangerous. `isResolved` is the rider pipeline's answer to "have I
/// established what this account is doing?" — false during the cold-launch window
/// and after a §7.8 read that FAILED, true once a list has answered or a record is
/// held. See `RideRequestService.hasResolvedActiveRide`.
struct RideActivityAccountRide: Equatable {
    var record: RideRequestRecord?
    var isResolved: Bool

    /// The resolved, dormancy-aware answer the reconciler consumes.
    ///
    /// Dormancy is consulted through `RideReservation.isLiveRide` — the SAME
    /// predicate `startState` uses — so "which ride may hold a card" is one rule.
    /// A reservation accepted for Saturday resolves to `.none` today, and an
    /// Activity sitting on the lock screen for it is an orphan by that rule rather
    /// than by a second copy of it.
    ///
    /// A `completed` ride resolves to `.live`, deliberately: it is still the ride
    /// this Activity is ABOUT, and reaping it here would take the arrival card down
    /// with `.immediate` instead of letting the state machine end it on MYR-405's
    /// five-minute linger. The reconciler establishes WHOSE card it is; the state
    /// machine decides how it ends.
    func resolve(now: Date = Date()) -> RideActivityLiveRide {
        guard isResolved else { return .unresolved }
        guard let record, RideReservation.isLiveRide(record, now: now) else { return .none }
        return .live(rideID: record.id)
    }
}

/// What to do about the Activities ActivityKit restored into this process
/// (MYR-405) — the pure half of "adopt, never duplicate" and of orphan reaping.
struct RideActivityReconciliation: Equatable {
    /// Rides whose Activity must come off the lock screen NOW, in the order they
    /// were found.
    var reap: [String] = []

    /// The restored Activity to TAKE OVER rather than duplicate. When this is
    /// non-nil the start path must not call `Activity.request` at all.
    var adopt: String?

    /// Rides whose Activity the RIDER dismissed. Recorded, never resurrected.
    var dismissed: [String] = []

    /// Is this reap a SECOND card for the ride being kept, rather than an orphan
    /// of some other ride?
    ///
    /// Two things hang off it, and both go wrong quietly if it is dropped:
    ///
    ///  • **No §7.21 delete.** The registration is keyed on `(ride, rider)`, so a
    ///    delete issued for a duplicate would remove the row belonging to the banner
    ///    just adopted — re-creating the starvation this issue exists to remove,
    ///    from inside the fix.
    ///  • **No local teardown.** The coordinator's own `phase` names the ride, not
    ///    the Activity, so clearing it here would forget the card it just adopted
    ///    and the next tick would adopt it all over again.
    func isDuplicateOfAdopted(_ rideID: String) -> Bool { rideID == adopt }
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

    // MARK: - Reconciling what the SYSTEM restored (MYR-405)

    /// Decide what to do about every Activity ActivityKit handed back, given what
    /// the account is actually doing.
    ///
    /// This is the whole of semantics 1, 2, 4 and half of 5 as one pure function
    /// over a list — which is the point. The client's bug is not that any single
    /// rule was wrong; it is that the start path asked ONE question ("do I hold an
    /// Activity in this process?") when the lock screen can hold several this
    /// process never started.
    ///
    /// Three rules, and the two skips matter as much as the reap:
    ///
    ///  1. **`.ended` is skipped.** It is already leaving on a dismissal policy —
    ///     including MYR-405's own five-minute completed linger. Re-ending it with
    ///     `.immediate` would take a just-completed ride's card away seconds after
    ///     it appeared, i.e. this issue's own fix cancelling its own fix.
    ///  2. **`.dismissed` is skipped and REMEMBERED.** Nothing is on screen to
    ///     reap, and the rider's swipe is a decision (semantic 5).
    ///  3. Of what is left, the one matching the live ride is ADOPTED and every
    ///     other one is REAPED — terminal, unknown, another account's leftovers, or
    ///     a duplicate of the very ride being adopted. `.unresolved` reaps and
    ///     adopts nothing at all.
    static func reconcile(
        snapshots: [RideActivitySnapshot],
        liveRide: RideActivityLiveRide
    ) -> RideActivityReconciliation {
        var plan = RideActivityReconciliation()

        plan.dismissed = snapshots
            .filter { $0.lifecycle == .dismissed }
            .map(\.rideID)

        // A read taken before the pipeline answered is not evidence about anything.
        guard liveRide != .unresolved else { return plan }

        for snapshot in snapshots where snapshot.lifecycle.isOnScreenAndOurs {
            let isTheLiveRide = snapshot.rideID == liveRide.rideID
            // The FIRST on-screen Activity for the live ride is the one kept. Any
            // further one is a duplicate of it — the client's exact screenshot —
            // and is reaped like any other orphan, which is what heals an install
            // that is already in the broken state.
            if isTheLiveRide, plan.adopt == nil, !plan.dismissed.contains(snapshot.rideID) {
                plan.adopt = snapshot.rideID
            } else {
                plan.reap.append(snapshot.rideID)
            }
        }
        return plan
    }

    // MARK: - The per-tick decision

    /// Decide what to do, given what we last did and what the rider's ride looks
    /// like now.
    ///
    /// `record` is the rider's `activeRequest` — `nil` meaning the rider holds no
    /// open ride at all, which is a genuine and load-bearing input rather than a
    /// missing one.
    /// `now` is injected for the same reason every other MYR-376/377 gate takes
    /// one: reservation dormancy is TIME-BOUNDED, so "may this ride open an
    /// Activity" is a question about the clock as well as the record. Defaulted, so
    /// every existing call site is unchanged.
    ///
    /// `dismissedRideIDs` (MYR-405, semantic 5) is the set of rides whose Activity
    /// the RIDER swiped away. It is an INPUT rather than a phase case deliberately:
    /// a dismissal outlives the phase (the coordinator drops to `.idle` the moment
    /// the system reports one), it can arrive from the restore list for a ride this
    /// process never presented, and more than one ride can be in it. Modelling it
    /// as one more `.dismissed` phase would have made all three of those wrong.
    static func action(
        phase: RideActivityPhase,
        record: RideRequestRecord?,
        vehicleName: String,
        dismissedRideIDs: Set<String> = [],
        now: Date = Date()
    ) -> RideActivityAction {
        switch phase {
        case .idle:
            guard let record, let state = startState(for: record, vehicleName: vehicleName, now: now) else {
                return .none
            }
            // NEVER RESURRECT A DISMISSED CARD. The rider swiped this ride's
            // Activity away while the ride was still running; starting a second one
            // for the same ride — on the next status change, on the next foreground,
            // on the next launch — would overrule them repeatedly and look like the
            // dismissal never worked. A DIFFERENT ride is a different decision and
            // starts normally, which is the client's "or if new ride begins".
            guard !dismissedRideIDs.contains(record.id) else { return .none }
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
                guard let next = startState(for: record, vehicleName: vehicleName, now: now),
                      !dismissedRideIDs.contains(record.id) else {
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
        vehicleName: String,
        now: Date = Date()
    ) -> RideActivityAttributes.ContentState? {
        // A DORMANT reservation is not a live ride, even once the owner has
        // accepted it. MYR-313 lets a reservation be accepted days ahead, so an
        // Activity started at accept time would sit on the lock screen until
        // Saturday counting down to nothing.
        //
        // MYR-377 — but the gate is DORMANCY, not "carries a schedule", which is
        // what MYR-172 shipped. Once the reservation sweeper dispatches it the ride
        // is live in every way that matters — the car has the navigation, the rider
        // has a tracking map and a "Start ride" button — and a lock-screen card is
        // exactly as useful as it is for an instant ride. `go_live_activities` had
        // ZERO rows in production, and this line is why: the client's only rides
        // were reservations. §7.21 registers a token for any non-terminal ride
        // including a reservation, so there was never a server-side gap to work
        // around.
        //
        // This still mirrors `SharedViewerScreen.reconciledPhase` — the two must
        // agree, or the rider gets a lock screen about a ride the app itself is not
        // tracking — and both now read the same `RideReservation` predicate rather
        // than each spelling the rule out.
        guard RideReservation.isLiveRide(record, now: now) else { return nil }

        switch record.status {
        case .pending:
            // ⚠️ **THE ACTIVITY NOW STARTS AT REQUEST — MYR-398 v3, CLIENT-DIRECTED,
            // AND IT REVERSES MYR-172's "start at ACCEPTED".**
            //
            // That rule said "a pending request is the app's job": nothing to count
            // down, no car assigned, and the app's own pending pill is the right
            // surface. The v3 board answers it with a STATE rather than with an
            // argument — **Dispatch**, "Finding your ride" / "Matching you with a
            // ride", an idle rail and the mark alone on the island. It is Uber's
            // first phase, and the whole point of it is that the wait for a car is
            // the part of the ride a rider is most likely to be staring at a locked
            // phone through.
            //
            // Nothing else about the card changes to accommodate it, which is the
            // reason it is cheap: the footprint is fixed in every state, the rail's
            // idle variant already existed for no-telemetry, and no ETA is a word
            // rather than a gap. It also needs no server work — §7.21 registers a
            // token for any NON-TERMINAL ride, `requested` included.
            //
            // **A SCHEDULED RIDE STILL STARTS NOTHING**, and that falls out of the
            // dormancy guard above rather than out of this switch: a `pending`
            // reservation is dormant by `RideReservation.isDormant`'s first arm, at
            // every moment before it is dispatched, so it never reaches here. Only an
            // INSTANT request does — which is exactly the client's "instant rides
            // start at request", enforced by the predicate both pipelines already
            // share rather than by a second reading of `scheduledFor`.
            return contentState(for: record, vehicleName: vehicleName, previous: nil)

        case .accepted, .arrived, .enroute:
            // `arrived`/`enroute` start too, not just `accepted`. The app adopts a
            // rider's already-open ride on cold launch (MYR-230), so a rider who
            // force-quit mid-ride and reopened the app would otherwise get no
            // Activity for the rest of the trip.
            return contentState(for: record, vehicleName: vehicleName, previous: nil)

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
            destination: record.input.destination.label,
            // NO LOCALLY COMPUTED PROGRESS, EVER — the same rule as `eta`, and
            // sharper. The app holds `record.trackProgress`, a simulated 0…1 over
            // the WHOLE trip (both legs), and turning it into this field would be
            // the "wrong one renders a lie" half of §7.21.3: a fraction of the
            // whole journey rendered as a fraction of the current leg, drawn
            // confidently, with nothing on the card admitting it was invented.
            //
            // So the client only ever CARRIES FORWARD what the car itself reported,
            // and `RideActivityProgress.held` is where the leg reset and the
            // monotone floor live. Across a leg flip nothing survives — leg one
            // ends at exactly 1 and leg two opens near 0.
            progress: RideActivityProgress.held(
                current: nil,
                currentLeg: RideActivityLeg.of(wireStatus(for: record.status)),
                previous: previous?.progress,
                previousLeg: previous.map { RideActivityLeg.of($0.status) } ?? nil
            )
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
    ///
    /// THE PROGRESS GOES WITH THE LEG, and that is the whole reason this is not a
    /// one-line mutation. `cancelled` / `declined` / `reservation_expired` have no
    /// leg at all, and §7.21.3's degradation table promises "no track on the ending
    /// card" for exactly those three — a car that was 62% of the way to a rider who
    /// then cancelled is not 62% of the way to anything. Carrying the fraction
    /// through would leave a confident gold arrow mid-rail under the word
    /// "Cancelled", which is MYR-172's own "reads as a ride still in progress"
    /// objection wearing a picture instead of a sentence.
    func with(status newStatus: LiveActivityRideStatus) -> Self {
        var copy = self
        copy.progress = RideActivityProgress.held(
            current: nil,
            currentLeg: RideActivityLeg.of(newStatus),
            previous: progress,
            previousLeg: RideActivityLeg.of(status)
        )
        copy.status = newStatus
        return copy
    }
}
