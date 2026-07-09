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

    // NOTE ON DRIVES: rest-api.md §7.2/§7.3 (`/vehicles/{id}/drives`,
    // `/drives/{id}`) return REST-only shapes that are declared inline in the
    // OpenAPI document and have NO generated `MyRobotaxiContracts` type in
    // v0.5.0. Because the Kit's hard rule is "contracts types only — no
    // hand-written wire shapes", the drives read-path is intentionally NOT
    // implemented here; it unblocks the moment a `Drive` / `DriveSummary`
    // contracts type is generated. `vehicles` + `snapshot` are the typed
    // read-path the app needs first.

    // MARK: - Request pipeline

    private func get<T: Decodable>(_ segments: [String]) async throws -> T {
        try await perform(segments, method: "GET", allowTokenRefresh: true)
    }

    private func perform<T: Decodable>(
        _ segments: [String],
        method: String,
        allowTokenRefresh: Bool
    ) async throws -> T {
        let url = segments.reduce(environment.restBaseURL) { $0.appendingPathComponent($1) }
        try validateTransport(url)

        // FR-6.1/6.2: fetch the token per request; on the 401 retry the provider
        // is asked again so it can hand back a freshly-refreshed value.
        let token = try await tokenProvider.token()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
            return try await perform(segments, method: method, allowTokenRefresh: false)
        default:
            throw Self.mapError(status: httpResponse.statusCode, data: data)
        }
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
