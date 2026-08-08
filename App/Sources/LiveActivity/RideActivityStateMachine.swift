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
    /// ─────────────────────────────────────────────────────────────────────────
    /// **⚠️ MYR-425 — THIS IS NO LONGER WHAT ENDS A COMPLETED RIDE.** The state
    /// machine does not reach for it any more; see `RideActivityCompletedEnd`. It
    /// survives as the DISMISSAL VOCABULARY (and as the DEBUG capture launcher's
    /// spelling of the same policy), because the five minutes is still the right
    /// number — it simply belongs to the server's held end now, which the client
    /// must not preempt.
    /// ─────────────────────────────────────────────────────────────────────────
    static let completedLinger = RideActivityDismissal.linger(5 * 60)
}

// MARK: - Who ends a COMPLETED ride's Activity (MYR-425)

/// **THE CLIENT DOES NOT END A COMPLETED RIDE. THE SERVER DOES.**
///
/// Prod-DB-proven, r20: every completed ride showed `go_live_activities.ended_at =
/// completed_at + ~0.5s` with `alerted_phase` stuck at **5**, including rides after
/// MYR-421's held-end deploy. The cause was one line of client policy that predates
/// the server owning completion (MYR-418/421) and that nobody retired: a record
/// folding to `.completed` returned `.end(dismissal: .completedLinger)`, so the app
/// took the Activity down the instant the ride finished.
///
/// A five-minute DISMISSAL DATE does not keep the card alive — it only governs how
/// long the LOCK-SCREEN frame lingers. An `.ended` Activity leaves the DYNAMIC
/// ISLAND ~1.4s later whatever the dismissal date says (measured platform truth),
/// and the coordinator's registration release tombstones the server's row, so the
/// server's completed announcement — the "You've arrived" alert that raises
/// `alerted_phase` to 6 and expands the island with the check — arrived at a row
/// with **zero recipients**, and its held end had nothing left to hold.
///
/// So `completed` is an UPDATE now (the final frame, composed through MYR-423's
/// merge rule so the server's `eta`/`progress`/`asOf` survive), the registration is
/// RETAINED, and the end belongs to the server's held end at completion + 5 min.
///
/// **`declined` / `cancelled` / expired are deliberately untouched.** They are
/// outside the design's six phases, there is no announcement coming for them, and
/// their prompt client-side end is the point rather than an accident.
enum RideActivityCompletedEnd {

    /// **THE LOCAL BACKSTOP'S HORIZON — the same five minutes, from the other end.**
    ///
    /// The server's held end (MYR-421) fires at `completed_at + 5 min`. This is the
    /// deadline after which the client stops waiting for it and takes the card down
    /// itself, `.immediate`, on the final frame.
    ///
    /// It is deliberately the SAME number rather than a padded one. A longer horizon
    /// would leave a visible gap on every ride whose push is simply late; an equal
    /// one means the backstop is only ever reached when the server's end genuinely
    /// did not arrive — a dead APNs token, an unregistered ride (MYR-415's whole
    /// class), or Live Activities pushed to a device that never came back online.
    static let backstop: TimeInterval = 5 * 60

    /// Has the wait for the server's end run out?
    ///
    /// **`nil` IS NEVER ELAPSED**, and that arm is load-bearing rather than
    /// defensive. `completedAt` is the SERVER's own instant (`RideRequest
    /// .completedAt`, MYR-414) and a ride whose completion this client learned about
    /// through a WS frame can legitimately hold none; the coordinator then supplies
    /// its own first-observation stamp. Reading an absent instant as "long ago"
    /// would end the card at the same moment the defect did.
    static func backstopHasElapsed(completedAt: Date?, now: Date) -> Bool {
        guard let completedAt else { return false }
        return now.timeIntervalSince(completedAt) >= backstop
    }

