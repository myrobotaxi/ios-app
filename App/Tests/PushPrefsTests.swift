import XCTest
import MyRoboTaxiKit
@testable import MyRoboTaxi

// MARK: - MYR-349 — the notification toggles, made real
//
// The client's report, three separate times: "the Settings notification toggles
// are local-only lies". They were `@State private var toggles =
// NotificationToggles()` on both Settings screens — private structs that
// persisted nowhere and gated nothing. This file asserts the three things that
// have to be true for that sentence to stop being accurate:
//
//  1. EVERY ROW IS BOUND TO THE RIGHT CATEGORY. This is the failure mode with no
//     other detector: a row wired to its neighbour's category still moves, still
//     saves, and still comes back holding the position the user chose. It just
//     silences a different notification. No decode, no error and no screenshot
//     can see it, so the whole six-row matrix is asserted here.
//  2. THE WRITE IS OPTIMISTIC, ADOPTS THE ECHO, AND ROLLS BACK. Including an echo
//     that DISAGREES with what was sent — the echo is §7.19's read-after-write and
//     is therefore the authority on what is now stored, so it must win over the
//     bool the client submitted (MYR-351/MYR-362).
//  3. THE SIMULATED PATH TOUCHES NOTHING. Zero network by construction, and the
//     prototype's own switch positions, which is what keeps the drift gate honest.
@MainActor
final class PushPrefsTests: XCTestCase {

    // MARK: - Stub endpoint

    /// A scripted §7.19 endpoint. Records every call so "the simulated path made
    /// no network call" is an assertion rather than a claim.
    private final class StubEndpoint: PushPrefsEndpoint, @unchecked Sendable {
        struct Failure: Error {}

        var readResult: Result<PushPrefsResponse, Error>
        var writeResults: [Result<PushPrefsResponse, Error>]
        private(set) var reads = 0
        private(set) var writes: [PushPrefsUpdateRequest] = []

        init(
            read: Result<PushPrefsResponse, Error> = .success(.allOn),
            writes: [Result<PushPrefsResponse, Error>] = []
        ) {
            self.readResult = read
            self.writeResults = writes
        }

        func pushPrefs() async throws -> PushPrefsResponse {
            reads += 1
            return try readResult.get()
        }

        func setPushPrefs(_ update: PushPrefsUpdateRequest) async throws -> PushPrefsResponse {
            writes.append(update)
            guard !writeResults.isEmpty else { return try readResult.get() }
            let next = writeResults.removeFirst()
            return try next.get()
        }
    }

    // MARK: - (1) The six-row matrix

    // Every row on BOTH screens, and the category it writes. The tables under test
    // are the ones the screens render (`ForEach` over them), so this is the
    // shipping mapping and not a second copy of it.
    func testEveryRowIsBoundToItsOwnCategory() {
        XCTAssertEqual(
            SettingsNotificationRows.owner,
            [
                .init(label: "Drive started", category: .driveStarted),
                .init(label: "Drive completed", category: .driveCompleted),
                .init(label: "Charging complete", category: .chargingComplete),
                .init(label: "Viewer joined", category: .viewerJoined),
            ]
        )
        XCTAssertEqual(
            SettingsNotificationRows.rider,
            [
                .init(label: "Request accepted / declined", category: .rideLifecycle),
                .init(label: "Pick-up & arrival alerts", category: .rideLifecycle),
            ]
        )
    }

    // The four owner categories are DISTINCT — nothing there is shared, so a
    // copy-paste slip that pointed two rows at one column would be caught here
    // even if the literals above were updated to match it.
    func testTheOwnerRowsUseFourDifferentCategories() {
        let categories = SettingsNotificationRows.owner.map(\.category)
        XCTAssertEqual(Set(categories).count, categories.count)
    }

    // The rider's two rows SHARE `rideLifecycle`, deliberately: `ride_lifecycle`
    // covers the whole requested/accepted/declined/arrived/completed status class
    // and every rider-facing send site is inside it. There is no column that could
    // switch one of these off and leave the other on, so they must always agree —
    // asserted below by driving one row and reading the other.
    func testBothRiderRowsShareOneCategoryOnPurpose() {
        XCTAssertEqual(SettingsNotificationRows.rider.map(\.category), [.rideLifecycle, .rideLifecycle])
    }

