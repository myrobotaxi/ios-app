import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// MYR-351 — the snapshot READ STAMP, and the two properties a consumer's
/// staleness guard rests on.
///
/// The stamp exists because the three SNAPSHOT-ONLY fields (`licensePlate`,
/// `serviceEstimatedEndAt`, `rideShareEnabled`) have no WebSocket delta: a write
/// echo is the only way a client can hold their current value between cold reads,
/// so it needs to know whether an incoming read can possibly have SEEN that write.
///
/// Both properties below are load-bearing, and both are easy to break by a change
/// that looks like a simplification.
@MainActor
final class SnapshotReadStampTests: XCTestCase {

    private func baseState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    /// These tests drive `LiveVehicleState` directly — the fold and the stamp are
    /// its job, and routing through a socket would only add a handshake to assert
    /// around. The socket is a satisfied dependency, never exercised.
    private func makeLiveState() throws -> LiveVehicleState {
        LiveVehicleState(
            vehicleId: "veh-1",
            socket: TelemetrySocket(
                webSocketURL: URL(string: "wss://example/api/ws")!,
                tokenProvider: StaticTokenProvider("t"),
                snapshotSource: StubSnapshotSource(state: try baseState())
            )
        )
    }

    // MARK: - 1. A delta does NOT advance the stamp

    /// THE PROPERTY THE WHOLE FIX RESTS ON. `VehicleStateMerger.apply(fields:to:)`
    /// opens with `var state = original`, so a folded delta carries every
    /// snapshot-only field forward VERBATIM — the merger declining to FOLD them is
    /// not the same as the state not CARRYING them.
    ///
    /// So the delta's snapshot-only fields are exactly as old as the snapshot they
    /// were folded onto, and the stamp must say so. Advancing it on a delta would
    /// claim a freshness those carried-forward values do not have, and would hand a
    /// consumer's guard a reason to re-apply the very value it was protecting
    /// against — which is precisely the defect this shipped to fix.
    func testAFoldedDeltaKeepsTheSnapshotsIssueStampRatherThanAdvancingIt() throws {
        let live = try makeLiveState()

        let issuedAt = Date(timeIntervalSince1970: 1_000)
        var observed: [(VehicleState, Date)] = []
        live.onStateChanged = { state, stamp in observed.append((state, stamp)) }

        var snapshot = try baseState()
        snapshot.rideShareEnabled = true
        live.apply(.snapshot(snapshot, readIssuedAt: issuedAt))

        // A live frame carrying an unrelated (STREAMED) field.
        live.apply(.update(VehicleUpdatePayload(
            vehicleId: "veh-1",
            fields: ["chargeLevel": .number(42)],
            timestamp: "2026-07-30T12:00:00Z"
        )))

        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(observed[0].1, issuedAt, "the snapshot carries its own issue stamp")
        XCTAssertEqual(
            observed[1].1, issuedAt,
            "a delta must inherit the SNAPSHOT's stamp — its snapshot-only fields are that old"
        )
        // And the carried-forward field really is still there, which is why the
        // stamp matters at all.
        XCTAssertEqual(observed[1].0.rideShareEnabled, true)
        XCTAssertEqual(observed[1].0.chargeLevel, 42, "the streamed field IS refreshed")
        XCTAssertEqual(live.snapshotReadIssuedAt, issuedAt)
    }

    // MARK: - 2. A new snapshot DOES advance it

    /// The guard must not latch. A genuinely newer read replaces the stamp, so a
    /// consumer stops protecting a value the server has since moved past.
    func testANewSnapshotAdvancesTheStamp() throws {
        let live = try makeLiveState()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)

        live.apply(.snapshot(try baseState(), readIssuedAt: first))
        XCTAssertEqual(live.snapshotReadIssuedAt, first)

        live.apply(.snapshot(try baseState(), readIssuedAt: second))
        XCTAssertEqual(live.snapshotReadIssuedAt, second, "a fresh read replaces the stamp")
    }
}
