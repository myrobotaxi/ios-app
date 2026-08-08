import XCTest
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-385 — the schedule picker can see the conflict before the rider
// commits to it
//
// r15: *"Still letting me schedule for noon even though I already have a ride
// scheduled for that time."* The MYR-383 gate refuses that booking at SUBMIT; this
// is the read side (§7.22) that lets the picker dim the slot instead.
//
// Four things are pinned here, and each is a way the feature could have been
// wrong while looking right:
//
//  1. **THE EXCLUSIVE EDGES.** The gate compares strictly inside, so a slot at
//     exactly `start` or exactly `end` is ALLOWED. `<=` is the spelling a reader's
//     hand reaches for and it refuses bookings the server would have taken.
//  2. **THE HALF-WIDTH IS NOT KNOWN HERE.** §7.22 emits resolved endpoints
//     precisely so the ±45min product guess can move server-side with no client
//     release. Every window in this file is built from explicit instants, and one
//     test walks a deliberately WRONG half-width to prove nothing downstream
//     re-derives it.
//  3. **`own` / `pending` change the WORDS, never the availability.** A pending
//     claim blocks exactly as hard as a committed one (the create path counts them
//     in full) and an own window blocks exactly as hard as a stranger's.
//  4. **FAIL OPEN.** A failed read, an unparseable instant, a read for a different
//     vehicle and the whole simulated path all resolve to "no dimming", which is
//     the pre-MYR-385 picker exactly.
//
// Clock injection follows the file-local convention the rest of this suite uses
// (`RideScheduleDaysTests`, `VehicleServiceWindowTests`).
final class RideBookedWindowsTests: XCTestCase {

    private var calendar: Calendar { .current }

    private func date(_ components: DateComponents) -> Date {
        calendar.date(from: components)!
    }

    /// Saturday 2026-08-01, 06:00 local — BEFORE the first chip time (7:00 AM), so
    /// MYR-370's wall-clock rule dims nothing and every blocked slot in this file
    /// is blocked by a window. An 08:00 anchor silently costs "7:00 AM", "7:30 AM"
    /// and "8:00 AM" to the roll-forward rule, which is correct behaviour and the
    /// wrong subject for these assertions.
    private var saturdayMorning: Date {
        date(DateComponents(year: 2026, month: 8, day: 1, hour: 6, minute: 0))
    }

    private var times: [String] { RideScheduleTimes.grid }

    /// The instant the picker itself resolves a chip pair to — asked of the
    /// SHIPPING encoder, never re-derived, so a window built around it is provably
    /// around the slot under test.
    private func slot(_ day: String, _ time: String, now: Date) -> Date {
        RideRequestContractMapping.scheduledDate(
            from: RideSchedule(day: day, time: time), now: now, calendar: calendar
        )!
    }

    private func window(
        around instant: Date,
        halfWidth: TimeInterval = 45 * 60,
        pending: Bool = false,
        own: Bool = false
    ) -> RideBookedWindow {
        RideBookedWindow(
            start: instant.addingTimeInterval(-halfWidth),
            end: instant.addingTimeInterval(halfWidth),
            pending: pending,
            own: own
        )
    }

    // MARK: - The exclusive edges

