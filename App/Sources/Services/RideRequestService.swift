import Foundation
import MyRobotaxiContracts
import Observation

// MARK: - Ride request seam (MYR-171)
//
// `RideRequestService` is the M1↔M2 seam for the whole ride-request flow —
// mirrors `VehicleTelemetrySource`'s reasoning (VehicleTelemetry.swift): this
// issue ships `SimulatedRideRequestService`, a local state machine + timers,
// no network (CLAUDE.md "M1 is simulated"). P10's real dispatch API (M2)
// swaps in a service that talks to the backend over `MyRoboTaxiKit` and
// drives the identical `activeRequest` snapshot — the rider's
// `SharedViewerScreen` phases and the owner's `IncomingRequestSheet` don't
// change; they only ever read `activeRequest` and call the methods below.
//
// Lifted at `RootView` (alongside `sharedViewerState`/`ownerHomeState`), so
// ONE instance is visible to both roles within a single app session — the
// mechanism M1 uses to demo the cross-role round trip without a backend: the
// rider submits a request on the Shared flow, switches role to Owner
// (Settings → Sign out → Add Tesla — RootView's existing role-switch path),
// and `IncomingRequestSheet` on the owner Home reads the very same
// `activeRequest`, because `rideRequestService` is never recreated across
// that switch (see `RootView`'s header comment for why its `@State`
// properties survive changing `screen`/`role`).
@MainActor
public protocol RideRequestService: AnyObject, Observable {
    /// The RIDER's ride: `nil` when no ride has been requested this session (or the
    /// last one finished and was dismissed). One request in flight at a time — M1
    /// scope, matches the prototype's single `requestState`/`requestDest`.
    ///
    /// MYR-325 — RIDER-SCOPED. It used to be the single slot both roles read, which
    /// is why the owner's incoming card could be starved by the rider's own held
    /// record (see `LiveRideRequestService`'s pipeline note). Owner surfaces read
    /// `incomingRequest` / `ownerDispatch` instead; nothing owner-side reads this.
    var activeRequest: RideRequestRecord? { get }

    /// MYR-325 — the OWNER's currently-presented INCOMING request, i.e. one awaiting
    /// this owner's Accept/Decline. Exactly the `IncomingRequestSheet` presentation
    /// gate: PENDING only, so the sheet's dismiss animation is driven by this going
    /// `nil` the instant the owner answers.
    ///
    /// On the LIVE service this is its own pipeline, independent of `activeRequest`,
    /// so an owner who also rides keeps receiving requests while their own ride (or
    /// their own declined notice, or their own summary) is on screen. On the
    /// SIMULATED service it derives from `activeRequest` — see the default below.
    var incomingRequest: RideRequestRecord? { get }

    /// MYR-325 — the OWNER's ACCEPTED ride through to drop-off (`accepted` →
    /// `arrived` → `enroute` → `completed`), i.e. what `OwnerDispatchCard` narrates
    /// and what the owner's "Picked up"/"Dropped off" CTAs advance. `nil` for a
    /// pending request (that is `incomingRequest`) and for a declined one (no owner
    /// surface renders it). The "Dropped off ✓ until acknowledged" rule stays in the
    /// pure `OwnerRideStatusLine.dispatchCardVisible` resolver.
    var ownerDispatch: RideRequestRecord? { get }

    /// MYR-325 — the SERVER id of the request on the owner's incoming card, for the
    /// foreground push-banner suppression decision. Distinct from
    /// `activeServerRideID` (the rider's): now that the two pipelines are separate
    /// they routinely name different rides, and suppressing on the rider's id would
    /// hide a banner for a request the owner cannot see.
    var incomingServerRideID: String? { get }

    /// MYR-220: the most recent SESSION/CONNECTION failure of a mutation (a
    /// create POST whose auth died mid-session — 401 / auth-shaped 403 — not an
    /// owner refusal). Bumps to a fresh value on each failure so the rider's
    /// `SharedViewerScreen` can react through `.onChange` even on a repeat, land
    /// the rider back in a retryable state with the draft intact, and surface a
    /// CALM retry notice rather than the declined affordance. `nil`/never-set in
    /// sim (no network) — see the default implementation.
    var sessionFailure: RideSessionFailure? { get }

