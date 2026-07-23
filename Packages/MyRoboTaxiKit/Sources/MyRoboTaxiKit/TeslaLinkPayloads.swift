import Foundation

// MARK: - In-app Tesla link wire shapes (rest-api.md §7.11, MYR-246)
//
// Same EXCEPTION as `AuthPayloads.swift`: the §7.11 owner-onboarding surface
// (`POST /api/tesla/link/start`) landed on the backend AFTER the last
// `MyRobotaxiContracts` codegen (v0.9.0) and has no JSON Schema in the telemetry
// repo yet, so there is no generated `TeslaLinkStart*` type to import. This one
// small response DTO is authored here, verbatim from rest-api.md §7.11.1, and
// MUST be replaced by the generated type the moment `contracts` regenerates the
// tesla-link schema (codegen follow-up — see the PR body). Codable/Equatable/
// Sendable to match the generated-type conventions so the swap is drop-in.

/// Response of `POST /api/tesla/link/start` (§7.11.1) — the server-minted Tesla
/// authorize URL (server-side PKCE + `state`; the `client_secret` never reaches
/// the device) plus the `state` nonce echoed for optional client correlation.
///
/// Both fields are P0 (public): `authorizeUrl` carries no secret, and `state` is
/// a CSRF nonce whose authority lives server-side. Neither is ever logged or
/// persisted by the client (swift-lifecycle: no token/URL query material on disk
/// or in logs).
public struct TeslaLinkStartResponse: Codable, Equatable, Sendable {
    /// The public Tesla authorize URL to open in `ASWebAuthenticationSession`.
    public var authorizeUrl: String
    /// CSRF nonce / server-side session key. Echoed for optional correlation; the
    /// server is the sole authority on its validation.
    public var state: String

    public init(authorizeUrl: String, state: String) {
        self.authorizeUrl = authorizeUrl
        self.state = state
    }
}

/// The in-app Tesla-link surface (rest-api.md §7.11, MYR-246), factored into its
/// own protocol so callers depend only on "start a link" and can be tested with
/// a stub — the same narrowing pattern as ``SnapshotFetching`` /
/// ``AuthenticationEndpoint``. `RestClient` is the production conformer.
///
/// Unlike ``AuthenticationEndpoint``, this IS an authenticated endpoint: it runs
/// the standard Bearer + 401-refresh pipeline (the caller must already be a
/// signed-in owner).
public protocol TeslaLinkEndpoint: Sendable {
    /// `POST /api/tesla/link/start` (§7.11.1) — mint the Tesla authorize URL for
    /// the signed-in owner. Owner-authenticated; no request body.
    func teslaLinkStart() async throws -> TeslaLinkStartResponse
}