    /// Is this frame the LAST thing the card will say about this ride?
    ///
    /// Used for one thing: a final frame carries **no stale date**. Staleness means
    /// "this may have moved on without us", and a finished ride cannot — which
    /// `SystemRideActivityPresenter.end` has always known, and which the completed
    /// UPDATE path now has to know too. Without it the arrival card would grey
    /// itself out three minutes into the five-minute linger, i.e. before the
    /// server's own end arrives.
    ///
    /// Deliberately NOT `RideActivityLeg.of(status) == nil`: `completed` has a leg
    /// (`.dropoff`, so the rail renders full for the whole linger — MYR-398 v3) and
    /// is precisely the status this predicate exists for.
    static func isFinalFrame(_ status: LiveActivityRideStatus) -> Bool {
        switch status {
        case .completed, .declined, .cancelled, .reservationExpired: return true
        case .requested, .accepted, .arrived, .enroute: return false
        case .unrecognized: return false
        }
    }
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
    ///
    /// **MYR-425 makes that arm carry more weight than it used to.** A completed
    /// ride's Activity is now genuinely LIVE — `.active`, holding its registration,
    /// waiting for the server's announcement and its held end — rather than an
    /// `.ended` card living out a dismissal date. So this is what the launch and
    /// foreground reconcile ADOPTS instead of reaping, and the same pass is what
    /// drives the backstop: `handleLaunchOrForeground` finishes by re-asking
    /// `action`, which is where a five-minute-old completion is noticed.
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

