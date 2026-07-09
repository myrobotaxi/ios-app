import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Drives the `TelemetrySocket` reconnect / resubscribe state machine against a
/// protocol-mocked socket layer with no network. Verifies the handshake reaches
/// `connected`, that a drop triggers a jittered-backoff reconnect, and that on
/// reconnect the socket re-authenticates, re-sends the per-vehicle subscribe
/// frame, and re-fetches the REST snapshot before resuming the stream
/// (NFR-3.11, Rule CG-SM-4 / CG-SM-7).
final class ReconnectStateMachineTests: XCTestCase {
    private func vehicleState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    /// Fast, deterministic backoff so tests don't wait on the 1s contract delay.
    private let fastBackoff = ExponentialBackoff(initialDelay: 0.001, multiplier: 2, maxDelay: 0.005, jitterFraction: 0)

    func testHandshakeReachesConnectedAndEmitsSnapshotFirst() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let factory = MockChannelFactory([channel])
        let snapshots = StubSnapshotSource(state: try vehicleState())
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: factory,
            backoff: fastBackoff,
            randomUnit: { 0.5 }
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()

        // First event on the stream MUST be the snapshot baseline.
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        guard case .snapshot(let state)? = first else {
            return XCTFail("expected snapshot first, got \(String(describing: first))")
        }
        XCTAssertEqual(state.vehicleId, "clxyz1234567890abcdef")

        await eventually { await socket.currentConnectionState() == .connected }
        let snapshotCalls = await snapshots.callCount()
        XCTAssertEqual(snapshotCalls, 1)

        // The auth frame and the per-vehicle subscribe frame were both sent.
        let sent = await channel.sentFrames()
        XCTAssertTrue(sent.contains { $0.contains("\"auth\"") })
        XCTAssertTrue(sent.contains { $0.contains("\"subscribe\"") && $0.contains("v1") })

        await socket.disconnect()
    }

    func testDropReconnectsResubscribesAndRefetchesSnapshot() async throws {
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let factory = MockChannelFactory([channel0, channel1])
        let snapshots = StubSnapshotSource(state: try vehicleState())
        let recorder = ConnectionRecorder()

        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: factory,
            backoff: fastBackoff,
            randomUnit: { 0.5 }
        )

        // Record the connection-state trajectory.
        let recordTask = Task {
            for await state in await socket.connectionStates() { await recorder.append(state) }
        }

        // Retain the stream — discarding it would auto-unsubscribe (onTermination).
        let stream = await socket.subscribe(to: "v1")
        await socket.connect()

        await eventually { await socket.currentConnectionState() == .connected }
        // `connected` flips before the snapshot fetch completes, so poll for it.
        await eventually { await snapshots.callCount() == 1 }
        XCTAssertEqual(factory.madeCount(), 1)

        // Simulate a silent drop: close the live channel.
        await channel0.close()

        // The socket must open a SECOND channel and re-fetch the snapshot.
        await eventually(timeout: 3.0) { factory.madeCount() == 2 }
        await eventually(timeout: 3.0) { await snapshots.callCount() == 2 }
        await eventually(timeout: 3.0) { await socket.currentConnectionState() == .connected }

        // Second attempt re-authenticated AND re-subscribed v1 (resubscribe).
        let sent1 = await channel1.sentFrames()
        XCTAssertTrue(sent1.contains { $0.contains("\"auth\"") }, "must re-auth on reconnect")
        XCTAssertTrue(sent1.contains { $0.contains("\"subscribe\"") && $0.contains("v1") }, "must resubscribe on reconnect")

        // The trajectory passed through .reconnecting and returned to .connected.
        await eventually { await recorder.contains(.reconnecting) }
        await eventually { await recorder.count(.connected) >= 2 }

        recordTask.cancel()
        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    func testDisconnectSettlesTerminalAndStopsRetrying() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let factory = MockChannelFactory([channel])
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: StubSnapshotSource(state: try vehicleState()),
            channelFactory: factory,
            backoff: fastBackoff,
            randomUnit: { 0.5 }
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        await socket.disconnect()
        await eventually { await socket.currentConnectionState() == .disconnected }

        // No new channel is created after an explicit disconnect.
        let madeAfterDisconnect = factory.madeCount()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(factory.madeCount(), madeAfterDisconnect)
        withExtendedLifetime(stream) {}
    }
}
