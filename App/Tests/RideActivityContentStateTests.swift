import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - The decode trap (MYR-172, MYR-362's lesson pointed forwards)
//
// `RideActivityAttributes.ContentState` is a HAND-KEPT MIRROR of the generated
// `LiveActivityContentState` — it has to be, because ActivityKit requires
// `Hashable` and the generated type is not. A mirror is exactly the shape MYR-362
// bit on: two types written from one reading of a schema, agreeing with each other
// and with their own fixtures, and wrong about the wire.
//
// The failure here would be SILENT in the worst way. ActivityKit decodes a remote
// update's `content-state` with a plain `JSONDecoder`; every field but `eta` is
// non-optional, so a wrong key on one of THOSE throws and the update is visibly
// dropped. `eta` is optional, so a wrong key on it decodes to `nil` — which is
// indistinguishable from the server's own legitimate "no ETA known, key omitted".
// The rider's lock screen simply never counts down, nothing throws, nothing logs,
// and a round-trip test written against the same misspelling passes.
//
// So the guards below are, in order of strength:
//   1. RAW KEYS — what this type actually produces, asserted as a set.
//   2. CROSS-PINNED raw keys — this type's keys against the GENERATED type's keys,
//      which is the check MYR-362 did not have.
//   3. Decode from the SCHEMA'S OWN PRINTED EXAMPLES, byte for byte.

final class RideActivityContentStateTests: XCTestCase {

    // MARK: - 1. Raw keys

    func testTheContentStateEncodesExactlyTheFiveContractKeys() throws {
        let state = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: "Blue Whale",
            destination: "Home"
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(json.keys),
            ["v", "status", "eta", "vehicleName", "destination"],
            """
            The property NAMES are the wire keys — there are no CodingKeys on this \
            type and there must not be. Renaming a property to read better (etaAt, \
            vehicle, destinationLabel) stops that key decoding from a real push.
            """
        )
    }

    func testTheEtaKeyIsOmittedRatherThanNullWhenThereIsNoETA() throws {
        let state = RideActivityAttributes.ContentState(
            status: .accepted,
            eta: nil,
            vehicleName: "Blue Whale",
            destination: "Home"
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )

        XCTAssertFalse(
            json.keys.contains("eta"),
            """
            The schema says eta is OMITTED ENTIRELY when unknown — "never null, \
            never zero, never a guess". Encoding an explicit null would disagree \
            with the server's own shape.
            """
        )
        XCTAssertEqual(Set(json.keys), ["v", "status", "vehicleName", "destination"])
    }

    // MARK: - 2. Cross-pin against the generated type

    func testTheMirrorProducesTheSAMERAWKEYSAsTheGeneratedContractType() throws {
        // The ONE assertion that would have caught MYR-362. Both types are encoded
        // and their raw key sets compared — not their Swift property names, and not
        // a round trip through either one, both of which stay green when the two
        // agree with each other and disagree with the schema.
        let mirror = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: "Blue Whale",
            destination: "Home"
        )
        let generated = LiveActivityContentState(
            v: 1,
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: "Blue Whale",
            destination: "Home"
        )

        let mirrorKeys = try rawKeys(of: mirror)
        let generatedKeys = try rawKeys(of: generated)

        XCTAssertEqual(
            mirrorKeys,
            generatedKeys,
            """
            The app's ContentState has drifted from the generated contracts type. \
            Whichever side moved, the wire did not — fix the mirror.
            """
        )
    }

    func testTheGeneratedContractTypeCanDecodeWhatTheMirrorEncodes() throws {
        // Byte-level interchangeability in the direction that matters least
        // (the client never sends a content state) but which pins the VALUES —
        // key parity alone would not catch `eta` being sent in milliseconds.
        let mirror = RideActivityAttributes.ContentState(
            status: .arrived,
            eta: 1_785_535_200,
            vehicleName: "Blue Whale",
            destination: "Home"
        )

        let decoded = try JSONDecoder().decode(
            LiveActivityContentState.self,
            from: JSONEncoder().encode(mirror)
        )

        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.status, .arrived)
        XCTAssertEqual(decoded.eta, 1_785_535_200)
        XCTAssertEqual(decoded.vehicleName, "Blue Whale")
        XCTAssertEqual(decoded.destination, "Home")
    }

    // MARK: - 3. Decode the schema's own printed examples

    /// Built from the `examples` in `schemas/live-activity.schema.json`:
    /// `v: 1`, `eta: 1785535200`, `vehicleName: "Blue Whale"`,
    /// `destination: "Home"`. This is what ActivityKit hands the widget.
    func testDecodesTheSchemasPrintedExamplePayload() throws {
        let payload = Data("""
        {
          "v": 1,
          "status": "enroute",
          "eta": 1785535200,
          "vehicleName": "Blue Whale",
          "destination": "Home"
        }
        """.utf8)

        let state = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: payload)

        XCTAssertEqual(state.v, 1)
        XCTAssertEqual(state.status, .enroute)
        XCTAssertEqual(state.eta, 1_785_535_200)
        XCTAssertEqual(state.vehicleName, "Blue Whale")
        XCTAssertEqual(state.destination, "Home")

        // The unit assertion. `x-unit: unix-seconds` — a mirror that read this as
        // milliseconds would put the ETA in 1970 and the countdown would render
        // empty forever, with no decode failure anywhere.
        XCTAssertEqual(
            state.etaDate,
            Date(timeIntervalSince1970: 1_785_535_200),
            "eta is unix SECONDS, not milliseconds"
        )
    }

    func testDecodesAPayloadWithNoETAKeyAtAll() throws {
        // "a car with no active nav route yields no key at all rather than an
        // invented number".
        let payload = Data("""
        {"v":1,"status":"accepted","vehicleName":"Blue Whale","destination":"Home"}
        """.utf8)

        let state = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: payload)

        XCTAssertNil(state.eta)
        XCTAssertNil(state.etaDate)
        XCTAssertEqual(state.status, .accepted)
    }

    func testDecodesAnUnnamedVehicleAsAnEmptyStringRatherThanFailing() throws {
        let payload = Data("""
        {"v":1,"status":"accepted","vehicleName":"","destination":"Home"}
        """.utf8)

        let state = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: payload)

        XCTAssertEqual(state.vehicleName, "")
        XCTAssertEqual(
            RideActivityCopy.vehicleDisplayName(state.vehicleName),
            RideActivityCopy.genericVehicleName,
            "an unnamed car gets the client's generic fallback, never a blank"
        )
    }

    // MARK: - Forward compatibility

    func testAnUnrecognisedStatusDecodesRatherThanThrowing() throws {
        // The schema is explicit: "Append-only; a client MUST tolerate an
        // unrecognised member rather than failing to decode." This is why the
        // ContentState carries the GENERATED enum rather than a second hand-written
        // copy — a plain Swift enum would throw here and take the whole lock screen
        // down on the first status a future server adds.
        let payload = Data("""
        {"v":1,"status":"boarding","vehicleName":"Blue Whale","destination":"Home"}
        """.utf8)

        let state = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: payload)

        XCTAssertEqual(state.status, .unrecognized("boarding"))
        XCTAssertEqual(
            state.status.rawValue,
            "boarding",
            "the raw value is preserved so it re-encodes byte-identically (MYR-195)"
        )
    }

    func testAnUnrecognisedStatusIsNotTreatedAsTerminal() throws {
        let state = RideActivityAttributes.ContentState(
            status: .unrecognized("boarding"),
            vehicleName: "Blue Whale",
            destination: "Home"
        )

        XCTAssertFalse(
            state.isTerminal,
            """
            A member this build has never heard of is far likelier to be a new \
            IN-FLIGHT state than a new terminal one. Guessing terminal takes a live \
            ride off the rider's lock screen; guessing in-flight leaves a card up \
            until the server's own end push clears it, which is recoverable.
            """
        )
    }

    func testAnUnknownFUTUREKeyDoesNotBreakTheDecode() throws {
        // Codable ignores unknown keys, which is what lets the server add an
        // optional field without a client release. Pinned so nobody "tidies" this
        // type into something strict.
        let payload = Data("""
        {"v":1,"status":"enroute","eta":1785535200,"vehicleName":"Blue Whale",
         "destination":"Home","driverMood":"serene"}
        """.utf8)

        let state = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: payload)
        XCTAssertEqual(state.status, .enroute)
    }

    func testTheContentVersionThisBuildSpeaksIsOne() {
        XCTAssertEqual(RideActivityContentVersion.current, 1)
        let state = RideActivityAttributes.ContentState(
            status: .accepted,
            vehicleName: "",
            destination: ""
        )
        XCTAssertEqual(state.v, 1, "v defaults to the version this build speaks")
    }

    // MARK: - Terminality

    func testEveryTerminalStatusIsTerminalAndEveryRunningOneIsNot() {
        let terminal: [LiveActivityRideStatus] = [.completed, .declined, .cancelled, .reservationExpired]
        let running: [LiveActivityRideStatus] = [.requested, .accepted, .arrived, .enroute]

        for status in terminal {
            let state = RideActivityAttributes.ContentState(status: status, vehicleName: "", destination: "")
            XCTAssertTrue(state.isTerminal, "\(status.rawValue) should be terminal")
        }
        for status in running {
            let state = RideActivityAttributes.ContentState(status: status, vehicleName: "", destination: "")
            XCTAssertFalse(state.isTerminal, "\(status.rawValue) should not be terminal")
        }
    }

    func testReservationExpiredIsCarriedEvenThoughItIsNotARideStatus() {
        // Its whole reason for existing: the sweeper leaves the ride ROW at
        // `accepted`, so without this member the lock screen would sit on "your car
        // is on its way" forever.
        let payload = Data("""
        {"v":1,"status":"reservation_expired","vehicleName":"Blue Whale","destination":"Home"}
        """.utf8)

        let state = try? JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: payload)

        XCTAssertEqual(state?.status, .reservationExpired)
        XCTAssertEqual(state?.isTerminal, true)
        XCTAssertFalse(
            RideActivityCopy.showsCountdown(for: .reservationExpired),
            "a lapsed reservation must never count down to an arrival that is not coming"
        )
    }

    // MARK: - Helper

    private func rawKeys(of value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }
}
