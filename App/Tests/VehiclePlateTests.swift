import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-286 — the owner-entered license plate, end to end
//
// The defect this pins: `LiveVehicleCommandExecutor.setPlate` wrote only to
// memory (the edit sheet's Save silently discarded the owner's input), and
// `plateDisplay` always rendered `VIN ····xxxx` no matter what was stored. Both
// halves are covered here, plus the display precedence every consuming surface
// resolves through.
@MainActor
final class VehiclePlateTests: XCTestCase {

    private static func restError(_ code: String, _ status: Int) -> RestError {
        .http(status: status, code: ErrorPayload.Code(rawValue: code), message: nil, subCode: nil)
    }

    // MARK: - 1. The display resolver matrix

    /// THE precedence rule, in one table: a non-empty plate wins; otherwise the
    /// `VIN ····xxxx` fallback; otherwise empty (and every caller HIDES the chip
    /// on empty rather than rendering a blank box). `nil` and `""` are the same
    /// answer — "no plate set" — because the server always emits the key with an
    /// empty string and only a pre-MYR-286 server omits it.
    func testPlateDisplayPrecedenceMatrix() {
        struct Case {
            let plate: String?
            let vinLast4: String
            let expected: String
            let why: String
            let line: UInt
            init(_ plate: String?, _ vinLast4: String, _ expected: String, _ why: String, line: UInt = #line) {
                self.plate = plate; self.vinLast4 = vinLast4
                self.expected = expected; self.why = why; self.line = line
            }
        }
        let cases: [Case] = [
            Case("RBO 2046", "2046", "RBO 2046", "a set plate beats the VIN fallback"),
            Case("RBO 2046", "", "RBO 2046", "a set plate needs no VIN at all"),
            Case("", "2046", "VIN ····2046", "EMPTY means not-set → the VIN fallback"),
            Case(nil, "2046", "VIN ····2046", "ABSENT (pre-MYR-286 server) → the VIN fallback"),
            Case("", "", "", "no plate and no VIN → empty, so the caller hides the chip"),
            Case(nil, "", "", "absent plate and no VIN → empty, never a fabricated value"),
            Case("   ", "2046", "VIN ····2046", "a whitespace-only plate is not a plate"),
            Case(nil, "  2046  ", "VIN ····2046", "the VIN last-4 is trimmed for the label"),
        ]
        for c in cases {
            XCTAssertEqual(
                VehicleContractMapping.plateDisplay(licensePlate: c.plate, vinLast4: c.vinLast4),
                c.expected, c.why, line: c.line
            )
        }
    }

    /// The plate is rendered VERBATIM — already server-normalized, and rest-api.md
    /// §7.1 tells consumers NOT to re-normalize. A client that lowercased, trimmed
    /// interior spacing, or collapsed "ABC 1234" to "ABC1234" would be rewriting
    /// the owner's answer ("ABC 1234" and "ABC1234" are different plates in some
    /// jurisdictions).
    func testPlateIsRenderedVerbatimNeverReNormalized() {
        XCTAssertEqual(
            VehicleContractMapping.plateDisplay(licensePlate: "ABC 1234", vinLast4: "0001"),
            "ABC 1234"
        )
        // Interior spacing preserved; no uppercasing/collapsing applied client-side.
        XCTAssertEqual(
            VehicleContractMapping.plateDisplay(licensePlate: "8-ZZZ 999", vinLast4: "0001"),
            "8-ZZZ 999"
        )
    }

    /// `editablePlate` is the RAW value for the owner's edit surface — it must NOT
    /// carry the VIN fallback, or the edit sheet would prefill a VIN the owner
    /// cannot change and "Add plate" would never appear.
    func testEditablePlateNeverCarriesTheVinFallback() {
        XCTAssertEqual(VehicleContractMapping.editablePlate(licensePlate: "RBO 2046"), "RBO 2046")
        XCTAssertEqual(VehicleContractMapping.editablePlate(licensePlate: ""), "")
        XCTAssertEqual(VehicleContractMapping.editablePlate(licensePlate: nil), "")
    }

    // MARK: - 2. BOTH read surfaces flow to their consumers

    /// The owner fleet row (`Vehicle.plate` — the map-header switcher, the
    /// Settings vehicle rows, the Invites row, the Add-Tesla summary) resolves the
    /// plate from the SNAPSHOT.
    func testOwnerRowTakesThePlateFromTheSnapshot() {
        let vehicle = VehicleContractMapping.vehicle(
            summary: Contracts.summary(vinLast4: "9417"),
            state: Contracts.parkedState(licensePlate: "RBO 2046")
        )
        XCTAssertEqual(vehicle.plate, "RBO 2046")
    }

