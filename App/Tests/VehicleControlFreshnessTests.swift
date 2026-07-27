import Foundation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-260 — honest unknown / stale labeling for the quick-tile subs
//
// Splits the old perpetual "— Syncing" into three bounded states: transient
// Syncing (connecting or a streaming car still delivering), honest Unavailable
// (a reachable NON-streaming snapshot proves the value isn't coming), and a
// stale "X ago" qualifier on a KNOWN safety value. Pure logic — a fixed `now`
// keeps the age buckets deterministic.
final class VehicleControlFreshnessTests: XCTestCase {

    // MARK: State 1 — connecting / first snapshot not yet arrived → "Syncing"

    func testUnknownWhileConnectingIsSyncing() {
        // No snapshot yet (no read time). Streaming state is not even known —
        // the value is genuinely transient, so "Syncing" is honest.
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: false, isStreaming: nil),
            VehicleControlFreshness.syncingSub
        )
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: false, isStreaming: false),
            VehicleControlFreshness.syncingSub,
            "no snapshot means connecting regardless of a stale streaming flag"
        )
    }

    func testSimulatedPathIsAlwaysSyncingNeverUnavailable() {
        // Simulated: lastUpdated nil (→ hasSnapshot false), isStreaming nil. Every
        // field is isKnown there so this branch never actually renders, but it must
        // NOT resolve to "Unavailable" (which would be a regression risk).
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: false, isStreaming: nil),
            VehicleControlFreshness.syncingSub
        )
    }

    // MARK: State 2 — reachable snapshot, car NOT streaming → "Unavailable"

    func testUnknownWithSnapshotButNotStreamingIsUnavailable() {
        // We have a frame (read time exists) but the car is offline/in_service and
        // the one-shot REST read couldn't fill the field: it is NOT coming.
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: true, isStreaming: false),
            VehicleControlFreshness.unavailableSub
        )
    }

    func testUnknownWhileStreamingStaysSyncing() {
        // Online car: the value really is in flight and will land → still Syncing,
        // NOT Unavailable.
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: true, isStreaming: true),
            VehicleControlFreshness.syncingSub
        )
    }

    func testSyncingAndUnavailableAreDistinctAndDashPrefixed() {
        XCTAssertNotEqual(VehicleControlFreshness.syncingSub, VehicleControlFreshness.unavailableSub)
        XCTAssertTrue(VehicleControlFreshness.syncingSub.hasPrefix(VehicleControlFreshness.dash))
        XCTAssertTrue(VehicleControlFreshness.unavailableSub.hasPrefix(VehicleControlFreshness.dash))
        XCTAssertTrue(VehicleControlFreshness.unavailableSub.contains("Unavailable"))
    }

    // MARK: showsQualifier — a non-streaming car's known value is never "live"

    func testNonStreamingKnownValueAlwaysQualifiesEvenWhenRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Car just went offline 5s ago: NOT streaming → still qualifies, so a
        // stale trunk never renders as bare "Open" (the trunk-open incident).
        XCTAssertTrue(VehicleControlFreshness.showsQualifier(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-5), now: now))
    }

    func testStreamingKnownValueQualifiesOnlyWhenStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(VehicleControlFreshness.showsQualifier(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-30), now: now), "fresh stream")
        XCTAssertTrue(VehicleControlFreshness.showsQualifier(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-120), now: now), "stalled stream")
    }

    func testSimulatedPathNeverQualifies() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // nil isStreaming (M1) and/or nil lastUpdated → never a qualifier.
        XCTAssertFalse(VehicleControlFreshness.showsQualifier(
            isStreaming: nil, lastUpdated: now.addingTimeInterval(-9999), now: now))
        XCTAssertFalse(VehicleControlFreshness.showsQualifier(
            isStreaming: false, lastUpdated: nil, now: now))
    }

    // MARK: State 3 — known but stale → value + "X ago"

    func testFreshKnownValueHasNoStaleQualifier() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Read 30s ago — inside the freshness threshold → not stale.
        XCTAssertFalse(VehicleControlFreshness.isStale(lastUpdated: now.addingTimeInterval(-30), now: now))
    }

    func testNilLastUpdatedIsNeverStale() {
        // Simulated / pre-first-frame: no read time → never a qualifier (keeps M1
        // pixel-identical).
        XCTAssertFalse(VehicleControlFreshness.isStale(lastUpdated: nil, now: Date()))
    }

    func testOldKnownValueIsStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(VehicleControlFreshness.isStale(lastUpdated: now.addingTimeInterval(-120), now: now))
    }

    func testAgoLabelBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-5 * 60), now: now), "5m ago")
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-2 * 3600), now: now), "2h ago")
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
    }

    func testAgoLabelClampsFutureReadToJustNow() {
        // Clock skew (read time slightly in the future) must not produce a negative
        // or nonsensical label.
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(10), now: now), "just now")
    }

    // MARK: MYR-281 — staleQualifier: qualifier only when GENUINELY stale
    //
    // The tile sub drops the sub-60s "just now" so the everyday case stays short +
    // uniform (the "cheap look" was a long sub scaling down beside a short one);
    // a genuinely stale value still surfaces "X ago", and the simulated path never
    // qualifies.

    func testStaleQualifierOmitsFreshStreamingValue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(VehicleControlFreshness.staleQualifier(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-20), now: now),
            "a fresh streaming value shows bare — no qualifier")
    }

    func testStaleQualifierOmitsRecentNonStreamingValue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Car offline 10s ago: showsQualifier is TRUE, but MYR-281 still omits the
        // sub-60s "just now" so the tile stays short (footer carries "Not live").
        XCTAssertNil(VehicleControlFreshness.staleQualifier(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-10), now: now),
            "recent non-streaming value drops the noisy 'just now' qualifier")
    }

    func testStaleQualifierShowsAgoForOldNonStreamingValue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(VehicleControlFreshness.staleQualifier(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-2 * 3600), now: now), "2h ago",
            "a genuinely stale offline value still surfaces how long ago")
    }

    func testStaleQualifierShowsAgoForStalledStream() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(VehicleControlFreshness.staleQualifier(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-5 * 60), now: now), "5m ago")
    }

    func testStaleQualifierNilOnSimulatedPath() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(VehicleControlFreshness.staleQualifier(
            isStreaming: nil, lastUpdated: nil, now: now))
        XCTAssertNil(VehicleControlFreshness.staleQualifier(
            isStreaming: nil, lastUpdated: now.addingTimeInterval(-9999), now: now),
            "nil isStreaming (M1) never qualifies")
    }
}

