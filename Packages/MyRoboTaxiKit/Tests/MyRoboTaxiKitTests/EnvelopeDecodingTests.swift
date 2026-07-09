import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Round-trips every wire shape the Kit consumes through the REAL generated
/// `MyRobotaxiContracts` types, using the canonical fixtures copied from the
/// telemetry repo — including a forward-compat unrecognized-enum fixture.
final class EnvelopeDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: WebSocket envelopes

    func testAuthOkEnvelopeAndPayload() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/auth_ok.json"))
        XCTAssertEqual(envelope.type, .authOk)
        let payload = try WireCodec.decodePayload(AuthOkPayload.self, from: envelope)
        XCTAssertEqual(payload.userId, "clxyz1234567890userid")
        XCTAssertEqual(payload.vehicleCount, 1)
    }

    func testVehicleUpdateChargeGroupDecodes() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/vehicle_update.charge.json"))
        XCTAssertEqual(envelope.type, .vehicleUpdate)
        let payload = try WireCodec.decodePayload(VehicleUpdatePayload.self, from: envelope)
        XCTAssertEqual(payload.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(payload.fields["chargeLevel"]?.numberValue, 78)
        XCTAssertEqual(payload.fields["chargeState"]?.stringValue, "Disconnected")
        // A JSON null must survive as `.null` (distinct from an absent key) so the
        // atomic-clear semantics work.
        XCTAssertEqual(payload.fields["timeToFull"], .null)
    }

    func testHeartbeatHasNoPayload() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/heartbeat.json"))
        XCTAssertEqual(envelope.type, .heartbeat)
        XCTAssertNil(envelope.payload)
    }

    func testDriveEndedSummaryDecodes() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/drive_ended.json"))
        let payload = try WireCodec.decodePayload(DriveEndedPayload.self, from: envelope)
        XCTAssertEqual(payload.driveId, "clmno9876543210zyxw0001")
        XCTAssertEqual(payload.durationSeconds, 1458, accuracy: 0.001)
        XCTAssertEqual(payload.maxSpeed, 65.2, accuracy: 0.001)
    }

    func testErrorFrameCarriesTypedCode() throws {
        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/error.auth_failed.json"))
        let payload = try WireCodec.decodePayload(ErrorPayload.self, from: envelope)
        XCTAssertEqual(payload.code, .authFailed) // branch on the enum, never the message
    }

    // MARK: REST bodies

    func testSnapshotDecodesIntoVehicleState() throws {
        let state = try decoder.decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
        XCTAssertEqual(state.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(state.chargeLevel, 78)
        XCTAssertEqual(state.gearPosition, .p)
        XCTAssertNil(state.chargeState)          // nullable, steady-state null
        XCTAssertNil(state.destinationName)      // no active navigation
    }

    func testVehiclesListDecodes() throws {
        let response = try decoder.decode(VehicleListResponse.self, from: try Fixture.data("rest/vehicles_list.json"))
        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].role, .owner)
        XCTAssertEqual(response.items[0].status, .parked)
        XCTAssertEqual(response.items[1].status, .charging)
    }

    // MARK: Forward-compat — unrecognized enum arms

    /// A message `type` this build has never heard of must decode to
    /// `.unrecognized` and re-encode byte-identically (MYR-195).
    func testUnrecognizedMessageTypeRoundTrips() throws {
        let json = #"{"type":"quantum_teleport","payload":{"vehicleId":"v1"}}"#
        let envelope = try WireCodec.decodeEnvelope(json)
        XCTAssertEqual(envelope.type, .unrecognized("quantum_teleport"))

        let reencoded = String(decoding: try encoder.encode(envelope), as: UTF8.self)
        let again = try WireCodec.decodeEnvelope(reencoded)
        XCTAssertEqual(again.type, .unrecognized("quantum_teleport"))

        // A switch MUST handle the unrecognized arm (neutral fallback).
        let label: String
        switch envelope.type {
        case .unrecognized(let raw): label = raw
        default: label = "known"
        }
        XCTAssertEqual(label, "quantum_teleport")
    }

    /// An unrecognized `VehicleState.status` / `chargeState` value survives a
    /// decode → encode → decode round-trip with its raw string intact.
    func testUnrecognizedVehicleStateEnumsRoundTrip() throws {
        let base = try Fixture.text("rest/snapshot.json")
        let mutated = base
            .replacingOccurrences(of: "\"status\": \"parked\"", with: "\"status\": \"teleporting\"")
            .replacingOccurrences(of: "\"chargeState\": null", with: "\"chargeState\": \"Photonic\"")

        let state = try decoder.decode(VehicleState.self, from: Data(mutated.utf8))
        XCTAssertEqual(state.status, .unrecognized("teleporting"))
        XCTAssertEqual(state.chargeState, .unrecognized("Photonic"))

        let round = try decoder.decode(VehicleState.self, from: try encoder.encode(state))
        XCTAssertEqual(round.status, .unrecognized("teleporting"))
        XCTAssertEqual(round.chargeState, .unrecognized("Photonic"))
    }
}
