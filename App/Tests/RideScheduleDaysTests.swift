import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-370 — the day chips are generated, dated, and mean what they say
//
// The picker's day row was `["Today", "Tomorrow", "Thu", "Fri", "Sat", "Sun",
// "Mon"]`, a literal transcribed from the prototype. It is chronological on a
// TUESDAY and on no other day. These tests are anchored to the client's own
// moment — Thursday 2026-07-30, 22:09 — where the old list produced a duplicate
// weekday AND a row that jumped a week forward and six days back.
//
// Clock injection follows the file-local convention the rest of this suite uses
// (`VehicleServiceWindowTests`, `ScheduledForEncodingTests`): a `calendar`
// property and a `date(_:)` helper over `DateComponents`, threaded explicitly
// into every call as `now:` / `calendar:`.
final class RideScheduleDaysTests: XCTestCase {

    private var calendar: Calendar { .current }

    private func date(_ components: DateComponents) -> Date {
        calendar.date(from: components)!
    }

    /// THE CLIENT'S MOMENT: Thursday 2026-07-30, 22:09 local — late enough that
    /// today's whole slot grid (7:00 AM … 10:30 PM) has passed, which is the
    /// second half of what made the old row incoherent.
    private var thursdayNight: Date {
        date(DateComponents(year: 2026, month: 7, day: 30, hour: 22, minute: 9))
    }

    /// The same Thursday at 06:00, BEFORE the first slot — the anchor to use for
    /// any assertion that is about the service window rather than the wall clock.
    private var thursdayMorning: Date {
        date(DateComponents(year: 2026, month: 7, day: 30, hour: 6, minute: 0))
    }

    private var times: [String] { RideScheduleTimes.grid }

    private func days(_ now: Date) -> [RideScheduleDay] {
        RideScheduleDays.days(now: now, calendar: calendar)
    }

    private func tokens(_ now: Date) -> [String] {
        days(now).map(\.token)
    }

    // MARK: - 1. Chip generation

    func testTheRowIsTodayTomorrowThenExplicitlyDatedDays() {
        XCTAssertEqual(
            tokens(thursdayNight),
            ["Today", "Tomorrow", "Sat, Aug 1", "Sun, Aug 2", "Mon, Aug 3", "Tue, Aug 4", "Wed, Aug 5"],
            "the row is generated from the device clock, not transcribed from the prototype"
        )
    }

    /// The regression, stated as the literal it replaced. On this Thursday the
    /// old list repeated Today's weekday ("Thu") and Tomorrow's ("Fri").
    func testTheHardCodedPrototypeRowIsNoLongerWhatIsRendered() {
        let generated = tokens(thursdayNight)
        XCTAssertNotEqual(generated, RideRequestFixtures.scheduleDays)
        XCTAssertFalse(generated.contains("Thu"), "a bare weekday duplicating Today is the MYR-370 defect")
        XCTAssertFalse(generated.contains("Fri"), "a bare weekday duplicating Tomorrow is the MYR-370 defect")
    }

    /// No weekday may appear twice, on ANY starting weekday. A seven-day row over
    /// distinct calendar days cannot repeat one — the old list could, because its
    /// tokens were not derived from its dates.
    func testNoWeekdayIsEverDuplicatedWhicheverDayTheRowStartsOn() {
        for offset in 0..<7 {
            let now = calendar.date(byAdding: .day, value: offset, to: thursdayMorning)!
            let dates = days(now).map(\.date)
            XCTAssertEqual(Set(dates).count, dates.count, "duplicate calendar day starting +\(offset)d")
            XCTAssertEqual(Set(tokens(now)).count, 7, "duplicate token starting +\(offset)d")
        }
    }

    func testTheRowIsStrictlyChronological() {
        for offset in 0..<14 {
            let now = calendar.date(byAdding: .day, value: offset, to: thursdayMorning)!
            let dates = days(now).map(\.date)
            XCTAssertEqual(dates, dates.sorted(), "the row must be in date order starting +\(offset)d")
            for (earlier, later) in zip(dates, dates.dropFirst()) {
                XCTAssertLessThan(earlier, later, "strictly increasing, never a repeat")
            }
        }
    }

