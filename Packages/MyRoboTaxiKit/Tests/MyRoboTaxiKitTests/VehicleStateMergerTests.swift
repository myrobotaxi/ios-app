import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Verifies the field-delta fold onto `VehicleState`, including the atomic
/// nav-clear amplification (NFR-3.9 / Rule CG-SM-3).
final class VehicleStateMergerTests: XCTestCase {
    private func baseState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    func testChargeDeltaMergesAndIsolatesGroup() throws {
        var state = try baseState()
        state.latitude = 37.0
        state.longitude = -122.0

        let fields: [String: JSONValue] = [
            "chargeLevel": .number(55),
            "chargeState": .string("Charging"),
            "estimatedRange": .number(180),
        ]
        let result = VehicleStateMerger.apply(fields: fields, to: state)

        XCTAssertEqual(result.state.chargeLevel, 55)
        XCTAssertEqual(result.state.chargeState, .charging)
        XCTAssertEqual(result.state.estimatedRange, 180)
        XCTAssertEqual(result.changedGroups, [.charge])
        XCTAssertFalse(result.navigationCleared)
        // Other groups untouched.
        XCTAssertEqual(result.state.latitude, 37.0)
        XCTAssertEqual(result.state.longitude, -122.0)
    }

    func testGpsDeltaRoundsHeading() throws {
        let state = try baseState()
        let result = VehicleStateMerger.apply(
            fields: ["latitude": .number(40.1), "longitude": .number(-74.2), "heading": .number(276)],
            to: state
        )
        XCTAssertEqual(result.state.latitude, 40.1)
        XCTAssertEqual(result.state.heading, 276)
        XCTAssertEqual(result.changedGroups, [.gps])
    }

    /// A PARTIAL nav clear (server sends only `destinationName: null`) must null
    /// the ENTIRE navigation group.
    func testPartialNavClearAmplifiesToWholeGroup() throws {
        var state = try baseState()
        state.destinationName = "Airport"
        state.destinationLatitude = 37.6
        state.destinationLongitude = -122.4
        state.etaMinutes = 22
        state.navRouteCoordinates = [[-122.4, 37.6], [-122.3, 37.7]]

        let result = VehicleStateMerger.apply(fields: ["destinationName": .null], to: state)

        XCTAssertTrue(result.navigationCleared)
        XCTAssertEqual(result.changedGroups, [.navigation])
        XCTAssertNil(result.state.destinationName)
        XCTAssertNil(result.state.destinationLatitude)
        XCTAssertNil(result.state.destinationLongitude)
        XCTAssertNil(result.state.etaMinutes)
        XCTAssertNil(result.state.navRouteCoordinates)
    }

    func testFullNavClearFixtureAmplifies() throws {
        var state = try baseState()
        state.destinationName = "Home"
        state.etaMinutes = 5

        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/vehicle_update.nav_clear.json"))
        let payload = try WireCodec.decodePayload(VehicleUpdatePayload.self, from: envelope)
        let result = VehicleStateMerger.apply(fields: payload.fields, to: state)

        XCTAssertTrue(result.navigationCleared)
        XCTAssertNil(result.state.destinationName)
        XCTAssertNil(result.state.etaMinutes)
    }

    func testUnknownFieldIsIgnored() throws {
        let state = try baseState()
        let result = VehicleStateMerger.apply(
            fields: ["someFutureField": .number(9), "speed": .number(34)],
            to: state
        )
        XCTAssertEqual(result.state.speed, 34)          // known ungrouped field applied
        XCTAssertTrue(result.changedGroups.isEmpty)     // no atomic group touched
    }

    func testClassifyFlagsNavClear() {
        let (groups, navCleared) = VehicleStateMerger.classify(
            fields: ["etaMinutes": .null, "chargeLevel": .number(80)]
        )
        XCTAssertTrue(groups.contains(.navigation))
        XCTAssertTrue(groups.contains(.charge))
        XCTAssertTrue(navCleared)
    }
}
