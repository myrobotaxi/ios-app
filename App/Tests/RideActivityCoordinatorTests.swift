import CoreLocation
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - Token registration, rotation and the 409 (MYR-172)
//
// The ActivityKit half is stubbed (`StubRideActivityPresenter`) exactly as MYR-186
// stubs `PushAuthorizing`; what is asserted here is everything AROUND the
// framework — hex encoding, the sandbox flag, re-registration on rotation, and the
// 409-means-end-locally rule.

@MainActor
final class RideActivityCoordinatorTests: XCTestCase {

    // MARK: - Registration

    func testStartingAnActivityRegistersItsTokenAsLowercaseHex() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0x8a, 0x1f, 0x4c, 0x2e, 0x00, 0xff]))
        await settle()

        let calls = endpoint.registrations
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.rideID, "ride-1")
        XCTAssertEqual(
            calls.first?.token,
            "8a1f4c2e00ff",
            """
            The server validates HEX. `Data.description` — the shape a naive \
            interpolation produces — is "<8a1f4c2e 00ff>", which is not it. Note \
            the zero byte: it must pad to "00", not collapse to "0".
            """
        )
        XCTAssertTrue(presenter.isPresenting)
    }

    func testTheHexEncodingIsMYR186sAndNotASecondCopy() {
        // The same encoder the device token uses. Two encoders is two places to get
        // padding or case wrong.
        XCTAssertEqual(PushDeviceToken.hex(from: Data([0x00, 0x0f, 0xff])), "000fff")
    }

    func testTheSandboxFlagMirrorsTheBuildsAPNsEnvironment() async throws {
        let (sandboxCoordinator, sandboxPresenter, sandboxEndpoint) = makeCoordinator(sandbox: true)
        await sandboxCoordinator.handleRideChange(makeRecord(status: .accepted))
        sandboxPresenter.emit(token: Data([0x01]))
        await settle()
        XCTAssertEqual(sandboxEndpoint.registrations.first?.sandbox, true)

        let (prodCoordinator, prodPresenter, prodEndpoint) = makeCoordinator(sandbox: false)
        await prodCoordinator.handleRideChange(makeRecord(status: .accepted))
        prodPresenter.emit(token: Data([0x01]))
        await settle()
        XCTAssertEqual(
            prodEndpoint.registrations.first?.sandbox,
            false,
            """
            Sent explicitly rather than omitted on the production arm: the schema \
            defaults a missing key to production, so omitting it would make \
            "production" and "the client did not say" the same bytes.
            """
        )
    }

    func testTheDefaultSandboxFlagIsTheSameOneMYR186Uses() {
        // Not re-derived from an entitlement read or a profile parse — one source
        // of truth for the whole app.
        #if DEBUG
        XCTAssertTrue(PushEnvironment.isSandbox)
        #else
        XCTAssertFalse(PushEnvironment.isSandbox)
        #endif
    }

    // MARK: - Rotation

    func testAROTATEDTokenIsREREGISTERED() async throws {
        // ActivityKit reissues the token during the life of ONE Activity and
        // expects the server to switch. Missing a rotation fails silently: the old
        // token simply stops delivering and the lock screen stops updating.
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()
        presenter.emit(token: Data([0xbb]))
        await settle()

        XCTAssertEqual(endpoint.registrations.map(\.token), ["aa", "bb"])
        XCTAssertEqual(
            Set(endpoint.registrations.map(\.rideID)),
            ["ride-1"],
            "a rotation is an ordinary re-registration against the SAME ride — the endpoint upserts"
        )
    }

    func testTheSAMETokenTwiceForTheSameRideIsNotReRegistered() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertEqual(endpoint.registrations.count, 1, "a wasted round trip on every foreground")
    }

    // MARK: - The 409

    func testA409OnRegistrationENDSTheActivityLocally() async throws {
        // §7.21: posting against a ride that has already reached a terminal state is
        // 409, "and the 409 is the signal to end it locally". This is the ONLY thing
        // that rescues a rider whose ride ended while the app was not running.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        endpoint.registrationResult = .failure(
            RestError.http(status: 409, code: nil, message: nil, subCode: nil)
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertFalse(presenter.isPresenting, "the card must come off the lock screen")
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(endpoint.ends, ["ride-1"], "and the server is told the Activity is gone")
    }

    func testTheTerminalConflictIsRecognisedByStatusAlone() {
        XCTAssertTrue(
            RestError.http(status: 409, code: nil, message: nil, subCode: nil)
                .isTerminalRideActivityConflict
        )
        XCTAssertFalse(
            RestError.http(status: 500, code: nil, message: nil, subCode: nil)
                .isTerminalRideActivityConflict
        )
        XCTAssertFalse(RestError.transport(underlying: URLError(.timedOut)).isTerminalRideActivityConflict)
    }

    func testATRANSIENTFailureLeavesTheActivityUpAndRetriesOnTheNextRotation() async throws {
        // Pushes are the primary channel but the app is the backstop, and the
        // backstop is still standing. Tearing the card down on a 500 would punish
        // the rider for the server's bad minute.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        endpoint.registrationResult = .failure(
            RestError.http(status: 503, code: nil, message: nil, subCode: nil)
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertTrue(presenter.isPresenting)
        XCTAssertNil(presenter.endedWith)

        endpoint.registrationResult = .success(LiveActivityRegistrationResponse(registered: true, sandbox: true))
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertEqual(
            endpoint.attempts.count,
            2,
            """
            The failed attempt recorded nothing in `registered`, so the SAME token is \
            tried again rather than deduped away as already-registered. A dedup that \
            counted failures would strand the Activity: the server would never learn \
            the token, and the lock screen would sit there never updating.
            """
        )
        XCTAssertEqual(endpoint.registrations.count, 1, "and exactly one of the two succeeded")
    }

    // MARK: - Lifecycle end to end

    func testACompletedRideEndsWithTheLingerAndTellsTheServer() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleRideChange(makeRecord(status: .completed))

        XCTAssertEqual(presenter.endedWith?.state.status, .completed)
        XCTAssertEqual(presenter.endedWith?.dismissal, .completedLinger)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAnErasedRideEndsTheActivityAsCancelled() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleRideChange(nil)

        XCTAssertEqual(presenter.endedWith?.state.status, .cancelled)
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
    }

    func testSigningOutTakesTheCardDownAtOnce() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleSignOut()

        XCTAssertFalse(
            presenter.isPresenting,
            """
            the card names the rider's DESTINATION, which is P1 and scoped to that \
            one rider — it must not still be there when the next account signs in
            """
        )
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
    }

    // MARK: - Simulated mode

    func testSIMULATEDModeNeverTouchesActivityKitOrTheNetwork() async throws {
        // A fixture ride putting a real card on a real lock screen would be visible
        // to a human, not just to a test. This is the same inert-by-construction
        // rule `PushComposition` follows.
        let presenter = StubRideActivityPresenter()
        let endpoint = SpyRideActivityEndpoint()
        let coordinator = RideActivityCoordinator(
            presenter: presenter,
            endpoint: endpoint,
            isLive: false,
            sandbox: true,
            vehicleName: { "Blue Whale" }
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        XCTAssertFalse(presenter.isPresenting)
        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertTrue(endpoint.registrations.isEmpty)
        XCTAssertTrue(endpoint.ends.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testASYSTEMREFUSALIsOrdinaryAndRegistersNothing() async throws {
        // The rider may simply have Live Activities switched off in Settings. That
        // is not an error and must not leave the coordinator believing it holds a
        // card.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.allowsStart = false

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(endpoint.registrations.isEmpty)
        XCTAssertTrue(endpoint.ends.isEmpty)
    }

    // MARK: - Harness

    private func makeCoordinator(
        sandbox: Bool = true
    ) -> (RideActivityCoordinator, StubRideActivityPresenter, SpyRideActivityEndpoint) {
        let presenter = StubRideActivityPresenter()
        let endpoint = SpyRideActivityEndpoint()
        let coordinator = RideActivityCoordinator(
            presenter: presenter,
            endpoint: endpoint,
            isLive: true,
            sandbox: sandbox,
            vehicleName: { "Blue Whale" }
        )
        return (coordinator, presenter, endpoint)
    }

    /// Let the token-consuming `Task` run. The stream is fed from the test, so a
    /// couple of yields is enough — there is no real clock anywhere in this path.
    /// Let the coordinator's unstructured registration `Task` run to completion.
    ///
    /// MYR-377 — this was six bare `Task.yield()`s, and it is a PRE-EXISTING FLAKE
    /// rather than anything this issue changed: `RideActivityCoordinatorTests` fails
    /// its 409 and transient-retry cases on `origin/main` when run in ISOLATION (14
    /// tests, 6 failures, reproducible), and passes inside the full suite, because
    /// how many yields it takes for a detached task to reach an `await` is a
    /// function of what else the cooperative pool is doing. Adding tests anywhere in
    /// the target is enough to flip it — which is exactly what a suite must not do.
    ///
    /// Yielding AND sleeping gives the pool a real chance to schedule rather than a
    /// hopeful one. Deliberately not asserting on coordinator internals to know when
    /// to stop: these tests are about observable effects, and a settle helper that
    /// reached into the thing under test would be assertion by another name.
    private func settle() async {
        for _ in 0..<12 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeRecord(id: String = "ride-1", status: MyRoboTaxi.RideRequestStatus) -> RideRequestRecord {
        let place = RidePlace(
            id: "dest", label: "Home", subtitle: nil, miles: 4.2, minutes: 12,
            icon: "house.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
        )
        var record = RideRequestRecord(
            id: id,
            input: RideRequestInput(pickup: place, destination: place, fleetMemberID: "vehicle-1"),
            status: status
        )
        record.status = status
        return record
    }
}

// MARK: - Fakes

@MainActor
final class StubRideActivityPresenter: RideActivityPresenting {
    var areActivitiesEnabled = true
    var allowsStart = true

    private(set) var startCount = 0
    private(set) var updates: [RideActivityAttributes.ContentState] = []
    private(set) var endedWith: (state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal)?
    private(set) var isPresenting = false

    private var continuation: AsyncStream<Data>.Continuation?

    func start(
        attributes: RideActivityAttributes,
        state: RideActivityAttributes.ContentState,
        staleDate: Date?
    ) async -> Bool {
        guard allowsStart, areActivitiesEnabled else { return false }
        startCount += 1
        isPresenting = true
        endedWith = nil
        return true
    }

    func update(state: RideActivityAttributes.ContentState, staleDate: Date?) async {
        updates.append(state)
    }

    func end(state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal) async {
        endedWith = (state, dismissal)
        isPresenting = false
        continuation?.finish()
        continuation = nil
    }

    func pushTokens() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Stand in for ActivityKit issuing (or reissuing) the Activity's push token.
    func emit(token: Data) {
        continuation?.yield(token)
    }
}

final class SpyRideActivityEndpoint: RideActivityTokenEndpoint, @unchecked Sendable {
    struct Registration: Equatable {
        let rideID: String
        let token: String
        let sandbox: Bool
    }

    /// Calls that SUCCEEDED.
    private(set) var registrations: [Registration] = []
    /// Every call the coordinator made, successful or not. Kept separately because
    /// the interesting property of a failed registration is that it was ATTEMPTED
    /// — a spy that records only successes cannot tell "retried and failed again"
    /// from "never retried at all".
    private(set) var attempts: [Registration] = []
    private(set) var ends: [String] = []

    var registrationResult: Result<LiveActivityRegistrationResponse, Error> =
        .success(LiveActivityRegistrationResponse(registered: true, sandbox: true))

    func registerRideActivityToken(
        rideID: String,
        token: String,
        sandbox: Bool
    ) async throws -> LiveActivityRegistrationResponse {
        let call = Registration(rideID: rideID, token: token, sandbox: sandbox)
        attempts.append(call)
        switch registrationResult {
        case .success(let response):
            registrations.append(call)
            return response
        case .failure(let error):
            throw error
        }
    }

    func endRideActivityToken(rideID: String) async throws -> EndLiveActivityResponse {
        ends.append(rideID)
        return EndLiveActivityResponse(ended: true)
    }
}
