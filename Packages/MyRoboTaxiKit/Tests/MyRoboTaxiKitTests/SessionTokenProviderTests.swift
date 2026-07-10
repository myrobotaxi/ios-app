import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// State-machine tests for ``SessionTokenProvider`` (rest-api.md §7.10 session
/// contract, MYR-164): sign-in adoption, memory-vs-Keychain split, proactive
/// refresh timing under an injected clock, the `invalidate → refresh` (Bearer
/// 401) path, single-use rotation adoption + concurrent-caller coalescing, and
/// revoke/expiry clearing. No network, no Keychain — a scripted
/// `MockAuthEndpoint` + an in-memory `RefreshTokenStore`.
final class SessionTokenProviderTests: XCTestCase {

    private func pair(access: String, expiresIn: Int = 3600, refresh: String) -> AuthTokenResponse {
        AuthTokenResponse(accessToken: access, expiresIn: expiresIn, refreshToken: refresh, user: AuthUser(id: "u1"))
    }

    // MARK: - Sign-in

    func testCompleteAppleSignInAdoptsPairAccessInMemoryRefreshInStore() async throws {
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(apple: [.success(pair(access: "acc1", refresh: "rt1"))])
        let provider = SessionTokenProvider(auth: auth, store: store)

        let user = try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "apple.jwt"))

        XCTAssertEqual(user.id, "u1")
        // Access token now vended from memory without any refresh call.
        let token = try await provider.token()
        XCTAssertEqual(token, "acc1")
        XCTAssertEqual(try store.read(), "rt1", "refresh token persisted to the store")
        let counts = await auth.counts()
        XCTAssertEqual(counts.refresh, 0, "a fresh, in-margin access token needs no refresh")
    }

    func testTokenWithoutSessionThrowsNotSignedIn() async {
        let provider = SessionTokenProvider(auth: MockAuthEndpoint(), store: InMemoryRefreshTokenStore())
        do {
            _ = try await provider.token()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? SessionError, .notSignedIn)
        }
    }

    // MARK: - Proactive refresh (injected clock)

    func testTokenReturnsCachedWhileOutsideRefreshMargin() async throws {
        let clock = TestClock()
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(apple: [.success(pair(access: "acc1", expiresIn: 3600, refresh: "rt1"))])
        let provider = SessionTokenProvider(auth: auth, store: store, refreshMargin: 60, now: { clock.now })

        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))
        clock.advance(3600 - 61) // still 1s before the 60s margin opens
        let token = try await provider.token()

        XCTAssertEqual(token, "acc1")
        let counts = await auth.counts()
        XCTAssertEqual(counts.refresh, 0, "outside the margin: no refresh")
    }

    func testTokenRefreshesProactivelyInsideMargin() async throws {
        let clock = TestClock()
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(
            apple: [.success(pair(access: "acc1", expiresIn: 3600, refresh: "rt1"))],
            refresh: [.success(pair(access: "acc2", expiresIn: 3600, refresh: "rt2"))]
        )
        let provider = SessionTokenProvider(auth: auth, store: store, refreshMargin: 60, now: { clock.now })

        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))
        clock.advance(3600 - 59) // now inside the 60s margin
        let token = try await provider.token()

        XCTAssertEqual(token, "acc2", "proactively refreshed before expiry")
        XCTAssertEqual(try store.read(), "rt2", "rotated refresh token adopted")
        let counts = await auth.counts()
        XCTAssertEqual(counts.refresh, 1)
    }

    // MARK: - Bearer 401 → invalidate → refresh

    func testInvalidateForcesRefreshOnNextToken() async throws {
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(
            apple: [.success(pair(access: "acc1", refresh: "rt1"))],
            refresh: [.success(pair(access: "acc2", refresh: "rt2"))]
        )
        let provider = SessionTokenProvider(auth: auth, store: store)

        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))
        let first = try await provider.token()
        XCTAssertEqual(first, "acc1")

        // Transport reports the server rejected acc1 with a 401.
        await provider.invalidate(rejectedToken: "acc1")
        let second = try await provider.token()

        XCTAssertEqual(second, "acc2", "after invalidation the next token forces a refresh")
        let counts = await auth.counts()
        XCTAssertEqual(counts.refresh, 1)
    }

    func testInvalidateOfStaleTokenIsIgnored() async throws {
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(apple: [.success(pair(access: "acc1", refresh: "rt1"))])
        let provider = SessionTokenProvider(auth: auth, store: store)

        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))
        _ = try await provider.token()
        // A token we never vended (e.g. from a since-refreshed request) is a no-op.
        await provider.invalidate(rejectedToken: "some-old-token")
        let token = try await provider.token()

        XCTAssertEqual(token, "acc1", "still the cached token — no spurious refresh")
        let counts = await auth.counts()
        XCTAssertEqual(counts.refresh, 0)
    }

    // MARK: - Single-use rotation: concurrent coalescing

    func testConcurrentRefreshesCoalesceToSingleNetworkCall() async throws {
        let store = InMemoryRefreshTokenStore(seed: "rt1") // already signed in
        let auth = MockAuthEndpoint(refresh: [.success(pair(access: "acc2", refresh: "rt2"))])
        // Gate the single scripted refresh so all callers pile up inside it.
        let gate = Gate()
        await auth.setRefreshGate { await gate.wait() }
        let provider = SessionTokenProvider(auth: auth, store: store)

        async let a = provider.token()
        async let b = provider.token()
        async let c = provider.token()
        // Let the three calls reach the in-flight refresh, then release it.
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()

        let results = try await [a, b, c]
        XCTAssertEqual(results, ["acc2", "acc2", "acc2"])
        let counts = await auth.counts()
        XCTAssertEqual(counts.refresh, 1, "single-use rotation: exactly one refresh for N concurrent callers")
        XCTAssertEqual(store.writeCount, 1, "the rotated token is written once")
    }

    // MARK: - Expiry / revoke clearing

    func testRefreshRejectionClearsSessionAndSurfacesExpired() async throws {
        let store = InMemoryRefreshTokenStore(seed: "rt_spent")
        let auth = MockAuthEndpoint(refresh: [.failure(.http(status: 401, code: .authFailed, message: nil, subCode: nil))])
        let provider = SessionTokenProvider(auth: auth, store: store)

        do {
            _ = try await provider.token()
            XCTFail("expected sessionExpired")
        } catch {
            XCTAssertEqual(error as? SessionError, .sessionExpired)
        }
        XCTAssertNil(try store.read(), "a revoked refresh family clears the stored token")
        let hasSession = await provider.hasStoredSession()
        XCTAssertFalse(hasSession)
    }

    func testTransientRefreshErrorKeepsSession() async throws {
        let store = InMemoryRefreshTokenStore(seed: "rt1")
        let auth = MockAuthEndpoint(refresh: [
            .failure(.transport(underlying: URLError(.notConnectedToInternet))),
            .success(pair(access: "acc2", refresh: "rt2")),
        ])
        let provider = SessionTokenProvider(auth: auth, store: store)

        do { _ = try await provider.token(); XCTFail("expected transport error") }
        catch { XCTAssertTrue(error is RestError) }
        XCTAssertEqual(try store.read(), "rt1", "a transient failure must NOT drop the session")

        // A subsequent attempt recovers.
        let token = try await provider.token()
        XCTAssertEqual(token, "acc2")
    }

    // MARK: - Session user identity (MYR-224)

    func testSessionUserNilBeforeAnyTokenResponse() async {
        let provider = SessionTokenProvider(auth: MockAuthEndpoint(), store: InMemoryRefreshTokenStore())
        let user = await provider.sessionUser()
        XCTAssertNil(user, "no identity before the first token response")
    }

    func testSignInPopulatesSessionUser() async throws {
        let store = InMemoryRefreshTokenStore()
        let response = AuthTokenResponse(
            accessToken: "acc1", expiresIn: 3600, refreshToken: "rt1",
            user: AuthUser(id: "u1", name: "Thomas Nandola", email: "thomas@example.com")
        )
        let auth = MockAuthEndpoint(apple: [.success(response)])
        let provider = SessionTokenProvider(auth: auth, store: store)

        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))

        let user = await provider.sessionUser()
        XCTAssertEqual(user?.id, "u1")
        XCTAssertEqual(user?.name, "Thomas Nandola")
        XCTAssertEqual(user?.email, "thomas@example.com")
    }

    /// The MYR-224 recovery path: a session that predates local profile storage
    /// (a returning user with only a Keychain refresh token) recovers its
    /// identity from the refresh response `token()` performs at launch — there is
    /// no `/api/auth/me` endpoint.
    func testSilentResumeRecoversSessionUserFromRefresh() async throws {
        let store = InMemoryRefreshTokenStore(seed: "rt1") // already signed in, no in-memory user
        let refreshed = AuthTokenResponse(
            accessToken: "acc2", expiresIn: 3600, refreshToken: "rt2",
            user: AuthUser(id: "u1", name: "Thomas Nandola", email: "thomas@example.com")
        )
        let auth = MockAuthEndpoint(refresh: [.success(refreshed)])
        let provider = SessionTokenProvider(auth: auth, store: store)

        let before = await provider.sessionUser()
        XCTAssertNil(before, "cold: no identity until the refresh runs")
        _ = try await provider.token() // the silent-resume refresh
        let user = await provider.sessionUser()
        XCTAssertEqual(user?.name, "Thomas Nandola", "identity recovered from the refresh response")
    }

    func testSignOutClearsSessionUser() async throws {
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(apple: [.success(pair(access: "acc1", refresh: "rt1"))])
        let provider = SessionTokenProvider(auth: auth, store: store)
        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))
        let signedIn = await provider.sessionUser()
        XCTAssertNotNil(signedIn)

        await provider.signOut()

        let afterSignOut = await provider.sessionUser()
        XCTAssertNil(afterSignOut, "sign-out forgets the identity")
    }

    func testSignOutRevokesAndClears() async throws {
        let store = InMemoryRefreshTokenStore()
        let auth = MockAuthEndpoint(apple: [.success(pair(access: "acc1", refresh: "rt1"))])
        let provider = SessionTokenProvider(auth: auth, store: store)
        try await provider.completeAppleSignIn(AppleSignInRequest(identityToken: "j"))

        await provider.signOut()

        let counts = await auth.counts()
        XCTAssertEqual(counts.revoke, 1, "sign-out revokes the family server-side")
        XCTAssertNil(try store.read(), "sign-out clears the Keychain")
        do { _ = try await provider.token(); XCTFail("expected notSignedIn after sign-out") }
        catch { XCTAssertEqual(error as? SessionError, .notSignedIn) }
    }
}

/// A one-shot async gate for the coalescing test.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