    /// MYR-233: the most recent `409 vehicle_unavailable` refusal of a ride
    /// mutation the rider touches — the target vehicle already carries an open
    /// instant ride, or went in service / offline. Like `sessionFailure` this is
    /// NOT an owner decline and NOT a stuck pending: it bumps to a fresh value
    /// per occurrence so `.onChange` fires even on a repeat, and the rider is
    /// returned to a retryable state pointed at the SCHEDULING flow. Never
    /// auto-retried — the same POST would 409 again (no retry loop).
    /// `nil`/never-set in sim (no network) — see the default implementation.
    var vehicleUnavailableFailure: RideVehicleUnavailableFailure? { get }

    /// MYR-316: the most recent `400 invalid_request` refusal of a SCHEDULED ride
    /// mutation — the server rejected the pickup time because it falls before the
    /// target vehicle's `serviceEstimatedEndAt`. Like the two failures above this
    /// is NOT an owner decline: nobody refused the rider, the car simply is not
    /// back yet. Should be UNREACHABLE in practice (the picker floors at the same
    /// instant the server checks), so it exists for the races the floor cannot
    /// cover — a window that moved while the sheet was open, or a rider on a build
    /// whose fleet row was fetched before the owner set the time. Bumps to a fresh
    /// value per occurrence for the same reason its siblings do.
    /// `nil`/never-set in sim (no network) — see the default implementation.
    var scheduleWindowFailure: RideScheduleWindowFailure? { get }

    /// MYR-317: how many OTHER pending incoming requests are queued BEHIND the one
    /// `activeRequest` is currently showing the owner. Drives the muted
    /// "+N more waiting" chip on `IncomingRequestSheet` — the owner's only signal
    /// that resolving this card is not the end of the queue. `0` whenever nothing
    /// is waiting, and `0` on the simulated path (see the default implementation).
    var waitingIncomingCount: Int { get }

    /// MYR-381 — bumped whenever a WebSocket ride frame arrives about a SCHEDULED
    /// ride (one carrying `scheduledFor`), whatever its status and whichever
    /// pipeline — if any — holds it.
    ///
    /// THE DEFECT it exists for: *"Took a long time for ride declined to appear on
    /// the rider side."* The rider's Scheduled tab and the owner's Drives →
    /// Upcoming are their own narrow read seams (MYR-376/377), deliberately off
    /// `RideRequestService`'s two ride pipelines — which meant they refreshed on
    /// screen appearance and foreground and NOTHING ELSE. The socket was already
    /// delivering the decline; nothing was listening on behalf of a list.
    ///
    /// A TICK rather than a payload, for two reasons. A reservation surface's
    /// question is "is my list still right", not "what changed" — the answer is
    /// always the same one page fetch it already knows how to make. And the frames
    /// arrive about rides these surfaces may not hold (a decline is the exact case:
    /// the row is about to STOP existing), so routing by held id would miss the one
    /// event that matters most. Gated on `scheduledFor` so a live ride's per-status
    /// frames never spend a reservation refetch.
    ///
    /// `0` forever on the simulated path (see the default), so no DEBUG scene or
    /// drift-gate capture can be moved by it.
    var scheduledSurfaceTick: Int { get }

    /// Submits a new request — mirrors ride-request.jsx's `onSubmit`
    /// (`ReviewContent`'s primary CTA, ride-request.jsx:1234-1237): status
    /// becomes `.pending` immediately so the rider's Review→Booking transition
    /// reads the optimistic record synchronously. Arms the
    /// `minimizeToAutoAcceptDelay` fallback (ride-request.jsx:1112-1117) in
    /// case the owner never manually intervenes.
    ///
    /// MYR-218 defect 1: in LIVE mode the 10s "Sending request" countdown is a
    /// REAL grace window — `submit` creates the local optimistic record but
    /// does NOT yet hit the server. The create POST is deferred to the end of
    /// the window (or to `confirmSend()` if the rider taps "Tap to send now"),
    /// so the owner does not receive the request while the rider's fill is
    /// still running. The sim service is unaffected (no network; its owner is
    /// the same shared snapshot).
    func submit(_ input: RideRequestInput)

