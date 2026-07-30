import XCTest
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-352 — the idle banner's predicate + copy matrix
//
// THE CLIENT'S ASK (TestFlight, Jul 30): *"If no owner vehicles available with
// ride share enabled we need to display a banner saying no rides available right
// now. Kind of like the Tesla Robotaxi app. We can do it as a sleek banner above
// the search bar."*
//
// Everything the banner decides is a pure function of the resolved vehicle set,
// so the whole matrix is asserted here rather than photographed — the same choice
// MYR-341 made for `RiderIdlePlaceholder.items`, and for the same reason: the idle
// sheet's trace border, search glow and rotation crossfade animate continuously,
// so two launches of the SAME binary diff.
//
// Failing-first: every test in this file failed to compile against origin/main
// faebe12 (`RiderIdleAvailabilityBanner` did not exist), except
// `testTheReviewHelperCopyIsUnchangedByTheSharedClause`, which is the DRIFT GATE
// on the four strings MYR-233/342 already shipped and passed before and after.
final class RiderIdleAvailabilityTests: XCTestCase {

    // MARK: Builders — every member comes through the SHIPPING mapping

    /// A live-shaped member built from real wire inputs, so these tests exercise
    /// `LiveFleetMemberMapping.unavailability` rather than a hand-set enum.
    private func member(
        id: String = "v1",
        name: String = "Lunar",
        status: VehicleSummary.Status = .parked,
        hasActiveRide: Bool? = nil,
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
            lastUpdated: "2026-07-26T12:00:00Z",
            role: .owner,
            hasActiveRide: hasActiveRide,
            rideShareEnabled: rideShareEnabled
        ))
    }

    /// The wire inputs that produce each reason, so a case can be driven by name.
    private func member(named name: String, reason: FleetUnavailability) -> FleetMember {
        switch reason {
        case .busy: return member(id: name, name: name, status: .parked, hasActiveRide: true)
        case .inService: return member(id: name, name: name, status: .inService)
        case .offline: return member(id: name, name: name, status: .offline)
        case .paused: return member(id: name, name: name, status: .parked, rideShareEnabled: false)
        }
    }

    // MARK: The two ways the banner stays silent

    /// "No rides available" about NO vehicles is a different situation, and one
    /// MYR-343 already answers with the invite-code empty state. The banner must
    /// not borrow that surface's question.
    func testAnEmptyVehicleSetRendersNoBanner() {
        XCTAssertNil(RiderIdleAvailabilityBanner.banner(members: []))
    }

    /// The predicate is "no vehicle can take a request", not "the watched one
    /// can't". One free car cancels the banner outright — and this is the case a
    /// naive `members.first` implementation would get wrong.
    func testOneRequestableVehicleCancelsTheBannerWhateverTheOthersAreDoing() {
        for reason in FleetUnavailability.allCases {
            let set = [member(named: "Lunar", reason: reason), member(id: "free", name: "Comet")]
            XCTAssertNil(
                RiderIdleAvailabilityBanner.banner(members: set),
                "a free car means rides ARE available, whatever \(reason.rawValue) is doing"
            )
            // ...in either order — the head of the list is not privileged here.
            XCTAssertNil(RiderIdleAvailabilityBanner.banner(members: set.reversed()))
        }
    }

    /// An entirely available fleet is the common case and must be silent.
    func testAnAvailableFleetRendersNoBanner() {
        XCTAssertNil(RiderIdleAvailabilityBanner.banner(members: [
            member(id: "a", name: "Lunar"), member(id: "b", name: "Comet")
        ]))
    }

    /// Every FIXTURE member is requestable, which is the structural reason the
    /// simulated path and every pre-existing DEBUG capture are byte-identical.
    func testNoFixtureFleetCanEverRaiseTheBanner() {
        XCTAssertTrue(
            RideRequestFixtures.fleet.allSatisfy { $0.unavailability == nil },
            "a fixture with an unavailability would raise the banner on the simulated path"
        )
        XCTAssertNil(RiderIdleAvailabilityBanner.banner(members: RideRequestFixtures.fleet))
    }

    // MARK: The single-vehicle headline — one per reason

    func testTheSingleVehicleHeadlineNamesTheReason() {
        let expected: [FleetUnavailability: String] = [
            .busy: "Lunar is on another ride \u{2014} no rides right now",
            .inService: "Lunar is in service \u{2014} no rides right now",
            .offline: "Lunar is offline \u{2014} no rides right now",
            .paused: "Lunar has paused ride requests \u{2014} no rides right now"
        ]
        for reason in FleetUnavailability.allCases {
            let banner = RiderIdleAvailabilityBanner.banner(members: [member(named: "Lunar", reason: reason)])
            XCTAssertEqual(banner?.headline, expected[reason], "headline for \(reason.rawValue)")
        }
        XCTAssertEqual(expected.count, FleetUnavailability.allCases.count, "every reason is covered")
    }

    /// The headline titles on the vehicle's own nickname — MYR-212's live naming,
    /// the same field Review's row and helper line use.
    func testTheHeadlineUsesTheVehicleNickname() {
        let banner = RiderIdleAvailabilityBanner.banner(members: [member(named: "Comet", reason: .inService)])
        XCTAssertEqual(banner?.headline, "Comet is in service \u{2014} no rides right now")
    }

    // MARK: The multi-vehicle headline

    /// Past one vehicle there is no single true reason, so the copy stops
    /// claiming one — the client's own words.
    func testAFleetWithTwoDifferentReasonsGetsTheGenericHeadline() {
        let banner = RiderIdleAvailabilityBanner.banner(members: [
            member(named: "Lunar", reason: .inService),
            member(named: "Comet", reason: .offline)
        ])
        XCTAssertEqual(banner?.headline, "No rides available right now")
        XCTAssertEqual(banner?.headline, RiderIdleAvailabilityBanner.genericHeadline)
    }

    /// Deliberately NOT special-cased: two cars out for the same reason is a
    /// coincidence, and a specific headline would assert it as a pattern.
    func testAFleetSharingONEReasonStillGetsTheGenericHeadline() {
        let banner = RiderIdleAvailabilityBanner.banner(members: [
            member(named: "Lunar", reason: .inService),
            member(named: "Comet", reason: .inService)
        ])
        XCTAssertEqual(banner?.headline, RiderIdleAvailabilityBanner.genericHeadline)
    }

    // MARK: The scheduling line — the MYR-313 / §7.18 split

    /// MYR-313 keeps reservations open against a car that will come back, and the
    /// contract keeps them outside the `busy` index. Say so.
    func testTheSchedulingLineIsShownForEveryReasonThatEndsOnItsOwn() {
        for reason: FleetUnavailability in [.busy, .inService, .offline] {
            let banner = RiderIdleAvailabilityBanner.banner(members: [member(named: "Lunar", reason: reason)])
            XCTAssertEqual(
                banner?.detail, "You can still schedule a pickup.",
                "\(reason.rawValue) allows scheduling (MYR-313), so the banner must say so"
            )
            XCTAssertTrue(reason.offersScheduling, "the line is derived from the shipping predicate")
        }
    }

    /// §7.18 — the server refuses scheduled rides against a paused car on all
    /// three enforcement layers. Offering scheduling here would be a longer walk
    /// to the same `409 vehicle_unavailable`, so the banner says nothing.
    func testAPausedVehicleGetsNoSchedulingLine() {
        let banner = RiderIdleAvailabilityBanner.banner(members: [member(named: "Lunar", reason: .paused)])
        XCTAssertNotNil(banner)
        XCTAssertNil(banner?.detail, "a pause blocks scheduling too — do not offer it")
        XCTAssertFalse(FleetUnavailability.paused.offersScheduling)
    }

    /// A whole fleet that is paused is the same answer at fleet scale.
    func testAnEntirelyPausedFleetGetsNoSchedulingLine() {
        let banner = RiderIdleAvailabilityBanner.banner(members: [
            member(named: "Lunar", reason: .paused),
            member(named: "Comet", reason: .paused)
        ])
        XCTAssertEqual(banner?.headline, RiderIdleAvailabilityBanner.genericHeadline)
        XCTAssertNil(banner?.detail)
    }

    /// ONE schedulable car in an otherwise-paused fleet restores the line — there
    /// genuinely is a pickup to schedule, even though none can be requested now.
    func testOneSchedulableVehicleRestoresTheSchedulingLine() {
        let banner = RiderIdleAvailabilityBanner.banner(members: [
            member(named: "Lunar", reason: .paused),
            member(named: "Comet", reason: .inService)
        ])
        XCTAssertEqual(banner?.headline, RiderIdleAvailabilityBanner.genericHeadline)
        XCTAssertEqual(banner?.detail, RiderIdleAvailabilityBanner.schedulingDetail)
    }

    // MARK: Agreement with the MYR-341 placeholder — the two must never contradict

    /// The banner exists to explain the placeholder's silence, so they must be
    /// raised and suppressed by the SAME fact. Any state where the ETA line is
    /// offered while the banner claims no rides (or the reverse) is a screen
    /// saying two things at once.
    func testTheBannerAndTheETAPlaceholderAgreeOnEveryReason() {
        for reason in FleetUnavailability.allCases {
            let only = member(named: "Lunar", reason: reason)
            let items = RiderIdlePlaceholder.items(
                pickupETAMinutes: 9, unavailability: only.unavailability, hasActiveRequest: false
            )
            XCTAssertEqual(
                items, [RiderIdlePlaceholder.destinationPrompt],
                "\(reason.rawValue): the ETA line must stay suppressed while the banner is up"
            )
            XCTAssertNotNil(RiderIdleAvailabilityBanner.banner(members: [only]))
        }

        // And the converse: an available car offers the ETA and raises no banner.
        let free = member(name: "Lunar")
        XCTAssertEqual(
            RiderIdlePlaceholder.items(
                pickupETAMinutes: 9, unavailability: free.unavailability, hasActiveRequest: false
            ),
            [RiderIdlePlaceholder.destinationPrompt, RiderIdlePlaceholder.etaLine(minutes: 9)]
        )
        XCTAssertNil(RiderIdleAvailabilityBanner.banner(members: [free]))
    }

    // MARK: The shared clause is a dedup, not a rewrite

    /// MYR-352 factored MYR-233/342's four Review helper strings onto
    /// `FleetUnavailability.riderClause` so the banner and the helper line cannot
    /// drift. This pins that the factoring changed no shipped copy by one byte.
    func testTheReviewHelperCopyIsUnchangedByTheSharedClause() {
        let expected: [FleetUnavailability: String] = [
            .busy: "Lunar is on another ride right now \u{2014} schedule a pickup instead",
            .inService: "Lunar is in service right now \u{2014} schedule a pickup instead",
            .offline: "Lunar is offline right now \u{2014} schedule a pickup instead",
            .paused: "Lunar has paused ride requests right now"
        ]
        for reason in FleetUnavailability.allCases {
            let sentence = "Lunar \(reason.riderClause) right now"
            let composed = reason.offersScheduling
                ? "\(sentence) \u{2014} schedule a pickup instead"
                : sentence
            XCTAssertEqual(composed, expected[reason], "Review helper copy for \(reason.rawValue)")
        }
    }
}
