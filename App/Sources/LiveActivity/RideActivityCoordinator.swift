import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import OSLog

// MARK: - The performer (MYR-172)
//
// Owns the side effects and none of the decisions: every "should we?" comes from
// `RideActivityStateMachine.action`, and this type's whole job is to carry that
// out and to keep the server's copy of the push token current.
//
// Modelled on `PushRegistrationCoordinator` (MYR-186) down to the composition
// rule: in simulated mode it is built INERT (`endpoint: nil`, `isLive: false`)
// rather than optional, so no call site has to remember to check — which is what
// keeps every simulated and DEBUG-scene capture byte-identical.

@MainActor
@Observable
final class RideActivityCoordinator {
    private let presenter: any RideActivityPresenting
    private let endpoint: (any RideActivityTokenEndpoint)?
    private let sandbox: Bool
    private let isLive: Bool

    /// Resolves the rider's current vehicle nickname for the LOCAL start frame
    /// only. Every subsequent frame prefers the wire's `vehicleName`, which is
    /// authoritative — see `RideActivityStateMachine.contentState`.
    private let vehicleName: @MainActor () -> String

    /// Resolves the car's IDENTIFICATION — plate, colour, model, year, trim — for
    /// the pickup leg's subline (MYR-398 v3).
    ///
    /// Read ONCE, at `Activity.request`, because it is a STATIC attribute: a ride's
    /// vehicle is fixed at accept time and the server pushes nothing about it. That
    /// is also its one accepted cost — a plate the owner edits mid-ride reaches the
    /// rider's `GET /api/vehicles` but not an Activity already up (MYR-286: there is
    /// no WS delta for the plate either).
    private let vehicle: @MainActor () -> RideActivityVehicle?

    /// **THE SERVER'S ID FOR THE RIDER'S OWN RIDE — MYR-415, and the whole fix.**
    ///
    /// `RideRequestRecord.id` is NOT a server id for the ride this device
    /// submitted. `LiveRideRequestService.submit` mints an OPTIMISTIC record with a
    /// client `UUID` (MYR-218) and `fold` copies that record forward verbatim (`var
    /// current = held`, and `id` is a `let`), so the local UUID is the record's id
    /// for the whole life of the ride while the server's id lives only in
    /// `riderServerRideID`. Every §7.8 write in the app already knows this — accept,
    /// decline and cancel all post on the server id — and `RideRequestService
    /// .activeServerRideID` is the accessor MYR-186 added for exactly this reason.
    ///
    /// The Live Activity registration was the one place that used `record.id`
    /// directly, so `POST /api/ride-requests/{client-uuid}/activity-token` addressed
    /// a ride the server has never heard of. That is why `go_live_activities` was
    /// EMPTY in production while `go_push_devices` — which is ACCOUNT-scoped and
    /// carries no ride id at all — stayed healthy.
    ///
    /// A closure rather than a value because the id arrives LATER than the Activity
    /// does: MYR-398 v3 starts the card at REQUEST, which is before the create POST
    /// has even fired (MYR-218's send grace window), so at `Activity.request` time
    /// there is legitimately no server id yet. See `flushPendingRegistration`.
    private let serverRideID: @MainActor () -> String?

    /// **THE `local ↔ server` MAPPING, AND IT HAS TO OUTLIVE THE PROCESS** (MYR-416).
    ///
    /// MYR-415 fixed the half of the two-id split that talks to the SERVER. This is
    /// the half that talks to the LOCK SCREEN: `RideActivityAttributes.rideID` is
    /// stamped at `Activity.request` — before the create POST has fired — and is
    /// immutable for the card's life, so a rider-submitted ride's card carries the
    /// LOCAL draft UUID for ever while a relaunched process rebuilds the record from
    /// the wire and holds only the SERVER's id.
    ///
    /// An in-memory map cannot close that: the only process that ever holds both ids
    /// is the one that submitted the ride, and it is dead by the time adoption is
    /// asked the question. So the pair is persisted, exactly as MYR-396's
    /// `OwnerDispatchPointer` persists the owner's dispatch id, and for the same
    /// reason — *it is a fact this device already knew and threw away when the
    /// process died.*
    private let identities: RideActivityRideIDStoring

    /// The mapping as the pure layer consumes it. Cached because nothing outside this
    /// process can write it while this process runs; refreshed only by `noteIdentity`.
    private var identity: RideActivityRideIdentity

    private(set) var phase: RideActivityPhase = .idle

    /// The token last successfully registered, and the SERVER ride id it was
    /// registered against. BOTH halves matter: the same token may never be
    /// re-registered for the same ride (a wasted round trip on every foreground),
    /// but it absolutely must be re-registered for a DIFFERENT ride, since the
    /// server keys the registration on `(ride, rider)`.
    private var registered: (token: String, serverRideID: String)?

    /// A token ActivityKit has issued that is NOT yet confirmed registered — either
    /// because no server id existed when it arrived, or because the POST failed.
    ///
    /// This is MYR-186's `pendingToken` with the same policy and for the same
    /// reason: that coordinator persists a token whose PUT failed and retries it on
    /// the next foreground, which is precisely why `go_push_devices` recovers from a
    /// bad minute and this one did not. Before MYR-415 a failed registration was
    /// dropped on the floor by `catch { return }` — no retry, no log, and a token
    /// that does not rotate is never offered again.
    private var pendingToken: Data?

    private let log = Logger(subsystem: "app.myrobotaxi.ios", category: "liveactivity")

    private var tokenTask: Task<Void, Never>?

    /// MYR-405 semantic 5 — rides whose Activity the RIDER swiped away. Seeded from
    /// ActivityKit's own restore list as well as from the live lifecycle stream, so
    /// a dismissal survives the process it happened in.
    private var dismissedRideIDs: Set<String> = []

    /// **CARDS THIS APP TOOK DOWN ITSELF** (MYR-479), so the finality set cannot be
    /// fed by them.
    ///
    /// `ActivityState.dismissed` does NOT mean "the rider swiped": Apple's own
    /// wording is that the Activity is no longer visible *"because a person **or the
    /// system** removed it"*, and every `.immediate` end this coordinator issues —
    /// the §7.21 409 arm, `performEnd`, `reap` — asks the system to remove it. The
    /// LIFECYCLE STREAM is safe (each of those cancels `stateTask` before it ends
    /// anything, so a self-end is never observed as a swipe), but the RESTORE LIST
    /// carries no provenance at all: `reconcile` reads a `.dismissed` row and cannot
    /// tell the rider's decision from our own teardown. Folding that into
    /// `dismissedRideIDs` bars the ride from ever getting a card again — which is
    /// precisely what would defeat this issue's revival arm for the ride it was
    /// written for, the one the client ended on a `409 reservation_expired`.
    ///
    /// It is IN-MEMORY and scoped to this process, and that is a deliberate limit
    /// rather than an oversight — see the PR's "what I could not close" note. It is
    /// also behaviour-neutral if the platform never reports a self-end as
    /// `.dismissed`: the set is then simply never consulted.
    ///
    /// **A ride leaves the set the moment a fresh card is started or adopted for
    /// it**, so the shield only ever covers the window between our teardown and the
    /// next card. Without that, a rider who swiped the REVIVED card would find their
    /// swipe stopped surviving a relaunch.
    private var endedByAppRideIDs: Set<String> = []

