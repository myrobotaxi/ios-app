import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - Live ride-request service (MYR-209)
//
// The M2 conformer of the `RideRequestService` seam: the SAME `activeRequest`
// snapshot + method surface the rider's `SharedViewerScreen` and the owner's
// `IncomingRequestSheet` already read/call — screens do not change. Where the
// simulated service runs local timers, this talks to the production backend over
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
// single-session demo (rider + owner are the same JWT, ONE service instance
// shared across the role switch — see `RideRequestService`'s header) the shared
// snapshot alone bridges the round trip; the WS path is the real multi-device
// route and the audit's live pass.
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
    private(set) var activeRequest: RideRequestRecord?

    /// MYR-220: the latest session/connection failure of the create POST (auth
    /// died mid-session — 401 / auth-shaped 403). Observed by the rider's
    /// `SharedViewerScreen` to surface a calm retry, never a decline.
    private(set) var sessionFailure: RideSessionFailure?

    /// MYR-233: the latest `409 vehicle_unavailable` refusal (create or accept).
    /// Observed by the rider's `SharedViewerScreen` to surface honest messaging
    /// and route toward scheduling — never a decline, never a retry.
    private(set) var vehicleUnavailableFailure: RideVehicleUnavailableFailure?

    /// MYR-292 — which role's flow put the CURRENT `activeRequest` there.
    ///
    /// ONE service instance serves both roles (see the header), so "is the held ride
    /// dead?" cannot be answered from its status alone: a `completed` ride is DEAD on
    /// the owner's Home (the "Dropped off ✓" banner acknowledges and hides) but very
    /// much LIVE on the rider's Ride Summary, which renders that exact record until
    /// "See you soon" calls `completeAndReset()`. Recorded at the five sites that
    /// ADOPT a record — never on an in-place status mutation, which leaves the origin
    /// untouched — so the incoming-adoption guards can widen for the owner without
    /// ever clobbering the rider's summary.
    enum ActiveRequestOrigin {
        /// This device's rider submitted it, or adopted its own open ride
        /// (cold launch / `409 ride_active`).
        case rider
        /// Adopted from the OWNER incoming path — a `ride_request_created` frame for
        /// a ride this device has no local draft for, or the incoming feed seed.
        case ownerIncoming
    }
    private(set) var activeRequestOrigin: ActiveRequestOrigin?

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

    /// The server-assigned ride id for the active request (distinct from the
    /// local `activeRequest.id`, which for a rider-submitted ride is a client
    /// UUID until the create POST returns). Mutations target this id.
    private var serverRideID: String?
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
        sendWindow: Duration = .seconds(RideRequestTiming.sendFillDuration)
    ) {
        self.api = api
        self.socket = socket
        self.reconcilePolicy = reconcilePolicy
        self.sendWindow = sendWindow
        if autoStart { start() }
    }

    deinit {
        sendTask?.cancel()
        eventTask?.cancel()
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
            // Rider-side takes priority; only if the rider holds no open ride does
            // the owner incoming feed seed (its guard no-ops once this adopts one).
            await self?.adoptOpenRiderRide()
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
        activeRequestOrigin = .rider
        serverRideID = nil

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
                self.serverRideID = ride.id
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
                if case RestError.rideActive(let active) = error {
                    await self.adoptRideActive(active)
                } else if Self.isVehicleUnavailable(error) {
                    self.failCreateVehicleUnavailable()
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

    /// MYR-233 VEHICLE_UNAVAILABLE create failure: the server refused the create
    /// because the car is busy / in service / offline, so NO ride was created.
    /// Clear the stuck optimistic pending (no frozen "Waiting…", no false
    /// "Ride declined") WITHOUT touching `.declined`, and raise a fresh
    /// `vehicleUnavailableFailure` for the rider's `SharedViewerScreen`. The
    /// DRAFT lives in `SharedViewerState` and is untouched, so the rider can
    /// schedule the very same trip in one tap. No-op if the request was
    /// cancelled or already moved on.
    private func failCreateVehicleUnavailable() {
        guard let request = activeRequest, request.status == .pending else { return }
        activeRequest = nil
        activeRequestOrigin = nil
        serverRideID = nil
        vehicleUnavailableFailure = RideVehicleUnavailableFailure()
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
        serverRideID = nil
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
        activeRequestOrigin = nil
        serverRideID = nil
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
            guard activeRequest?.status == .pending, serverRideID == nil else { return }
            guard let page = try? await api.rideRequests(cursor: nil, limit: 20) else { continue }
            if let match = page.items.first(where: { Self.matchesSubmission($0, input: input, since: since) }) {
                serverRideID = match.id
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

    func accept() {
        guard var request = activeRequest, request.status == .pending else { return }
        request.status = .accepted
        request.acceptedAt = Date()
        if request.input.schedule == nil {
            request.trackProgress = RideRequestTiming.autoAcceptInitialProgress
        }
        activeRequest = request
        // MYR-277 C: the backend now 409s an accept for an in_service/offline
        // vehicle (parallel PR). A swallowed error would strand the owner on a
        // phantom "accepted" — so reconcile on failure instead of fire-and-forget.
        reconcileAcceptOnFailure()
        // MYR-317: the accepted ride now owns the slot, so `canAdoptIncoming` makes
        // the adoption half a no-op — but the queue must still be re-read, because
        // the card the owner just cleared changed how many are waiting behind it.
        markIncomingResolved()
        advanceIncoming()
    }

    /// MYR-277 C: POST the accept; on SUCCESS keep the optimistic `.accepted` (the
    /// owner tracking + WS frames drive the rest, unchanged from the prior
    /// fire-and-forget behavior). On ANY error — notably a 409 when the target
    /// vehicle went in_service/offline and the backend refuses the dispatch —
    /// REFETCH the authoritative record and fold it: a still-`requested` ride folds
    /// back to `.pending`, re-showing the incoming sheet (clean, tappable — the
    /// sheet resets its sending/sent choreography on the id round-trip) instead of
    /// leaving the owner stuck. If even the refetch fails, revert to pending.
    private func reconcileAcceptOnFailure() {
        guard let id = serverRideID else { return } // create not yet acknowledged
        let api = self.api
        Task { @MainActor [weak self] in
            do {
                _ = try await api.acceptRideRequest(id: id)
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
                    self?.vehicleUnavailableFailure = RideVehicleUnavailableFailure()
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
        guard var request = activeRequest, request.status == .accepted else { return }
        request.status = .pending
        request.acceptedAt = nil
        request.trackProgress = nil
        activeRequest = request
    }

    func decline() {
        guard var request = activeRequest, request.status == .pending else { return }
        request.status = .declined
        activeRequest = request
        postMutation { try await $0.declineRideRequest(id: $1) }
        // MYR-306 + MYR-317: a declined OWNER-originated request releases the slot,
        // so the next waiting request surfaces on the very next frame — instead of
        // the old behaviour, where the `.declined` record jammed adoption until the
        // app was relaunched (MYR-306) and any queued rider stayed invisible. A
        // RIDER-originated decline (the rider's own `DeclinedNotice`) is refused by
        // `canAdoptIncoming` and nothing moves.
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
    func pickedUp() {
        guard var request = activeRequest, request.status == .accepted else { return }
        request.status = .arrived
        activeRequest = request
        advanceMutation(revertTo: .accepted) { try await $0.pickedUp(rideID: $1) }
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
        advanceMutation(revertTo: .arrived) { try await $0.start(rideID: $1) }
    }

    /// OWNER "Dropped off" — `enroute → completed`.
    func droppedOff() {
        guard var request = activeRequest, request.status == .enroute else { return }
        request.status = .completed
        if request.input.schedule == nil { request.trackProgress = 1 }
        activeRequest = request
        advanceMutation(revertTo: .enroute) { try await $0.droppedOff(rideID: $1) }
    }

    /// Shared optimistic-advance reconcile (MYR-270). POST the action; a 200 folds the
    /// returned record; any error REFETCHES the authoritative record and folds it (so
    /// an already-advanced ride settles on its true state while a genuinely failed
    /// advance reverts). A double failure (POST AND refetch) reverts the optimistic
    /// flip to `previous` — the server never advanced, so no `ride_status_changed`
    /// frame will arrive to correct it; a re-tap is an idempotent 200 and the WS
    /// re-confirms the real state.
    private func advanceMutation(
        revertTo previous: RideRequestStatus,
        _ op: @escaping @Sendable (any RideRequestAPI, String) async throws -> RideRequest
    ) {
        guard let id = serverRideID else { return } // create not yet acknowledged
        let api = self.api
        Task { @MainActor [weak self] in
            do {
                let ride = try await op(api, id)
                self?.integrate(ride)
            } catch {
                if let ride = try? await api.rideRequest(id: id) {
                    self?.integrate(ride)
                } else {
                    self?.revertOptimisticAdvance(to: previous)
                }
            }
        }
    }

    /// Undo an optimistic advance the server never confirmed, restoring the prior
    /// status + its leg tracking anchor (MYR-270).
    private func revertOptimisticAdvance(to previous: RideRequestStatus) {
        guard var request = activeRequest else { return }
        request.status = previous
        if request.input.schedule == nil {
            switch previous {
            case .accepted, .arrived: request.trackProgress = RideRequestTiming.autoAcceptInitialProgress
            case .enroute: request.trackProgress = request.enrouteSeedProgress
            default: break
            }
        }
        activeRequest = request
    }

    func cancel() {
        // MYR-218 defect 1: a cancel DURING the grace window (before the
        // deferred POST fired) must make ZERO server calls — no ride exists yet.
        // Disarm the auto-send and drop the held draft, then discard locally.
        // `serverRideID` is still nil at that point, so the guard below no-ops
        // the remote cancel; after the send it is set and cancel keeps its
        // existing remote behavior.
        sendTask?.cancel()
        sendTask = nil
        pendingSend = nil
        let id = serverRideID
        activeRequest = nil
        activeRequestOrigin = nil
        serverRideID = nil
        guard let id else { return }
        let api = self.api
        Task { _ = try? await api.cancelRideRequest(id: id) }
    }

    func completeAndReset() -> RequestedRide? {
        // v1 has no completed lifecycle (MYR-176/177), so the Ride Summary is
        // unreachable in live mode. Reset defensively; nothing to persist.
        activeRequest = nil
        activeRequestOrigin = nil
        serverRideID = nil
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

    private func integrate(_ ride: RideRequest) {
        let mapped = RideRequestContractMapping.status(ride.status)
        if mapped == nil {
            // Cancelled / terminal — drop it if it's the ride we're tracking, and
            // (MYR-317) drop it from the queue if it was waiting behind the card:
            // a rider who cancels while queued must not be surfaced later as a
            // request the owner can still accept.
            if isCurrent(ride.id) {
                activeRequest = nil; activeRequestOrigin = nil; serverRideID = nil
            } else {
                dequeueIncoming(id: ride.id)
            }
            return
        }
        if isCurrent(ride.id) {
            // Update status in place, preserving the richer local draft input.
            // `record(from:)` is non-nil here (it returns nil only for the
            // already-handled cancelled/terminal case above).
            let refetched = RideRequestContractMapping.record(from: ride)!
            var current = activeRequest ?? refetched
            current.status = mapped!
            current.acceptedAt = ride.acceptedAt.flatMap(RideRequestContractMapping.parseISO)
            // MYR-277 A1: in the single-account demo the rider's optimistic draft
            // carries NO requesterName (the rider never stamps their own display
            // name) and may carry placeholder place labels; the refetched server
            // record is authoritative for identity. Refresh those fields from it
            // WITHOUT downgrading a richer local value, so the owner card shows the
            // real "<Name> wants a ride" instead of the neutral "Shared viewer".
            // The two-device owner path builds its record in the `else if` branch
            // below (via `record(from:)`) and is unaffected by this fold.
            // Prefer a non-empty refetched name; never overwrite a known name with
            // nil OR an empty string (MYR-277 review — symmetric with preferRicherPlace).
            if let name = ride.requesterName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                current.input.requesterName = name
            }
            current.input.pickup = Self.preferRicherPlace(local: current.input.pickup, refetched: refetched.input.pickup)
            current.input.destination = Self.preferRicherPlace(local: current.input.destination, refetched: refetched.input.destination)
            // MYR-265: seed the per-leg tracking anchor so a WS-driven status change
            // moves the rider's sheet to the matching leg (v1 has no live ticker).
            // The owner side ignores `trackProgress`; only the rider reads it.
            if current.input.schedule == nil {
                switch mapped! {
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
            }
            activeRequest = current
            serverRideID = ride.id
            // MYR-317 — the tracked ride reached a status that RELEASES the owner's
            // slot (its own `completed` — the drop-off — or `declined` once MYR-306
            // widened the guard): surface the next queued request instead of sitting
            // on a dead card until a fresh frame happens to arrive, which is exactly
            // how a waiting rider stayed invisible after ONE ride. Narrowed to those
            // two statuses so a live dispatch's frames don't each re-fetch the feed;
            // `canAdoptIncoming` is still the thing that decides (a RIDER-originated
            // completed/declined record is never touched).
            if mapped == .completed || mapped == .declined { advanceIncoming() }
        } else if mapped == .pending {
            // OWNER side: a pending request for some OTHER ride.
            //
            // MYR-317 — it is QUEUED first (deduped by id), so it is counted on the
            // card's "+N more waiting" chip even while another request owns the
            // slot; before, a frame that arrived with the slot occupied was simply
            // dropped and that rider became invisible. Adoption then runs under the
            // unchanged `canAdoptIncoming` guard and takes the queue HEAD (server
            // feed order), which for a free slot is this very ride.
            enqueueIncoming(ride)
            adoptNextIncoming()
        } else {
            // MYR-317 — a QUEUED request resolved remotely (another device accepted
            // or declined it, it ran, it completed): drop it from the queue so the
            // owner is never advanced onto a request nobody is waiting on.
            dequeueIncoming(id: ride.id)
        }
    }

    // MARK: MYR-317 — incoming queue mechanics

    /// Add a pending incoming request to the tail of the queue, deduped by id (a
    /// re-delivered frame refreshes the held record in place rather than counting
    /// the same rider twice). Never queues the request already on the card.
    private func enqueueIncoming(_ ride: RideRequest) {
        guard RideRequestContractMapping.status(ride.status) == .pending,
              !isCurrent(ride.id), !resolvedIncomingIDs.contains(ride.id)
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
                && !isCurrent($0.id)
                && !resolvedIncomingIDs.contains($0.id)
        }
    }

    /// Take the queue HEAD into the `activeRequest` slot, if the slot may be taken.
    ///
    /// The guard is the SAME `canAdoptIncoming` every other adoption site uses —
    /// deliberately, so the queue can never become a back door around the
    /// rider-safety invariants (MYR-292): a live dispatch is never displaced, and a
    /// RIDER-originated record (their Ride Summary, their `DeclinedNotice`) is never
    /// clobbered no matter how many owners' requests are waiting.
    @discardableResult
    private func adoptNextIncoming() -> Bool {
        guard canAdoptIncoming else { return false }
        while !incomingQueue.isEmpty {
            let next = incomingQueue.removeFirst()
            guard !isCurrent(next.id),
                  let record = RideRequestContractMapping.record(from: next),
                  record.status == .pending
            else { continue }
            activeRequest = record
            activeRequestOrigin = .ownerIncoming
            serverRideID = next.id
            return true
        }
        return false
    }

    /// Remember the ride the owner just answered (accept/decline) as resolved, so a
    /// feed page that was already in flight can't hand it back as still-waiting.
    private func markIncomingResolved() {
        if let id = serverRideID { resolvedIncomingIDs.insert(id) }
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

    private func isCurrent(_ rideID: String) -> Bool {
        rideID == serverRideID || rideID == activeRequest?.id
    }

    /// MYR-292 — may a brand-new incoming `pending` request take the single
    /// `activeRequest` slot? Yes when nothing is held, and yes when what is held is
    /// the OWNER's own adopted ride in the one status that is TERMINAL for the owner:
    /// `completed`.
    ///
    /// The defect this widening fixes: nothing on the owner path ever clears a
    /// completed ride. `completeAndReset()` is the RIDER summary's "See you soon", and
    /// the owner's "Dropped off ✓" acknowledgement is deliberately view-side only
    /// (MYR-267/292 — it must not disturb the rider's card). So the owner sat on a
    /// dead `.completed` `activeRequest` forever, and because adoption was gated on
    /// `activeRequest == nil`, every subsequent `ride_created` / `ride_status_changed`
    /// frame was silently dropped: after ONE completed ride the owner could not
    /// receive another dispatch until the app was relaunched.
    ///
    /// MYR-306 extends the same reasoning to `declined`: `decline()` leaves
    /// `activeRequest` on `.declined` with nothing on the owner path to clear it, so
    /// an owner who DECLINED a request landed in the identical blocked-adoption state
    /// MYR-292 fixed for `completed` — every later incoming frame dropped until
    /// relaunch. MYR-292 deliberately left `.declined` alone because the rider's
    /// `DeclinedNotice` renders a declined record; now that adoption is ORIGIN-scoped
    /// that objection is answered by the origin test, not by the status: a rider's
    /// notice holds a `.rider`-origin record and is still untouchable. This is also
    /// what makes MYR-317's decline→advance work at all.
    ///
    /// Deliberately NOT widened for:
    ///  • a RIDER-originated `completed` or `declined` ride — the rider's Ride Summary
    ///    / `DeclinedNotice` is rendering that exact record right now; displacing it
    ///    would swap the itinerary out from under them and point "See you soon" at a
    ///    stranger's ride. This is why the guard tests `activeRequestOrigin`, not just
    ///    the status.
    ///  • every non-terminal status (`pending`/`accepted`/`arrived`/`enroute`) — a
    ///    live dispatch still owns the slot and must never be displaced.
    private var canAdoptIncoming: Bool {
        guard let held = activeRequest else { return true }
        guard activeRequestOrigin == .ownerIncoming else { return false }
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
        guard activeRequest == nil, serverRideID == nil else { return }
        guard let open = await fetchOpenRiderRide(),
              let record = RideRequestContractMapping.record(from: open) else { return }
        activeRequest = record
        activeRequestOrigin = .rider
        serverRideID = open.id
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
            serverRideID = active.id
            activeRequest = record
            activeRequestOrigin = .rider
            return
        }
        guard let open = await fetchOpenRiderRide(),
              let record = RideRequestContractMapping.record(from: open) else {
            activeRequest = nil
            activeRequestOrigin = nil
            serverRideID = nil
            return
        }
        serverRideID = open.id
        activeRequest = record
        activeRequestOrigin = .rider
    }

    /// GET the rider's own list (newest first) and return the newest OPEN INSTANT
    /// ride, or nil. Shared by cold-launch adoption and the 409 missing-sibling
    /// fallback.
    private func fetchOpenRiderRide() async -> RideRequest? {
        guard let page = try? await api.rideRequests(cursor: nil, limit: 20) else { return nil }
        return page.items.first(where: { Self.isOpenInstant($0) })
    }

    /// A wire ride is an ADOPTABLE open instant ride when it carries no
    /// `scheduledFor` (scheduled reservations are not a live ride to narrate and
    /// are exempt from the single-active rule) and its status is non-terminal
    /// (`requested`/`accepted`/`enroute`/`arrived`). `completed`/`declined`/
    /// `cancelled` are terminal and never adopted. Matches the server's
    /// `uq_go_ride_requests_active_instant_rider` open-state set (rest-api.md §7.8,
    /// migration 0004).
    static func isOpenInstant(_ ride: RideRequest) -> Bool {
        guard ride.scheduledFor == nil else { return false }
        switch ride.status {
        case .requested, .accepted, .enroute, .arrived: return true
        default: return false
        }
    }

    /// Owner incoming feed seed (open requests already in flight at connect time).
    ///
    /// MYR-292 — gated on the SAME `canAdoptIncoming` predicate as the `integrate`
    /// adoption arm, deliberately and symmetrically: both are the owner adopting an
    /// incoming request into the single `activeRequest` slot, so a held ride that is
    /// dead for the owner (its OWN acknowledged `completed` ride) must not block
    /// either one, and the rider's live Ride Summary must not be clobbered by either
    /// one. Two guards for one decision is exactly how the two paths would drift.
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
    }

    // MARK: Helpers

    private func resolveVehicleID() async -> String? {
        if let cachedVehicleID { return cachedVehicleID }
        guard let list = try? await api.vehicles(), let first = list.first else { return nil }
        cachedVehicleID = first.vehicleId
        return first.vehicleId
    }

    private func postMutation(_ op: @escaping @Sendable (any RideRequestAPI, String) async throws -> RideRequest) {
        guard let id = serverRideID else { return } // create not yet acknowledged
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