    /// Signals the send moment inside the booking grace window — the rider
    /// tapped "Tap to send now", or (under Reduce Motion) the booking card
    /// flipped straight to "Request sent". LIVE mode fires the deferred create
    /// POST here; the countdown-zero auto-send routes through the SAME path, so
    /// there is exactly one idempotent send trigger. Sim is a no-op (its
    /// `submit` already models the send — see the default implementation).
    func confirmSend()

    /// Owner accepts (`IncomingRequestSheet`'s "Accept & send"/"Accept
    /// ride"). Cancels the auto-accept fallback, flips `status` to
    /// `.accepted`, stamps `acceptedAt`, seeds `trackProgress` at
    /// `RideRequestTiming.autoAcceptInitialProgress`, and starts ticking it
    /// toward 1 over `RideRequestTiming.trackingDemoDuration`.
    func accept()

    /// Owner declines. Immediate, no animation (ride-request.jsx:1276
    /// `onReject` has no choreography, unlike accept).
    func decline()

    /// Rider cancels an in-flight (not yet accepted) request
    /// (`PendingContent`'s "Cancel request" / `closeToIdle`).
    func cancel()

    /// MYR-270 — OWNER confirms the rider is aboard on the leg-1 tracking sheet:
    /// advances `accepted → arrived` (car reached pickup, awaiting the rider's
    /// start). LIVE mode optimistically flips the local status and POSTs
    /// `/picked-up`, reconciling to server state on a 409/failure. Sim is a no-op
    /// default (a live-only affordance — the simulated tracking is `trackProgress`
    /// ticker-driven, unchanged). NO nav is pushed here (see `start()`).
    func pickedUp()

    /// MYR-270 — RIDER starts the ride once the owner has confirmed pickup:
    /// advances `arrived → enroute` (leg 2). This is what makes the server PUSH THE
    /// DROPOFF NAV to the car. LIVE mode optimistically flips the status + seeds the
    /// leg-2 tracking anchor and POSTs `/start`, reconciling on a 409/failure (a 409
    /// from `accepted` means the owner has not confirmed pickup yet). Sim no-op.
    func startRide()

    /// MYR-270 — OWNER completes the ride at the drop-off: advances
    /// `enroute → completed`. There is NO drive-end auto-completion anymore; the
    /// owner explicitly ends the ride. LIVE mode optimistically flips the status and
    /// POSTs `/dropped-off`, reconciling on a 409/failure. Sim no-op.
    func droppedOff()

    /// MYR-186 — the id a PUSH payload uses for the request this service is
    /// currently holding, i.e. the SERVER's ride id.
    ///
    /// Distinct from `activeRequest?.id`, which for a rider-submitted ride is a
    /// CLIENT UUID until the create POST returns. A push `userInfo.rideId` is
    /// always the server's, so anything comparing the two — the foreground
    /// banner-suppression decision — must compare against this. See the default
    /// implementation for why the simulated service can answer with the local id.
    var activeServerRideID: String? { get }

    /// MYR-186 — re-sync the OWNER's incoming feed after a push tap, so the card
    /// for the tapped ride surfaces through the EXISTING queue machinery rather
    /// than any push-specific navigation. Sim is a no-op (no feed to fetch).
    func refreshIncoming() async

    /// MYR-186 — re-sync the RIDER's own open ride after a push tap, so a rider
    /// who launched cold from a notification lands in their active flow. This is
    /// the same adoption a cold launch already performs. Sim is a no-op.
    func refreshActiveRide() async