    /// Every chip past Tomorrow carries a DATE, not a bare weekday. This is the
    /// deliverable: "Thu" alone is what let one label mean two Thursdays.
    func testEveryChipBeyondTomorrowCarriesItsDate() {
        let generated = tokens(thursdayNight)
        XCTAssertEqual(generated[0], "Today")
        XCTAssertEqual(generated[1], "Tomorrow")
        for token in generated.dropFirst(2) {
            XCTAssertTrue(token.contains(","), "\(token) must carry a date, not a bare weekday")
            XCTAssertGreaterThan(token.count, 4, "\(token) is too short to carry a month and day")
        }
    }

    /// The chip's date grammar is the SAME one the caption above it uses, so
    /// "Lunar is in service until Sat, Aug 1 · 11:30 AM" and the "Sat, Aug 1"
    /// chip the rider matches it against are one format rather than two.
    func testTheChipDateGrammarMatchesTheServiceWindowCaption() {
        let aug1 = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        let caption = VehicleServiceWindow.completionLabel(for: aug1, now: thursdayNight, calendar: calendar)
        XCTAssertEqual(caption, "Sat, Aug 1 \u{00B7} 11:30 AM")
        XCTAssertTrue(tokens(thursdayNight).contains("Sat, Aug 1"))
    }

    // MARK: - 2. Tokens resolve back to their own date

    func testEveryGeneratedTokenResolvesBackToTheDayItNames() {
        for day in days(thursdayNight) {
            XCTAssertEqual(
                RideScheduleDays.dayStart(forToken: day.token, now: thursdayNight, calendar: calendar),
                day.date,
                "\(day.token) must resolve to the day it is printed for"
            )
        }
    }

    /// A dated token whose month/day has already passed this year belongs to
    /// NEXT year — the row read on Dec 30 runs into January.
    func testADatedTokenResolvesForwardAcrossTheNewYear() {
        let dec30 = date(DateComponents(year: 2026, month: 12, day: 30, hour: 6, minute: 0))
        let generated = days(dec30)
        XCTAssertEqual(generated.map(\.token).prefix(4), ["Today", "Tomorrow", "Fri, Jan 1", "Sat, Jan 2"])
        XCTAssertEqual(
            calendar.component(.year, from: generated[2].date), 2027,
            "Jan 1 read on Dec 30 2026 is 2027's"
        )
    }

    /// Legacy bare weekdays committed by an older build keep resolving through
    /// the existing weekday branch — this generator stops MINTING them, it does
    /// not stop understanding them.
    func testLegacyBareWeekdayTokensAreLeftToTheExistingWeekdayRule() {
        for legacy in ["Thu", "Fri", "Sat", "Sun", "Mon"] {
            XCTAssertNil(
                RideScheduleDays.dayStart(forToken: legacy, now: thursdayNight, calendar: calendar),
                "\(legacy) names no date and must fall through to the weekday branch"
            )
            XCTAssertNotNil(
                RideRequestContractMapping.scheduledDate(
                    from: RideSchedule(day: legacy, time: "7:00 AM"), now: thursdayNight, calendar: calendar
                ),
                "\(legacy) must still resolve — an in-flight schedule cannot become unreadable"
            )
        }
    }

    // MARK: - 3. THE INVARIANT — an offered slot lands on the day its chip names

    /// The whole point of the issue, as one sweep: for every day × time the
    /// picker OFFERS, the instant the create body would carry falls on that
    /// chip's own calendar date. Run at 22:09, where the old grid silently
    /// resolved "Today 7:00 AM" to tomorrow and "Thu 7:00 AM" to a week out.
    func testNoOfferedSlotEverResolvesOntoADifferentDayThanItsChip() {
        for floor in [nil, VehicleServiceWindow.earliestSelectable(
            serviceEstimatedEndAt: date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        )] {
            for day in days(thursdayNight) {
                for time in RideScheduleFloor.allowedTimes(
                    on: day.token, times: times, floor: floor, now: thursdayNight, calendar: calendar
                ) {
                    let instant = RideRequestContractMapping.scheduledDate(
                        from: RideSchedule(day: day.token, time: time),
                        now: thursdayNight, calendar: calendar
                    )
                    guard let resolved = instant else {
                        XCTFail("\(day.token) \(time) was offered but resolves to nothing")
                        continue
                    }
                    XCTAssertTrue(
                        calendar.isDate(resolved, inSameDayAs: day.date),
                        "\(day.token) \(time) was offered but resolves onto another day"
                    )
                    XCTAssertGreaterThan(
                        resolved, thursdayNight,
                        "\(day.token) \(time) was offered but is in the past"
                    )
                }
            }
        }
    }

