import Foundation

/// The identity-module auth surface (rest-api.md §7.10, MYR-193), factored into
/// its own protocol so ``SessionTokenProvider`` depends only on "exchange /
/// rotate / revoke" and can be tested with a stub — the same narrowing pattern
/// as ``SnapshotFetching``. `RestClient` is the production conformer.
///
/// All three are **pre-authentication**: they mint or rotate the very Bearer
/// credential every other endpoint requires, so the conformer MUST NOT attach a
/// Bearer header and MUST NOT run the 401 refresh-retry loop on them (that loop
/// is what calls `refresh(...)` — recursing through it would be circular).
public protocol AuthenticationEndpoint: Sendable {
    /// `POST /api/auth/apple` (§7.10.1) — validate a native Sign in with Apple
    /// identity token and mint the first token pair.
    func signInWithApple(_ body: AppleSignInRequest) async throws -> AuthTokenResponse

    /// `POST /api/auth/refresh` (§7.10.2) — single-use refresh-token rotation.
    /// Presenting a spent/revoked token revokes the whole family → `401`.
    func refreshSession(_ body: RefreshTokenRequest) async throws -> AuthTokenResponse

    /// `POST /api/auth/revoke` (§7.10.3) — revoke the token's family (sign-out).
    /// Always `204` for a well-formed request; never leaks whether the token
    /// existed.
    func revokeSession(_ body: RefreshTokenRequest) async throws
}