    /// MYR-396 — re-sync the OWNER's live dispatch: the accepted / arrived /
    /// enroute ride they are currently driving.
    ///
    /// The owner's counterpart to `refreshActiveRide`, and the one that did not
    /// exist. Nothing on the owner side reads an answered ride back — §7.8's
    /// incoming feed is status `requested` ONLY — so before this the in-progress
    /// card, its status line and its Picked-up / Dropped-off controls simply did
    /// not survive a force-quit. Run at cold launch (inside `start()`), on every
    /// foreground, and after an owner push tap.
    ///
    /// Costs nothing when there is nothing to restore: it makes no request unless
    /// this device remembers a ride it accepted, and none when the pipeline already
    /// holds it. Sim is a no-op (no server, and one in-process record).
    func refreshOwnerDispatch() async

    /// MYR-396 — release what `refreshOwnerDispatch` reads. Called from the local
    /// end-of-session sequence, so a signed-out device forgets the ride exactly as
    /// it forgets the profile and the view mode. Sim is a no-op.
    func forgetOwnerDispatch()

    /// MYR-376/377 — re-sync any held reservation whose DUE MOMENT has arrived.
    ///
    /// Dispatch produces no WebSocket frame — the reservation sweeper stamps the
    /// latch, pushes leg-1 navigation and sends the rider a `ride.due` APNs
    /// notification, and that is the whole of the signal. The live service sleeps
    /// to the due instant while it is running, but a suspended app's timer does not
    /// fire, so a reservation that came due overnight is still dormant on this
    /// device at breakfast. `RootView` calls this on every foreground, beside the
    /// existing push re-arm and Live Activity re-evaluation.
    ///
    /// Costs nothing when nothing is held: it makes no request at all unless a
    /// dormant reservation's moment has actually passed. Sim is a no-op (no
    /// server, and its reservations never dispatch).
    func refreshDueReservations() async

    /// Ride Summary's "See you soon" — builds the completed-ride record for
    /// `RideHistoryStore` and resets `activeRequest` to `nil`. Returns `nil`
    /// if there's no request or it hasn't reached `trackProgress >= 0.999`.
    func completeAndReset() -> RequestedRide?
}

public extension RideRequestService {
    /// MYR-325 default — the SIMULATED service (M1) deliberately keeps ONE record
    /// for both roles: that shared snapshot IS the mechanism the M1 demo uses to
    /// show the cross-role round trip in a single process (the rider submits, the
    /// user switches role, the owner's sheet reads the very same request — see this
    /// protocol's header). It has no incoming FEED and no second party, so there is
    /// no second pipeline to have.
    ///
    /// These two derivations are, character for character, the expressions
    /// `HomeScreen` used to compute locally off `activeRequest` before the split —
    /// so every simulated run and every DEBUG capture scene (`ownerIncoming`,
    /// `ownerIncomingQueued`, `ownerScheduled`, `ownerDispatchedCompleted`) renders
    /// byte-identically. Only `LiveRideRequestService`, which really does serve two
    /// parties, overrides them with independent storage.
    var incomingRequest: RideRequestRecord? {
        guard let request = activeRequest, request.status == .pending else { return nil }
        return request
    }

    /// MYR-376 — the dormancy gate applies HERE TOO, and deliberately so. The
    /// simulated service has no dispatch latch to read (its records carry none),
    /// so `RideReservation.isLiveRide` answers `true` for every instant ride and
    /// `false` for an accepted reservation — which is the correct simulated
    /// answer: a reservation accepted in the simulator is reserved into Drives →
    /// Upcoming and does not dispatch either. Putting the rule in the default
    /// rather than only in the live override keeps ONE model of what a reservation
    /// is; a second, more permissive definition living in the shared path is
    /// exactly how the live gate would be quietly re-opened later.
    var ownerDispatch: RideRequestRecord? {
        guard let request = activeRequest else { return nil }
        switch request.status {
        case .accepted, .arrived, .enroute, .completed:
            return RideReservation.isLiveRide(request) ? request : nil
        case .pending, .declined: return nil
        }
    }

