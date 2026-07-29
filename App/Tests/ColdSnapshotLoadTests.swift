import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-326 — the cold snapshot has an END, not just a start
//
// Owner Home's loading treatment is a SKELETON now, and a skeleton is a promise
// that content is arriving. That promise has to be one the fleet can keep.
//
// Before this issue it couldn't: MYR-319's cold-read retry is bounded (0 / 0.8 /
// 3 / 9s) precisely because a car that is asleep, offline or in service produces
// no `vehicle_update` frames to re-trigger a read — and when the last attempt
// failed, nothing said so. `state` stayed nil, `isConnecting` stayed true, and
// Home showed its connecting treatment for the rest of the session with nothing
// in flight behind it. A spinner forever is bad; a shimmering placeholder
// forever is a lie.
//
// These tests drive the REAL composition (`LiveVehicleFleet` → `TelemetrySocket`
// → REST snapshot) with an authenticating-but-silent channel — the
// non-streaming car — and a snapshot route scripted to fail, so the timeout is
// reached the way a real one is.
@MainActor
final class ColdSnapshotLoadTests: XCTestCase {

    private static let vehicleID = "v-lunar"

    // MARK: - The budget itself (pure)

    /// The budget must outlast the Kit's WHOLE schedule, including the final
    /// attempt's own request. A budget of exactly `sum(delays)` would expire
    /// while the last ask was still in flight and call a car unreachable that was
    /// about to answer.
    func testBudgetOutlastsTheKitsEntireRetrySchedule() {
        let delays = TelemetrySocket.defaultSnapshotRetryDelays
        let backoff = delays.reduce(0, +)
        let budget = ColdSnapshotLoad.budget()

        XCTAssertGreaterThan(
            budget, backoff,
            "the budget expires before the last retry has even been attempted"
        )
        // Slack for every attempt's own round trip, not just the last.
        XCTAssertEqual(budget, backoff + 2 * Double(delays.count), accuracy: 0.001)
        // Sanity on the shipping schedule: 12.8s of backoff, ~20.8s of budget.
        XCTAssertEqual(backoff, 12.8, accuracy: 0.001)
        XCTAssertEqual(budget, 20.8, accuracy: 0.001)
    }

    /// A degenerate schedule (tests inject `[0]`) still gets a real budget rather
    /// than zero, which would time out instantly.
    func testBudgetIsNeverZeroForASingleAttemptSchedule() {
        XCTAssertGreaterThan(ColdSnapshotLoad.budget(delays: [0]), 0)
    }

    /// The honest line names the car when the LIST gave us a name — which it
    /// usually did, since the list is the fast call and the snapshot is the one
    /// that didn't answer. It is about reaching the CAR, not the network: the
    /// fleet list demonstrably succeeded.
    func testUnreachableMessageNamesTheCarWhenItIsKnown() {
        XCTAssertEqual(
            ColdSnapshotLoad.unreachableMessage(vehicleName: "Lunar"),
            "Can\u{2019}t reach Lunar right now"
        )
    }

    func testUnreachableMessageFallsBackWhenNoNameIsKnown() {
        for name in [nil, "", "   "] as [String?] {
            XCTAssertEqual(
                ColdSnapshotLoad.unreachableMessage(vehicleName: name),
                "Can\u{2019}t reach your vehicle right now",
                "a blank name must never render as \"Can't reach  right now\""
            )
        }
    }

    // MARK: - The fleet

    /// THE FIX. A car whose cold read never lands stops claiming to be loading
    /// once its budget is spent, and says something honest instead. Before this,
    /// `isConnecting` stayed true forever and Home never left the loading state.
    func testAColdReadThatNeverLandsStopsClaimingToBeLoading() async {
        let fleet = Self.makeFleet(snapshotAlwaysFails: true, budget: 0.4)
        fleet.start()

        // It IS loading first — the skeleton is correct while the retries run.
        await eventually { fleet.vehicles.count == 1 }
        XCTAssertTrue(fleet.isConnecting, "the skeleton must show while the read is genuinely in flight")
        XCTAssertNil(fleet.statusMessage)

        await eventually { !fleet.isConnecting }
        XCTAssertEqual(
            fleet.statusMessage, "Can\u{2019}t reach Lunar right now",
            "the honest line, naming the car the LIST already told us about"
        )
        XCTAssertNil(
            fleet.telemetry(at: 0).snapshot.odometerMiles,
            "nothing was fabricated to fill the gap"
        )

        fleet.stop()
    }

    /// The budget must NOT fire for a healthy car. This is the regression guard
    /// on the whole mechanism: a working cold read has to leave the fleet in the
    /// loaded state with no message at all.
    func testAHealthyColdReadNeverProducesATimeout() async {
        let fleet = Self.makeFleet(snapshotAlwaysFails: false, budget: 0.4)
        fleet.start()

        await eventually { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }
        XCTAssertFalse(fleet.isConnecting)
        XCTAssertNil(fleet.statusMessage)

        // Well past the budget — the watchdog must have been stood down, not just
        // out-raced.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(fleet.statusMessage, "a timeout fired behind an already-loaded sheet")
        XCTAssertFalse(fleet.isConnecting)

        fleet.stop()
    }