// MARK: - MYR-280 — SeatClimatePresentation (pure seat-section decisions)

final class SeatClimatePresentationTests: XCTestCase {

    func testSupportsCoolWhenVent() {
        XCTAssertTrue(SeatClimatePresentation.supportsCool(seatVent: true, driverMode: .heat, passengerMode: .heat))
    }

    // MARK: MYR-299 — capability from cooler-field PRESENCE, not runtime state

    /// The capability matrix. A car without ventilated seats never emits Tesla
    /// protos 237/238, so presence (non-nil, INCLUDING 0) is the capability and
    /// nil/nil is an honest "no cooled seats".
    func testHasVentilatedSeatsFromCoolerFieldPresence() {
        let cases: [(left: Int?, right: Int?, vent: Bool?, want: Bool, why: String)] = [
            (nil, nil, nil, false,
             "no cooler fields, no vent flag → the car never emitted 237/238; honest heat-only"),
            (0, nil, nil, true,
             "a ZERO driver cooler is present-but-off — the whole point of MYR-299; must offer Cool"),
            (nil, 0, nil, true,
             "presence on either side is enough"),
            (0, 0, nil, true,
             "both seats off on a vented car — the client's exact case, previously locked out of Cool"),
            (2, 0, nil, true,
             "actively cooling driver, passenger off"),
            (3, 3, nil, true,
             "both cooling"),
            (nil, nil, true, true,
             "no cooler fields yet, but the car says ventilation is ON — belt-and-braces OR-signal"),
            (nil, nil, false, false,
             "vent OFF is a runtime reading, NOT proof the hardware is absent — but on its own it is no evidence either, so stay honest"),
            (0, 0, false, true,
             "presence wins over the runtime vent flag: this is the shipped bug, a vented car reporting vent=off"),
        ]

        for c in cases {
            XCTAssertEqual(
                SeatClimatePresentation.hasVentilatedSeats(
                    seatCoolerLeft: c.left, seatCoolerRight: c.right, seatVentEnabled: c.vent
                ),
                c.want,
                "left=\(String(describing: c.left)) right=\(String(describing: c.right)) "
                    + "vent=\(String(describing: c.vent)): \(c.why)"
            )
        }
    }

