import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-319 — the NON-STREAMING live car, end to end (client bug)
//
// The client's car is IN SERVICE. Telemetry only streams while a car is awake,
// so this vehicle produces ZERO `vehicle_update` frames — forever. Everything
// the owner sheet can ever know about it arrives in the one cold REST
// `GET /api/vehicles/{id}/snapshot` the socket fetches on connect.
//
// The server's snapshot for that car is verified live and carries the lot:
//   vin 7SAYGDET7TA613795 · softwareVersion 2026.20.6.6 · trim p74d ·
//   model "Model Y" · odometerMiles 6349 · seatCoolingCapable true ·
//   status in_service.
//
// MYR-320 — telemetry PR #340 enriched that same verified snapshot with three
// more facts, so the fixture carries them too: color "Quicksilver", the
// display-ready trimLabel "Performance", and fsdVersion
// "FSD (Supervised) v14.3.5". `trim` stays "p74d" — the RAW BADGE CODE this car
// actually reports, and the string the owner saw in the Model row before this
// issue ("2026 Model Y p74d"). Keeping both fields on the fixture is what makes
// the assertions below a substitution proof rather than a formatting check.
//
// Yet the owner saw the VEHICLE DETAILS section empty and no Heat↔Cool seat
// toggle. This test drives the REAL path — `LiveVehicleFleet` → `TelemetrySocket`
// (authenticating channel, zero frames) → REST snapshot → `LiveVehicleState` →
// `VehicleContractMapping` — and asserts the mapped row + snapshot carry those
// values. No DEBUG scene, no injected fleet: those inject a `VehicleState`
// downstream of the very composition the bug lives in.
@MainActor
final class OwnerVehicleDetailsLivePathTests: XCTestCase {

    private static let vehicleID = "7SAYGDET7TA613795-vid"

    /// The client's car as `GET /api/vehicles` returns it: the LEAN list row. It
    /// carries a partial model and no VIN/software — which is exactly why the
    /// snapshot has to reach the mapping for the details to populate.
    private nonisolated static func listRow(
        serviceEstimatedEndAt: String? = nil
    ) -> VehicleSummary {
        VehicleSummary(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "3795",
            status: .inService,
            chargeLevel: 71,
            estimatedRange: 244,
            lastUpdated: "2026-07-26T15:40:00.000Z",
            role: .owner,
            licensePlate: nil,
            serviceEstimatedEndAt: serviceEstimatedEndAt
        )
    }

