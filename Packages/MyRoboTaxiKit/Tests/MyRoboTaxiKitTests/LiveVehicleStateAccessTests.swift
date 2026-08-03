import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// MYR-432 — the bridge's half of the revocation: a stream that ENDED because the
/// server stopped letting us must be distinguishable from one that ended because
/// we stopped watching.
@MainActor
final class LiveVehicleStateAccessTests: XCTestCase {
    private func bridge() throws -> (LiveVehicleState, VehicleState) {
        let state = try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: StubSnapshotSource(state: state),
            channelFactory: MockChannelFactory([MockWebSocketChannel(label: 0)])
        )
        return (LiveVehicleState(vehicleId: state.vehicleId, socket: socket), state)
    }

    func testAccessRevokedLatchesAndFiresTheHookExactlyOnce() throws {
        let (live, state) = try bridge()
        var fired = 0
        var revokedInsideHook = false
        live.onAccessRevoked = {
            fired += 1
            revokedInsideHook = live.accessRevoked
        }

        live.apply(.snapshot(state, readIssuedAt: Date()))
        XCTAssertFalse(live.accessRevoked)

        live.apply(.accessRevoked)
        XCTAssertTrue(live.accessRevoked)
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(revokedInsideHook, "the latch must be visible from inside the hook")

        // A second delivery changes nothing: access coming back is a NEW
        // subscription, never this bridge waking up.
        live.apply(.accessRevoked)
        XCTAssertEqual(fired, 1)
    }

    func testTheLastKnownStateIsRetainedThroughARevocation() throws {
        let (live, state) = try bridge()
        live.apply(.snapshot(state, readIssuedAt: Date()))
        live.apply(.accessRevoked)

        // NFR-3.12/3.13's rule, unchanged: the bridge never blanks itself.
        // Blanking here would make a surface that has not yet released flash empty
        // in the instant before it does, and the release is the caller's call.
        XCTAssertEqual(live.state?.vehicleId, state.vehicleId)
        XCTAssertNotNil(live.snapshotReadIssuedAt)
    }

    func testAnOrdinaryEventStreamNeverLatchesTheFlag() throws {
        let (live, state) = try bridge()
        live.apply(.snapshot(state, readIssuedAt: Date()))
        live.apply(.dataState(group: .charge, state: .stale))
        live.apply(.connectivity(ConnectivityPayload(vehicleId: state.vehicleId, online: false, timestamp: "2026-08-02T00:00:00Z")))
        XCTAssertFalse(live.accessRevoked, "a disconnect is not a revocation")
    }
}
