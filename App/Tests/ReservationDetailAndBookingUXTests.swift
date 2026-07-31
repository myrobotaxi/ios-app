import XCTest
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-378 + MYR-382 — the shared reservation detail, and the paper cuts
//
// One TestFlight session's worth of booking-flow findings, plus the owner's
// missing reservation detail. What ties them together is that every one of them is
// a place where the app SAID something it could not back up — a possessive with
// nobody's name in it, an SMS nobody sends, a sheet sized to the screen instead of
// to what is in it, and an owner list that named a ride it could not show.
final class ReservationDetailAndBookingUXTests: XCTestCase {

    // MARK: - MYR-382 — "with 's Lunar"

    /// The line the client photographed. A LIVE reservation carries no owner name
    /// anywhere (MYR-377), so this is not an edge case — it is every live ride.
    func testAnAbsentOwnerNameDropsThePossessiveWhole() {
        let nameless = Self.row(driver: "", vehicle: "Lunar")
        XCTAssertEqual(ScheduledRideDisplay.vehicleTitle(nameless), "Lunar")
        XCTAssertEqual(ScheduledRideDisplay.withVehiclePhrase(nameless), "with Lunar")
        XCTAssertFalse(ScheduledRideDisplay.withVehiclePhrase(nameless).contains("\u{2019}s"))
        XCTAssertFalse(ScheduledRideDisplay.withVehiclePhrase(nameless).contains("'s"))
    }

    /// A NAMED owner is byte-identical to what shipped, which is what keeps every
    /// fixture-fed scene unchanged.
    func testANamedOwnerStillGetsThePossessive() {
        let named = Self.row(driver: "Mom", vehicle: "Model Y")
        XCTAssertEqual(ScheduledRideDisplay.vehicleTitle(named), "Mom\u{2019}s Model Y")
        XCTAssertEqual(ScheduledRideDisplay.withVehiclePhrase(named), "with Mom\u{2019}s Model Y")
    }

    /// The sweep. Every OTHER sentence on this sheet that embeds the owner's name
    /// has a nameless form too — a dangling subject reads as broken as a dangling
    /// apostrophe.
    func testEverySentenceThatNamesTheOwnerHasANamelessForm() {
        let nameless = Self.row(driver: "", vehicle: "Lunar")
        for sentence in [
            ScheduledRideDisplay.changeNote(nameless),
            ScheduledRideDisplay.rescheduleNote(nameless),
            ScheduledRideDisplay.awaitingConfirmationNote(nameless),
            ScheduledRideDisplay.rescheduleFooterNote(nameless)
        ] {
            // A DANGLING SUBJECT is the sentence-level form of "with 's Lunar":
            // the name went and the grammar around it stayed.
            XCTAssertFalse(sentence.hasPrefix(" "), sentence)
            XCTAssertFalse(sentence.contains("  "), sentence)
            XCTAssertFalse(sentence.hasPrefix("will "), sentence)
            XCTAssertFalse(sentence.contains("for .") || sentence.contains("once  "), sentence)
            XCTAssertFalse(sentence.contains("Waiting for  "), sentence)
        }
        XCTAssertEqual(
            ScheduledRideDisplay.rescheduleNote(nameless),
            "The owner will be asked to re-confirm the new time."
        )
    }

    /// It composes through `SharedVehicleTitle`, the app's ONE possessive rule —
    /// which also means the sheet inherits its "Alex's Alex's Model 3" guard.
    func testTheTitleUsesTheOneSharedComposer() {
        let selfNamed = Self.row(driver: "Alex", vehicle: "Alex\u{2019}s Model 3")
        XCTAssertEqual(ScheduledRideDisplay.vehicleTitle(selfNamed), "Alex\u{2019}s Model 3")
    }

    // MARK: - MYR-382 — the sheet is its CONTENT's height