    /// …and from the LIST ROW before the first snapshot arrives, so the switcher
    /// shows the real plate on the very first paint instead of a VIN that flips a
    /// second later.
    func testOwnerRowTakesThePlateFromTheSummaryBeforeAnySnapshot() {
        let vehicle = VehicleContractMapping.vehicle(
            summary: Contracts.summary(vinLast4: "9417", licensePlate: "RBO 2046"),
            state: nil
        )
        XCTAssertEqual(vehicle.plate, "RBO 2046")
    }

    /// A snapshot that has NOT got the plate must not erase the list row's — the
    /// summary is a real read surface, not a placeholder.
    func testSnapshotWithoutAPlateFallsBackToTheSummaryPlate() {
        let vehicle = VehicleContractMapping.vehicle(
            summary: Contracts.summary(vinLast4: "9417", licensePlate: "RBO 2046"),
            state: Contracts.parkedState(licensePlate: nil)
        )
        XCTAssertEqual(vehicle.plate, "RBO 2046")
    }

    /// Neither surface has a plate → the honest `VIN ····xxxx` degrade, exactly as
    /// before MYR-286. This is the "nothing changed for a car with no plate" pin.
    func testOwnerRowKeepsTheVinFallbackWhenNoPlateIsSet() {
        let vehicle = VehicleContractMapping.vehicle(
            summary: Contracts.summary(vinLast4: "9417", licensePlate: ""),
            state: Contracts.parkedState(licensePlate: "")
        )
        XCTAssertEqual(vehicle.plate, "VIN ····9417")
    }

    /// The RIDER's chip (Booking / Tracking / Summary sheets) reads
    /// `VehicleSummary.licensePlate` — contracts 0.15.0 puts the plate in the
    /// VIEWER role mask deliberately, because a plate only the owner can see fails
    /// at its one job: letting a rider identify the correct car at pickup.
    func testRiderChipShowsTheRealPlateFromTheSummary() {
        let member = LiveFleetMemberMapping.fleetMember(
            from: Contracts.summary(vinLast4: "2046", licensePlate: "RBO 2046")
        )
        XCTAssertEqual(member.plate, "RBO 2046")
    }

    /// Rider chip, no plate set → the VIN degrade (MYR-212's behavior, unchanged).
    func testRiderChipKeepsTheVinDegradeWhenNoPlateIsSet() {
        XCTAssertEqual(
            LiveFleetMemberMapping.fleetMember(from: Contracts.summary(vinLast4: "2046", licensePlate: "")).plate,
            "VIN ····2046"
        )
        XCTAssertEqual(
            LiveFleetMemberMapping.fleetMember(from: Contracts.summary(vinLast4: "2046", licensePlate: nil)).plate,
            "VIN ····2046"
        )
    }

    /// No plate AND no VIN → an EMPTY chip value, which every consuming sheet
    /// guards with `if !fleetMember.plate.isEmpty`. Never a blank pill.
    func testRiderChipIsEmptyRatherThanBlankWhenNothingIsKnown() {
        let member = LiveFleetMemberMapping.fleetMember(
            from: Contracts.summary(vinLast4: "", licensePlate: "")
        )
        XCTAssertTrue(member.plate.isEmpty, "the sheets hide the chip on empty — they must never render a blank pill")
    }

    // MARK: - 3. setPlate persists (the defect) and adopts the NORMALIZED echo

    func testSetPlatePersistsThroughTheEndpointAndAdoptsTheServerEcho() async {
        // The server trims + uppercases before validating, so the stored value
        // differs from what the owner typed. Adopting the raw input would leave
        // the UI disagreeing with the database until the next snapshot.
        let endpoint = ScriptedPlateEndpoint(normalizedEcho: "ABC 1234")
        let exec = makeLiveExecutor(plateEndpoint: endpoint)

        try? await exec.setPlate("  abc 1234  ")

        XCTAssertEqual(endpoint.callCount, 1, "the plate must actually be written — the MYR-286 defect was zero calls")
        XCTAssertEqual(endpoint.submitted, ["  abc 1234  "], "the RAW input is sent; normalization is the server's job")
        XCTAssertEqual(exec.controls.plate, "ABC 1234", "the SERVER's normalized echo is adopted, not the raw input")
        XCTAssertEqual(exec.uiState(for: .plate), .idle)
        XCTAssertTrue(exec.isKnown(.plate))
    }

