import Foundation
import MyRobotaxiContracts

/// The snapshot half of the read-path, factored into its own protocol so the
/// telemetry socket depends only on "give me the current `VehicleState`" and can
/// be tested with a stub. `RestClient` is the production conformer.
public protocol SnapshotFetching: Sendable {
    /// `GET /api/vehicles/{vehicleId}/snapshot` — the reconnect baseline
    /// (NFR-3.11, Rule CG-SM-4).
    func snapshot(vehicleId: String) async throws -> VehicleState
}

/// URLSession-based REST client for the read-path the app needs first. Base-URL
/// + bearer-token injection via an async ``TokenProvider`` (MYR-193's real auth
/// slots in). Every response decodes into a generated `MyRobotaxiContracts`
/// type — the client owns no wire shapes of its own.
///
/// Value type (`Sendable`): all dependencies are immutable, so it is free to
/// share across tasks without a serialization bottleneck.
public struct RestClient: Sendable, SnapshotFetching {
    private let environment: BackendEnvironment
    private let tokenProvider: any TokenProvider
    private let http: any HTTPPerforming
    private let decoder: JSONDecoder

    public init(
        environment: BackendEnvironment,
        tokenProvider: any TokenProvider,
        http: any HTTPPerforming
    ) {
        self.environment = environment
        self.tokenProvider = tokenProvider
        self.http = http
        self.decoder = JSONDecoder()
    }

    /// Convenience initializer wiring a `URLSession` tuned per swift-lifecycle.md
    /// §4 (waits-for-connectivity, request/resource timeouts).
    public init(environment: BackendEnvironment, tokenProvider: any TokenProvider) {
        self.init(
            environment: environment,
            tokenProvider: tokenProvider,
            http: URLSession(configuration: RestClient.defaultConfiguration())
        )
    }

    // MARK: - Endpoints

    /// `GET /api/vehicles` — the caller's vehicle catalog (rest-api.md §7.0).
    /// Returns the unwrapped rows; the `VehicleListResponse` envelope is a
    /// contract detail handled here.
    public func vehicles() async throws -> [VehicleSummary] {
        let response: VehicleListResponse = try await get(["vehicles"])
        return response.items
    }

    /// `GET /api/vehicles/{vehicleId}/snapshot` — cold-load full `VehicleState`
    /// (rest-api.md §7.1). This is the snapshot the telemetry socket re-fetches
    /// before resuming the live stream on every reconnect (NFR-3.11, CG-SM-4).
    public func snapshot(vehicleId: String) async throws -> VehicleState {
        try await get(["vehicles", vehicleId, "snapshot"])
    }

