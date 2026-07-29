import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-329 — the rejection notice names the reason
//
// TestFlight (Thomas, Jul 28): "Any reason why car didn't accept climate, is it
// because low battery?" The car was in service mode; the battery was fine. The
// `.rejected` notice said only "The car didn't accept that", so the guess the
// owner made was the only one available to him.
//
// The server now names the cause it recognizes (rest-api.md §7.9). These tests
// cover the three things that had to be true for that to help:
//   1. a named reason becomes owner-friendly copy,
//   2. an UNnamed reason is byte-identical to the pre-MYR-329 behavior, and
//   3. nothing else moved — `.asleep` in particular.

@MainActor
final class VehicleCommandRejectionNoticeTests: XCTestCase {

    private static func rejection(_ message: String?) -> RestError {
        .http(status: 502, code: ErrorPayload.Code(rawValue: "command_failed"), message: message, subCode: nil)
    }

    // MARK: 1 — reason → copy

    /// Every reason in the catalog maps to its own distinct, owner-friendly
    /// line. The table is the contract: adding a token server-side without copy
    /// here would silently show an owner a blank-feeling generic notice.
    func testEveryReasonHasItsOwnOwnerFacingLine() {
        struct Case {
            let reason: VehicleCommandRejectionReason
            let message: String
            let line: UInt
            init(_ reason: VehicleCommandRejectionReason, _ message: String, line: UInt = #line) {
                self.reason = reason
                self.message = message
                self.line = line
            }
        }
        let cases: [Case] = [
            // The client's own case, and the reason this issue exists.
            Case(.vehicleInService, "Car is in service \u{2014} commands are limited"),
            Case(.requiresUserAcknowledgement, "Confirm this on the car\u{2019}s screen"),
            Case(.userNotPresent, "Someone needs to be in the car for that"),
            Case(.remoteAccessDisabled, "Remote access is off in the car\u{2019}s settings"),
            Case(.lowBattery, "Battery is too low for that"),
            Case(.vehicleBusy, "Car is busy \u{2014} try again in a moment"),
        ]
        XCTAssertEqual(
            cases.count, VehicleCommandRejectionReason.allCases.count,
            "a reason was added to the Kit without owner-facing copy here"
        )
        for c in cases {
            XCTAssertEqual(
                VehicleCommandNotice.rejected(c.reason).message, c.message,
                "copy for \(c.reason.rawValue)", line: c.line
            )
        }

        // Distinct copy, or naming the reason bought the owner nothing.
        let messages = VehicleCommandRejectionReason.allCases.map { VehicleCommandNotice.rejected($0).message }
        XCTAssertEqual(Set(messages).count, messages.count, "two reasons share a line")
        for message in messages {
            XCTAssertNotEqual(message, VehicleCommandNotice.rejected(nil).message)
        }
    }

    /// The unnamed rejection must read EXACTLY as it did before MYR-329 — that
    /// is the case every owner on an older server still gets.
    func testAnUnnamedRejectionIsUnchanged() {
        XCTAssertEqual(VehicleCommandNotice.rejected(nil).message, "The car didn\u{2019}t accept that")
        XCTAssertEqual(VehicleCommandNotice.rejected(nil).tileText, "Declined")
        XCTAssertNil(VehicleCommandNotice.rejected(nil).action)
        XCTAssertFalse(VehicleCommandNotice.rejected(nil).isTransient)
    }

    /// The tile has room for one short token only, so the reason lives on the
    /// full-width notice row and every rejection keeps the same tile vocabulary
    /// and the same (absent) route.
    func testReasonChangesOnlyTheFullWidthLine() {
        for reason in VehicleCommandRejectionReason.allCases {
            let notice = VehicleCommandNotice.rejected(reason)
            XCTAssertEqual(notice.tileText, "Declined", "\(reason.rawValue) must keep the tile token")
            XCTAssertNil(notice.action, "\(reason.rawValue) has no in-app fix to route to")
            XCTAssertFalse(notice.isTransient, "\(reason.rawValue) is a settled outcome")
        }
    }

    // MARK: 2 — the wire → notice fold

    /// The whole path in one assertion: the server sentence the client's own
    /// 502 would carry becomes the line he needed to read.
    func testTheClientsOwnRejectionNamesServiceMode() {
        let error = Self.rejection("vehicle command failed: vehicle_in_service")
        let notice = LiveVehicleCommandExecutor.notice(
            for: error.commandFailureKind, key: .climate, reason: error.commandRejectionReason
        )
        XCTAssertEqual(notice, .rejected(.vehicleInService))
        XCTAssertEqual(notice.message, "Car is in service \u{2014} commands are limited")
    }

