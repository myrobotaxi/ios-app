import Foundation

/// Reasons ``SessionTokenProvider/token()`` cannot produce a Bearer token
/// without user interaction. The app's auth layer surfaces these as an
/// interactive re-sign-in (rest-api.md §7.10 session contract).
public enum SessionError: Error, Sendable, Equatable {
    /// No session exists — there is no stored refresh token to refresh from.
    /// The user has never signed in on this device, or was signed out.
    case notSignedIn
    /// A refresh was attempted but the refresh token was rejected (spent,
    /// expired, or the family was revoked — a `401` from `/api/auth/refresh`).
    /// The stored session has been cleared; the user must sign in again.
    case sessionExpired
}

/// The real ``TokenProvider`` for MyRoboTaxi's backend session (rest-api.md
/// §7.10 session contract, MYR-164). Implements the backend author's
/// recommendation exactly:
///
/// - **accessToken in MEMORY only** — never persisted; gone on process death,
///   rebuilt from the refresh token on next launch.
/// - **refreshToken in the KEYCHAIN** — via the injected ``RefreshTokenStore``.
/// - **proactive refresh at `expiresIn − margin`** — `token()` refreshes when
///   the cached access token is within `refreshMargin` (default 60 s) of expiry,
///   so a request never rides an about-to-expire token.
/// - **one refresh + retry on a Bearer 401** — the transport calls
///   ``invalidate(rejectedToken:)`` with the token the server rejected; the next
///   `token()` then forces a refresh. A second 401 surfaces the typed error
///   (the transport does not retry again) → interactive re-sign-in.
/// - **single-use rotation is honored** — concurrent `token()` callers coalesce
///   onto ONE in-flight refresh, so the single-use refresh token is spent
///   exactly once (a double-spend would revoke the whole family, §7.10.2).
///
/// An `actor`: all mutable session state is actor-isolated, so it is `Sendable`
/// and free of data races under the Kit's complete-concurrency checking.
public actor SessionTokenProvider: TokenProvider {
    private let auth: any AuthenticationEndpoint
    private let store: any RefreshTokenStore
    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval

    /// Access token + its absolute expiry — memory only.
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    /// The single in-flight refresh, so concurrent callers coalesce (see above).
    private var refreshTask: Task<AuthTokenResponse, Error>?

    /// - Parameters:
    ///   - auth: the identity-module endpoint (a `RestClient`; see the
    ///     `AuthenticationEndpoint` note — it needs no Bearer token itself, so in
    ///     production it is a `RestClient` built with a throwaway static provider).
    ///   - store: secure storage for the refresh token (Keychain in production).
    ///   - refreshMargin: refresh this many seconds before the access token
    ///     actually expires (default 60 s per the §7.10 contract).
    ///   - now: clock, injected for deterministic proactive-refresh tests.
    public init(
        auth: any AuthenticationEndpoint,
        store: any RefreshTokenStore,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.auth = auth
        self.store = store
        self.refreshMargin = refreshMargin
        self.now = now
    }

    // MARK: - TokenProvider

    /// Return a valid Bearer access token, refreshing proactively (or on demand
    /// after an ``invalidate(rejectedToken:)``) as needed. Throws
    /// ``SessionError/notSignedIn`` when no session exists, or
    /// ``SessionError/sessionExpired`` when the refresh token is no longer valid.
    public func token() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, now() < expiry.addingTimeInterval(-refreshMargin) {
            return accessToken
        }
        return try await refreshAccessToken()
    }

    /// The transport rejected a request bearing `rejectedToken` with a 401.
    /// Drop it from memory (keep the refresh token) so the transport's retry —
    /// which calls `token()` again — forces a fresh refresh. A no-op if the
    /// rejected token is already stale (a concurrent refresh replaced it).
    public func invalidate(rejectedToken: String) async {
        if accessToken == rejectedToken {
            accessToken = nil
            accessTokenExpiry = nil
        }
    }

    // MARK: - Sign-in / sign-out (driven by the app's AuthSession)

    /// Complete a native Sign in with Apple: exchange the credential at
    /// `POST /api/auth/apple` and adopt the returned session. Returns the signed
    /// in user. Throws on cancel/failure (the app keeps the user on the sheet).
    @discardableResult
    public func completeAppleSignIn(_ request: AppleSignInRequest) async throws -> AuthUser {
        let response = try await auth.signInWithApple(request)
        try adopt(response)
        return response.user
    }

    /// Sign out: best-effort revoke the refresh-token family server-side, then
    /// clear all local session state (memory + Keychain). The local clear always
    /// happens even if the network revoke fails — the device must forget the
    /// session regardless.
    public func signOut() async {
        let refreshToken = try? store.read()
        if let refreshToken {
            try? await auth.revokeSession(RefreshTokenRequest(refreshToken: refreshToken))
        }
        clearSession()
    }

    /// Whether a session can be resumed without interaction (a refresh token is
    /// stored). Used by the app to decide sign-in-screen vs. main-app at launch.
    public func hasStoredSession() -> Bool {
        ((try? store.read()) ?? nil) != nil
    }

    // MARK: - Refresh core

    private func refreshAccessToken() async throws -> String {
        // Coalesce: if a refresh is already in flight, await ITS result rather
        // than spending the (single-use) refresh token a second time.
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        guard let refreshToken = try store.read() else {
            throw SessionError.notSignedIn
        }

        let auth = self.auth
        // `Task { … }` is created synchronously here — no `await` between the
        // `if let refreshTask` check above and this assignment, so the
        // check-and-set is atomic on the actor and only one task is ever live.
        let task = Task<AuthTokenResponse, Error> {
            try await auth.refreshSession(RefreshTokenRequest(refreshToken: refreshToken))
        }
        refreshTask = task

        do {
            let response = try await task.value
            refreshTask = nil
            try adopt(response)
            return response.accessToken
        } catch {
            refreshTask = nil
            // A 401 means the refresh token is spent/revoked/expired (family
            // revoked, §7.10.2) — the session is unrecoverable. Clear it and
            // surface `sessionExpired` so the app forces interactive re-sign-in.
            if (error as? RestError)?.httpStatus == 401 {
                clearSession()
                throw SessionError.sessionExpired
            }
            // Transient (network/5xx): keep the session, surface the error so the
            // caller can retry later.
            throw error
        }
    }

    /// Adopt a fresh token pair: access token + expiry into memory, the rotated
    /// refresh token into the Keychain.
    private func adopt(_ response: AuthTokenResponse) throws {
        accessToken = response.accessToken
        accessTokenExpiry = now().addingTimeInterval(TimeInterval(response.expiresIn))
        try store.write(response.refreshToken)
    }

    private func clearSession() {
        accessToken = nil
        accessTokenExpiry = nil
        try? store.clear()
    }
}