    /// Tolerant absence: before the first snapshot every input is nil, and the
    /// section must stay honestly heat-only rather than guessing either way.
    func testHasVentilatedSeatsIsFalseBeforeAnySnapshot() {
        XCTAssertFalse(
            SeatClimatePresentation.hasVentilatedSeats(
                seatCoolerLeft: nil, seatCoolerRight: nil, seatVentEnabled: nil
            )
        )
    }

    /// End-to-end through the shipping predicate: a vented car with BOTH seats off
    /// and no seat reading `.cool` must still offer the toggle. This is the exact
    /// combination that failed for the client — `supportsCool` used to see
    /// `seatVent: false` (the runtime flag) and neither mode `.cool`.
    func testVentedCarWithBothSeatsOffOffersCool() {
        let capable = SeatClimatePresentation.hasVentilatedSeats(
            seatCoolerLeft: 0, seatCoolerRight: 0, seatVentEnabled: false
        )
        XCTAssertTrue(
            SeatClimatePresentation.supportsCool(
                seatVent: capable, driverMode: .heat, passengerMode: .heat
            ),
            "a car that emits seat-cooler telemetry HAS cooled seats even with both off"
        )
        XCTAssertEqual(SeatClimatePresentation.sectionLabel(supportsCool: capable), "SEAT CLIMATE")
    }

    /// The contrast half: a genuinely heat-only car is unaffected — it never emits
    /// 237/238, so it keeps the honest "SEAT HEATING" label and no toggle.
    func testHeatOnlyCarStillGetsNoToggleUnderTheNewPredicate() {
        let capable = SeatClimatePresentation.hasVentilatedSeats(
            seatCoolerLeft: nil, seatCoolerRight: nil, seatVentEnabled: nil
        )
        XCTAssertFalse(
            SeatClimatePresentation.supportsCool(
                seatVent: capable, driverMode: .heat, passengerMode: .heat
            )
        )
        XCTAssertEqual(SeatClimatePresentation.sectionLabel(supportsCool: capable), "SEAT HEATING")
    }

    func testSupportsCoolWhenASeatReadsCoolEvenWithoutVentFlag() {
        // The client's incoherence: a seat streaming a cool state on a car whose
        // vent flag is false must STILL offer the toggle (and read "SEAT CLIMATE"),
        // never a snowflake stranded under "SEAT HEATING".
        XCTAssertTrue(SeatClimatePresentation.supportsCool(seatVent: false, driverMode: .cool, passengerMode: .heat))
        XCTAssertTrue(SeatClimatePresentation.supportsCool(seatVent: false, driverMode: .heat, passengerMode: .cool))
    }

    func testHeatOnlyCarDoesNotSupportCool() {
        XCTAssertFalse(SeatClimatePresentation.supportsCool(seatVent: false, driverMode: .heat, passengerMode: .heat))
    }

    func testSectionLabelIsHonest() {
        XCTAssertEqual(SeatClimatePresentation.sectionLabel(supportsCool: true), "SEAT CLIMATE")
        XCTAssertEqual(SeatClimatePresentation.sectionLabel(supportsCool: false), "SEAT HEATING")
    }

    func testIconIsSingleMetaphorPerMode() {
        XCTAssertEqual(SeatClimatePresentation.icon(mode: .heat), "flame.fill", "heat is a flame, not a sun")
        XCTAssertEqual(SeatClimatePresentation.icon(mode: .cool), "snowflake")
    }

    func testStateCaptionStatesModeInWords() {
        XCTAssertEqual(SeatClimatePresentation.stateCaption(known: true, mode: .heat, level: 2), "Heating")
        XCTAssertEqual(SeatClimatePresentation.stateCaption(known: true, mode: .cool, level: 3), "Cooling")
        XCTAssertEqual(SeatClimatePresentation.stateCaption(known: true, mode: .heat, level: 0), "Off")
        XCTAssertEqual(SeatClimatePresentation.stateCaption(known: true, mode: .cool, level: 0), "Off",
            "off is off regardless of the armed mode")
    }

    func testStateCaptionIsNilWhenUnknownSoCallerShowsFreshnessSub() {
        XCTAssertNil(SeatClimatePresentation.stateCaption(known: false, mode: .heat, level: 0))
    }
}
