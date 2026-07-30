import XCTest
import UIKit
import DesignSystem
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-342 — the owner's ride-share pause, both sides of it
//
// The owner flips a switch; a rider must stop being offered the car. This file
// asserts the two pure decisions in between — the availability PREDICATE and the
// CTA GATE — plus the resolver that decides which of two sources the owner's own
// toggle renders from, and the measurements behind the two copy choices.
//
// THE ONE RULE THAT GOVERNS EVERYTHING HERE, and the one most likely to be broken
// by a well-meaning refactor: `rideShareEnabled` is OPTIONAL on the wire and
// ABSENT MEANS ENABLED. Every predicate tests `== false` explicitly. `!= true`
// would be the natural spelling and would silently withdraw every car served by a
// pre-0.20.0 server — so the tolerant-decode assertions below are written against
// nil as carefully as against false.
final class RideSharePauseTests: XCTestCase {

    // MARK: - Fixtures

    private func summary(
        status: VehicleSummary.Status = .parked,
        hasActiveRide: Bool? = nil,
        rideShareEnabled: Bool? = nil
    ) -> VehicleSummary {
        VehicleSummary(
            vehicleId: "veh-1",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "2046",
            status: status,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-07-29T12:00:00Z",
            role: .owner,
            hasActiveRide: hasActiveRide,
            rideShareEnabled: rideShareEnabled
        )
    }

    // MARK: - 1. The predicate

