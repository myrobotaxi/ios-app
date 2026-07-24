import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-249 — §7.9 vehicle-command endpoint (no network)
//
// Table-driven: every catalog command maps to the right `{name}` path segment
// and JSON body, the 200 result decodes, and each §7.9 error code folds to the
// right `CommandFailureKind`.
final class VehicleCommandEndpointTests: XCTestCase {
    private let env = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func appliedBody(_ command: String) -> Data {
        Data(#"{"status":"applied","command":"\#(command)","vin":"***0001"}"#.utf8)
    }

    // MARK: command → path + body

    func testCommandNameToPathAndBody() async throws {
        struct Case {
            let command: VehicleCommand
            let name: String
            let expectedBody: [String: Any]?  // nil = no body (parameterless)
            let line: UInt
            init(_ command: VehicleCommand, _ name: String, _ expectedBody: [String: Any]?, line: UInt = #line) {
                self.command = command; self.name = name; self.expectedBody = expectedBody; self.line = line
            }
        }
        let cases: [Case] = [
            Case(.doorLock, "door_lock", nil),
            Case(.doorUnlock, "door_unlock", nil),
            Case(.autoConditioningStart, "auto_conditioning_start", nil),
            Case(.autoConditioningStop, "auto_conditioning_stop", nil),
            Case(.setTemps(driverTempC: 21.0, passengerTempC: nil), "set_temps", ["driver_temp": 21.0]),
            Case(.setTemps(driverTempC: 20.5, passengerTempC: 22.0), "set_temps", ["driver_temp": 20.5, "passenger_temp": 22.0]),
            Case(.chargeStart, "charge_start", nil),
            Case(.chargeStop, "charge_stop", nil),
            Case(.setChargeLimit(percent: 80), "set_charge_limit", ["percent": 80]),
            Case(.actuateTrunk(.rear), "actuate_trunk", ["which_trunk": "rear"]),
            Case(.actuateTrunk(.front), "actuate_trunk", ["which_trunk": "front"]),
            Case(.remoteStartDrive, "remote_start_drive", nil),
            Case(.honkHorn, "honk_horn", nil),
            Case(.flashLights, "flash_lights", nil),
        ]

        for c in cases {
            let http = RecordingHTTP([.init(status: 200, body: appliedBody(c.name))])
            let client = RestClient(environment: env, tokenProvider: StaticTokenProvider("t"), http: http)

            let result = try await client.sendCommand(c.command, vehicleID: "veh-1")
            XCTAssertEqual(result.status, "applied", line: c.line)

            let requests = await http.capturedRequests()
            XCTAssertEqual(requests.count, 1, line: c.line)
            let request = requests[0]
            XCTAssertEqual(request.httpMethod, "POST", line: c.line)
            XCTAssertEqual(request.url?.path, "/api/vehicles/veh-1/command/\(c.name)", line: c.line)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t", line: c.line)

            if let expected = c.expectedBody {
                guard let body = request.httpBody,
                      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return XCTFail("expected a JSON body for \(c.name)", line: c.line)
                }
                XCTAssertEqual(json.count, expected.count, "unexpected keys for \(c.name): \(json)", line: c.line)
                for (key, value) in expected {
                    if let d = value as? Double {
                        XCTAssertEqual((json[key] as? NSNumber)?.doubleValue ?? .nan, d, accuracy: 0.001, "\(key) for \(c.name)", line: c.line)
                    } else if let i = value as? Int {
                        XCTAssertEqual((json[key] as? NSNumber)?.intValue, i, "\(key) for \(c.name)", line: c.line)
                    } else if let s = value as? String {
                        XCTAssertEqual(json[key] as? String, s, "\(key) for \(c.name)", line: c.line)
                    }
                }
            } else {
                XCTAssertNil(request.httpBody, "\(c.name) is parameterless — no body", line: c.line)
            }
        }
    }

    // MARK: error code → CommandFailureKind

    func testErrorCodeToFailureKind() {
        struct Case {
            let status: Int
            let code: String?
            let expected: RestError.CommandFailureKind
            let line: UInt
            init(_ status: Int, _ code: String?, _ expected: RestError.CommandFailureKind, line: UInt = #line) {
                self.status = status; self.code = code; self.expected = expected; self.line = line
            }
        }
        let cases: [Case] = [
            Case(503, "vehicle_asleep", .vehicleAsleep),
            Case(403, "key_not_paired", .keyNotPaired),
            Case(403, "permission_denied", .permissionDenied),
            Case(403, "vehicle_not_owned", .notOwned),
            Case(429, "rate_limited", .rateLimited),
            Case(400, "invalid_request", .invalidRequest),
            Case(502, "command_failed", .commandFailed),
            Case(404, "not_found", .notFound),
            Case(401, "auth_failed", .auth),
            // No typed code in the body → fall back on the HTTP status.
            Case(503, nil, .vehicleAsleep),
            Case(429, nil, .rateLimited),
            Case(502, nil, .commandFailed),
            Case(418, nil, .other),
        ]
        for c in cases {
            let code = c.code.map { ErrorPayload.Code(rawValue: $0) }
            let error = RestError.http(status: c.status, code: code, message: "x", subCode: nil)
            XCTAssertEqual(error.commandFailureKind, c.expected, "status \(c.status) code \(c.code ?? "nil")", line: c.line)
        }

        XCTAssertEqual(RestError.transport(underlying: URLError(.notConnectedToInternet)).commandFailureKind, .transport)
        XCTAssertEqual(RestError.invalidResponse.commandFailureKind, .other)
    }

    // MARK: result decode + failing send

    func testSendPropagatesTypedError() async {
        let http = RecordingHTTP([.init(status: 403, body: Data(#"{"error":{"code":"key_not_paired","message":"pair"}}"#.utf8))])
        let client = RestClient(environment: env, tokenProvider: StaticTokenProvider("t"), http: http)
        do {
            _ = try await client.sendCommand(.doorLock, vehicleID: "veh-1")
            XCTFail("expected throw")
        } catch let error as RestError {
            XCTAssertEqual(error.commandFailureKind, .keyNotPaired)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