    /// `.frame(maxHeight:)` is permission to GROW to that height, and the sheet
    /// took it: a fixed 88% of the screen with the content centred, in every mode.
    func testTheSheetIsSizedToItsContentAndOnlyCappedWhenItOverflows() {
        // Ordinary content: the sheet is exactly as tall as it is — NOT 750.
        XCTAssertEqual(ScheduledRideSheet.resolvedSheetHeight(content: 450, screen: 852), 450)
        // Content taller than the cap: the cap, and the ScrollView takes over inside.
        XCTAssertEqual(ScheduledRideSheet.resolvedSheetHeight(content: 900, screen: 852), 852 * 0.88)
        // Exactly at the cap.
        XCTAssertEqual(ScheduledRideSheet.resolvedSheetHeight(content: 852 * 0.88, screen: 852), 852 * 0.88)
        // Before the first measurement: no frame at all, so nothing flashes full-height.
        XCTAssertNil(ScheduledRideSheet.resolvedSheetHeight(content: 0, screen: 852))
        // No host height (the `screenHeight: nil` call sites): hug, uncapped.
        XCTAssertEqual(ScheduledRideSheet.resolvedSheetHeight(content: 450, screen: nil), 450)
        // The prototype's own number, unchanged.
        XCTAssertEqual(ScheduledRideSheet.maxHeightFraction, 0.88)
    }

    // MARK: - MYR-378 — one sheet, two roles

    func testTheRoleDecidesOnlyWhatItIsCalledAndWhoItIsAbout() {
        let owner = ScheduledRideSheetRole.owner(vehicleName: "Cybercab", requesterName: "Thomas")
        XCTAssertTrue(owner.isOwner)
        XCTAssertEqual(owner.cancelLabel, "Cancel reservation")
        XCTAssertEqual(owner.confirmTitle, "Cancel this reservation?")

        let rider = ScheduledRideSheetRole.rider
        XCTAssertFalse(rider.isOwner)
        XCTAssertEqual(rider.cancelLabel, "Cancel ride", "the rider's sheet is unchanged")
        XCTAssertEqual(rider.confirmTitle, "Cancel this ride?")
    }

    /// The owner's row carries the WHOLE reservation now, built by the same mapping
    /// the rider's Scheduled tab uses — which is what makes "the two roles cannot
    /// disagree about one ride" structural instead of aspirational.
    func testTheOwnerRowCarriesTheSameDetailTheRiderSheetRenders() throws {
        let wire = Self.wire(id: "res-1")
        let reservation = try XCTUnwrap(LiveUpcomingReservations.reservation(from: wire))
        let row = try XCTUnwrap(UpcomingReservationRow.row(for: reservation))
        let detail = try XCTUnwrap(row.detail, "the row the owner taps must have something to open")

        XCTAssertEqual(detail.id, row.id, "the detail is the SAME reservation the X declines")
        XCTAssertEqual(detail.from, "Home", "pick up …")
        XCTAssertEqual(detail.to, "Galleria Dallas", "… to drop off — the client's whole ask")
        XCTAssertEqual(detail.route.count, 2, "both endpoints, so the map preview has pins")
        XCTAssertEqual(detail.status, .confirmed)
        XCTAssertEqual(detail.day, row.scheduleDay, "one ride, one day string")
        XCTAssertEqual(detail.time, row.scheduleTime)

        // And the rider's own row for the SAME wire says the same things.
        let riderRow = try XCTUnwrap(RiderScheduledRideMapping.ride(from: wire, vehicle: nil))
        XCTAssertEqual(riderRow.from, detail.from)
        XCTAssertEqual(riderRow.to, detail.to)
        XCTAssertEqual(riderRow.day, detail.day)
        XCTAssertEqual(riderRow.time, detail.time)
        XCTAssertEqual(riderRow.miles, detail.miles)
    }

    /// The SIM fixtures carry details too, so the owner's sheet is reachable (and
    /// capturable) on the simulated path — and the ROW renders none of those
    /// fields, so `ownerDrives` is unchanged.
    func testTheFixtureReservationsCanOpenTheSheetToo() throws {
        for ride in DriveFixtures.upcomingRides {
            let detail = try XCTUnwrap(ride.detail, ride.id)
            XCTAssertFalse(detail.from.isEmpty)
            XCTAssertEqual(detail.to, ride.destination.label, "the row and its detail name one destination")
            XCTAssertEqual(detail.id, ride.id)
        }
    }

    // MARK: - MYR-382 — "Schedule with {car} instead" is a round trip

