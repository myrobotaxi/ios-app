import DesignSystem
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-287 — Drives header lifetime odometer
//
// The Drives tab header rendered `"\(vehicle.name) · 42,184 mi total"` on BOTH
// paths: a real vehicle name next to the prototype's fixture odometer. A live
// owner whose car reads ~6,347 mi was shown 42,184 (client-verified via
// TestFlight) — a direct "No fixtures on the live path" violation (MYR-228).
//
// `DrivesScreen.headerSubtitle` is the pure resolver behind the header, so the
// three cases that matter are covered here without a SwiftUI host:
//  • LIVE + a real odometer  → the REAL figure, grouped, "mi total" suffix.
//  • LIVE + no odometer yet  → the "· X mi total" clause is OMITTED entirely
//    (honest unknown), never a fixture number and never a fabricated 0.
//  • SIMULATED               → the prototype literal, byte-identical, so the
//    `ownerDrives` drift-gate scene stays pixel-identical.
@MainActor
final class DrivesHeaderOdometerTests: XCTestCase {

    // MARK: Live — real odometer

    func testLiveRendersRealOdometer() {
        // The client's actual reading (Linear MYR-287) — NOT the fixture 42,184.
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: 6347),
            "Lunar · 6,347 mi total"
        )
    }

    func testLiveOdometerNeverShowsTheFixtureFigure() {
        let subtitle = DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: 6347)
        XCTAssertFalse(
            subtitle.contains(DrivesScreen.simulatedLifetimeOdometerText),
            "the prototype's 42,184 must never reach a live header (MYR-228)"
        )
    }

    func testLiveGroupsThousandsLikeThePrototypeFormat() {
        // Same grouping the owner sheet's Lifetime → Odometer row uses
        // (`MRTNumber.grouped`), so the two surfaces read identically.
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: 128_402),
            "Lunar · 128,402 mi total"
        )
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: 812),
            "Lunar · 812 mi total"
        )
    }

    func testLiveZeroOdometerIsAValueNotAnUnknown() {
        // A brand-new car genuinely reading 0 is KNOWN — it must render, not be
        // mistaken for "not streamed yet".
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: 0),
            "Lunar · 0 mi total"
        )
    }

    // MARK: Live — honest unknown

    func testLiveWithoutOdometerDropsTheSuffix() {
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: nil),
            "Lunar",
            "no snapshot odometer yet → omit the clause rather than invent a total"
        )
    }

    func testLiveWithoutOdometerNeverClaimsATotal() {
        let subtitle = DrivesScreen.headerSubtitle(isLive: true, vehicleName: "Lunar", odometerMiles: nil)
        XCTAssertFalse(subtitle.contains("mi total"))
        XCTAssertFalse(subtitle.contains("·"))
    }

    func testLiveMidConnectFallsBackToTheGenericFleetLabel() {
        // The live fleet has no selected vehicle until the list loads; "Fleet" is
        // a generic stand-in, not a fixture persona.
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: nil, odometerMiles: nil),
            "Fleet"
        )
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: true, vehicleName: nil, odometerMiles: 6347),
            "Fleet · 6,347 mi total"
        )
    }

    // MARK: Simulated — drift-gate pixel identity

    func testSimulatedKeepsThePrototypeLiteral() {
        // screens.jsx:633 verbatim.
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: false, vehicleName: "Model Y", odometerMiles: nil),
            "Model Y · 42,184 mi total"
        )
    }

    func testSimulatedIgnoresAnySnapshotOdometer() {
        // The prototype pins `VEHICLES[0]`'s figure regardless of the selection,
        // and the simulated telemetry source seeds 42,184 for every vehicle —
        // the sim string must not start tracking the snapshot and drift.
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: false, vehicleName: "Model Y", odometerMiles: 6347),
            "Model Y · 42,184 mi total"
        )
    }

    func testSimulatedWithoutASelectionMatchesTheFleetFallback() {
        XCTAssertEqual(
            DrivesScreen.headerSubtitle(isLive: false, vehicleName: nil, odometerMiles: nil),
            "Fleet · 42,184 mi total"
        )
    }
}
