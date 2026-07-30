import DesignSystem
import Observation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-345 (client defect) — "the refresh icon doesn't work"
//
// Jul 29 TestFlight, screenshot AKXUQLSW…: an owner on an IN-SERVICE car taps the
// freshness stamp and nothing happens. The car had been read moments earlier, so
// the stamp read "Synced just now".
//
// Nothing was broken about the tap, the target, or the network. The bug was that
// the branch the tap lands in for a car that is ALREADY CURRENT —
// `VehicleFreshnessStamp.wakes == false` ⇒ `VehicleRefreshPhase.acknowledged` —
// carried NO copy: `phase.text` was `nil`, so the stamp re-rendered the identical
// line it was already showing, with no spin (the spin is gated on `.waking`) and
// no notice. MYR-315's own reasoning for that was "the resting recency stamp
// shows through, which IS the acknowledgement" — true of the state, but invisible
// as an EVENT, and an owner cannot tell an acknowledgement apart from a dead
// button when both render the same pixels.
//
// The second half is the settle. §7.15 can be refused, and on an in-service car
// it is refused by NAME: `502 command_failed` carrying MYR-329's
// `vehicle_in_service` token. That folded through `commandFailureKind` alone,
// which flattens every 502 to `.other` ⇒ "Couldn't reach the car" — the exact
// wrong-guess problem MYR-329 fixed on the command path, reproduced on the
// refresh path. A refusal the server explained must be explained to the owner.
//
// These tests drive `OwnerHomeState.refreshSelectedVehicle` — the real method the
// stamp's action calls — against a stub fleet, and assert on what the stamp would
// RENDER (`phase.text`), never on internal state alone.
@MainActor
final class OwnerFreshnessRefreshTests: XCTestCase {

    // MARK: Stub fleet

    /// A minimal live-shaped fleet: one vehicle whose snapshot travels the
    /// PRODUCTION `VehicleContractMapping` (so `isStreaming`/`lastUpdated` are the
    /// real fold of a real wire status), and a §7.15 refresh that answers with
    /// whatever the test seeded.
    @Observable
    @MainActor
    fileprivate final class StubFleet: VehicleFleet {
        let vehicles: [Vehicle]
        private let source: StubSource
        private let executor = SimulatedVehicleCommandExecutor(driving: false, plate: "")
        private let feed = SimulatedDrivesFeed()
        private let answer: Result<VehicleRefreshOutcome, RestError>

        /// Set when `refreshVehicle` is actually called — the difference between
        /// "the tap acknowledged" and "the tap spent a call".
        private(set) var refreshCalls = 0

        var isConnecting: Bool { false }
        var statusMessage: String? { nil }

        init(
            status: VehicleState.Status,
            lastReadAt: Date,
            answer: Result<VehicleRefreshOutcome, RestError> = .success(.refreshed)
        ) {
            self.answer = answer
            let state = Self.state(status: status, lastReadAt: lastReadAt)
            let summary = VehicleSummary(
                vehicleId: "stub-veh",
                name: "Lunar",
                model: "Model Y",
                year: 2026,
                color: "",
                vinLast4: "3456",
                status: status == .inService ? .inService : .parked,
                chargeLevel: 64,
                estimatedRange: 174,
                lastUpdated: state.lastUpdated,
                role: .owner,
                licensePlate: nil
            )
            vehicles = [VehicleContractMapping.vehicle(summary: summary, state: state)]
            source = StubSource(snapshot: VehicleContractMapping.snapshot(from: state))
        }

        func telemetry(at index: Int) -> any VehicleTelemetrySource { source }
        func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executor }
        func drivesFeed(at index: Int) -> any DrivesFeed { feed }
        func badgeStatus(at index: Int) -> MRTVehicleStatus { .parked }
        func start() {}
        func stop() {}
        func setActive(index: Int) {}
        func handleForeground() {}
        func handleBackground() {}

        func refreshVehicle(at index: Int) async throws -> VehicleRefreshOutcome {
            refreshCalls += 1
            switch answer {
            case .success(let outcome): return outcome
            case .failure(let error): throw error
            }
        }

