import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-329 — the car's reason, not just "it said no"
//
// A TestFlight owner's climate command was refused because his car was in
// service mode. The 502 carried that fact in `error.message` all along once the
// server started naming it; the Kit parsed the message into `RestError.http`
// and then dropped it at `commandFailureKind`, which is payload-free. These
// tests cover the recovery path — and, just as importantly, every case where we
// must NOT claim to know why.

@MainActor
final class VehicleCommandRejectionTests: XCTestCase {

    private func commandFailed(_ message: String?) -> RestError {
        .http(status: 502, code: ErrorPayload.Code(rawValue: "command_failed"), message: message, subCode: nil)
    }

    // MARK: Parsing the token out of the server sentence

    func testServerMessageYieldsTheReason() {
        struct Case {
            let message: String
            let want: VehicleCommandRejectionReason?
            let line: UInt
            init(_ message: String, _ want: VehicleCommandRejectionReason?, line: UInt = #line) {
                self.message = message
                self.want = want
                self.line = line
            }
        }
        let cases: [Case] = [
            // The documented layout, exactly as the server emits it.
            Case("vehicle command failed: vehicle_in_service", .vehicleInService),
            Case("vehicle command failed: requires_user_acknowledgement", .requiresUserAcknowledgement),
            Case("vehicle command failed: user_not_present", .userNotPresent),
            Case("vehicle command failed: remote_access_disabled", .remoteAccessDisabled),
            Case("vehicle command failed: low_battery", .lowBattery),
            Case("vehicle command failed: vehicle_busy", .vehicleBusy),

            // The scan is deliberately tolerant of the leading sentence, so a
            // server-side reword cannot silently drop every owner to generic.
            Case("VEHICLE COMMAND FAILED: VEHICLE_IN_SERVICE", .vehicleInService),
            Case("the car refused (vehicle_in_service)", .vehicleInService),

            // Nothing named — the generic sentence, today's behavior.
            Case("vehicle command failed", nil),
            Case("", nil),
            // A token this build has never heard of: a NEWER server naming a
            // reason we don't ship copy for. Must read as "we don't know".
            Case("vehicle command failed: cabin_overheat_protection", nil),
            // Prose that talks ABOUT service must not trip the token match.
            Case("the vehicle is in service", nil),
            Case("could not reach the service", nil),
        ]
        for c in cases {
            XCTAssertEqual(
                VehicleCommandRejectionReason(serverMessage: c.message), c.want,
                "message \(c.message.debugDescription)", line: c.line
            )
        }
    }

    // MARK: The token set's own invariants

    /// The scan returns the FIRST matching case, so a token that contained
    /// another would make the result depend on declaration order. Assert the
    /// property instead of relying on today's spelling staying lucky.
    func testNoTokenIsASubstringOfAnother() {
        for a in VehicleCommandRejectionReason.allCases {
            for b in VehicleCommandRejectionReason.allCases where a != b {
                XCTAssertFalse(
                    a.rawValue.contains(b.rawValue),
                    "\(a.rawValue) contains \(b.rawValue) — the scan would be order-dependent"
                )
            }
        }
    }

    /// Tokens must be lowercase snake_case identifiers: that is what makes them
    /// impossible for firmware prose to produce by accident, and it is the shape
    /// the server guarantees (`reject_reason.go`).
    func testTokensAreLowercaseSnakeCase() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_")
        for reason in VehicleCommandRejectionReason.allCases {
            XCTAssertTrue(
                reason.rawValue.unicodeScalars.allSatisfy(allowed.contains),
                "\(reason.rawValue) is not lowercase snake_case"
            )
            XCTAssertTrue(reason.rawValue.contains("_"), "\(reason.rawValue) should be snake_case")
        }
    }

    // MARK: RestError.commandRejectionReason — scoped to a real car rejection

    func testOnlyACommandFailedRejectionCarriesAReason() {
        XCTAssertEqual(
            commandFailed("vehicle command failed: vehicle_in_service").commandRejectionReason,
            .vehicleInService
        )
        // A 502 with no typed code still folds to .commandFailed, so it counts.
        XCTAssertEqual(
            RestError.http(status: 502, code: nil, message: "vehicle command failed: low_battery", subCode: nil)
                .commandRejectionReason,
            .lowBattery
        )
        // Generic 502 — no reason.
        XCTAssertNil(commandFailed("vehicle command failed").commandRejectionReason)
        XCTAssertNil(commandFailed(nil).commandRejectionReason)
    }

    /// The asleep path has its own notice and must NOT be hijacked (MYR-329
    /// explicitly must not regress `.asleep`). Even a 503 whose message somehow
    /// carried a token yields nil, because it is not the car refusing.
    func testNonRejectionFailuresNeverCarryAReason() {
        let others: [RestError] = [
            .http(status: 503, code: ErrorPayload.Code(rawValue: "vehicle_asleep"),
                  message: "vehicle command failed: vehicle_in_service", subCode: nil),
            .http(status: 403, code: ErrorPayload.Code(rawValue: "key_not_paired"),
                  message: "vehicle command failed: vehicle_in_service", subCode: nil),
            .http(status: 403, code: ErrorPayload.Code(rawValue: "permission_denied"),
                  message: "vehicle command failed: low_battery", subCode: nil),
            .http(status: 429, code: ErrorPayload.Code(rawValue: "rate_limited"),
                  message: "vehicle command failed: vehicle_busy", subCode: nil),
            .http(status: 400, code: ErrorPayload.Code(rawValue: "invalid_request"),
                  message: "vehicle command failed: user_not_present", subCode: nil),
            .transport(underlying: URLError(.notConnectedToInternet)),
            .invalidResponse,
        ]
        for error in others {
            XCTAssertNil(
                error.commandRejectionReason,
                "\(error) must not claim a rejection reason"
            )
        }
    }

    /// The reason is ADDITIVE: it never changes how an error folds onto the
    /// existing outcome, so nothing that shipped before MYR-329 moves.
    func testFailureKindIsUnchangedByTheReason() {
        XCTAssertEqual(
            commandFailed("vehicle command failed: vehicle_in_service").commandFailureKind,
            .commandFailed
        )
        XCTAssertEqual(commandFailed("vehicle command failed").commandFailureKind, .commandFailed)
        XCTAssertEqual(commandFailed(nil).commandFailureKind, .commandFailed)
    }
}
