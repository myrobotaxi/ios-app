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

    // MARK: MYR-335 — the tile forms of the two unknown subs

    /// The 4-column tiles hold ~50pt of text; "\u{2014} Unavailable" is 75pt and
    /// "\u{2014} Syncing" 56pt, so both ellipsized there. The tile forms say the
    /// SAME two states in the room a tile has, while the full-width rows
    /// (`ClimateSection`) keep the em-dash grammar. Widths are asserted in
    /// `VehicleControlTileCaptionTests`; this pins the DECISION.
    func testTileUnknownSubMirrorsTheFullWidthDecision() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = now
        XCTAssertEqual(
            VehicleControlFreshness.tileUnknownSub(hasSnapshot: true, isStreaming: false),
            VehicleControlFreshness.tileUnavailableSub,
            "a reachable, non-streaming snapshot proves the value is not coming"
        )
        for (hasSnapshot, isStreaming) in [(false, nil), (false, Bool?.some(true)), (true, Bool?.some(true))] {
            XCTAssertEqual(
                VehicleControlFreshness.tileUnknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming),
                VehicleControlFreshness.tileSyncingSub,
                "hasSnapshot=\(hasSnapshot) isStreaming=\(String(describing: isStreaming)) is genuinely in flight"
            )
        }
        // The two states must never collapse into one word (MYR-260's whole point)
        // and neither tile form may carry the em-dash the wide rows use.
        XCTAssertNotEqual(VehicleControlFreshness.tileSyncingSub, VehicleControlFreshness.tileUnavailableSub)
        XCTAssertFalse(VehicleControlFreshness.tileSyncingSub.contains(VehicleControlFreshness.dash))
        XCTAssertFalse(VehicleControlFreshness.tileUnavailableSub.contains(VehicleControlFreshness.dash))
    }
}

// MARK: - MYR-280 — SeatClimatePresentation (pure seat-section decisions)

final class SeatClimatePresentationTests: XCTestCase {

    func testSupportsCoolWhenVent() {
        XCTAssertTrue(SeatClimatePresentation.supportsCool(
            capability: .ventilated, driverMode: .heat, passengerMode: .heat))
    }

    // MARK: MYR-299 — capability from cooler-field PRESENCE, not runtime state

    /// The capability matrix. A car without ventilated seats never emits Tesla
    /// protos 237/238, so presence (non-nil, INCLUDING 0) is a positive detection.
    ///
    /// **MYR-441 changed exactly the nil/nil/nil-shaped rows** — see
    /// `testAbsenceIsUnknownRatherThanAConfidentNo`. Presence still detects; what
    /// absence no longer does is DENY.
    func testCapabilityFromCoolerFieldPresence() {
        let cases: [(left: Int?, right: Int?, vent: Bool?, want: SeatClimateCapability, why: String)] = [
            (nil, nil, nil, .unknown,
             "no cooler fields, no vent flag → the car has said NOTHING about its seats (MYR-441)"),
            (0, nil, nil, .ventilated,
             "a ZERO driver cooler is present-but-off — the whole point of MYR-299; must offer Cool"),
            (nil, 0, nil, .ventilated,
             "presence on either side is enough"),
            (0, 0, nil, .ventilated,
             "both seats off on a vented car — the client's exact case, previously locked out of Cool"),
            (2, 0, nil, .ventilated,
             "actively cooling driver, passenger off"),
            (3, 3, nil, .ventilated,
             "both cooling"),
            (nil, nil, true, .ventilated,
             "no cooler fields yet, but the car says ventilation is ON — belt-and-braces OR-signal"),
            (nil, nil, false, .unknown,
             "vent OFF is a runtime reading, NOT proof the hardware is absent, and on its own it is no evidence either way"),
            (0, 0, false, .ventilated,
             "presence wins over the runtime vent flag: this is the shipped bug, a vented car reporting vent=off"),
        ]

        for c in cases {
            XCTAssertEqual(
                SeatClimatePresentation.capability(
                    seatCoolingCapable: nil,
                    seatCoolerLeft: c.left, seatCoolerRight: c.right, seatVentEnabled: c.vent
                ),
                c.want,
                "left=\(String(describing: c.left)) right=\(String(describing: c.right)) "
                    + "vent=\(String(describing: c.vent)): \(c.why)"
            )
        }
    }

    // MARK: MYR-308 — the REST seat SPEC outranks the presence heuristic

