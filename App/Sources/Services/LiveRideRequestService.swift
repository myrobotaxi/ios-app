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
//  • No enroute / arrived / completed. After accept, the rider's tracking sheet
//    mounts at the static `autoAcceptInitialProgress` seed (heading-to-pickup)
//    with NO progress ticker and NO summary auto-advance — reusing existing UI,
//    inventing no new screen (dead-code rule).
//  • Create targets the caller's first owned vehicle (the demo's single shared
//    car); the fixture fleet-picker → live-vehicle join is future work (needs the
//    MYR-91 shared-viewer access set + a live Review picker). Display-only fleet
//    fields fall back to fixtures — see `RideRequestContractMapping`.
//  • Live scheduled-create time encoding is deferred; live `submit` sends an
//    on-demand request (the demo is "now"). Server-supplied `scheduledFor` still
//    decodes for display on the incoming/detail path.
@Observable
@MainActor
final class LiveRideRequestService: RideRequestService {
    private(set) var activeRequest: RideRequestRecord?

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
                if Self.isDefinitiveCreateFailure(error) {
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
        postMutation { try await $0.acceptRideRequest(id: $1) }
    }

    func decline() {
        guard var request = activeRequest, request.status == .pending else { return }
        request.status = .declined
        activeRequest = request
        postMutation { try await $0.declineRideRequest(id: $1) }
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
        serverRideID = nil
        guard let id else { return }
        let api = self.api
        Task { _ = try? await api.cancelRideRequest(id: id) }
    }

    func completeAndReset() -> RequestedRide? {
        // v1 has no completed lifecycle (MYR-176/177), so the Ride Summary is
        // unreachable in live mode. Reset defensively; nothing to persist.
        activeRequest = nil
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
            // Cancelled / terminal — drop it if it's the ride we're tracking.
            if isCurrent(ride.id) { activeRequest = nil; serverRideID = nil }
            return
        }
        if isCurrent(ride.id) {
            // Update status in place, preserving the richer local draft input.
            // `record(from:)` is non-nil here (it returns nil only for the
            // already-handled cancelled/terminal case above).
            var current = activeRequest ?? RideRequestContractMapping.record(from: ride)!
            current.status = mapped!
            current.acceptedAt = ride.acceptedAt.flatMap(RideRequestContractMapping.parseISO)
            if mapped == .accepted, current.trackProgress == nil, current.input.schedule == nil {
                current.trackProgress = RideRequestTiming.autoAcceptInitialProgress
            }
            activeRequest = current
            serverRideID = ride.id
        } else if activeRequest == nil, mapped == .pending {
            // OWNER side: a brand-new incoming request from another device.
            if let record = RideRequestContractMapping.record(from: ride) {
                activeRequest = record
                serverRideID = ride.id
            }
        }
    }

    private func isCurrent(_ rideID: String) -> Bool {
        rideID == serverRideID || rideID == activeRequest?.id
    }

    /// Owner incoming feed seed (open requests already in flight at connect time).
    private func refreshIncoming() async {
        guard activeRequest == nil else { return }
        guard let page = try? await api.incomingRideRequests(cursor: nil, limit: 20) else { return }
        guard let first = page.items.first, let record = RideRequestContractMapping.record(from: first) else { return }
        activeRequest = record
        serverRideID = first.id
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

    private static func createBody(from input: RideRequestInput, vehicleId: String) -> RideRequestCreateRequest {
        RideRequestCreateRequest(
            vehicleId: vehicleId,
            pickup: wirePlace(input.pickup),
            dropoff: wirePlace(input.destination),
            passengerName: input.passenger?.name,
            passengerPhone: input.passenger.flatMap { $0.phone.isEmpty ? nil : $0.phone },
            scheduledFor: nil // live scheduled-create encoding deferred — see header
        )
    }

    private static func wirePlace(_ place: RidePlace) -> MyRobotaxiContracts.RidePlace {
        MyRobotaxiContracts.RidePlace(
            lat: place.coordinate.latitude,
            lng: place.coordinate.longitude,
            label: place.label,
            address: place.subtitle
        )
    }
}
