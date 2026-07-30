import XCTest
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-361 — the Now/Schedule segment's DEFAULT MATRIX
//
// The pure half of the client's first report: *"Even though no car is available
// right now it's still allowing me to request a ride right now. Vs defaulting to
// scheduling."*
//
// FAILING-FIRST: none of this type existed on origin/main (06f4627) — the segment
// was `selected: viewerState.draftSchedule == nil` inline in `chipRow`, with no
// input from the fleet at all, so every case below that expects `.schedule` or a
// disabled "Now" was unreachable.
final class RideRequestSchedulingSegmentTests: XCTestCase {

    // MARK: Fixtures — live-SHAPED members through the REAL mapping

    private func member(
        id: String = "m1",
        name: String = "Lunar",
        status: VehicleSummary.Status = .parked,
        hasActiveRide: Bool = false,
        rideShareEnabled: Bool? = nil
    ) -> FleetMember {
        LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
            vehicleId: id,
            name: name,
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "2046",
            status: status,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-07-30T12:00:00Z",
            role: .owner,
            hasActiveRide: hasActiveRide,
            rideShareEnabled: rideShareEnabled
        ))
    }

    private func availability(_ members: [FleetMember]) -> RideSchedulingAvailability {
        .resolve(members: members)
    }

    private func segment(
        _ members: [FleetMember],
        hasSchedule: Bool = false,
        cardOpen: Bool = false
    ) -> RideRequestSchedulingSegment {
        .resolve(availability: availability(members), hasSchedule: hasSchedule, cardOpen: cardOpen)
    }

    // MARK: 1 — the client's own state

    /// The three reasons that END on their own all default the segment to
    /// Schedule and disable "Now", because MYR-313 keeps a reservation open
    /// against every one of them.
    func testAFleetWithNoRequestableMemberDefaultsToScheduleAndDisablesNow() {
        let cases: [(String, FleetMember)] = [
            ("inService", member(status: .inService)),
            ("offline", member(status: .offline)),
            ("busy", member(hasActiveRide: true)),
        ]
        for (label, only) in cases {
            let seg = segment([only])
            XCTAssertEqual(seg.selection, .schedule, "\(label): the segment must open on Schedule")
            XCTAssertFalse(seg.nowEnabled, "\(label): 'Now' must not be offered")
            XCTAssertNotNil(seg.nowCaption, "\(label): a disabled 'Now' must say why")
        }
    }

    /// The caption is the IDLE BANNER'S OWN HEADLINE, verbatim — the same sentence
    /// the rider read one tap earlier. Two copies of it would be two places for the
    /// grammar to drift, which is the whole reason MYR-352 factored `riderClause`
    /// out in the first place.
    func testTheDisabledNowCaptionIsTheIdleBannersHeadlineVerbatim() {
        let only = member(status: .inService)
        let banner = try? XCTUnwrap(RiderIdleAvailabilityBanner.banner(members: [only]))
        XCTAssertEqual(segment([only]).nowCaption, banner?.headline)
        XCTAssertEqual(segment([only]).nowCaption, "Lunar is in service — no rides right now")
    }

    /// The MULTI-vehicle set takes the banner's generic headline for the same
    /// reason it does at idle: with two cars out for two reasons, no single reason
    /// is true of the fleet.
    func testAMixedUnavailableFleetTakesTheGenericHeadline() {
        let seg = segment([member(id: "a", status: .inService), member(id: "b", name: "Comet", status: .offline)])
        XCTAssertEqual(seg.selection, .schedule)
        XCTAssertFalse(seg.nowEnabled)
        XCTAssertEqual(seg.nowCaption, RiderIdleAvailabilityBanner.genericHeadline)
    }

    // MARK: 2 — every case that must change NOTHING

    /// ONE free car cancels the whole thing, whatever the others are doing — the
    /// MYR-352 set predicate, reused rather than re-derived.
    func testOneRequestableMemberLeavesTheSegmentAlone() {
        let seg = segment([member(id: "a", status: .inService), member(id: "b", name: "Comet")])
        XCTAssertEqual(seg.selection, .now)
        XCTAssertTrue(seg.nowEnabled)
        XCTAssertNil(seg.nowCaption)
    }

    /// EMPTY is the SIM path and the before-the-list-lands path, and it is also
    /// MYR-343's `.empty` shell answering a different question. It must say
    /// nothing — this is what keeps every simulated scene byte-identical.
    func testAnEmptySetIsUnconstrained() {
        XCTAssertEqual(availability([]), .unconstrained)
        let seg = segment([])
        XCTAssertEqual(seg.selection, .now)
        XCTAssertTrue(seg.nowEnabled)
        XCTAssertNil(seg.nowCaption)
    }

    /// THE PAUSED CARVE-OUT, and the single most important case in this file.
    ///
    /// A paused car gates instant rides AND scheduled ones (§7.18 refuses
    /// reservations on all three enforcement layers, MYR-342). Defaulting to
    /// Schedule would march the rider through a day, a time and a passenger to
    /// reach the same `409 vehicle_unavailable`. So the segment is left exactly as
    /// it was: an absent good option is not a licence to fabricate a pick.
    func testAPausedOnlyFleetLeavesTheSegmentExactlyAsItWas() {
        let paused = member(rideShareEnabled: false)
        XCTAssertEqual(paused.unavailability, .paused, "precondition: the real mapping calls this paused")
        XCTAssertNotNil(
            RiderIdleAvailabilityBanner.banner(members: [paused]),
            "precondition: the idle banner DOES fire here — the segment's silence is its own rule, not a missing predicate"
        )

        let seg = segment([paused])
        XCTAssertEqual(seg.selection, .now, "a paused fleet must not default to a picker that will also refuse")
        XCTAssertTrue(seg.nowEnabled, "and must not dim the only chip it leaves selected")
        XCTAssertNil(seg.nowCaption)
        XCTAssertEqual(availability([paused]), .unconstrained)
    }

    /// A fleet where SOME reason still offers scheduling defaults, even with a
    /// paused car in it — the offer is over the set, exactly like the banner's
    /// second line.
    func testAPausedCarAlongsideASchedulableOneStillDefaults() {
        let seg = segment([member(id: "a", rideShareEnabled: false), member(id: "b", name: "Comet", status: .inService)])
        XCTAssertEqual(seg.selection, .schedule)
        XCTAssertFalse(seg.nowEnabled)
        XCTAssertEqual(seg.nowCaption, RiderIdleAvailabilityBanner.genericHeadline)
    }

    /// The banner's own second line and this default answer the same question, so
    /// they must agree on every set. Pinned across the whole `FleetUnavailability`
    /// case list so a new reason cannot land on one side only.
    func testTheDefaultAgreesWithTheBannersSchedulingLineOnEveryReason() {
        for reason in FleetUnavailability.allCases {
            let only: FleetMember
            switch reason {
            case .busy: only = member(hasActiveRide: true)
            case .inService: only = member(status: .inService)
            case .offline: only = member(status: .offline)
            case .paused: only = member(rideShareEnabled: false)
            }
            XCTAssertEqual(only.unavailability, reason, "precondition for \(reason)")
            let bannerOffersScheduling =
                RiderIdleAvailabilityBanner.banner(members: [only])?.detail == RiderIdleAvailabilityBanner.schedulingDetail
            XCTAssertEqual(
                availability([only]).defaultsToSchedule, bannerOffersScheduling,
                "\(reason): the segment defaults to Schedule exactly when the idle banner says scheduling is still open"
            )
        }
    }

    // MARK: 3 — the ordering of facts (the client's second report)

    /// A COMMITTED schedule outranks everything: the segment reads Schedule even on
    /// a perfectly available fleet. This is the one branch that worked before this
    /// issue, and it must keep working.
    func testACommittedScheduleSelectsScheduleOnAnAvailableFleet() {
        let seg = segment([member()], hasSchedule: true)
        XCTAssertEqual(seg.selection, .schedule)
        XCTAssertTrue(seg.nowEnabled, "an available fleet still offers 'Now' — the rider can switch back")
    }

    /// *"scheduled should be selected instead of now"* — a rider standing IN the
    /// picker is scheduling, committed slot or not. Leaving "Now" lit a few points
    /// above an open "Schedule pickup" card is the contradiction they photographed.
    func testAnOpenScheduleCardSelectsScheduleBeforeAnythingIsCommitted() {
        let seg = segment([member()], hasSchedule: false, cardOpen: true)
        XCTAssertEqual(seg.selection, .schedule)
    }

    /// …and NOTHING is remembered when they cancel: with no commit the segment
    /// falls straight back to whatever the fleet and the draft say. On an available
    /// fleet that is "Now".
    func testCancellingThePickerRestoresNowWhenNowIsAvailable() {
        let members = [member()]
        XCTAssertEqual(segment(members, cardOpen: true).selection, .schedule)
        XCTAssertEqual(segment(members, cardOpen: false).selection, .now)
    }

    /// …and on a fleet that cannot take an instant request it stays on Schedule
    /// with "Now" still disabled, because cancelling a picker does not make a car
    /// available.
    func testCancellingThePickerOnAnUnavailableFleetStaysOnScheduleWithNowDisabled() {
        let members = [member(status: .inService)]
        let afterCancel = segment(members, hasSchedule: false, cardOpen: false)
        XCTAssertEqual(afterCancel.selection, .schedule)
        XCTAssertFalse(afterCancel.nowEnabled)
        XCTAssertNotNil(afterCancel.nowCaption)
    }

    /// Clearing a committed schedule on an AVAILABLE fleet returns to Now — the
    /// "Now" chip's own action is `draftSchedule = nil` and nothing else, so this
    /// is the whole round trip.
    func testClearingAScheduleReturnsToNowOnAnAvailableFleet() {
        let members = [member()]
        XCTAssertEqual(segment(members, hasSchedule: true).selection, .schedule)
        XCTAssertEqual(segment(members, hasSchedule: false).selection, .now)
    }
}