    /// A generic 502, and a 502 naming a token this build predates, both fall
    /// back to the unchanged copy rather than guessing.
    func testUnknownAndAbsentReasonsFallBackToGeneric() {
        for message in ["vehicle command failed", "vehicle command failed: some_future_reason", nil] {
            let error = Self.rejection(message)
            let notice = LiveVehicleCommandExecutor.notice(
                for: error.commandFailureKind, key: .climate, reason: error.commandRejectionReason
            )
            XCTAssertEqual(notice, .rejected(nil), "message \(String(describing: message))")
            XCTAssertEqual(notice.message, "The car didn\u{2019}t accept that")
        }
    }

    /// MYR-301's asleep/rejected split must survive. An asleep car is NOT a
    /// rejection, and no reason token in a 503 body may turn it into one.
    func testAsleepIsNotRegressed() {
        let asleep = RestError.http(
            status: 503, code: ErrorPayload.Code(rawValue: "vehicle_asleep"),
            message: "vehicle command failed: vehicle_in_service", subCode: nil
        )
        let notice = LiveVehicleCommandExecutor.notice(
            for: asleep.commandFailureKind, key: .climate, reason: asleep.commandRejectionReason
        )
        XCTAssertEqual(notice, .asleep)
        XCTAssertEqual(notice.message, "Car is asleep \u{2014} try again shortly")
    }

    /// The plate path (§7.14) never contacts the car, so it must not grow car
    /// vocabulary just because a reason token appeared in a body.
    func testThePlatePathIgnoresRejectionReasons() {
        let error = Self.rejection("vehicle command failed: vehicle_in_service")
        let notice = LiveVehicleCommandExecutor.notice(
            for: error.commandFailureKind, key: .plate, reason: error.commandRejectionReason
        )
        XCTAssertEqual(notice, .plateNotSaved)
    }

    // MARK: 3 — integration: through the real executor's settle path

    /// The client's exact interaction, end to end: he taps climate OFF, the
    /// server answers 502 naming service mode, and the REAL executor settles the
    /// REAL notice. Nothing here reaches past `sendCommand`.
    func testExecutorSettlesTheNamedReasonOnTheRealNoticePath() async {
        let sender = ScriptedCommandSender([
            .failure(Self.rejection("vehicle command failed: vehicle_in_service")),
        ])
        let exec = LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: sender,
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 0,
            // MYR-301's window, lengthened so this test asserts the settled
            // state rather than racing the auto-clear. The lifecycle itself is
            // covered by LiveVehicleCommandExecutorTests and is untouched here.
            noticeDisplayDuration: .seconds(600)
        )

        try? await exec.setClimateOn(false)

        let state = exec.uiState(for: .climate)
        XCTAssertFalse(state.isPending, "a settled rejection is not pending")
        XCTAssertEqual(state.notice, .rejected(.vehicleInService))
        XCTAssertEqual(state.notice?.message, "Car is in service \u{2014} commands are limited")
        XCTAssertEqual(sender.calls.map(\.name), ["auto_conditioning_stop"])
    }

    /// The same path with a server that names nothing must land on the exact
    /// pre-MYR-329 state, so an older backend is a no-op for this app.
    func testExecutorSettlesGenericWhenTheServerNamesNothing() async {
        let sender = ScriptedCommandSender([.failure(Self.rejection("vehicle command failed"))])
        let exec = LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: sender,
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 0,
            noticeDisplayDuration: .seconds(600)
        )

        try? await exec.setClimateOn(false)

        XCTAssertEqual(exec.uiState(for: .climate).notice, .rejected(nil))
        XCTAssertEqual(exec.uiState(for: .climate).notice?.message, "The car didn\u{2019}t accept that")
    }

    /// The bounded display MYR-301 established still owns a named notice: the
    /// reason changes the words, never the lifecycle.
    func testANamedNoticeStillClearsItselfAfterItsBoundedDisplay() async throws {
        let sender = ScriptedCommandSender([
            .failure(Self.rejection("vehicle command failed: vehicle_in_service")),
        ])
        let exec = LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: sender,
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 0,
            noticeDisplayDuration: .milliseconds(60)
        )

        try? await exec.setClimateOn(false)
        XCTAssertEqual(exec.uiState(for: .climate).notice, .rejected(.vehicleInService))

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(
            exec.uiState(for: .climate).notice,
            "a named rejection must expire on the same MYR-301 schedule as an unnamed one"
        )
    }
}
