import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// MYR-319 — the cold REST read is retried.
///
/// For a car that is STREAMING, a failed cold read is annoying but self-healing:
/// frames keep arriving and a reconnect eventually performs another one. For a
/// car that is OFFLINE or IN SERVICE it is terminal — telemetry only streams
/// while a car is awake, so `GET /api/vehicles/{id}/snapshot` is the only data
/// event that will ever happen for it, and the socket stays healthy, so nothing
/// triggers a second attempt. And a sleeping car in a service bay is exactly the
/// vehicle a backend answers `503 vehicle_asleep` for on the first ask.
///
/// The consequence upstairs is the client's bug: `LiveVehicleState.state` stays
/// nil, so the owner's sheet holds no VIN, no software version, no composed model
/// and no seat-cooling capability for the whole session.
final class ColdSnapshotRetryTests: XCTestCase {

    private func vehicleState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    private let fastBackoff = ExponentialBackoff(
        initialDelay: 0.001, multiplier: 2, maxDelay: 0.005, jitterFraction: 0)

    private func makeSocket(
        snapshots: any SnapshotFetching,
        channel: MockWebSocketChannel
    ) -> TelemetrySocket {
        TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: MockChannelFactory([channel]),
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            // Same SHAPE as production (immediate, then three backed-off), with
            // the waiting taken out so the policy is provable without sleeping.
            snapshotRetryDelays: [0, 0, 0]
        )
    }

    /// The regression: a first ask that fails must not be the only ask.
    func testAFailedColdReadIsRetriedAndTheSnapshotStillArrives() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: 1)
        let socket = makeSocket(snapshots: snapshots, channel: channel)

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()

        var iterator = stream.makeAsyncIterator()
        // Drive the stream until the snapshot lands (the failed attempt emits a
        // `.dataState(.error)` first — the honest in-between the sheet renders).
        var snapshot: VehicleState?
        while let event = await iterator.next() {
            if case .snapshot(let state) = event { snapshot = state; break }
        }
        XCTAssertEqual(snapshot?.vehicleId, "clxyz1234567890abcdef")
        let calls = await snapshots.callCount()
        XCTAssertEqual(calls, 2, "the failed cold read must be retried exactly once here")

        await socket.disconnect()
    }

    /// The retry is BOUNDED — a car that is genuinely unreachable costs the
    /// attempt schedule and then stops, never a poll.
    func testTheRetryIsBoundedForAPermanentlyFailingRead() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: .max)
        let socket = makeSocket(snapshots: snapshots, channel: channel)

        // HOLD the stream: an AsyncStream dropped on the floor terminates, which
        // unsubscribes the vehicle and there would be nothing to fetch for.
        let stream = await socket.subscribe(to: "v1")
        await socket.connect()

        await eventually { await snapshots.callCount() >= 3 }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let calls = await snapshots.callCount()
        XCTAssertEqual(calls, 3, "3 scheduled attempts, then stop — not a poll")
        // The failure is surfaced honestly rather than left claiming to load.
        let dataState = await socket.dataState(vehicleId: "v1", group: .charge)
        XCTAssertEqual(dataState, .error)

        withExtendedLifetime(stream) {}
        await socket.disconnect()
    }

    /// A vehicle nobody is watching any more must stop costing requests: the
    /// pending retry is cancelled by `unsubscribe`.
    func testUnsubscribeCancelsAPendingRetry() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = FlakySnapshotSource(state: try vehicleState(), failures: .max)
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: MockChannelFactory([channel]),
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            // A real gap, so the unsubscribe lands INSIDE the schedule.
            snapshotRetryDelays: [0, 5, 5]
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await snapshots.callCount() >= 1 }

        await socket.unsubscribe(from: "v1")
        try? await Task.sleep(nanoseconds: 80_000_000)
        let calls = await snapshots.callCount()
        XCTAssertEqual(calls, 1, "an unsubscribed vehicle must not keep being asked for")

        withExtendedLifetime(stream) {}
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

/// A `SnapshotFetching` that throws for its first `failures` calls, then answers.
/// Models the backend's `503 vehicle_asleep` for a car in a service bay.
actor FlakySnapshotSource: SnapshotFetching {
    struct Asleep: Error {}

    private let state: VehicleState
    private let failures: Int
    private var count = 0

    init(state: VehicleState, failures: Int) {
        self.state = state
        self.failures = failures
    }

    func snapshot(vehicleId: String) async throws -> VehicleState {
        count += 1
        if count <= failures { throw Asleep() }
        return state
    }

    func callCount() -> Int { count }
}