    /// *"When I select schedule with lunar we go back 2 steps to the schedule button
    /// again!"* The route out of Review was one-way: it armed the picker and left
    /// the rider on the search sheet, two taps from the CTA they had been reaching
    /// for.
    @MainActor
    func testTheBusyVehicleRouteRemembersToComeBack() {
        let state = SharedViewerState()
        state.sheetPhase = .review
        XCTAssertEqual(state.scheduleReturn, .search, "the two on-sheet entries never leave")

        state.routeToScheduling()
        XCTAssertTrue(state.opensScheduleOnSearch)
        XCTAssertEqual(state.sheetPhase, .search, "the picker lives on the search sheet")
        XCTAssertEqual(state.scheduleReturn, .review, "…but the errand ends back in Review")
    }

    /// The return is per-DRAFT, exactly like the one-shot flag beside it: a Review
    /// return left armed would make some later Schedule-chip commit jump to a Review
    /// nobody asked for.
    @MainActor
    func testTheReturnNeverOutlivesTheDraft() {
        let state = SharedViewerState()
        state.routeToScheduling()
        state.resetDraftToIdle()
        XCTAssertEqual(state.scheduleReturn, .search)
        XCTAssertFalse(state.opensScheduleOnSearch)
    }

    // MARK: - MYR-382 — the "Someone else" flow is gone

    /// The rider's booking surface has ONE text field now. Asserting the enum is
    /// asserting the flow: it is documented as the exhaustive list of the flow's
    /// fields, not a sample of them.
    func testTheBookingFlowHasOneTextFieldLeft() {
        #if canImport(UIKit)
        XCTAssertEqual(RideRequestFieldContentType.all.count, 1)
        XCTAssertEqual(RideRequestFieldContentType.all.first, RideRequestFieldContentType.destination)
        #endif
    }

    /// THE WIRE IS UNTOUCHED, which is the whole reason this removal is reversible.
    /// A ride booked for someone else before this build still maps its passenger
    /// back out, and the owner's surfaces still render them.
    func testThePassengerStillTravelsAndStillRenders() throws {
        let wire = Self.wire(id: "res-2", passengerName: "Maya Chen", passengerPhone: "(415) 555-0142")
        let passenger = try XCTUnwrap(RideRequestContractMapping.passenger(wire))
        XCTAssertEqual(passenger.name, "Maya Chen")
        XCTAssertEqual(passenger.phone, "(415) 555-0142")

        // …all the way onto the reservation detail both roles now open.
        let reservation = try XCTUnwrap(LiveUpcomingReservations.reservation(from: wire))
        let detail = try XCTUnwrap(UpcomingReservationRow.row(for: reservation)?.detail)
        XCTAssertEqual(detail.passenger?.name, "Maya Chen")
    }

    // MARK: - Fixtures

    private static func row(driver: String, vehicle: String) -> ScheduledRide {
        ScheduledRide(
            id: "s1", day: "Tomorrow", date: "Aug 1", time: "12:00 PM",
            from: "Home", to: "Galleria Dallas",
            driver: driver, relationship: "Your Tesla", vehicle: vehicle,
            miles: 12.4, status: .confirmed, route: []
        )
    }

    private static func wire(
        id: String,
        passengerName: String? = nil,
        passengerPhone: String? = nil
    ) -> MyRobotaxiContracts.RideRequest {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return MyRobotaxiContracts.RideRequest(
            id: id,
            riderId: "u-rider",
            ownerId: "u-owner",
            vehicleId: "veh-live",
            pickup: RidePlace(lat: 33.0198, lng: -96.6989, label: "Home"),
            dropoff: RidePlace(lat: 32.9346, lng: -96.8206, label: "Galleria Dallas"),
            status: .accepted,
            passengerName: passengerName,
            passengerPhone: passengerPhone,
            scheduledFor: formatter.string(from: Date().addingTimeInterval(24 * 3600)),
            createdAt: "2026-07-31T05:00:00.000Z",
            updatedAt: "2026-07-31T05:04:00.000Z",
            acceptedAt: "2026-07-31T05:04:00.000Z",
            requesterName: "Thomas"
        )
    }
}
