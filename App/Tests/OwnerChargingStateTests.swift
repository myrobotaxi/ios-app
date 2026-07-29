import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-333 — the charging session that was invisible (client defect)
//
// Jul 29, TestFlight: "Service center was charging my car but I couldn't see it
// was charging. We should ensure that state is working and the bar should be a
// clean pulsing green animation when that happens."
//
// The two screenshots a minute apart show the battery climbing 74% → 76% under a
// bar that says nothing, and a Charge tile reading "Port open". So the data path
// was healthy end to end — the charging STATE simply had nowhere to render.
//
// The layer-by-layer walk (the MYR-320 lesson: a field can persist server-side
// and be dropped by ONE projection) found the field intact everywhere EXCEPT the
// app's own view model:
//
//   contracts        `VehicleState.chargeState` — contracted since MYR-11, a
//                    `charge` atomic-group member, sourced from Tesla proto 179
//                    since MYR-42.                                     PRESENT
//   telemetry        proto decode, the MYR-260 in-service REST backfill
//                    (`charge_state.charging_state`), `internal/store`
//                    persistence, the `/snapshot` projection, the WS broadcast
//                    and the owner mask allow-list.                    PRESENT
//   MyRoboTaxiKit    `VehicleStateMerger` folds `chargeState` off a live
//                    `vehicle_update` delta.                           PRESENT
//   THE APP          `VehicleContractMapping.snapshot(from:)` read
//                    `state.chargeLevel` and nothing else — `chargeState` was
//                    never carried onto `VehicleTelemetrySnapshot`, so no view
//                    could render it.                                  MISSING
//
// These tests pin the closed link on the REAL path — `LiveVehicleFleet` →
// `TelemetrySocket` → REST snapshot → `LiveVehicleState` →
// `VehicleContractMapping` — for the client's actual car, and then pin the fold
// itself against every wire arm.
@MainActor
final class OwnerChargingStateTests: XCTestCase {

    private static let vehicleID = "7SAYGDET7TA613795-vid"

    /// The client's car as `GET /api/vehicles` returns it. Note `status:
    /// .inService`: the wire `status` enum is single-valued and the server ranks
    /// in_service ABOVE charging (`deriveVehicleStatus`), so for this car the
    /// status can never say "charging" — which is precisely why the charging
    /// treatment must read `chargeState` instead.
    private nonisolated static func listRow() -> VehicleSummary {
        VehicleSummary(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "3795",
            status: .inService,
            chargeLevel: 74,
            estimatedRange: 244,
            lastUpdated: "2026-07-29T15:46:00.000Z",
            role: .owner,
            licensePlate: nil,
            serviceEstimatedEndAt: nil
        )
    }

    /// The client's car as `GET /api/vehicles/{id}/snapshot` returns it while the
    /// service centre has it plugged in: `status: .inService` AND
    /// `chargeState: .charging`, together, which is the whole shape of the bug.
    private nonisolated static func snapshotState(
        chargeState: VehicleState.ChargeState? = .charging,
        chargeLevel: Int = 76
    ) -> VehicleState {
        VehicleState(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vin: "7SAYGDET7TA613795",
            softwareVersion: "2026.20.6.6",
            trim: "p74d",
            status: .inService,
            speed: 0,
            heading: 0,
            latitude: 33.0293,
            longitude: -96.7010,
            locationName: "Tesla Service · Plano",
            locationAddress: "420 Lexington Drive, Plano, Texas 75075",
            gearPosition: .p,
            chargeLevel: chargeLevel,
            chargeState: chargeState,
            estimatedRange: 244,
            timeToFull: 1.5,
            interiorTemp: 100,
            exteriorTemp: 90,
            odometerMiles: 6349,
            fsdMilesSinceReset: 812.5,
            // The port really was open — the ONE charge-adjacent fact the app did
            // render, because its proto 183 sibling carries a resend. Keeping it
            // here makes the test the same before/after the client experienced.
            chargePortDoorOpen: true,
            trimLabel: "Performance",
            fsdVersion: "FSD (Supervised) v14.3.5",
            lastUpdated: "2026-07-29T15:47:00.000Z"
        )
    }