    /// The core fact: an explicit `false` is a PAUSE, on a car that is otherwise
    /// perfectly bookable. This is the state no pre-MYR-342 field could express —
    /// the car is online, parked, idle and not in service, and it is still
    /// unavailable, because its owner said so.
    func testExplicitFalseIsPausedOnAnOtherwiseHealthyCar() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary(rideShareEnabled: false))
        XCTAssertEqual(member.unavailability, .paused)
        XCTAssertFalse(member.isRequestable)
        XCTAssertFalse(member.isAvailable)
        XCTAssertEqual(member.availabilityWord, FleetUnavailability.paused.word)
    }

    /// TOLERANT DECODE, and the assertion this whole feature fails safe on. An
    /// ABSENT key (a server predating contracts 0.20.0, or any row a build
    /// predates) is nil, and nil is ENABLED — never paused. A client that failed
    /// closed here would withdraw every car on every older deployment at once.
    func testAbsentAndTrueAreBothEnabledNeverPaused() {
        for value: Bool? in [nil, true] {
            let member = LiveFleetMemberMapping.fleetMember(from: summary(rideShareEnabled: value))
            XCTAssertNil(
                member.unavailability,
                "rideShareEnabled = \(String(describing: value)) must never read as paused"
            )
            XCTAssertTrue(member.isRequestable)
        }
        // Stated at the predicate level too, since that is where a refactor to
        // `!= true` would land.
        XCTAssertFalse(VehicleRideShare.isPaused(nil))
        XCTAssertFalse(VehicleRideShare.isPaused(true))
        XCTAssertTrue(VehicleRideShare.isPaused(false))
    }

    /// PRECEDENCE: paused outranks every vehicle-state reason. This is not
    /// cosmetic ordering — it is what keeps the CTA honest. `inService` and
    /// `offline` offer "Schedule instead"; a paused car refuses scheduled rides
    /// too (rest-api.md §7.18), so surfacing the vehicle-state reason on a car that
    /// is ALSO paused would route the rider into a flow the server will 409.
    func testPausedOutranksEveryVehicleStateReason() {
        for status: VehicleSummary.Status in [.inService, .offline, .parked, .charging, .driving] {
            let member = LiveFleetMemberMapping.fleetMember(
                from: summary(status: status, hasActiveRide: true, rideShareEnabled: false)
            )
            XCTAssertEqual(
                member.unavailability, .paused,
                "a paused car reads as paused even when \(status) / hasActiveRide would also apply"
            )
        }
    }

    /// The own-ride exception suppresses BUSY only — MYR-233's rule, unchanged —
    /// and must NOT suppress a pause. Busy is a fact about a ride the rider is
    /// already in (so their own ride takes precedence client-side); a pause is the
    /// owner's decision about the car, and it applies to everyone including a rider
    /// mid-ride. Suppressing it would offer a rider a second request against a car
    /// the server will refuse.
    func testOwnRideExceptionDoesNotSuppressAPause() {
        XCTAssertEqual(
            LiveFleetMemberMapping.unavailability(
                status: .parked, hasActiveRide: true, rideShareEnabled: false, riderOwnsActiveRide: true
            ),
            .paused,
            "the pause survives the own-ride exception — it is not about the rider's ride"
        )
        // And the MYR-233 behaviour it must not disturb: the same call WITHOUT a
        // pause still clears busy.
        XCTAssertNil(
            LiveFleetMemberMapping.unavailability(
                status: .parked, hasActiveRide: true, rideShareEnabled: nil, riderOwnsActiveRide: true
            )
        )
    }

    /// The read seam applies the exception exactly once
    /// (`SharedViewerState.resolvingOwnRide`), and it is scoped to `.busy` — so a
    /// paused member reaches it and passes straight through. Asserted through the
    /// `FleetMember` helper the seam calls, so a future widening of the exception
    /// trips here.
    func testClearingUnavailabilityIsNeverAppliedToAPause() {
        let paused = LiveFleetMemberMapping.fleetMember(from: summary(rideShareEnabled: false))
        XCTAssertNotEqual(
            paused.unavailability, .busy,
            "the read seam only clears `.busy`; a pause must not be able to masquerade as one"
        )
    }

    // MARK: - 2. The CTA gate

    /// A paused vehicle gates the instant CTA like every other unavailability...
    func testPausedGatesTheInstantCTA() {
        let gate = RideRequestCTAGate(unavailability: .paused, isScheduled: false)
        XCTAssertEqual(gate.reason, .paused)
        XCTAssertFalse(gate.allowsSubmit, "no instant request may be POSTed against a paused car")
    }

    /// ...but it does NOT offer "Schedule instead", and that is the deliberate
    /// deviation this issue documents. MYR-233's rule was "never a dead end — route
    /// the rider to scheduling", and for `busy`/`inService`/`offline` it still
    /// holds, because each of those ENDS on its own and the car will be back. A
    /// pause is open-ended, and the server refuses scheduled rides against a paused
    /// car on every layer (create, accept, and the reservation sweeper). Offering
    /// scheduling would be a worse dead end than none: the rider would fill in a
    /// pickup, a time, and a passenger, and be 409'd at the very end.
    func testPausedDoesNotOfferSchedulingWhileEveryOtherReasonStillDoes() {
        XCTAssertFalse(
            RideRequestCTAGate(unavailability: .paused, isScheduled: false).routesToScheduling,
            "scheduling is blocked server-side for a paused car — offering it would be a 409 with extra steps"
        )
        for reason: FleetUnavailability in [.busy, .inService, .offline] {
            XCTAssertTrue(
                RideRequestCTAGate(unavailability: reason, isScheduled: false).routesToScheduling,
                "\(reason.rawValue) keeps MYR-233's scheduling route — it ends on its own"
            )
        }
    }

    /// The SCHEDULED-draft exemption does not reach a pause either, for the same
    /// reason and on the server's own authority: §7.18 applies the pause to
    /// scheduled rides "on any layer", a stated deviation from the reservation
    /// exemption MYR-313 grants in-service/offline cars. A draft that already
    /// carries a schedule is therefore still gated against a paused car — and still
    /// offered no scheduling route, since it is already in one.
    func testScheduledDraftIsStillGatedAgainstAPausedCar() {
        let gate = RideRequestCTAGate(unavailability: .paused, isScheduled: true)
        XCTAssertEqual(gate.reason, .paused, "the scheduled exemption does not reach an owner's pause")
        XCTAssertFalse(gate.allowsSubmit)
        XCTAssertFalse(gate.routesToScheduling)

        // The MYR-233 exemption it must not disturb: the other three stay exempt.
        for reason: FleetUnavailability in [.busy, .inService, .offline] {
            let exempt = RideRequestCTAGate(unavailability: reason, isScheduled: true)
            XCTAssertNil(exempt.reason, "scheduled + \(reason.rawValue) stays exempt (MYR-233 / MYR-313)")
            XCTAssertTrue(exempt.allowsSubmit)
        }
    }

    /// The CTA AREA's three-way outcome, asserted as one table so no future edit
    /// can produce a fourth. `isGated` is what the view uses to render the helper
    /// text alone — the state that exists only for a pause.
    func testTheCTAAreaHasExactlyThreeOutcomes() {
        let available = RideRequestCTAGate(unavailability: nil, isScheduled: false)
        XCTAssertFalse(available.isGated)
        XCTAssertFalse(available.routesToScheduling)

        let busy = RideRequestCTAGate(unavailability: .busy, isScheduled: false)
        XCTAssertTrue(busy.isGated)
        XCTAssertTrue(busy.routesToScheduling)

        let paused = RideRequestCTAGate(unavailability: .paused, isScheduled: false)
        XCTAssertTrue(paused.isGated)
        XCTAssertFalse(paused.routesToScheduling, "helper text only — no button at all")
    }

    // MARK: - 3. The chip word (MYR-335 measurement)

    /// The MYR-335 geometry, hoisted out of the assertions so the arithmetic is
    /// stated once: the narrowest supported screen (375pt) less the 24pt page
    /// gutters, less the three 8pt gaps between four columns, over four, less the
    /// tile's own 13pt inner padding on each side.
    private static let fourColumnBudget: CGFloat = {
        let screen: CGFloat = 375
        let column = (screen - 24 * 2 - 8 * 3) / 4
        return column - 13 * 2
    }()

    /// THE CHIP WORD IS "Paused", and this test records BOTH the measurement and
    /// the part the measurement could not settle.
    ///
    /// THE MEASUREMENT (MYR-335): no caption may rely on the prototype's ellipsis
    /// fallback, measured at the four-column content width on the narrowest
    /// supported device — 49.75pt, the tightest budget any short status string in
    /// this app has to clear. `MRTMutedChip` renders at 11pt semibold.
    ///
    /// BOTH CANDIDATES CLEAR IT, which was not the expected outcome and is why the
    /// numbers are asserted rather than described: "Paused" measures 40.05pt and
    /// "Rides off" 48.88pt. So the budget is a GATE both pass, not a tiebreak — and
    /// the margin is the one thing it does say, because 0.87pt of headroom is one
    /// font-metrics revision or one longer localization away from failing, while
    /// 9.70pt is not.
    ///
    /// THE CHOICE, on the two grounds the measurement leaves open:
    ///   • ONE WORD FOR ONE STATE, ACROSS BOTH ROLES. The owner's own row reads
    ///     "Paused — ride requests are off". A rider seeing "Rides off" for the
    ///     state the owner set as "Paused" makes the two halves of one feature
    ///     describe themselves differently, which is how a support conversation
    ///     goes wrong.
    ///   • THIS CHIP SPEAKS IN SINGLE-STATE ADJECTIVES — "Busy", "Offline",
    ///     "In service". "Rides off" is a clause, and on a Review sheet that is
    ///     about ONE specific ride it can be read as "the ride is off", i.e.
    ///     cancelled. That is a genuinely wrong meaning, not merely a stylistic
    ///     mismatch.
    func testChipWordIsPausedAndBothCandidatesClearTheFourColumnBudget() {
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        XCTAssertEqual(FleetUnavailability.paused.word, "Paused")

        let chosen = width(of: FleetUnavailability.paused.word, font: font)
        let alternative = width(of: "Rides off", font: font)

        // The MYR-335 gate — both candidates pass it.
        XCTAssertLessThanOrEqual(chosen, Self.fourColumnBudget)
        XCTAssertLessThanOrEqual(
            alternative, Self.fourColumnBudget,
            "recorded deliberately: the budget did NOT rule out the alternative, so the choice rests on the grounds in the doc comment above, not on this number"
        )

        // ...and the margin, which is the part of the decision the number DOES
        // support. If a future edit ever makes the chosen word the tighter of the
        // two, this whole choice is worth re-opening rather than preserving.
        XCTAssertLessThan(
            chosen, alternative,
            "\"Paused\" must stay the roomier of the two candidates"
        )
    }

    /// The new word is safe in this chip BY CONSTRUCTION: it is narrower than the
    /// widest word the chip already ships.
    ///
    /// Note this is asserted against `In service` rather than against the
    /// four-column budget, and the reason is a real finding rather than a
    /// convenience: `In service` measures 52.88pt and OVERFLOWS that budget today,
    /// because `MRTMutedChip` on the Review vehicle row is not four-column
    /// geometry at all — it sits on a full-width row beside a 36pt avatar. Holding
    /// the chip to the tile budget would fail on shipping, working copy. What is
    /// genuinely load-bearing is that a NEW reason cannot widen the chip beyond
    /// what it has already been proven to hold.
    func testTheNewWordIsNarrowerThanTheWidestWordTheChipAlreadyShips() {
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let widestShipping = max(
            width(of: FleetUnavailability.busy.word, font: font),
            max(
                width(of: FleetUnavailability.inService.word, font: font),
                width(of: FleetUnavailability.offline.word, font: font)
            )
        )
        XCTAssertLessThanOrEqual(
            width(of: FleetUnavailability.paused.word, font: font), widestShipping,
            "a new unavailability reason must not widen a chip that already renders correctly"
        )
    }

    private func width(of text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - 4. The owner-side resolver

    /// Nothing committed → the SNAPSHOT is authoritative, and an absent snapshot
    /// value resolves to ON. This is the cold-launch path and the whole simulated
    /// path (both sides nil), which is why every drift-gate scene renders a switch
    /// that is on — the state the pre-MYR-342 app effectively had.
    func testUncommittedResolvesFromTheSnapshotAndAbsenceIsOn() {
        XCTAssertTrue(VehicleRideShare.resolvedEnabled(committed: true, isCommitted: false, snapshot: nil))
        XCTAssertTrue(VehicleRideShare.resolvedEnabled(committed: false, isCommitted: false, snapshot: nil))
        XCTAssertTrue(VehicleRideShare.resolvedEnabled(committed: true, isCommitted: false, snapshot: true))
        XCTAssertFalse(VehicleRideShare.resolvedEnabled(committed: true, isCommitted: false, snapshot: false))
    }

    /// A COMMITTED value outranks the snapshot — the MYR-316 defect avoided in
    /// advance. `rideShareEnabled` has no WebSocket delta, so after a successful
    /// write the snapshot still holds the OLD position for an unbounded time; a
    /// surface preferring it would show the owner's flip as if it had not happened.
    func testCommittedPauseOutranksAStaleSnapshotStillSayingEnabled() {
        XCTAssertFalse(
            VehicleRideShare.resolvedEnabled(committed: false, isCommitted: true, snapshot: true),
            "a just-committed pause must win over a snapshot that cannot yet know about it"
        )
        XCTAssertTrue(
            VehicleRideShare.resolvedEnabled(committed: true, isCommitted: true, snapshot: false),
            "and symmetrically for a resume"
        )
    }

    // MARK: - 5. The owner-side copy

    /// Both captions say what the position MEANS rather than restating the switch,
    /// and the paused half leads with the state word so the row scans at a glance.
    func testRowCopyStatesTheConsequenceInBothPositions() {
        XCTAssertEqual(VehicleRideShare.rowCaption(isEnabled: true), "Riders can request this car")
        XCTAssertEqual(VehicleRideShare.rowCaption(isEnabled: false), "Paused \u{2014} ride requests are off")
        XCTAssertEqual(VehicleRideShare.rowLabel, "Ride sharing")
    }

    /// The row's label + caption must fit the card without truncating, measured on
    /// the narrowest supported device against the sheet card's real inner width —
    /// the same discipline `VehicleServiceWindowTests` applies to the sibling row.
    ///
    /// The card is the screen less the 24pt page gutters less `SectionCard`'s own
    /// 16pt padding each side; the row additionally reserves the toggle's 51pt
    /// track plus the 12pt minimum gap beside it.
    func testRowCopyFitsTheCardWithoutTruncating() {
        let screen: CGFloat = 375
        let cardInner: CGFloat = screen - 24 * 2 - 16 * 2
        let textBudget: CGFloat = cardInner - MRTMetrics.toggleTrackWidth - 12

        let labelWidth = (VehicleRideShare.rowLabel as NSString)
            .size(withAttributes: [.font: UIFont.systemFont(ofSize: 13)]).width
        XCTAssertLessThanOrEqual(labelWidth, textBudget)

        for enabled in [true, false] {
            let caption = VehicleRideShare.rowCaption(isEnabled: enabled)
            let width = (caption as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 11)]).width
            XCTAssertLessThanOrEqual(width, textBudget, "\"\(caption)\" does not fit the card row")
        }
    }
}