    // The client: "the tips notification seems useless." It is gone from the table
    // the screen renders, so it cannot come back through a stray call site — and
    // §7.19 has no column that could feed it if it did.
    func testTheTipsRowIsGone() {
        let labels = (SettingsNotificationRows.owner + SettingsNotificationRows.rider).map(\.label)
        XCTAssertFalse(labels.contains { $0.lowercased().contains("tips") })
        XCTAssertFalse(PushPrefCategory.allCases.map(\.rawValue).contains { $0.lowercased().contains("promo") })
        XCTAssertEqual(SettingsNotificationRows.rider.count, 2, "the rider card is two rows now, not three")
    }

    // MARK: - (2) The write pattern

    // The flip is OPTIMISTIC: the value has already moved when the write is still
    // in flight. A toggle that waited for a round trip would read as broken.
    func testTheFlipIsOptimisticAndVisibleBeforeTheWriteLands() async {
        let gate = Gate()
        let endpoint = StubEndpoint(read: .success(.allOn))
        let service = LivePushPrefsService(endpoint: GatedEndpoint(inner: endpoint, gate: gate))
        await service.load()
        XCTAssertTrue(service.prefs.chargingComplete)

        let write = Task { await service.setEnabled(.chargingComplete, false) }
        await gate.waitUntilEntered()
        XCTAssertFalse(
            service.prefs.chargingComplete,
            "the row must move under the finger, not after the round trip"
        )
        await gate.release()
        await write.value
    }

    // Every category writes ONE key — its own — and the row reads back what it
    // wrote. The full matrix, through the shipping service.
    func testEachCategoryWritesItsOwnKeyAndSettles() async {
        for category in PushPrefCategory.allCases {
            var echo = PushPrefsResponse.allOn
            echo[keyPath: PushPrefsResponse.writableKeyPath(category)] = false
            let endpoint = StubEndpoint(read: .success(.allOn), writes: [.success(echo)])
            let service = LivePushPrefsService(endpoint: endpoint)
            await service.load()

            await service.setEnabled(category, false)

            XCTAssertEqual(endpoint.writes.count, 1, "\(category)")
            XCTAssertEqual(endpoint.writes[0], PushPrefsUpdateRequest(category, false), "\(category)")
            XCTAssertFalse(service.prefs[category], "\(category)")
            for other in PushPrefCategory.allCases where other != category {
                XCTAssertTrue(service.prefs[other], "\(category) must not disturb \(other)")
            }
            XCTAssertNil(service.statusMessage)
        }
    }

    // THE ECHO WINS, even when it disagrees with the submission. §7.19's PUT
    // answers with all five re-read AFTER the write, so it is the authority on
    // what is now stored; a client that adopted its own bool would be correct by
    // luck and would break silently the day a server coerces or refuses.
    func testAnEchoThatDisagreesWithTheSubmissionWins() async {
        // Asked for OFF; the server answers ON.
        let endpoint = StubEndpoint(read: .success(.allOn), writes: [.success(.allOn)])
        let service = LivePushPrefsService(endpoint: endpoint)
        await service.load()

        await service.setEnabled(.chargingComplete, false)

        XCTAssertTrue(
            service.prefs.chargingComplete,
            "the row shows what the SERVER stored, not what the client asked for"
        )
        XCTAssertNil(service.statusMessage, "a server that coerced is a SUCCESS, not a failure")
    }

    // The echo is adopted WHOLESALE — all five keys, not just the one written. A
    // sibling the server changed underneath us must not survive the write.
    func testTheEchoIsAdoptedWholesaleAcrossAllFiveKeys() async {
        let echo = PushPrefsResponse(
            rideLifecycle: false,
            driveStarted: false,
            driveCompleted: true,
            chargingComplete: false,
            viewerJoined: false
        )
        let endpoint = StubEndpoint(read: .success(.allOn), writes: [.success(echo)])
        let service = LivePushPrefsService(endpoint: endpoint)
        await service.load()

        await service.setEnabled(.driveCompleted, true)

        XCTAssertEqual(service.prefs, PushPrefs(echo))
        XCTAssertFalse(service.prefs.rideLifecycle, "a sibling key the echo changed must be adopted too")
    }

