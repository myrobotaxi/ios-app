import XCTest
import MyRobotaxiContracts
@testable import MyRoboTaxi

/// MYR-316 — the service window's three pure decision layers, asserted as
/// matrices against an INJECTED clock: the owner's display formatter, the owner's
/// entry validation, and the rider's scheduling floor. Plus the two mapping seams
/// that feed them (`VehicleContractMapping.snapshot`, `LiveFleetMemberMapping`).
///
/// The single behaviour every one of these matrices is really guarding: `nil`
/// means NO WINDOW KNOWN — render nothing, floor nothing — because an absent
/// estimate is the COMMON case (Tesla holds no appointment record for most
/// service visits) and treating it as an error would make those cars unbookable.
final class VehicleServiceWindowTests: XCTestCase {

    /// A fixed reference clock so "same day" / "other day" are decidable.
    /// Wednesday 2026-07-29, 06:00 local — deliberately BEFORE the picker's first
    /// slot (7:00 AM), because `RideRequestContractMapping.scheduledDate` rolls a
    /// "Today" token whose wall clock has already passed forward to TOMORROW
    /// ("a reservation is never in the past", MYR-179). Anchoring the matrix
    /// before the first slot keeps "Today" meaning today, so the floor assertions
    /// below test the floor rather than that pre-existing roll-over. The roll-over
    /// itself is still covered: `testAnAllowedSlotResolvesToAnInstantAtOrAfterThe
    /// Floor` checks the RESOLVED instant of every offered cell, whichever day the
    /// token actually lands on.
    private var calendar: Calendar { .current }

    private func date(_ components: DateComponents) -> Date {
        calendar.date(from: components)!
    }

    private var now: Date {
        date(DateComponents(year: 2026, month: 7, day: 29, hour: 6, minute: 0))
    }

    // MARK: - 1. Display formatter matrix

    func testCompletionLabelIsNilWhenNoWindowIsKnown() {
        XCTAssertNil(
            VehicleServiceWindow.completionLabel(for: nil, now: now, calendar: calendar),
            "an absent estimate renders NOTHING — never a placeholder, never 'unknown'"
        )
    }

    func testCompletionLabelSameDayIsTimeOnly() {
        let end = date(DateComponents(year: 2026, month: 7, day: 29, hour: 14, minute: 0))
        XCTAssertEqual(
            VehicleServiceWindow.completionLabel(for: end, now: now, calendar: calendar), "~2:00 PM"
        )
    }