    // §7.22, verbatim: "a reservation booked at exactly `start` or exactly `end` is
    // ALLOWED and the gate will accept it… A picker that dims the endpoints refuses
    // a slot the server would have taken." Two rides that touch at a boundary are a
    // legal back-to-back booking.
    func testASlotExactlyAtEitherEdgeIsAllowedAndOneStrictlyInsideIsNot() {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))
        let w = window(around: noon) // 11:15 … 12:45

        XCTAssertNil(RideBookedWindows.conflict(at: w.start, in: [w]), "exactly `start` is a legal booking")
        XCTAssertNil(RideBookedWindows.conflict(at: w.end, in: [w]), "exactly `end` is a legal booking")
        XCTAssertNotNil(RideBookedWindows.conflict(at: noon, in: [w]))
        XCTAssertNotNil(
            RideBookedWindows.conflict(at: w.start.addingTimeInterval(1), in: [w]),
            "one second inside is inside"
        )
        XCTAssertNil(RideBookedWindows.conflict(at: w.start.addingTimeInterval(-1), in: [w]))
        XCTAssertNil(RideBookedWindows.conflict(at: w.end.addingTimeInterval(1), in: [w]))
    }

    // The same rule seen from the GRID, which is where a rider meets it. A noon
    // reservation blocks everything strictly inside 11:15 … 12:45 and leaves the
    // two EDGES alone — and MYR-464's fifteen-minute grid is what finally puts
    // chips on those edges. On the old half-hour row 11:15 and 12:45 were not
    // slots at all, so the exclusive-interval rule was asserted over a grid too
    // coarse to contain a counter-example; now the boundary slots are real chips
    // and are asserted BOOKABLE, which is the sharper form of the same claim.
    func testANoonWindowTakesExactlyTheSlotsStrictlyInsideIt() {
        let now = saturdayMorning
        let noon = slot("Today", "12:00 PM", now: now)
        let windows = [window(around: noon)]

        let allowed = RideScheduleFloor.allowedTimes(
            on: "Today", times: times, floor: nil, windows: windows, now: now, calendar: calendar
        )
        let blocked = times.filter { !allowed.contains($0) }

        XCTAssertEqual(
            blocked,
            ["11:30 AM", "11:45 AM", "12:00 PM", "12:15 PM", "12:30 PM"]
        )
        // The two open ENDS of the ±45min interval, now that the grid has chips
        // on them. `<=` — the spelling a reader's hand reaches for — dims these
        // two and refuses bookings the server would have taken.
        XCTAssertTrue(allowed.contains("11:15 AM"), "exactly `start` is bookable")
        XCTAssertTrue(allowed.contains("12:45 PM"), "exactly `end` is bookable")
        XCTAssertTrue(allowed.contains("11:00 AM"))
        XCTAssertTrue(allowed.contains("1:00 PM"))
    }

    // MARK: - The half-width never crosses the wire

    // The dimming follows the EMITTED endpoints, whatever they are. Widen the
    // server's guess to three hours and more slots dim; narrow it to ten minutes
    // and fewer do — with not one line of this client changed. That is the property
    // §7.22's concrete-instants design buys, and a client that hard-coded 45 minutes
    // would fail this test on both arms.
    func testNothingInThisLayerKnowsTheHalfWidth() {
        let now = saturdayMorning
        let noon = slot("Today", "12:00 PM", now: now)

        let wide = RideScheduleFloor.allowedTimes(
            on: "Today", times: times, floor: nil,
            windows: [window(around: noon, halfWidth: 3 * 60 * 60)], now: now, calendar: calendar
        )
        let narrow = RideScheduleFloor.allowedTimes(
            on: "Today", times: times, floor: nil,
            windows: [window(around: noon, halfWidth: 10 * 60)], now: now, calendar: calendar
        )

        // ±3h is a six-hour interval, OPEN at both ends: 9 AM and 3 PM stay
        // bookable and the 23 slots between them do not. The number moved with
        // MYR-464's step and the RULE did not — which is the whole point of this
        // test, since a client that had hard-coded 45 minutes would answer the
        // same count on either grid.
        XCTAssertEqual(times.filter { !wide.contains($0) }.count, 23, "±3h over a 15-min grid")
        XCTAssertTrue(wide.contains("9:00 AM"), "exactly `start`")
        XCTAssertTrue(wide.contains("3:00 PM"), "exactly `end`")
        XCTAssertEqual(times.filter { !narrow.contains($0) }, ["12:00 PM"], "±10min touches only the slot itself")
    }

    // MARK: - `own` and `pending`

    // Both flags are PRESENTATIONAL. §7.22: a pending window "MUST be dimmed
    // exactly as hard as a committed one", and an own window "blocks a new booking
    // exactly as hard as anybody else's".
    func testEveryFlagCombinationBlocksTheSlotIdentically() {
        let now = saturdayMorning
        let noon = slot("Today", "12:00 PM", now: now)

        for pending in [true, false] {
            for own in [true, false] {
                XCTAssertFalse(
                    RideScheduleFloor.allows(
                        day: "Today", time: "12:00 PM", floor: nil,
                        windows: [window(around: noon, pending: pending, own: own)],
                        now: now, calendar: calendar
                    ),
                    "pending: \(pending), own: \(own) must dim exactly as hard"
                )
            }
        }
    }

    // The four sentences. `own` and `pending` are independent facts and each pair
    // is a genuinely different thing to say to the rider.
    func testTheCaptionNamesTheRightPartyAndTheRightCertainty() {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))

        XCTAssertEqual(
            RideBookedWindows.caption(vehicleName: "Lunar", conflict: window(around: noon, own: true)),
            "You already have a ride around this time"
        )
        XCTAssertEqual(
            RideBookedWindows.caption(vehicleName: "Lunar", conflict: window(around: noon, pending: true, own: true)),
            "You already have a ride requested around this time"
        )
        XCTAssertEqual(
            RideBookedWindows.caption(vehicleName: "Lunar", conflict: window(around: noon)),
            "Lunar is booked around this time"
        )
        XCTAssertEqual(
            RideBookedWindows.caption(vehicleName: "Lunar", conflict: window(around: noon, pending: true)),
            "Lunar is already requested around this time"
        )
    }

    // "BOOKED" IS RESERVED FOR A COMMITTED CLAIM. A rider told a slot is booked
    // when it is merely contested has been misinformed, and this whole surface
    // exists because the client asked for accuracy.
    func testAPendingClaimIsNeverCalledBooked() {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))
        for own in [true, false] {
            let copy = RideBookedWindows.caption(
                vehicleName: "Lunar", conflict: window(around: noon, pending: true, own: own)
            )
            XCTAssertFalse(try XCTUnwrap(copy).lowercased().contains("booked"))
            XCTAssertTrue(try XCTUnwrap(copy).lowercased().contains("requested"))
        }
    }

    // "AROUND", NOT "AT", IN ALL FOUR. The blocked interval is wider than the
    // occupying ride, and "at this time" would both be false and come as close as
    // copy can to leaking the half-width the contract keeps off the wire.
    func testNoCaptionClaimsTheOtherRideIsAtTheChosenTime() {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))
        for pending in [true, false] {
            for own in [true, false] {
                let copy = try? XCTUnwrap(
                    RideBookedWindows.caption(
                        vehicleName: "Lunar", conflict: window(around: noon, pending: pending, own: own)
                    )
                )
                XCTAssertTrue(try XCTUnwrap(copy).contains("around this time"))
            }
        }
    }

    // Nothing to say when nothing conflicts, and the two THEIRS arms need a name —
    // an empty one suppresses them rather than emitting " is booked around this
    // time" (the same guard `VehicleServiceWindow.schedulingCaption` makes). The
    // OWN arms need no name and are never suppressed: what they say is true of the
    // rider whatever the car is called.
    func testTheCaptionIsNilWithNoConflictAndTheOwnArmsSurviveANamelessVehicle() {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))

        XCTAssertNil(RideBookedWindows.caption(vehicleName: "Lunar", conflict: nil))
        XCTAssertNil(RideBookedWindows.caption(vehicleName: "   ", conflict: window(around: noon)))
        XCTAssertEqual(
            RideBookedWindows.caption(vehicleName: "   ", conflict: window(around: noon, own: true)),
            "You already have a ride around this time"
        )
    }

    // OVERLAP PRECEDENCE: the rider's OWN window wins the caption. Availability is
    // identical either way; "that car is booked" said to somebody looking at their
    // own reservation is the r15 report's failure mode restated as copy.
    func testWhenTwoWindowsCoverOneSlotTheRidersOwnIsTheOneNamed() {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))
        let theirs = window(around: noon, halfWidth: 60 * 60)
        let mine = window(around: noon, own: true)

        XCTAssertEqual(RideBookedWindows.conflict(at: noon, in: [theirs, mine]), mine)
        XCTAssertEqual(RideBookedWindows.conflict(at: noon, in: [mine, theirs]), mine)
    }

    // MARK: - The two rules in one grid

    // The service floor and the booked windows are DIFFERENT IN KIND — the floor is
    // a monotone bound, windows are scattered intervals with bookable gaps between
    // them — so folding windows into a "floor" would push the first bookable slot
    // past a perfectly free morning. Both are consulted, neither is expressed as
    // the other, and `firstAllowedSlot` lands on a slot that clears BOTH.
    func testTheFirstAllowedSlotClearsTheFloorAndTheWindowsAtOnce() {
        let now = saturdayMorning
        let floor = date(DateComponents(year: 2026, month: 8, day: 1, hour: 11, minute: 0))
        let windows = [window(around: slot("Today", "11:30 AM", now: now))] // 10:45 … 12:15
        let days = RideScheduleDays.days(now: now, calendar: calendar).map(\.token)

        let first = RideScheduleFloor.firstAllowedSlot(
            days: days, times: times, floor: floor, windows: windows, now: now, calendar: calendar
        )

        // The floor alone would have answered 11:00 AM; the window alone would have
        // answered 7:00 AM. Together the answer is the first slot past both — which
        // on MYR-464's fifteen-minute grid is 12:15, the window's own open END,
        // rather than the 12:30 the coarser row happened to land on. Same rule,
        // finer resolution, and a slot fifteen minutes earlier for the rider.
        XCTAssertEqual(first?.day, "Today")
        XCTAssertEqual(first?.time, "12:15 PM")
    }

    // A day is out only when EVERY one of its times is out. A day holding one noon
    // reservation still has a bookable morning and evening, so its chip stays lit —
    // the rule that matters far more for scattered windows than it did for a floor.
    func testADayWithABookedNoonStaysPickable() {
        let now = saturdayMorning
        let windows = [window(around: slot("Today", "12:00 PM", now: now))]
        let days = RideScheduleDays.days(now: now, calendar: calendar).map(\.token)

        let allowed = RideScheduleFloor.allowedDays(
            days, times: times, floor: nil, windows: windows, now: now, calendar: calendar
        )

        XCTAssertEqual(allowed, days, "no chip may be lost to a single reservation")
    }

    // MARK: - Fail open

    // The DEFAULT is what every pre-MYR-385 caller and test gets, and it must allow
    // everything. An empty list dims nothing — §7.22's own instruction for the
    // common case, and also the resting state of a read that failed.
    func testNoWindowsDimsNothing() {
        let now = saturdayMorning
        XCTAssertEqual(
            RideScheduleFloor.allowedTimes(on: "Today", times: times, floor: nil, now: now, calendar: calendar),
            RideScheduleFloor.allowedTimes(
                on: "Today", times: times, floor: nil, windows: [], now: now, calendar: calendar
            )
        )
        XCTAssertTrue(
            RideScheduleFloor.allows(
                day: "Today", time: "12:00 PM", floor: nil, windows: [], now: now, calendar: calendar
            )
        )
    }

    // A row that does not parse is DROPPED, never guessed at. Both directions of
    // that choice matter: a dropped window under-dims and the create-time 409
    // catches it, whereas a fabricated one dims a slot the server would have taken
    // and the rider has no recourse at all.
    func testAnUnparseableOrInvertedWindowIsDroppedRatherThanFabricated() {
        let response = VehicleBookedWindowsResponse(items: [
            BookedWindow(start: "not an instant", end: "2026-08-01T12:45:00Z", pending: false, own: false),
            BookedWindow(start: "2026-08-01T11:15:00Z", end: "nonsense", pending: false, own: false),
            // `end` before `start` — §7.22 guarantees this never happens; dropping
            // it says so rather than carrying a vacuous interval around.
            BookedWindow(start: "2026-08-01T12:45:00Z", end: "2026-08-01T11:15:00Z", pending: false, own: false),
            BookedWindow(start: "2026-08-01T18:15:00Z", end: "2026-08-01T19:45:00Z", pending: false, own: true)
        ])

        let windows = RideBookedWindowMapping.windows(from: response)

        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(try XCTUnwrap(windows.first).own)
    }

    // Both RFC 3339 shapes the backend emits — with and without fractional seconds
    // — parse, through the same `parseISO` pair every other wire instant in this
    // app uses.
    func testBothWireInstantShapesParse() {
        let plain = RideBookedWindowMapping.window(
            from: BookedWindow(start: "2026-08-01T11:15:00Z", end: "2026-08-01T12:45:00Z", pending: false, own: false)
        )
        let fractional = RideBookedWindowMapping.window(
            from: BookedWindow(
                start: "2026-08-01T11:15:00.000Z", end: "2026-08-01T12:45:00.000Z", pending: false, own: false
            )
        )

        XCTAssertEqual(plain, fractional)
    }

    // A cell whose day/time cannot be resolved at all conflicts with NOTHING. The
    // server is the authority on validity; a client that blocked slots it merely
    // failed to parse would shrink the picker for no stated reason.
    func testAnUnparseableCellIsAllowed() {
        let now = saturdayMorning
        let noon = slot("Today", "12:00 PM", now: now)
        XCTAssertTrue(
            RideScheduleFloor.allows(
                day: "Today", time: "half past noon", floor: nil,
                windows: [window(around: noon)], now: now, calendar: calendar
            )
        )
    }

    // MARK: - The store: coverage, refresh policy, and the SIM sweep

    /// Counts calls and can be made to fail — the only two behaviours the store's
    /// policy is defined against.
    private final class CountingWindows: RideBookedWindowsProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let windows: [RideBookedWindow]
        let failure: Error?

        init(windows: [RideBookedWindow] = [], failure: Error? = nil) {
            self.windows = windows
            self.failure = failure
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func windows(vehicleID: String, from: Date, to: Date) async throws -> [RideBookedWindow] {
            lock.lock(); calls += 1; lock.unlock()
            if let failure { throw failure }
            return windows
        }
    }

    /// Let the store's detached read land. It is fire-and-forget by design (nothing
    /// waits on it), so the tests have to.
    @MainActor
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    func testTheStorePublishesWhatItReadForTheVehicleItReadItFor() async {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))
        let provider = CountingWindows(windows: [window(around: noon, own: true)])
        let store = RideBookedWindowsStore(provider: provider)

        store.refresh(vehicleID: "veh_1", from: saturdayMorning, to: saturdayMorning.addingTimeInterval(86_400))
        await settle()

        XCTAssertEqual(store.windows(for: "veh_1").count, 1)
        // THE CROSS-VEHICLE GUARD. A draft re-pointed at another car must not be
        // dimmed by the first car's calendar, and asking by id is what makes that
        // structural rather than remembered.
        XCTAssertTrue(store.windows(for: "veh_2").isEmpty)
    }

    // A FAILED read publishes nothing, records no coverage, and leaves the picker
    // exactly as it was — no error state, no retry, no spinner. The server gate
    // backstops. The absent COVERAGE is the sharp part: adopting an empty result on
    // failure would say "checked, all clear" about a range nobody checked.
    @MainActor
    func testAFailedReadLeavesThePickerUnrestrictedAndClaimsNoCoverage() async {
        struct Boom: Error {}
        let provider = CountingWindows(failure: Boom())
        let store = RideBookedWindowsStore(provider: provider)
        let to = saturdayMorning.addingTimeInterval(86_400)

        store.refresh(vehicleID: "veh_1", from: saturdayMorning, to: to)
        await settle()

        XCTAssertTrue(store.windows(for: "veh_1").isEmpty)
        XCTAssertNil(store.coverage, "a failure must never be recorded as a clean range")

        // And because nothing was covered, the very next `ensureCovered` re-asks
        // rather than trusting a range that was never read.
        store.ensureCovered(vehicleID: "veh_1", from: saturdayMorning, to: to)
        await settle()
        XCTAssertEqual(provider.callCount, 2)
    }

    // `refresh` is UNCONDITIONAL (the picker opening; a 409) and `ensureCovered` is
    // not (a day-chip change). Windows appear and vanish between two openings and
    // the active-instant arm slides with the server's clock, so a cached answer
    // from the last time the card was up is exactly the stale thing to avoid.
    @MainActor
    func testRefreshAlwaysReadsWhileEnsureCoveredOnlyReadsOutsideWhatIsHeld() async {
        let provider = CountingWindows()
        let store = RideBookedWindowsStore(provider: provider)
        let from = saturdayMorning
        let to = from.addingTimeInterval(7 * 86_400)

        store.refresh(vehicleID: "veh_1", from: from, to: to)
        await settle()
        XCTAssertEqual(provider.callCount, 1)

        store.ensureCovered(vehicleID: "veh_1", from: from.addingTimeInterval(3600), to: to)
        await settle()
        XCTAssertEqual(provider.callCount, 1, "inside the held range — nothing to ask")

        store.ensureCovered(vehicleID: "veh_1", from: from, to: to.addingTimeInterval(86_400))
        await settle()
        XCTAssertEqual(provider.callCount, 2, "past the held range — re-ask")

        store.ensureCovered(vehicleID: "veh_2", from: from, to: to)
        await settle()
        XCTAssertEqual(provider.callCount, 3, "another vehicle is never covered by this one")

        store.refresh(vehicleID: "veh_2", from: from, to: to)
        await settle()
        XCTAssertEqual(provider.callCount, 4, "refresh does not consult coverage")
    }

    // THE SIM SWEEP, stated where it is structural. A simulated picker does not
    // decline to fetch — it has nothing to fetch WITH, because
    // `PlaceSearchComposition.Seams.simulated` carries no provider and the store
    // refuses to construct a read without one. That is what keeps every simulated
    // and DEBUG capture byte-identical with no `isLive` branch inside the card.
    @MainActor
    func testTheSimulatedPathCannotConstructTheReadAtAll() async {
        XCTAssertNil(
            PlaceSearchComposition.Seams.simulated.bookedWindows,
            "SIM has no bookings and no endpoint — inventing fixture windows would be a MYR-228 leak"
        )

        let viewer = SharedViewerState(seams: .simulated)
        XCTAssertFalse(viewer.bookedWindows.isEnabled)

        // Drive the two entry points the picker uses, and the state it reads.
        viewer.refreshBookedWindows()
        viewer.ensureBookedWindowsCovered()
        await settle()
        XCTAssertTrue(viewer.draftBookedWindows.isEmpty)
        XCTAssertNil(viewer.bookedWindows.coverage)
    }

    // `invalidate` returns the picker to its pre-MYR-385 behaviour, which is the
    // correct resting state for "we no longer know" — never a reason to block.
    @MainActor
    func testInvalidateDropsEverythingHeld() async {
        let noon = date(DateComponents(year: 2026, month: 8, day: 1, hour: 12, minute: 0))
        let store = RideBookedWindowsStore(provider: CountingWindows(windows: [window(around: noon)]))

        store.refresh(vehicleID: "veh_1", from: saturdayMorning, to: saturdayMorning.addingTimeInterval(86_400))
        await settle()
        XCTAssertFalse(store.windows(for: "veh_1").isEmpty)

        store.invalidate()
        XCTAssertTrue(store.windows(for: "veh_1").isEmpty)
        XCTAssertNil(store.coverage)
    }

    // MARK: - The request range

    // The range covers every chip in ONE request, starts at NOW (an active-instant
    // window straddles the present moment, and §7.22 returns anything OVERLAPPING
    // the range) and stays comfortably inside §7.22's 14-day cap — which is a
    // REFUSAL, not a clamp, so exceeding it would degrade the picker to unrestricted
    // rather than silently under-dim it.
    func testTheRangeCoversEveryChipInOneRequestAndFitsTheContractsCap() throws {
        let now = saturdayMorning
        let days = RideScheduleDays.days(now: now, calendar: calendar)
        let range = try XCTUnwrap(RideBookedWindowsRange.range(days: days, now: now, calendar: calendar))

        XCTAssertEqual(range.from, now)
        for day in days {
            let lastSlot = slot(day.token, "10:30 PM", now: now)
            XCTAssertLessThan(lastSlot, range.to, "\(day.token)'s last slot falls outside the fetched range")
        }
        XCTAssertLessThanOrEqual(range.to.timeIntervalSince(range.from), BookedWindowsRange.maximum)
    }

    func testAnEmptyChipRowAsksForNothing() {
        XCTAssertNil(RideBookedWindowsRange.range(days: [], now: saturdayMorning, calendar: calendar))
    }
}