    /// **WHETHER THE SYSTEM WILL ALLOW A LIVE ACTIVITY AT ALL** (MYR-479).
    ///
    /// `ActivityAuthorizationInfo().areActivitiesEnabled` has been readable through
    /// the presenter since MYR-172 and was surfaced NOWHERE: a rider with Live
    /// Activities switched off got a silent `false` out of `presenter.start`, an
    /// unchanged `.idle` phase, and no way — in the app, in a log, or in Settings —
    /// to find out why the ride never reached their lock screen. MYR-461's whole
    /// triage turned on a rider's permission state that "has not been verified".
    ///
    /// Published as observable state and refreshed on every launch and foreground,
    /// which is exactly when a rider comes back from iOS Settings. `.unknown` on the
    /// simulated path, where the system is never asked and nothing must render.
    private(set) var authorization: LiveActivityAuthorizationState = .unknown

    private var stateTask: Task<Void, Never>?

    /// Whether ActivityKit's asynchronous restore has been waited out in this
    /// process. See `settledInputs`.
    private var restoreSettled = false

    /// Injected only so tests do not pay the restore budget in real time. Production
    /// passes nothing.
    private let sleep: @Sendable (Duration) async -> Void

    // MARK: - MYR-425: waiting for the server's end

    /// When the ride this process holds a card for COMPLETED, as best this app can
    /// say: the server's own `completedAt` when the wire carried one, and otherwise
    /// this process's first sighting of the `completed` status.
    ///
    /// The fallback is not a nicety — a completion that reaches the client as a WS
    /// `ride_status_changed` frame carries no instant at all, and a backstop with no
    /// clock is a backstop that never fires. The cost of the fallback is stated
    /// honestly: a relaunch re-stamps it, so a card that outlived the process gets
    /// its five minutes measured from the relaunch rather than from the drop-off.
    ///
    /// **It is about the CARD, not about the record**, and that distinction is
    /// load-bearing: the rider's slot is released the moment they dismiss the
    /// post-ride summary, so for most of the five minutes there is no record left to
    /// re-derive this from.
    private var completionInstant: Date?

    /// The one deferred WAKE-UP for the backstop, and deliberately nothing more.
    ///
    /// It contains no policy: it sleeps to the deadline and then re-asks
    /// `handleRideChange`, so the DECISION is the same pure `RideActivityStateMachine
    /// .action` call every other tick makes. Without it the backstop would only be
    /// reached at the next launch or foreground — which is the common case, since a
    /// completed card matters most on a locked phone, but not the only one.
    private var backstopTask: Task<Void, Never>?

    /// How the backstop waits. Injected for the same reason `sleep` is, and kept
    /// SEPARATE from it on purpose: the restore budget is skipped wholesale in tests
    /// (`sleep: { _ in }`), and a backstop sharing that closure would fire instantly
    /// in every test that ever completes a ride.
    private let backstopWait: @Sendable (TimeInterval) async -> Void