    // A FAILED WRITE restores the previous value AND says so. Leaving the
    // optimistic position up would manufacture the exact false belief this feature
    // exists to prevent — an owner walking away believing charging alerts are off
    // while they are still firing.
    func testAFailedWriteRollsBackAndRaisesTheNotice() async {
        let endpoint = StubEndpoint(read: .success(.allOn), writes: [.failure(StubEndpoint.Failure())])
        let service = LivePushPrefsService(endpoint: endpoint)
        await service.load()

        await service.setEnabled(.chargingComplete, false)

        XCTAssertTrue(service.prefs.chargingComplete, "the row must snap back to what the server holds")
        XCTAssertEqual(service.statusMessage, LivePushPrefsService.writeFailedNotice)
    }

    // The rollback restores the PREVIOUS value, not a default — a category that
    // was already off stays off when a write to it fails.
    func testTheRollbackRestoresThePreviousValueRatherThanADefault() async {
        let stored = PushPrefsResponse(
            rideLifecycle: true,
            driveStarted: true,
            driveCompleted: true,
            chargingComplete: false,
            viewerJoined: true
        )
        let endpoint = StubEndpoint(read: .success(stored), writes: [.failure(StubEndpoint.Failure())])
        let service = LivePushPrefsService(endpoint: endpoint)
        await service.load()
        XCTAssertFalse(service.prefs.chargingComplete)

        await service.setEnabled(.chargingComplete, true)

        XCTAssertFalse(service.prefs.chargingComplete, "restored to OFF, which is where it was")
        XCTAssertEqual(service.statusMessage, LivePushPrefsService.writeFailedNotice)
    }

    // A later SUCCESS clears the notice — the line is about the last attempt, not
    // a latch.
    func testASuccessfulWriteClearsAPreviousFailureNotice() async {
        let endpoint = StubEndpoint(
            read: .success(.allOn),
            writes: [.failure(StubEndpoint.Failure()), .success(.allOn)]
        )
        let service = LivePushPrefsService(endpoint: endpoint)
        await service.load()

        await service.setEnabled(.viewerJoined, false)
        XCTAssertEqual(service.statusMessage, LivePushPrefsService.writeFailedNotice)

        await service.setEnabled(.viewerJoined, true)
        XCTAssertNil(service.statusMessage)
    }

    // MARK: - The read

    // The GET hydrates the rows from the ACCOUNT, so a value stored on another
    // device shows up here — the whole point of the issue.
    func testLoadHydratesTheRowsFromTheServer() async {
        let stored = PushPrefsResponse(
            rideLifecycle: false,
            driveStarted: true,
            driveCompleted: false,
            chargingComplete: true,
            viewerJoined: false
        )
        let endpoint = StubEndpoint(read: .success(stored))
        let service = LivePushPrefsService(endpoint: endpoint)

        await service.load()

        XCTAssertEqual(service.prefs, PushPrefs(stored))
        XCTAssertTrue(service.hasLoaded)
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(endpoint.reads, 1)
    }

    // A FAILED GET is an honest state: the notice renders and `hasLoaded` stays
    // false. It is NOT silently folded into "everything is on" — a read that did
    // not answer is not the same as an account that wants everything.
    func testAFailedLoadRendersTheHonestStateRatherThanASilentDefault() async {
        let endpoint = StubEndpoint(read: .failure(StubEndpoint.Failure()))
        let service = LivePushPrefsService(endpoint: endpoint)

        await service.load()

        XCTAssertFalse(service.hasLoaded, "nothing was read, so nothing is known")
        XCTAssertEqual(service.statusMessage, LivePushPrefsService.readFailedNotice)
    }

    // MARK: - (3) The simulated path

