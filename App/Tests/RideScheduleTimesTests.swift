import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-464 — the schedule picker's time grid
//
// *"I can't schedule 7:45. Something is off in design here."* The row offered
// hours and half hours only, so the slot the tester wanted did not exist.
//
// The RESTORATION test is `testTheGridOffersQuarterHours`: it fails the moment
// the step goes back to thirty minutes, in the tester's own words.
//
// The rest pin the two properties a wider grid could quietly break. These strings
// are not decoration — the picker compares them for equality against a committed
// `RideSchedule.time` and `RideRequestContractMapping` encodes the chosen one into
// the create body — so every slot has to round-trip through the SHIPPING parser to
// the minute it names, and none of them may collide.
final class RideScheduleTimesTests: XCTestCase {

    private var calendar: Calendar { .current }

    // MARK: The client's report

    /// THE RESTORATION TEST. 7:45 PM is a slot, and so is every other quarter
    /// hour; on the half-hour grid this fails on the first assertion.
    func testTheGridOffersQuarterHours() {
        XCTAssertTrue(RideScheduleTimes.grid.contains("7:45 PM"), "the tester's own slot")
        XCTAssertTrue(RideScheduleTimes.grid.contains("7:15 PM"))
        XCTAssertTrue(RideScheduleTimes.grid.contains("7:15 AM"))
        XCTAssertTrue(RideScheduleTimes.grid.contains("12:45 PM"))
        XCTAssertEqual(RideScheduleTimes.stepMinutes, 15)
    }

    /// Every slot the half-hour grid used to mint is still in this one, which is
    /// what makes an older build's committed schedule select, render and encode
    /// unchanged — and is why no legacy table was kept.
    func testEveryHalfHourSlotSurvives() {
        for hour in RideScheduleTimes.firstHour...RideScheduleTimes.lastHour {
            for minute in [0, 30] {
                let legacy = RideScheduleTimes.label(hour24: hour, minute: minute)
                XCTAssertTrue(
                    RideScheduleTimes.grid.contains(legacy),
                    "\(legacy) was bookable before MYR-464 and must still be"
                )
            }
        }
    }

    // MARK: Shape

    func testTheRowSpansTheServiceDayAndNothingElse() {
        XCTAssertEqual(RideScheduleTimes.grid.first, "7:00 AM")
        XCTAssertEqual(RideScheduleTimes.grid.last, "10:45 PM")
        // 16 hours × 4 slots. Asserted as a NUMBER as well as as a formula, so a
        // change to either the hours or the step has to be stated twice.
        XCTAssertEqual(RideScheduleTimes.grid.count, 64)
        XCTAssertEqual(
            RideScheduleTimes.grid.count,
            (RideScheduleTimes.lastHour - RideScheduleTimes.firstHour + 1) * (60 / RideScheduleTimes.stepMinutes)
        )
    }

    /// A duplicate would be invisible in the row and fatal in the `ForEach`, whose
    /// `id` is the string itself — SwiftUI draws one chip per id, so the second
    /// copy would be counted and not drawn (`RiderScheduledRideMapping.rides`'
    /// own lesson, pointed at a picker).
    func testEverySlotIsUniqueAndOrdered() {
        XCTAssertEqual(Set(RideScheduleTimes.grid).count, RideScheduleTimes.grid.count)
        let minutes = RideScheduleTimes.grid.map { minutesOfDay($0) }
        XCTAssertEqual(minutes, minutes.sorted(), "the row is read left to right")
    }

    /// Midnight/noon are the two the 12-hour clock gets wrong, and only one of
    /// them is inside this row — so the rule is asserted through `label` directly
    /// as well as through the grid.
    func testTheMeridiemGrammarIsThePickersOwn() {
        XCTAssertEqual(RideScheduleTimes.label(hour24: 0, minute: 15), "12:15 AM")
        XCTAssertEqual(RideScheduleTimes.label(hour24: 12, minute: 0), "12:00 PM")
        XCTAssertEqual(RideScheduleTimes.label(hour24: 13, minute: 45), "1:45 PM")
        XCTAssertTrue(RideScheduleTimes.grid.contains("12:00 PM"))
        XCTAssertFalse(RideScheduleTimes.grid.contains("12:00 AM"), "outside the service day")
    }

    // MARK: The wire

    /// THE ONE THAT MATTERS FOR THE BACKEND. Every chip resolves through the
    /// SHIPPING encoder to the exact wall-clock minute it prints. A `:15`/`:45`
    /// slot that failed to parse would not throw — `scheduledDate` answers `nil`
    /// and `createBody` would send an INSTANT ride wearing a reservation's label,
    /// which is MYR-179's original defect.
    func testEverySlotRoundTripsThroughTheShippingEncoder() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 6))!
        for time in RideScheduleTimes.grid {
            guard let resolved = RideRequestContractMapping.scheduledDate(
                from: RideSchedule(day: "Tomorrow", time: time), now: now, calendar: calendar
            ) else {
                return XCTFail("\(time) did not resolve to an instant")
            }
            let parts = calendar.dateComponents([.hour, .minute], from: resolved)
            XCTAssertEqual(parts.hour! * 60 + parts.minute!, minutesOfDay(time), "\(time)")
        }
    }

    /// The row the picker renders is the row every grid predicate is asked about.
    /// A second list would let a chip be drawn that the CTA gate never considered.
    func testTheFloorPredicateSeesTheWholeRow() {
        XCTAssertEqual(
            RideScheduleFloor.allowedTimes(on: "Tomorrow", times: RideScheduleTimes.grid, floor: nil),
            RideScheduleTimes.grid,
            "with no floor and no windows every minted slot is bookable"
        )
    }

    private func minutesOfDay(_ time: String) -> Int {
        let parts = time.split(separator: " ")
        let clock = parts[0].split(separator: ":")
        var hour = Int(clock[0])! % 12
        if parts[1] == "PM" { hour += 12 }
        return hour * 60 + Int(clock[1])!
    }
}
