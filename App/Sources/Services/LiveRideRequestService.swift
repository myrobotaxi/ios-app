import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - Live ride-request service (MYR-209)
//
// The M2 conformer of the `RideRequestService` seam: the same method surface the
// rider's `SharedViewerScreen` and the owner's `IncomingRequestSheet` already
// call. MYR-325 splits the STATE those two surfaces read into two role-scoped
// pipelines — see the pipeline note at the top of the class. Where the simulated
// service runs local timers, this talks to the production backend over
// `MyRoboTaxiKit`:
//
//  • REST (rest-api.md §7.8) for the mutations — create / cancel / accept /
//    decline — and the owner incoming feed + full-record refetch.
//  • The account-wide WS ride stream (`ride_request_created` /
//    `ride_status_changed`, summary-only) to react to the OTHER party's action;
//    each frame triggers a `GET /api/ride-requests/{id}` refetch for the full
//    record (the frames carry no pickup/dropoff/passenger).
//
// Method calls apply an OPTIMISTIC local state change synchronously (so the
// sheets react with the same timing as the simulated service — no visual change)
// and fire the POST in the background; the WS frame then reconciles. In the M1/M2
// single-session demo (rider + owner are the same JWT, ONE service instance shared
// across the role switch — see `RideRequestService`'s header) MYR-325 makes the
// round trip explicit rather than implicit: the two roles no longer share a
// snapshot, so an owner action reaches the rider through an authoritative server
// record (the mutation's own 200, or the WS frame) — the same route a second
// device takes, which is why the demo and the real multi-device case now exercise
// identical code.
//
// Deliberate v1 gaps (MYR-176/177 own the rest of the lifecycle):
//  • No per-second progress ticker (MYR-176/177). Each lifecycle leg mounts the
//    rider's tracking sheet at a STATIC anchor (heading-to-pickup / aboard) and the
//    LEG/stage is read off the server STATUS (accepted → arrived → enroute →
//    completed), not an interpolated progress — reusing existing UI, inventing no
//    new screen (dead-code rule). The dropoff ETA "arriving" takeover derives from
//    the streamed nav ETA where available, never a timer (MYR-270).
//  • Create targets the caller's first owned vehicle (the demo's single shared
//    car); the fixture fleet-picker → live-vehicle join is future work (needs the
//    MYR-91 shared-viewer access set + a live Review picker). Display-only fleet
//    fields fall back to fixtures — see `RideRequestContractMapping`.
//
// MYR-179 (was a gap): a scheduled create now carries a REAL RFC 3339
// `scheduledFor`, resolved from the rider's picked day/time at the send moment
// in the rider's own time zone (`RideRequestContractMapping.scheduledFor`). The
// local optimistic draft + the scheduled sheets keep rendering their display
// strings; the wire value is authoritative on refetch.
@Observable
@MainActor
final class LiveRideRequestService: RideRequestService {
    // MARK: - MYR-325 — TWO pipelines, because one device serves TWO roles
    //
    // Until MYR-325 a single `activeRequest` slot served the rider's ride AND the
    // owner's incoming card, with an `activeRequestOrigin` tag deciding who was
    // allowed to displace whom. That tag answered the rider-safety question
    // correctly (MYR-292/306/317: never clobber a Ride Summary or a
    // `DeclinedNotice`) and, in doing so, starved the owner: the client is owner
    // AND rider on one account, so his held rider-origin `.declined` record made
    // `canAdoptIncoming` refuse every subsequent incoming request — two live
    // `requested` rides, pushes delivered, `refreshIncoming()` fired, and no card
    // ever appeared. There was no correct answer available: one slot cannot hold
    // the rider's terminal record and the owner's next request at the same time.
    //
    // So the state is split by ROLE, not arbitrated by origin:
    //
    //   RIDER pipeline  — `activeRequest` (+ `riderServerRideID`). Rides this
    //     device's rider created or adopted. Read by `SharedViewerScreen`,
    //     `RideRequestBookingContent`, `RideRequestTrackingContent`,
    //     `RideRequestSummaryContent`. Driven by `submit`/`confirmSend`/`cancel`/
    //     `startRide`/`completeAndReset`/`refreshActiveRide`. Untouched by this
    //     issue — every rider behaviour is exactly as it was.
    //
    //   OWNER pipeline  — `ownerRequest` (+ `ownerServerRideID`) backed by the
    //     MYR-317 `incomingQueue`. Requests addressed to this owner's cars. Two
    //     projections, one per surface: `incomingRequest` (PENDING only — the
    //     `IncomingRequestSheet` gate) and `ownerDispatch` (accepted → arrived →
    //     enroute → completed — the `OwnerDispatchCard`). Driven by
    //     `refreshIncoming`/`accept`/`decline`/`pickedUp`/`droppedOff`.
    //
    // The rider-safety invariants are now true BY CONSTRUCTION rather than by
    // guard: an incoming request cannot displace the rider's summary or notice
    // because it never writes to that storage at all. `canAdoptIncoming` shrinks
    // to a question about the owner's own slot, and `ActiveRequestOrigin` is gone
    // — it existed only to arbitrate the shared slot.
    //
    // SAME-ACCOUNT DUALITY (the deliberate decision): both pipelines may be live
    // at once, and for a ride this device's rider created they may hold the SAME
    // ride id. See `integrate`'s doc comment for why that is right rather than
    // suppressed, and for the one place the two pipelines are allowed to touch:
    // an authoritative server record folded into whichever of them holds that id.

    /// The RIDER's ride — see the pipeline note above. Never written by an owner
    /// action; the owner's accept/decline reaches it only through `integrate`,
    /// i.e. through a record the server confirmed.
    private(set) var activeRequest: RideRequestRecord?

    /// The OWNER's current incoming/dispatched request — see the pipeline note
    /// above. `internal` rather than private so the pipeline's own invariants have
    /// direct unit coverage; the SCREENS read the two projections below, never this.
    private(set) var ownerRequest: RideRequestRecord?

    /// The request awaiting this owner's decision — the `IncomingRequestSheet`
    /// presentation gate. PENDING only: the moment the owner answers, the sheet's
    /// dismiss animation is driven by this going `nil` (unchanged behaviour; this
    /// is the very expression `HomeScreen` used to compute locally off the shared
    /// slot, now owned by the pipeline that actually holds it).
    var incomingRequest: RideRequestRecord? {
        guard let held = ownerRequest, held.status == .pending else { return nil }
        return held
    }

    /// The owner's ACCEPTED ride, through to drop-off — what `OwnerDispatchCard`
    /// narrates. Excludes `pending` (the incoming sheet owns that) and `declined`
    /// (`OwnerRideStatusLine.text` renders no line for it, so it is on no surface);
    /// the `completed`-until-acknowledged rule stays in the pure
    /// `OwnerRideStatusLine.dispatchCardVisible` resolver, unchanged.
    ///
    /// MYR-376 — AND EXCLUDES A DORMANT RESERVATION. A ride the owner accepted for
    /// tomorrow is `accepted` today, so status alone put the live dispatch card up
    /// the instant he tapped Accept: "En route to pickup · Thomas" over a parked
    /// car, and a "Picked up" button that the server took, stranding the ride on
    /// "waiting for Thomas to start" for a pickup that had not happened. The gate
    /// is the shared `RideReservation.isLiveRide`, so the card and every other
    /// surface answer this from one predicate.
    var ownerDispatch: RideRequestRecord? {
        guard let held = ownerRequest else { return nil }
        switch held.status {
        case .accepted, .arrived, .enroute, .completed:
            return RideReservation.isLiveRide(held) ? held : nil
        case .pending, .declined: return nil
        }
    }

    /// MYR-220: the latest session/connection failure of the create POST (auth
    /// died mid-session — 401 / auth-shaped 403). Observed by the rider's
    /// `SharedViewerScreen` to surface a calm retry, never a decline.
    private(set) var sessionFailure: RideSessionFailure?

    /// MYR-233: the latest `409 vehicle_unavailable` refusal (create or accept).
    /// Observed by the rider's `SharedViewerScreen` to surface honest messaging
    /// and route toward scheduling — never a decline, never a retry.
    private(set) var vehicleUnavailableFailure: RideVehicleUnavailableFailure?
    /// MYR-316 — see `RideRequestService.scheduleWindowFailure`.
    private(set) var scheduleWindowFailure: RideScheduleWindowFailure?

    // MYR-292's `ActiveRequestOrigin` is DELETED by MYR-325. It tagged the shared
    // slot with "which role put this here" so the adoption guards could widen for
    // the owner without clobbering the rider — the best answer available while one
    // slot served both roles. With the pipelines split there is nothing left to
    // arbitrate: the rider's storage is only ever written by rider actions, so the
    // question the tag answered cannot arise. Keeping it would be dead state
    // (CLAUDE.md "dead-code rule") whose only remaining effect would be to invite a
    // future guard to consult the wrong pipeline again.

    /// MYR-317 — the OWNER's incoming QUEUE: every OTHER still-pending incoming
    /// request, in the server's feed order, waiting behind the one on the card.
    ///
    /// The defect: the owner holds ONE `activeRequest` slot, and `refreshIncoming`
    /// adopted only `page.items.first`. Extra pending requests (several riders, or
    /// several future reservations against the same car) were invisible — nothing
    /// was lost server-side, but the owner had no idea anyone else was waiting, and
    /// the next request surfaced only if a fresh WS frame happened to arrive after
    /// the current one resolved.
    ///
    /// Invariant: this holds ONLY pending requests that are NOT the current one —
    /// entries are removed on adoption (`adoptNextIncoming`) and on remote
    /// resolution (`integrate`), so `waitingIncomingCount` is a straight `count`.
    /// Wire records rather than app records: arrivals come off the wire, and the
    /// mapping to a `RideRequestRecord` (which fills a client-side trip estimate)
    /// is worth doing once, at adoption.
    private(set) var incomingQueue: [RideRequest] = []

    /// MYR-317 — ride ids this session has already RESOLVED: the owner accepted or
    /// declined them, or a frame showed them resolving somewhere else. The incoming
    /// feed is fetched concurrently with those mutations, so a page built before the
    /// decline landed still lists the ride as `requested`; without this filter that
    /// stale page would put a request the owner has already answered back in the
    /// queue — and eventually re-present it as a fresh card (whose Accept would 409).
    /// Session-scoped and small: one id per request the owner handles.
    private var resolvedIncomingIDs: Set<String> = []

    /// MYR-317 — how many pending incoming requests are waiting BEHIND the current
    /// card; drives the muted "+N more waiting" chip on `IncomingRequestSheet`.
    var waitingIncomingCount: Int { incomingQueue.count }

    /// MYR-381 — see the protocol's own note. Bumped in `integrate` for every
    /// frame about a ride carrying `scheduledFor`; the rider's Scheduled tab and
    /// the owner's Drives → Upcoming re-read on it. `&+=` so a very long session
    /// wraps instead of trapping — the VALUE is meaningless, only the change is.
    private(set) var scheduledSurfaceTick = 0

    /// The server-assigned ride id for the RIDER's request (distinct from the
    /// local `activeRequest.id`, which for a rider-submitted ride is a client
    /// UUID until the create POST returns). Rider mutations target this id.
    private var riderServerRideID: String?

    /// MYR-325 — the server-assigned ride id for the OWNER's held request. Always a
    /// real server id: every owner record is built from a WIRE record, so unlike the
    /// rider's there is no client-UUID window. Owner mutations (accept / decline /
    /// picked-up / dropped-off) target this id, which is why an accept fired from
    /// the owner card can never land on the rider's ride by accident.
    private var ownerServerRideID: String?
    /// Cached create-target vehicle (the caller's first owned vehicle).
    private var cachedVehicleID: String?

