import DesignSystem
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

/// MYR-440 — what the app does with a cabin/ambient temperature the viewer mask
/// withheld.
///
/// contracts 0.29.0 makes `VehicleState.interiorTemp` / `.exteriorTemp` optional
/// so a viewer's `/snapshot` decodes at all (the Kit's
/// `ViewerMaskedSnapshotTests` covers the decode). This suite covers the two
/// things that happen NEXT: the mapping must carry the absence through as `nil`
/// rather than substituting a number, and the surfaces must render the repo's
/// honest-unknown mark.
///
/// Both were previously untestable in practice rather than untested by oversight:
/// with a non-optional contract the live path could not produce a nil, so the arm
/// existed for a case that could not occur. It occurs now, for every shared
/// viewer, for the whole session.
final class ViewerMaskedTempsTests: XCTestCase {

    // MARK: The fold

    func testTheMappingCarriesAWithheldTempThroughAsNil() throws {
        // A viewer-shaped state: identical to the owner's in every respect the
        // mask does not touch, so anything that changes below is the mask.
        let viewer = Contracts.parkedState()
            .withCabinTempsWithheld()

        let snapshot = VehicleContractMapping.snapshot(from: viewer)

        XCTAssertNil(snapshot.interiorTempF)
        XCTAssertNil(snapshot.exteriorTempF)

        // Nothing ELSE degrades. A withheld cabin temperature must not cost the
        // viewer the readings they are entitled to — this is the seam-level
        // restatement of the Kit's "one missing key must not discard the
        // document".
        XCTAssertEqual(snapshot.odometerMiles, 20481)
        XCTAssertEqual(try XCTUnwrap(snapshot.fsdMilesSinceReset), 12.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.batteryPercent, 82, accuracy: 1e-9)
    }

    /// The owner path must be byte-identical — the owner always receives both, so
    /// a real value must still arrive as that exact value and never as a default.
    func testTheOwnerMappingIsUnchangedWhenBothTempsArePresent() {
        let owner = Contracts.parkedState()

        let snapshot = VehicleContractMapping.snapshot(from: owner)

        XCTAssertEqual(snapshot.interiorTempF, 68)
        XCTAssertEqual(snapshot.exteriorTempF, 60)
    }

    /// A driving owner state too — the mapping has a `driving` branch, and the
    /// temps are read outside it, so this pins that the branch cannot start
    /// interfering with them.
    func testTheDrivingOwnerMappingAlsoKeepsBothTemps() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState())

        XCTAssertEqual(snapshot.interiorTempF, 70)
        XCTAssertEqual(snapshot.exteriorTempF, 61)
    }

    // MARK: The render

    func testAWithheldTempRendersTheHonestUnknownDash() {
        XCTAssertEqual(ClimateTemperatureText.degrees(nil), "\u{2014}")

        // The unit goes with the value. "—°" would read as a rendering fault
        // rather than as an unknown reading.
        XCTAssertFalse(ClimateTemperatureText.degrees(nil).contains("°"))
    }

    func testAKnownTempIsUnchangedByTheDashGrammar() {
        XCTAssertEqual(ClimateTemperatureText.degrees(68), "68°")
        XCTAssertEqual(ClimateTemperatureText.degrees(0), "0°")
        XCTAssertEqual(ClimateTemperatureText.degrees(-4), "-4°")
    }

    /// ONE honest-unknown mark across the app. Two surfaces are free to differ in
    /// how much of the sentence survives (`BatteryReadout` keeps "— used"; the
    /// climate columns keep their INTERIOR/EXTERIOR captions) but never in the
    /// GLYPH — and two separate string literals is exactly how that drifts.
    func testTheClimateDashIsTheSameGlyphAsTheBatteryReadoutDash() {
        XCTAssertEqual(ClimateTemperatureText.dash, BatteryReadout.dash)
    }

    /// The inline "climate ON" line degrades to a readable sentence rather than
    /// to punctuation soup — this is the composed form the viewer actually sees,
    /// and it is asserted whole because the two dashes are interpolated into one
    /// string where a stray unit or separator would not fail any test above.
    func testTheInlineClimateLineStaysReadableWithBothTempsWithheld() {
        let line = "Interior \(ClimateTemperatureText.degrees(nil)) · Outside \(ClimateTemperatureText.degrees(nil))"
        XCTAssertEqual(line, "Interior \u{2014} · Outside \u{2014}")
    }
}

private extension VehicleState {
    /// The viewer mask's effect on ONE state, expressed as the two absences it
    /// causes, so a test's "before" and "after" differ by exactly the mask.
    func withCabinTempsWithheld() -> VehicleState {
        var masked = self
        masked.interiorTemp = nil
        masked.exteriorTemp = nil
        return masked
    }
}