    /// An empty submission CLEARS (§7.14: an ordinary write, not a separate verb),
    /// and the empty echo is adopted — otherwise a cleared plate would linger.
    func testClearingThePlateAdoptsTheEmptyEcho() async {
        let endpoint = ScriptedPlateEndpoint(normalizedEcho: "")
        let exec = makeLiveExecutor(plateEndpoint: endpoint, plate: "RBO 2046")

        try? await exec.setPlate("")

        XCTAssertEqual(endpoint.submitted, [""])
        XCTAssertEqual(exec.controls.plate, "", "cleared is a real answer and must be adopted")
    }

    /// The §7.14 echo is broadcast so the owner's fleet row can adopt it at once —
    /// there is NO WebSocket delta for this field, so without the hook the
    /// switcher / Settings rows would keep the stale plate until the next list
    /// fetch.
    func testSuccessfulSaveBroadcastsTheNormalizedEcho() async {
        let endpoint = ScriptedPlateEndpoint(normalizedEcho: "ABC 1234")
        let exec = makeLiveExecutor(plateEndpoint: endpoint)
        var broadcast: [String] = []
        exec.onPlateSaved = { broadcast.append($0) }

        try? await exec.setPlate("abc 1234")

        XCTAssertEqual(broadcast, ["ABC 1234"], "the NORMALIZED value is what propagates")
    }

    /// A failed save broadcasts nothing — the fleet row must not adopt a value the
    /// server never stored.
    func testFailedSaveBroadcastsNothingAndLeavesTheValueAlone() async {
        let endpoint = ScriptedPlateEndpoint(failure: Self.restError("invalid_request", 400))
        let exec = makeLiveExecutor(plateEndpoint: endpoint, plate: "RBO 2046")
        var broadcast: [String] = []
        exec.onPlateSaved = { broadcast.append($0) }

        try? await exec.setPlate("!!!!")

        XCTAssertTrue(broadcast.isEmpty)
        XCTAssertEqual(exec.controls.plate, "RBO 2046", "a rejected plate must not overwrite the stored one")
    }

    // MARK: - 4. Honest failure notices

    /// The 400 validation failure — the headline case. The server normalizes
    /// BEFORE validating, so this can never be a casing/whitespace complaint: the
    /// plate genuinely breaks the charset or the 10-character cap.
    func testValidationFailureSurfacesTheHonestPlateNotice() async {
        let endpoint = ScriptedPlateEndpoint(failure: Self.restError("invalid_request", 400))
        let exec = makeLiveExecutor(plateEndpoint: endpoint)

        try? await exec.setPlate("!!!!!!!!!!!!")

        let state = exec.uiState(for: .plate)
        XCTAssertFalse(state.isPending)
        XCTAssertEqual(state.notice, .invalidPlate)
        XCTAssertEqual(state.notice?.message, "That plate doesn’t look right")
        XCTAssertNil(state.notice?.action, "there is nothing to route to — the fix is to correct the plate")
        XCTAssertFalse(exec.isKnown(.plate), "a rejected plate confirms nothing")
    }

    /// The whole §7.14 catalog → honest copy. Nothing on this path may mention the
    /// CAR: §7.14 is a local owner-scoped DB write that makes no Tesla call at all,
    /// so "Couldn't reach the car" / "asleep" / "the car didn't accept that" would
    /// all be lies here.
    func testPlateErrorCatalogNeverBlamesTheCar() async {
        struct Case {
            let code: String
            let status: Int
            let expected: VehicleCommandNotice
            let line: UInt
            init(_ code: String, _ status: Int, _ expected: VehicleCommandNotice, line: UInt = #line) {
                self.code = code; self.status = status; self.expected = expected; self.line = line
            }
        }
        let cases: [Case] = [
            Case("invalid_request", 400, .invalidPlate),
            Case("auth_failed", 401, .relink),
            // Account-level failures keep the existing re-link route (the one
            // notice on this path that has somewhere to send the owner).
            Case("vehicle_not_owned", 403, .relink),
            Case("not_found", 404, .plateNotSaved),
            Case("internal_error", 500, .plateNotSaved),
        ]
        for c in cases {
            let exec = makeLiveExecutor(plateEndpoint: ScriptedPlateEndpoint(failure: Self.restError(c.code, c.status)))
            try? await exec.setPlate("ABC")
            let notice = exec.uiState(for: .plate).notice
            XCTAssertEqual(notice, c.expected, "notice for \(c.code)", line: c.line)
            XCTAssertFalse(
                notice?.message.localizedCaseInsensitiveContains("car") ?? false,
                "\(c.code): §7.14 never touches the car, so its copy must not blame one",
                line: c.line
            )
        }
    }

