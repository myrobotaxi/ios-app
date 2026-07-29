import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

/// Registration sequencing (MYR-186): the prompt, token delivery, rotation, the
/// app-upgrade re-assert, the retry-next-foreground policy, and the sign-out
/// DELETE. Every OS + network dependency is injected, so none of this needs a
/// simulator, APNs, or a backend.
@MainActor
final class PushRegistrationCoordinatorTests: XCTestCase {

    private let tokenData = Data([0x0a, 0x1b, 0x2c, 0x3d])
    private var tokenHex: String { "0a1b2c3d" }

    private func makeCoordinator(
        endpoint: RecordingPushEndpoint? = RecordingPushEndpoint(),
        authorizer: StubPushAuthorizer = StubPushAuthorizer(),
        store: InMemoryPushStore = InMemoryPushStore(),
        isLive: Bool = true,
        sandbox: Bool = true,
        build: String = "42"
    ) -> (PushRegistrationCoordinator, RecordingPushEndpoint?, StubPushAuthorizer, InMemoryPushStore) {
        let coordinator = PushRegistrationCoordinator(
            endpoint: endpoint,
            authorizer: authorizer,
            store: store,
            isLive: isLive,
            sandbox: sandbox,
            build: build
        )
        return (coordinator, endpoint, authorizer, store)
    }

    // MARK: The prompt

    func testTheMeaningfulMomentPromptsAndRegistersOnGrant() async {
        let authorizer = StubPushAuthorizer(grants: true)
        let (coordinator, _, _, store) = makeCoordinator(authorizer: authorizer)

        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)