    /// The past-slot half of that invariant, named — and with NO service window
    /// at all, so this is purely the wall clock.
    ///
    /// At 22:09 the picker's grid (7:00 AM … 10:45 PM) has three slots left on
    /// Today. Before MYR-370 every slot was offered, and tapping any of the ones
    /// that had gone booked TOMORROW at that hour under a chip reading "Today" —
    /// the same silent day-substitution "Thu" was making, one row up.
    ///
    /// MYR-464 widened the grid to fifteen minutes, so the survivors are three
    /// rather than one and the row now runs to 10:45 PM. The RULE is unchanged
    /// and is what this asserts: everything at or before the wall clock is gone,
    /// everything after it is offered.
    func testTodaysPastSlotsAreDroppedAndOnlyTheRemainingOnesAreOffered() {
        let remaining = RideScheduleFloor.allowedTimes(
            on: "Today", times: times, floor: nil, now: thursdayNight, calendar: calendar
        )
        XCTAssertEqual(
            remaining, ["10:15 PM", "10:30 PM", "10:45 PM"],
            "only the slots still ahead of 22:09 survive"
        )
        XCTAssertLessThan(remaining.count, times.count, "the morning is gone; it must not roll to tomorrow")

        let allowedDays = RideScheduleFloor.allowedDays(
            tokens(thursdayNight), times: times, floor: nil, now: thursdayNight, calendar: calendar
        )
        XCTAssertTrue(allowedDays.contains("Today"), "one bookable slot keeps the day alive")
        XCTAssertTrue(allowedDays.contains("Tomorrow"), "tomorrow is untouched — this drops past slots, not future ones")
        XCTAssertEqual(
            RideScheduleFloor.allowedTimes(on: "Tomorrow", times: times, floor: nil, now: thursdayNight, calendar: calendar),
            times,
            "every one of tomorrow's slots is still ahead"
        )
    }

    /// And once the grid IS wholly behind — 23:00, past the 10:30 PM last slot —
    /// the day drops out entirely rather than becoming tomorrow.
    func testTodayDropsOutEntirelyOnceItsWholeGridHasPassed() {
        let lateNight = date(DateComponents(year: 2026, month: 7, day: 30, hour: 23, minute: 0))
        XCTAssertTrue(
            RideScheduleFloor.allowedTimes(on: "Today", times: times, floor: nil, now: lateNight, calendar: calendar).isEmpty
        )
        XCTAssertFalse(
            RideScheduleFloor.allowedDays(tokens(lateNight), times: times, floor: nil, now: lateNight, calendar: calendar)
                .contains("Today")
        )
    }

    // MARK: - 4. Slot filtering against a service window

    /// FULL-DAY: a day entirely inside the window is disabled outright.
    func testADayEntirelyInsideTheWindowIsDisabled() {
        // Back Sat Aug 1 at 11:30 AM → floor 12:00 PM.
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)
        let allowed = RideScheduleFloor.allowedDays(
            tokens(thursdayMorning), times: times, floor: floor, now: thursdayMorning, calendar: calendar
        )

