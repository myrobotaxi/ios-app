import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-179 — the rider's picked day/time becomes a REAL `scheduledFor`
//
// Before this issue `LiveRideRequestService.createBody` sent `scheduledFor: nil`
// with a "deferred" comment, so a "Sat 5:30 PM" reservation reached the server as
// an INSTANT ride (production check: every `go_ride_requests` row had
// `scheduled_for IS NULL`) and every scheduled exemption silently never applied.
//
// The resolution rule is deterministic and INJECTED (calendar + `now`), which is
// what makes it testable at all: the app's `RideSchedule` is a pair of display
// strings off the picker, and turning those into an instant depends entirely on
// the rider's clock and time zone. These tests pin every branch of that rule and
// the wire encoding it produces.
final class ScheduledForEncodingTests: XCTestCase {

    /// The rider's zone for the matrix — deliberately NOT UTC, so any accidental
    /// UTC-vs-local slip shows up as a 7-hour error rather than passing by luck.
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// A wall-clock instant in a given zone, built the long way round so the
    /// expectations never lean on the code under test.
    private func instant(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, zone: TimeZone) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = zone
        return calendar(zone).date(from: c)!
    }

    private func resolve(_ day: String, _ time: String, now: Date, zone: TimeZone = losAngeles) -> Date? {
        RideRequestContractMapping.scheduledDate(
            from: RideSchedule(day: day, time: time), now: now, calendar: calendar(zone))
    }

    // MARK: On-demand — the key stays absent

    /// A "Now" request carries NO schedule, so nothing is encoded and the create
    /// body omits the key entirely (rest-api.md §7.8) — unchanged behaviour, and
    /// the reason this can ship without touching the instant flow.
    func testOnDemandRequestEncodesNoScheduledFor() {
        XCTAssertNil(RideRequestContractMapping.scheduledFor(from: nil))
        let body = LiveRideRequestService.createBody(from: Self.input(schedule: nil), vehicleId: "veh-1")
        XCTAssertNil(body.scheduledFor, "an on-demand create must not carry a reservation time")
    }

    // MARK: "Today" — future time stays today, past time rolls

    /// The plain case: it's 9:00 AM and the rider picks 5:30 PM today. The
    /// reservation is TODAY's date at that wall clock, in the rider's own zone.
    func testTodayWithFutureTimeResolvesToTodayAtThatWallClock() {
        let now = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles) // Monday
        XCTAssertEqual(
            resolve("Today", "5:30 PM", now: now),
            instant(2026, 7, 27, 17, 30, zone: Self.losAngeles)
        )
    }

    /// It's 9:00 PM and the rider picks "Today 7:00 AM" — the picker offers the
    /// whole day regardless of the hour, so that instant is already gone. A
    /// reservation is never in the past: it rolls to the NEXT occurrence.
    func testTodayWithPastTimeRollsToTomorrow() {
        let now = instant(2026, 7, 27, 21, 0, zone: Self.losAngeles)
        XCTAssertEqual(
            resolve("Today", "7:00 AM", now: now),
            instant(2026, 7, 28, 7, 0, zone: Self.losAngeles)
        )
    }

    /// The boundary: the picked wall clock is exactly now. Treated as past (a
    /// reservation for this instant is not bookable) → next day.
    func testTodayAtExactlyNowRollsForward() {
        let now = instant(2026, 7, 27, 17, 30, zone: Self.losAngeles)
        XCTAssertEqual(
            resolve("Today", "5:30 PM", now: now),
            instant(2026, 7, 28, 17, 30, zone: Self.losAngeles)
        )
    }

    // MARK: "Tomorrow"

    func testTomorrowResolvesToTheNextCalendarDay() {
        let now = instant(2026, 7, 27, 21, 0, zone: Self.losAngeles)
        XCTAssertEqual(
            resolve("Tomorrow", "6:30 AM", now: now),
            instant(2026, 7, 28, 6, 30, zone: Self.losAngeles)
        )
    }

    // MARK: An EXPLICIT picked weekday

    /// The picker's day chips carry real weekdays ("Thu"/"Fri"/"Sat"…), and the
    /// client's own report was a Saturday 5:30 PM reservation. From Monday the
    /// 27th, "Sat" is the 1st.
    func testExplicitWeekdayResolvesToItsNextOccurrence() {
        let now = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles) // Monday
        XCTAssertEqual(
            resolve("Sat", "5:30 PM", now: now),
            instant(2026, 8, 1, 17, 30, zone: Self.losAngeles)
        )
    }

    /// Picking TODAY's own weekday, with the time still ahead, means today — not
    /// a week out. (Monday, 9 AM, "Mon 5:30 PM".)
    func testExplicitWeekdayMatchingTodayWithFutureTimeStaysToday() {
        let now = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles) // Monday
        XCTAssertEqual(
            resolve("Mon", "5:30 PM", now: now),
            instant(2026, 7, 27, 17, 30, zone: Self.losAngeles)
        )
    }

    /// …and picking today's weekday at a time already gone means NEXT week's, not
    /// tomorrow: the rider named a weekday, so the roll is a whole week.
    func testExplicitWeekdayMatchingTodayWithPastTimeRollsAWeek() {
        let now = instant(2026, 7, 27, 21, 0, zone: Self.losAngeles) // Monday evening
        XCTAssertEqual(
            resolve("Mon", "7:00 AM", now: now),
            instant(2026, 8, 3, 7, 0, zone: Self.losAngeles)
        )
    }

    /// Every day token the picker can produce resolves to a real future instant —
    /// no silent nil, and never a past reservation.
    func testEveryPickerDayTokenResolvesIntoTheFuture() {
        let now = instant(2026, 7, 27, 21, 0, zone: Self.losAngeles)
        for day in RideRequestFixtures.scheduleDays {
            for time in [RideScheduleTimes.grid.first!, RideScheduleTimes.grid.last!] {
                let resolved = resolve(day, time, now: now)
                XCTAssertNotNil(resolved, "\(day) \(time) must resolve")
                XCTAssertGreaterThan(resolved!, now, "\(day) \(time) must be in the future")
            }
        }
    }

    // MARK: Time-zone sanity

    /// The SAME picked wall clock is a DIFFERENT absolute instant for riders in
    /// different zones — which is the whole reason the resolution runs against the
    /// rider's calendar rather than UTC. Los Angeles 5:30 PM on 2026-07-27 is
    /// 00:30Z the next day; Tokyo 5:30 PM the same date is 08:30Z the same day.
    func testSameWallClockResolvesPerRiderTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let laNow = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles)
        let tokyoNow = instant(2026, 7, 27, 9, 0, zone: tokyo)

        let la = RideRequestContractMapping.scheduledFor(
            from: RideSchedule(day: "Today", time: "5:30 PM"), now: laNow, calendar: calendar(Self.losAngeles))
        let tk = RideRequestContractMapping.scheduledFor(
            from: RideSchedule(day: "Today", time: "5:30 PM"), now: tokyoNow, calendar: calendar(tokyo))

        XCTAssertEqual(la, "2026-07-28T00:30:00.000Z")
        XCTAssertEqual(tk, "2026-07-27T08:30:00.000Z")
    }

    // MARK: Wire encoding

    /// RFC 3339 UTC with milliseconds — byte-for-byte the shape the server emits
    /// ("2026-07-11T06:30:00.000Z"), so the value round-trips through the decode
    /// half (`schedule(from:)`) and the incoming card reads back the same clock.
    func testEncodesRFC3339UTCWithMilliseconds() throws {
        let now = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles)
        let encoded = try XCTUnwrap(RideRequestContractMapping.scheduledFor(
            from: RideSchedule(day: "Sat", time: "5:30 PM"), now: now, calendar: calendar(Self.losAngeles)))
        XCTAssertEqual(encoded, "2026-08-02T00:30:00.000Z") // Sat 1 Aug 17:30 PDT
        // …and the app's own parser reads it back to the identical instant.
        XCTAssertEqual(
            RideRequestContractMapping.parseISO(encoded),
            instant(2026, 8, 1, 17, 30, zone: Self.losAngeles)
        )
    }

    /// The decode half turns the encoded value back into the SAME clock the rider
    /// picked (the day label is relative, so only the time is asserted here) —
    /// proving the create the owner refetches narrates the reservation the rider
    /// actually made.
    func testEncodedValueRoundTripsToTheRidersClock() throws {
        let now = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles)
        let encoded = try XCTUnwrap(RideRequestContractMapping.scheduledFor(
            from: RideSchedule(day: "Tomorrow", time: "6:30 AM"), now: now, calendar: calendar(Self.losAngeles)))
        let decoded = try XCTUnwrap(RideRequestContractMapping.schedule(from: encoded))
        // `schedule(from:)` formats in the DEVICE zone; assert against the same
        // instant formatted the same way rather than a hardcoded "6:30 AM".
        let expected = DateFormatter()
        expected.locale = Locale(identifier: "en_US_POSIX")
        expected.dateFormat = "h:mm a"
        XCTAssertEqual(decoded.time, expected.string(from: instant(2026, 7, 28, 6, 30, zone: Self.losAngeles)))
    }

    /// An unparseable clock never fabricates a reservation time — the create
    /// degrades to on-demand rather than booking a wrong instant.
    func testUnparseableTimeEncodesNothing() {
        XCTAssertNil(RideRequestContractMapping.scheduledFor(from: RideSchedule(day: "Today", time: "later")))
    }

    // MARK: The create body carries it

    /// The end of the chain: a scheduled draft produces a create body whose
    /// `scheduledFor` is the resolved instant — the one line MYR-179 says was
    /// missing. The rest of the body is unchanged.
    func testCreateBodyCarriesTheResolvedReservationInstant() throws {
        let now = instant(2026, 7, 27, 9, 0, zone: Self.losAngeles)
        let body = LiveRideRequestService.createBody(
            from: Self.input(schedule: RideSchedule(day: "Sat", time: "5:30 PM")),
            vehicleId: "veh-live",
            now: now,
            calendar: calendar(Self.losAngeles)
        )
        XCTAssertEqual(body.scheduledFor, "2026-08-02T00:30:00.000Z")
        XCTAssertEqual(body.vehicleId, "veh-live")
        XCTAssertEqual(body.pickup.label, "1200 Grandscape Blvd")
        XCTAssertEqual(body.dropoff.label, "Bell Southstone Yards")
    }

    // MARK: - Builders

    private static func input(schedule: RideSchedule?) -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(id: "pin", label: "1200 Grandscape Blvd", subtitle: nil, miles: 0, minutes: 0,
                              icon: "mappin", coordinate: CLLocationCoordinate2D(latitude: 33.09, longitude: -96.85)),
            destination: RidePlace(id: "live|bell", label: "Bell Southstone Yards", subtitle: nil, miles: 5.4,
                                   minutes: 16, icon: "mappin",
                                   coordinate: CLLocationCoordinate2D(latitude: 33.15, longitude: -96.82)),
            fleetMemberID: "veh-live",
            schedule: schedule
        )
    }
}