    func testCompletionLabelOtherDayCarriesTheWeekday() {
        // Saturday 2026-08-01.
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 0))
        XCTAssertEqual(
            VehicleServiceWindow.completionLabel(for: end, now: now, calendar: calendar), "Sat ~2:00 PM"
        )
    }

    /// A same-day estimate that has already passed still renders as a time — the
    /// server, not the client, decides when a window stops being true (it clears
    /// the field on the status change), and inventing a "should have been back"
    /// state here would be the client guessing at the car's reality.
    func testCompletionLabelForAPastSameDayInstantStillFormats() {
        let end = date(DateComponents(year: 2026, month: 7, day: 29, hour: 5, minute: 30))
        XCTAssertEqual(
            VehicleServiceWindow.completionLabel(for: end, now: now, calendar: calendar), "~5:30 AM"
        )
    }

    // MARK: - Display line gating (status + value)

    func testCompletionLineRequiresBothInServiceAndAValue() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 0))

        XCTAssertEqual(
            VehicleServiceWindow.completionLine(for: end, isInService: true, now: now, calendar: calendar),
            "Estimated completion \u{00B7} Sat ~2:00 PM"
        )
        XCTAssertNil(
            VehicleServiceWindow.completionLine(for: end, isInService: false, now: now, calendar: calendar),
            "a car that has LEFT service must not keep a completion time on screen"
        )
        XCTAssertNil(
            VehicleServiceWindow.completionLine(for: nil, isInService: true, now: now, calendar: calendar),
            "in service with no known estimate is the COMMON case and renders nothing"
        )
    }

    // MARK: - 2. Owner entry validation (mirrors the server's rule exactly)

    func testIsEnterableAcceptsTheFutureAndRejectsThePastAndNow() {
        XCTAssertTrue(VehicleServiceWindow.isEnterable(now.addingTimeInterval(60), now: now))
        XCTAssertFalse(VehicleServiceWindow.isEnterable(now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(
            VehicleServiceWindow.isEnterable(now, now: now),
            "'now' is not the future — the server's boundary is strict, and so is ours"
        )
    }

    // MARK: - 3. Scheduling floor matrix

    func testNilWindowProducesNoFloorAndBlocksNothing() {
        XCTAssertNil(
            VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: nil),
            "an unknown window leaves scheduling FULLY OPEN (the contract's own consumer rule)"
        )
        XCTAssertTrue(VehicleServiceWindow.allows(now, floor: nil))
        XCTAssertTrue(VehicleServiceWindow.allows(now.addingTimeInterval(-99_999), floor: nil))
    }

    func testFloorIsTheEstimatePlusTheBuffer() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 0))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)
        XCTAssertEqual(floor, end.addingTimeInterval(15 * 60))
        XCTAssertEqual(VehicleServiceWindow.schedulingBuffer, 15 * 60)
    }

    /// The boundary is INCLUSIVE: the floor names the first bookable moment, not
    /// the last blocked one. An off-by-one here would silently drop a legal slot.
    func testFloorBoundaryIsInclusive() {
        let end = date(DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 0))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)!

        XCTAssertTrue(VehicleServiceWindow.allows(floor, floor: floor), "the floor instant itself is bookable")
        XCTAssertFalse(VehicleServiceWindow.allows(floor.addingTimeInterval(-1), floor: floor))
        XCTAssertTrue(VehicleServiceWindow.allows(floor.addingTimeInterval(1), floor: floor))
        XCTAssertFalse(
            VehicleServiceWindow.allows(end, floor: floor),
            "the ESTIMATE itself is inside the buffer — the car isn't collectable the same minute"
        )
    }

    // MARK: - Scheduling caption

    func testSchedulingCaptionShapes() {
        let sameDay = date(DateComponents(year: 2026, month: 7, day: 29, hour: 14, minute: 0))
        let otherDay = date(DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 0))
        let halfPast = date(DateComponents(year: 2026, month: 8, day: 1, hour: 14, minute: 30))

        XCTAssertEqual(
            VehicleServiceWindow.schedulingCaption(
                vehicleName: "Lunar", serviceEstimatedEndAt: otherDay, now: now, calendar: calendar
            ),
            "Lunar is in service until ~Sat 2 PM"
        )
        XCTAssertEqual(
            VehicleServiceWindow.schedulingCaption(
                vehicleName: "Lunar", serviceEstimatedEndAt: sameDay, now: now, calendar: calendar
            ),
            "Lunar is in service until ~2 PM",
            "a same-day estimate drops the weekday"
        )
        XCTAssertEqual(
            VehicleServiceWindow.schedulingCaption(
                vehicleName: "Lunar", serviceEstimatedEndAt: halfPast, now: now, calendar: calendar
            ),
            "Lunar is in service until ~Sat 2:30 PM",
            "an off-the-hour estimate keeps its minutes"
        )
        XCTAssertNil(
            VehicleServiceWindow.schedulingCaption(
                vehicleName: "Lunar", serviceEstimatedEndAt: nil, now: now, calendar: calendar
            ),
            "no window, no caption — the card renders exactly as it always has"
        )
        XCTAssertNil(
            VehicleServiceWindow.schedulingCaption(
                vehicleName: "  ", serviceEstimatedEndAt: otherDay, now: now, calendar: calendar
            ),
            "a nameless vehicle yields no caption rather than a sentence with a hole in it"
        )
    }

    // MARK: - Picker-cell floor (the day × time grid)

    /// With no floor, every cell in the picker stays available — this is the
    /// pixel-identity guarantee for every simulated / drift-gate scene.
    func testPickerIsUnflooredWhenNoWindowIsKnown() {
        let days = RideRequestFixtures.scheduleDays
        let times = RideRequestFixtures.scheduleTimes

        XCTAssertEqual(RideScheduleFloor.allowedDays(days, times: times, floor: nil, now: now), days)
        XCTAssertEqual(RideScheduleFloor.allowedTimes(on: "Today", times: times, floor: nil, now: now), times)
        for day in days {
            for time in times {
                XCTAssertTrue(RideScheduleFloor.allows(day: day, time: time, floor: nil, now: now))
            }
        }
    }

    /// A floor mid-way through today blocks the morning and keeps the evening —
    /// the boundary DAY must survive, or the rider loses same-day booking for a
    /// car that is back at lunchtime.
    func testFlooredPickerBlocksEarlySlotsButKeepsTheBoundaryDay() {
        let times = RideRequestFixtures.scheduleTimes
        // Back today at 2:00 PM → floor 2:15 PM → the 2:30 PM chip is the first
        // bookable one, and 2:00 PM is not (it is inside the buffer).
        let end = date(DateComponents(year: 2026, month: 7, day: 29, hour: 14, minute: 0))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)

        XCTAssertFalse(RideScheduleFloor.allows(day: "Today", time: "9:00 AM", floor: floor, now: now))
        XCTAssertFalse(RideScheduleFloor.allows(day: "Today", time: "2:00 PM", floor: floor, now: now))
        XCTAssertTrue(RideScheduleFloor.allows(day: "Today", time: "2:30 PM", floor: floor, now: now))
        XCTAssertTrue(RideScheduleFloor.allows(day: "Today", time: "10:00 PM", floor: floor, now: now))

        let allowedToday = RideScheduleFloor.allowedTimes(on: "Today", times: times, floor: floor, now: now)
        XCTAssertEqual(allowedToday.first, "2:30 PM")
        XCTAssertFalse(allowedToday.isEmpty, "the boundary day stays pickable")

        XCTAssertTrue(
            RideScheduleFloor.allowedDays(RideRequestFixtures.scheduleDays, times: times, floor: floor, now: now)
                .contains("Today")
        )
    }

    /// A floor after today's last slot removes "Today" entirely — but only after
    /// every one of its times has been checked, never on the first blocked one.
    func testADayIsOnlyDisabledWhenEveryOneOfItsTimesIsBlocked() {
        let times = RideRequestFixtures.scheduleTimes
        // The picker's last slot is 10:30 PM; a floor past it leaves nothing today.
        let end = date(DateComponents(year: 2026, month: 7, day: 29, hour: 23, minute: 30))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)

        XCTAssertTrue(RideScheduleFloor.allowedTimes(on: "Today", times: times, floor: floor, now: now).isEmpty)
        XCTAssertFalse(
            RideScheduleFloor.allowedDays(RideRequestFixtures.scheduleDays, times: times, floor: floor, now: now)
                .contains("Today")
        )
        XCTAssertTrue(
            RideScheduleFloor.allowedDays(RideRequestFixtures.scheduleDays, times: times, floor: floor, now: now)
                .contains("Tomorrow"),
            "tomorrow is entirely past the floor and must stay open"
        )
    }

    /// The selection the picker opens on when the rider's pick is out of reach.
    func testFirstAllowedSlotScansDaysInPickerOrder() {
        let times = RideRequestFixtures.scheduleTimes
        let end = date(DateComponents(year: 2026, month: 7, day: 29, hour: 23, minute: 30))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)

        let slot = RideScheduleFloor.firstAllowedSlot(
            days: RideRequestFixtures.scheduleDays, times: times, floor: floor, now: now
        )
        XCTAssertEqual(slot?.day, "Tomorrow")
        XCTAssertEqual(slot?.time, times.first, "the whole of tomorrow clears the floor")

        XCTAssertEqual(
            RideScheduleFloor.firstAllowedSlot(
                days: RideRequestFixtures.scheduleDays, times: times, floor: nil, now: now
            )?.day,
            "Today",
            "with no floor the first cell in the grid is the answer"
        )
    }

    /// The floored slot the picker offers and the instant the create body carries
    /// are produced by the SAME resolver — this asserts they cannot diverge.
    func testAnAllowedSlotResolvesToAnInstantAtOrAfterTheFloor() {
        let times = RideRequestFixtures.scheduleTimes
        let end = date(DateComponents(year: 2026, month: 7, day: 29, hour: 14, minute: 0))
        let floor = VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: end)!

        for day in RideRequestFixtures.scheduleDays {
            for time in RideScheduleFloor.allowedTimes(on: day, times: times, floor: floor, now: now) {
                let instant = RideRequestContractMapping.scheduledDate(
                    from: RideSchedule(day: day, time: time), now: now, calendar: calendar
                )
                XCTAssertNotNil(instant)
                XCTAssertGreaterThanOrEqual(
                    instant!, floor,
                    "\(day) \(time) was offered but resolves before the floor"
                )
            }
        }
    }

    // MARK: - Mapping seams

    func testSnapshotMappingCarriesTheServiceWindowAndDegradesHonestly() {
        var state = Self.inServiceState()
        state.serviceEstimatedEndAt = "2026-08-01T21:00:00.000Z"
        XCTAssertEqual(
            VehicleContractMapping.snapshot(from: state).serviceEstimatedEndAt,
            ISO8601DateFormatter().date(from: "2026-08-01T21:00:00Z")
        )

        state.serviceEstimatedEndAt = nil
        XCTAssertNil(VehicleContractMapping.snapshot(from: state).serviceEstimatedEndAt)

        state.serviceEstimatedEndAt = "not-a-date"
        XCTAssertNil(
            VehicleContractMapping.snapshot(from: state).serviceEstimatedEndAt,
            "an unparseable instant degrades to 'no window known', never to a fabricated date"
        )
    }

    func testFleetMemberMappingCarriesTheServiceWindowForTheRiderFloor() {
        let summary = Self.inServiceSummary(serviceEstimatedEndAt: "2026-08-01T21:00:00.000Z")
        let member = LiveFleetMemberMapping.fleetMember(from: summary)

        XCTAssertEqual(
            member.serviceEstimatedEndAt,
            ISO8601DateFormatter().date(from: "2026-08-01T21:00:00Z")
        )
        XCTAssertEqual(member.unavailability, .inService, "the MYR-233 gate is unchanged by this issue")

        let noWindow = LiveFleetMemberMapping.fleetMember(from: Self.inServiceSummary(serviceEstimatedEndAt: nil))
        XCTAssertNil(noWindow.serviceEstimatedEndAt)
        XCTAssertNil(
            VehicleServiceWindow.earliestSelectable(serviceEstimatedEndAt: noWindow.serviceEstimatedEndAt),
            "an in-service car with no estimate imposes NO floor"
        )
    }

    /// MYR-233's own-ride exception clears `busy`, and must leave the service
    /// window alone: a rider holding an open ride still cannot book a car that is
    /// physically in the shop.
    func testOwnRideExceptionPreservesTheServiceWindow() {
        let member = LiveFleetMemberMapping.fleetMember(
            from: Self.inServiceSummary(serviceEstimatedEndAt: "2026-08-01T21:00:00.000Z")
        )
        let cleared = member.clearingUnavailability()
        XCTAssertEqual(cleared.serviceEstimatedEndAt, member.serviceEstimatedEndAt)
    }

    /// The fixture fleet — every simulated / DEBUG scene — carries no window, so
    /// nothing about the shipped simulated experience changes.
    func testFixtureFleetImposesNoFloor() {
        for member in RideRequestFixtures.fleet {
            XCTAssertNil(member.serviceEstimatedEndAt, "\(member.owner) must not carry a simulated window")
        }
    }

    // MARK: - Support

    private static func inServiceSummary(serviceEstimatedEndAt: String?) -> VehicleSummary {
        VehicleSummary(
            vehicleId: "veh", name: "Lunar", model: "Model Y", year: 2026, color: "Quicksilver",
            vinLast4: "2046", status: .inService, chargeLevel: 61, estimatedRange: 166,
            lastUpdated: "2026-07-29T10:00:00Z", role: .owner,
            serviceEstimatedEndAt: serviceEstimatedEndAt
        )
    }

    private static func inServiceState() -> VehicleState {
        VehicleState(
            vehicleId: "veh", name: "Lunar", model: "Model Y", year: 2026, color: "Quicksilver",
            status: .inService, speed: 0, heading: 0, latitude: 37.79, longitude: -122.39,
            locationName: "Tesla Service", locationAddress: "999 Brannan St",
            chargeLevel: 61, estimatedRange: 166, interiorTemp: 70, exteriorTemp: 63,
            odometerMiles: 18432, fsdMilesSinceReset: 11274,
            lastUpdated: "2026-07-29T10:00:00Z"
        )
    }
}