    /// The FULL precedence matrix: capability (true/false/nil) × cooler-field
    /// presence × the runtime vent flag. The spec field decides whenever it is
    /// present, in BOTH directions; only its absence falls back to MYR-299.
    func testCapabilityPrefersTheSpecFieldOverTheHeuristic() {
        let cases: [(capable: Bool?, left: Int?, right: Int?, vent: Bool?, want: SeatClimateCapability, why: String)] = [
            // capable == true — authoritative yes, whatever telemetry says.
            (true, nil, nil, nil, .ventilated,
             "the spec says the car HAS cooled seats before any cooler telemetry has ever arrived"),
            (true, nil, nil, false, .ventilated,
             "the runtime vent flag being off is not a contradiction of the spec"),
            (true, 0, 0, false, .ventilated, "spec and heuristic agree"),

            // capable == false — authoritative NO. The schema forbids offering the
            // control at all, even greyed out: it would imply hardware that is not
            // there. This OUTRANKS every heuristic signal. MYR-441 leaves this arm
            // exactly as it was: an explicit false is the ONE thing that may deny.
            (false, nil, nil, nil, .heatOnly, "a heat-only car, plainly"),
            (false, 0, 0, nil, .heatOnly,
             "cooler read-backs present at 0 would make the heuristic fire — the spec overrules it"),
            (false, 2, 3, nil, .heatOnly,
             "even non-zero cooler read-backs lose to an explicit spec false (a firmware quirk, not hardware)"),
            (false, nil, nil, true, .heatOnly,
             "and the runtime vent flag cannot conjure hardware the spec says is absent"),

            // capable == nil — absent: a pre-MYR-308 server, or one that has not
            // finished a vehicle-config read. The schema REQUIRES the fallback
            // (hiding the control outright would re-break the client's car).
            (nil, nil, nil, nil, .unknown,
             "nothing known at all → UNKNOWN, which is what the schema's own wording demands (MYR-441)"),
            (nil, 0, 0, false, .ventilated,
             "the MYR-299 client car: presence wins while the spec is unknown"),
            (nil, nil, nil, true, .ventilated,
             "vent-on alone still qualifies while the spec is unknown, per MYR-299's OR-signal"),
        ]
        for c in cases {
            XCTAssertEqual(
                SeatClimatePresentation.capability(
                    seatCoolingCapable: c.capable,
                    seatCoolerLeft: c.left, seatCoolerRight: c.right, seatVentEnabled: c.vent
                ),
                c.want,
                "capable=\(String(describing: c.capable)) left=\(String(describing: c.left)) "
                    + "right=\(String(describing: c.right)) vent=\(String(describing: c.vent)): \(c.why)"
            )
        }
    }

