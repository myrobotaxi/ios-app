import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// MYR-387 — the cold snapshot must not be hostage to the WebSocket.
///
/// `GET /api/vehicles/{id}/snapshot` is a plain REST read, and before this issue
/// `fetchAndEmitSnapshot` had exactly two callers, both of which required a live,
/// AUTHENTICATED connection: `activateSubscription` (reached from `auth_ok`, or
/// from `subscribe` when already connected) and `refreshSnapshot` (which needs a
/// subscription that had already been activated).
///
/// So a socket that failed to connect — or authenticated and was then killed, or
/// was refused terminally with `auth_failed`, after which `supervise()` breaks
/// out of its loop for the whole session — meant the snapshot was **never even
/// attempted**, on a device whose REST client had just successfully answered a
/// fleet list. That is the MYR-387 client report: the switcher chip read "Lunar"
/// and the sheet held nothing, for as long as the app was open.
///
/// The fix is a GRACE-DELAYED FALLBACK, and the grace is what keeps every healthy
/// boot byte-identical: a socket that is going to work authenticates long before
/// it elapses and cancels the fallback outright.
final class StandaloneColdSnapshotTests: XCTestCase {

    private func vehicleState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    /// **THE FIX.** No connection at all — `connect()` is never even called, so
    /// nothing will ever produce an `auth_ok`. The snapshot still arrives.
    func testTheSnapshotArrivesWithNoWebSocketConnectionAtAll() async throws {
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: 0)
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: MockChannelFactory([]),
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.05
        )

        let stream = await socket.subscribe(to: "v1")
        var iterator = stream.makeAsyncIterator()
        var snapshot: VehicleState?
        while let event = await iterator.next() {
            if case .snapshot(let state, _) = event { snapshot = state; break }
        }

        XCTAssertEqual(snapshot?.vehicleId, "clxyz1234567890abcdef")
        let dataState = await socket.dataState(vehicleId: "v1", group: .charge)
        XCTAssertEqual(dataState, .ready)
        await socket.disconnect()
    }

    /// **THE REGRESSION GUARD ON THE FIX.** A healthy boot must still make
    /// exactly ONE cold read, from the connection path, with CG-SM-4's ordering
    /// intact — the fallback is cancelled, not merely out-raced.
    ///
    /// Asserted well past the grace, so a fallback that fired late would be
    /// caught rather than missed.
    func testAHealthyHandshakeCancelsTheFallbackEntirely() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: 0)
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: MockChannelFactory([channel]),
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.05
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await snapshots.callCount() >= 1 }

        // Three graces' worth of wall time — nothing else may ask.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let calls = await snapshots.callCount()
        XCTAssertEqual(calls, 1, "the fallback fired behind a perfectly healthy connection")

        withExtendedLifetime(stream) {}
        await socket.disconnect()
    }

    /// A vehicle nobody is watching costs nothing: the pending fallback goes with
    /// the subscription.
    func testUnsubscribeCancelsThePendingFallback() async throws {
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: 0)
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: MockChannelFactory([]),
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.1
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.unsubscribe(from: "v1")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let calls = await snapshots.callCount()
        XCTAssertEqual(calls, 0, "an unsubscribed vehicle must not be asked for")
        withExtendedLifetime(stream) {}
        await socket.disconnect()
    }

    /// The fallback carries MYR-319's whole retry schedule with it — a car that is
    /// asleep at the first ask is still retried, socket or no socket.
    func testTheFallbackIsRetriedLikeAnyOtherColdRead() async throws {
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: 1)
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: MockChannelFactory([]),
            snapshotRetryDelays: [0, 0, 0],
            standaloneSnapshotGrace: 0.05
        )

        let stream = await socket.subscribe(to: "v1")
        var iterator = stream.makeAsyncIterator()
        var snapshot: VehicleState?
        while let event = await iterator.next() {
            if case .snapshot(let state, _) = event { snapshot = state; break }
        }
        XCTAssertNotNil(snapshot)
        let calls = await snapshots.callCount()
        XCTAssertEqual(calls, 2, "the failed standalone read must be retried exactly once here")

        await socket.disconnect()
    }

    /// A `.standalone` read belongs to the SUBSCRIPTION, not to a connection
    /// generation — which is the whole reason it is scoped separately. A subscribe
    /// issued before the first `runConnection()` captures generation 0, which the
    /// connect then bumps to 1; a generation-gated fallback would have its emit
    /// dropped as "superseded" in exactly the common case it exists for.
    func testTheFallbackSurvivesConnectionChurn() async throws {
        // A channel that opens and dies immediately, so the supervisor spins:
        // every attempt bumps `generation` while the standalone read is still
        // awaiting its answer.
        let snapshots = SlowSnapshotSource(state: try vehicleState(), delay: 0.3)
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: DeadChannelFactory(),
            backoff: ExponentialBackoff(initialDelay: 0.001, multiplier: 2, maxDelay: 0.005, jitterFraction: 0),
            randomUnit: { 0.5 },
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.02
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()

        var iterator = stream.makeAsyncIterator()
        var snapshot: VehicleState?
        while let event = await iterator.next() {
            if case .snapshot(let state, _) = event { snapshot = state; break }
        }
        XCTAssertNotNil(
            snapshot,
            "the standalone emit was dropped as superseded by a connection it never belonged to"
        )

        await socket.disconnect()
    }

    // MARK: - Helpers

    private func eventually(
        timeout: TimeInterval = 3.0,
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

/// A `SnapshotFetching` that always answers, but slowly — so a connection can
/// churn underneath an in-flight read.
actor SlowSnapshotSource: SnapshotFetching {
    private let state: VehicleState
    private let delay: Double
    private var count = 0

    init(state: VehicleState, delay: Double) {
        self.state = state
        self.delay = delay
    }

    func snapshot(vehicleId: String) async throws -> VehicleState {
        count += 1
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return state
    }

    func callCount() -> Int { count }
}

/// A channel that opens and then fails its very first `receive()`, so the
/// supervisor's reconnect loop churns the connection generation as fast as its
/// backoff allows. Nothing here ever reaches `auth_ok`.
actor DeadWebSocketChannel: WebSocketChannel {
    struct Dead: Error {}
    func send(_ text: String) async throws {}
    func receive() async throws -> String { throw Dead() }
    func ping() async throws {}
    func close() async {}
}

final class DeadChannelFactory: WebSocketChannelFactory, @unchecked Sendable {
    func makeChannel(url: URL) -> any WebSocketChannel { DeadWebSocketChannel() }
}