    /// Default: one record, one id (see above). Nothing ever pushes to a simulated
    /// run, so this exists to keep the protocol total.
    var incomingServerRideID: String? { incomingRequest?.id }

    /// Default: the simulated service (M1) has no network, so a mutation can
    /// never fail a live session — it never signals a session failure. Only
    /// `LiveRideRequestService` overrides this (MYR-220).
    var sessionFailure: RideSessionFailure? { nil }

    /// Default: the simulated service (M1) has no network, so no server can
    /// refuse a mutation with `409 vehicle_unavailable`. Only
    /// `LiveRideRequestService` overrides this (MYR-233).
    var vehicleUnavailableFailure: RideVehicleUnavailableFailure? { nil }

    /// Default: the simulated service (M1) has no network, so no server can
    /// refuse a scheduled mutation on a service window. Only
    /// `LiveRideRequestService` overrides this (MYR-316).
    var scheduleWindowFailure: RideScheduleWindowFailure? { nil }

    /// Default: the simulated service (M1) has no incoming FEED — its single
    /// `activeRequest` is the whole world (one rider, one owner, one in-process
    /// snapshot), so nothing can ever be queued behind it and the chip never
    /// renders. Only `LiveRideRequestService` overrides this (MYR-317); the DEBUG
    /// capture scene seeds the simulated service's own DEBUG-only counter.
    var waitingIncomingCount: Int { 0 }

    /// Default: the simulated service has no SOCKET, so no frame can arrive about
    /// anything. It stays `0` for the life of every simulated run and every DEBUG
    /// scene — which is what keeps MYR-381's refresh wiring incapable of moving a
    /// drift-gate capture. Only `LiveRideRequestService` overrides it.
    var scheduledSurfaceTick: Int { 0 }

    /// Default: no send-window deferral. The simulated service (M1) has no
    /// network — its `submit` already installs the full state machine, and the
    /// owner is the same in-process snapshot — so there is nothing to send
    /// later. Only `LiveRideRequestService` overrides this to fire the deferred
    /// create POST (MYR-218 defect 1).
    func confirmSend() {}

    /// Default: the simulated service has no server, so its ONE local id is also
    /// the only id anything could refer to. (Nothing ever pushes to a simulated
    /// run — `PushPermissionMoment` refuses to even prompt — so this exists to
    /// keep the protocol total, not because a sim notification can arrive.)
    var activeServerRideID: String? { activeRequest?.id }

    /// Default: no-op. The simulated service has no incoming FEED and no server
    /// ride to re-adopt — its single `activeRequest` is the whole world (see
    /// `waitingIncomingCount`). Only `LiveRideRequestService` overrides these
    /// (MYR-186), so a simulated run's behaviour is unchanged.
    func refreshIncoming() async {}
    func refreshActiveRide() async {}

    /// Default: no-op. The simulated service has no server ride to re-read and no
    /// second party — its ONE `activeRequest` is both roles' record and it lives
    /// only as long as the process, so there is nothing to restore and nothing to
    /// forget. Only `LiveRideRequestService` overrides these (MYR-396), which is
    /// what keeps every simulated run and every DEBUG capture byte-identical.
    func refreshOwnerDispatch() async {}
    func forgetOwnerDispatch() {}

    /// Default: no-op. A simulated reservation is reserved into Drives → Upcoming
    /// and never dispatches (there is no sweeper and no clock to run one), so there
    /// is no due moment to re-read. Only `LiveRideRequestService` overrides this
    /// (MYR-376/377).
    func refreshDueReservations() async {}

    /// Default: no-op. The simulated service has no server ride to advance — its
    /// tracking is driven by the `trackProgress` ticker, and the dispatch v2 CTAs
    /// (owner "Picked up" / "Dropped off", rider "Start ride") are gated to the LIVE
    /// path (`SharedViewerState.isLiveLocation`), so these never reach the sim. Only
    /// `LiveRideRequestService` overrides them (MYR-270).
    func pickedUp() {}
    func startRide() {}
    func droppedOff() {}
}