    /// `GET /api/vehicles/{vehicleId}/drives` — one page of the vehicle's
    /// completed-drive history, newest first (rest-api.md §7.2). Cursor-based
    /// pagination (§4.2): pass a prior response's `nextCursor` to fetch the next
    /// page; `nil` on the first page. Use `hasMore` (or `nextCursor != nil`) as
    /// the paging predicate — `null nextCursor` means the last page. `limit` is
    /// clamped to the contract's 1…100 range. Returns the `DrivesListResponse`
    /// envelope (items + nextCursor + hasMore) — the envelope IS the contract,
    /// so it is surfaced whole rather than unwrapped.
    public func drives(
        vehicleID: String,
        cursor: String? = nil,
        limit: Int = 20
    ) async throws -> DrivesListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["vehicles", vehicleID, "drives"], query: query)
    }

    /// `GET /api/drives/{driveId}` — the full FR-3.4 record for one completed
    /// drive (rest-api.md §7.3): the detail-only `energyUsedKwh` / `interventions`
    /// on top of the `DriveSummary` stats. The tap-through target behind a
    /// `DriveSummary` row / a `drive_ended` frame (the SDK's `fetchDrive`).
    /// Returned as a bare object (no envelope).
    public func drive(id: String) async throws -> Drive {
        try await get(["drives", id])
    }

    /// `GET /api/drives/{driveId}/route` — the full GPS polyline for one
    /// completed drive (rest-api.md §7.4, `DriveRoute`). Deliberately excluded
    /// from both the drives list (§7.2) and drive detail (§7.3): it is the heavy
    /// per-drive payload (~3.6k points / ~250 KB for an hour drive), fetched
    /// LAZILY on tap-through of a drive's map, never eagerly per list row (§7.4
    /// lazy-fetch guidance — cellular bandwidth / perceived latency). Returned as
    /// a bare object; `routePoints` is ALWAYS an array (`[]`, never null, for a
    /// very short drive) — callers branch on `.isEmpty`, not on optionality.
    public func driveRoute(id: String) async throws -> DriveRoute {
        try await get(["drives", id, "route"])
    }

    // MARK: - Ride requests (rest-api.md §7.8, P10 ride-hailing — MYR-174 rider
    // surface + MYR-175 owner surface)
    //
    // Every method decodes a generated `MyRobotaxiContracts` ride type — the Kit
    // owns no ride shapes of its own. The single-resource paths return a bare
    // `RideRequest`; the list paths return the `RideRequestsListResponse`
    // envelope whole (the envelope IS the contract, same as `drives`). An illegal
    // lifecycle mutation surfaces as `RestError.http(status: 409, code: .conflict …)`
    // (§7.8 transition matrix) — callers MUST NOT auto-retry the same mutation.

    /// `POST /api/ride-requests` (rest-api.md §7.8) — the rider's Review-sheet
    /// submit. Body is the strict `RideRequestCreateRequest` (unknown keys →
    /// `400 invalid_request` server-side). Responds `201 Created` with the full
    /// server-assigned `RideRequest` and unicasts `ride_request_created` to the
    /// rider + owner over the WS.
    public func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        try await post(["ride-requests"], body: body)
    }

    /// `GET /api/ride-requests` (rest-api.md §7.8) — the authenticated rider's
    /// own requests, newest first (`createdAt DESC, id DESC`), cursor-paginated
    /// per §4.2. Returns the envelope whole (`items` always present — `[]` never
    /// null; `nextCursor` null on the final page).
    public func rideRequests(cursor: String? = nil, limit: Int = 20) async throws -> RideRequestsListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["ride-requests"], query: query)
    }

    /// `GET /api/ride-requests/incoming` (rest-api.md §7.8, MYR-175) — the
    /// OWNER's feed of open (`requested`-only) requests across their vehicles,
    /// on-demand + scheduled variants both. Same envelope + `(createdAt, id)`
    /// cursor as `rideRequests`. Decided rows leave the feed by construction.
    public func incomingRideRequests(cursor: String? = nil, limit: Int = 20) async throws -> RideRequestsListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["ride-requests", "incoming"], query: query)
    }

    /// `GET /api/ride-requests/{id}` (rest-api.md §7.8) — the full `RideRequest`
    /// behind a `ride_request_created` / `ride_status_changed` summary frame
    /// (the frames are summary-only; pickup/dropoff/passenger live here). Party-
    /// only server-side: a non-party gets `404` (existence is never leaked).
    public func rideRequest(id: String) async throws -> RideRequest {
        try await get(["ride-requests", id])
    }

    /// `POST /api/ride-requests/{id}/cancel` (rest-api.md §7.8) — RIDER-only.
    /// Legal from `requested`/`accepted` → `cancelled`; any other state is
    /// `409 conflict`. Responds `200 OK` with the updated `RideRequest`.
    public func cancelRideRequest(id: String) async throws -> RideRequest {
        try await post(["ride-requests", id, "cancel"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/accept` (rest-api.md §7.8, MYR-175) —
    /// OWNER-only. Legal only from `requested` → `accepted`; else `409 conflict`.
    /// Responds `200 OK` with the updated `RideRequest` (now carrying
    /// `acceptedAt`) and unicasts `ride_status_changed` to both parties.
    public func acceptRideRequest(id: String) async throws -> RideRequest {
        try await post(["ride-requests", id, "accept"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/decline` (rest-api.md §7.8, MYR-175) —
    /// OWNER-only. Legal only from `requested` → `declined`; else `409 conflict`.
    public func declineRideRequest(id: String) async throws -> RideRequest {
        try await post(["ride-requests", id, "decline"], body: Optional<Empty>.none)
    }

    /// Empty JSON body sentinel for the action POSTs that take no payload
    /// (`/cancel`, `/accept`, `/decline`). Encodes to `{}`.
    private struct Empty: Encodable {}

    // MARK: - Request pipeline

    private func get<T: Decodable>(_ segments: [String], query: [URLQueryItem] = []) async throws -> T {
        try await perform(segments, query: query, method: "GET", body: nil, allowTokenRefresh: true)
    }

    /// `POST` with an optional JSON body (nil for the no-payload action
    /// endpoints). The body is encoded once and reused across the single 401
    /// refresh-retry so the provider's fresh token rides the same payload.
    private func post<T: Decodable>(_ segments: [String], body: (some Encodable)?) async throws -> T {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await perform(segments, query: [], method: "POST", body: data, allowTokenRefresh: true)
    }

    private func perform<T: Decodable>(
        _ segments: [String],
        query: [URLQueryItem] = [],
        method: String,
        body: Data?,
        allowTokenRefresh: Bool
    ) async throws -> T {
        let url = try Self.buildURL(base: environment.restBaseURL, segments: segments, query: query)
        try validateTransport(url)

        // FR-6.1/6.2: fetch the token per request; on the 401 retry the provider
        // is asked again so it can hand back a freshly-refreshed value.
        let token = try await tokenProvider.token()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw RestError.transport(underlying: error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RestError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw RestError.decoding(underlying: error) }
        case 401 where allowTokenRefresh:
            // FR-6.2: do NOT retry with the same token — refresh once, retry
            // exactly once, then surface the typed error.
            return try await perform(segments, query: query, method: method, body: body, allowTokenRefresh: false)
        default:
            throw Self.mapError(status: httpResponse.statusCode, data: data)
        }
    }

    /// Compose the request URL by appending each path segment to the REST base
    /// and folding in query items. Path segments are percent-encoded by
    /// `appendingPathComponent`; query items by `URLComponents`. Throws
    /// `invalidResponse` if the composed URL is malformed (unreachable in
    /// practice — the segments are contract-fixed identifiers).
    private static func buildURL(base: URL, segments: [String], query: [URLQueryItem]) throws -> URL {
        let path = segments.reduce(base) { $0.appendingPathComponent($1) }
        guard !query.isEmpty else { return path }
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else {
            throw RestError.invalidResponse
        }
        components.queryItems = query
        guard let url = components.url else { throw RestError.invalidResponse }
        return url
    }

    private func validateTransport(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else { throw RestError.insecureTransport(url) }
        if scheme == "https" { return }
        if scheme == "http", environment.allowsInsecureLoopback {
            let host = url.host?.lowercased()
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return }
        }
        throw RestError.insecureTransport(url)
    }

    private static func mapError(status: Int, data: Data) -> RestError {
        struct Envelope: Decodable { let error: ErrorPayload }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return .http(
                status: status,
                code: envelope.error.code,
                message: envelope.error.message,
                subCode: envelope.error.subCode
            )
        }
        return .http(status: status, code: nil, message: nil, subCode: nil)
    }

    /// URLSession configuration per swift-lifecycle.md §4: waits for
    /// connectivity, 30s request / 60s resource timeouts.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }
}
