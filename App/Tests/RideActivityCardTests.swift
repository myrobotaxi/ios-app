import CoreLocation
import DesignSystem
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - What the redesigned Live Activity renders (MYR-398, r16 redesign v2)
//
// The four surfaces cannot be tested. `ActivityViewContext` needs a real Activity
// in a real host process with a real installed widget extension, so a SwiftUI
// assertion about the lock screen is not available at any price — which is exactly
// why `RideActivityCard.resolve` exists as a pure function and why every view takes
// its output rather than a content state. Everything below drives that function.
//
// ─────────────────────────────────────────────────────────────────────────────
// SECTION 1 IS `design/la/la-data.jsx`, ROW FOR ROW.
//
// That file's own header says "This mirrors RideActivityCopy on the client; every
// string here is a client-side string", which makes it the ANSWER KEY rather than
// an illustration. So the twelve rows are written out with the design's own
// fixtures — `Cybercab` / `Sansome & Clay` / `Duarte's Tavern` — and each asserts
// EVERY decision the four surfaces read: headline, second line, rail, chip word,
// chip tone, whether the tone dot pulses, and the compact island's trailing text.
//
// A row that renders differently from its entry in that table is a defect on THIS
// side. That is the whole point of writing them as literals: a helper that derived
// the expected value the same way the code does would agree with a wrong
// implementation.
// ─────────────────────────────────────────────────────────────────────────────
//
// Sections 2–7 are the rules the table cannot state as rows: the countdown's
// format, the honesty rules from rest-api.md §7.21.3 (which are UNCHANGED by the
// redesign and are the promises the server made on the strength of this client
// rendering them), staleness, and the monotone hold.

final class RideActivityCardTests: XCTestCase {

    // The design's own fixtures, so the expected strings below can be read straight
    // off `la-data.jsx`.
    private static let vehicle = "Cybercab"
    private static let pickup = "Sansome & Clay"
    private static let destination = "Duarte's Tavern"

    /// A fixed instant, and a `now` a known distance before it. 4.5 minutes out
    /// renders "4 min" and 17.5 renders "17 min" — the design's own two figures,
    /// reached through the truncation rule rather than by handing the formatter a
    /// whole number it cannot get wrong.
    private let eta = Date(timeIntervalSince1970: 1_785_535_200)

