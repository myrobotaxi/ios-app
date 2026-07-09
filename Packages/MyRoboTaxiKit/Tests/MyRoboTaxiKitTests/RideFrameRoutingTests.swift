import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// The P10 ride-hailing WS frames (`ride_request_created` / `ride_status_changed`,
/// websocket-protocol.md §4.7/§4.8 — MYR-174/175): pure `WireCodec` decode of the
/// canonical fixtures, plus the `TelemetrySocket` routing that fans each frame out
/// onto the account-wide `rideEvents()` stream. No network — a protocol-mocked
/// channel replays the frames.
final class RideFrameRoutingTests: XCTestCase {
    private let fastBackoff = ExponentialBackoff(initialDelay: 0.001, multiplier: 2, maxDelay: 0.005, jitterFraction: 0)

    // MARK: - Pure decode (WireCodec, no socket)

    func testRideRequestCreatedFrameDecodes() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/ride_request_created.json"))
        XCTAssertEqual(envelope.type, .rideRequestCreated)
        let payload = try WireCodec.decodePayload(RideRequestCreatedPayload.self, from: envelope)
        XCTAssertEqual(payload.rideRequestId, "clride0000000000000001")
        XCTAssertEqual(payload.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(payload.status, .requested)
        XCTAssertNil(payload.scheduledFor, "summary omits scheduledFor for an on-demand request")
    }

    func testRideStatusChangedFrameDecodes() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/ride_status_changed.json"))
        XCTAssertEqual(envelope.type, .rideStatusChanged)
        let payload = try WireCodec.decodePayload(RideStatusChangedPayload.self, from: envelope)
        XCTAssertEqual(payload.rideRequestId, "clride0000000000000002")
        XCTAssertEqual(payload.status, .accepted)
        XCTAssertNil(payload.rescheduleStatus, "no reschedule history on this frame")
    }

    // MARK: - Socket routing (frames -> rideEvents())

    func testSocketRoutesBothRideFramesToRideEventStream() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let factory = MockChannelFactory([channel])
        let snapshots = StubSnapshotSource(state: try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json")))
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            channelFactory: factory,
            backoff: fastBackoff,
            randomUnit: { 0.5 }
        )

        let rides = await socket.rideEvents()
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        // Ride frames are account-wide: they route WITHOUT any vehicle subscription.
        await channel.push(try Fixture.text("websocket/ride_request_created.json"))
        await channel.push(try Fixture.text("websocket/ride_status_changed.json"))

        var iterator = rides.makeAsyncIterator()

        guard case .created(let created)? = await iterator.next() else {
            return XCTFail("expected .created first")
        }
        XCTAssertEqual(created.rideRequestId, "clride0000000000000001")
        XCTAssertEqual(created.status, .requested)

        guard case .statusChanged(let changed)? = await iterator.next() else {
            return XCTFail("expected .statusChanged second")
        }
        XCTAssertEqual(changed.rideRequestId, "clride0000000000000002")
        XCTAssertEqual(changed.status, .accepted)

        await socket.disconnect()
    }
}
