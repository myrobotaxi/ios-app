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

    private let api: any RideRequestAPI
    private let socket: any RideEventStreaming
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can cancel it — only ever
    /// touched on the main actor otherwise (same precedent as
    /// `SimulatedRideRequestService`'s timers).
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?

    init(api: any RideRequestAPI, socket: any RideEventStreaming, autoStart: Bool = true) {
        self.api = api
        self.socket = socket
        if autoStart { start() }
    }

    deinit {
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
        // synchronously, so it must be pending the instant this returns.
        activeRequest = RideRequestRecord(input: input, status: .pending)
        serverRideID = nil
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
                // MYR-212 defect 3: do NOT drop the optimistic pending on a
                // create error. The client's live QA saw a frozen "10s" +
                // placeholder labels ("Destination", 14 mi, 28 min) on Booking
                // because a create round-trip that errored on the CLIENT (e.g. a
                // transport blip or a response-decode mismatch) even though the
                // server had created the ride nilled `activeRequest`, leaving
                // Booking with no record — its countdown reads
                // `record.requestedAt` and its labels read `record.input`, so a
                // nil record freezes at 10s with fixture-ish fallbacks. Keeping
                // the optimistic record makes live Booking behave exactly like
                // sim: the 10s fill ticks down off `requestedAt` and carries the
                // REAL draft labels; a WS `ride_request_created` frame then
                // reconciles the real record (or the rider cancels from the
                // pending pill if it truly never landed).
            }
        }
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
