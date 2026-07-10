import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

// MARK: - AppMode + device/sim launch-mode + silent-resume tests (MYR-221)
//
// `#if targetEnvironment(simulator)` can't be toggled at runtime, so `AppMode`
// wraps it in the injectable `isSimulator` seam and these tests exercise BOTH
// the device and simulator branches deterministically (with an injected launch
// environment, never the real process env). They also cover the launch routing
// the mode feeds (signed-out device → SignInScreen; stored refresh → silent
// resume) and prove the fixture sign-in path is simulator-only.
@MainActor
final class AppModeTests: XCTestCase {

    // MARK: - Resolution: device branch (the bug — device must default to live)

    func testDeviceDefaultsToLiveProductionWithNoEnv() {
        let mode = AppMode.resolve(isSimulator: false, env: { _ in nil })
        guard case let .live(config) = mode else { return XCTFail("device must default to .live") }
        XCTAssertEqual(config.environment, AppMode.productionEnvironment, "device default targets production")
        XCTAssertNil(config.staticToken, "no MRT_BACKEND_TOKEN on device → real Apple session auth")
    }

    func testDeviceHonorsStaticBackendTokenOverride() {
        let mode = AppMode.resolve(isSimulator: false, env: { $0 == "MRT_BACKEND_TOKEN" ? "dev.jwt" : nil })
        XCTAssertEqual(mode.live?.staticToken, "dev.jwt", "static token override still works on device (dev debugging)")
    }

    func testDeviceHonorsBackendURLOverride() {
        let mode = AppMode.resolve(isSimulator: false, env: { $0 == "MRT_BACKEND_URL" ? "https://staging.telemetry.example" : nil })
        XCTAssertEqual(mode.live?.environment.restBaseURL.absoluteString, "https://staging.telemetry.example/api")
    }

    // MARK: - Resolution: simulator branch (unchanged env-driven behavior)

    func testSimulatorDefaultsToSimulatedWithoutEnv() {
        let mode = AppMode.resolve(isSimulator: true, env: { _ in nil })
        XCTAssertEqual(mode, .simulated, "simulator stays fixture mode unless MRT_TELEMETRY=live")
    }

    func testSimulatorGoesLiveOnlyWithTelemetryLive() {
        let mode = AppMode.resolve(isSimulator: true, env: { $0 == "MRT_TELEMETRY" ? "live" : nil })
        guard case let .live(config) = mode else { return XCTFail("MRT_TELEMETRY=live selects live in sim") }
        XCTAssertEqual(config.environment, AppMode.productionEnvironment)
    }

    func testSimulatorLiveWithStaticTokenOverride() {
        let mode = AppMode.resolve(isSimulator: true, env: {
            switch $0 {
            case "MRT_TELEMETRY": return "live"
            case "MRT_BACKEND_TOKEN": return "sim.jwt"
            default: return nil
            }
        })
        XCTAssertEqual(mode.live?.staticToken, "sim.jwt", "the sim static-token override is preserved")
    }

    // MARK: - Auth composition: session selection by mode

    func testDeviceLiveNoTokenComposesRealSessionAndProvider() {
        let mode = AppMode.resolve(isSimulator: false, env: { _ in nil })
        let result = AuthComposition.make(mode: mode, store: InMemoryRefreshTokenStore())
        XCTAssertTrue(result.session is LiveAuthSession, "device (no static token) → the real Apple session")
        XCTAssertNotNil(result.sessionTokenProvider, "the live session yields a backend token provider")
    }

    func testStaticTokenOverrideKeepsSimulatedSession() {
        let mode = AppMode.live(.init(environment: AppMode.productionEnvironment, staticToken: "dev.jwt"))
        let result = AuthComposition.make(mode: mode, store: InMemoryRefreshTokenStore())
        XCTAssertTrue(result.session is SimulatedAuthSession, "static token → sign-in is pure navigation")
        XCTAssertNil(result.sessionTokenProvider, "the static token drives the fleet, not a session provider")
    }

    func testSimulatedModeComposesFixtureSession() {
        let result = AuthComposition.make(mode: .simulated, store: InMemoryRefreshTokenStore())
        XCTAssertTrue(result.session is SimulatedAuthSession, "simulated mode → the fixture sign-in session")
        XCTAssertFalse(result.hasStoredSession)
    }

    // MARK: - Launch routing: signed-out device → SignInScreen (no fixture bypass)