    /// Does carrying this out leave the ALREADY-HELD card in place, still driven by
    /// this process?
    ///
    /// `.start` and `.restart` answer NO even though a card is on screen afterwards:
    /// it is a different ride's card. MYR-425's backstop arms off this rather than
    /// off a list of case names, so an action added later has to answer the question
    /// instead of falling outside it — MYR-395's `Opening.drawsWholeLine` lesson, one
    /// enum over.
    var continuesTheHeldCard: Bool {
        switch self {
        case .none, .update: return true
        case .start, .end, .restart: return false
        }
    }
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
    ///
    /// **⚠️ "MATCHING" IS NOT `==` — MYR-416.** For a ride this device SUBMITTED the
    /// snapshot carries the LOCAL draft UUID stamped into the Activity's immutable
    /// attributes, while `liveRide` on a relaunch carries the SERVER id the record
    /// was rebuilt from. Compared with `==` the rider's own live banner reads as a
    /// stranger's card: rule 3 reaps it and the start path puts a second one up
    /// beside it, which is this issue's own defect wearing MYR-405's fix. `identity`
    /// is the account's `local ↔ server` mapping and the comparison goes through it;
    /// with no mapping (`.unmapped`, the default) this is byte-for-byte the equality
    /// it replaces.
    static func reconcile(
        snapshots: [RideActivitySnapshot],
        liveRide: RideActivityLiveRide,
        identity: RideActivityRideIdentity = .unmapped
    ) -> RideActivityReconciliation {
        var plan = RideActivityReconciliation()

        plan.dismissed = snapshots
            .filter { $0.lifecycle == .dismissed }
            .map(\.rideID)

        // A read taken before the pipeline answered is not evidence about anything.
        guard liveRide != .unresolved else { return plan }

        for snapshot in snapshots where snapshot.lifecycle.isOnScreenAndOurs {
            let isTheLiveRide = liveRide.rideID.map {
                identity.namesTheSameRide(activityRideID: snapshot.rideID, as: $0)
            } ?? false
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
    ///
    /// `completedAt` (MYR-425) is when the ride COMPLETED, and it is consulted for
    /// exactly one question: has the wait for the server's held end run out? It is a
    /// parameter rather than a read off `record.completedAt` because the coordinator
    /// holds the better answer — the server's instant when the wire carried one, and
    /// this process's own first sighting of `completed` when it did not. Defaulted,
    /// so every call site that is not about the backstop is unchanged, and `nil`
    /// means "keep waiting" rather than "waited long enough".
    ///
    /// `identity` (MYR-416) is the account's `local ↔ server` id mapping, and it is
    /// consulted for the two comparisons in here that are about a RIDE rather than
    /// about a string: "is the card on screen this record's card" and "did the rider
    /// swipe this ride away". Both are asked across a process boundary — the card's
    /// id was stamped by the process that submitted the ride and the record's id is
    /// rebuilt from the wire by the one that relaunched — so `==` answers them
    /// wrongly for exactly the rides this device created. Defaulted to `.unmapped`,
    /// which is that same `==`.
    static func action(
        phase: RideActivityPhase,
        record: RideRequestRecord?,
        vehicleName: String,
        dismissedRideIDs: Set<String> = [],
        identity: RideActivityRideIdentity = .unmapped,
        completedAt: Date? = nil,
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
            //
            // MYR-416 — asked through `identity`, because a swipe is only ever
            // recorded under the ACTIVITY's id (the restore list and the lifecycle
            // stream are the only two things that can report one) and this record's
            // id is the SERVER's after a relaunch. With `==` the dismissal would be
            // invisible to the very launch that most wants to overrule it.
            guard !identity.anyIdentity(of: record.id, isIn: dismissedRideIDs) else { return .none }
            return .start(rideID: record.id, state: state)

        case .live(let liveID, let lastState):
            guard let record else {
                // ⚠️ **AN ERASURE OVER A COMPLETED CARD IS NOT A CANCELLATION —
                // MYR-425**, and this arm is newly reachable because of it. The
                // rider's slot is released when they dismiss the post-ride summary,
                // which nils `activeRequest`; before this issue the completed card
                // had already been ended by then, so a later `nil` found nothing. Now
                // the card is LIVE for five minutes and an unguarded erasure would
                // relabel the arrival **"Ride cancelled"** and take it down early —
                // the defect this issue exists to remove, wearing the summary's
                // Done button.
                //
                // The record going away says nothing about the lock screen here. The
                // card waits for the server's end exactly as it would have, and the
                // backstop still applies: the ride is over either way, so the deadline
                // is the only thing that can still end it locally.
                if lastState.status == .completed {
                    guard RideActivityCompletedEnd.backstopHasElapsed(completedAt: completedAt, now: now)
                    else { return .none }
                    return .end(rideID: liveID, state: lastState, dismissal: .immediate)
                }

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

            guard identity.namesTheSameRide(activityRideID: liveID, as: record.id) else {
                // A different ride is open than the one on the lock screen. End the
                // old one; start the new one if it is startable, otherwise just end.
                //
                // **⚠️ "DIFFERENT" IS A QUESTION ABOUT THE RIDE, NOT ABOUT TWO
                // STRINGS — MYR-416.** This guard used to read `record.id == liveID`,
                // and for a ride this device SUBMITTED the two ids differ while
                // naming the same ride the moment a relaunch rebuilds the record from
                // the wire (the card holds the local draft UUID, the record holds the
                // server's id). So the app ended its own live card and started a
                // second one in the same breath — a `.restart` that reads as correct
                // at every line of this branch and is wrong about which ride it is
                // looking at.
                //
                // **A CARD THAT ALREADY SAYS `completed` IS NOT CORRECTED TO
                // `cancelled` — MYR-425.** The correction exists because a card the
                // rider is replacing "is over and did not complete"; a completed card
                // did complete, and this branch is newly reachable for one now that
                // the five minutes are spent LIVE rather than `.ended` (an `.ended`
                // card was skipped by the reaper and never came through here). The
                // client's own rule is "clear banners … if new ride begins", which is
                // a statement about clearing, not about relabelling an arrival as a
                // cancellation on its way out.
                let endingState = lastState.status == .completed
                    ? lastState
                    : lastState.with(status: .cancelled)
                guard let next = startState(for: record, vehicleName: vehicleName, now: now),
                      !identity.anyIdentity(of: record.id, isIn: dismissedRideIDs) else {
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

            // ⚠️ **COMPLETED IS AN UPDATE, NOT AN END — MYR-425.** The line that used
            // to stand here read `if let dismissal = dismissal(for: record.status)`,
            // and for `completed` it returned `.completedLinger`, so the app ended
            // the Activity the instant the ride finished — killing the island in
            // ~1.4s and tombstoning the server's registration before the server's own
            // completed announcement (phase 6, the alert, the check) could be
            // delivered. See `RideActivityCompletedEnd`.
            //
            // The frame written here is the FINAL one and it goes through the same
            // `contentState` merge everything else does, which is what keeps MYR-423
            // intact: the local frame asserts `status: .completed` and the server's
            // last-delivered `eta` / `progress` / `asOf` are carried forward rather
            // than overwritten with nil.
            if record.status == .completed {
                guard RideActivityCompletedEnd.backstopHasElapsed(completedAt: completedAt, now: now)
                else {
                    // The ordinary path, and the one every real ride takes: say the
                    // final frame and STAY LIVE so the server can announce and then
                    // end. `.none` when the card already says it — the server's own
                    // completed push is a perfectly normal way for that to be true,
                    // and re-writing an identical frame would spend the rider's
                    // ActivityKit budget saying nothing.
                    return current == lastState ? .none : .update(rideID: liveID, state: current)
                }
                // THE BACKSTOP. Five minutes on and no server end has arrived, so
                // there is not one coming: take the card down on the final frame,
                // `.immediate`, because the linger this is the far end of has now
                // been served in full by the card standing there.
                return .end(rideID: liveID, state: current, dismissal: .immediate)
            }

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
        guard mayStartActivity(for: record, now: now) else { return nil }
        return contentState(for: record, vehicleName: vehicleName, previous: nil)
    }

    /// **MAY THIS RIDE OPEN A FRESH ACTIVITY RIGHT NOW?** — the eligibility half of
    /// `startState`, extracted by MYR-479 so the launch/foreground REVIVAL arm asks
    /// the identical question rather than a second reading of it.
    ///
    /// It is a real hazard rather than tidiness: `RideActivityAccountRide.resolve()`
    /// answers `.live` for a COMPLETED ride on purpose (MYR-425), so a revival arm
    /// keyed on the reconciler's own liveness would start an arrival card for a ride
    /// that finished — the exact thing the `.completed` case below refuses.
    static func mayStartActivity(for record: RideRequestRecord, now: Date = Date()) -> Bool {
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
        guard RideReservation.isLiveRide(record, now: now) else { return false }

        switch record.status {
        case .pending:
            // ⚠️ **THE ACTIVITY NOW STARTS AT REQUEST — MYR-398 v3, CLIENT-DIRECTED,
            // AND IT REVERSES MYR-172's "start at ACCEPTED".**
            //
            // That rule said "a pending request is the app's job": nothing to count
            // down, no car assigned, and the app's own pending pill is the right
            // surface. The v3 board answers it with a STATE rather than with an
            // argument — **Dispatch**, an idle rail and the waiting ring on the
            // island. It is Uber's first phase, and the whole point of it is that the
            // wait for a car is the part of the ride a rider is most likely to be
            // staring at a locked phone through. (MYR-417 replaced the board's own
            // copy for this state: there is no matching in this product, so the card
            // reads "Ride requested from {car}" over the same vehicle descriptor the
            // rest of the pickup leg carries.)
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
            return true

        case .accepted, .arrived, .enroute:
            // `arrived`/`enroute` start too, not just `accepted`. The app adopts a
            // rider's already-open ride on cold launch (MYR-230), so a rider who
            // force-quit mid-ride and reopened the app would otherwise get no
            // Activity for the rest of the trip.
            //
            // MYR-479 — these two are also exactly the statuses the revival arm is
            // named for: a ride observed at `arrived`/`enroute` with no card at all.
            return true

        case .completed, .declined:
            // Already over. Starting an Activity in order to immediately end it
            // would put a card on the lock screen announcing something that
            // finished before it appeared.
            return false
        }
    }

    /// The dismissal policy for a status the CLIENT ends on, or `nil` when the
    /// client does not end this ride at all.
    ///
    /// **`completed` RETURNS `nil` NOW — MYR-425**, and that is the fix rather than a
    /// tidy-up: it is not "no policy", it is "not the client's call". A completed
    /// ride is ended by the SERVER's held end (+5 min) and, failing that, by the
    /// backstop in `action`, which chooses `.immediate` on its own rather than
    /// through this table. Leaving `.completedLinger` here would be one call site
    /// away from putting the defect straight back.
    ///
    /// `declined` is byte-identical to what it always was, deliberately: it is
    /// outside the design's six phases, no announcement is coming for it, and the
    /// prompt end is the point. Cancellation and expiry never reach this function —
    /// they are ERASURES (the record disappears) and are ended by the `record == nil`
    /// branch above, also unchanged.
    private static func dismissal(for status: RideRequestStatus) -> RideActivityDismissal? {
        switch status {
        case .declined: return .immediate
        case .completed, .pending, .accepted, .arrived, .enroute: return nil
        }
    }

    // MARK: - Content

    /// Build the content state the CLIENT would show for this record.
    ///
    /// The client is the BACKSTOP, not the author: server pushes are the truth
    /// (MYR-194 decision 2), and everything here is either locally certain (the
    /// status, from the rider's own service) or inherited from the last thing the
    /// server said (`vehicleName`, `eta`, `progress`, `asOf`).
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// **⚠️ `previous` MUST BE THE FRAME THAT IS ON THE ACTIVITY, NOT THE LAST ONE
    /// THIS APP WROTE — MYR-423, and the whole of it.**
    /// ─────────────────────────────────────────────────────────────────────────
    ///
    /// This function was always written to hold the server's fields ("carrying the
    /// PREVIOUS eta forward is not a guess"), and it always did exactly that — over
    /// an input that could never contain one. The coordinator passed
    /// `RideActivityPhase.live`'s state, i.e. this process's memory of its OWN last
    /// composition, and a locally-composed frame has no `eta`, no `progress` and no
    /// `asOf` by construction. So the carry-forward inherited `nil` from `nil`, and
    /// the resulting frame **overwrote the server's pushed values on the card**: the
    /// client's "Pick up in 12 min" reverting to "Pickup soon / Last updated 11:19
    /// AM" the moment an unlock foregrounded the app.
    ///
    /// A promise about holding a field is only as good as the thing being held. The
    /// caller now reads `RideActivityPresenting.deliveredContentState(rideID:)`, so
    /// `previous` is the state ActivityKit is actually rendering — push included.
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
            //
            // BUT IT IS LEG-SCOPED, and MYR-423 is what makes that load-bearing:
            // before it, `previous?.eta` was always nil and the leg question could
            // never arise. See `RideActivityHeldETA.held`.
            eta: RideActivityHeldETA.held(
                currentLeg: RideActivityLeg.of(wireStatus(for: record.status)),
                previous: previous?.eta,
                previousLeg: previous.map { RideActivityLeg.of($0.status) } ?? nil
            ),
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
            ),
            // `asOf` IS HELD ACROSS EVERYTHING, INCLUDING A LEG FLIP — it is the only
            // one of the three server fields that is not leg-scoped. It states when
            // the SERVER last learned something about this ride, and the app
            // recomposing a frame is not the server learning anything, so nothing
            // about a local update makes the last-learned instant less true.
            //
            // The alternative — leaving it nil, which is what every local frame did
            // before MYR-423 — is the one reading the contract forbids: absence means
            // "this server does not say", so a backstop frame that dropped it made an
            // up-to-date card render the wordless "Waiting for an update", and made a
            // GENUINELY stale one stop admitting it. Carrying it forward is also what
            // lets `RideActivityFreshness.hasGoneQuiet` keep working across a local
            // recomposition: a four-minute-old instant still ages out on schedule.
            asOf: previous?.asOf
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

// MARK: - Holding the server's ETA (MYR-423)

/// The ETA a newly-composed LOCAL frame may carry, given the ETA already on the
/// Activity.
///
/// It is `RideActivityProgress.held`'s sibling and deliberately reads like it — the
/// LEG IS THE RESET KEY in both, because both fields describe the leg in progress
/// and neither survives it. The reason is sharper for the ETA, though, and it is
/// not merely staleness: **the two legs render this one field in two different
/// GRAMMARS.** `RideActivityCard.figure` reads a pickup ETA as a countdown
/// ("8 min") and a dropoff ETA as a clock time ("3:42 PM"), and
/// `RideActivityCopy.showsFigure` is true for `accepted` AND `enroute`. So a pickup
/// arrival instant that survived the flip would not just linger — it would be
/// re-read as the moment the rider is DROPPED OFF, and the card would state it with
/// full confidence.
///
/// There is no `current` parameter, and its absence is the standing rule made
/// structural: **the client never computes an ETA, ever.** The contract's ETA is the
/// car's own carried navigation ETA and only the server has it, so the only two
/// answers this function can give are "the one the server last delivered for THIS
/// leg" and "none".
enum RideActivityHeldETA {
    static func held(
        currentLeg: RideActivityLeg?,
        previous: Int?,
        previousLeg: RideActivityLeg?
    ) -> Int? {
        // A ride with no leg at all — declined, cancelled, lapsed, or a status this
        // build has never heard of — is not arriving anywhere, so it holds no
        // arrival instant. That covers the `nil == nil` case the equality below
        // would otherwise wave through.
        guard let currentLeg else { return nil }
        guard currentLeg == previousLeg else { return nil }
        return previous
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
    /// **THE ETA GOES WITH THE LEG TOO — MYR-423.** Same rule, same reason, and it
    /// only became reachable when the last-delivered frame started carrying a real
    /// ETA: before that this copy was made from a frame whose `eta` was always nil,
    /// so an ending card could not have carried one. `cancelled`/`declined`/
    /// `reservation_expired` have no leg, so they hold no arrival instant, and the
    /// three-word promise of §7.21.3's degradation table — no track, no figure, no
    /// claim — is kept by one predicate instead of two.
    func with(status newStatus: LiveActivityRideStatus) -> Self {
        var copy = self
        copy.progress = RideActivityProgress.held(
            current: nil,
            currentLeg: RideActivityLeg.of(newStatus),
            previous: progress,
            previousLeg: RideActivityLeg.of(status)
        )
        copy.eta = RideActivityHeldETA.held(
            currentLeg: RideActivityLeg.of(newStatus),
            previous: eta,
            previousLeg: RideActivityLeg.of(status)
        )
        copy.status = newStatus
        return copy
    }
}