    init(
        presenter: any RideActivityPresenting,
        endpoint: (any RideActivityTokenEndpoint)?,
        isLive: Bool,
        sandbox: Bool = PushEnvironment.isSandbox,
        vehicleName: @escaping @MainActor () -> String = { "" },
        vehicle: @escaping @MainActor () -> RideActivityVehicle? = { nil },
        serverRideID: @escaping @MainActor () -> String? = { nil },
        identities: RideActivityRideIDStoring = UserDefaultsRideActivityRideIDs(),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        backstopWait: @escaping @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(for: .seconds($0))
        }
    ) {
        self.presenter = presenter
        self.endpoint = endpoint
        self.isLive = isLive
        self.sandbox = sandbox
        self.vehicleName = vehicleName
        self.vehicle = vehicle
        self.serverRideID = serverRideID
        self.identities = identities
        self.identity = identities.identity()
        self.sleep = sleep
        self.backstopWait = backstopWait
    }

    // MARK: - The one entry point

    /// Called whenever the rider's active ride changes — including to `nil`.
    ///
    /// `nil` is a real input, not a missing one: a remotely CANCELLED ride is
    /// erased rather than transitioned, so disappearance is the only signal the
    /// client gets that the ride is over. Treating it as "nothing to do" would
    /// leave a card on the lock screen for a ride that no longer exists.
    func handleRideChange(_ record: RideRequestRecord?) async {
        // Simulated mode never touches ActivityKit. The fixture ride would put a
        // real card on a real lock screen describing a ride that is not happening.
        guard isLive else { return }

        // MYR-415 — every tick is a retry opportunity for a registration that could
        // not be made yet. This is MYR-186's "try again next foreground" policy,
        // reached through the one entry point rather than a second schedule:
        // `handleLaunchOrForeground` funnels into this method too, so a launch, a
        // foreground and a status change all re-attempt without three call sites.
        await flushPendingRegistration()

        // MYR-425 — IF SOMEBODY ELSE ALREADY ENDED THE CARD, STOP DRIVING IT. The
        // server's held end is the normal way a completed ride's Activity goes away
        // now, and it happens entirely outside this process.
        standDownIfTheSystemEndedTheHeldCard()

        // MYR-423 — RE-SEAT THE REMEMBERED FRAME ON THE REAL ONE BEFORE DECIDING
        // ANYTHING. See `reseatPhaseOnDeliveredState`.
        reseatPhaseOnDeliveredState()

        // MYR-416 — the two ids are both knowable HERE, in the process that submitted
        // the ride, and nowhere else. Written before the decision so the very tick
        // that learns the server id can already reason with it.
        noteIdentity()

        let completedAt = noteCompletion(of: record)

        let action = RideActivityStateMachine.action(
            phase: phase,
            record: record,
            vehicleName: vehicleName(),
            dismissedRideIDs: dismissedRideIDs,
            identity: identity,
            completedAt: completedAt
        )

        armBackstopIfStillWaiting(action: action, record: record, completedAt: completedAt)

        switch action {
        case .none:
            break

        case .start(let rideID, let state):
            await performStart(rideID: rideID, state: state, record: record)

        case .update(let rideID, let state):
            // MYR-425 — A FINAL FRAME CARRIES NO STALE DATE. `completed` reaches this
            // arm now, and it is the one status whose card must not grey itself out
            // while it waits: the server's held end is five minutes away and
            // `RideActivityStaleness.window` is three, so a completed card written
            // with the default stale date would start admitting it might be out of
            // date about a ride that is over. `SystemRideActivityPresenter.end` has
            // always passed `nil` here for exactly this reason; the update path
            // simply had no terminal status to worry about until now.
            await presenter.update(
                state: state,
                staleDate: RideActivityCompletedEnd.isFinalFrame(state.status)
                    ? nil
                    : RideActivityStaleness.date()
            )
            phase = .live(rideID: rideID, state: state)

        case .end(let rideID, let state, let dismissal):
            await performEnd(rideID: rideID, state: state, dismissal: dismissal)

        case .restart(let endingRideID, let endingState, let rideID, let state):
            await performEnd(rideID: endingRideID, state: endingState, dismissal: .immediate)
            await performStart(rideID: rideID, state: state, record: record)
        }

        // And again after the fact: a `.start` is the tick that first gives this
        // process a card to map, and on the common path (MYR-218's grace window) the
        // server id is already in hand by then.
        noteIdentity()
    }

    // MARK: - Remembering which card is which ride (MYR-416)

    /// Record that the card this process holds is the ride the SERVER calls
    /// `serverRideID()`.
    ///
    /// Cheap, idempotent and safe on every tick: it writes only when there is a held
    /// card, a server id, and the two genuinely differ — i.e. only for a ride this
    /// device SUBMITTED, which is the only case with a split to remember. A ride
    /// adopted from the wire (MYR-230) has one id and writes nothing at all, so the
    /// ledger stays empty for every account that only ever relaunches into rides the
    /// server told it about.
    ///
    /// It is deliberately NOT written from `flushPendingRegistration`, where both
    /// facts are also in scope: that path runs only when ActivityKit has issued a
    /// token, and a simulator never does (MYR-415). Tying the mapping to a token
    /// would make adoption work in production and silently not on any device without
    /// APNs — the "correct and unreachable" shape this repo has been bitten by twice.
    private func noteIdentity() {
        guard let activityRideID = phase.rideID,
              let serverID = serverRideID(),
              serverID != activityRideID,
              !identity.namesTheSameRide(activityRideID: activityRideID, as: serverID)
        else { return }
        identities.note(activityRideID: activityRideID, serverRideID: serverID)
        identity = identities.identity()
    }

    // MARK: - The completed ride's clock (MYR-425)

    /// Establish (and remember) WHEN the held ride completed, or forget it.
    ///
    /// Returns the instant the backstop measures from, which is the server's own
    /// `completedAt` whenever the wire carried one. The local stamp is written ONCE
    /// and never re-written while the ride stays completed — re-stamping on every
    /// tick would walk the deadline forward for ever and the backstop would never
    /// fire at all, which is the quietest way to ship this fix un-shipped.
    private func noteCompletion(of record: RideRequestRecord?) -> Date? {
        // MYR-416 — "is this record the held card's ride" is the same two-id question
        // the adoption asks, so it is asked the same way. With `==` a relaunched
        // rider-submitted ride would never stamp the SERVER's `completedAt` and the
        // backstop would measure from this process's first sighting instead.
        let recordSaysCompleted: Bool = {
            guard let record, record.status == .completed, let held = phase.rideID else { return false }
            return identity.namesTheSameRide(activityRideID: held, as: record.id)
        }()
        guard phase.rideID != nil, isHoldingACompletedCard || recordSaysCompleted else {
            completionInstant = nil
            return nil
        }
        // The server's own instant wins whenever the wire carries one. The local
        // stamp is written ONCE — re-stamping on every tick would walk the deadline
        // forward for ever and the backstop would never fire at all, which is the
        // quietest way to ship this fix un-shipped.
        completionInstant = record?.completedAt ?? completionInstant ?? Date()
        return completionInstant
    }

    /// Does the card on screen say the ride is over?
    ///
    /// Read off the PHASE rather than off the record, for the reason `completionInstant`
    /// spells out: the record is gone for most of the wait.
    private var isHoldingACompletedCard: Bool {
        phase.state?.status == .completed
    }

    /// Is the held card a completed ride still inside its wait for the server's end?
    ///
    /// **This is what stops MYR-405's reaper eating the arrival card.** With the five
    /// minutes now spent LIVE rather than `.ended`, an Activity for a ride whose
    /// record has been released (the rider tapped Done on the summary) looks exactly
    /// like an orphan to `reconcile` — and reaping it would take the card down
    /// `.immediate` AND issue the §7.21 DELETE, i.e. reproduce this issue's defect
    /// from inside its own fix, the way MYR-405's `.ended` skip was written to
    /// prevent.
    private var isHoldingALingeringCompletedCard: Bool {
        isHoldingACompletedCard
            && !RideActivityCompletedEnd.backstopHasElapsed(completedAt: completionInstant, now: Date())
    }

    /// Arm the deferred wake-up when — and only when — the app is still waiting for
    /// the server to end a completed card.
    ///
    /// Any other answer cancels it: a `.start`, a `.restart`, an `.end` (including
    /// the backstop's own, so it cannot re-arm itself) and a ride that is no longer
    /// completed all mean there is nothing left to wait for.
    private func armBackstopIfStillWaiting(
        action: RideActivityAction,
        record: RideRequestRecord?,
        completedAt: Date?
    ) {
        guard let completedAt,
              phase.rideID != nil,
              isHoldingACompletedCard || record?.status == .completed,
              action.continuesTheHeldCard
        else {
            backstopTask?.cancel()
            backstopTask = nil
            return
        }

        let deadline = completedAt.addingTimeInterval(RideActivityCompletedEnd.backstop)
        let delay = max(0, deadline.timeIntervalSinceNow)
        let wait = backstopWait

        backstopTask?.cancel()
        backstopTask = Task { [weak self] in
            await wait(delay)
            guard !Task.isCancelled else { return }
            // Re-ASK rather than re-decide: `handleRideChange` runs the same pure
            // `action` call, over inputs that may well have moved on (the server's
            // end may have landed while we slept), so a wake-up can never end a card
            // the state machine would have kept.
            await self?.handleRideChange(record)
        }
    }

    /// **THE SERVER'S END, HONOURED WITHOUT A FIGHT** (MYR-425).
    ///
    /// A held Activity that the system reports as no longer on screen was ended by
    /// somebody other than this coordinator — in the shipping case, by the server's
    /// held end landing while the app was away. This process stands down: it stops
    /// driving a card that is gone, and it issues **no §7.21 DELETE**, because the
    /// end that removed the card is the same event that closed the server's row.
    ///
    /// Absence is deliberately NOT evidence: a ride the restore list does not mention
    /// at all leaves everything exactly where it is (MYR-405's own rule, and the
    /// reason `reconcile` waits out the restore budget before believing an empty
    /// list).
    private func standDownIfTheSystemEndedTheHeldCard() {
        guard let rideID = phase.rideID,
              let snapshot = presenter.presentedActivities.first(where: { $0.rideID == rideID }),
              !snapshot.lifecycle.isOnScreenAndOurs,
              snapshot.lifecycle != .dismissed // the rider's swipe has its own path
        else { return }
        standDown()
    }

    /// Forget the held Activity without ending anything and without telling the
    /// server. Used only where the card is ALREADY gone.
    private func standDown() {
        backstopTask?.cancel()
        backstopTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil
        registered = nil
        pendingToken = nil
        completionInstant = nil
        phase = .idle
    }

    /// **The server's id for the rider's ride became known** (MYR-415).
    ///
    /// A separate entry point from `handleRideChange` because it is a separate FACT
    /// with its own arrival time: the create POST's acknowledgement sets
    /// `riderServerRideID` without touching `activeRequest`, so the record observer
    /// cannot see it. Cheap and idempotent — it does nothing at all unless a token
    /// is genuinely waiting to be placed.
    func handleServerRideIDChange() async {
        guard isLive else { return }
        // MYR-416 — THIS IS THE MOMENT THE TWO IDS ARE FIRST KNOWN TOGETHER, and it
        // is the reason the mapping can be written at all: the create's
        // acknowledgement does not touch `activeRequest`, so no other entry point
        // fires for it. A card started at REQUEST plus a server id landing seconds
        // later is the whole shape of a rider-submitted ride.
        noteIdentity()
        await flushPendingRegistration()
    }

    /// Signing out ends the Activity at once. A lock-screen card naming a
    /// destination (P1) must not outlive the session that was allowed to see it.
    ///
    /// MYR-405 — and it ends EVERY card, not just the one this process happens to
    /// hold. The held Activity was never the whole lock screen, and an orphan left
    /// by a previous process names the same rider's destination. Reading
    /// `presentedActivities` directly rather than paying the restore budget is
    /// deliberate: a sign-out is a tap, so the app has been running and the list is
    /// long since restored.
    func handleSignOut() async {
        if case .live(let rideID, let state) = phase {
            await performEnd(rideID: rideID, state: state, dismissal: .immediate)
        }
        guard isLive else { return }
        for snapshot in presenter.presentedActivities where snapshot.lifecycle.isOnScreenAndOurs {
            await reap(rideID: snapshot.rideID, isDuplicateOfAdopted: false)
        }
        // MYR-416 — the mapping is a statement about THIS ACCOUNT's rides, so it goes
        // out with the session, alongside the profile, the view mode and the owner's
        // dispatch pointer. Nothing on the lock screen survives a sign-out either, so
        // there is nothing left for it to name.
        identities.clear()
        identity = .unmapped
        // MYR-479 — both of these are statements about THIS ACCOUNT's rides, and
        // nothing on the lock screen survives a sign-out for them to describe.
        dismissedRideIDs = []
        endedByAppRideIDs = []
    }

    // MARK: - Launch and foreground (MYR-405)

    /// Reconcile the lock screen with the account, then act on the ride.
    ///
    /// Called at LAUNCH and on every FOREGROUND, and the two are the same problem:
    /// the app was not running while the ride moved, so what is on the lock screen
    /// is whatever the last process left plus whatever the server managed to push.
    /// `handleRideChange` alone cannot fix that — it reasons from `phase`, which is
    /// this process's memory and is empty at launch, so an Activity started by a
    /// PREVIOUS process is invisible to it. The client's orphan is exactly that
    /// Activity: never updated, never ended, and unreachable by every code path the
    /// app had.
    ///
    /// `ride` is a CLOSURE rather than a value because the two facts this needs —
    /// the restored Activity list and the account's own live ride — both settle
    /// asynchronously after launch, and re-reading it inside the poll is what lets
    /// ONE bounded budget cover both. See `settledInputs`.
    func handleLaunchOrForeground(_ ride: @escaping @MainActor () -> RideActivityAccountRide) async {
        guard isLive else { return }

        // MYR-479 — read the system's answer where the rider can have just changed
        // it. A launch and a foreground are the two moments they may have come back
        // from iOS Settings, and this is the only thing in the app that ever asks.
        authorization = presenter.areActivitiesEnabled ? .enabled : .disabled

        let settled = await settledInputs(ride)
        // MYR-416 — THE COMPARISON THAT COULD NOT MATCH. `resolve()` names the
        // RECORD's id, which after a relaunch is the server's, while the restored
        // snapshot carries the local draft UUID this device stamped into the card's
        // immutable attributes. Without the mapping the rider's own live banner is
        // reaped here and a second one is started three lines later.
        let plan = RideActivityStateMachine.reconcile(
            snapshots: settled.snapshots,
            liveRide: settled.ride.resolve(),
            identity: identity
        )
        recordDismissals(plan.dismissed)

        // ADOPT FIRST, THEN REAP — the order is load-bearing when the duplicate
        // shares its ride id with the survivor. `endActivity` is keyed on the ride
        // and skips the HELD Activity, so the adoption is what marks which of two
        // identically-named cards is the one to keep. Reaping first would end both.
        if let adopt = plan.adopt, phase.rideID != adopt, let record = settled.ride.record {
            adoptRestored(rideID: adopt, record: record)
        }

        for rideID in plan.reap {
            // MYR-425 — see `isHoldingALingeringCompletedCard`. The rider dismissing
            // the summary releases the ride slot, so the account resolves to `.none`
            // and the completed card the server is about to announce on reads as an
            // orphan. It is not one: it is this process's own card, mid-linger.
            if rideID == phase.rideID, isHoldingALingeringCompletedCard { continue }
            await reap(rideID: rideID, isDuplicateOfAdopted: plan.isDuplicateOfAdopted(rideID))
        }

        // ⚠️ **AND THIRD, REVIVE — MYR-479.** Adopt and reap are both about cards
        // that EXIST; this is the arm for a live ride that has NONE. Only the app can
        // close that gap: APNs can update or end an Activity and cannot create one,
        // so a rider whose card was ended on the pre-#381 `409 reservation_expired`,
        // or whose card the system removed while the app was away, has no route back
        // that does not start here.
        //
        // It runs AFTER the reap on purpose. The reap is what clears a `phase` still
        // naming a card that has just come down, and a revival that ran first would
        // start a card the reap then took away.
        if case .start(let rideID) = RideActivityStateMachine.revival(
            snapshots: settled.snapshots,
            account: settled.ride,
            dismissedRideIDs: dismissedRideIDs,
            identity: identity
        ), let record = settled.ride.record {
            await revive(rideID: rideID, record: record)
        }

        // Adopting sets `phase`, so the state machine's next answer is an `.update`
        // to the card the rider can actually see rather than a `.start` beside it.
        await handleRideChange(settled.ride.record)
    }

    /// Put a card back on the lock screen for a ride that is live and has none.
    ///
    /// **THE STAND-DOWN IS THE HALF THAT COULD NOT BE DONE ANYWHERE ELSE.**
    /// `standDownIfTheSystemEndedTheHeldCard` refuses to act on ABSENCE — "a ride the
    /// restore list does not mention at all leaves everything exactly where it is" —
    /// which is correct in general, because the restore list is empty for the first
    /// moments of a process and believing it is MYR-405's duplicate-banner defect.
    /// Here, and only here, the restore budget has already been spent
    /// (`settledInputs`), so an absence IS evidence: whatever `phase` names, the
    /// system is not showing it. Nothing is ENDED and **no §7.21 DELETE is issued** —
    /// there is no card to end, and the row is about to be re-registered under the
    /// server id by the start below.
    private func revive(rideID: String, record: RideRequestRecord) async {
        if phase.rideID != nil { standDown() }
        logRevival("live ride=\(rideID) has no Activity on screen — starting a fresh one")
        await performStart(
            rideID: rideID,
            state: RideActivityStateMachine.contentState(
                for: record,
                vehicleName: vehicleName(),
                previous: nil
            ),
            record: record
        )
    }

    /// **THE ONE DOOR INTO THE FINALITY SET** (MYR-479).
    ///
    /// A funnel rather than two `formUnion`s, for MYR-389's reason inverted: a rule
    /// about what may ENTER a set is only as complete as the list of writers was on
    /// the day it was written, and this set has two writers that read a list nobody
    /// stamped with provenance. See `endedByAppRideIDs`.
    private func recordDismissals(_ rideIDs: [String]) {
        for rideID in rideIDs where !identity.anyIdentity(of: rideID, isIn: endedByAppRideIDs) {
            dismissedRideIDs.insert(rideID)
        }
    }

    /// Remember that the card for this ride came down because THIS APP took it down.
    private func noteEndedByApp(_ rideID: String) {
        endedByAppRideIDs.formUnion(identity.identities(of: rideID))
    }

    /// A fresh card exists for this ride, so our own teardown is history.
    private func forgetEndedByApp(_ rideID: String) {
        endedByAppRideIDs.subtract(identity.identities(of: rideID))
    }

    /// Wait for BOTH asynchronous facts to settle, inside one bounded budget.
    ///
    /// `Activity.activities` fills in over the first moments of a process
    /// (`RideActivityRestore`) and the rider's own ride list answers over the
    /// network at roughly the same time. Polling them together costs one budget
    /// instead of two and, more importantly, means the reaper never runs on the
    /// half-settled reading that produced the bug.
    ///
    /// It stops EARLY the moment both are settled — an already-running app with a
    /// known ride and a stable list pays one read and one 250ms step — and it
    /// returns whatever it has when the budget is spent, because a `.unresolved`
    /// ride is itself a safe answer: `reconcile` reaps nothing on it.
    private func settledInputs(
        _ ride: @MainActor () -> RideActivityAccountRide
    ) async -> (snapshots: [RideActivitySnapshot], ride: RideActivityAccountRide) {
        var snapshots = presenter.presentedActivities
        var account = ride()

        // THE RACE IS A ONCE-PER-PROCESS PHENOMENON. Once the restore has settled,
        // `Activity.activities` is authoritative the moment it is read, so every
        // later start and every later foreground pays a single synchronous read.
        // Without this latch a ride accepted while the app is open would sit two
        // seconds behind its own lock-screen card for no reason at all.
        if restoreSettled { return (snapshots, account) }

        for _ in 0..<RideActivityRestore.attempts {
            await sleep(RideActivityRestore.interval)
            let next = presenter.presentedActivities
            let settledList = !snapshots.isEmpty && next == snapshots
            snapshots = next
            account = ride()
            // A NON-EMPTY list that did not change across an interval is restored.
            // An EMPTY list is never taken as settled before the budget runs out —
            // that reading IS the defect, and the cost of being wrong about it is a
            // second banner the rider cannot remove.
            if settledList, account.isResolved {
                restoreSettled = true
                return (snapshots, account)
            }
        }
        // The budget is spent. Whatever the list holds now is as restored as it is
        // going to get, so later calls stop paying for it — but note that the RIDE
        // may still be `.unresolved`, and `reconcile` reaps nothing on that reading.
        restoreSettled = true
        return (snapshots, account)
    }

    // MARK: - Holding what the server delivered (MYR-423)

    /// Replace this process's memory of the current frame with the frame that is
    /// actually ON the Activity.
    ///
    /// **`phase` IS BOOKKEEPING, NOT A RECORD OF THE CARD**, and reading it as the
    /// latter is the whole of MYR-423 — the same shape as MYR-405's "a guard on a
    /// process-local handle is not a guard on a lock screen that outlives the
    /// process", one field deeper. `RideActivityPhase.live` carries the last frame
    /// this coordinator WROTE. The server writes to the same Activity over APNs
    /// without this process being involved at all, so between two local ticks the
    /// card can gain an `eta`, a `progress` and an `asOf` that `phase` has never
    /// seen. Composing the next local frame from `phase` therefore asserted `nil`
    /// over all three: the client's "Pick up in 12 min" reverting to "Pickup soon"
    /// on an unlock, with nothing wrong anywhere in the state machine's own logic.
    ///
    /// It replaces the state WHOLESALE rather than merging field by field, and that
    /// is the stronger and simpler statement: ActivityKit's copy already reflects
    /// every write, local and remote, so it is never behind what we last wrote and
    /// is frequently ahead. `RideActivityStateMachine.contentState` then does the
    /// per-field merging it was always written to do, over an input that finally
    /// contains something to hold. It also makes the "only speak when something
    /// changed" guard compare against the card the rider is looking at rather than
    /// against our memory of it, which is what stops a redundant push in the first
    /// place.
    ///
    /// Cheap and safe on every tick: a synchronous read, and a no-op when the system
    /// has nothing for this ride (the restore race, or Live Activities switched off).
    private func reseatPhaseOnDeliveredState() {
        guard case .live(let rideID, _) = phase,
              let delivered = presenter.deliveredContentState(rideID: rideID)
        else { return }
        phase = .live(rideID: rideID, state: delivered)
    }

    // MARK: - Effects

    /// **ADOPT, NEVER DUPLICATE, AND NEVER START BESIDE A STRANGER** (MYR-405).
    ///
    /// The production start path used to be the two lines at the bottom of this
    /// method, and that is the whole defect. `SystemRideActivityPresenter.start`
    /// does guard `activity == nil` — but `activity` is THIS PROCESS's handle, and
    /// after a cold launch it is nil while the lock screen is not empty. So the app
    /// requested a second Activity for a ride that already had one, the server's
    /// `(ride, rider)` token upsert kept only the newest token, and the first card
    /// starved: "IN RIDE · Not updating", for ever, with no code path able to reach
    /// it. The capture tooling hit the identical race the same day.
    ///
    /// So a start now begins by ASKING THE SYSTEM, with the restore budget spent
    /// before the question is believed:
    ///
    ///  • an Activity for THIS ride → adopt it and re-register ITS push token, so
    ///    the server's next rotation lands on the banner the rider is looking at;
    ///  • every OTHER Activity → ended first (semantic 4, "a new ride ends all
    ///    prior"), including a duplicate of this same ride;
    ///  • a ride the rider DISMISSED → nothing at all.
    ///
    /// Note what the measurement actually said: the duplicate is **deterministic**,
    /// not a race the app sometimes loses. The restore race is real and is what bit
    /// the CAPTURE tooling the same day (`RideActivityDebugLauncher`'s sweep), and
    /// the budget below exists for it — but production had no enumeration for the
    /// race to spoil.
    private func performStart(
        rideID: String,
        state: RideActivityAttributes.ContentState,
        record: RideRequestRecord?
    ) async {
        let settled = await settledInputs {
            RideActivityAccountRide(record: record, isResolved: true)
        }
        let plan = RideActivityStateMachine.reconcile(
            snapshots: settled.snapshots,
            liveRide: .live(rideID: rideID),
            identity: identity
        )
        recordDismissals(plan.dismissed)
        // MYR-416 — the swipe was recorded under the CARD's id and `rideID` here is
        // the record's, which a relaunch makes the server's. Asked through the
        // mapping, a dismissal survives the process it happened in exactly as
        // MYR-405 semantic 5 promises.
        guard !identity.anyIdentity(of: rideID, isIn: dismissedRideIDs) else { return }

        // Adopt before reaping — see `handleLaunchOrForeground` for why the order
        // is load-bearing when the duplicate carries the same ride id.
        let adopted = plan.adopt.map { adoptRestored(rideID: $0, state: state) } ?? false

        for reaped in plan.reap {
            await reap(rideID: reaped, isDuplicateOfAdopted: plan.isDuplicateOfAdopted(reaped))
        }

        // SEMANTIC 4 LIVES IN THAT LOOP, NOT IN A SEPARATE STEP: for a genuinely new
        // ride the plan adopts nothing and every prior card is in `reap`, so "a new
        // ride ends all prior Activities" is enforced by the same expression that
        // heals a duplicate rather than by a second rule that could disagree.
        if adopted { return }

        let started = await presenter.start(
            attributes: RideActivityAttributes(rideID: rideID, vehicle: vehicle()),
            state: state,
            staleDate: RideActivityStaleness.date()
        )
        // A refusal is ordinary — the rider may simply have Live Activities off.
        // The phase stays `.idle`, so nothing is registered and nothing is ended,
        // and the app's own in-app tracking sheet carries the ride as it always
        // has.
        guard started else { return }

        phase = .live(rideID: rideID, state: state)
        // MYR-479 — a fresh card exists, so our own previous teardown of this ride
        // stops shielding it: a swipe on THIS card is the rider's and must survive.
        forgetEndedByApp(rideID)
        observe(rideID: rideID)
    }

    /// Take over an Activity a PREVIOUS process started.
    ///
    /// `registered` is cleared unconditionally, and that clearing is the half of
    /// this that fixes the client's screenshot. The server keeps ONE token per
    /// `(ride, rider)`; an adopted Activity has its own, different token, and until
    /// the server hears it every push still addresses whatever this account
    /// registered last. Re-registering is what moves the rotation onto the live
    /// banner — `pushTokenUpdates` yields the current token on subscription, so
    /// `observe` is all it takes.
    ///
    /// MYR-423 — the frame it adopts is **the restored Activity's own**, not the one
    /// composed for it. An adopted card is by definition one this process did not
    /// write, so its `eta`/`progress`/`asOf` are the previous process's or the
    /// server's, and `state` here is a locally-composed stand-in that has none of
    /// them. Seating `phase` on the stand-in is what made the very next local update
    /// wipe the card clean.
    @discardableResult
    private func adoptRestored(rideID: String, state: RideActivityAttributes.ContentState) -> Bool {
        guard presenter.adopt(rideID: rideID) else { return false }
        phase = .live(rideID: rideID, state: presenter.deliveredContentState(rideID: rideID) ?? state)
        // MYR-479 — see `performStart`: a card we are driving again is not a card we
        // took down.
        forgetEndedByApp(rideID)
        registered = nil
        // MYR-425 — a completion stamp belongs to the ride it was taken for. Carrying
        // one onto an adopted card would measure a NEW ride's backstop from an old
        // ride's drop-off; `noteCompletion` re-establishes it from the record.
        completionInstant = nil
        // MYR-415 — a token still pending for a DIFFERENT Activity must not be
        // placed against this one. The adopted card publishes its own token on
        // subscription, which is what `observe` is here for.
        pendingToken = nil
        observe(rideID: rideID)
        return true
    }

    /// The launch/foreground spelling.
    ///
    /// **MYR-423 — `previous` IS THE RESTORED CARD'S OWN FRAME, AND THE COMMENT THAT
    /// USED TO STAND HERE HAD THE RIGHT PRINCIPLE AND THE WRONG CONCLUSION.** It read:
    /// "carrying nothing forward, because a card this process did not start has no
    /// previous state to inherit from — the pushed `eta` and `progress` on the
    /// restored card are the SERVER's and are not ours to re-assert." Every clause of
    /// that is true, and `previous: nil` is the one implementation of it that does
    /// not work: a composed frame does not decline to speak about a field, it CARRIES
    /// a value for every field, so composing with nothing forward asserts `nil` — an
    /// active re-assertion, and the destructive one. Not re-asserting the server's
    /// fields means copying them through untouched, which is what inheriting from the
    /// delivered frame does.
    private func adoptRestored(rideID: String, record: RideRequestRecord) {
        adoptRestored(
            rideID: rideID,
            state: RideActivityStateMachine.contentState(
                for: record,
                vehicleName: vehicleName(),
                previous: presenter.deliveredContentState(rideID: rideID)
            )
        )
    }

    /// End an Activity that is not describing anything this account is doing
    /// (MYR-405 semantic 2 — the generalization of §7.21's 409-means-end-now).
    ///
    /// See `RideActivityReconciliation.isDuplicateOfAdopted` for the one case that
    /// ends the card and nothing else.
    private func reap(rideID: String, isDuplicateOfAdopted: Bool) async {
        // A duplicate of the ride just adopted takes the presenter's own "never end
        // the held Activity" path and leaves BOTH the phase and the server
        // registration exactly where they are.
        await presenter.endActivity(rideID: rideID, dismissal: .immediate)
        guard !isDuplicateOfAdopted else { return }

        // MYR-479 — WE took this card down. A `.dismissed` row the restore list
        // hands back for it later is our own teardown, not the rider's decision.
        noteEndedByApp(rideID)

        // MYR-415 — resolved BEFORE the teardown clears it, because the row to
        // delete is keyed by the id we REGISTERED under, not by the Activity's.
        let deleteID = registrationIDToRelease(forActivity: rideID)

        if phase.rideID == rideID {
            backstopTask?.cancel()
            backstopTask = nil
            tokenTask?.cancel()
            tokenTask = nil
            stateTask?.cancel()
            stateTask = nil
            registered = nil
            pendingToken = nil
            completionInstant = nil
            phase = .idle
        }
        guard let deleteID else { return }
        _ = try? await endpoint?.endRideActivityToken(rideID: deleteID)
    }

    private func performEnd(
        rideID: String,
        state: RideActivityAttributes.ContentState,
        dismissal: RideActivityDismissal
    ) async {
        let deleteID = registrationIDToRelease(forActivity: rideID)

        // MYR-479 — including the §7.21 409 arm, which reaches this method and is
        // the exact teardown this issue exists to recover from.
        noteEndedByApp(rideID)

        backstopTask?.cancel()
        backstopTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil
        registered = nil
        pendingToken = nil
        completionInstant = nil
        phase = .idle

        await presenter.end(state: state, dismissal: dismissal)

        // Tell the server the Activity is gone so it stops pushing to a token that
        // no longer addresses anything. Idempotent by contract, and a failure here
        // is genuinely not worth reacting to: the registration dies with the ride
        // server-side anyway, and the card is already off the rider's screen.
        guard let deleteID else { return }
        _ = try? await endpoint?.endRideActivityToken(rideID: deleteID)
    }

    /// The id the §7.21 DELETE must name for an Activity that is going away.
    ///
    /// **The registration was keyed on the SERVER's ride id (MYR-415), so the
    /// release has to be too** — a DELETE under the Activity's local draft UUID is
    /// the same 404 the POST used to be, which would leave the server pushing to a
    /// card that is no longer on screen.
    ///
    /// **It must never fall back to the HELD registration for an orphan** — reaping
    /// somebody else's leftover card must not delete the row belonging to the ride
    /// this process is driving, which is the same starvation `isDuplicateOfAdopted`
    /// exists to prevent, reached by a different door.
    private func registrationIDToRelease(forActivity rideID: String) -> String? {
        guard phase.rideID == rideID else {
            // An ORPHAN. This process never registered it and cannot know the id the
            // process that did used, so the Activity's own id is the only thing
            // available — correct when that id IS a server id (a card started from a
            // cold-adopted record, MYR-230), an idempotent no-op otherwise, and
            // MYR-405's "the server is told" either way.
            return rideID
        }
        // The HELD ride: release exactly what was registered, falling back to the id
        // the registration WOULD have used when none was confirmed (the §7.21 409
        // arm gets here that way). Falling back to the Activity's local draft UUID
        // instead would be the same 404 the POST used to be.
        return registered?.serverRideID ?? serverRideID()
    }

    // MARK: - Push token

    /// Consume the Activity's token stream for as long as it lives.
    ///
    /// Every element is registered, not just the first — ActivityKit REISSUES the
    /// token mid-Activity and expects the server to switch. A rotation is an
    /// ordinary re-registration (the endpoint upserts on `(ride, rider)`), so there
    /// is nothing special to do beyond noticing it.
    private func observeTokens(for rideID: String) {
        tokenTask?.cancel()
        let stream = presenter.pushTokens()
        tokenTask = Task { [weak self] in
            for await token in stream {
                guard !Task.isCancelled else { return }
                await self?.register(token: token, rideID: rideID)
            }
        }
    }

    /// Both streams the held Activity publishes, started together because they are
    /// started at exactly the same three moments and forgetting one is silent.
    private func observe(rideID: String) {
        observeTokens(for: rideID)
        observeLifecycle(for: rideID)
    }

    // MARK: - The rider's own decision (MYR-405 semantic 5)

    /// Watch the held Activity's `ActivityState`.
    ///
    /// A swipe-dismissal is otherwise INVISIBLE to this app: no callback, no error,
    /// and `Activity.activities` keeps listing it for a while. Without this the very
    /// next status change would push an update into a card the rider deliberately
    /// removed — and a relaunch would start a fresh one, which reads as the swipe
    /// having done nothing.
    private func observeLifecycle(for rideID: String) {
        stateTask?.cancel()
        let stream = presenter.activityStates()
        stateTask = Task { [weak self] in
            for await lifecycle in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(lifecycle: lifecycle, rideID: rideID)
            }
        }
    }

    private func handle(lifecycle: RideActivitySnapshot.Lifecycle, rideID: String) async {
        guard phase.rideID == rideID else { return }

        // **THE SERVER ENDED IT — MYR-425.** With `completed` no longer ended by the
        // client, the held card's ordinary exit is the server's held end (+5 min),
        // which arrives over APNs and reaches this app only as an `.ended` lifecycle.
        // Standing down here is what makes "the server end is honoured, and there is
        // no fight" true rather than merely intended: the backstop's wake-up is
        // cancelled with everything else, so it cannot re-end a card that is already
        // gone, and no §7.21 DELETE is issued because the end that removed the card
        // is the same event that closed the row.
        if lifecycle == .ended {
            standDown()
            return
        }

        guard lifecycle == .dismissed else { return }

        // MYR-415 — resolved before the teardown clears the registration it names.
        let deleteID = registrationIDToRelease(forActivity: rideID)

        dismissedRideIDs.insert(rideID)
        backstopTask?.cancel()
        backstopTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil
        registered = nil
        pendingToken = nil
        completionInstant = nil
        phase = .idle

        // Tell the server to stop pushing to a card nobody can see. The rider ended
        // this ride's Activity, not the ride — the in-app tracking sheet carries on
        // exactly as it does for a rider who never enabled Live Activities.
        guard let deleteID else { return }
        _ = try? await endpoint?.endRideActivityToken(rideID: deleteID)
    }

    /// ActivityKit issued (or reissued) a token. Hold it, then try to place it.
    ///
    /// The token is held FIRST and unconditionally, because it is the scarce half:
    /// `pushTokenUpdates` yields once per Activity in the ordinary case, so a token
    /// dropped because the server id had not landed yet is a token that never comes
    /// back. The server id, by contrast, is seconds away and arrives on its own.
    private func register(token: Data, rideID: String) async {
        // A token belongs to ONE Activity. If the phase has already moved on, this
        // is a straggler from a stream whose Activity is gone and placing it would
        // point the server at a card nobody is looking at.
        guard phase.rideID == rideID else { return }
        pendingToken = token
        await flushPendingRegistration()
    }

    /// Register the held token against the SERVER's ride id, if both are known.
    ///
    /// Idempotent and safe to call on every tick — it returns immediately unless
    /// there is genuinely something new to say.
    private func flushPendingRegistration() async {
        guard let endpoint, let token = pendingToken else { return }

        // Hex, via MYR-186's encoder rather than a second one. The server validates
        // hex, and `Data.description` — the shape a naive interpolation produces —
        // is `<8a1f4c2e …>`, which is not it.
        let hex = PushDeviceToken.hex(from: token)
        guard !hex.isEmpty else { pendingToken = nil; return }

        // ⚠️ MYR-415 — THE ID MUST BE THE SERVER'S. Posting under the local draft
        // UUID is a 404 against a ride that does not exist, which is exactly the
        // silent failure that left `go_live_activities` empty. Waiting is correct
        // and is not a degradation: the card is already on the lock screen showing
        // MYR-398 v3's Dispatch state, and the only thing deferred is the server's
        // ability to push to it.
        guard let serverID = serverRideID() else {
            logRegistration("deferred — no server ride id yet (create not acknowledged)")
            return
        }

        if let registered, registered.token == hex, registered.serverRideID == serverID {
            pendingToken = nil
            return
        }

        logRegistration("POST ride=\(serverID) token=\(LiveActivityTokenRedaction.redacted(hex)) sandbox=\(sandbox)")

        do {
            _ = try await endpoint.registerRideActivityToken(
                rideID: serverID,
                token: hex,
                sandbox: sandbox
            )
            registered = (token: hex, serverRideID: serverID)
            pendingToken = nil
            logRegistration("registered ride=\(serverID) sandbox=\(sandbox)")
        } catch let error as RestError where error.isTerminalRideActivityConflict {
            // The ride is already terminal, so there is nothing left to place.
            pendingToken = nil
            logRegistration("409 — ride already terminal, ending the Activity locally")
            let rideID = phase.rideID ?? serverID
            // §7.21: a 409 means the ride is already terminal, "and the 409 is the
            // signal to end it locally". This is the ONLY thing that can rescue a
            // rider whose ride ended while the app was not running to see it.
            //
            // The final frame is the last one we had, with its status UNCHANGED,
            // and the dismissal is immediate. We deliberately do not guess: the
            // server told us the ride is over but not HOW it ended, and writing
            // "You've arrived" over a ride that was cancelled is a worse lock
            // screen than one that disappears promptly. If the app's own record
            // catches up a moment later, the state machine ends it properly — but
            // by then there is nothing left to end, which is the correct outcome.
            guard case .live(_, let last) = phase else { return }
            await performEnd(rideID: rideID, state: last, dismissal: .immediate)
        } catch {
            // ⚠️ MYR-415 — THE TOKEN STAYS PENDING. This arm used to `return` and
            // drop it, on the reasoning that "the next rotation tries again" — but
            // ActivityKit does not rotate on a schedule, so in the ordinary case
            // there IS no next rotation and one bad minute cost the whole ride its
            // lock-screen updates, silently. `pendingToken` is left set and the next
            // tick (a status change, a launch, a foreground) re-attempts, which is
            // MYR-186's policy verbatim — no backoff loop, no timer, no queue.
            let status = (error as? RestError)?.httpStatus.map(String.init) ?? "none"
            logRegistration(
                "FAILED status=\(status) — token held, will retry: \(error.localizedDescription)",
                isFailure: true
            )
        }
    }

    // MARK: - Visibility (MYR-415)

    /// **A FAILED REGISTRATION USED TO VANISH**, and that is why this cost days
    /// rather than minutes: the POST went to a 404 on every ride for three days and
    /// produced no throw a user could see, no banner, no log line and no row. The
    /// MYR-381 lesson ("silent refusals cost days") pointed at the one call in this
    /// feature that talks to the server.
    ///
    /// `os_log` is the primary channel and the one the repo's own probes use
    /// (MYR-222 / MYR-405: `--console` does not reliably carry a SwiftUI app's
    /// stdout, `log stream` does), on the SAME `liveactivity` category the MYR-405
    /// census already streams — so one predicate shows the lifecycle and the
    /// registration together. The DEBUG `print` is the tethered-Xcode-console half.
    ///
    /// The token never travels in full: `LiveActivityTokenRedaction` is the only
    /// spelling allowed, since §7.21 classifies it P1.
    private func logRegistration(_ message: String, isFailure: Bool = false) {
        if isFailure {
            log.notice("activity-token \(message, privacy: .public)")
        } else {
            log.info("activity-token \(message, privacy: .public)")
        }
        #if DEBUG
        print("[MRT liveactivity] activity-token \(message)")
        #endif
    }

    /// **MYR-479 — A REVIVAL HAS TO BE VISIBLE IN THE CENSUS.** MYR-415's lesson is
    /// that a silent Live Activity failure costs days, and a card appearing from
    /// nowhere is exactly the kind of event a `log stream` on this category should
    /// explain: the MYR-405 probe already streams `liveactivity`, so one predicate
    /// now shows the restore, the adoption, the reap, the revival and the
    /// registration together.
    private func logRevival(_ message: String) {
        log.notice("activity-revival \(message, privacy: .public)")
        #if DEBUG
        print("[MRT liveactivity] activity-revival \(message)")
        #endif
    }
}