    /// A car that answers LATE — after the budget declared it unreachable —
    /// recovers on its own, because the snapshot arriving is what clears the
    /// timeout. No stuck "Can't reach Lunar" over a sheet full of real data.
    func testALateSnapshotClearsTheTimeoutAndTheSheetReturns() async {
        // Fails long enough to blow a very short budget, then answers.
        let fleet = Self.makeFleet(snapshotFailures: 2, budget: 0.05)
        fleet.start()

        await eventually { fleet.statusMessage != nil }
        XCTAssertFalse(fleet.isConnecting)

        // The Kit's own retry schedule is still running behind it; when it lands…
        await eventually(timeout: 6.0) { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }
        XCTAssertNil(fleet.statusMessage, "the honest line outlived the condition it described")
        XCTAssertFalse(fleet.isConnecting)

        fleet.stop()
    }

    /// A FLEET-LIST failure still wins the message. The two sources compose in
    /// one order — list first — so a 401 says "Sign-in required", never "Can't
    /// reach Lunar" (we don't even know there is a Lunar).
    func testFleetListFailureStillOwnsTheStatusLine() async {
        let envelope = Contracts.errorEnvelope(code: "auth_failed")
        let http = RoutedHTTP([
            .init("/vehicles", failFirst: Int.max, status: 401, failureBody: envelope, body: envelope),
        ])
        let fleet = LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: AuthenticatingChannelFactory(),
            coldSnapshotBudget: 0.05
        ))
        fleet.start()

        await eventually { fleet.statusMessage != nil }
        XCTAssertEqual(fleet.statusMessage, "Sign-in required to load vehicles")
        XCTAssertFalse(fleet.isConnecting)

        // And it STAYS that, past the budget — no cold read was ever started, so
        // no timeout may claim to have observed one.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fleet.statusMessage, "Sign-in required to load vehicles")

        fleet.stop()
    }

    /// Coming back to the app re-asks for the car — the same low-friction
    /// recovery a failed LIST load already had, rather than a retry button the
    /// design doesn't have. The screen goes back to LOADING while it re-asks,
    /// which is the honest description of what is happening again.
    ///
    /// Asserted on the fleet's own state rather than on a request count: the
    /// Kit's bounded retry schedule is still running behind this, so a count
    /// would rise whether or not the resume did anything.
    func testResumeRestartsTheColdReadAfterATimeout() async {
        let fleet = Self.makeFleet(snapshotAlwaysFails: true, budget: 0.4)
        fleet.start()
        await eventually { fleet.statusMessage != nil }
        XCTAssertFalse(fleet.isConnecting)

        fleet.handleBackground()
        fleet.handleForeground()

        // Synchronous on the resume — before the fresh budget can expire again.
        XCTAssertNil(fleet.statusMessage, "the resume must drop the stale honest line")
        XCTAssertTrue(fleet.isConnecting, "…and go back to loading while it re-asks")

        // And the new budget is a real one: it times out again if the car still
        // never answers, rather than leaving the skeleton up forever.
        await eventually(timeout: 3.0) { fleet.statusMessage != nil }

        fleet.stop()
    }

    // MARK: - Support

    private static func routedHTTP(
        snapshotAlwaysFails: Bool = false,
        snapshotFailures: Int = 0
    ) -> RoutedHTTP {
        // swiftlint:disable:next force_try
        let snapshotBody = try! JSONEncoder().encode(snapshotState())
        let asleep = Data(#"{"error":{"code":"vehicle_asleep","message":"did not wake"}}"#.utf8)
        return RoutedHTTP([
            .init(
                "/snapshot",
                // `Int.max` = the car never answers, for the whole test.
                failFirst: snapshotAlwaysFails ? Int.max : snapshotFailures,
                status: 503,
                failureBody: asleep,
                body: snapshotBody
            ),
            .init("/vehicles", body: Contracts.listResponse([listRow()])),
        ])
    }

    private static func makeFleet(
        snapshotAlwaysFails: Bool = false,
        snapshotFailures: Int = 0,
        budget: TimeInterval
    ) -> LiveVehicleFleet {
        LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: routedHTTP(
                snapshotAlwaysFails: snapshotAlwaysFails,
                snapshotFailures: snapshotFailures
            ),
            // Authenticates, then emits NOTHING — the non-streaming car whose
            // only possible data event is the cold REST read.
            channelFactory: AuthenticatingChannelFactory(),
            coldSnapshotBudget: budget
        ))
    }

    /// The LEAN list row: name known, nothing else. Exactly why the honest line
    /// can name the car.
    private nonisolated static func listRow() -> VehicleSummary {
        VehicleSummary(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3795",
            status: .offline,
            chargeLevel: 71,
            estimatedRange: 244,
            lastUpdated: "2026-07-26T15:40:00.000Z",
            role: .owner,
            licensePlate: nil
        )
    }

    private nonisolated static func snapshotState() -> VehicleState {
        VehicleState(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vin: "7SAYGDET7TA613795",
            softwareVersion: "2026.20.6.6",
            trim: "p74d",
            status: .offline,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 71,
            estimatedRange: 244,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 6349,
            fsdMilesSinceReset: 812.5,
            lastUpdated: "2026-07-26T15:40:00.000Z"
        )
    }

    private func eventually(
        timeout: TimeInterval = 3.0,
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
