import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// MYR-440 — a VIEWER-masked `/snapshot` must DECODE.
///
/// The mask MYR-435 narrows withholds 34 fields from a shared viewer. Thirty-two
/// of them were already optional in the contract; `interiorTemp` and
/// `exteriorTemp` were the two stragglers still in `VehicleState.required`, which
/// generated them as non-optional `Int`. So on contracts 0.28.0 a viewer's
/// snapshot threw `keyNotFound` on the FIRST missing temp and the WHOLE document
/// was discarded — not just the two fields.
///
/// The failure was silent in the worst way. `TelemetrySocket.attemptSnapshot`
/// catches a `DecodingError` in the same generic `catch` it uses for a network
/// blip, returns `false`, and walks the retry ladder — so a permanent, structural
/// contract mismatch was indistinguishable from a flaky connection, and the only
/// thing a viewer saw was a map frozen on "Locating…".
///
/// That is why the load-bearing assertion here is a DECODE rather than a
/// nil-check: the nil-check alone would still pass on a build where the document
/// never decoded, because there would be no document to read nils from.
final class ViewerMaskedSnapshotTests: XCTestCase {

    /// The canonical viewer document, vendored from telemetry's own
    /// `snapshot.viewer.json` — the same car and the same moment as
    /// `snapshot.json`, so the pair is a clean field-for-field diff of the mask.
    private func viewerData() throws -> Data { try Fixture.data("rest/snapshot.viewer.json") }
    private func ownerData() throws -> Data { try Fixture.data("rest/snapshot.json") }

    func testAViewerMaskedSnapshotDecodesAndCarriesNoCabinTemps() throws {
        let viewer = try JSONDecoder().decode(VehicleState.self, from: try viewerData())

        XCTAssertNil(viewer.interiorTemp)
        XCTAssertNil(viewer.exteriorTemp)

        // The rest of the document survived, which is the actual point: one
        // withheld field must not cost the reader every other one. These are the
        // fields the frozen "Locating…" map needed and never got.
        XCTAssertEqual(viewer.vehicleId, "clxyz1234567890abcdef")
        XCTAssertEqual(viewer.latitude, 37.7749, accuracy: 1e-9)
        XCTAssertEqual(viewer.longitude, -122.4194, accuracy: 1e-9)
        XCTAssertEqual(viewer.locationName, "Home")
        XCTAssertEqual(viewer.chargeLevel, 78)
        XCTAssertEqual(viewer.estimatedRange, 245)
        XCTAssertEqual(viewer.status, .parked)
    }

    /// The fixture is evidence only to the extent it is the WIRE (MYR-362's
    /// lesson: a hand-authored fixture that agrees with a misreading proves
    /// nothing). A wrong key on an optional can never fail a decode, so the two
    /// temps being ABSENT is asserted on the raw JSON rather than inferred from
    /// the nils above — those nils would read identically if the fixture spelled
    /// the keys wrongly, or nulled them.
    func testTheViewerFixtureOmitsTheTempKEYSRatherThanNullingThem() throws {
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try viewerData()) as? [String: Any]
        )
        XCTAssertFalse(raw.keys.contains("interiorTemp"))
        XCTAssertFalse(raw.keys.contains("exteriorTemp"))

        // Absent, not nulled, is a rule with a reason (rest-api.md §5.1): emitting
        // an explicit null would still tell the viewer the field exists. The other
        // masked owner-only fields are held to the same rule here.
        for withheld in ["vin", "locked", "chargePortDoorOpen", "frunkOpen", "trunkOpen", "mediaPlaybackStatus"] {
            XCTAssertFalse(raw.keys.contains(withheld), "`\(withheld)` must be an absent KEY on a viewer document")
        }

        // And the owner fixture is the control: the same two keys ARE present
        // there, so this test cannot pass because of a fixture that lost them.
        let owner = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try ownerData()) as? [String: Any]
        )
        XCTAssertTrue(owner.keys.contains("interiorTemp"))
        XCTAssertTrue(owner.keys.contains("exteriorTemp"))
    }

    /// The owner path must be byte-identical — the owner always receives both.
    func testTheOwnerSnapshotStillCarriesBothTemps() throws {
        let owner = try JSONDecoder().decode(VehicleState.self, from: try ownerData())
        XCTAssertEqual(owner.interiorTemp, 68)
        XCTAssertEqual(owner.exteriorTemp, 55)
    }
}