        XCTAssertEqual(authorizer.requestCount, 1, "the system prompt was presented once")
        XCTAssertEqual(authorizer.registerCount, 1, "a grant immediately asks APNs for a token")
        XCTAssertTrue(store.hasAskedForAuthorization(), "the one-shot gate is closed")
        XCTAssertEqual(coordinator.authorizationState, .authorized)
    }

    func testADenialClosesTheGateAndDoesNotRegister() async {
        let authorizer = StubPushAuthorizer(grants: false)
        let (coordinator, _, _, store) = makeCoordinator(authorizer: authorizer)

        await coordinator.handleMeaningfulMoment(.riderRideRequestSubmitted, role: .shared)

        XCTAssertEqual(authorizer.requestCount, 1)
        XCTAssertEqual(authorizer.registerCount, 0, "no token is requested without authorization")
        XCTAssertTrue(store.hasAskedForAuthorization(), "a denial still consumes the one shot — iOS will not re-ask")
        XCTAssertEqual(coordinator.authorizationState, .denied)
    }

    func testARepeatedMomentDoesNotPromptAgain() async {
        let authorizer = StubPushAuthorizer(grants: true)
        let (coordinator, _, _, _) = makeCoordinator(authorizer: authorizer)

        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)
        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)
        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)

        XCTAssertEqual(authorizer.requestCount, 1, "every later arrival on the home map is free")
    }

    /// The gate is closed BEFORE the prompt is presented, so a crash or a kill
    /// mid-prompt cannot leave it open (iOS would silently swallow the second ask
    /// and the app would then skip registration forever).
    func testTheGateIsClosedBeforeThePromptIsPresented() async {
        let store = InMemoryPushStore()
        let authorizer = StubPushAuthorizer(grants: true)
        authorizer.onRequest = { XCTAssertTrue(store.hasAskedForAuthorization(), "gate closes first") }
        let (coordinator, _, _, _) = makeCoordinator(authorizer: authorizer, store: store)

        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)
    }

    // MARK: Simulated mode is inert

    func testSimulatedModeNeverPromptsRegistersOrCallsTheNetwork() async {
        let authorizer = StubPushAuthorizer(grants: true)
        let endpoint = RecordingPushEndpoint()
        let (coordinator, _, _, store) = makeCoordinator(
            endpoint: nil, authorizer: authorizer, isLive: false
        )

        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)
        await coordinator.handleForeground()
        await coordinator.handleDeviceToken(tokenData)

        XCTAssertEqual(authorizer.requestCount, 0, "no permission alert over a fixture run / drift-gate capture")
        XCTAssertEqual(authorizer.registerCount, 0)
        XCTAssertFalse(store.hasAskedForAuthorization())
        let registered = await endpoint.registered
        XCTAssertTrue(registered.isEmpty)
        // …and it never observes an authorization state, so the Settings
        // "notifications are off" notice can never render on a simulated run and
        // both Settings screens stay pixel-identical for the drift-gate captures.
        XCTAssertEqual(coordinator.authorizationState, .notDetermined)
    }

    // MARK: Token delivery

    func testTokenIsHexEncodedAndSentWithTheBuildsSandboxFlag() async {
        let (coordinator, endpoint, _, store) = makeCoordinator(sandbox: true)

        await coordinator.handleDeviceToken(tokenData)

        let registered = await endpoint!.registered
        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(registered.first?.token, tokenHex)
        XCTAssertEqual(registered.first?.sandbox, true)
        XCTAssertEqual(store.confirmedRegistration()?.token, tokenHex)
        XCTAssertNil(store.pendingToken(), "a confirmed registration leaves nothing pending")
    }

    func testAProductionBuildRegistersAsNotSandbox() async {
        let (coordinator, endpoint, _, _) = makeCoordinator(sandbox: false)
        await coordinator.handleDeviceToken(tokenData)
        let registered = await endpoint!.registered
        XCTAssertEqual(registered.first?.sandbox, false, "TestFlight/App Store builds are production APNs")
    }

    func testAnUnchangedTokenFromTheSameBuildIsNotResent() async {
        let (coordinator, endpoint, _, _) = makeCoordinator()

        await coordinator.handleDeviceToken(tokenData)
        await coordinator.handleDeviceToken(tokenData)
        await coordinator.handleDeviceToken(tokenData)

        let registered = await endpoint!.registered
        XCTAssertEqual(registered.count, 1, "re-registering every launch must not mean a PUT every launch")
    }

    func testAROTATEDTokenIsResent() async {
        let (coordinator, endpoint, _, _) = makeCoordinator()

        await coordinator.handleDeviceToken(tokenData)
        await coordinator.handleDeviceToken(Data([0xff, 0xee]))

        let registered = await endpoint!.registered
        XCTAssertEqual(registered.map(\.token), [tokenHex, "ffee"], "a rotated token re-registers")
    }

    /// An app upgrade re-asserts the registration even when the token did not
    /// change — an upgrade is the other documented way a registration goes stale
    /// server-side, and it costs one idempotent call to be sure.
    func testAnAppUpgradeResendsTheSameToken() async {
        let store = InMemoryPushStore()
        let endpoint = RecordingPushEndpoint()
        let before = PushRegistrationCoordinator(
            endpoint: endpoint, authorizer: StubPushAuthorizer(), store: store,
            isLive: true, sandbox: true, build: "42"
        )
        await before.handleDeviceToken(tokenData)

        let after = PushRegistrationCoordinator(
            endpoint: endpoint, authorizer: StubPushAuthorizer(), store: store,
            isLive: true, sandbox: true, build: "43"
        )
        await after.handleDeviceToken(tokenData)

        let registered = await endpoint.registered
        XCTAssertEqual(registered.count, 2, "the upgraded build re-asserts")
        XCTAssertEqual(store.confirmedRegistration()?.build, "43")
    }

    func testAnEmptyTokenIsNeverSent() async {
        let (coordinator, endpoint, _, _) = makeCoordinator()
        await coordinator.handleDeviceToken(Data())
        let registered = await endpoint!.registered
        XCTAssertTrue(registered.isEmpty)
    }

    // MARK: Retry policy

    func testAFailedRegistrationStaysPendingAndIsRetriedNextForeground() async {
        let endpoint = RecordingPushEndpoint(failRegister: true)
        let authorizer = StubPushAuthorizer(state: .authorized)
        let (coordinator, _, _, store) = makeCoordinator(endpoint: endpoint, authorizer: authorizer)

        await coordinator.handleDeviceToken(tokenData)
        XCTAssertEqual(store.pendingToken(), tokenHex, "a failed PUT is persisted, not lost with the process")
        XCTAssertNil(store.confirmedRegistration())

        await endpoint.setFailRegister(false)
        await coordinator.handleForeground()

        XCTAssertEqual(store.confirmedRegistration()?.token, tokenHex, "the next foreground retried it")
        XCTAssertNil(store.pendingToken())
    }

    func testForegroundDoesNothingWhileUnauthorized() async {
        let authorizer = StubPushAuthorizer(state: .notDetermined)
        let (coordinator, endpoint, _, _) = makeCoordinator(authorizer: authorizer)

        await coordinator.handleForeground()

        XCTAssertEqual(authorizer.registerCount, 0, "never ask APNs for a token before the user has authorized")
        let registered = await endpoint!.registered
        XCTAssertTrue(registered.isEmpty)
    }

    /// An authorized launch re-arms APNs every time — that is how the app learns
    /// a token that rotated while it was not running.
    func testForegroundReArmsAPNsWhenAuthorized() async {
        let authorizer = StubPushAuthorizer(state: .authorized)
        let (coordinator, _, _, _) = makeCoordinator(authorizer: authorizer)

        await coordinator.handleForeground()
        await coordinator.handleForeground()

        XCTAssertEqual(authorizer.registerCount, 2)
        XCTAssertEqual(coordinator.authorizationState, .authorized)
    }

    /// A denial discovered later (the user switched notifications off in
    /// Settings) is reflected, which is what surfaces the Settings notice.
    func testForegroundObservesALaterDenial() async {
        let authorizer = StubPushAuthorizer(state: .denied)
        let (coordinator, _, _, _) = makeCoordinator(authorizer: authorizer)

        await coordinator.handleForeground()

        XCTAssertEqual(coordinator.authorizationState, .denied)
    }

    // MARK: Sign-out

    func testSignOutDeletesTheRegistrationAndClearsLocalState() async {
        let (coordinator, endpoint, _, store) = makeCoordinator()
        await coordinator.handleDeviceToken(tokenData)

        coordinator.handleSignOut()

        XCTAssertNil(store.confirmedRegistration(), "local state clears immediately, network or not")
        XCTAssertNil(store.pendingToken())
        await endpoint!.waitForUnregister()
        let unregistered = await endpoint!.unregistered
        XCTAssertEqual(unregistered.first?.token, tokenHex, "the next account on this phone must not inherit alerts")
        XCTAssertEqual(unregistered.first?.sandbox, true)
    }

    func testSignOutUnregistersATokenThatNeverConfirmed() async {
        let endpoint = RecordingPushEndpoint(failRegister: true)
        let (coordinator, _, _, store) = makeCoordinator(endpoint: endpoint)
        await coordinator.handleDeviceToken(tokenData)
        XCTAssertEqual(store.pendingToken(), tokenHex)

        coordinator.handleSignOut()

        await endpoint.waitForUnregister()
        let unregistered = await endpoint.unregistered
        XCTAssertEqual(unregistered.first?.token, tokenHex, "a pending token is still this device's token")
    }

    /// The one-shot gate SURVIVES sign-out: system authorization is per-install,
    /// so re-prompting the next account would be a silent OS no-op.
    func testSignOutDoesNotReopenThePermissionGate() async {
        let authorizer = StubPushAuthorizer(grants: true)
        let (coordinator, _, _, store) = makeCoordinator(authorizer: authorizer)
        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)

        coordinator.handleSignOut()

        XCTAssertTrue(store.hasAskedForAuthorization())
        await coordinator.handleMeaningfulMoment(.ownerLiveHomeAppeared, role: .owner)
        XCTAssertEqual(authorizer.requestCount, 1, "still exactly one prompt for the life of the install")
    }

    func testSignOutWithNoTokenIsAQuietNoOp() async {
        let (coordinator, endpoint, _, _) = makeCoordinator()
        coordinator.handleSignOut()
        let unregistered = await endpoint!.unregistered
        XCTAssertTrue(unregistered.isEmpty)
    }
}