// MARK: - Timing constants (single source, per CLAUDE.md deliverable 2)

/// Every simulated delay in the ride-request flow, one place, each cited to
/// the jsx it ports. M2's real service deletes this file — dispatch timing
/// then comes from the backend.
public enum RideRequestTiming {
    /// Rider's booking CTA gold-fill sweep — ride-request.jsx:528,647 `10000ms linear`.
    public static let sendFillDuration: TimeInterval = 10
    /// Hold on "Request sent" before minimizing to idle — ride-request.jsx:524 `1000ms`.
    public static let sentHoldDuration: TimeInterval = 1
    /// Minimize-then-auto-accept fallback if the owner never manually
    /// intervenes — ride-request.jsx:1112-1117 `2600ms`.
    public static let minimizeToAutoAcceptDelay: TimeInterval = 2.6
    /// Owner's manual accept: tap → "Sending to {vehicle}…" — ride-request.jsx:1278 `700ms`.
    public static let ownerSendingDuration: TimeInterval = 0.7
    /// Owner's manual accept: "sent" checkmark hold before `onAccept` fires —
    /// ride-request.jsx:1279 (total 1700ms from tap; `1000ms` after `sent`).
    public static let ownerSentHoldDuration: TimeInterval = 1.0
    /// `RouteSentToast` auto-dismiss — app.jsx:144 `4200ms`.
    public static let toastAutoDismissDuration: TimeInterval = 4.2
    /// Fixed pickup leg ("car → rider") used by both Pending and Tracking —
    /// ride-request.jsx:554,751,918 `6 min`.
    public static let pickupLegMinutes: Double = 6
    /// `trackProgress` seed on auto-accept (no intermediate "accepted"
    /// banner) — screens.jsx:2081 `progressOverride = 0.06`.
    public static let autoAcceptInitialProgress: Double = 0.06
    /// Total wall-clock time to animate `trackProgress` 0→1 once accepted.
    /// The prototype has no reference auto-increment — `trackProgress` is
    /// entirely Tweaks-slider-driven there (see MYR-171 research notes); this
    /// compresses a ride the way `SimulatedVehicleTelemetrySource
    /// .demoDurationSeconds` already compresses a drive, so the tracking →
    /// Ride Summary transition is observable in a manual QA pass or the
    /// drift-gate screenshots without a real multi-minute wait.
    public static let trackingDemoDuration: TimeInterval = 48
    /// Rotating placeholder / search glow interval reused as-is
    /// (`SharedViewerScreen.RotatingPlaceholder`, MYR-191) — not redefined
    /// here.
}

// MARK: - Models

public enum RideRequestStatus: String, Sendable, Equatable {
    /// Sent, awaiting the owner's decision.
    case pending
    /// MYR-270 leg 1 — owner accepted; car en route to the PICKUP. The owner's
    /// "Picked up" (`pickedUp()`) is the affordance out of this state.
    case accepted
    /// MYR-270 — the rider has been picked up (owner confirmed); the car is at the
    /// pickup, awaiting the rider's "Start ride" (`start()`). NOT yet moving to the
    /// dropoff. The rider's Start CTA is gated to exactly this state.
    case arrived
    /// MYR-270 leg 2 — the ride has STARTED; car en route to the DROPOFF (the rider
    /// tapped Start, the backend flipped `arrived → enroute` and pushed the dropoff
    /// nav). The owner's "Dropped off" (`droppedOff()`) is the affordance out here.
    case enroute
    /// MYR-270 — dropped off (owner tapped "Dropped off"; no drive-end auto-complete).
    case completed
    /// Owner declined.
    case declined
}