    /// MYR-218 defect 1: the draft awaiting its DEFERRED create POST during the
    /// booking grace window. Set by `submit`, consumed once by `fireSend` (the
    /// countdown-zero timer OR a send-now tap — whichever lands first), and
    /// cleared by `cancel`. Being non-nil is exactly "the send has not fired
    /// yet", so it also serves as the single-fire guard against a tap racing
    /// the timer.
    private var pendingSend: RideRequestInput?
    /// Countdown-zero auto-send timer, armed at `submit` for `sendWindow` and
    /// disarmed on send-now / cancel / send. Owned by the service (not the
    /// booking view) so a minimize-to-pending-pill mid-countdown still sends,
    /// mirroring how `SimulatedRideRequestService` arms its fallback at submit.
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can cancel it — only
    /// ever touched on the main actor otherwise (same precedent as `eventTask`).
    private nonisolated(unsafe) var sendTask: Task<Void, Never>?

    private let api: any RideRequestAPI
    private let socket: any RideEventStreaming
    /// MYR-396 — the one fact about the owner's live dispatch that survives a
    /// force-quit: its ride id. See `OwnerDispatchPointer.swift` for why a
    /// persisted id is what the contract leaves the client, and
    /// `refreshOwnerDispatch` for the read it enables.
    private let dispatchPointer: any OwnerDispatchPointerStoring
    private let reconcilePolicy: ReconcilePolicy
    /// Length of the booking grace window before the deferred create POST fires
    /// on its own — the same 10s the rider's "Sending request" fill animates
    /// over (`RideRequestTiming.sendFillDuration`). Injected so tests can drive
    /// the countdown-zero auto-send in milliseconds.
    private let sendWindow: Duration
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can cancel it — only ever
    /// touched on the main actor otherwise (same precedent as
    /// `SimulatedRideRequestService`'s timers).
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?

    // MARK: MYR-376/377 — the due-time flip
    //
    // THERE IS NO WS FRAME AT DISPATCH. The reservation sweeper stamps the latch,
    // pushes leg-1 navigation and sends the rider's `ride.due` APNs notification —
    // and that push is the ONLY thing that tells a client the ride went live.
    // A party sitting in the app with notifications off, or simply not tapping the
    // banner, would hold a dormant record until something else happened to refetch
    // it: the owner's card would never appear and the rider's map would never leave
    // the idle banner, which is precisely half of what the client photographed.
    //
    // The client already knows the wall-clock moment the server will act, so it
    // does not poll — it sleeps until that instant and asks ONCE. One task, for the
    // SOONEST due instant across both pipelines, re-armed after every refetch.
    /// `nonisolated(unsafe)` for the same reason `eventTask` is: cancelled from the
    /// nonisolated `deinit`, touched on the main actor everywhere else.
    private nonisolated(unsafe) var dueTask: Task<Void, Never>?
    /// What `dueTask` is currently waiting for, so a re-sync that changes nothing
    /// (the common case — every WS frame calls it) does not cancel and rebuild the
    /// same wait.
    private var armedDue: (rideID: String, at: Date)?
    /// How many more times the armed ride may be re-asked after its due instant has
    /// already passed. Reset whenever `dueRetryKey` changes.
    private var dueRetriesRemaining = 0
    /// `rideID` + due instant, so a DIFFERENT reservation (or the same one moved by
    /// a reschedule) starts with a full retry budget while the same one does not
    /// silently refill its own.
    private var dueRetryKey: String?
    /// MYR-377 — the RIDER's soonest dormant reservation, which by design is in no
    /// pipeline at all (adopting it would hand tomorrow's ride today's map). This
    /// is the only reason the service remembers it: something has to know when to
    /// look again.
    private var riderDueReservation: (rideID: String, at: Date)?
    /// MYR-396 — the OWNER's remembered reservation while it is still DORMANT,
    /// held outside the pipeline for exactly the reason `riderDueReservation` is:
    /// adopting it would put tomorrow's ride on today's card, and something still
    /// has to know when to look again. Before this it could not exist at all — a
    /// relaunch left the owner pipeline empty, so a reservation accepted before the
    /// force-quit had nothing waiting for its due moment on this device.
    private var ownerDueReservation: (rideID: String, at: Date)?

    /// Asked this long AFTER the due instant, so the sweeper's own write has landed
    /// before the client reads.
    static let dueRefetchGrace: TimeInterval = 5
    /// A due instant that has already passed is re-asked on this interval — the
    /// sweeper runs on its own schedule and can be a beat late.
    static let dueRefetchRetryInterval: TimeInterval = 30
    /// …at most this many times. A bounded retry, not a poll: after this the
    /// `ride.due` push and the foreground resume (`refreshDueReservations`) are the
    /// remaining channels, and both are cheaper than a timer that never stops.
    static let dueRefetchMaxRetries = 4

    /// How the INDETERMINATE-create-failure reconcile polls the rider's own ride
    /// list before giving up and declaring a definitive failure (see
    /// `reconcileCreate`). Injected so tests can drive the window fast.
    struct ReconcilePolicy: Sendable {
        var attempts: Int
        var delay: Duration
        /// ~3s window (4 polls, ~1s apart) — generous enough to cover create
        /// write-visibility lag without stranding the rider on a spinner.
        static let live = ReconcilePolicy(attempts: 4, delay: .seconds(1))
    }

    init(
        api: any RideRequestAPI,
        socket: any RideEventStreaming,
        autoStart: Bool = true,
        reconcilePolicy: ReconcilePolicy = .live,
        sendWindow: Duration = .seconds(RideRequestTiming.sendFillDuration),
        dispatchPointer: any OwnerDispatchPointerStoring = UserDefaultsOwnerDispatchPointer()
    ) {
        self.api = api
        self.socket = socket
        self.reconcilePolicy = reconcilePolicy
        self.sendWindow = sendWindow
        self.dispatchPointer = dispatchPointer
        if autoStart { start() }
    }

    deinit {
        sendTask?.cancel()
        eventTask?.cancel()
        dueTask?.cancel()
        let socket = self.socket
        Task { await socket.disconnect() }
    }

    // MARK: Lifecycle

    /// Connect the socket, seed the owner incoming feed, then pump ride frames.
    func start() {
        guard eventTask == nil else { return }
        let socket = self.socket
        eventTask = Task { @MainActor [weak self] in
            await socket.connect()
            let stream = await socket.rideEvents()
            // MYR-230 cold-launch adoption (deliverable 2): before pumping frames,
            // adopt the rider's OWN open instant ride so a rider who force-quit
            // mid-ride (or a fresh session that created nothing this run) relaunches
            // back into the correct pending/tracking state — not the idle greeting.
            //
            // MYR-325 — these two seeds no longer compete. They fill DIFFERENT
            // pipelines, so an owner who also rides now cold-launches into their own
            // ride AND their incoming card, instead of the feed seed being suppressed
            // by whatever the rider happened to be holding.
            await self?.adoptOpenRiderRide()
            // MYR-396 — and the OWNER's own open ride, which no list this client
            // can read will hand back (see `refreshOwnerDispatch`). BEFORE the
            // incoming feed, deliberately: a live dispatch owns the owner's slot
            // and the still-`requested` requests queue behind it, which is exactly
            // the arrangement those same two reads produce when they happen live.
            await self?.refreshOwnerDispatch()
            await self?.refreshIncoming()
            for await event in stream {
                guard let self else { break }
                switch event {
                case .created(let payload): self.applyRemote(rideID: payload.rideRequestId)
                case .statusChanged(let payload): self.applyRemote(rideID: payload.rideRequestId)
                }
            }
        }
    }

    // MARK: RideRequestService