    private static func makeFleet(state: VehicleState = snapshotState()) -> LiveVehicleFleet {
        // swiftlint:disable:next force_try
        let snapshotBody = try! JSONEncoder().encode(state)
        let http = RoutedHTTP([
            .init("/snapshot", body: snapshotBody),
            .init("/vehicles", body: Contracts.listResponse([Self.listRow()])),
        ])
        return LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            // Authenticates, then emits NOTHING — the in-service car that never
            // streams. The cold REST read is its only data event, which is
            // exactly the case the client hit.
            channelFactory: AuthenticatingChannelFactory()
        ))
    }

    // MARK: The bug

    /// THE regression test. An in-service car whose snapshot says `Charging` must
    /// reach the hero as `.charging`, with the In Service badge INTACT beside it.
    ///
    /// Both halves matter. Before this fix `chargingState` did not exist and the
    /// only charge-ish signal the sheet had was `status`, which for this car says
    /// `in_service` forever. Asserting the badge is still `.inService` is what
    /// makes the fix additive rather than a status hack: the car is in service AND
    /// charging, and the sheet now says both.
    func testInServiceCarThatIsChargingReachesTheHeroAsCharging() async {
        let fleet = Self.makeFleet()
        fleet.start()

        await eventually { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }

        let snapshot = fleet.telemetry(at: 0).snapshot
        XCTAssertEqual(
            snapshot.chargingState, .charging,
            "the wire chargeState must reach the snapshot — this is the link that was missing")
        XCTAssertEqual(snapshot.batteryPercent, 76, "his second screenshot's reading")
        XCTAssertEqual(
            fleet.badgeStatus(at: 0), .inService,
            "the badge must NOT be repurposed — the car is in service AND charging")
        XCTAssertEqual(
            snapshot.isStreaming, false,
            "in service → not streaming; the charge state still arrived, via the REST snapshot")

        fleet.stop()
    }

    /// The end of the same session. `Complete` is a DIFFERENT answer from
    /// `Charging`, not a synonym: the bar must stop pulsing and the caption must
    /// say the session finished. Collapsing the two would leave a car that
    /// finished charging hours ago breathing green forever.
    func testCompletedSessionIsItsOwnState() async {
        let fleet = Self.makeFleet(state: Self.snapshotState(chargeState: .complete, chargeLevel: 100))
        fleet.start()
        await eventually { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }

        XCTAssertEqual(fleet.telemetry(at: 0).snapshot.chargingState, .complete)

        fleet.stop()
    }

    /// A car that has never charged surfaces `chargeState: null`, which the
    /// contract requires consumers to tolerate with a NEUTRAL render — not a
    /// spinner and not a guess. The hero must look exactly as it did before this
    /// issue, which is what keeps every non-charging car unchanged.
    func testNullChargeStateLeavesTheHeroExactlyAsItWas() async {
        let fleet = Self.makeFleet(state: Self.snapshotState(chargeState: nil, chargeLevel: 74))
        fleet.start()
        await eventually { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }

        XCTAssertEqual(fleet.telemetry(at: 0).snapshot.chargingState, .idle)

        fleet.stop()
    }

    // MARK: The fold itself

    /// Every arm of the wire enum, pinned. The three that matter are the two
    /// named states and the catch-all; the rest exist so that adding a look for
    /// one of them later is a DELIBERATE edit to this table rather than a silent
    /// behaviour change.
    func testChargingStateFoldCoversEveryWireArm() {
        let cases: [(VehicleState.ChargeState?, VehicleChargingState, String)] = [
            (.charging, .charging, "the live session — pulsing green"),
            (.complete, .complete, "finished at the limit — static green"),
            (.disconnected, .idle, "unplugged"),
            (.stopped, .idle, "plugged in but not drawing"),
            (.noPower, .idle, "plugged into a dead outlet"),
            // `Starting` is the pre-session handshake. Claiming "Charging" before
            // the car has actually begun would be a small lie, and the state is
            // transient anyway — nothing rests here.
            (.starting, .idle, "handshake, not yet a session"),
            (.unknown, .idle, "Tesla could not read it"),
            // MYR-195 open enum: a value this build has never seen must not pick a
            // look. Neutral, and the raw string still round-trips on the wire.
            (.unrecognized("Preconditioning"), .idle, "forward-compat wire value"),
            (nil, .idle, "never charged / no charge frame yet"),
        ]
        for (wire, expected, why) in cases {
            XCTAssertEqual(
                VehicleContractMapping.chargingState(from: wire), expected,
                "\(String(describing: wire)) → \(expected): \(why)")
        }
    }

    /// The fold must read `chargeState` and ONLY `chargeState`. A car whose wire
    /// `status` is literally `charging` but whose `chargeState` says otherwise is
    /// not a live session — and, more to the point, the reverse (this test's
    /// sibling above) is the client's car. Pinning the independence here stops a
    /// future "simplification" from re-deriving the treatment off `status` and
    /// reintroducing the exact blind spot.
    func testChargingTreatmentIsIndependentOfWireStatus() {
        var state = Self.snapshotState(chargeState: .charging)
        state.status = .inService
        XCTAssertEqual(VehicleContractMapping.snapshot(from: state).chargingState, .charging)

        state.status = .charging
        state.chargeState = .disconnected
        XCTAssertEqual(
            VehicleContractMapping.snapshot(from: state).chargingState, .idle,
            "status: charging alone must not fabricate a session")
    }

    // MARK: - Polling helper (no fixed sleeps)

    private func eventually(
        timeout: TimeInterval = 5.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}