    /// The client's car as `GET /api/vehicles/{id}/snapshot` returns it — the
    /// LIVE-VERIFIED values, in the wire shape the server emits them.
    private nonisolated static func snapshotState() -> VehicleState {
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
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Tesla Service · Burlingame",
            locationAddress: "50 Edwards Ct, Burlingame, CA",
            gearPosition: .p,
            chargeLevel: 71,
            chargeState: nil,
            estimatedRange: 244,
            timeToFull: nil,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 6349,
            fsdMilesSinceReset: 812.5,
            // The car has cooled seats per the REST vehicle_config spec — the
            // authoritative MYR-308 field. No cooler READ-BACKS are present,
            // because a non-streaming car never streams any.
            seatCoolingCapable: true,
            // MYR-320 — the two contracts-0.18.0 detail-sheet strings, in their
            // wire positions. `trimLabel` sits alongside the `trim: "p74d"` above
            // it, deliberately: the Model row must compose from this one and
            // ignore that one.
            trimLabel: "Performance",
            fsdVersion: "FSD (Supervised) v14.3.5",
            lastUpdated: "2026-07-26T15:40:00.000Z"
        )
    }

    private static func makeFleet(
        state: VehicleState = snapshotState(),
        row: VehicleSummary = listRow(),
        snapshotFailures: Int = 0
    ) -> LiveVehicleFleet {
        // swiftlint:disable:next force_try
        let snapshotBody = try! JSONEncoder().encode(state)
        let http = RoutedHTTP([
            .init("/snapshot", failFirst: snapshotFailures, status: 503,
                  failureBody: Data(#"{"error":{"code":"vehicle_asleep","message":"did not wake"}}"#.utf8),
                  body: snapshotBody),
            .init("/vehicles", body: Contracts.listResponse([row])),
        ])
        return LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            // Authenticates, then emits NOTHING — the non-streaming car.
            channelFactory: AuthenticatingChannelFactory()
        ))
    }

    // MARK: The bug

    /// THE regression test. A car that never streams a frame must still show
    /// everything its REST snapshot carries: the composed model, the full VIN,
    /// the software version, the real odometer — and the ventilated-seat
    /// capability that puts the Heat↔Cool toggle on screen.
    func testNonStreamingCarPopulatesVehicleDetailsFromTheRestSnapshot() async {
        let fleet = Self.makeFleet()
        fleet.start()

        // The snapshot lands through the normal pipeline (no WS frame involved).
        await eventually { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }

        let vehicle = fleet.vehicles[0]
        // MYR-320 — composed from the DISPLAY-READY `trimLabel`. The same snapshot
        // carries `trim: "p74d"`, which is what this row used to render; that the
        // badge code is absent here is the substitution proof.
        XCTAssertEqual(vehicle.model, "2026 Model Y Performance", "the composed model from the snapshot")
        XCTAssertFalse(vehicle.model.contains("p74d"), "the raw trim badge must never reach a display surface")
        XCTAssertEqual(vehicle.vin, "7SAYGDET7TA613795", "VEHICLE DETAILS · VIN")
        XCTAssertEqual(vehicle.softwareVersion, "2026.20.6.6", "VEHICLE DETAILS · Software")
        // MYR-320 — the two enriched rows, both rendered verbatim off the same
        // cold read. Color needed no mapping change (it has always flowed through
        // `VehicleState.color`); this asserts it arrives non-empty now that the
        // server populates it, so the row stops showing its honest empty state.
        XCTAssertEqual(vehicle.colorName, "Quicksilver", "VEHICLE DETAILS · Color")
        XCTAssertEqual(vehicle.fsdVersion, "FSD (Supervised) v14.3.5", "VEHICLE DETAILS · FSD")
        XCTAssertTrue(
            vehicle.seatVent,
            "seatCoolingCapable=true must reach the row, or the Heat↔Cool toggle never renders")

        let snapshot = fleet.telemetry(at: 0).snapshot
        XCTAssertEqual(snapshot.odometerMiles, 6349, "Lifetime · Odometer")
        XCTAssertEqual(snapshot.isStreaming, false, "in service → not streaming")
        XCTAssertEqual(fleet.badgeStatus(at: 0), .inService)
        XCTAssertFalse(fleet.isConnecting, "the sheet must be showing, not the connecting state")

        fleet.stop()
    }

    /// THE CLIENT'S BUG. The cold REST read is the ONLY data event a
    /// non-streaming car will ever produce, and the first ask for a car that is
    /// asleep in a service bay is exactly the ask a backend answers `503
    /// vehicle_asleep`. Before this fix that single failure was TERMINAL: the
    /// socket absorbed it into an `.error` data state and never asked again —
    /// there is no next frame to trigger anything, and the socket stays healthy so
    /// there is no reconnect either. The owner's sheet therefore held no VIN, no
    /// software version, no composed model and no seat capability for the entire
    /// session, from a snapshot the server was serving perfectly well one second
    /// later.
    func testAFailedColdReadIsRetriedSoANonStreamingCarStillPopulates() async {
        let fleet = Self.makeFleet(snapshotFailures: 1)
        fleet.start()

        await eventually { fleet.vehicles.first?.vin != nil }

        let vehicle = fleet.vehicles[0]
        XCTAssertEqual(vehicle.vin, "7SAYGDET7TA613795")
        XCTAssertEqual(vehicle.softwareVersion, "2026.20.6.6")
        XCTAssertEqual(vehicle.model, "2026 Model Y Performance")
        XCTAssertEqual(vehicle.colorName, "Quicksilver")
        XCTAssertEqual(vehicle.fsdVersion, "FSD (Supervised) v14.3.5")
        XCTAssertTrue(vehicle.seatVent)
        XCTAssertFalse(fleet.isConnecting)

        fleet.stop()
    }

    /// The seat capability specifically: `SeatClimatePresentation` must see the
    /// spec field off the snapshot. Kept separate from the details assertions
    /// because it is the client's SECOND symptom and has its own resolver.
    func testNonStreamingCarOffersSeatCoolingWhenTheSpecSaysItHasIt() async {
        let fleet = Self.makeFleet()
        fleet.start()
        await eventually { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }

        XCTAssertTrue(fleet.vehicles[0].seatVent)

        fleet.stop()
    }

    /// The same path also has to carry MYR-316's service window: it is
    /// snapshot-only by contract, so a non-streaming car is the ONLY way it ever
    /// arrives. `nil` here would silently hide the estimated-completion line for
    /// exactly the cars that have one.
    func testNonStreamingCarCarriesTheServiceWindowFromTheSnapshot() async {
        var state = Self.snapshotState()
        state.serviceEstimatedEndAt = "2026-08-01T21:00:00.000Z"
        let fleet = Self.makeFleet(state: state)
        fleet.start()
        await eventually { fleet.telemetry(at: 0).snapshot.serviceEstimatedEndAt != nil }

        let expected = ISO8601DateFormatter().date(from: "2026-08-01T21:00:00Z")
        XCTAssertEqual(fleet.telemetry(at: 0).snapshot.serviceEstimatedEndAt, expected)

        fleet.stop()
    }

    // MARK: The seat block's placement rule (MYR-319)

    /// The client's SECOND symptom: "no seat Heat↔Cool toggle". The capability
    /// reached the row (above) — but the seat block itself was rendered ONLY
    /// inside the climate-ON branch, and a car in a service bay reports no
    /// `isClimateOn` at all. So the one car whose snapshot authoritatively says
    /// `seatCoolingCapable: true` was also the one car that could never show the
    /// control.
    func testSeatBlockShowsForACarThatIsNotReportingClimateState() {
        // Live, non-streaming: climate unknown → the block must be on screen.
        XCTAssertTrue(SeatClimatePresentation.showsSeatBlock(climateOnKnown: false, climateOn: false))
        XCTAssertTrue(SeatClimatePresentation.showsSeatBlock(climateOnKnown: false, climateOn: true))
    }

    /// The two CONFIRMED states are unchanged — which is what keeps the simulated
    /// path and every drift-gate scene byte-identical (the simulated executor
    /// knows every field, so it is only ever on one of these two branches).
    func testSeatBlockKeepsItsConfirmedOnAndOffBehaviourExactly() {
        XCTAssertTrue(SeatClimatePresentation.showsSeatBlock(climateOnKnown: true, climateOn: true))
        XCTAssertFalse(
            SeatClimatePresentation.showsSeatBlock(climateOnKnown: true, climateOn: false),
            "the designed climate-OFF card is its own layout; the seats come back with the HVAC")
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