    /// A transport failure (no HTTP response at all) is still an honest
    /// "couldn't save", never "couldn't reach the car".
    func testTransportFailureReadsAsCouldntSave() async {
        struct Boom: Error {}
        let endpoint = ScriptedPlateEndpoint(failure: .transport(underlying: Boom()))
        let exec = makeLiveExecutor(plateEndpoint: endpoint)

        try? await exec.setPlate("ABC")

        XCTAssertEqual(exec.uiState(for: .plate).notice, .plateNotSaved)
        XCTAssertEqual(exec.uiState(for: .plate).notice?.message, "Couldn’t save the plate")
    }

    /// The §7.9 command vocabulary is unreachable on this endpoint, and the
    /// mapping keeps it that way even if a code somehow arrived.
    func testPlateNoticeMappingIsSeparateFromTheCommandMapping() {
        // Same failure kind, two different honest answers — because the plate is
        // not a Tesla command.
        XCTAssertEqual(LiveVehicleCommandExecutor.notice(for: .invalidRequest, key: .plate), .invalidPlate)
        XCTAssertEqual(LiveVehicleCommandExecutor.notice(for: .invalidRequest, key: .lock), .failed)
        XCTAssertEqual(LiveVehicleCommandExecutor.notice(for: .vehicleAsleep, key: .plate), .plateNotSaved)
        XCTAssertEqual(LiveVehicleCommandExecutor.notice(for: .vehicleAsleep, key: .lock), .asleep)
        // …and the charge-port scope carve-out is untouched by the new branch.
        XCTAssertEqual(LiveVehicleCommandExecutor.notice(for: .permissionDenied, key: .chargePort), .relinkCharging)
    }

    /// Double-save suppression: a second Save while the write is in flight is
    /// dropped, exactly like the commanded controls.
    func testSecondSaveIsSuppressedWhileOneIsInFlight() async {
        let endpoint = GatedPlateEndpoint(normalizedEcho: "ABC")
        let exec = makeLiveExecutor(plateEndpoint: endpoint)

        let first = Task { try? await exec.setPlate("ABC") }
        await endpoint.waitUntilInFlight()
        XCTAssertTrue(exec.uiState(for: .plate).isPending)

        try? await exec.setPlate("XYZ")
        XCTAssertEqual(endpoint.callCount, 1, "the second save is suppressed while one is in flight")

        endpoint.release()
        await first.value
        XCTAssertFalse(exec.uiState(for: .plate).isPending)
    }

    // MARK: - 5. Reconcile from the SNAPSHOT (there is no WS delta)

    func testReconcileAdoptsThePlateFromASnapshot() {
        let exec = makeLiveExecutor()
        XCTAssertEqual(exec.controls.plate, "")
        XCTAssertFalse(exec.isKnown(.plate))

        exec.reconcile(from: Contracts.parkedState(licensePlate: "RBO 2046"))

        XCTAssertEqual(exec.controls.plate, "RBO 2046")
        XCTAssertTrue(exec.isKnown(.plate))
    }

    /// A snapshot carrying an EMPTY plate is a real answer ("the owner cleared it")
    /// and must be adopted — skipping it would leave a deleted plate on the row
    /// forever. The `VIN ····xxxx` fallback is applied at DISPLAY time, never here:
    /// baking it in would put an uneditable VIN into the edit sheet.
    func testReconcileAdoptsAnEmptyPlateAndNeverBakesInTheVinFallback() {
        let exec = makeLiveExecutor(plate: "RBO 2046")

        exec.reconcile(from: Contracts.parkedState(licensePlate: ""))

        XCTAssertEqual(exec.controls.plate, "", "an empty plate is a real answer, not a skip")
        XCTAssertFalse(exec.controls.plate.contains("VIN"), "the VIN fallback belongs to display, not to the editable value")
    }

    /// An ABSENT plate (a pre-MYR-286 server) leaves the value untouched and
    /// honestly unknown — never a fabricated one.
    func testReconcileLeavesAnAbsentPlateAlone() {
        let exec = makeLiveExecutor()
        exec.reconcile(from: Contracts.parkedState(licensePlate: nil))
        XCTAssertEqual(exec.controls.plate, "")
        XCTAssertFalse(exec.isKnown(.plate), "absent on the wire stays honestly unknown")
    }