    /// End-to-end: a spec-declared heat-only car keeps the honest "SEAT HEATING"
    /// label and is offered NO Heat↔Cool toggle — even though its cooler read-backs
    /// are present and the old presence rule would have offered one.
    ///
    /// **This is the byte-identity guard for `ownerVehicleSeatsHeatOnly`**: MYR-441
    /// must not have moved the one car the server authoritatively describes.
    func testSpecHeatOnlyCarGetsNoToggleEvenWhenTheHeuristicWouldFire() {
        let capability = SeatClimatePresentation.capability(
            seatCoolingCapable: false, seatCoolerLeft: 0, seatCoolerRight: 0, seatVentEnabled: false
        )
        XCTAssertEqual(capability, .heatOnly)
        let supportsCool = SeatClimatePresentation.supportsCool(
            capability: capability, driverMode: .heat, passengerMode: .heat)
        XCTAssertFalse(supportsCool)
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: capability, supportsCool: supportsCool),
            "SEAT HEATING",
            "an AUTHORITATIVE no is still allowed to say so — that arm is untouched by MYR-441"
        )
    }

    /// The mirror: `true` offers the toggle before the car has ever actuated a
    /// cooler, which is the whole point of having a spec field.
    func testSpecCapableCarOffersCoolWithNoCoolerTelemetryYet() {
        let capability = SeatClimatePresentation.capability(
            seatCoolingCapable: true, seatCoolerLeft: nil, seatCoolerRight: nil, seatVentEnabled: nil
        )
        XCTAssertEqual(capability, .ventilated)
        let supportsCool = SeatClimatePresentation.supportsCool(
            capability: capability, driverMode: .heat, passengerMode: .heat)
        XCTAssertTrue(supportsCool)
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: capability, supportsCool: supportsCool),
            "SEAT CLIMATE"
        )
    }

    // MARK: MYR-441 — absence is UNKNOWN, and unknown is not a no

    /// The defect this issue closes on this surface. Before it, every input being
    /// `nil` — no snapshot yet, a pre-MYR-308 server, or a response whose seat
    /// fields were withheld — produced `false`, i.e. the SAME value as a car the
    /// contract authoritatively describes as heat-only. The section then asserted
    /// "SEAT HEATING" about a car nobody had read.
    ///
    /// The contract's own words on `seatCoolingCapable` are the acceptance
    /// criterion: absence *"does NOT mean 'no seat cooling'"*.
    func testAbsenceIsUnknownRatherThanAConfidentNo() {
        let capability = SeatClimatePresentation.capability(
            seatCoolingCapable: nil, seatCoolerLeft: nil, seatCoolerRight: nil, seatVentEnabled: nil
        )
        XCTAssertEqual(capability, .unknown, "no snapshot is not evidence of no hardware")
        XCTAssertNotEqual(capability, .heatOnly, "and it must never collapse onto the authoritative no")
    }

    /// What `.unknown` RENDERS: the neutral region name, and still no toggle.
    ///
    /// Both halves matter and they pull in opposite directions. The toggle stays
    /// absent because offering seat cooling on a car that may not have it is the
    /// schema's own prohibition; the LABEL stops denying because "SEAT HEATING" is
    /// a sentence about the hardware. That separation is the whole fix — the
    /// header had been carrying the value.
    func testUnknownCapabilityRendersTheNeutralLabelAndNoToggle() {
        let supportsCool = SeatClimatePresentation.supportsCool(
            capability: .unknown, driverMode: .heat, passengerMode: .heat)
        XCTAssertFalse(supportsCool, "a control the car may not have must not be offered")

        let label = SeatClimatePresentation.sectionLabel(
            capability: .unknown, supportsCool: supportsCool)
        XCTAssertEqual(label, "SEATS")
        XCTAssertNotEqual(label, "SEAT HEATING", "the denial is exactly what MYR-441 removes")
    }

    /// A seat ACTIVELY reading cool still wins, even with the capability unknown —
    /// MYR-280's safety net is unchanged, and it is the one route by which an
    /// `.unknown` car reaches "SEAT CLIMATE" and a working toggle.
    func testAnActivelyCoolingSeatStillOverridesAnUnknownCapability() {
        let supportsCool = SeatClimatePresentation.supportsCool(
            capability: .unknown, driverMode: .cool, passengerMode: .heat)
        XCTAssertTrue(supportsCool)
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: .unknown, supportsCool: supportsCool),
            "SEAT CLIMATE",
            "a snowflake must never sit under a label that denies cooling"
        )
    }

    /// End-to-end through the shipping predicate: a vented car with BOTH seats off
    /// and no seat reading `.cool` must still offer the toggle. This is the exact
    /// combination that failed for the client — `supportsCool` used to see
    /// `seatVent: false` (the runtime flag) and neither mode `.cool`.
    func testVentedCarWithBothSeatsOffOffersCool() {
        let capability = SeatClimatePresentation.capability(
            seatCoolingCapable: nil, seatCoolerLeft: 0, seatCoolerRight: 0, seatVentEnabled: false
        )
        let supportsCool = SeatClimatePresentation.supportsCool(
            capability: capability, driverMode: .heat, passengerMode: .heat)
        XCTAssertTrue(
            supportsCool,
            "a car that emits seat-cooler telemetry HAS cooled seats even with both off"
        )
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: capability, supportsCool: supportsCool),
            "SEAT CLIMATE"
        )
    }

    func testSupportsCoolWhenASeatReadsCoolEvenWithoutVentFlag() {
        // The client's incoherence: a seat streaming a cool state on a car whose
        // vent flag is false must STILL offer the toggle (and read "SEAT CLIMATE"),
        // never a snowflake stranded under "SEAT HEATING".
        XCTAssertTrue(SeatClimatePresentation.supportsCool(
            capability: .heatOnly, driverMode: .cool, passengerMode: .heat))
        XCTAssertTrue(SeatClimatePresentation.supportsCool(
            capability: .heatOnly, driverMode: .heat, passengerMode: .cool))
    }

    func testHeatOnlyCarDoesNotSupportCool() {
        XCTAssertFalse(SeatClimatePresentation.supportsCool(
            capability: .heatOnly, driverMode: .heat, passengerMode: .heat))
    }

    func testSectionLabelIsHonest() {
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: .ventilated, supportsCool: true),
            "SEAT CLIMATE")
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: .heatOnly, supportsCool: false),
            "SEAT HEATING")
        XCTAssertEqual(
            SeatClimatePresentation.sectionLabel(capability: .unknown, supportsCool: false),
            "SEATS")
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
