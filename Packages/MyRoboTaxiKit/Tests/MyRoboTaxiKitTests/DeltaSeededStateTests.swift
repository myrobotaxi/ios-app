import XCTest
import MyRobotaxiContracts
@testable import MyRoboTaxiKit

// MARK: - MYR-449 — a live frame must be able to ESTABLISH state, not only refresh it
//
// THE DEFECT THESE PIN. `apply(.update:)` opened with
// `guard let current = state else { return }`, so a `vehicle_update` for a
// vehicle whose cold REST `/snapshot` had not landed was DISCARDED — every frame,
// for the life of the session, with no error and no log. The whole live surface
// was therefore gated on one REST read that the viewer path can legitimately
// never complete (a `403` latches `snapshotAccessDenied` for good, MYR-432; the
// MYR-319 ladder is bounded; MYR-440 recorded a viewer snapshot retrying "silently
// forever"). Downstream that is `state == nil` → no fix → `RiderCarMarker
// .withheld` → the rider's tracking map with no car on it: MYR-449's reported
// "Apple Maps route preview".
//
// The seeding is OPT-IN, so the owner path is byte-identical by construction, and
// the baseline can only ever publish what the car itself sent.
final class DeltaSeededStateTests: XCTestCase {

    private func makeSocket() -> TelemetrySocket {
        TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: StubSnapshotSource(state: Self.snapshot(lat: 0, lon: 0)),
            channelFactory: MockChannelFactory([MockWebSocketChannel(label: 0)])
        )
    }

    private func gpsFrame(lat: Double, lon: Double, at stamp: String = "2026-08-06T00:11:44Z") -> VehicleUpdatePayload {
        VehicleUpdatePayload(
            vehicleId: "v1",
            fields: [
                "latitude": .number(lat),
                "longitude": .number(lon),
                "heading": .number(212),
                "speed": .number(27),
                "status": .string("driving"),
                "lastUpdated": .string(stamp)
            ],
            timestamp: stamp
        )
    }

    // MARK: The fix

    /// THE HEADLINE. A seeding bridge that has never seen a snapshot renders the
    /// car's real position off the frame alone.
    @MainActor
    func testAFrameEstablishesStateWhenNoSnapshotEverLanded() {
        let bridge = LiveVehicleState(vehicleId: "v1", socket: makeSocket(), seedsStateFromDeltas: true)
        XCTAssertNil(bridge.state, "precondition: no snapshot has landed")

        bridge.apply(.update(gpsFrame(lat: 37.7871, lon: -122.3971)))

        XCTAssertNotNil(bridge.state, "a viewer frame must establish state with no snapshot behind it")
        XCTAssertEqual(bridge.state?.latitude ?? 0, 37.7871, accuracy: 0.00001)
        XCTAssertEqual(bridge.state?.longitude ?? 0, -122.3971, accuracy: 0.00001)
        XCTAssertEqual(bridge.state?.speed, 27)
        XCTAssertEqual(bridge.state?.heading, 212)
        XCTAssertEqual(bridge.state?.status, .driving)
    }

    /// Successive frames FOLD, exactly as they do onto a snapshot — the car moves.
    @MainActor
    func testSuccessiveFramesFoldOntoTheSeededState() {
        let bridge = LiveVehicleState(vehicleId: "v1", socket: makeSocket(), seedsStateFromDeltas: true)

        bridge.apply(.update(gpsFrame(lat: 37.7871, lon: -122.3971)))
        bridge.apply(.update(VehicleUpdatePayload(
            vehicleId: "v1",
            fields: ["latitude": .number(37.7920), "longitude": .number(-122.3999)],
            timestamp: "2026-08-06T00:12:44Z"
        )))

        XCTAssertEqual(bridge.state?.latitude ?? 0, 37.7920, accuracy: 0.00001)
        // The un-refreshed fields survive the fold rather than resetting to the
        // baseline: the second frame is a DELTA, not a new car.
        XCTAssertEqual(bridge.state?.speed, 27)
        XCTAssertEqual(bridge.state?.status, .driving)
    }

    // MARK: The honesty rules that make the seed safe

    /// A SEEDED STATE NEVER CLAIMS A SNAPSHOT. `snapshotReadIssuedAt` is the public
    /// signal that snapshot-only fields stand behind these values, and a delta-seeded
    /// state has none — so it stays `nil` (MYR-351's stamp must never be invented).
    @MainActor
    func testASeededStateCarriesNoSnapshotReadStamp() {
        let bridge = LiveVehicleState(vehicleId: "v1", socket: makeSocket(), seedsStateFromDeltas: true)
        bridge.apply(.update(gpsFrame(lat: 37.7871, lon: -122.3971)))

        XCTAssertNil(bridge.snapshotReadIssuedAt,
                     "a delta-seeded state has no snapshot behind it and must not claim one")
        XCTAssertNil(bridge.state?.vin, "snapshot-only identity must stay absent")
        XCTAssertNil(bridge.state?.softwareVersion)
        XCTAssertEqual(bridge.state?.name, "", "a baseline invents no identity")
        XCTAssertEqual(bridge.state?.model, "")
    }

    /// THE SEED CANNOT INVENT A POSITION. A frame carrying no GPS folds onto the
    /// `(0, 0)` no-fix sentinel and stays there, so every `hasFix` gate in the app
    /// still refuses to draw a marker — the seeding adds data, never a claim.
    @MainActor
    func testAFrameWithoutGPSLeavesTheNoFixSentinelStanding() {
        let bridge = LiveVehicleState(vehicleId: "v1", socket: makeSocket(), seedsStateFromDeltas: true)

        bridge.apply(.update(VehicleUpdatePayload(
            vehicleId: "v1", fields: ["chargeLevel": .number(61)], timestamp: "2026-08-06T00:11:44Z"
        )))

        XCTAssertEqual(bridge.state?.latitude, 0)
        XCTAssertEqual(bridge.state?.longitude, 0)
        XCTAssertEqual(bridge.state?.chargeLevel, 61)
    }

    /// A snapshot ARRIVING LATER replaces the seed outright rather than merging
    /// with it — the snapshot is the authority, and a stale seeded field must not
    /// survive underneath it.
    @MainActor
    func testALateSnapshotReplacesTheSeedAndStampsItself() {
        let bridge = LiveVehicleState(vehicleId: "v1", socket: makeSocket(), seedsStateFromDeltas: true)
        bridge.apply(.update(gpsFrame(lat: 37.7871, lon: -122.3971)))

        let issued = Date()
        bridge.apply(.snapshot(Self.snapshot(lat: 40.0, lon: -74.0), readIssuedAt: issued))

        XCTAssertEqual(bridge.state?.latitude ?? 0, 40.0, accuracy: 0.00001)
        XCTAssertEqual(bridge.state?.name, "Lunar", "the snapshot's identity replaces the baseline's blanks")
        XCTAssertEqual(bridge.snapshotReadIssuedAt, issued)
    }

    // MARK: The owner path is untouched

    /// THE DEFAULT IS THE PRE-MYR-449 BEHAVIOUR, EXACTLY. Every owner consumer
    /// constructs the bridge without the flag, so a frame with no snapshot behind
    /// it is still dropped and no owner surface can be handed a nameless car.
    @MainActor
    func testABridgeThatDoesNotSeedStillDropsAFrameWithNoSnapshot() {
        let bridge = LiveVehicleState(vehicleId: "v1", socket: makeSocket())

        bridge.apply(.update(gpsFrame(lat: 37.7871, lon: -122.3971)))

        XCTAssertNil(bridge.state, "the ordering guarantee is unchanged for a non-seeding bridge")
    }

    private static func snapshot(lat: Double, lon: Double) -> VehicleState {
        VehicleState(
            vehicleId: "v1", name: "Lunar", model: "Model Y", year: 2026, color: "Quicksilver",
            status: .parked, speed: 0, heading: 0, latitude: lat, longitude: lon,
            locationName: "Lot B", locationAddress: "1 Embarcadero Ctr",
            chargeLevel: 71, estimatedRange: 244, odometerMiles: 6349, fsdMilesSinceReset: 812.5,
            lastUpdated: "2026-08-06T00:10:00Z"
        )
    }
}