// MARK: - Test doubles

/// Records what was sent, and can be made to fail on demand. An actor because
/// the Kit's `PushDeviceEndpoint` is `Sendable`.
actor RecordingPushEndpoint: PushDeviceEndpoint {
    private(set) var registered: [(token: String, sandbox: Bool)] = []
    private(set) var unregistered: [(token: String, sandbox: Bool)] = []
    private var failRegister: Bool
    private var unregisterContinuations: [CheckedContinuation<Void, Never>] = []

    init(failRegister: Bool = false) { self.failRegister = failRegister }

    func setFailRegister(_ value: Bool) { failRegister = value }

    func registerPushDevice(token: String, sandbox: Bool) async throws {
        if failRegister { throw RestError.invalidResponse }
        registered.append((token, sandbox))
    }

    func unregisterPushDevice(token: String, sandbox: Bool) async throws {
        unregistered.append((token, sandbox))
        for continuation in unregisterContinuations { continuation.resume() }
        unregisterContinuations.removeAll()
    }

    /// Sign-out fires the DELETE in a detached task (it must not block the UI),
    /// so tests await the call rather than polling.
    func waitForUnregister() async {
        guard unregistered.isEmpty else { return }
        await withCheckedContinuation { unregisterContinuations.append($0) }
    }
}

/// Stands in for `UNUserNotificationCenter` + `UIApplication`.
final class StubPushAuthorizer: PushAuthorizing, @unchecked Sendable {
    private let grants: Bool
    private let state: PushAuthorizationState
    private(set) var requestCount = 0
    private(set) var registerCount = 0
    /// Runs inside `requestAuthorization`, so a test can assert what was already
    /// true at the moment the prompt went up.
    var onRequest: (() -> Void)?

    init(grants: Bool = true, state: PushAuthorizationState = .notDetermined) {
        self.grants = grants
        self.state = state
    }

    func authorizationState() async -> PushAuthorizationState { state }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        onRequest?()
        return grants
    }

    @MainActor
    func registerForRemoteNotifications() { registerCount += 1 }
}

/// A `UserDefaults`-free store, so tests never touch the real suite.
final class InMemoryPushStore: PushRegistrationStore, @unchecked Sendable {
    private var asked = false
    private var confirmed: PushConfirmedRegistration?
    private var pending: String?

    func hasAskedForAuthorization() -> Bool { asked }
    func setHasAskedForAuthorization(_ value: Bool) { asked = value }
    func confirmedRegistration() -> PushConfirmedRegistration? { confirmed }
    func setConfirmedRegistration(_ value: PushConfirmedRegistration?) { confirmed = value }
    func pendingToken() -> String? { pending }
    func setPendingToken(_ value: String?) { pending = value }
}