        XCTAssertFalse(allowed.contains("Today"), "Thu Jul 30 is wholly inside the window")
        XCTAssertFalse(allowed.contains("Tomorrow"), "Fri Jul 31 is wholly inside the window")
        XCTAssertTrue(allowed.contains("Sat, Aug 1"), "the boundary day survives — the car is back at lunchtime")
        XCTAssertTrue(allowed.contains("Sun, Aug 2"))
    }

    /// PARTIAL-DAY: the boundary day disables only the slots the window covers.
    func testTheBoundaryDayDisablesOnlyTheSlotsTheWindowCovers() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)

        let allowed = RideScheduleFloor.allowedTimes(
            on: "Sat, Aug 1", times: times, floor: floor, now: thursdayMorning, calendar: calendar
        )
        XCTAssertEqual(allowed.first, "12:00 PM", "11:30 AM + the 30-minute buffer lands on the 12:00 slot")
        XCTAssertFalse(allowed.contains("11:30 AM"), "the very minute the window closes is not offered")
        XCTAssertTrue(allowed.contains("10:30 PM"), "the rest of the day is untouched")

        for blocked in ["7:00 AM", "11:00 AM", "11:30 AM"] {
            XCTAssertFalse(RideScheduleFloor.allows(
                day: "Sat, Aug 1", time: blocked, floor: floor, now: thursdayMorning, calendar: calendar
            ), "\(blocked) is inside the window + buffer")
        }
    }

    /// ABSENT WINDOW: fail OPEN. This is the governing rule of the whole feature
    /// — a car with no service record (the common case) stays fully bookable.
    func testAnAbsentWindowBlocksNothing() {
        XCTAssertNil(VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: nil))

        let generated = tokens(thursdayMorning)
        XCTAssertEqual(
            RideScheduleFloor.allowedDays(generated, times: times, floor: nil, now: thursdayMorning, calendar: calendar),
            generated,
            "no window ⇒ every day open"
        )
        for day in generated {
            XCTAssertEqual(
                RideScheduleFloor.allowedTimes(on: day, times: times, floor: nil, now: thursdayMorning, calendar: calendar),
                times,
                "no window ⇒ every slot on \(day) open"
            )
        }
    }

    /// A STALE window — one whose estimate is already in the past — is likewise
    /// no constraint, because every slot the picker can express is after it.
    func testAStaleWindowConstrainsNothing() {
        let lastWeek = date(DateComponents(year: 2026, month: 7, day: 20, hour: 9, minute: 0))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: lastWeek)
        let generated = tokens(thursdayMorning)
        XCTAssertEqual(
            RideScheduleFloor.allowedDays(generated, times: times, floor: floor, now: thursdayMorning, calendar: calendar),
            generated
        )
    }

    /// The selection the card opens on when the rider's pick is out of reach.
    func testFirstAllowedSlotIsTheFirstBOOKABLECellInRowOrder() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)

        let slot = RideScheduleFloor.firstAllowedSlot(
            days: tokens(thursdayMorning), times: times, floor: floor, now: thursdayMorning, calendar: calendar
        )
        XCTAssertEqual(slot?.day, "Sat, Aug 1")
        XCTAssertEqual(slot?.time, "12:00 PM")
    }

    // MARK: - 5. The confirm-screen conflict copy

    func testAConflictedReservationGetsPlainCopyNamingBothInstants() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        let copy = RideScheduleConflict.copy(
            vehicleName: "Lunar",
            schedule: RideSchedule(day: "Sat, Aug 1", time: "7:00 AM"),
            serviceEstimatedEndAt: end,
            now: thursdayMorning,
            calendar: calendar
        )
        guard let line = copy else { return XCTFail("a conflicted reservation must say so") }
        XCTAssertTrue(line.contains("Sat, Aug 1 \u{00B7} 7:00 AM"), "it names the slot that is now unreachable")
        XCTAssertTrue(line.contains("Sat, Aug 1 \u{00B7} 11:30 AM"), "and the moment the car is back")
        XCTAssertTrue(line.contains("Lunar"))
    }

    func testAReservationThatStillClearsTheWindowGetsNoConflictCopy() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30))
        XCTAssertNil(RideScheduleConflict.copy(
            vehicleName: "Lunar",
            schedule: RideSchedule(day: "Sat, Aug 1", time: "12:00 PM"),
            serviceEstimatedEndAt: end,
            now: thursdayMorning,
            calendar: calendar
        ))
    }

    /// Fail OPEN on the confirm screen too: with no window there is no conflict
    /// to assert, and owner acceptance remains the real gate.
    func testNoWindowMeansNoConflictCopyEverAndNoScheduleMeansNoneEither() {
        XCTAssertNil(RideScheduleConflict.copy(
            vehicleName: "Lunar",
            schedule: RideSchedule(day: "Today", time: "7:00 AM"),
            serviceEstimatedEndAt: nil,
            now: thursdayMorning,
            calendar: calendar
        ))
        XCTAssertNil(RideScheduleConflict.copy(
            vehicleName: "Lunar",
            schedule: nil,
            serviceEstimatedEndAt: date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 30)),
            now: thursdayMorning,
            calendar: calendar
        ))
    }

    // MARK: - 6. The confirm phrase

    /// Every surface that quotes a slot goes through one composer, so none of
    /// them can print a day without its date.
    func testTheConfirmPhraseKeepsTheDayAndTheTimeSeparate() {
        XCTAssertEqual(
            RideScheduleDisplay.phrase(RideSchedule(day: "Sat, Aug 1", time: "12:00 PM")),
            "Sat, Aug 1 \u{00B7} 12:00 PM"
        )
        XCTAssertEqual(
            RideScheduleDisplay.phrase(day: "Today", time: "7:00 AM"),
            "Today \u{00B7} 7:00 AM"
        )
    }
}