    /// A snapshot that lands while a save is in flight must NOT clobber the
    /// in-flight value — same discipline the sibling fields use.
    func testReconcileIsSkippedWhileASaveIsInFlight() async {
        let endpoint = GatedPlateEndpoint(normalizedEcho: "ABC 1234")
        let exec = makeLiveExecutor(plateEndpoint: endpoint, plate: "OLD")

        let save = Task { try? await exec.setPlate("abc 1234") }
        await endpoint.waitUntilInFlight()

        exec.reconcile(from: Contracts.parkedState(licensePlate: "STALE 1"))
        XCTAssertEqual(exec.controls.plate, "OLD", "an in-flight save owns the value until it settles")

        endpoint.release()
        await save.value
        XCTAssertEqual(exec.controls.plate, "ABC 1234", "the ack's echo settles it")
    }

    // MARK: - 6. The simulated path is untouched (drift gate)

    /// `SimulatedVehicleCommandExecutor` still mutates locally with no endpoint and
    /// no notice, so every `.simulated` / DEBUG scene renders pixel-identically —
    /// the fixture plates (RBO-2046 et al.) keep rendering exactly as before.
    func testSimulatedExecutorStillWritesLocallyWithNoNotice() async {
        let exec = SimulatedVehicleCommandExecutor(driving: false, plate: "RBO-2046")
        XCTAssertEqual(exec.controls.plate, "RBO-2046")

        try? await exec.setPlate("NEW-1")

        XCTAssertEqual(exec.controls.plate, "NEW-1")
        XCTAssertEqual(exec.uiState(for: .plate), .idle, "no notice surface on the simulated path")
        XCTAssertTrue(exec.isKnown(.plate), "fixtures are authoritative in sim")
    }

    /// Fixture fleet members carry their own plate and never route through the
    /// contracts mapping, so the drift-gate scenes are unaffected by this issue.
    func testFixtureFleetPlatesAreUnchanged() {
        XCTAssertFalse(RideRequestFixtures.fleet[0].plate.isEmpty)
        XCTAssertFalse(RideRequestFixtures.fleet[0].plate.hasPrefix("VIN"))
    }

    // MARK: - Helpers

    private func makeLiveExecutor(
        plateEndpoint: any VehiclePlateEndpoint = ScriptedPlateEndpoint(),
        plate: String = ""
    ) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: NoopPlateTestSender(),
            plateEndpoint: plateEndpoint,
            // MYR-316 — the plate tests never touch the service window; this
            // satisfies the seam without changing any assertion here.
            serviceWindowEndpoint: NoopServiceWindowEndpoint(),
            rideShareEndpoint: NoopRideShareEndpoint(),
            driving: false,
            plate: plate,
            wakeRetryDelay: .zero,
            maxWakeRetries: 0
        )
    }
}

// MARK: - Fakes

/// MYR-316 — the plate tests never write a service window; this satisfies the
/// seam. Any call is a test bug, so it returns the "no window known" answer
/// rather than inventing one.
/// The plate tests never flip the ride-share switch; this satisfies the seam.
private struct NoopRideShareEndpoint: VehicleRideShareEndpoint {
    func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
        VehicleRideShareResponse(vehicleId: vehicleID, enabled: enabled)
    }
}

private struct NoopServiceWindowEndpoint: VehicleServiceWindowEndpoint {
    func setServiceWindow(expectedEndAt: String?, vehicleID: String) async throws -> VehicleServiceWindowResponse {
        VehicleServiceWindowResponse(vehicleId: vehicleID, serviceEstimatedEndAt: nil)
    }
}

/// The plate tests never send a §7.9 command; this satisfies the seam.
private struct NoopPlateTestSender: VehicleCommandSending {
    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        VehicleCommandResult(status: "applied", command: command.name, vin: nil)
    }
}

/// Holds the FIRST write inside `setLicensePlate` until `release()`, so a test can
/// observe the pending state (and prove a concurrent second Save is suppressed, or
/// that a snapshot arriving mid-flight can't clobber the value).
private final class GatedPlateEndpoint: VehiclePlateEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private let echo: String
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(normalizedEcho: String) { self.echo = normalizedEcho }

    func setLicensePlate(_ plate: String, vehicleID: String) async throws -> VehiclePlateResponse {
        lock.lock(); count += 1; let n = count; lock.unlock()
        if n == 1 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); continuation = c; lock.unlock()
            }
        }
        return VehiclePlateResponse(vehicleId: vehicleID, licensePlate: echo)
    }

    func release() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Polls until the first write is parked inside the endpoint — no fixed sleep.
    func waitUntilInFlight() async {
        for _ in 0..<500 {
            lock.lock(); let parked = continuation != nil; lock.unlock()
            if parked { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
