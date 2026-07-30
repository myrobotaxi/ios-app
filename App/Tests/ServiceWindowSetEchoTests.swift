import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-362 — the SET that returned 200 and showed nothing
//
// THE DEFECT, in one sentence: `PUT /service-window` answers with the key
// `expectedEndAt` and the client decoded a key called `serviceEstimatedEndAt`,
// so every SET adopted a `nil` that was never on the wire.
//
// TestFlight, build 202607300926 — the build carrying the MYR-351 fix:
// *"Just set the time and it didn't stick or update on the sheet."* His
// screenshot is the owner sheet on an in-service car with "Service completion
// date / Set a time" EMPTY, seconds after saving one.
//
// WHY IT WAS INVISIBLE. Every property on `VehicleServiceWindowResponse` is
// optional, so a body carrying none of them still DECODES — no throw, no notice,
// no log, no 4xx. `setServiceWindow` then took the successful branch in full:
// it committed the nil, raised MYR-251's known flag, stamped MYR-351's commit
// instant, settled `.idle` with no notice, and broadcast the nil onward. Every
// signal the app had said the save worked.
//
// WHY IT IS A SET AND NEVER A CLEAR. A clear WANTS nil, and the mis-decode
// produced nil unconditionally — so it got the right answer for the wrong reason.
// Every service-window test written for MYR-316 and MYR-351 drove the clear
// (`setServiceWindow(nil)`), which is precisely why a defect on the other half of
// the same method survived two rounds of tests about this exact field.
//
// WHY MYR-351 MADE IT PERMANENT rather than causing it. The mis-decode predates
// #130. What #130 changed is the recovery: before it, the next telemetry frame
// re-played the last snapshot's snapshot-only fields, so the row repopulated
// itself from the snapshot within seconds and the loss was survivable (and, on a
// car whose snapshot already held a window, invisible — that re-play IS MYR-351's
// report 1, "it popped right back"). `committedAt` now correctly refuses every
// read ISSUED before the write, so the mis-decoded nil is preserved exactly as a
// real committed value would be. The guard is right; what it was faithfully
// preserving was never the server's answer.
//
// WHAT §7.16 ACTUALLY SAYS, and it says it in as many words: the `200` body
// "echoes the OWNER column, not the resolved `serviceEstimatedEndAt` — echoing
// the resolved value would make a client believe its write had been overruled
// when it has merely been outranked by Tesla on the next read". The resolved
// window (`COALESCE(service_etc, service_expected_end_at)`) is therefore NOT
// knowable from the write at all, and the contract names the two legal responses:
// "adopts this response optimistically or re-reads §7.0 / §7.1". The fix does
// both — adopt the echo, and let MYR-351's deliberately non-latching guard hand
// the first read issued after the commit the last word.
@MainActor
final class ServiceWindowSetEchoTests: XCTestCase {

    /// The client's own car, as his screenshot found it: IN SERVICE, and the
    /// snapshot carries NO window — which is the COMMON case, not an edge one.
    /// Tesla returns an all-null `service_data` body for any visit with no
    /// appointment record, and that absence is the entire reason §7.16 exists.
    private static func inServiceState(serviceEstimatedEndAt: String? = nil) -> VehicleState {
        VehicleState(
            vehicleId: "veh-1", name: "Model Y", model: "Model Y", year: 2026, color: "Quicksilver",
            status: .inService, speed: 0, heading: 0, latitude: 37.79, longitude: -122.39,
            locationName: "Embarcadero", locationAddress: "1 Embarcadero Ctr",
            chargeLevel: 61, estimatedRange: 166, interiorTemp: 68, exteriorTemp: 61,
            odometerMiles: 18432, fsdMilesSinceReset: 11274,
            locked: nil, licensePlate: nil,
            serviceEstimatedEndAt: serviceEstimatedEndAt,
            rideShareEnabled: nil,
            lastUpdated: "2026-07-30T16:00:00Z"
        )
    }

