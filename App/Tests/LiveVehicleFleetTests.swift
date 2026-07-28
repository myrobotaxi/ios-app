import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-201 — live fleet REST load + graceful states (no network)
//
// Exercises `LiveVehicleFleet` end-to-end with an injected `HTTPPerforming`
// stub (the REST list) and a parked WS channel factory (so the socket makes no
// real dial). Verifies the fleet maps summaries → `Vehicle` rows and surfaces
// the quiet auth/unreachable states rather than crashing.
@MainActor
final class LiveVehicleFleetTests: XCTestCase {

    private func makeFleet(status: Int, body: Data) -> LiveVehicleFleet {
        LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: StubHTTP(status: status, body: body),
            channelFactory: ParkedChannelFactory()
        ))
    }

    func testLoadsFleetAndMapsRows() async {
        let fleet = makeFleet(
            status: 200,
            body: Contracts.listResponse([
                Contracts.summary(vehicleId: "v1", name: "Cybercab", model: "Cybercab", year: 2026, color: "Mercury Silver", vinLast4: "2046", status: .driving, chargeLevel: 68),
                Contracts.summary(vehicleId: "v2", name: "Daily", model: "Model 3 LR", year: 2024, color: "Pearl White", vinLast4: "9417", status: .parked, chargeLevel: 82),
            ])
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        XCTAssertEqual(fleet.vehicles.map(\.id), ["v1", "v2"])
        XCTAssertEqual(fleet.vehicles[0].model, "2026 Cybercab")
        XCTAssertEqual(fleet.vehicles[1].plate, "VIN ····9417")
        XCTAssertEqual(fleet.badgeStatus(at: 0), .driving)
        XCTAssertEqual(fleet.badgeStatus(at: 1), .parked)
        XCTAssertNil(fleet.statusMessage)

        fleet.stop()
    }

    // MYR-258 (§7.12) — remove drops the car from the fleet immediately (Home +
    // Settings read the same list), keeps the parallel arrays aligned, and is a
    // no-op for an unknown id. Removing the last car surfaces the empty notice.
    func testRemoveDropsVehicleFromFleet() async {
        let fleet = makeFleet(
            status: 200,
            body: Contracts.listResponse([
                Contracts.summary(vehicleId: "v1", name: "Cybercab", model: "Cybercab", year: 2026, color: "Mercury Silver", vinLast4: "2046", status: .driving, chargeLevel: 68),
                Contracts.summary(vehicleId: "v2", name: "Daily", model: "Model 3 LR", year: 2024, color: "Pearl White", vinLast4: "9417", status: .parked, chargeLevel: 82),
            ])
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        // Unknown id → no-op (idempotent, mirrors the endpoint's re-remove).
        fleet.remove(vehicleID: "nope")
        XCTAssertEqual(fleet.vehicles.map(\.id), ["v1", "v2"])

        fleet.remove(vehicleID: "v1")
        XCTAssertEqual(fleet.vehicles.map(\.id), ["v2"])
        // The parallel arrays stayed aligned — the remaining row still resolves.
        XCTAssertEqual(fleet.vehicles[0].plate, "VIN ····9417")
        XCTAssertEqual(fleet.badgeStatus(at: 0), .parked)

        fleet.remove(vehicleID: "v2")
        XCTAssertTrue(fleet.vehicles.isEmpty)
        XCTAssertEqual(fleet.statusMessage, "No vehicles linked to this account")

        fleet.stop()
    }

    func testAuthFailureSurfacesQuietSignInMessage() async {
        let fleet = makeFleet(status: 401, body: Contracts.errorEnvelope(code: "auth_failed"))
        fleet.start()
        await eventually { fleet.statusMessage != nil }

        XCTAssertEqual(fleet.statusMessage, "Sign-in required to load vehicles")
        XCTAssertFalse(fleet.isConnecting)
        XCTAssertTrue(fleet.vehicles.isEmpty)

        fleet.stop()
    }

    func testEmptyFleetSurfacesNoVehiclesMessage() async {
        let fleet = makeFleet(status: 200, body: Contracts.listResponse([]))
        fleet.start()
        await eventually { fleet.statusMessage != nil }

        XCTAssertEqual(fleet.statusMessage, "No vehicles linked to this account")
        XCTAssertFalse(fleet.isConnecting)
        XCTAssertTrue(fleet.vehicles.isEmpty)

        fleet.stop()
    }

    func testStartIsIdempotent() async {
        let fleet = makeFleet(status: 200, body: Contracts.listResponse([Contracts.summary()]))
        fleet.start()
        fleet.start() // second call must not double-load or crash
        await eventually { fleet.vehicles.count == 1 }
        XCTAssertEqual(fleet.vehicles.count, 1)
        fleet.stop()
    }

    func testStopIsIdempotentAndLeakFree() async {
        let fleet = makeFleet(status: 200, body: Contracts.listResponse([Contracts.summary()]))
        fleet.start()
        await eventually { fleet.vehicles.count == 1 }
        // Re-entry cycle (deliverable 4): stop → start again cleanly.
        fleet.stop()
        fleet.stop()
        fleet.start()
        await eventually { fleet.vehicles.count == 1 }
        fleet.stop()
    }

    // MARK: - MYR-315: foreground refetch + on-demand refresh

    /// A fleet over a SEQUENCED transport + a movable clock, so a resume's cost is
    /// countable and the 10s debounce is provable without sleeping for 10s.
    private func makeSequencedFleet(
        _ stubs: [SequencedHTTP.Stub],
        clock: TestClock
    ) -> (LiveVehicleFleet, SequencedHTTP) {
        let http = SequencedHTTP(stubs)
        let fleet = LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: ParkedChannelFactory(),
            now: { clock.now }
        ))
        return (fleet, http)
    }

    private func twoCarList(
        status: VehicleSummary.Status = .parked,
        plate: String? = nil
    ) -> Data {
        Contracts.listResponse([
            Contracts.summary(vehicleId: "v1", name: "Cybercab", status: status, licensePlate: plate),
            Contracts.summary(vehicleId: "v2", name: "Daily", status: .parked),
        ])
    }

    // A glance at another app must not cost a round trip. The WS nudge still fires
    // (it is free and correct at any interval); the LIST is what we refuse to
    // re-fetch.
    func testForegroundAfterABriefBackgroundSpellSkipsTheRefetch() async {
        let clock = TestClock()
        let (fleet, http) = makeSequencedFleet([.init(body: twoCarList())], clock: clock)
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }
        let afterLoad = await http.requestCount()

        fleet.handleBackground()
        clock.advance(4)
        fleet.handleForeground()

        // Give any (wrongly) scheduled work a chance to run before asserting it didn't.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let after = await http.requestCount()
        XCTAssertEqual(after, afterLoad, "a 4s background spell must not refetch")

        fleet.stop()
    }

    // Past the debounce, the resume refetches. This is the case MYR-201 left
    // uncovered: nothing had FAILED, so the old `handleForeground` did nothing at
    // all and the sheet kept rendering whatever survived suspension.
    func testForegroundAfterALongBackgroundSpellRefetchesTheFleetList() async {
        let clock = TestClock()
        let (fleet, http) = makeSequencedFleet([.init(body: twoCarList())], clock: clock)
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }
        let afterLoad = await http.requestCount()

        fleet.handleBackground()
        clock.advance(45 * 60)
        fleet.handleForeground()

        await eventuallyAsync { await http.requestCount() > afterLoad }
        let paths = await http.paths()
        XCTAssertTrue(paths.contains("/api/vehicles"), "the resume refetches the fleet list; got \(paths)")

        fleet.stop()
    }

    // The refetch must ADOPT the new row values without rebuilding the live objects
    // beneath them. Rebuilding drops every accumulated `LiveVehicleState`, so the
    // selected vehicle's state goes nil, `isConnecting` flips true, and Home
    // replaces the map+sheet with "Connecting to your vehicles…" — on every resume.
    func testForegroundRefetchAdoptsNewRowsWithoutTearingDownLiveSources() async {
        let clock = TestClock()
        let (fleet, _) = makeSequencedFleet(
            [
                .init(body: twoCarList()),
                // While the owner was away the car started charging and they set a
                // plate from another device — both live on the LIST row.
                .init(body: twoCarList(status: .charging, plate: "RBO 2046")),
            ],
            clock: clock
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }
        let sourceBefore = fleet.telemetry(at: 0)
        let executorBefore = fleet.commandExecutor(at: 0)
        let feedBefore = fleet.drivesFeed(at: 0)

        fleet.handleBackground()
        clock.advance(30 * 60)
        fleet.handleForeground()

        // The newer row values land...
        await eventually { fleet.vehicles[0].plate == "RBO 2046" }
        XCTAssertEqual(fleet.badgeStatus(at: 0), .charging)
        // ...on the SAME live objects, which still hold their subscription,
        // reconcile hooks and drive-feed pagination.
        XCTAssertTrue(fleet.telemetry(at: 0) === sourceBefore, "the live source was rebuilt")
        XCTAssertTrue(fleet.commandExecutor(at: 0) === executorBefore, "the executor was rebuilt")
        XCTAssertTrue(fleet.drivesFeed(at: 0) === feedBefore, "the drives feed was rebuilt")

        fleet.stop()
    }

    // A fleet whose COMPOSITION changed (a car added/removed while away) must take
    // the full rebuild — the parallel source/executor/feed arrays are index-keyed,
    // so adopting rows in place would misalign every one of them.
    func testForegroundRefetchRebuildsWhenTheFleetCompositionChanged() async {
        let clock = TestClock()
        let (fleet, _) = makeSequencedFleet(
            [
                .init(body: twoCarList()),
                .init(body: Contracts.listResponse([
                    Contracts.summary(vehicleId: "v2", name: "Daily", status: .parked, chargeLevel: 82),
                ])),
            ],
            clock: clock
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        fleet.handleBackground()
        clock.advance(30 * 60)
        fleet.handleForeground()

        await eventually { fleet.vehicles.count == 1 }
        XCTAssertEqual(fleet.vehicles.map(\.id), ["v2"])
        XCTAssertEqual(fleet.badgeStatus(at: 0), .parked, "the parallel arrays stayed aligned")

        fleet.stop()
    }

    // §7.15 — the manual refresh posts to the refresh endpoint for the SELECTED
    // vehicle and reports what the server did. `refreshed` is the woke-and-read
    // outcome.
    func testRefreshVehiclePostsTheRefreshEndpointAndReportsTheWake() async throws {
        let clock = TestClock()
        let refreshBody = Data(#"{"status":"refreshed","lastUpdated":"2026-07-27T16:09:48Z"}"#.utf8)
        let (fleet, http) = makeSequencedFleet(
            [.init(body: twoCarList()), .init(body: refreshBody)],
            clock: clock
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        let outcome = try await fleet.refreshVehicle(at: 0)

        XCTAssertEqual(outcome, .refreshed)
        let requests = await http.capturedRequests()
        let refresh = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/refresh") == true })
        XCTAssertEqual(refresh.httpMethod, "POST")
        XCTAssertEqual(refresh.url?.path, "/api/tesla/vehicles/v1/refresh")

        fleet.stop()
    }

    // `fresh` is a SUCCESS — the server deliberately declined to wake a car that
    // streamed recently. It must never surface as a failure.
    func testRefreshVehicleReportsAServerSideNoOpAsSuccess() async throws {
        let clock = TestClock()
        let refreshBody = Data(#"{"status":"fresh","lastUpdated":"2026-07-27T16:04:12Z"}"#.utf8)
        let (fleet, _) = makeSequencedFleet(
            [.init(body: twoCarList()), .init(body: refreshBody)],
            clock: clock
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        let outcome = try await fleet.refreshVehicle(at: 0)
        XCTAssertEqual(outcome, .fresh)

        fleet.stop()
    }

    // The typed 503 must reach the caller intact so the stamp can show the honest
    // asleep copy rather than a generic failure.
    func testRefreshVehicleSurfacesTheTypedAsleepFailure() async {
        let clock = TestClock()
        let error = Data(#"{"error":{"code":"vehicle_asleep","message":"did not wake"}}"#.utf8)
        let (fleet, _) = makeSequencedFleet(
            [.init(body: twoCarList()), .init(status: 503, body: error)],
            clock: clock
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        do {
            _ = try await fleet.refreshVehicle(at: 0)
            XCTFail("expected the 503 to surface")
        } catch let restError as RestError {
            XCTAssertEqual(restError.commandFailureKind, .vehicleAsleep)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }

        fleet.stop()
    }

    // MARK: - Polling helper (no fixed sleeps)

    private func eventually(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    /// The same poll for a condition that must `await` (an actor-isolated
    /// request count, say). Kept separate so the existing sync call sites are
    /// untouched.
    private func eventuallyAsync(
        timeout: TimeInterval = 3.0,
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

// MARK: - Composition point (env → backend environment / fleet selection)

final class TelemetryCompositionTests: XCTestCase {

    func testDefaultBackendIsProductionTelemetryHost() {
        // Default is the Fly-managed API listener on :4443 (PR #24) — :443 serves
        // Tesla vehicle mTLS and rejects plain API clients (split-TLS host).
        let env = AppMode.backendEnvironment(from: nil)
        XCTAssertEqual(env?.restBaseURL.absoluteString, "https://telemetry.myrobotaxi.app:4443/api")
        XCTAssertEqual(env?.webSocketURL.absoluteString, "wss://telemetry.myrobotaxi.app:4443/api/ws")
        XCTAssertEqual(env?.allowsInsecureLoopback, false)
    }

    func testCustomHTTPSBackendMountsRestAndWebSocketPaths() {
        let env = AppMode.backendEnvironment(from: "https://staging.telemetry.example")
        XCTAssertEqual(env?.restBaseURL.absoluteString, "https://staging.telemetry.example/api")
        XCTAssertEqual(env?.webSocketURL.absoluteString, "wss://staging.telemetry.example/api/ws")
    }

    func testLoopbackBackendAllowsInsecureAndDowngradesScheme() {
        let env = AppMode.backendEnvironment(from: "http://localhost:8080")
        XCTAssertEqual(env?.restBaseURL.absoluteString, "http://localhost:8080/api")
        XCTAssertEqual(env?.webSocketURL.absoluteString, "ws://localhost:8080/api/ws")
        XCTAssertEqual(env?.allowsInsecureLoopback, true)
    }
}