/// MYR-220: a mutation failed because the SESSION died (the token expired
/// mid-session → the deferred create POST got 401 / an auth-shaped 403), NOT
/// because the owner refused. Distinct from `.declined` so the rider's flow can
/// route to a calm retry instead of the owner-decline affordance. Carries a
/// fresh `id` per occurrence so a repeat failure still fires the observing
/// `.onChange` (two identical decline-shaped failures must not coalesce and drop
/// the retry notice).
public struct RideSessionFailure: Identifiable, Equatable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// MYR-233: a ride mutation was refused `409 vehicle_unavailable` — the target
/// vehicle can't take this ride right now (it already carries an open instant
/// ride, or it is in service / offline). Distinct from `.declined` (the owner
/// refused) and from `RideSessionFailure` (the token died): nobody refused the
/// rider, the CAR is busy, so the honest route is the scheduling flow. Carries a
/// fresh `id` per occurrence for the same reason `RideSessionFailure` does — two
/// consecutive refusals must not coalesce and drop the second notice.
public struct RideVehicleUnavailableFailure: Identifiable, Equatable, Sendable {
    public let id: UUID

    /// MYR-385 — the refusal's `subCode` was `time_conflict` (MYR-383's
    /// per-vehicle window gate): the car is not unavailable at all, the TIME is
    /// already spoken for.
    ///
    /// **A DISCRIMINATOR ON THE EXISTING FAILURE, NOT A NEW ONE**, and the choice
    /// is deliberate. Every routing decision is identical — no ride was created,
    /// nobody declined, the draft is intact and the rider goes back to Review — so
    /// a second failure type would have meant a second `onChange`, a second
    /// handler and a second chance for the two to drift. What differs is exactly
    /// one sentence, because MYR-233's *"That car just became unavailable. Your
    /// trip's saved — try scheduling it."* is **two lies and a non-sequitur** when
    /// the refusal is a time conflict: the car did not become unavailable, the
    /// rider's own noon reservation is why, and "try scheduling it" is a strange
    /// instruction for somebody who was already scheduling. That sentence landing
    /// on the r15 report is what MYR-385 is about.
    ///
    /// Defaults to `false`, so the broader `vehicle_unavailable` arm — a car in
    /// service, offline, or already carrying a ride — is untouched.
    public let isTimeConflict: Bool

    public init(id: UUID = UUID(), isTimeConflict: Bool = false) {
        self.id = id
        self.isTimeConflict = isTimeConflict
    }
}

/// MYR-316: a SCHEDULED ride mutation was refused `400 invalid_request` because
/// the requested pickup precedes the vehicle's estimated return from service.
/// Distinct from `.declined` (the owner refused), from
/// `RideVehicleUnavailableFailure` (the car is busy RIGHT NOW, and the answer is
/// to schedule), and from `RideSessionFailure` (the token died) — here the rider
/// already IS scheduling, and the only thing wrong is which time they picked.
///
/// The server names the estimated end in its human message, but this type does
/// NOT carry it: the app must not parse a server sentence to drive UI (FR-7.1),
/// and it does not need to — the rider's own fleet row holds the same instant, so
/// the picker re-floors itself from typed data on the way back.
public struct RideScheduleWindowFailure: Identifiable, Equatable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public struct RideSchedule: Sendable, Equatable {
    public var day: String
    public var time: String
    public init(day: String, time: String) {
        self.day = day
        self.time = time
    }
}

/// What the rider is asking for — ride-request.jsx's `requestDest` +
/// `requestPassenger` + `requestKind`/`requestSchedule` + the chosen
/// `FleetMember`, bundled into one value the service can stamp with a status.
public struct RideRequestInput: Sendable, Equatable {
    public var pickup: RidePlace
    public var destination: RidePlace
    public var fleetMemberID: String
    public var passenger: RidePassenger?
    public var schedule: RideSchedule?
    /// MYR-264 — the REAL rider display name carried off the wire record
    /// (`RideRequest.requesterName`), so the owner's `IncomingRequestSheet` shows
    /// "<Name> wants a ride". `nil` on the SIM/fixture path (the sheet then uses
    /// its fixture "Sam" persona) and `nil`/absent for a live request whose backend
    /// omitted a name (→ a neutral honest role label). NEVER a fabricated persona.
    public var requesterName: String?

