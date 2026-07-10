import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

// MARK: - MYR-224 account identity + owner/rider mode chooser
//
// Covers the deterministic seams: profile derivations + persistence round-trip
// (and clear-on-sign-out), greeting-name derivation, the per-user mode store,
// the post-auth routing rule (no choice → chooser; stored → direct shell; no
// account → onboarding), and the Settings mode toggle. The live Apple flow
// itself can't run headless (no Apple ID in the sim), so `LiveAuthSession` is
// exercised through a scripted `SessionTokenProvider` (fake endpoint + in-memory
// stores).

// MARK: Fakes

/// In-memory `RefreshTokenStore` (no Keychain).
private final class FakeRefreshTokenStore: RefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    init(seed: String? = nil) { stored = seed }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return stored }
    func write(_ token: String) throws { lock.lock(); defer { lock.unlock() }; stored = token }
    func clear() throws { lock.lock(); defer { lock.unlock() }; stored = nil }
}

/// Scripted `AuthenticationEndpoint` — replays one apple + one refresh response.
private actor FakeAuthEndpoint: AuthenticationEndpoint {
    private let apple: AuthTokenResponse?
    private let refresh: AuthTokenResponse?
    init(apple: AuthTokenResponse? = nil, refresh: AuthTokenResponse? = nil) {
        self.apple = apple
        self.refresh = refresh
    }
    func signInWithApple(_ body: AppleSignInRequest) async throws -> AuthTokenResponse {
        guard let apple else { throw RestError.invalidResponse }
        return apple
    }
    func refreshSession(_ body: RefreshTokenRequest) async throws -> AuthTokenResponse {
        guard let refresh else { throw RestError.invalidResponse }
        return refresh
    }
    func revokeSession(_ body: RefreshTokenRequest) async throws {}
}

/// In-memory `ProfileStore`.
private final class FakeProfileStore: ProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UserProfile?
    init(seed: UserProfile? = nil) { stored = seed }
    func read() -> UserProfile? { lock.lock(); defer { lock.unlock() }; return stored }
    func write(_ profile: UserProfile) { lock.lock(); defer { lock.unlock() }; stored = profile }
    func clear() { lock.lock(); defer { lock.unlock() }; stored = nil }
}

private func pair(id: String, name: String?, email: String?, access: String = "acc", refresh: String = "rt") -> AuthTokenResponse {
    AuthTokenResponse(accessToken: access, expiresIn: 3600, refreshToken: refresh, user: AuthUser(id: id, name: name, email: email))
}

// MARK: - UserProfile derivations

final class UserProfileDerivationTests: XCTestCase {
    func testFirstNameFromFullName() {
        XCTAssertEqual(UserProfile(id: "u", name: "Thomas Nandola").firstName, "Thomas")
    }

    func testFirstNameFromSingleName() {
        XCTAssertEqual(UserProfile(id: "u", name: "Thomas").firstName, "Thomas")
    }

    func testFirstNameNilWhenNameAbsent() {
        XCTAssertNil(UserProfile(id: "u", name: nil).firstName, "no name → generic greeting")
    }

    func testFirstNameNilWhenNameEmptyOrWhitespace() {
        XCTAssertNil(UserProfile(id: "u", name: "   ").firstName, "whitespace-only name is treated as absent")
    }

    func testSettingsDisplayNamePrefersNameThenEmailThenGeneric() {
        XCTAssertEqual(UserProfile(id: "u", name: "Ada Lovelace", email: "a@x.com").settingsDisplayName, "Ada Lovelace")
        XCTAssertEqual(UserProfile(id: "u", name: nil, email: "a@x.com").settingsDisplayName, "a@x.com")
        XCTAssertEqual(UserProfile(id: "u", name: nil, email: nil).settingsDisplayName, "Your account")
    }

    func testAvatarInitial() {
        XCTAssertEqual(UserProfile(id: "u", name: "thomas").avatarInitial, "T")
    }

    func testEmptyEmailNormalizedToNil() {
        XCTAssertNil(UserProfile(id: "u", name: "T", email: "").email)
    }
}

// MARK: - Persistence round-trips

