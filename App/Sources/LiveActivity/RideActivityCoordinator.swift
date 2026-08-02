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

    private var stateTask: Task<Void, Never>?

    /// Whether ActivityKit's asynchronous restore has been waited out in this
    /// process. See `settledInputs`.
    private var restoreSettled = false

    /// Injected only so tests do not pay the restore budget in real time. Production
    /// passes nothing.
    private let sleep: @Sendable (Duration) async -> Void

    init(
        presenter: any RideActivityPresenting,
        endpoint: (any RideActivityTokenEndpoint)?,
        isLive: Bool,
        sandbox: Bool = PushEnvironment.isSandbox,
        vehicleName: @escaping @MainActor () -> String = { "" },
        vehicle: @escaping @MainActor () -> RideActivityVehicle? = { nil },
        serverRideID: @escaping @MainActor () -> String? = { nil },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.presenter = presenter
        self.endpoint = endpoint
        self.isLive = isLive
        self.sandbox = sandbox
        self.vehicleName = vehicleName
        self.vehicle = vehicle
        self.serverRideID = serverRideID
        self.sleep = sleep
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

        let action = RideActivityStateMachine.action(
            phase: phase,
            record: record,
            vehicleName: vehicleName(),
            dismissedRideIDs: dismissedRideIDs
        )

        switch action {
        case .none:
            return

        case .start(let rideID, let state):
            await performStart(rideID: rideID, state: state, record: record)

        case .update(let rideID, let state):
            await presenter.update(state: state, staleDate: RideActivityStaleness.date())
            phase = .live(rideID: rideID, state: state)

        case .end(let rideID, let state, let dismissal):
            await performEnd(rideID: rideID, state: state, dismissal: dismissal)

        case .restart(let endingRideID, let endingState, let rideID, let state):
            await performEnd(rideID: endingRideID, state: endingState, dismissal: .immediate)
            await performStart(rideID: rideID, state: state, record: record)
        }
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

        let settled = await settledInputs(ride)
        let plan = RideActivityStateMachine.reconcile(
            snapshots: settled.snapshots,
            liveRide: settled.ride.resolve()
        )
        dismissedRideIDs.formUnion(plan.dismissed)

        // ADOPT FIRST, THEN REAP — the order is load-bearing when the duplicate
        // shares its ride id with the survivor. `endActivity` is keyed on the ride
        // and skips the HELD Activity, so the adoption is what marks which of two
        // identically-named cards is the one to keep. Reaping first would end both.
        if let adopt = plan.adopt, phase.rideID != adopt, let record = settled.ride.record {
            adoptRestored(rideID: adopt, record: record)
        }

        for rideID in plan.reap {
            await reap(rideID: rideID, isDuplicateOfAdopted: plan.isDuplicateOfAdopted(rideID))
        }

        // Adopting sets `phase`, so the state machine's next answer is an `.update`
        // to the card the rider can actually see rather than a `.start` beside it.
        await handleRideChange(settled.ride.record)
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
            liveRide: .live(rideID: rideID)
        )
        dismissedRideIDs.formUnion(plan.dismissed)
        guard !dismissedRideIDs.contains(rideID) else { return }

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
    @discardableResult
    private func adoptRestored(rideID: String, state: RideActivityAttributes.ContentState) -> Bool {
        guard presenter.adopt(rideID: rideID) else { return false }
        phase = .live(rideID: rideID, state: state)
        registered = nil
        // MYR-415 — a token still pending for a DIFFERENT Activity must not be
        // placed against this one. The adopted card publishes its own token on
        // subscription, which is what `observe` is here for.
        pendingToken = nil
        observe(rideID: rideID)
        return true
    }

    /// The launch/foreground spelling: the frame is built from the record, carrying
    /// nothing forward, because a card this process did not start has no previous
    /// state to inherit from — the pushed `eta` and `progress` on the restored card
    /// are the SERVER's and are not ours to re-assert.
    private func adoptRestored(rideID: String, record: RideRequestRecord) {
        adoptRestored(
            rideID: rideID,
            state: RideActivityStateMachine.contentState(
                for: record,
                vehicleName: vehicleName(),
                previous: nil
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

        // MYR-415 — resolved BEFORE the teardown clears it, because the row to
        // delete is keyed by the id we REGISTERED under, not by the Activity's.
        let deleteID = registrationIDToRelease(forActivity: rideID)

        if phase.rideID == rideID {
            tokenTask?.cancel()
            tokenTask = nil
            stateTask?.cancel()
            stateTask = nil
            registered = nil
            pendingToken = nil
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

        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil
        registered = nil
        pendingToken = nil
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
        guard lifecycle == .dismissed, phase.rideID == rideID else { return }

        // MYR-415 — resolved before the teardown clears the registration it names.
        let deleteID = registrationIDToRelease(forActivity: rideID)

        dismissedRideIDs.insert(rideID)
        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil
        registered = nil
        pendingToken = nil
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
}