    public init(pickup: RidePlace, destination: RidePlace, fleetMemberID: String, passenger: RidePassenger? = nil, schedule: RideSchedule? = nil, requesterName: String? = nil) {
        self.pickup = pickup
        self.destination = destination
        self.fleetMemberID = fleetMemberID
        self.passenger = passenger
        self.schedule = schedule
        self.requesterName = requesterName
    }

    public var fleetMember: FleetMember {
        RideRequestFixtures.fleet.first { $0.id == fleetMemberID } ?? RideRequestFixtures.fleet[0]
    }
}

public struct RideRequestRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public var input: RideRequestInput
    public var status: RideRequestStatus
    public let requestedAt: Date
    public var acceptedAt: Date?
    /// 0...1 along the whole trip (pickup leg + drop-off leg combined) —
    /// `nil` until `.accepted`. `>= 0.999` is "arrived" (ride-request.jsx:
    /// 1125,1245 `isSummary`).
    public var trackProgress: Double?

    // MARK: MYR-376/377 — the reservation's own three wire facts
    //
    // `input.schedule` is a pair of DISPLAY strings ("Tomorrow" / "12:00 PM"),
    // which is all any surface needed while a reservation was a row in a list.
    // The dormancy model needs the INSTANT (to know when the ride becomes live)
    // and the DISPATCH LATCH (to know whether it already has), so all three
    // travel on the record now. They are `nil` on every SIM/fixture record and
    // on a live INSTANT ride, so nothing that does not carry a schedule changes.

    /// The reserved pickup INSTANT (`RideRequest.scheduledFor`), in absolute
    /// time. `nil` for an on-demand ride and for every simulated record.
    ///
    /// Distinct from `input.schedule`, which is the pair of display strings the
    /// picker committed: a day token and a wall clock cannot be compared with
    /// `Date()`, and the due-time flip has to be.
    public var scheduledFor: Date?

    /// The outcome of the server's nav-dispatch push (`RideRequest.dispatchStatus`).
    /// Absent until dispatch resolves — and for a RESERVATION that is the
    /// reservation sweeper firing at due time, which is the moment the ride stops
    /// being dormant.
    public var dispatchStatus: DispatchStatus?

    /// When the nav-dispatch was CLAIMED (`RideRequest.dispatchedAt`) — the
    /// server's exactly-once latch, and the client's single clearest evidence
    /// that a reservation has gone live.
    public var dispatchedAt: Date?

    public init(id: String = UUID().uuidString, input: RideRequestInput, status: RideRequestStatus = .pending, requestedAt: Date = Date()) {
        self.id = id
        self.input = input
        self.status = status
        self.requestedAt = requestedAt
    }

    /// `pickupMins / (pickupMins + tripMins)` — the leg split
    /// (ride-request.jsx:751-757).
    public var pickupCut: Double {
        let pickupMins = RideRequestTiming.pickupLegMinutes
        let tripMins = Double(max(input.destination.minutes, 1))
        return pickupMins / (pickupMins + tripMins)
    }

    public var isArrived: Bool { (trackProgress ?? 0) >= 0.999 }

    /// MYR-265 — the whole-trip `trackProgress` anchor for the LIVE leg-2 seed
    /// ("aboard, just past pickup, heading to drop-off"). v1 live has no per-second
    /// progress ticker (MYR-176/177), so an `enroute` ride mounts the tracking sheet
    /// at this static point — the leg-2 analog of `autoAcceptInitialProgress`'s
    /// leg-1 seed — which puts `TrackingLeg`/`atPickup`/the itinerary/the leg-fit
    /// camera all on leg 2 with no new plumbing. Past `pickupCut`, well short of the
    /// `>= 0.999` "arrived" summary trigger.
    public var enrouteSeedProgress: Double {
        pickupCut + (1 - pickupCut) * RideRequestTiming.autoAcceptInitialProgress
    }
}