    private func state(
        _ status: LiveActivityRideStatus,
        eta etaSeconds: Int? = 1_785_535_200,
        vehicleName: String = vehicle,
        destination: String = RideActivityCardTests.destination,
        progress: Double? = nil
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            eta: etaSeconds,
            vehicleName: vehicleName,
            destination: destination,
            progress: progress
        )
    }

    /// Resolve a card at a FIXED moment.
    ///
    /// `now` defaults to 4.5 minutes before the fixture ETA, so a leg-one card
    /// renders the design's own "4 min" — through the truncation rule, rather than
    /// by handing the formatter a whole number it cannot get wrong.
    ///
    /// Passing `now` at all is the point: since the client's 2026-07-31 ruling the
    /// figure is derived ONCE, here, from the frame's own moment, so the whole card
    /// is a deterministic function of its inputs and the twelve rows can assert
    /// literal figures.
    private func card(
        _ status: LiveActivityRideStatus,
        eta etaSeconds: Int? = 1_785_535_200,
        progress: Double? = nil,
        pickupLabel: String? = pickup,
        destination: String = RideActivityCardTests.destination,
        vehicleName: String = vehicle,
        isStale: Bool = false,
        now: Date? = nil
    ) -> RideActivityCard {
        RideActivityCard.resolve(
            state: state(
                status,
                eta: etaSeconds,
                vehicleName: vehicleName,
                destination: destination,
                progress: progress
            ),
            pickupLabel: pickupLabel,
            isStale: isStale,
            now: now ?? eta.addingTimeInterval(-270)
        )
    }

    /// The two figures `la-data.jsx` prints, as values.
    private static let fourMinutes = RideActivityCountdown.Parts(value: "4", unit: "min")
    private static let seventeenMinutes = RideActivityCountdown.Parts(value: "17", unit: "min")

    /// Everything the four surfaces read, as one value, so a row can be asserted in
    /// one statement and a missing assertion is visible as a missing field.
    private struct Rendered: Equatable, CustomStringConvertible {
        var headline: RideActivityHeadline
        var secondLine: RideActivitySecondLine?
        var track: Double?
        var chipWord: String
        var tone: RideActivityTone
        var pulses: Bool
        var compact: RideActivityCompact

        var description: String {
            "headline=\(headline) second=\(String(describing: secondLine)) track=\(String(describing: track)) chip=\(chipWord) tone=\(tone) pulses=\(pulses) compact=\(compact)"
        }
    }

    private func rendered(_ card: RideActivityCard) -> Rendered {
        Rendered(
            headline: card.headline,
            secondLine: card.secondLine,
            track: card.track,
            chipWord: card.chipWord,
            tone: card.tone,
            pulses: card.pulsesToneDot,
            compact: card.compact
        )
    }

    // MARK: - 1. la-data.jsx, row for row

    func testRow01Requested() {
        // PROPOSED IN v1, FILLED IN BY THE BOARD (handoff §1 change 11). The chip
        // existed and the headline did not, so a status a push can legitimately
        // move an Activity backwards to had no line at all.
        //
        // NO RAIL. `requested` means nobody has accepted yet, so there is no leg to
        // be part-way along and the server sends no fraction.
        XCTAssertEqual(
            rendered(card(.requested, eta: nil)),
            Rendered(
                headline: .sentence("Cybercab is on its way to you"),
                secondLine: .pickup(Self.pickup),
                track: nil,
                chipWord: "Requested",
                tone: .pending,
                pulses: false,
                compact: .word("Sent")
            )
        )
    }

    func testRow02AcceptedWithAnETAAndProgress() {
        // THE HERO STATE. One type size across the headline, the unit carrying the
        // meaning so a duration can never be misread as a clock time.
        // The figure is la-data's own "4", RESOLVED ON THE CARD rather than left
        // as an instant for a view to re-derive — the client's 2026-07-31 ruling.
        XCTAssertEqual(
            rendered(card(.accepted, progress: 0.38)),
            Rendered(
                headline: .countdown(prefix: "Pick up in", figure: Self.fourMinutes),
                secondLine: .pickup(Self.pickup),
                track: 0.38,
                chipWord: "On the way",
                tone: .active,
                pulses: false,
                compact: .figure(Self.fourMinutes, isStale: false)
            )
        )
    }

    func testRow03AcceptedWithNoETA() {
        // Sentence headline, and NO RAIL AT ALL — never an empty one.
        XCTAssertEqual(
            rendered(card(.accepted, eta: nil)),
            Rendered(
                headline: .sentence("Cybercab is coming to pick you up"),
                secondLine: .pickup(Self.pickup),
                track: nil,
                chipWord: "On the way",
                tone: .active,
                pulses: false,
                compact: .word("Coming")
            )
        )
    }

    func testRow04Arrived() {
        // The rail is full on the SERVER's authority, not from an ETA — and this is
        // the one state whose tone dot pulses.
        XCTAssertEqual(
            rendered(card(.arrived, eta: nil, progress: 1)),
            Rendered(
                headline: .sentence("Cybercab is here"),
                secondLine: .pickup(Self.pickup),
                track: 1,
                chipWord: "Arrived",
                tone: .active,
                pulses: true,
                compact: .word("Here")
            )
        )
    }

    func testRow05EnRouteWithAnETA() {
        // The leg flip resets the rail to zero and swaps the second line from the
        // pickup to the destination — ONE place, in gold.
        XCTAssertEqual(
            rendered(card(.enroute, progress: 0.52, now: eta.addingTimeInterval(-1050))),
            Rendered(
                headline: .countdown(prefix: "Arriving in", figure: Self.seventeenMinutes),
                secondLine: .destination(Self.destination),
                track: 0.52,
                chipWord: "In ride",
                tone: .riding,
                pulses: false,
                compact: .figure(Self.seventeenMinutes, isStale: false)
            )
        )
    }

    func testRow06EnRouteWithNoETA() {
        XCTAssertEqual(
            rendered(card(.enroute, eta: nil, progress: 0.52)),
            Rendered(
                headline: .sentence("Cybercab is taking you there"),
                secondLine: .destination(Self.destination),
                track: 0.52,
                chipWord: "In ride",
                tone: .riding,
                pulses: false,
                compact: .word("Driving")
            )
        )
    }

    func testRow07Stale() {
        // FOUR THINGS CHANGE AND TWO DELIBERATELY DO NOT.
        //
        // The headline swaps to the state's own sentence; the chip becomes the
        // warning with a grey dot (board decision 2); the rail is kept and
        // DESATURATED by the view; the compact island keeps the last known FIGURE
        // rather than dropping to a word.
        //
        // The second line and the rail's FRACTION are unchanged — a pickup and a
        // destination are facts about the ride, and a fraction is a claim about the
        // past that does not rot while the pushes are away.
        XCTAssertEqual(
            rendered(card(
                .enroute,
                progress: 0.52,
                isStale: true,
                now: eta.addingTimeInterval(-1050)
            )),
            Rendered(
                headline: .sentence("Cybercab is taking you there"),
                secondLine: .destination(Self.destination),
                track: 0.52,
                chipWord: "Not updating",
                tone: .terminal,
                pulses: false,
                compact: .figure(Self.seventeenMinutes, isStale: true)
            )
        )
    }

    func testRow08Completed() {
        // The one ending where WHERE YOU ARE is the news, so it is the one ending
        // that names a place — in the headline, not on a second line.
        XCTAssertEqual(
            rendered(card(.completed, eta: nil, progress: 1)),
            Rendered(
                headline: .sentence("You've arrived at Duarte's Tavern"),
                secondLine: nil,
                track: 1,
                chipWord: "Dropped off",
                tone: .complete,
                pulses: false,
                compact: .word("Done")
            )
        )
    }

    func testRow09Declined() {
        XCTAssertEqual(
            rendered(card(.declined, eta: nil)),
            Rendered(
                headline: .sentence("Cybercab can't take this ride"),
                secondLine: nil,
                track: nil,
                chipWord: "Declined",
                tone: .terminal,
                pulses: false,
                compact: .word("Ended")
            )
        )
    }

    func testRow10Cancelled() {
        // SUBJECT-FREE, and the design says why: the rider may be the one who
        // cancelled, so a sentence that puts the car in the subject position blames
        // it for their own tap.
        let resolved = card(.cancelled, eta: nil)

        XCTAssertEqual(
            rendered(resolved),
            Rendered(
                headline: .sentence("This ride was cancelled"),
                secondLine: nil,
                track: nil,
                chipWord: "Cancelled",
                tone: .terminal,
                pulses: false,
                compact: .word("Ended")
            )
        )

        // The proof that "subject-free" is structural and not a coincidence of this
        // fixture's name: the sentence does not move when the car does.
        XCTAssertEqual(
            card(.cancelled, eta: nil, vehicleName: "Blue Whale").headline,
            .sentence("This ride was cancelled")
        )
    }

    func testRow11ReservationExpired() {
        XCTAssertEqual(
            rendered(card(.reservationExpired, eta: nil)),
            Rendered(
                headline: .sentence("Cybercab didn't make it in time"),
                secondLine: nil,
                track: nil,
                chipWord: "Reservation expired",
                tone: .terminal,
                pulses: false,
                compact: .word("Ended")
            )
        )
    }

    func testRow12UnknownStatus() {
        // PROPOSED IN v1, FILLED IN BY THE BOARD. The schema mandates tolerating a
        // member this build has never heard of; v1 rendered the bare vehicle name,
        // which is not a sentence and read as a truncated one.
        //
        // Every element that would ASSERT something withdraws: no countdown (the
        // status may not be a leg at all, so neither prefix is safe) and no second
        // line. The RAIL is the one thing that stays if the server sent a fraction —
        // that is the server's claim to make, and §7.21.3's "render both as given"
        // does not carve out statuses this build has not heard of.
        XCTAssertEqual(
            rendered(card(.unrecognized("boarding"), eta: nil, progress: 0.5)),
            Rendered(
                headline: .sentence("Cybercab ride in progress"),
                secondLine: nil,
                track: 0.5,
                chipWord: "Ride",
                tone: .terminal,
                pulses: false,
                compact: .word("Ride")
            )
        )
    }

    // MARK: - 2. The countdown format

    func testTheCountdownIsNEVERMMSS() {
        // §1 change 3, and the reason `Text(timerInterval:countsDown:)` cannot be
        // used as-is: it renders exactly the format the board removed. `4:12` after
        // "Pick up in" reads as a clock time.
        //
        // Swept across two hours a second at a time rather than spot-checked,
        // because "no colon" is a property of every figure this can ever print and a
        // handful of literals would not say so.
        let until = Date(timeIntervalSince1970: 1_785_535_200)
        for offset in stride(from: 0, through: 7200, by: 1) {
            let text = RideActivityCountdown
                .parts(until: until, now: until.addingTimeInterval(-Double(offset)))
                .text
            XCTAssertFalse(text.contains(":"), "\(text) at −\(offset)s")
            XCTAssertTrue(
                text.hasSuffix(" min") || text.hasSuffix(" s"),
                "the unit is never dropped — \(text) at −\(offset)s"
            )
        }
    }

    func testAboveAMinuteItSaysMinutesAndBelowItSaysSeconds() {
        let until = Date(timeIntervalSince1970: 1_785_535_200)
        func parts(_ secondsOut: Double) -> RideActivityCountdown.Parts {
            RideActivityCountdown.parts(until: until, now: until.addingTimeInterval(-secondsOut))
        }

        XCTAssertEqual(parts(3600), RideActivityCountdown.Parts(value: "60", unit: "min"))
        XCTAssertEqual(parts(1050), RideActivityCountdown.Parts(value: "17", unit: "min"))
        XCTAssertEqual(parts(270), RideActivityCountdown.Parts(value: "4", unit: "min"))
        // The boundary. 60s is the first figure that is a minute; 59.9 is the last
        // that is seconds. There is no gap and no overlap.
        XCTAssertEqual(parts(60), RideActivityCountdown.Parts(value: "1", unit: "min"))
        XCTAssertEqual(parts(59.9), RideActivityCountdown.Parts(value: "59", unit: "s"))
        XCTAssertEqual(parts(45), RideActivityCountdown.Parts(value: "45", unit: "s"))
        XCTAssertEqual(parts(1), RideActivityCountdown.Parts(value: "1", unit: "s"))
    }

    func testMinutesAreTRUNCATEDAndNeverRoundedUp() {
        // The handoff's own worked example settles this: §1 change 3 rewrites the
        // shipped `4:12` as `4 min`. Rounding up would print "5 min" over a car 4:12
        // away, and would make the minute→second handover jump BACKWARDS ("2 min" →
        // "1 min" → "59 s" across two seconds).
        let until = Date(timeIntervalSince1970: 1_785_535_200)
        func value(_ secondsOut: Double) -> String {
            RideActivityCountdown.parts(until: until, now: until.addingTimeInterval(-secondsOut)).value
        }

        XCTAssertEqual(value(252), "4", "4:12 is four minutes, which is what the board wrote")
        XCTAssertEqual(value(299), "4", "and it stays four for the whole of the fourth minute")
        XCTAssertEqual(value(300), "5")
    }

    func testTheFigureNeverGoesBackwardsAsTimeRunsForward() {
        // The property that catches a rounding rule with a discontinuity in it — a
        // countdown that ticks UP for one second reads as a broken widget, and a
        // ceiling at the minute boundary does exactly that.
        let until = Date(timeIntervalSince1970: 1_785_535_200)
        var previous = Int.max
        var previousUnit = "min"

        for offset in stride(from: 3600, through: 0, by: -1) {
            let parts = RideActivityCountdown
                .parts(until: until, now: until.addingTimeInterval(-Double(offset)))
            let value = Int(parts.value)!
            if parts.unit == previousUnit {
                XCTAssertLessThanOrEqual(value, previous, "at −\(offset)s")
            }
            previous = value
            previousUnit = parts.unit
        }
    }

    func testALapsedInstantClampsToZeroSecondsRatherThanGoingNegative() {
        // The card is repainted by pushes it does not control, so an ETA runs out
        // between them routinely. `0 s` holds the line's width and says "any moment
        // now" without inventing a word for it.
        let until = Date(timeIntervalSince1970: 1_785_535_200)
        XCTAssertEqual(
            RideActivityCountdown.parts(until: until, now: until),
            RideActivityCountdown.Parts(value: "0", unit: "s")
        )
        XCTAssertEqual(
            RideActivityCountdown.parts(until: until, now: until.addingTimeInterval(600)),
            RideActivityCountdown.Parts(value: "0", unit: "s")
        )
    }

    func testTheFigureIsHELDAndNothingInTheCardCanCountItDown() {
        // CLIENT DECISION, 2026-07-31, superseding the handoff's SwiftUI note 1:
        // *"We are pulling live data from Tesla ETA telemetry; counting down is
        // inaccurate."* The wire's `eta` is the CAR's own live navigation estimate,
        // so a phone decrementing it between pushes is showing an extrapolation of
        // the car's last answer dressed as its current one.
        //
        // The guard is STRUCTURAL, and this is what it looks like from the outside:
        // one content state resolved at two different moments gives two different
        // figures — the derivation happens ONCE, in `resolve` — and the resolved
        // card carries a FIGURE, not an instant, so no view downstream is able to
        // re-derive it a second later. `RideActivityHeadline.countdown` has no
        // `Date` in it at all, which is why this test can only be written this way.
        let sixMinutesOut = card(.accepted, now: eta.addingTimeInterval(-390))
        let oneMinuteOut = card(.accepted, now: eta.addingTimeInterval(-90))

        XCTAssertEqual(
            sixMinutesOut.headline,
            .countdown(prefix: "Pick up in", figure: .init(value: "6", unit: "min"))
        )
        XCTAssertEqual(
            oneMinuteOut.headline,
            .countdown(prefix: "Pick up in", figure: .init(value: "1", unit: "min"))
        )

        // The island holds the same figure the card does — one derivation, two
        // surfaces, so they can never print two different answers for one push.
        XCTAssertEqual(sixMinutesOut.compact, .figure(.init(value: "6", unit: "min"), isStale: false))
        XCTAssertEqual(oneMinuteOut.compact, .figure(.init(value: "1", unit: "min"), isStale: false))
    }

    func testASecondsFigureIsHeldTheSameWayAMinutesFigureIs() {
        // Under a minute the unit changes and nothing else does — there is no
        // "and now it ticks" arm below 60s, which would be the obvious place to
        // reintroduce the countdown by accident.
        XCTAssertEqual(
            card(.accepted, now: eta.addingTimeInterval(-45)).headline,
            .countdown(prefix: "Pick up in", figure: .init(value: "45", unit: "s"))
        )
    }

    // MARK: - 3. The second line is ONE place, never a pair

    func testTheSecondLineNamesOneEndAndDropsThePrefixAndTheTripLine() {
        // §1 change 10. v1 rendered "Meet at {pickup}" and "{Vehicle} → {Dest}";
        // both are gone. The proof is the STRING, since a second line that still
        // said "Meet at Sansome & Clay" would satisfy a case-only assertion.
        guard case .pickup(let leg1)? = card(.accepted).secondLine else {
            return XCTFail("leg one names the pickup")
        }
        XCTAssertEqual(leg1, "Sansome & Clay")
        XCTAssertFalse(leg1.contains("Meet at"))

        guard case .destination(let leg2)? = card(.enroute).secondLine else {
            return XCTFail("leg two names the destination")
        }
        XCTAssertEqual(leg2, "Duarte's Tavern")
        XCTAssertFalse(leg2.contains("→"))
        XCTAssertFalse(leg2.contains(Self.vehicle), "the vehicle name left this line with the arrow")
    }

    func testThePickupComesFromTheSTATICATTRIBUTESAndNotFromThePush() {
        // §7.21.3, "Why the 'Meet at {pickup}' line is NOT on the wire": the server
        // deliberately does not push it, because a pickup cannot change for the life
        // of a ride and the app already holds it. A client that expected it on the
        // content state would render no second line, forever, against a correct
        // server — and would look exactly like a server bug.
        //
        // The proof is that the line survives a content state carrying nothing but
        // the required keys, and disappears when only the ATTRIBUTE is missing.
        XCTAssertEqual(
            card(.accepted, eta: nil, progress: nil, destination: "").secondLine,
            .pickup(Self.pickup)
        )
        XCTAssertNil(card(.accepted, pickupLabel: nil).secondLine)
    }

    func testAPickupOrDestinationOfOnlySpacesRendersNoLineAtAll() {
        XCTAssertNil(card(.accepted, pickupLabel: "   ").secondLine)
        XCTAssertNil(card(.accepted, pickupLabel: "").secondLine)
        XCTAssertNil(card(.enroute, destination: "  ").secondLine)
    }

    func testEveryTerminalStateHasNoSecondLineWhateverTheWireCarries() {
        // MYR-172's reasoning, kept: a destination under "Cancelled" reads as a ride
        // still in progress. `completed` is the sharp one — it HAS a leg (the one it
        // ended on, which the full rail needs) and must still name no place on the
        // second line.
        for status in [
            LiveActivityRideStatus.completed, .declined, .cancelled,
            .reservationExpired, .unrecognized("boarding"),
        ] {
            XCTAssertNil(card(status).secondLine, status.rawValue)
        }
    }

    // MARK: - 4. The chip and the compact island are two vocabularies

    func testTheCompactWordIsShorterThanTheChipWordWhereverTheyDiffer() {
        // Board decision 1, and the defect it fixes: v1's compact island fell back
        // to the CHIP's word, which put "Reservation expired" into a slot that fits
        // "Ended". They are two tables now, and this is the property that says why.
        for status in LiveActivityRideStatus.allCases {
            let chip = RideActivityCopy.chipWord(for: status)
            let compact = RideActivityCopy.compactWord(for: status)
            XCTAssertLessThanOrEqual(
                compact.count, chip.count,
                "\(status.rawValue): the island's word may never be longer than the chip's"
            )
            XCTAssertFalse(
                compact.contains(" "),
                "\(status.rawValue): the compact island's text is ONE word — \(compact)"
            )
        }
    }

    func testTheFourEndingsCollapseToOneWordOnTheIsland() {
        // A rider glancing at the island wants to know the ride is over; which
        // flavour of over it was is the lock card's business, and it says so in a
        // whole sentence.
        for status in [
            LiveActivityRideStatus.declined, .cancelled, .reservationExpired,
        ] {
            XCTAssertEqual(RideActivityCopy.compactWord(for: status), "Ended", status.rawValue)
        }
        // …and `completed` does NOT, because it is the ending that went right.
        XCTAssertEqual(RideActivityCopy.compactWord(for: .completed), "Done")
    }

    func testEveryStatusResolvesToExactlyOneOfTheHandoffsFiveTones() {
        // §4's table is the whole palette and it has five rows. The TOKEN each tone
        // resolves to is asserted where the tokens live (`TokenTests
        // .testTheLiveActivityToneTokensAreTheHandoffsFive`) — the mapping itself is
        // in the widget process, which the app's test bundle cannot link.
        //
        // What is assertable here is the half that decides: every status names a
        // tone, and the five are distinct, so no two states can share a dot colour
        // by accident.
        XCTAssertEqual(Set(RideActivityTone.allCases).count, 5)

        let expected: [(LiveActivityRideStatus, RideActivityTone)] = [
            (.requested, .pending),
            (.accepted, .active),
            (.arrived, .active),
            (.enroute, .riding),
            (.completed, .complete),
            (.declined, .terminal),
            (.cancelled, .terminal),
            (.reservationExpired, .terminal),
            (.unrecognized("boarding"), .terminal),
        ]
        for (status, tone) in expected {
            XCTAssertEqual(card(status, eta: nil).tone, tone, status.rawValue)
        }
    }

    func testONLYArrivedPulses() {
        // The only animation on this card besides the rail's offset. Live Activities
        // are budget-limited, and `arrived` is the one state where something is
        // waiting for the RIDER rather than the other way round.
        for status in LiveActivityRideStatus.allCases {
            XCTAssertEqual(
                card(status, eta: nil, progress: 1).pulsesToneDot,
                status == .arrived,
                status.rawValue
            )
        }
    }

    func testAStaleArrivedDoesNotPulseBecauseMotionIsAClaimToBeLive() {
        XCTAssertFalse(card(.arrived, eta: nil, progress: 1, isStale: true).pulsesToneDot)
    }

    // MARK: - 5. Staleness

    func testStalenessSWAPSTheWholeHeadlineRatherThanFreezingTheTimer() {
        // Handoff SwiftUI note 1: "On stale, swap the whole headline to the sentence
        // — do not freeze the timer view." A frozen countdown looks identical to a
        // working one that has stopped ticking, and a dimmed "4 min" is still a
        // number a rider plans around.
        let stale = card(.enroute, progress: 0.52, isStale: true)
        XCTAssertEqual(stale.headline, .sentence("Cybercab is taking you there"))
        XCTAssertTrue(stale.isStale)
    }

    func testTheChipIsTheWarningAndTheGreyDotComesWithIt() {
        // Board decision 2. v1 left the chip saying "In ride" — the one place a
        // rider looks first, and the one place that was still confident.
        for status in [LiveActivityRideStatus.accepted, .arrived, .enroute, .requested] {
            let stale = card(status, isStale: true)
            XCTAssertEqual(stale.chipWord, "Not updating", status.rawValue)
            XCTAssertEqual(stale.tone, .terminal, status.rawValue)
        }
    }

    func testTheCompactIslandKEEPSTheLastFigureWhileTheCardGivesUpItsCountdown() {
        // The one place the island and the card disagree ON PURPOSE (§1 change 7).
        // The card has room to explain itself; the island has room for one thing,
        // and the last figure at 45% says more to a rider than a confident word.
        let stale = card(.enroute, progress: 0.52, isStale: true)
        XCTAssertEqual(stale.compact, .figure(Self.fourMinutes, isStale: true))

        // With no ETA there is no figure to keep, and the island falls to the word.
        XCTAssertEqual(card(.enroute, eta: nil, isStale: true).compact, .word("Driving"))
    }

    func testTheWordStaleNeverRendersAnywhereInTheMatrix() {
        // ActivityKit's vocabulary, not a rider's — the handoff is explicit that it
        // never appears. Swept over every string every surface can show.
        for status in LiveActivityRideStatus.allCases {
            for isStale in [false, true] {
                for etaValue in [nil, 1_785_535_200] as [Int?] {
                    let resolved = card(status, eta: etaValue, progress: 0.5, isStale: isStale)
                    var strings = [resolved.chipWord]
                    if case .sentence(let text) = resolved.headline { strings.append(text) }
                    if case .word(let word) = resolved.compact { strings.append(word) }
                    if case .pickup(let place)? = resolved.secondLine { strings.append(place) }
                    if case .destination(let place)? = resolved.secondLine { strings.append(place) }
                    strings.append(RideActivityCopy.staleNoticeWithoutAnInstant)

                    for text in strings {
                        XCTAssertFalse(
                            text.lowercased().contains("stale"),
                            "\(status.rawValue) stale=\(isStale) rendered \(text)"
                        )
                    }
                }
            }
        }
    }

    func testTheStaleNoticeHasNoInstantToDateItselfFromOnTodaysWire() {
        // See `RideActivityCopy.staleNotice(lastUpdate:formatter:)`. Nothing the
        // widget process holds is an UPDATE instant — `ActivityViewContext` exposes
        // no stale date, and the content state's only instant is the `eta`, which is
        // a FUTURE instant chosen BEFORE the update that carried it. Dating the
        // notice from it would OVERSTATE freshness on the one card whose entire job
        // is to admit it has none (v1 shipped exactly that, as "As of {eta} ago").
        //
        // So the resolver passes nil and the notice says the one true thing. The
        // `{t}` arm below is written and tested against the day the wire grows one.
        XCTAssertNil(card(.enroute, isStale: true).staleLastUpdate)
        XCTAssertEqual(
            RideActivityCopy.staleNotice(lastUpdate: nil) { _ in "4:02 PM" },
            "Waiting for an update"
        )
        XCTAssertEqual(
            RideActivityCopy.staleNotice(lastUpdate: eta) { _ in "4:02 PM" },
            "Last update 4:02 PM"
        )
    }

    // MARK: - 6. The honesty rules (rest-api.md §7.21.3) — unchanged by the redesign

    func testEveryStatusResolvesToTheLegTheContractSaysItIs() {
        XCTAssertEqual(RideActivityLeg.of(.requested), .pickup)
        XCTAssertEqual(RideActivityLeg.of(.accepted), .pickup)
        XCTAssertEqual(
            RideActivityLeg.of(.arrived),
            .pickup,
            """
            `arrived` is the END of leg one, not the start of leg two — the car is \
            at the kerb and the rider has not boarded. Reading it as leg two would \
            put its server-asserted progress of 1 on the DROP-OFF rail and tell a \
            rider who has not got in the car that they have arrived.
            """
        )
        XCTAssertEqual(RideActivityLeg.of(.enroute), .dropoff)
        XCTAssertEqual(RideActivityLeg.of(.completed), .dropoff)

        for status in [
            LiveActivityRideStatus.declined, .cancelled, .reservationExpired,
            .unrecognized("boarding"),
        ] {
            XCTAssertNil(RideActivityLeg.of(status), "\(status.rawValue) is not part-way along anything")
        }
    }

    func testAnAbsentProgressRendersNORAIL() {
        // THE GOVERNING RULE. §7.21.3: "an absent `progress` renders a TRACKLESS
        // card, a wrong one renders a LIE". `nil` must not become 0 anywhere on the
        // way to the view, because 0 is the claim "the car has covered none of the
        // distance" and the view has no way to tell the two apart.
        for status in LiveActivityRideStatus.allCases {
            XCTAssertNil(card(status, progress: nil).track, "\(status.rawValue) with no progress key")
        }
    }

    func testZeroIsARealRailAtZeroAndNotConfusedWithAbsence() {
        let zero = card(.accepted, progress: 0)
        XCTAssertEqual(zero.track, 0)
        XCTAssertNotNil(zero.track)
    }

    func testTheEndsAreNOTCLAMPEDAWAYTheWayTheDesignSystemBarClampsThem() {
        // `TripProgressBar.clamped` floors at 0.05 and ceils at 0.95, which is right
        // for an illustrated bar and wrong for a claim about a car: `arrived` and
        // `completed` send exactly `1` on the ride record's authority, and a rail
        // that stopped just short would contradict the card's own headline — and
        // would park the arrow's disc off the end cap, which IS the arrival beat.
        XCTAssertEqual(card(.arrived, eta: nil, progress: 1).track, 1)
        XCTAssertEqual(card(.completed, eta: nil, progress: 1).track, 1)
        XCTAssertEqual(card(.accepted, progress: 0.02).track, 0.02, "and no 0.05 floor either")
    }

    func testAnOutOfRangeFractionIsClampedIntoZeroToOneRatherThanDrawnOffTheRail() {
        XCTAssertEqual(card(.enroute, progress: 1.4).track, 1)
        XCTAssertEqual(card(.enroute, progress: -0.2).track, 0)
    }

    func testTheGenericVehicleNameReachesEverySentenceRatherThanABlank() {
        XCTAssertEqual(
            card(.arrived, eta: nil, vehicleName: "   ").headline,
            .sentence("\(RideActivityCopy.genericVehicleName) is here")
        )
        XCTAssertEqual(
            card(.requested, eta: nil, vehicleName: "").headline,
            .sentence("\(RideActivityCopy.genericVehicleName) is on its way to you")
        )
    }

    func testCompletedDegradesToTheUnplacedSentenceWhenTheWireCarriesNoDestination() {
        XCTAssertEqual(
            card(.completed, eta: nil, destination: "  ").headline,
            .sentence("You've arrived")
        )
    }

    // MARK: - 7. The full matrix, swept

    func testTheHeadlineIsNeverACountdownWithoutAnETAAndNeverASentenceWithOne() {
        // The one invariant that has to hold across the whole grid, stated as a
        // sweep rather than as thirty-six literals: a countdown appears if and only
        // if there is an instant to count to, the ride is still running, the card is
        // not stale, and the status belongs to a leg.
        for status in LiveActivityRideStatus.allCases {
            for etaValue in [nil, 1_785_535_200] as [Int?] {
                for stale in [false, true] {
                    for progress in [nil, 0.5] as [Double?] {
                        let resolved = card(status, eta: etaValue, progress: progress, isStale: stale)
                        let expectsCountdown = etaValue != nil
                            && !stale
                            && RideActivityCopy.showsCountdown(for: status)
                            && RideActivityLeg.of(status) != nil

                        switch resolved.headline {
                        case .countdown:
                            XCTAssertTrue(expectsCountdown, "\(status.rawValue) eta=\(String(describing: etaValue)) stale=\(stale)")
                        case .sentence(let text):
                            XCTAssertFalse(expectsCountdown, "\(status.rawValue) eta=\(String(describing: etaValue)) stale=\(stale)")
                            XCTAssertFalse(text.isEmpty, "a headline is never blank")
                        }

                        // The rail's presence is a pure function of the progress
                        // key, independent of every other axis.
                        XCTAssertEqual(
                            resolved.track != nil, progress != nil,
                            "the rail's presence must depend on the progress key and nothing else"
                        )

                        // And the chip always has a word, whatever else is missing.
                        XCTAssertFalse(resolved.chipWord.isEmpty, status.rawValue)
                    }
                }
            }
        }
    }

    func testTheCompactIslandAlwaysHasSomethingToSay() {
        // The island's trailing slot is never empty and never a dash — a figure when
        // there is one (stale or not), a word otherwise.
        for status in LiveActivityRideStatus.allCases {
            for etaValue in [nil, 1_785_535_200] as [Int?] {
                for stale in [false, true] {
                    switch card(status, eta: etaValue, isStale: stale).compact {
                    case .figure(let figure, let isStale):
                        XCTAssertFalse(figure.text.isEmpty)
                        XCTAssertNotNil(etaValue)
                        XCTAssertTrue(RideActivityCopy.showsCountdown(for: status))
                        XCTAssertEqual(isStale, stale)
                    case .word(let word):
                        XCTAssertFalse(word.isEmpty, status.rawValue)
                    }
                }
            }
        }
    }

    // MARK: - 8. The monotone hold and the leg reset (unchanged)

    func testWithinOneLegTheFractionNeverGoesDOWN() {
        // The server clamps, so this is the client's belt-and-braces on the frames
        // IT composes. An arrow sliding back down the rail reads as a broken widget
        // rather than as traffic.
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.41, currentLeg: .dropoff, previous: 0.62, previousLeg: .dropoff),
            0.62
        )
    }

    func testWithinOneLegAHigherFractionIsAdopted() {
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.8, currentLeg: .dropoff, previous: 0.62, previousLeg: .dropoff),
            0.8
        )
    }

    func testWithinOneLegAMissingFractionCarriesTheLastOneFORWARD() {
        XCTAssertEqual(
            RideActivityProgress.held(current: nil, currentLeg: .pickup, previous: 0.34, previousLeg: .pickup),
            0.34
        )
    }

    func testTHELEGISTHERESETKEYAndNothingSurvivesTheFlip() {
        // Leg one ends at exactly 1 and leg two opens near 0, so a max taken ACROSS
        // the flip would pin the drop-off rail at full for the entire ride — the
        // single worst thing this rule could get wrong.
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.04, currentLeg: .dropoff, previous: 1, previousLeg: .pickup),
            0.04
        )
    }

    func testALegFlipWithNoFractionYETIsAnHonestNoRailAndNotAHeldFullOne() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: .dropoff, previous: 1, previousLeg: .pickup)
        )
    }

    func testALegThatBECOMESNilDropsTheFractionSoAnEndingCardCarriesNoRail() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: nil, previous: 0.62, previousLeg: .dropoff)
        )
    }

    func testTheFirstFrameOfAnActivityHoldsNothingBecauseThereIsNoPrevious() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: .pickup, previous: nil, previousLeg: nil)
        )
    }

    // MARK: - 9. The hold, through the shipping state machine (unchanged)

    func testTheStateMachineCarriesAPushedFractionForwardOntoItsOwnFrames() {
        let previous = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: Self.vehicle,
            destination: Self.destination,
            progress: 0.62
        )

        let next = RideActivityStateMachine.contentState(
            for: enrouteRecord,
            vehicleName: Self.vehicle,
            previous: previous
        )

        XCTAssertEqual(next.progress, 0.62)
        XCTAssertEqual(next.eta, 1_785_535_200, "the ETA carries forward for the same reason")
    }

    func testTheStateMachineNEVERINVENTSAFractionFromTheAppsOwnTrackProgress() {
        var record = enrouteRecord
        record.trackProgress = 0.8

        let frame = RideActivityStateMachine.contentState(
            for: record,
            vehicleName: Self.vehicle,
            previous: nil
        )

        XCTAssertNil(frame.progress)
    }

    func testTheCancelledEndingFrameDropsTheRailItInherited() {
        let live = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: Self.vehicle,
            destination: Self.destination,
            progress: 0.62
        )

        let ending = live.with(status: .cancelled)

        XCTAssertEqual(ending.status, .cancelled)
        XCTAssertNil(ending.progress, "no rail on the ending card")
        XCTAssertNil(
            RideActivityCard.resolve(state: ending, pickupLabel: Self.pickup, isStale: false).track
        )
    }

    // MARK: - Fixtures

    private var enrouteRecord: RideRequestRecord {
        var record = RideRequestRecord(
            id: "ride-1",
            input: RideRequestInput(
                pickup: RidePlace(
                    id: "pickup",
                    label: RideActivityCardTests.pickup,
                    subtitle: nil,
                    miles: 0,
                    minutes: 0,
                    icon: "location.fill",
                    coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
                ),
                destination: RidePlace(
                    id: "dest",
                    label: RideActivityCardTests.destination,
                    subtitle: nil,
                    miles: 4.2,
                    minutes: 12,
                    icon: "house.fill",
                    coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
                ),
                fleetMemberID: "vehicle-1"
            ),
            status: .enroute
        )
        record.status = .enroute
        return record
    }
}

private extension LiveActivityRideStatus {
    /// Every member this build knows, plus one it does not — the sweeps above have
    /// to cover the `unrecognized` arm, and a generated enum with an
    /// associated-value catch-all has no synthesized `CaseIterable`.
    static var allCases: [LiveActivityRideStatus] {
        [
            .requested, .accepted, .arrived, .enroute,
            .completed, .declined, .cancelled, .reservationExpired,
            .unrecognized("boarding"),
        ]
    }
}
