import Foundation

// MARK: - Identity-module wire shapes (rest-api.md §7.10, MYR-193)
//
// EXCEPTION to the Kit's "owns ZERO wire shapes" rule (see Package.swift
// header): the auth surface (MYR-193) landed on the backend AFTER the last
// `MyRobotaxiContracts` codegen (v0.9.0), whose generated set covers only the
// vehicle / drive / ride-request / WebSocket shapes — there is no `AppleSignIn*`
// / token-pair type to import, and no JSON Schema in the telemetry repo for the
// codegen to derive one from yet. These four small pre-auth DTOs are therefore
// authored here, verbatim from rest-api.md §7.10, and MUST be replaced by the
// generated types the moment `contracts` regenerates the auth schemas (tracked
// as a codegen follow-up — see the PR body). They are Codable/Equatable/Sendable
// to match the generated-type conventions so the swap is drop-in.

/// Body of `POST /api/auth/apple` (§7.10.1) — a native Sign in with Apple
/// authorization forwarded for validation + token minting.
public struct AppleSignInRequest: Codable, Equatable, Sendable {
    /// The Apple identity token (JWT) from
    /// `ASAuthorizationAppleIDCredential.identityToken`. Required.
    public var identityToken: String
    /// Apple returns the human name only on the FIRST authorization; the client
    /// forwards it so the server can persist it on first sign-in. Omitted (nil)
    /// on every subsequent sign-in.
    public var fullName: String?
    /// Advisory only — the server links on the token's verified-email claim,
    /// never this field. Present on first authorization when the user shared it.
    public var email: String?
    /// If present, must equal the token's `nonce` claim server-side. The client
    /// sends the SAME value it set on `ASAuthorizationAppleIDRequest.nonce`
    /// (Apple embeds that verbatim into the token's `nonce` claim).
    public var nonce: String?

    public init(identityToken: String, fullName: String? = nil, email: String? = nil, nonce: String? = nil) {
        self.identityToken = identityToken
        self.fullName = fullName
        self.email = email
        self.nonce = nonce
    }
}

/// Body of `POST /api/auth/refresh` (§7.10.2) and `POST /api/auth/revoke`
/// (§7.10.3) — the opaque refresh token, the only credential these two
/// pre-auth endpoints accept.
public struct RefreshTokenRequest: Codable, Equatable, Sendable {
    public var refreshToken: String
    public init(refreshToken: String) { self.refreshToken = refreshToken }
}

/// The token pair returned by `POST /api/auth/apple` (§7.10.1) and
/// `POST /api/auth/refresh` (§7.10.2). `user` carries at least `id`; `name` /
/// `email` are present when known and omitted otherwise.
public struct AuthTokenResponse: Codable, Equatable, Sendable {
    /// ES256 JWT, ~1h. The Bearer token for every other endpoint. Hold in
    /// MEMORY only (never persist — see `SessionTokenProvider`).
    public var accessToken: String
    /// Access-token lifetime in seconds (nominally 3600). Drives the proactive
    /// refresh schedule (refresh at `expiresIn − margin`).
    public var expiresIn: Int
    /// Opaque single-use refresh token — store in the Keychain, send only to
    /// `/api/auth/refresh` | `/revoke`. Rotates on every refresh.
    public var refreshToken: String
    /// The authenticated user (`id` always; `name` / `email` when known).
    public var user: AuthUser

    public init(accessToken: String, expiresIn: Int, refreshToken: String, user: AuthUser) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.user = user
    }
}

/// The `user` object nested in ``AuthTokenResponse`` (§7.10.1).
public struct AuthUser: Codable, Equatable, Sendable {
    /// User CUID (`sub` of the access token). Always present.
    public var id: String
    /// Display name — present when known (first sign-in, or a previously
    /// persisted name), omitted otherwise.
    public var name: String?
    /// Verified email — present when known, omitted otherwise.
    public var email: String?

    public init(id: String, name: String? = nil, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}
