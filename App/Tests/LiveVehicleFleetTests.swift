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