    private func makeExecutor(
        _ endpoint: any VehicleServiceWindowEndpoint = ScriptedServiceWindowEndpoint()
    ) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: ScriptedCommandSender(),
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: endpoint,
            rideShareEndpoint: ScriptedRideShareEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 0
        )
    }

    // MARK: - 1. The wire

    /// THE ROOT CAUSE, at the layer it lives on. The bytes are §7.16's own
    /// "Response `200`" example from rest-api.md, verbatim.
    ///
    /// This is the assertion that could not have been written from the app side:
    /// the mis-decode is silent by construction, so the only way to catch it is to
    /// put the server's actual body in front of the type and read the value out.
    func testTheServerResponseBodyDecodesTheOwnerInstant() throws {
        let body = Data("""
        {
          "vehicleId": "clxyz1234567890abcdef",
          "expectedEndAt": "2026-07-29T18:00:00Z"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(VehicleServiceWindowResponse.self, from: body)

        XCTAssertEqual(decoded.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(
            decoded.expectedEndAt, "2026-07-29T18:00:00Z",
            "§7.16 echoes the OWNER column — a client reading any other key reads nothing, silently"
        )
        XCTAssertEqual(
            VehicleContractMapping.parseTimestamp(decoded.expectedEndAt ?? ""),
            ISO8601DateFormatter().date(from: "2026-07-29T18:00:00Z"),
            "the echo is `time.RFC3339` — seconds precision, no fractional part"
        )
    }

    /// A CLEAR echoes an explicit null on the SAME key, so nil still means nil and
    /// the fix cannot have quietly turned a clear into a no-op.
    func testTheClearResponseBodyDecodesToNil() throws {
        let body = Data(#"{"vehicleId":"clxyz1234567890abcdef","expectedEndAt":null}"#.utf8)
        let decoded = try JSONDecoder().decode(VehicleServiceWindowResponse.self, from: body)
        XCTAssertNil(decoded.expectedEndAt)
    }

    // MARK: - 2. The client's report, end to end

    /// THE REPORT: an in-service car with no window, the owner sets a time, and
    /// both owner read surfaces must show it — with nothing refetched, because the
    /// field is snapshot-only by contract and there is nothing to refetch it with.
    func testASetWindowIsOnScreenImmediatelyOnACarWhoseSnapshotHasNone() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!

        // The snapshot the sheet is holding when the editor opens.
        let onScreen = VehicleContractMapping.snapshot(from: Self.inServiceState())
        executor.reconcile(from: Self.inServiceState(), snapshotReadIssuedAt: Date())
        XCTAssertNil(
            VehicleServiceWindow.resolvedEndAt(executor: executor, snapshot: onScreen),
            "precondition: the row reads \u{201C}Set a time\u{201D}"
        )

        try await executor.setServiceWindow(picked)

        XCTAssertEqual(
            executor.uiState(for: .serviceWindow), .idle,
            "the write succeeded \u{2014} there is no notice to explain an empty row with"
        )
        XCTAssertEqual(
            VehicleServiceWindow.resolvedEndAt(executor: executor, snapshot: onScreen), picked,
            "the row and the hero line resolve through this one call \u{2014} EMPTY here is the client's screenshot"
        )
        XCTAssertNotNil(
            VehicleServiceWindow.completionLine(
                for: VehicleServiceWindow.resolvedEndAt(executor: executor, snapshot: onScreen),
                isInService: true,
                now: picked.addingTimeInterval(-3600)
            ),
            "the peek hero must carry the completion line too \u{2014} one value, two surfaces"
        )
    }

    /// The SECOND half of the same defect, and the one the owner could not see at
    /// all: the mis-decoded nil was BROADCAST. `LiveVehicleFleet.onServiceWindowSaved`
    /// writes it straight into the summary row that the RIDER-facing
    /// `LiveFleetMemberMapping` reads, so an owner setting a completion date
    /// withdrew the scheduling floor they had just created.
    func testTheSavedWindowIsBroadcastForTheRidersSchedulingFloor() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!
        var broadcast: Date??
        executor.onServiceWindowSaved = { broadcast = $0 }

        try await executor.setServiceWindow(picked)

        XCTAssertEqual(
            broadcast, .some(.some(picked)),
            "broadcasting nil is what pushed NULL into the row the rider's floor is built from"
        )
    }

    // MARK: - 3. MYR-351 must still hold — on the SET this time

    /// MYR-351's guard, asserted on the half of the method its own tests never
    /// drove. A `vehicle_update` frame carries the last snapshot's read instant,
    /// which necessarily predates the write, so it must not erase the save.
    func testASetWindowSurvivesADeltaCarryingThePreSaveSnapshotForward() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!
        let coldRead = Date()
        let preSave = Self.inServiceState()
        executor.reconcile(from: preSave, snapshotReadIssuedAt: coldRead)

        try await executor.setServiceWindow(picked)
        executor.reconcile(from: preSave, snapshotReadIssuedAt: coldRead)

        XCTAssertEqual(
            executor.controls.serviceEstimatedEndAt, picked,
            "a delta carrying the PRE-SAVE snapshot forward must not erase the set"
        )
    }

    /// The in-flight straddle, on the SET: a `/snapshot` GET issued BEFORE the
    /// write that lands after it. MYR-319's 0/0.8/3/9s cold ladder and MYR-315's
    /// foreground refetch make this routine on an in-service car.
    func testASnapshotIssuedBeforeTheSetDoesNotEraseItByArrivingAfter() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!
        let inFlight = Date()

        try await executor.setServiceWindow(picked)
        executor.reconcile(from: Self.inServiceState(), snapshotReadIssuedAt: inFlight)

        XCTAssertEqual(executor.controls.serviceEstimatedEndAt, picked)
    }

    /// And the guard still does not LATCH. A read ISSUED after the commit wins in
    /// full — including the car having left service, which is how the server
    /// retires a window (§7.16's auto-clear plus the in-service emission gate).
    func testAReadIssuedAfterTheSetStillWinsInFull() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!
        try await executor.setServiceWindow(picked)

        executor.reconcile(
            from: Self.inServiceState(serviceEstimatedEndAt: nil),
            snapshotReadIssuedAt: Date().addingTimeInterval(60)
        )
        XCTAssertNil(
            executor.controls.serviceEstimatedEndAt,
            "a later read is newer information and must be adopted, nil included"
        )
    }

    // MARK: - 4. Provenance moves to where it is provable (MYR-320 → MYR-362)

    /// The write can no longer claim a source, because §7.16's echo IS the owner's
    /// own column: it agrees with the submission unconditionally, so classifying it
    /// would answer `.manual` on every save — "Tesla hasn't provided an estimate
    /// for this visit" asserted about a car whose estimate was never read.
    func testTheWriteClaimsNoSourceBecauseTheEchoCannotProveOne() async throws {
        let executor = makeExecutor()
        try await executor.setServiceWindow(ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!)
        XCTAssertEqual(
            executor.controls.serviceWindowSource, .unknown,
            "nothing is provable at the write, so nothing is claimed"
        )
    }

    /// `.manual` is proved by the first read ISSUED after the commit coming back
    /// EQUAL to what the owner stored — which happens only when Tesla had no
    /// `service_etc` to outrank it. This is the first time the caption is reachable
    /// on the live path at all.
    func testAReadAgreeingWithTheOwnerEntryProvesItWasSetManually() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!
        try await executor.setServiceWindow(picked)

        executor.reconcile(
            from: Self.inServiceState(serviceEstimatedEndAt: "2026-08-01T22:00:00Z"),
            snapshotReadIssuedAt: Date().addingTimeInterval(30)
        )
        XCTAssertEqual(executor.controls.serviceWindowSource, .manual)
    }

    /// `.tesla` is the same comparison landing the other way: the resolved read
    /// DISAGREES with what the owner stored, so `service_etc` outranked it. The
    /// value on screen is Tesla's, and the sheet says so.
    func testAReadDisagreeingWithTheOwnerEntryProvesTeslaOutrankedIt() async throws {
        let executor = makeExecutor()
        try await executor.setServiceWindow(ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!)

        executor.reconcile(
            from: Self.inServiceState(serviceEstimatedEndAt: "2026-08-01T20:00:00Z"),
            snapshotReadIssuedAt: Date().addingTimeInterval(30)
        )
        XCTAssertEqual(executor.controls.serviceWindowSource, .tesla)
        XCTAssertEqual(
            executor.controls.serviceEstimatedEndAt,
            ISO8601DateFormatter().date(from: "2026-08-01T20:00:00Z"),
            "Tesla's estimate is what is on screen, so it is what the note describes"
        )
    }

    /// The classification is consumed ONCE. A LATER read that moves the window
    /// again is describing a different instant, so it falls back to MYR-320's own
    /// rule and drops the note rather than re-asserting a stale claim.
    func testTheProvenanceIsConsumedByTheFirstReadOnly() async throws {
        let executor = makeExecutor()
        let picked = ISO8601DateFormatter().date(from: "2026-08-01T22:00:00Z")!
        try await executor.setServiceWindow(picked)

        executor.reconcile(
            from: Self.inServiceState(serviceEstimatedEndAt: "2026-08-01T22:00:00Z"),
            snapshotReadIssuedAt: Date().addingTimeInterval(30)
        )
        XCTAssertEqual(executor.controls.serviceWindowSource, .manual)

        // Tesla files an estimate later in the visit; the window moves.
        executor.reconcile(
            from: Self.inServiceState(serviceEstimatedEndAt: "2026-08-01T19:00:00Z"),
            snapshotReadIssuedAt: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(
            executor.controls.serviceWindowSource, .unknown,
            "a moved window invalidates the note that described the old one"
        )
    }

    /// A CLEAR holds nothing to classify — it submits no instant, so there is
    /// nothing for a source to be the source OF. The next read must not inherit a
    /// claim from it.
    func testAClearHoldsNoProvenanceForTheNextReadToConsume() async throws {
        let executor = makeExecutor()
        try await executor.setServiceWindow(nil)

        executor.reconcile(
            from: Self.inServiceState(serviceEstimatedEndAt: "2026-08-01T20:00:00Z"),
            snapshotReadIssuedAt: Date().addingTimeInterval(30)
        )
        XCTAssertEqual(executor.controls.serviceWindowSource, .unknown)
    }
}