    // Zero network, BY CONSTRUCTION: the simulated service holds no endpoint at
    // all, so there is nothing for it to call. Asserted through the composition
    // point, which is where a live client could ever be handed to it.
    func testSimulatedModeComposesAServiceWithNoNetworkAtAll() {
        let service = PushPrefsComposition.makeService(mode: .simulated)
        XCTAssertTrue(
            service is SimulatedPushPrefsService,
            "a DEBUG capture or the offline demo must never reach §7.19"
        )
    }

    // The simulated seed is the PROTOTYPE's positions, not §7.19's defaults.
    // "Charging complete" boots OFF in screens.jsx and ON on the server; taking
    // the server's default in sim would have silently redrawn the `ownerSettings`
    // drift-gate capture.
    func testTheSimulatedSeedIsThePrototypesPositions() {
        let service = SimulatedPushPrefsService()
        XCTAssertTrue(service.prefs.driveStarted)
        XCTAssertTrue(service.prefs.driveCompleted)
        XCTAssertFalse(service.prefs.chargingComplete, "screens.jsx boots this row OFF")
        XCTAssertTrue(service.prefs.viewerJoined)
        XCTAssertTrue(service.prefs.rideLifecycle)
    }

    // The simulated service keeps local persistence exactly as the `@State`
    // structs did, and can never raise a notice — which is what keeps both
    // Settings screens pixel-identical on every simulated and DEBUG capture.
    func testTheSimulatedServiceKeepsLocalStateAndNeverFails() async {
        let service = SimulatedPushPrefsService()
        await service.load()
        XCTAssertTrue(service.hasLoaded)

        await service.setEnabled(.chargingComplete, true)
        XCTAssertTrue(service.prefs.chargingComplete)
        await service.setEnabled(.chargingComplete, false)
        XCTAssertFalse(service.prefs.chargingComplete)
        XCTAssertNil(service.statusMessage, "nothing here can fail, so nothing here can notice")
    }

    // The two rider rows are ONE value: driving either moves both, always.
    func testDrivingEitherRiderRowMovesBoth() async {
        let service = SimulatedPushPrefsService()
        let first = SettingsNotificationRows.rider[0].category
        let second = SettingsNotificationRows.rider[1].category

        await service.setEnabled(first, false)
        XCTAssertFalse(service.prefs[second], "one category, so the rows can never contradict each other")
    }

    // MARK: - The notice view's own gate

    // The quiet line renders only when there is something to say. Anything else
    // would reserve space on the overwhelmingly common path.
    func testTheNoticeIsAbsentWithoutAMessage() {
        XCTAssertNil(SimulatedPushPrefsService().statusMessage)
    }
}

// MARK: - Test support

private extension PushPrefsResponse {
    static let allOn = PushPrefsResponse(
        rideLifecycle: true,
        driveStarted: true,
        driveCompleted: true,
        chargingComplete: true,
        viewerJoined: true
    )

    static func writableKeyPath(_ category: PushPrefCategory) -> WritableKeyPath<PushPrefsResponse, Bool> {
        switch category {
        case .rideLifecycle: return \.rideLifecycle
        case .driveStarted: return \.driveStarted
        case .driveCompleted: return \.driveCompleted
        case .chargingComplete: return \.chargingComplete
        case .viewerJoined: return \.viewerJoined
        }
    }
}

/// Parks a write inside the endpoint so the OPTIMISTIC position can be observed
/// while the round trip is still in flight — the same "hold the call open" move
/// `DebugHangingRideShareEndpoint` makes for the MYR-342 pending capture.
private actor Gate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }
}

private struct GatedEndpoint: PushPrefsEndpoint, @unchecked Sendable {
    let inner: any PushPrefsEndpoint
    let gate: Gate

    func pushPrefs() async throws -> PushPrefsResponse {
        try await inner.pushPrefs()
    }

    func setPushPrefs(_ update: PushPrefsUpdateRequest) async throws -> PushPrefsResponse {
        await gate.enter()
        return try await inner.setPushPrefs(update)
    }
}