    func testSignedOutDeviceHasNoStoredSession() {
        // Empty Keychain → hasStoredSession false → RootView starts on `.signIn`
        // (the ternary `hasStoredSession ? .resolvingSession : .signIn`), and the
        // session is the REAL one, so the Apple sheet is required — no bypass.
        let mode = AppMode.resolve(isSimulator: false, env: { _ in nil })
        let result = AuthComposition.make(mode: mode, store: InMemoryRefreshTokenStore())
        XCTAssertFalse(result.hasStoredSession, "no stored refresh token → show SignInScreen")
        XCTAssertTrue(result.session is LiveAuthSession)
    }

    func testStoredRefreshTokenRoutesToSilentResume() {
        // A seeded Keychain → hasStoredSession true → RootView starts on
        // `.resolvingSession` (silent resume), skipping SignInScreen.
        let mode = AppMode.resolve(isSimulator: false, env: { _ in nil })
        let result = AuthComposition.make(mode: mode, store: InMemoryRefreshTokenStore(seed: "rt.stored"))
        XCTAssertTrue(result.hasStoredSession, "stored refresh token → attempt silent resume")
    }

    // MARK: - Silent resume behavior (LiveAuthSession.resumeStoredSession)

    func testSilentResumeSucceedsWithValidStoredRefresh() async {
        let store = InMemoryRefreshTokenStore(seed: "rt1")
        let auth = StubAuthEndpoint(refresh: .success(.init(
            accessToken: "acc1", expiresIn: 3600, refreshToken: "rt2", user: AuthUser(id: "u1")
        )))
        let provider = SessionTokenProvider(auth: auth, store: store)
        let session = LiveAuthSession(sessionProvider: provider)

        let resumed = await session.resumeStoredSession()

        XCTAssertTrue(resumed, "a valid stored refresh token resumes silently")
        XCTAssertTrue(session.isSignedIn, "→ route straight into the app")
    }

    func testSilentResumeFailsAndClearsWhenRefreshRejected() async throws {
        let store = InMemoryRefreshTokenStore(seed: "rt_spent")
        let auth = StubAuthEndpoint(refresh: .failure(.http(status: 401, code: nil, message: nil, subCode: nil)))
        let provider = SessionTokenProvider(auth: auth, store: store)
        let session = LiveAuthSession(sessionProvider: provider)

        let resumed = await session.resumeStoredSession()

        XCTAssertFalse(resumed, "a rejected refresh token → fall back to SignInScreen")
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(try store.read(), "the unrecoverable session is cleared")
    }

    func testSilentResumeFailsWithoutStoredSession() async {
        let provider = SessionTokenProvider(auth: StubAuthEndpoint(refresh: nil), store: InMemoryRefreshTokenStore())
        let session = LiveAuthSession(sessionProvider: provider)
        let resumed = await session.resumeStoredSession()
        XCTAssertFalse(resumed, "no stored session → SignInScreen")
    }

    // MARK: - Fixture path is simulator-only

    func testSimulatedSessionNeverSilentlyResumes() async {
        // The always-succeeds fixture session must never bypass sign-in via a
        // silent resume — that path is exclusive to the live device session.
        let session: any AuthSession = SimulatedAuthSession()
        let resumed = await session.resumeStoredSession()
        XCTAssertFalse(resumed)
    }
}

// MARK: - Test doubles

/// In-memory ``RefreshTokenStore`` — Rule: "No Keychain in unit tests".
final class InMemoryRefreshTokenStore: RefreshTokenStore, @unchecked Sendable {
    private var token: String?
    init(seed: String? = nil) { self.token = seed }
    func read() throws -> String? { token }
    func write(_ token: String) throws { self.token = token }
    func clear() throws { token = nil }
}

/// A scripted ``AuthenticationEndpoint`` — only `refreshSession` is exercised by
/// the silent-resume tests; the other two are unused stubs.
struct StubAuthEndpoint: AuthenticationEndpoint {
    /// nil → the test never calls refresh (no-session path).
    var refresh: Result<AuthTokenResponse, RestError>?

    func signInWithApple(_ body: AppleSignInRequest) async throws -> AuthTokenResponse {
        throw RestError.http(status: 500, code: nil, message: nil, subCode: nil)
    }
    func refreshSession(_ body: RefreshTokenRequest) async throws -> AuthTokenResponse {
        guard let refresh else { throw RestError.http(status: 500, code: nil, message: nil, subCode: nil) }
        return try refresh.get()
    }
    func revokeSession(_ body: RefreshTokenRequest) async throws {}
}