    func submit(_ input: RideRequestInput) {
        // Optimistic: the rider's Review→Booking transition reads `activeRequest`
        // synchronously, so it must be pending the instant this returns. The
        // countdown + real itinerary labels the Booking card animates over all
        // read off this record.
        activeRequest = RideRequestRecord(input: input, status: .pending)
        riderServerRideID = nil

        // MYR-218 defect 1: DEFER the create POST. The client's dual-simulator
        // test caught the owner receiving the request while the rider's
        // "Sending request 7s" fill was still running — because this method used
        // to fire the POST here, at booking entry, making the countdown theater
        // over an already-created server ride. Instead, hold the draft and arm a
        // grace-window timer; the POST fires from `fireSend` at countdown zero,
        // OR earlier if the rider taps "Tap to send now" (`confirmSend`). One
        // idempotent send path either way.
        pendingSend = input
        sendTask?.cancel()
        let window = sendWindow
        sendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.fireSend()
        }
    }

    func confirmSend() {
        // Rider tapped "Tap to send now" (or Reduce Motion flipped the card
        // straight to "sent"). Route through the SAME `fireSend` the
        // countdown-zero timer uses — idempotent, so a tap racing the timer
        // still results in exactly one POST.
        fireSend()
    }

    /// The single, idempotent send trigger (MYR-218 defect 1). Consumes
    /// `pendingSend` — the FIRST caller (countdown-zero timer OR a send-now tap)
    /// wins; any racing second caller finds it `nil` and no-ops, so there is
    /// never a double POST. Carries the ORIGINAL create + MYR-216 failure
    /// classification unchanged, just moved off the booking-entry moment.
    private func fireSend() {
        guard let input = pendingSend else { return }
        pendingSend = nil
        sendTask?.cancel()
        sendTask = nil
        let api = self.api
        Task { @MainActor [weak self] in
            guard let self else { return }
            let vehicleID = await self.resolveVehicleID() ?? input.fleetMemberID
            do {
                let ride = try await api.createRideRequest(Self.createBody(from: input, vehicleId: vehicleID))
                self.riderServerRideID = ride.id
                if let mapped = RideRequestContractMapping.status(ride.status), mapped != .pending {
                    self.applyRemote(rideID: ride.id) // server already advanced it
                }
            } catch {
                // MYR-212 defect 3 (round 2): CLASSIFY the create failure instead
                // of blindly keeping the optimistic pending. The original round-1
                // fix (keep it on ANY error) cured the frozen-"10s"/placeholder
                // Booking card seen when a create that DID land on the server
                // errored client-side — but it over-applied: for a DEFINITIVE
                // failure (the server refused the create, no ride exists) it left
                // the rider staring at "Request sent · Waiting…" forever for a
                // ride that will never be accepted (the client's stuck-card
                // complaint). The decision tree:
                //
                //  DEFINITIVE — a typed HTTP 4xx from the Kit
                //    (`RestError.http` with a 4xx status: 400 invalid_request,
                //    403 forbidden/permission_denied, 409 conflict, …). The
                //    server received and REFUSED the request; no ride was
                //    created. We branch on the TYPED case (FR-7.1), never the
                //    human message. → `failCreateDefinitively()`: transition the
                //    stuck pending to `.declined` so the rider's SharedViewerScreen
                //    surfaces the EXISTING declined affordance (the same
                //    `handleStatusChange(.declined)` path an owner-decline uses —
                //    no new UI) and can retry, rather than a frozen "Waiting…".
                //
                //  INDETERMINATE — transport failure / decode mismatch / invalid
                //    response / a 5xx: the POST MAY have created the ride
                //    (round-1's real bug). Keep the optimistic pending (unchanged)
                //    and run ONE background reconcile that PREFERS a GET of the
                //    rider's own ride list over a blind re-POST (a re-POST
                //    duplicates rides). Found → adopt the server id; nothing after
                //    the window → fall through to the DEFINITIVE path.
                //
                //  SESSION/CONNECTION (MYR-220) — a typed AUTH rejection: the
                //    HS256 backend token expired mid-session (no client refresh
                //    until MYR-193), so the DEFERRED create POST came back 401
                //    (or an auth-shaped 403 carrying `auth_failed`/`auth_timeout`).
                //    The MYR-216 tree above wrongly counted this as a DEFINITIVE
                //    4xx and dropped the rider into `.declined` — "Alex can't take
                //    this ride right now" for a DEAD SESSION (no ride was ever
                //    created). Split it out FIRST (it is a 4xx, so it must be
                //    caught before the definitive branch): keep the request OUT of
                //    `.declined`, clear the stuck optimistic pending, and raise
                //    `sessionFailure` so the rider lands back on a retryable state
                //    with the draft intact + a calm notice. Branch on the TYPED
                //    case (FR-7.1), never the message.
                //  RIDE_ACTIVE (MYR-230, §7.8) — a typed `409 ride_active`: the
                //    rider already holds an OPEN instant ride, so the server refused
                //    this create and rode the existing ride back in the body. This is
                //    NOT a decline and NOT a stuck pending — ADOPT the returned ride
                //    (pending/tracking UI), discarding this draft. It is a 409/4xx,
                //    so like the session split it MUST be caught BEFORE the definitive
                //    branch (which would wrongly drop it into `.declined`).
                //  VEHICLE_UNAVAILABLE (MYR-233, §7.8 / MYR-277) — a typed
                //    `409 vehicle_unavailable`: the target VEHICLE can't take this
                //    ride (it already carries an open instant ride, or it went
                //    in_service/offline between the list fetch and the send). Like
                //    the two splits above this is a 409/4xx, so it MUST be caught
                //    BEFORE the definitive branch, which would drop it into
                //    `.declined` — "Alex can't take this ride right now" is a LIE
                //    about the owner when the car is simply busy. Clear the stuck
                //    optimistic pending and raise `vehicleUnavailableFailure` so the
                //    rider gets honest copy + the scheduling route. NEVER retried:
                //    the identical POST would 409 again (no retry loop).
                //  SERVICE WINDOW (MYR-316) — a typed `400 invalid_request` on a
                //    request that carries a SCHEDULE: the server refused the
                //    pickup time because it falls before the vehicle's
                //    `serviceEstimatedEndAt`. It is a 400, so like the three
                //    splits above it MUST be caught BEFORE the definitive branch,
                //    which would drop it into `.declined` — telling the rider the
                //    owner refused them when in fact the car is still in the shop
                //    is exactly the class of lie MYR-233 removed for `busy`.
                //    Scoped to SCHEDULED creates on purpose: `invalid_request` is
                //    a generic code, and attributing every 400 to a service window
                //    would mislabel real malformed-input failures. An instant
                //    ("Now") request cannot hit this rule at all — it carries no
                //    `scheduledFor` for the server to compare.
                if case RestError.rideActive(let active) = error {
                    await self.adoptRideActive(active)
                } else if Self.isVehicleUnavailable(error) {
                    // MYR-385 — the same arm, carrying WHICH refusal it was, so the
                    // rider's notice can name the time conflict instead of asserting
                    // the car became unavailable. Routing is identical either way.
                    self.failCreateVehicleUnavailable(timeConflict: Self.isTimeConflict(error))
                } else if Self.isScheduleWindowRefusal(error, input: input) {
                    self.failCreateScheduleWindow()
                } else if Self.isSessionFailure(error) {
                    self.failCreateSessionError()
                } else if Self.isDefinitiveCreateFailure(error) {
                    self.failCreateDefinitively()
                } else {
                    await self.reconcileCreate(input: input)
                }
            }
        }
    }

    // MARK: Create-failure classification (MYR-212 defect 3, round 2)

    /// True when a create failure DEFINITIVELY means no ride was created — a
    /// typed HTTP 4xx from the Kit (`RestError.http` with a client-error status).
    /// A 4xx is the server understanding and refusing the create (bad input,
    /// forbidden, lifecycle conflict, rate limit), so retrying the same POST is
    /// futile. Everything else (transport / decode / invalid response / 5xx, and
    /// any non-`RestError`) is INDETERMINATE — the ride might exist, so it routes
    /// to `reconcileCreate`. Branches on the typed `httpStatus`, never the message.
    private static func isDefinitiveCreateFailure(_ error: Error) -> Bool {
        guard let status = (error as? RestError)?.httpStatus else { return false }
        return (400..<500).contains(status)
    }

    /// MYR-220: True when a create failure is an AUTH/SESSION rejection rather
    /// than a semantic refusal — a bare HTTP 401, or a typed auth code
    /// (`auth_failed`/`auth_timeout`, which the backend also carries on an
    /// auth-shaped 403; `RestError.isAuthFailure` matches these). This means the
    /// SESSION is dead (expired token), not that the owner declined — so it must
    /// NOT become `.declined`. Checked BEFORE `isDefinitiveCreateFailure` because
    /// a 401 is itself a 4xx. A generic 403 (`permission_denied`) is NOT auth-
    /// shaped and stays on the definitive path. Branches on the typed case only.
    private static func isSessionFailure(_ error: Error) -> Bool {
        guard let rest = error as? RestError else { return false }
        return rest.isAuthFailure || rest.httpStatus == 401
    }

    /// MYR-233: True when the failure is the typed `409 vehicle_unavailable` —
    /// the VEHICLE can't take this ride. Branches on the Kit's typed helper
    /// (`RestError.isVehicleUnavailable`, which matches the typed code's raw wire
    /// value), never the human message (FR-7.1).
    private static func isVehicleUnavailable(_ error: Error) -> Bool {
        (error as? RestError)?.isVehicleUnavailable == true
    }

    /// MYR-385: True when that same `409 vehicle_unavailable` carries `subCode:
    /// time_conflict` — MYR-383's per-vehicle window gate, i.e. the car is free but
    /// the HOUR is taken.
    ///
    /// A STRICT NARROWING of the predicate above, so the routing is unchanged and
    /// only the copy gets to be specific. Branches on the Kit's typed helper
    /// (`RestError.isTimeConflict`), never the human message (FR-7.1) — even though
    /// that message is the only thing naming the conflicting instant.
    private static func isTimeConflict(_ error: Error) -> Bool {
        (error as? RestError)?.isTimeConflict == true
    }

    /// MYR-316: True when the failure is a typed `400 invalid_request` on a ride
    /// that carries a SCHEDULE — i.e. the server's service-window refusal.
    ///
    /// Branches on the typed status + code, NEVER the human message (FR-7.1),
    /// even though that message is the only thing that names the estimated end.
    /// The narrowing to scheduled requests is what keeps this from swallowing
    /// genuine malformed-input 400s: an on-demand create has no `scheduledFor`,
    /// so the server has nothing to compare a window against and this rule cannot
    /// have fired.
    private static func isScheduleWindowRefusal(_ error: Error, input: RideRequestInput) -> Bool {
        guard input.schedule != nil, let rest = error as? RestError else { return false }
        guard case .http(let status, let code, _, _) = rest else { return false }
        return status == 400 && code?.rawValue == "invalid_request"
    }

    /// MYR-316 SERVICE-WINDOW create failure: the server refused the create
    /// because the requested pickup precedes the car's estimated return, so NO
    /// ride was created. Clear the stuck optimistic pending WITHOUT touching
    /// `.declined` (nobody declined) and raise a fresh `scheduleWindowFailure`.
    /// The rider's DRAFT lives in `SharedViewerState` and is untouched, so
    /// re-picking a time keeps the whole trip. Never auto-retried: the identical
    /// POST would 400 again.
    private func failCreateScheduleWindow() {
        guard let request = activeRequest, request.status == .pending else { return }
        activeRequest = nil
        riderServerRideID = nil
        scheduleWindowFailure = RideScheduleWindowFailure()
    }

    /// MYR-233 VEHICLE_UNAVAILABLE create failure: the server refused the create
    /// because the car is busy / in service / offline, so NO ride was created.
    /// Clear the stuck optimistic pending (no frozen "Waiting…", no false
    /// "Ride declined") WITHOUT touching `.declined`, and raise a fresh
    /// `vehicleUnavailableFailure` for the rider's `SharedViewerScreen`. The
    /// DRAFT lives in `SharedViewerState` and is untouched, so the rider can
    /// schedule the very same trip in one tap. No-op if the request was
    /// cancelled or already moved on.
    private func failCreateVehicleUnavailable(timeConflict: Bool = false) {
        guard let request = activeRequest, request.status == .pending else { return }
        activeRequest = nil
        riderServerRideID = nil
        vehicleUnavailableFailure = RideVehicleUnavailableFailure(isTimeConflict: timeConflict)
    }

    /// DEFINITIVE create failure: the optimistic pending describes a ride that
    /// does not (and won't) exist. Transition it to `.declined` so the rider's
    /// `SharedViewerScreen` reacts through the SAME reactive path as an
    /// owner-decline (`handleStatusChange(.declined)` → `DeclinedNotice` over
    /// Search) — the stuck "Request sent · Waiting…" pill/countdown is gone and
    /// the rider can retry. No-op if the request was cancelled or already moved on.
    private func failCreateDefinitively() {
        guard var request = activeRequest, request.status == .pending else { return }
        request.status = .declined
        activeRequest = request
        riderServerRideID = nil
    }

    /// MYR-220 SESSION/CONNECTION create failure: the token died mid-session, so
    /// the create POST was rejected before any ride was created — this is NOT an
    /// owner decline. Clear the stuck optimistic pending (no false "Ride declined"
    /// card, no frozen "Waiting…") WITHOUT touching `.declined`, and raise a fresh
    /// `sessionFailure` for the rider's `SharedViewerScreen` to surface a calm
    /// retry notice + drop back to a retryable state. The rider's DRAFT lives in
    /// `SharedViewerState` and is untouched, so the retry re-uses the same trip.
    /// No-op if the request was cancelled or already moved on.
    private func failCreateSessionError() {
        guard let request = activeRequest, request.status == .pending else { return }
        activeRequest = nil
        riderServerRideID = nil
        sessionFailure = RideSessionFailure()
    }

    /// INDETERMINATE create failure: discover whether the server actually created
    /// the ride WITHOUT a blind re-POST (which would duplicate rides). Poll the
    /// rider's own ride list (`GET /api/ride-requests`, newest first) for a
    /// request matching this submission; found → adopt its server id + fold its
    /// status onto the optimistic record. If nothing surfaces within the window,
    /// the create truly never landed → definitive path.
    private func reconcileCreate(input: RideRequestInput) async {
        let since = activeRequest?.requestedAt ?? Date()
        for attempt in 0..<reconcilePolicy.attempts {
            if attempt > 0 { try? await Task.sleep(for: reconcilePolicy.delay) }
            // Stop if the rider cancelled, or a WS `ride_request_created` frame
            // already adopted the ride out from under us.
            guard activeRequest?.status == .pending, riderServerRideID == nil else { return }
            guard let page = try? await api.rideRequests(cursor: nil, limit: 20) else { continue }
            if let match = page.items.first(where: { Self.matchesSubmission($0, input: input, since: since) }) {
                riderServerRideID = match.id
                integrate(match) // keeps the richer local draft input, folds status/id
                return
            }
        }
        failCreateDefinitively()
    }

    /// A wire ride IS this submission when its pickup+dropoff coordinates match
    /// the draft (tight epsilon) and it was created no earlier than our optimistic
    /// timestamp — enough to disambiguate our just-POSTed ride from older rides to
    /// the same places in the single-account demo. Cancelled/terminal rows are
    /// never a match (a fresh create is never already terminal).
    private static func matchesSubmission(_ ride: RideRequest, input: RideRequestInput, since: Date) -> Bool {
        guard RideRequestContractMapping.status(ride.status) != nil else { return false }
        if let created = RideRequestContractMapping.parseISO(ride.createdAt),
           created < since.addingTimeInterval(-5) { return false }
        return coordinatesMatch(ride.pickup, input.pickup.coordinate)
            && coordinatesMatch(ride.dropoff, input.destination.coordinate)
    }

    private static func coordinatesMatch(_ wire: MyRobotaxiContracts.RidePlace, _ coord: CLLocationCoordinate2D) -> Bool {
        abs(wire.lat - coord.latitude) < 1e-4 && abs(wire.lng - coord.longitude) < 1e-4
    }

    /// OWNER "Accept & send" — the incoming card becomes this owner's DISPATCH.
    /// MYR-325: reads and writes the OWNER pipeline only. The rider half of a
    /// self-created ride (same account, both roles) learns through `integrate` when
    /// the server's `ride_status_changed` frame lands — never by this method
    /// reaching across into the rider's record, which is exactly the coupling that
    /// made one slot serve two roles in the first place.
    func accept() {
        guard var request = ownerRequest, request.status == .pending else { return }
        request.status = .accepted
        request.acceptedAt = Date()
        if request.input.schedule == nil {
            request.trackProgress = RideRequestTiming.autoAcceptInitialProgress
        }
        // MYR-396 — the accept is the moment the owner becomes responsible for this
        // ride, so it is also the moment the pointer has to exist: a force-quit in
        // the second before the server's own record comes back must still leave the
        // relaunch something to ask about.
        setOwnerRequest(request)
        // MYR-277 C: the backend now 409s an accept for an in_service/offline
        // vehicle (parallel PR). A swallowed error would strand the owner on a
        // phantom "accepted" — so reconcile on failure instead of fire-and-forget.
        reconcileAcceptOnFailure()
        // MYR-317: the accepted ride now owns the owner's slot, so `canAdoptIncoming`
        // makes the adoption half a no-op — but the queue must still be re-read,
        // because the card the owner just cleared changed how many wait behind it.
        markIncomingResolved()
        advanceIncoming()
    }

    /// MYR-277 C: POST the accept; on SUCCESS fold the returned record. On ANY
    /// error — notably a 409 when the target
    /// vehicle went in_service/offline and the backend refuses the dispatch —
    /// REFETCH the authoritative record and fold it: a still-`requested` ride folds
    /// back to `.pending`, re-showing the incoming sheet (clean, tappable — the
    /// sheet resets its sending/sent choreography on the id round-trip) instead of
    /// leaving the owner stuck. If even the refetch fails, revert to pending.
    private func reconcileAcceptOnFailure() {
        guard let id = ownerServerRideID else { return } // nothing held to accept
        let api = self.api
        Task { @MainActor [weak self] in
            do {
                // MYR-325: fold the 200, exactly as `advanceMutation` folds every
                // other lifecycle POST. It used to be discarded, which was harmless
                // while one slot served both roles — the optimistic accept was
                // already visible to the rider. With the pipelines split, this
                // response is the authoritative record that carries the accept back
                // to the RIDER half of a self-created ride without waiting on a WS
                // frame; `integrate` routes it to whichever pipelines hold that id.
                let ride = try await api.acceptRideRequest(id: id)
                self?.integrate(ride)
            } catch {
                // MYR-233: a typed `409 vehicle_unavailable` here is the SPECIFIC
                // reason MYR-277 C added this reconcile — the car went busy /
                // in_service / offline, so the dispatch was refused. Raise the
                // honest notice alongside the existing reconcile (which still folds
                // the authoritative record / reverts), so the single-account demo's
                // rider-who-also-accepts gets the same honest copy + scheduling
                // route as the create path instead of a silent snap-back. Still no
                // retry: the same POST would 409 again.
                if Self.isVehicleUnavailable(error) {
                    self?.vehicleUnavailableFailure = RideVehicleUnavailableFailure(
                        isTimeConflict: Self.isTimeConflict(error) // MYR-385
                    )
                }
                // MYR-316 — the ACCEPT half of the service-window refusal. An
                // owner accepting a SCHEDULED request whose pickup precedes the
                // car's estimated return gets the same typed 400, and the same
                // honest notice + re-pick route as the create path, rather than a
                // silent snap-back to the incoming card with no explanation. Same
                // scoping rule: only for a request that actually carries a
                // schedule. Still no retry — the same POST would 400 again.
                if let input = self?.ownerRequest?.input, Self.isScheduleWindowRefusal(error, input: input) {
                    self?.scheduleWindowFailure = RideScheduleWindowFailure()
                }
                if let ride = try? await api.rideRequest(id: id) {
                    self?.integrate(ride)
                } else {
                    self?.revertOptimisticAccept()
                }
            }
        }
    }

    /// Undo an optimistic accept the server never confirmed (a 409 whose refetch
    /// also failed), restoring the pending incoming card (MYR-277 C). Guards on the
    /// optimistic `.accepted` so a WS frame that already moved the ride on is never
    /// clobbered.
    private func revertOptimisticAccept() {
        guard var request = ownerRequest, request.status == .accepted else { return }
        request.status = .pending
        request.acceptedAt = nil
        request.trackProgress = nil
        setOwnerRequest(request)
    }

    /// OWNER declines. MYR-325: the OWNER pipeline only — the rider's own
    /// `DeclinedNotice` for a self-created ride arrives through `integrate` on the
    /// server's frame, which is also what makes it correct on a second device.
    func decline() {
        guard var request = ownerRequest, request.status == .pending else { return }
        request.status = .declined
        setOwnerRequest(request)
        postOwnerMutation { try await $0.declineRideRequest(id: $1) }
        // MYR-306 + MYR-317: a declined request releases the owner's slot, so the
        // next waiting request surfaces on the very next frame — instead of the old
        // behaviour, where the `.declined` record jammed adoption until the app was
        // relaunched (MYR-306) and any queued rider stayed invisible.
        //
        // MYR-325 removes the caveat that used to live here: a decline the RIDER is
        // looking at can no longer block this, because it is not in this storage.
        markIncomingResolved()
        advanceIncoming()
    }

    // MARK: MYR-270 — owner-driven dispatch v2 (picked-up / start / dropped-off)
    //
    // Each is the optimistic-then-reconcile analog of accept/decline for a lifecycle
    // advance the owner or rider triggers: flip the local status (and, where relevant,
    // the leg tracking anchor) synchronously so the sheet reacts with the same timing
    // as the sim, then POST + reconcile. A 200 (the advance OR the idempotent
    // already-there no-op) folds the returned record; a 409 (wrong state) or transient
    // failure REFETCHES the authoritative record; a double failure (POST AND refetch)
    // reverts the optimistic flip so the party is not stranded on a phantom state the
    // car never entered (MYR-265 review — reset the optimistic advance when the server
    // never confirmed it). Never an auto-retry of the same POST (§7.8).

    /// OWNER "Picked up" — `accepted → arrived`. No nav push here (that is `start`).
    /// MYR-325: an OWNER CTA, so it advances the OWNER pipeline.
    func pickedUp() {
        guard var request = ownerRequest, request.status == .accepted else { return }
        request.status = .arrived
        setOwnerRequest(request)
        advanceMutation(.owner, revertTo: .accepted) { try await $0.pickedUp(rideID: $1) }
    }

    /// RIDER "Start ride" — `arrived → enroute`. The server pushes the dropoff nav.
    /// Seeds the leg-2 anchor optimistically so the rider's sheet advances to leg 2
    /// the instant this returns (v1 has no per-second ticker).
    func startRide() {
        guard var request = activeRequest, request.status == .arrived else { return }
        request.status = .enroute
        if request.input.schedule == nil {
            request.trackProgress = max(request.trackProgress ?? 0, request.enrouteSeedProgress)
        }
        activeRequest = request
        advanceMutation(.rider, revertTo: .arrived) { try await $0.start(rideID: $1) }
    }

    /// OWNER "Dropped off" — `enroute → completed`. MYR-325: an OWNER CTA, so it
    /// advances the OWNER pipeline; the rider's summary follows on the frame.
    func droppedOff() {
        guard var request = ownerRequest, request.status == .enroute else { return }
        request.status = .completed
        if request.input.schedule == nil { request.trackProgress = 1 }
        setOwnerRequest(request)
        advanceMutation(.owner, revertTo: .enroute) { try await $0.droppedOff(rideID: $1) }
    }

    /// Shared optimistic-advance reconcile (MYR-270). POST the action; a 200 folds the
    /// returned record; any error REFETCHES the authoritative record and folds it (so
    /// an already-advanced ride settles on its true state while a genuinely failed
    /// advance reverts). A double failure (POST AND refetch) reverts the optimistic
    /// flip to `previous` — the server never advanced, so no `ride_status_changed`
    /// frame will arrive to correct it; a re-tap is an idempotent 200 and the WS
    /// re-confirms the real state.
    /// MYR-325 — `pipeline` names WHOSE record was optimistically advanced, so the
    /// POST targets that pipeline's server id and a double failure reverts that
    /// pipeline's record. It is not a routing hint for the RESULT: the returned /
    /// refetched record goes through `integrate`, which folds it into every pipeline
    /// holding that ride id — so a self-created ride's rider half is reconciled by
    /// the owner's advance for free, through an authoritative record.
    private func advanceMutation(
        _ pipeline: Pipeline,
        revertTo previous: RideRequestStatus,
        _ op: @escaping @Sendable (any RideRequestAPI, String) async throws -> RideRequest
    ) {
        guard let id = serverID(pipeline) else { return } // create not yet acknowledged
        let api = self.api
        Task { @MainActor [weak self] in
            do {
                let ride = try await op(api, id)
                self?.integrate(ride)
            } catch {
                if let ride = try? await api.rideRequest(id: id) {
                    self?.integrate(ride)
                } else {
                    self?.revertOptimisticAdvance(pipeline, to: previous)
                }
            }
        }
    }

    /// Undo an optimistic advance the server never confirmed, restoring the prior
    /// status + its leg tracking anchor (MYR-270).
    private func revertOptimisticAdvance(_ pipeline: Pipeline, to previous: RideRequestStatus) {
        guard var request = record(pipeline) else { return }
        request.status = previous
        if request.input.schedule == nil {
            switch previous {
            case .accepted, .arrived: request.trackProgress = RideRequestTiming.autoAcceptInitialProgress
            case .enroute: request.trackProgress = request.enrouteSeedProgress
            default: break
            }
        }
        setRecord(request, pipeline)
    }

    // MARK: MYR-325 — pipeline addressing
    //
    // The two pipelines are separate STORAGE, but their optimistic-advance and
    // reconcile MECHANICS are identical, so the shared helpers take the pipeline as
    // a parameter rather than being written twice (CLAUDE.md "reuse, don't fork").
    // Deliberately private and tiny: nothing outside this file should be able to
    // address a pipeline generically — the screens read the role-named projections.

    private enum Pipeline { case rider, owner }

    private func record(_ pipeline: Pipeline) -> RideRequestRecord? {
        pipeline == .rider ? activeRequest : ownerRequest
    }

    private func setRecord(_ value: RideRequestRecord?, _ pipeline: Pipeline) {
        if pipeline == .rider { activeRequest = value } else { setOwnerRequest(value) }
    }

    // MARK: MYR-396 — the OWNER slot has ONE write path, and the pointer follows it
    //
    // `refreshOwnerDispatch` can only ask about a ride whose id this device wrote
    // down before it died, so "when is the pointer written" has to be a fact about
    // the pipeline rather than a list of call sites somebody keeps up to date.
    // MYR-389's lesson, stated there about draft resets, is the general one:
    // *exit-side cleanup is only ever as complete as the exit list was on the day
    // it was written.* So every write to the owner slot goes through this one
    // setter, and the pointer is derived from the slot — a new owner mutation
    // cannot forget to keep it, because it has nowhere else to write.

    /// Assign the OWNER slot (and, when the caller has one, its server id) and make
    /// the persisted pointer agree.
    private func setOwnerRequest(_ value: RideRequestRecord?, serverID: String? = nil) {
        if let serverID { ownerServerRideID = serverID }
        ownerRequest = value
        syncOwnerDispatchPointer()
    }

    /// Make the pointer agree with the OWNER slot.
    ///
    /// It is written for every status the owner is ON THE HOOK for — `accepted`
    /// through `enroute` — which deliberately INCLUDES a dormant reservation: that
    /// ride is the owner's, it simply is not happening yet, and its due moment is
    /// the very thing a later launch has to be able to notice (MYR-376's
    /// time-bounded dormancy).
    ///
    /// A `pending` record UN-writes it, which is the MYR-277 C revert: an accept the
    /// server refused leaves a still-`requested` ride the incoming feed restores
    /// authoritatively, and a pointer naming it would be one wasted read per launch
    /// until it expired. The clear is guarded on the ID, so the ordinary case — a
    /// fresh incoming card adopted while a dormant reservation is remembered —
    /// cannot erase the reservation.
    ///
    /// **An EMPTY slot clears nothing**, and that asymmetry is the point: the
    /// pointer's whole job is to outlive a process that has no slot at all, so
    /// "there is no record in memory" is never evidence about a ride. Clearing is a
    /// statement about the RIDE, made only where one is known to be over — the
    /// terminal arm below, `retireOwnerRide`, `refreshOwnerDispatch`, and sign-out.
    private func syncOwnerDispatchPointer() {
        guard let held = ownerRequest else { return }
        let id = ownerServerRideID ?? held.id
        switch held.status {
        case .accepted, .arrived, .enroute: dispatchPointer.write(rideID: id)
        case .completed, .declined, .pending: forgetOwnerDispatch(rideID: id)
        }
    }

    /// Forget the pointer if — and only if — it names this ride. Guarded so a
    /// terminal record for some OTHER ride (a stale queued row resolving elsewhere)
    /// cannot erase the dispatch the owner is actually driving.
    private func forgetOwnerDispatch(rideID: String) {
        if ownerDueReservation?.rideID == rideID { ownerDueReservation = nil }
        guard dispatchPointer.read() == rideID else { return }
        dispatchPointer.clear()
    }

    /// MYR-396 — see `RideRequestService.forgetOwnerDispatch`. The pointer is a
    /// SINGLE record on a device that holds exactly one session (the same reasoning
    /// `UserDefaultsProfileStore` is written on), so it is released with the
    /// session and the next account never inherits the previous one's ride.
    func forgetOwnerDispatch() {
        ownerDueReservation = nil
        dispatchPointer.clear()
    }

    private func serverID(_ pipeline: Pipeline) -> String? {
        pipeline == .rider ? riderServerRideID : ownerServerRideID
    }

    func cancel() {
        // MYR-218 defect 1: a cancel DURING the grace window (before the
        // deferred POST fired) must make ZERO server calls — no ride exists yet.
        // Disarm the auto-send and drop the held draft, then discard locally.
        // `riderServerRideID` is still nil at that point, so the guard below no-ops
        // the remote cancel; after the send it is set and cancel keeps its
        // existing remote behavior.
        sendTask?.cancel()
        sendTask = nil
        pendingSend = nil
        let id = riderServerRideID
        activeRequest = nil
        riderServerRideID = nil
        // MYR-325 same-account duality: this device's OWNER pipeline may be showing
        // an incoming card for the very ride the rider just cancelled (that is the
        // deliberate decision — see `integrate`). Retire it here rather than waiting
        // for the cancellation frame, or the owner half of the client's own account
        // is left holding a phantom request whose Accept would 409.
        if let id { retireOwnerRide(id: id) }
        armDueRefetch() // MYR-376 — nothing left to wait for on a cancelled ride
        guard let id else { return }
        let api = self.api
        Task { _ = try? await api.cancelRideRequest(id: id) }
    }

    /// MYR-397 — the AWAITED cancel for a ride that is already running.
    ///
    /// Deliberately the mutation and nothing else: it makes the call, lets the Kit's
    /// error out, and touches NO local state. Everything the optimistic `cancel()`
    /// above does — clearing `activeRequest`, retiring the owner-side twin,
    /// re-arming the due refetch — happens here through the normal reconciliation
    /// path instead, because the ride is only over once the server says so. On
    /// success the caller's `refreshActiveRide()` re-reads and `integrate` maps the
    /// wire's `cancelled` to the record disappearing (MYR-172), which is the same
    /// erasure by the route that can be trusted.
    ///
    /// One local effect is kept and it is not optimism: the deferred create is
    /// disarmed, because a send that has not gone out yet must not go out after a
    /// cancel has been asked for.
    func cancelActiveRide(id: String) async throws {
        sendTask?.cancel()
        sendTask = nil
        pendingSend = nil
        _ = try await api.cancelRideRequest(id: id)
        // The rider's ride is also this device's OWNER incoming card when the
        // account is both (MYR-325's same-account duality) — retire it here for the
        // same reason `cancel()` does, rather than leaving the owner half holding a
        // phantom request whose Accept would 409.
        retireOwnerRide(id: id)
    }

    func completeAndReset() -> RequestedRide? {
        // v1 has no completed lifecycle (MYR-176/177), so the Ride Summary is
        // unreachable in live mode. Reset defensively; nothing to persist.
        activeRequest = nil
        riderServerRideID = nil
        return nil
    }

    // MARK: Remote reconciliation

    /// A WS frame arrived: refetch the full record and fold it onto `activeRequest`.
    private func applyRemote(rideID: String) {
        let api = self.api
        Task { @MainActor [weak self] in
            guard let ride = try? await api.rideRequest(id: rideID) else { return }
            self?.integrate(ride)
        }
    }

    /// Fold an AUTHORITATIVE server record into whichever pipeline(s) hold that ride.
    ///
    /// MYR-325 — this is the ONE place the rider and owner pipelines meet, and it
    /// meets them only through a record the server confirmed. The two arms run
    /// INDEPENDENTLY, and both may run for the same frame.
    ///
    /// SAME-ACCOUNT DUALITY — the decision, made deliberately rather than inherited:
    /// a ride this device's rider created ALSO surfaces on this device's owner side,
    /// so the two pipelines legitimately hold the SAME ride id.
    ///  • It is what the client actually does. He is owner and rider on one account
    ///    and self-tests every build by requesting a ride and then answering it; a
    ///    suppression rule ("skip rides the rider pipeline owns") would delete the
    ///    incoming card from his primary workflow — and that card presenting is
    ///    precisely what tonight's bug report is about.
    ///  • It is also what the surfaces mean. The rider's booking/pending card and the
    ///    owner's incoming card are DIFFERENT SURFACES answering different questions
    ///    ("has my request gone out?" vs. "will I lend my car?"), on different tabs,
    ///    behind different roles. Two surfaces reading one ride is not duplication.
    ///  • It is safe because neither pipeline WRITES to the other. `accept()` /
    ///    `decline()` mutate only the owner slot and POST on `ownerServerRideID`; the
    ///    rider's half of the same ride is updated here, from the server's record.
    ///    The one place that would otherwise desync is a rider CANCEL, which
    ///    `cancel()` handles explicitly via `retireOwnerRide`.
    ///
    /// The MYR-292/306/317 rider-safety invariants no longer need a guard: an
    /// incoming request cannot displace the rider's Ride Summary or `DeclinedNotice`
    /// because the owner arm never writes `activeRequest`.
    private func integrate(_ ride: RideRequest) {
        // MYR-381 — tell the RESERVATION surfaces something happened, BEFORE the
        // terminal early-return below. A cancelled ride is mapped to no status at
        // all and returns immediately, and a cancelled reservation is precisely the
        // frame the rider's Scheduled tab and the owner's Upcoming list most need:
        // the row has to stop existing. Bumping first is what makes that
        // unmissable rather than a case someone has to remember.
        if ride.scheduledFor != nil { scheduledSurfaceTick &+= 1 }
        guard let mapped = RideRequestContractMapping.status(ride.status) else {
            // Cancelled / unknown-terminal — retire it from BOTH pipelines and from
            // the queue (MYR-317: a rider who cancels while queued must not be
            // surfaced later as a request the owner can still accept).
            if riderHolds(ride.id) { activeRequest = nil; riderServerRideID = nil }
            retireOwnerRide(id: ride.id)
            return
        }
        if riderHolds(ride.id) {
            integrateRider(ride, mapped: mapped)
        } else if activeRequest == nil, RideReservation.isAdoptableLiveRide(ride) {
            // MYR-377 — A RESERVATION THAT JUST WENT LIVE HAS NOBODY HOLDING IT.
            //
            // A dormant reservation is deliberately never in the rider's active
            // slot (it would replace "Where to?" with a tracking map for a ride
            // that is tomorrow), so when the sweeper dispatches it and the ride
            // reaches `arrived`, the `ride_status_changed` frame arrives about a
            // ride NEITHER pipeline holds — and, before this issue, was dropped on
            // the floor. That is why the client's rider side showed the idle
            // in-service banner with no tracking card and no "Start ride": the one
            // control that can move `arrived → enroute` was never rendered, so the
            // flow simply deadlocked.
            //
            // Adoption goes through `adoptOpenRiderRide`, i.e. through
            // `GET /api/ride-requests` — the AUTHENTICATED RIDER'S OWN list — and
            // not straight off the frame. The ride stream is account-wide and this
            // device serves both roles, so a frame about a ride is not evidence
            // that this device's RIDER is the one taking it; on an owner-only
            // account, adopting off the frame would put someone else's ride on the
            // owner's rider map. Asking the rider's own list answers exactly the
            // question being asked, with the machinery cold launch already uses.
            Task { @MainActor [weak self] in await self?.adoptOpenRiderRide() }
        }
        integrateOwner(ride, mapped: mapped)
        armDueRefetch()
    }

    // MARK: MYR-376/377 — arm the due-time refetch

    /// Re-evaluate what (if anything) this service is waiting for.
    ///
    /// Idempotent and cheap: it runs after every fold and every adoption, and when
    /// the answer has not changed it returns without touching the armed task. That
    /// matters because a live dispatch's frames arrive several per minute, and
    /// rebuilding a `Task.sleep` on each of them would be a timer that never
    /// actually reaches its deadline.
    ///
    /// Deliberately ONE task for BOTH pipelines' soonest due instant rather than
    /// one per pipeline: on the client's own account the two hold the SAME
    /// reservation (`integrate`'s same-account duality), so a per-pipeline timer
    /// would fire two refetches of one ride at the same second.
    private func armDueRefetch(now: Date = Date()) {
        let held = [activeRequest, ownerRequest]
            .compactMap { $0 }
            .compactMap { record in RideReservation.dueInstant(record).map { (rideID: record.id, at: $0) } }
        // MYR-396 adds the OWNER's dormant reservation to the same single timer,
        // for the same reason the rider's is here: it is deliberately in no
        // pipeline, so `held` cannot see it.
        let due = (held + [riderDueReservation, ownerDueReservation].compactMap { $0 })
            .min { $0.at < $1.at }

        guard let due else {
            // Nothing dormant is held — the reservation dispatched, was declined,
            // or was cancelled. Stop waiting.
            dueTask?.cancel()
            dueTask = nil
            armedDue = nil
            dueRetriesRemaining = 0
            dueRetryKey = nil
            return
        }

        if let armed = armedDue, armed.rideID == due.rideID, armed.at == due.at, dueTask != nil { return }

        let key = "\(due.rideID)|\(due.at.timeIntervalSince1970)"
        if key != dueRetryKey {
            dueRetryKey = key
            dueRetriesRemaining = Self.dueRefetchMaxRetries
        }

        dueTask?.cancel()
        let lead = due.at.timeIntervalSince(now) + Self.dueRefetchGrace
        guard lead <= 0 else {
            // The ordinary case: the moment is ahead of us. Sleep to it and ask
            // once, with the retry budget held in reserve for a late sweeper.
            armedDue = due
            scheduleDueRefetch(rideID: due.rideID, after: lead)
            return
        }
        // The moment has PASSED and the ride is still dormant — the sweeper has not
        // written yet (or this record predates its write). Re-ask on the bounded
        // retry rather than immediately, which would be a tight poll wearing a
        // timer's clothes.
        armOverdueRetry(rideID: due.rideID, at: due.at)
    }

    /// Sleep, then ask the server for exactly one ride. The refetch routes through
    /// `applyRemote` → `integrate` → `armDueRefetch`, so a reservation that HAS
    /// dispatched disarms itself and one that has not is re-armed on the bounded
    /// retry interval.
    private func scheduleDueRefetch(rideID: String, after delay: TimeInterval) {
        dueTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.dueTask = nil
            // Clear the arm BEFORE the refetch so the fold's own `armDueRefetch`
            // sees a free slot; the retry decrement below is what stops it from
            // re-arming forever on a sweeper that never runs.
            self.armedDue = nil
            // MYR-396 — a reservation NOBODY HOLDS wakes through the owner
            // adoption rather than through `applyRemote`. `integrateOwner` has no
            // arm for a non-pending ride the pipeline does not hold — it reads that
            // as a queued row resolving elsewhere and drops it — so a plain refetch
            // would fetch the record and throw it away. `refreshOwnerDispatch` is
            // the one path that can take it, and it re-arms (or gives up on the
            // bounded retry) by itself.
            if self.ownerDueReservation?.rideID == rideID, !self.ownerHolds(rideID) {
                await self.refreshOwnerDispatch()
                self.armDueRefetch()
                return
            }
            self.applyRemote(rideID: rideID)
        }
    }

    /// The bounded retry: called by `armDueRefetch` through `applyRemote`'s fold
    /// when a ride whose due instant has PASSED is still dormant.
    private func armOverdueRetry(rideID: String, at instant: Date) {
        guard dueRetriesRemaining > 0 else { return }
        dueRetriesRemaining -= 1
        armedDue = (rideID, instant)
        scheduleDueRefetch(rideID: rideID, after: Self.dueRefetchRetryInterval)
    }

    /// MYR-376/377 — the FOREGROUND half, and the one a suspended timer cannot do.
    ///
    /// A `Task.sleep` does not run while the app is suspended, so a reservation that
    /// came due overnight is still dormant on this device when the owner opens the
    /// app in the morning. `RootView` calls this on every `.active` transition,
    /// beside the existing push re-arm and Live Activity re-evaluation: it refetches
    /// every held reservation whose moment has arrived, and re-arms whatever is
    /// still ahead. A no-op — no fetch at all — when nothing dormant is held, which
    /// is every session that is not sitting on a reservation.
    func refreshDueReservations() async {
        let now = Date()
        var ids = [activeRequest, ownerRequest]
            .compactMap { $0 }
            .filter { record in RideReservation.dueInstant(record).map { $0 <= now } == true }
            .map(\.id)
        // The rider's own next reservation is held OUTSIDE both pipelines by design
        // (see `riderDueReservation`), so it needs naming here explicitly.
        if let riderDue = riderDueReservation, riderDue.at <= now { ids.append(riderDue.rideID) }
        for id in Set(ids) {
            if let ride = try? await api.rideRequest(id: id) { integrate(ride) }
        }
        // MYR-396 — the OWNER's own dormant reservation, which is likewise in no
        // pipeline and, like the cold-launch case, can only be TAKEN by the owner
        // adoption. `refreshOwnerDispatch` makes no request unless the pointer
        // still names a ride this pipeline is not already holding.
        if let ownerDue = ownerDueReservation, ownerDue.at <= now, !ownerHolds(ownerDue.rideID) {
            await refreshOwnerDispatch()
        }
        // Re-read the rider's own list too: a reservation booked on another device
        // since this one went to sleep is invisible until somebody asks.
        if activeRequest == nil { await adoptOpenRiderRide() }
        armDueRefetch(now: now)
    }

    /// The RIDER arm: fold the server record onto the rider's tracked ride in place,
    /// preserving the richer local draft and seeding the per-leg tracking anchor.
    /// Behaviour is byte-for-byte what the single-slot `integrate` did for a rider
    /// record; only the storage it writes is now role-scoped.
    private func integrateRider(_ ride: RideRequest, mapped: RideRequestStatus) {
        // `record(from:)` is non-nil here (it returns nil only for the
        // already-handled cancelled/terminal case in `integrate`).
        let refetched = RideRequestContractMapping.record(from: ride)!
        let current = Self.fold(ride, refetched: refetched,
                                onto: activeRequest ?? refetched,
                                mapped: mapped, seedsTracking: true)
        activeRequest = current
        riderServerRideID = ride.id
    }

    /// The OWNER arm: fold onto the held request, or queue/adopt a new incoming one,
    /// or drop a queued one that resolved elsewhere.
    private func integrateOwner(_ ride: RideRequest, mapped: RideRequestStatus) {
        if ownerHolds(ride.id) {
            let refetched = RideRequestContractMapping.record(from: ride)!
            // `seedsTracking: false` — the owner surfaces read the STATUS, never
            // `trackProgress` (only the rider's tracking sheet does).
            setOwnerRequest(
                Self.fold(ride, refetched: refetched,
                          onto: ownerRequest ?? refetched,
                          mapped: mapped, seedsTracking: false),
                serverID: ride.id)
            // MYR-317 — the held request reached a status that RELEASES the owner's
            // slot (`completed` — the drop-off — or `declined`): surface the next
            // queued request instead of sitting on a dead card until a fresh frame
            // happens to arrive, which is exactly how a waiting rider stayed
            // invisible after ONE ride. Narrowed to those two statuses so a live
            // dispatch's frames don't each re-fetch the feed.
            if mapped == .completed || mapped == .declined { advanceIncoming() }
        } else if mapped == .pending {
            // A pending request this owner has not answered.
            //
            // MYR-317 — it is QUEUED first (deduped by id), so it is counted on the
            // card's "+N more waiting" chip even while another request owns the
            // slot; before, a frame that arrived with the slot occupied was simply
            // dropped and that rider became invisible. Adoption then runs under
            // `canAdoptIncoming` and takes the queue HEAD (server feed order), which
            // for a free slot is this very ride.
            //
            // MYR-325 — this arm no longer asks whether the RIDER pipeline holds the
            // ride. It used to (as `else if` on a shared `isCurrent`), which is why a
            // self-created ride could never reach the owner card independently, and
            // why a held rider record starved every other owner's request.
            enqueueIncoming(ride)
            adoptNextIncoming()
        } else {
            // MYR-317 — a QUEUED request resolved remotely (another device accepted
            // or declined it, it ran, it completed): drop it from the queue so the
            // owner is never advanced onto a request nobody is waiting on.
            dequeueIncoming(id: ride.id)
        }
    }

    /// Fold an authoritative wire record onto a held app record. Shared by both
    /// pipelines so the identity/place/status reconciliation cannot drift between
    /// them; `seedsTracking` is the only difference (the rider's per-leg anchor).
    private static func fold(
        _ ride: RideRequest,
        refetched: RideRequestRecord,
        onto held: RideRequestRecord,
        mapped: RideRequestStatus,
        seedsTracking: Bool
    ) -> RideRequestRecord {
        var current = held
        current.status = mapped
        current.acceptedAt = ride.acceptedAt.flatMap(RideRequestContractMapping.parseISO)
        // MYR-376/377 — adopt the DISPATCH LATCH from the authoritative record.
        //
        // This is the line that ends dormancy. The sweeper's stamp arrives on a
        // refetch (the due-time one below, a push tap, a `ride_status_changed`
        // frame, a foreground resume), and if the fold dropped it the held record
        // would stay dormant forever while the server considered the ride live —
        // the same class of stale-read defect MYR-316 shipped and MYR-362 traced.
        // Taken from `refetched` rather than re-parsed here so there is one
        // wire→record rule (`RideRequestContractMapping.record(from:)`) and not a
        // second reading of the same three keys.
        current.scheduledFor = refetched.scheduledFor
        current.dispatchStatus = refetched.dispatchStatus
        current.dispatchedAt = refetched.dispatchedAt
        // MYR-277 A1: in the single-account demo the rider's optimistic draft
        // carries NO requesterName (the rider never stamps their own display
        // name) and may carry placeholder place labels; the refetched server
        // record is authoritative for identity. Refresh those fields from it
        // WITHOUT downgrading a richer local value, so the owner card shows the
        // real "<Name> wants a ride" instead of the neutral "Shared viewer".
        // Prefer a non-empty refetched name; never overwrite a known name with
        // nil OR an empty string (MYR-277 review — symmetric with preferRicherPlace).
        if let name = ride.requesterName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            current.input.requesterName = name
        }
        current.input.pickup = preferRicherPlace(local: current.input.pickup, refetched: refetched.input.pickup)
        current.input.destination = preferRicherPlace(local: current.input.destination, refetched: refetched.input.destination)
        // MYR-265: seed the per-leg tracking anchor so a WS-driven status change
        // moves the rider's sheet to the matching leg (v1 has no live ticker).
        guard seedsTracking, current.input.schedule == nil else { return current }
        switch mapped {
        case .accepted, .arrived:
            // Live has no per-second ticker, so an accepted/arrived ride's
            // anchor is always the static leg-1 seed (car at/approaching the
            // pickup). Set it unconditionally so an advance that FAILED
            // (optimistic enroute reverting on the refetch) also rewinds the
            // anchor back to leg 1 — not just when it was nil. The rider's
            // arrived "Your car is here" stage reads off the STATUS itself.
            current.trackProgress = RideRequestTiming.autoAcceptInitialProgress
        case .enroute:
            current.trackProgress = max(current.trackProgress ?? 0, current.enrouteSeedProgress)
        case .completed:
            current.trackProgress = 1
        default:
            break
        }
        return current
    }

    /// MYR-325 — retire a ride from the OWNER pipeline entirely: out of the queue
    /// (and remembered as resolved, so a stale feed page cannot re-queue it) and, if
    /// it is the held card, off the card, advancing to whatever waits behind it.
    /// Used by a cancellation frame and by the rider's own `cancel()`.
    private func retireOwnerRide(id: String) {
        dequeueIncoming(id: id)
        // MYR-396 — a retired ride is over for this owner however it ended
        // (cancelled by the rider, resolved elsewhere), so nothing should ask about
        // it again. Guarded on the id, so retiring a QUEUED row never forgets the
        // dispatch on the card.
        forgetOwnerDispatch(rideID: id)
        guard ownerHolds(id) else { return }
        ownerServerRideID = nil
        setOwnerRequest(nil)
        advanceIncoming()
    }

    // MARK: MYR-317 — incoming queue mechanics

    /// Add a pending incoming request to the tail of the queue, deduped by id (a
    /// re-delivered frame refreshes the held record in place rather than counting
    /// the same rider twice). Never queues the request already on the card.
    private func enqueueIncoming(_ ride: RideRequest) {
        guard RideRequestContractMapping.status(ride.status) == .pending,
              !ownerHolds(ride.id), !resolvedIncomingIDs.contains(ride.id)
        else { return }
        if let existing = incomingQueue.firstIndex(where: { $0.id == ride.id }) {
            incomingQueue[existing] = ride
        } else {
            incomingQueue.append(ride)
        }
    }

    /// Drop a request from the queue and remember it as resolved, so a stale feed
    /// page cannot re-queue it.
    private func dequeueIncoming(id: String) {
        incomingQueue.removeAll { $0.id == id }
        resolvedIncomingIDs.insert(id)
    }

    /// Replace the queue from a freshly fetched incoming page. The page is the
    /// server's authority on who is still waiting (it returns `requested` rows
    /// only), so entries it omits are gone. A `ride_request_created` frame that
    /// raced this fetch can be missed by one round; the next adoption re-fetches,
    /// and the frame's own `enqueueIncoming` already counted it if it arrived
    /// after the response landed.
    ///
    /// Feed ORDER is preserved exactly as the server returns it (createdAt DESC —
    /// rest-api.md §7.8): the head this adopts is the same record `page.items.first`
    /// adopted before this issue, so nothing about WHICH request surfaces first
    /// changes here. Re-ordering the owner's triage queue (oldest-first vs
    /// soonest-scheduled-first) is a deliberate server-side decision — MYR-317's
    /// telemetry half — not something the client should invent per device.
    private func replaceQueue(with items: [RideRequest]) {
        incomingQueue = items.filter {
            RideRequestContractMapping.status($0.status) == .pending
                && !ownerHolds($0.id)
                && !resolvedIncomingIDs.contains($0.id)
        }
    }

    /// Take the queue HEAD into the OWNER's slot, if that slot may be taken.
    ///
    /// The guard is the SAME `canAdoptIncoming` every other adoption site uses —
    /// deliberately, so the queue can never become a back door around the owner
    /// pipeline's own rule: a live dispatch is never displaced.
    ///
    /// MYR-325 — it writes `ownerRequest`, never `activeRequest`. That single change
    /// is what makes the MYR-292 rider-safety invariants structural: however many
    /// requests are queued, none of them can reach the rider's Ride Summary or
    /// `DeclinedNotice`, because this does not know how to write there.
    @discardableResult
    private func adoptNextIncoming() -> Bool {
        guard canAdoptIncoming else { return false }
        while !incomingQueue.isEmpty {
            let next = incomingQueue.removeFirst()
            guard !ownerHolds(next.id),
                  let record = RideRequestContractMapping.record(from: next),
                  record.status == .pending
            else { continue }
            setOwnerRequest(record, serverID: next.id)
            return true
        }
        return false
    }

    /// Remember the ride the owner just answered (accept/decline) as resolved, so a
    /// feed page that was already in flight can't hand it back as still-waiting.
    private func markIncomingResolved() {
        if let id = ownerServerRideID { resolvedIncomingIDs.insert(id) }
    }

    /// The current card resolved (accepted / declined / completed / cancelled):
    /// surface the next waiting request immediately from the held queue, then
    /// re-fetch the incoming page so the queue (and the badge) stay fresh — a
    /// request that arrived while this device was backgrounded is only visible
    /// through the feed.
    ///
    /// Both halves are guarded: the adoption by `canAdoptIncoming`, so an accept
    /// (a live dispatch now owns the slot) refreshes the count and adopts nothing.
    private func advanceIncoming() {
        adoptNextIncoming()
        Task { @MainActor [weak self] in await self?.refreshIncoming() }
    }

    /// Does the RIDER pipeline track this ride? The local-id fallback covers the
    /// window between `submit` and the create POST's acknowledgement, where the
    /// record still carries a client UUID.
    private func riderHolds(_ rideID: String) -> Bool {
        rideID == riderServerRideID || rideID == activeRequest?.id
    }

    /// Does the OWNER pipeline hold this ride on its card? Owner records are always
    /// built from the wire, so both ids are server ids and this is a plain match.
    private func ownerHolds(_ rideID: String) -> Bool {
        rideID == ownerServerRideID || rideID == ownerRequest?.id
    }

    /// MYR-186 — see `RideRequestService.activeServerRideID`. Prefer the server's
    /// id; fall back to the local one for the window between `submit` and the
    /// create POST's acknowledgement, where no server id exists yet (a push for a
    /// ride the server has not created cannot arrive, so the fallback is only
    /// ever a safe non-match).
    var activeServerRideID: String? { riderServerRideID ?? activeRequest?.id }

    /// MYR-325 — see `RideRequestService.incomingServerRideID`. The OWNER pipeline's
    /// id, which is what a push about an incoming request carries; `activeServerRideID`
    /// is the rider's and would suppress the wrong banner now that they can differ.
    var incomingServerRideID: String? { ownerServerRideID ?? ownerRequest?.id }

    /// MYR-186 — the rider half of push-tap re-sync. Runs the SAME cold-launch
    /// adoption `start()` performs, so a rider who launched from a notification
    /// lands in their open ride's flow.
    ///
    /// **MYR-402 — IT NOW RE-READS BEFORE IT ADOPTS, AND THAT IS THE WHOLE POINT.**
    /// This method used to be `adoptOpenRiderRide()` alone, whose first line is
    /// `guard activeRequest == nil` — so it was ADOPT-ONLY: it could fill an empty
    /// slot and could never empty a full one. The rider's held ride was therefore
    /// releasable by exactly one channel, the WS `ride_status_changed` frame, and a
    /// socket that was down, backgrounded or terminally `auth_failed` (MYR-387's own
    /// finding) left a cancelled ride in the slot for the rest of the session.
    /// `RiderIdleGate.requestInFlight` then held the placeholder shut until the
    /// process died — the force-quit signature, arriving by a second road.
    ///
    /// Two callers were already written as though the re-read happened:
    ///  • **MYR-397's awaited cancel** documents "the caller's `refreshActiveRide()`
    ///    re-reads and `integrate` maps the wire's `cancelled` to the record
    ///    disappearing", then checks `stillStands(status: activeRequest?.status)` —
    ///    against a record nothing had re-read. It reported the local optimistic
    ///    value and happened to be right only because a frame usually followed.
    ///  • **The push tap** (`RootView.applyPushTapRoute`) pokes "the EXISTING
    ///    refresh that repopulates" the rider surface. A `ride.cancelled` push
    ///    tapped by a rider whose socket missed the frame repopulated nothing.
    ///
    /// The re-read goes through `integrate`, deliberately — the SAME fold
    /// `applyRemote` applies to a frame — so a refetched cancellation erases the
    /// slot by the identical code path a frame does, and there is no second
    /// definition of "this ride is over" to drift from the first.
    func refreshActiveRide() async {
        await resyncHeldRiderRide()
        await adoptOpenRiderRide()
    }

    /// MYR-402 — ask the server about the ride this device's rider is DISPLAYING.
    ///
    /// Narrow on purpose, and each guard is load-bearing:
    ///  • **A server id is required.** An optimistic record from a create still in
    ///    its MYR-218 grace window has no server ride to ask about; asking would
    ///    404 and folding a 404 would discard a ride the rider is mid-way through
    ///    booking.
    ///  • **A record must be HELD.** `riderServerRideID` can outlive the record it
    ///    named for a beat; re-integrating then would RESURRECT a summary the rider
    ///    dismissed (`completeAndReset` clears both, but the order is not this
    ///    method's to depend on).
    ///  • **A read that fails changes nothing** — `refreshOwnerDispatch`'s rule
    ///    verbatim (MYR-326: a request that did not answer is not evidence that a
    ///    ride ended). The WS frame remains the primary channel; this is the backstop.
    private func resyncHeldRiderRide() async {
        guard let rideID = riderServerRideID, activeRequest != nil else { return }
        guard let ride = try? await api.rideRequest(id: rideID) else { return }
        integrate(ride)
    }

    /// May a brand-new incoming `pending` request take the OWNER's slot?
    ///
    /// MYR-325 makes this a question about the OWNER pipeline and nothing else —
    /// which is the whole fix. It used to also consult the rider's record (via
    /// `activeRequestOrigin`), because both roles shared one slot; that made the
    /// answer "no" for as long as this device's rider held ANY terminal record, and
    /// an owner who also rides — i.e. the client, i.e. every real owner — went deaf
    /// to incoming requests indefinitely. The rider's Ride Summary and
    /// `DeclinedNotice` are still untouchable, now because adoption cannot write to
    /// their storage rather than because a guard says so.
    ///
    /// Free slot → yes. Otherwise yes only for the two statuses that are TERMINAL
    /// FOR THE OWNER:
    ///  • `completed` (MYR-292) — nothing on the owner path ever clears a completed
    ///    ride. `completeAndReset()` is the RIDER summary's "See you soon", and the
    ///    owner's "Dropped off ✓" acknowledgement is deliberately view-side only
    ///    (MYR-267/292). So the owner would sit on a dead record forever and every
    ///    later frame would be dropped: after ONE completed ride, no more dispatches
    ///    until relaunch.
    ///  • `declined` (MYR-306) — identically, `decline()` leaves the record on
    ///    `.declined` with nothing to clear it. This is also what makes MYR-317's
    ///    decline→advance work at all.
    ///
    /// Deliberately NOT widened for any non-terminal status
    /// (`pending`/`accepted`/`arrived`/`enroute`) — a live dispatch owns the slot and
    /// must never be displaced out from under the owner who is driving it.
    private var canAdoptIncoming: Bool {
        guard let held = ownerRequest else { return true }
        return held.status == .completed || held.status == .declined
    }

    /// MYR-277 A1: prefer the local draft's place, adopting the refetched server
    /// place ONLY when the local one is a placeholder (empty label). Never
    /// downgrades a routed local value (miles/minutes the rider already computed);
    /// only fills a same-device draft that lacked the field.
    private static func preferRicherPlace(local: RidePlace, refetched: RidePlace) -> RidePlace {
        let localEmpty = local.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return localEmpty && !refetched.label.isEmpty ? refetched : local
    }

    // MARK: MYR-230 — adopt the rider's real open ride

    /// Cold-launch adoption (deliverable 2): GET the rider's own ride list
    /// (newest first) and adopt the newest OPEN INSTANT ride into `activeRequest`,
    /// so a relaunch / fresh session lands back in the correct pending/tracking
    /// state instead of the idle greeting. No-op if a request is already tracked
    /// (a create this session, or a WS frame already adopted one).
    private func adoptOpenRiderRide() async {
        guard activeRequest == nil, riderServerRideID == nil else { return }
        guard let page = try? await api.rideRequests(cursor: nil, limit: 20) else { return }
        // MYR-377 — note the rider's soonest DORMANT reservation off the SAME page.
        // It is not adopted (a ride that is tomorrow must not own the map), but the
        // client still needs to know when to look again: dispatch produces no WS
        // frame, only the `ride.due` push, so without this the rider's flip to
        // tracking depends entirely on them tapping a notification.
        noteRiderDueReservation(in: page.items)
        guard let open = page.items.first(where: { RideReservation.isAdoptableLiveRide($0) }),
              let record = RideRequestContractMapping.record(from: open) else {
            armDueRefetch()
            return
        }
        activeRequest = record
        riderServerRideID = open.id
        armDueRefetch()
    }

    /// MYR-377 — remember the SOONEST dormant reservation on the rider's own list,
    /// purely so `armDueRefetch` has a due instant to sleep to. Cleared when the
    /// list carries none.
    private func noteRiderDueReservation(in items: [RideRequest]) {
        let dormant = items.compactMap { ride -> (rideID: String, at: Date)? in
            guard !RideReservation.isAdoptableLiveRide(ride),
                  let record = RideRequestContractMapping.record(from: ride),
                  let due = RideReservation.dueInstant(record)
            else { return nil }
            return (ride.id, due)
        }
        riderDueReservation = dormant.min { $0.at < $1.at }
    }

    /// 409 `ride_active` adoption (deliverable 3): the create was refused because
    /// the rider already holds an OPEN instant ride, returned in the 409 body. Fold
    /// it onto `activeRequest`, DISCARDING this draft — the rider's
    /// `SharedViewerScreen` then reacts through its normal status→phase path (an
    /// accepted ride → tracking; a still-requested ride → the pending pill), never
    /// a decline. If the body omitted the sibling (rare terminal-race, or a
    /// contracts build without the field — §7.8), re-sync from the rider's own open
    /// list; if nothing is open after all, drop the stuck optimistic pending so the
    /// rider is not stranded on a "Waiting…" card for a ride that no longer exists.
    private func adoptRideActive(_ active: RideRequest?) async {
        if let active, let record = RideRequestContractMapping.record(from: active) {
            riderServerRideID = active.id
            activeRequest = record
            return
        }
        guard let open = await fetchOpenRiderRide(),
              let record = RideRequestContractMapping.record(from: open) else {
            activeRequest = nil
            riderServerRideID = nil
            return
        }
        riderServerRideID = open.id
        activeRequest = record
    }

    /// GET the rider's own list (newest first) and return the newest ADOPTABLE
    /// ride, or nil. Shared by the 409 missing-sibling fallback; cold-launch
    /// adoption reads the same page directly so it can also note the rider's next
    /// dormant reservation from it (MYR-377) without a second request.
    ///
    /// MYR-377 renamed the predicate from `isOpenInstant` to
    /// `RideReservation.isAdoptableLiveRide` and widened it: a reservation that has
    /// GONE LIVE (dispatched, or already `arrived`/`enroute`) is a live ride and is
    /// adopted like any other. A DORMANT one still is not. The `409 ride_active`
    /// single-active-instant rule is untouched — that is a server-side uniqueness
    /// index over INSTANT rides (`uq_go_ride_requests_active_instant_rider`,
    /// rest-api.md §7.8, migration 0004) and reservations remain exempt from it.
    private func fetchOpenRiderRide() async -> RideRequest? {
        guard let page = try? await api.rideRequests(cursor: nil, limit: 20) else { return nil }
        noteRiderDueReservation(in: page.items)
        return page.items.first(where: { RideReservation.isAdoptableLiveRide($0) })
    }

    // MARK: MYR-396 — adopt the OWNER's live dispatch

    /// Cold-launch / foreground adoption for the OWNER pipeline: the mirror of
    /// `adoptOpenRiderRide`, and the thing that did not exist.
    ///
    /// THE DEFECT (TestFlight r16): *"When I close out the app the owner loses the
    /// UI of the current ride in progress."* Force-quit mid-ride, relaunch, and
    /// owner Home has no dispatch card, no status line and no Picked-up /
    /// Dropped-off controls — because `ownerDispatch` is a projection of a pipeline
    /// that starts every process empty and nothing on the owner side fills it from
    /// the server.
    ///
    /// WHY THE INCOMING FEED CANNOT DO THIS, and why a pointer is involved at all.
    /// §7.8 gives an owner exactly one feed — `GET /api/ride-requests/incoming` —
    /// and it is status `requested` ONLY: *"decided rows leave the feed by
    /// construction"*. `GET /api/ride-requests` is the RIDER's list, and
    /// `?upcomingForVehicle=` is `accepted` AND strictly FUTURE, i.e. precisely the
    /// reservations that are NOT live. **On this wire an owner cannot ask which
    /// ride they are driving** — the accept is what removes it from the only list
    /// they can read. What they can ask is `GET /api/ride-requests/{id}`, which is
    /// party-only and therefore theirs; all it needs is the id, and the id is a
    /// fact this device knew and lost when the process died. Hence
    /// `OwnerDispatchPointer`, written by the owner pipeline itself.
    ///
    /// THE STORED ID DECIDES NOTHING. It is a question, not an answer: the SERVER's
    /// record decides every arm below, so a stale, terminal or dormant pointer can
    /// never put a card on screen.
    ///
    ///  • **Non-destructive.** Holding this ride already → return without a request
    ///    at all (the foreground case; re-folding a record nobody asked to change
    ///    is how a surface flashes). Holding a LIVE ride → return; the guard is the
    ///    same `canAdoptIncoming` every other adoption site uses, so this cannot
    ///    become a back door around "a live dispatch is never displaced".
    ///  • **Dormancy is the shared predicate** (MYR-376). A reservation accepted
    ///    for tomorrow is `accepted` today, and adopting it as a live dispatch
    ///    would put "En route to pickup" and a live "Picked up" over a parked car —
    ///    that issue's defect, re-entered by a new door. `RideReservation
    ///    .isAdoptableLiveRide` is consulted, never re-implemented. The pointer
    ///    SURVIVES a dormant answer, because dormancy is time-bounded: the same
    ///    reservation is a live ride at its due moment, and the next foreground is
    ///    what notices.
    ///  • **Terminal forgets.** `completed`/`declined`/`cancelled` are over. A
    ///    re-adopted `completed` ride would also raise MYR-292's "Dropped off ✓"
    ///    banner on every launch forever, since that acknowledgement is deliberately
    ///    session-scoped.
    ///  • **`pending` is the feed's**, and the feed is read on the very next line
    ///    of `start()`. Adopting it here would put a pending record in the slot from
    ///    a second source and race `adoptNextIncoming` for it.
    ///  • **A read that fails changes nothing** — no adoption, and no forgetting.
    ///    A network failure is not evidence that a ride ended (MYR-326's
    ///    "loading ≠ unavailable", pointed at a pointer).
    ///
    /// The adopted record is built by `RideRequestContractMapping.record(from:)` —
    /// the same fold `integrate` applies to a WS frame — so the card, the tracking
    /// map's leg-1 pickup and the phase controls are exactly what a live accept
    /// would have produced.
    func refreshOwnerDispatch() async {
        guard let rideID = dispatchPointer.read() else { return }
        guard !ownerHolds(rideID) else { return }
        guard canAdoptIncoming else { return }
        guard let ride = try? await api.rideRequest(id: rideID) else { return }
        guard let mapped = RideRequestContractMapping.status(ride.status) else {
            forgetOwnerDispatch(rideID: rideID) // cancelled / unrecognized-terminal
            return
        }
        switch mapped {
        case .completed, .declined:
            forgetOwnerDispatch(rideID: rideID)
            return
        case .pending:
            return
        case .accepted, .arrived, .enroute:
            break
        }
        guard let record = RideRequestContractMapping.record(from: ride) else { return }
        guard RideReservation.isAdoptableLiveRide(ride) else {
            // DORMANT. Nothing is adopted and nothing is forgotten — but the due
            // moment is now known, and MYR-376's dormancy is time-bounded, so the
            // one timer both pipelines share is armed for it. Without this an owner
            // who force-quit after accepting a reservation would get their card
            // only if they happened to foreground the app after it came due.
            ownerDueReservation = RideReservation.dueInstant(record).map { (ride.id, $0) }
            armDueRefetch()
            return
        }
        ownerDueReservation = nil
        setOwnerRequest(record, serverID: ride.id)
        armDueRefetch()
    }

    /// Owner incoming feed seed (open requests already in flight at connect time).
    ///
    /// MYR-292 — gated on the SAME `canAdoptIncoming` predicate as the `integrate`
    /// adoption arm, deliberately and symmetrically: both are the owner adopting an
    /// incoming request into the owner's slot, so a held ride that is dead for the
    /// owner (its OWN acknowledged `completed`/`declined` ride) must not block
    /// either one. Two guards for one decision is exactly how the two paths would
    /// drift.
    ///
    /// MYR-325 — this is the call the client's deep link fires, and the one that
    /// silently did nothing on his device: the guard it shares used to consult the
    /// RIDER's held record. It is now owner-pipeline-internal, so a feed refresh
    /// surfaces a card whatever the rider half of the same account is doing.
    ///
    /// Internal rather than `private` so the widened guard has direct unit coverage —
    /// `start()` runs this once per session, which cannot reproduce a held completed
    /// ride on its own.
    ///
    /// MYR-317 — this now holds the WHOLE page as the owner's queue instead of taking
    /// `page.items.first` and discarding the rest, and the fetch is no longer skipped
    /// when the slot is occupied: the badge's count is exactly the requests this call
    /// used to throw away. Adoption itself is unchanged — the same guard, the same
    /// head record.
    func refreshIncoming() async {
        guard let page = try? await api.incomingRideRequests(cursor: nil, limit: 20) else { return }
        replaceQueue(with: page.items)
        adoptNextIncoming()
        armDueRefetch() // MYR-376 — a newly adopted reservation may be due later today
    }

    // MARK: Helpers

    private func resolveVehicleID() async -> String? {
        if let cachedVehicleID { return cachedVehicleID }
        guard let list = try? await api.vehicles(), let first = list.first else { return nil }
        cachedVehicleID = first.vehicleId
        return first.vehicleId
    }

    /// Fire-and-forget POST on the OWNER pipeline's ride. Its only caller is
    /// `decline()`, which needs no reconcile: a declined request is terminal for the
    /// owner either way, and MYR-317's advance has already moved the card on.
    /// MYR-325 — targets `ownerServerRideID`; it read the rider's id back when one
    /// slot held both, which after the split would have declined the wrong ride (or,
    /// with no rider ride in flight, silently declined nothing at all).
    private func postOwnerMutation(_ op: @escaping @Sendable (any RideRequestAPI, String) async throws -> RideRequest) {
        guard let id = ownerServerRideID else { return } // nothing held to answer
        let api = self.api
        Task { _ = try? await op(api, id) }
    }

    /// MYR-179 — the create body, now carrying a REAL `scheduledFor` for a
    /// scheduled request. The rider's picked day/time is resolved to an absolute
    /// instant at the SEND moment (`fireSend`, i.e. the end of the booking grace
    /// window) against the rider's own clock + time zone, and encoded RFC 3339
    /// UTC by `RideRequestContractMapping.scheduledFor(from:)`. `nil` for an
    /// on-demand ("Now") request — the key is then omitted, unchanged.
    /// `nonisolated` because it is pure — inputs in, wire body out, no actor state —
    /// so the encoding matrix can drive it directly (same precedent as the static
    /// failure classifiers above).
    nonisolated static func createBody(
        from input: RideRequestInput,
        vehicleId: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RideRequestCreateRequest {
        RideRequestCreateRequest(
            vehicleId: vehicleId,
            pickup: wirePlace(input.pickup),
            dropoff: wirePlace(input.destination),
            passengerName: input.passenger?.name,
            passengerPhone: input.passenger.flatMap { $0.phone.isEmpty ? nil : $0.phone },
            scheduledFor: RideRequestContractMapping.scheduledFor(
                from: input.schedule, now: now, calendar: calendar)
        )
    }

    nonisolated private static func wirePlace(_ place: RidePlace) -> MyRobotaxiContracts.RidePlace {
        MyRobotaxiContracts.RidePlace(
            lat: place.coordinate.latitude,
            lng: place.coordinate.longitude,
            label: place.label,
            address: place.subtitle
        )
    }
}