final class AccountStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "myr224.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testProfileStoreRoundTripAndClear() {
        let store = UserDefaultsProfileStore(defaults: makeDefaults())
        XCTAssertNil(store.read())
        let profile = UserProfile(id: "u1", name: "Thomas Nandola", email: "thomas@example.com")
        store.write(profile)
        XCTAssertEqual(store.read(), profile, "profile survives a read-back (relaunch)")
        store.clear()
        XCTAssertNil(store.read(), "cleared on sign-out")
    }

    func testModeChoiceStoreIsPerUserAndClears() {
        let store = UserDefaultsModeChoiceStore(defaults: makeDefaults())
        XCTAssertNil(store.mode(forUserID: "u1"), "no choice → chooser")
        store.setMode(.rider, forUserID: "u1")
        store.setMode(.owner, forUserID: "u2")
        XCTAssertEqual(store.mode(forUserID: "u1"), .rider)
        XCTAssertEqual(store.mode(forUserID: "u2"), .owner, "keyed by user id — no cross-leak")
        store.clearMode(forUserID: "u1")
        XCTAssertNil(store.mode(forUserID: "u1"))
        XCTAssertEqual(store.mode(forUserID: "u2"), .owner, "clearing one user leaves the other")
    }
}

// MARK: - Post-auth routing rule

final class PostAuthRoutingTests: XCTestCase {
    private let user = UserProfile(id: "u1", name: "Thomas", email: "t@x.com")

    func testNoAccountRoutesToOnboarding() {
        XCTAssertEqual(PostAuthRouter.destination(user: nil, storedMode: nil), .onboarding)
    }

    func testRealAccountNoStoredModeRoutesToChooser() {
        XCTAssertEqual(PostAuthRouter.destination(user: user, storedMode: nil), .chooser)
    }

    func testRealAccountStoredModeRoutesDirectToShell() {
        XCTAssertEqual(PostAuthRouter.destination(user: user, storedMode: .owner), .shell(.owner))
        XCTAssertEqual(PostAuthRouter.destination(user: user, storedMode: .rider), .shell(.rider))
    }

    func testViewModeToggleFlipsTheShell() {
        XCTAssertEqual(ViewMode.owner.toggled, .rider)
        XCTAssertEqual(ViewMode.rider.toggled, .owner)
    }
}

// MARK: - LiveAuthSession identity lifecycle

@MainActor
final class LiveAuthSessionIdentityTests: XCTestCase {

    func testSimulatedSessionHasNoCurrentUser() {
        XCTAssertNil(SimulatedAuthSession().currentUser, "sim carries no real identity")
    }

    /// Silent resume recovers + persists the identity from the refresh response,
    /// even when nothing was stored locally (a session predating this build).
    func testResumeRecoversAndPersistsProfile() async {
        let profileStore = FakeProfileStore() // nothing stored yet
        let auth = FakeAuthEndpoint(refresh: pair(id: "u1", name: "Thomas Nandola", email: "thomas@example.com"))
        let provider = SessionTokenProvider(auth: auth, store: FakeRefreshTokenStore(seed: "rt1"))
        let session = LiveAuthSession(sessionProvider: provider, profileStore: profileStore)

        XCTAssertNil(session.currentUser, "no local profile before resume")
        let resumed = await session.resumeStoredSession()

        XCTAssertTrue(resumed)
        XCTAssertEqual(session.currentUser?.name, "Thomas Nandola", "recovered from the refresh (no /me endpoint)")
        XCTAssertEqual(profileStore.read()?.email, "thomas@example.com", "and persisted for the next launch")
    }

    func testEagerlyLoadsPersistedProfileAtInit() {
        let stored = UserProfile(id: "u1", name: "Thomas Nandola", email: "thomas@example.com")
        let session = LiveAuthSession(
            sessionProvider: SessionTokenProvider(auth: FakeAuthEndpoint(), store: FakeRefreshTokenStore()),
            profileStore: FakeProfileStore(seed: stored)
        )
        XCTAssertEqual(session.currentUser, stored, "returning user's identity is available before resume completes")
    }

    func testSignOutClearsCurrentUserAndPersistedProfile() async {
        let profileStore = FakeProfileStore(seed: UserProfile(id: "u1", name: "Thomas"))
        let session = LiveAuthSession(
            sessionProvider: SessionTokenProvider(auth: FakeAuthEndpoint(), store: FakeRefreshTokenStore(seed: "rt1")),
            profileStore: profileStore
        )
        XCTAssertNotNil(session.currentUser)

        session.signOut()

        XCTAssertNil(session.currentUser, "identity cleared on sign-out")
        XCTAssertNil(profileStore.read(), "persisted profile cleared on sign-out")
    }
}