        private static func state(status: VehicleState.Status, lastReadAt: Date) -> VehicleState {
            VehicleState(
                vehicleId: "stub-veh",
                name: "Lunar",
                model: "Model Y",
                year: 2026,
                color: "",
                vin: "7SAYGDEE9RA123456",
                softwareVersion: "2026.14.3",
                trim: "Performance",
                status: status,
                speed: 0,
                heading: 0,
                latitude: 37.7955,
                longitude: -122.3937,
                locationName: "Embarcadero Center \u{00B7} Lot B",
                locationAddress: "1 Embarcadero Ctr, San Francisco",
                gearPosition: .p,
                chargeLevel: 64,
                estimatedRange: 174,
                interiorTemp: 58,
                exteriorTemp: 55,
                odometerMiles: 18432,
                fsdMilesSinceReset: 11274,
                lastUpdated: ISO8601DateFormatter().string(from: lastReadAt)
            )
        }
    }

    @Observable
    @MainActor
    fileprivate final class StubSource: VehicleTelemetrySource {
        private(set) var snapshot: VehicleTelemetrySnapshot
        init(snapshot: VehicleTelemetrySnapshot) { self.snapshot = snapshot }
        func start() {}
        func stop() {}
    }

    /// Wait for the stamp to leave `.waking` (the refresh task is detached).
    private func settle(_ state: OwnerHomeState, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .waking = state.refreshPhase {
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            return
        }
    }

    // MARK: THE CLIENT'S TAP

    /// THE DEFECT. His car was in service and had been read moments before, so the
    /// tap is a legitimate no-op — the server would answer `fresh` (or `429` inside
    /// its own cooldown) and the app rightly does not spend a wake to be told so.
    ///
    /// But a no-op the owner cannot SEE is indistinguishable from a broken button.
    /// The acknowledgement must put words on the stamp.
    func testTapOnAnAlreadyCurrentCarSaysSomething() async {
        let fleet = StubFleet(status: .inService, lastReadAt: Date())
        let state = OwnerHomeState(fleet: fleet)

        state.refreshSelectedVehicle()

        XCTAssertEqual(state.refreshPhase, .acknowledged)
        XCTAssertEqual(fleet.refreshCalls, 0, "an already-current car must not spend a wake")
        XCTAssertNotNil(
            state.refreshPhase.text,
            "the acknowledgement must render copy \u{2014} a tap that changes no pixel IS the client's bug"
        )
    }

    /// The acknowledgement is transient: it says the ask was answered and then
    /// hands the line back to the recency stamp, which is the durable claim.
    func testTheAcknowledgementClearsItselfBackToTheStamp() async {
        let state = OwnerHomeState(fleet: StubFleet(status: .inService, lastReadAt: Date()))
        state.refreshSelectedVehicle()
        XCTAssertEqual(state.refreshPhase, .acknowledged)

        try? await Task.sleep(for: .seconds(OwnerHomeState.acknowledgementDisplayDuration + 0.4))
        XCTAssertEqual(state.refreshPhase, .idle)
    }

    // MARK: The wake, and an honest settle

    /// A genuinely stale car spends the call and announces it, so the seconds a
    /// wake takes are not silence.
    func testTapOnAStaleCarShowsTheWakeAndSettlesBack() async {
        let fleet = StubFleet(status: .inService, lastReadAt: Date().addingTimeInterval(-7 * 3600))
        let state = OwnerHomeState(fleet: fleet)

        state.refreshSelectedVehicle()
        XCTAssertEqual(state.refreshPhase, .waking("Lunar"))
        XCTAssertNotNil(state.refreshPhase.text)

        await settle(state)
        XCTAssertEqual(fleet.refreshCalls, 1)
        XCTAssertEqual(state.refreshPhase, .idle)
    }

    /// THE SECOND HALF OF THE DEFECT. The server refuses the refresh and NAMES the
    /// reason with MYR-329's token. Folding on `commandFailureKind` alone flattens
    /// that to "Couldn't reach the car" — a sentence that is not even true (we
    /// reached it; it said no) and that sent a client guessing at his battery once
    /// already.
    func testAnInServiceRefusalIsNamedRatherThanGeneric() async {
        let fleet = StubFleet(
            status: .inService,
            lastReadAt: Date().addingTimeInterval(-7 * 3600),
            answer: .failure(.http(
                status: 502,
                code: ErrorPayload.Code(rawValue: "command_failed"),
                message: "vehicle command failed: vehicle_in_service",
                subCode: nil
            ))
        )
        let state = OwnerHomeState(fleet: fleet)

        state.refreshSelectedVehicle()
        await settle(state)

        XCTAssertEqual(state.refreshPhase, .notice(.rejected(.vehicleInService)))
        XCTAssertEqual(
            state.refreshPhase.text,
            "Car is in service \u{2014} commands are limited",
            "the refresh path must reuse MYR-329's named copy, not restate the generic failure"
        )
    }

    /// A 502 the server did NOT explain keeps the generic line — "we don't know
    /// why" and "we know it was X" are different, and only the second is safe to
    /// state (MYR-329's own rule).
    func testAnUnexplainedRejectionKeepsTheGenericLine() async {
        let fleet = StubFleet(
            status: .inService,
            lastReadAt: Date().addingTimeInterval(-7 * 3600),
            answer: .failure(.http(
                status: 502,
                code: ErrorPayload.Code(rawValue: "command_failed"),
                message: "car could not execute command",
                subCode: nil
            ))
        )
        let state = OwnerHomeState(fleet: fleet)

        state.refreshSelectedVehicle()
        await settle(state)

        XCTAssertEqual(state.refreshPhase, .notice(.rejected(nil)))
        XCTAssertEqual(state.refreshPhase.text, "The car didn\u{2019}t accept that")
    }

    /// The asleep and cooldown folds are unchanged by the rejection arm — MYR-315's
    /// copy still owns those two situations.
    func testAsleepAndCooldownFoldsAreUnchanged() async {
        for (error, expected) in [
            (RestError.http(status: 503, code: ErrorPayload.Code(rawValue: "vehicle_asleep"), message: nil, subCode: nil),
             VehicleRefreshNotice.asleep),
            (RestError.http(status: 429, code: ErrorPayload.Code(rawValue: "rate_limited"), message: nil, subCode: nil),
             VehicleRefreshNotice.cooldown)
        ] {
            let state = OwnerHomeState(fleet: StubFleet(
                status: .inService,
                lastReadAt: Date().addingTimeInterval(-7 * 3600),
                answer: .failure(error)
            ))
            state.refreshSelectedVehicle()
            await settle(state)
            XCTAssertEqual(state.refreshPhase, .notice(expected))
        }
    }
}
