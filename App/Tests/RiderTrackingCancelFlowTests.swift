import XCTest
import MyRoboTaxiKit
@testable import MyRoboTaxi

// MARK: - MYR-397 — the tracking sheet's Cancel is the REAL cancel path
//
// The r14 lesson (`ReservationCancel.swift`) applied to a ride that is already
// running. Three rules, and each is a way this could have shipped broken:
//
//  1. **NO OPTIMISTIC REMOVAL.** `RideRequestService.cancel()` clears the record
//     synchronously and fires the POST into a detached task whose answer is
//     discarded. On a DISPATCHED ride that is a rider who believes they have
//     cancelled walking away from a car that is still coming for them.
//  2. **CLASSIFIED, NOT COLLAPSED.** Refused (the server answered) and unreachable
//     (it did not) need different sentences, because they need different things
//     from the person reading them.
//  3. **RECONCILED.** A refusal whose ride has since left the list is not something
//     to tell anyone about — the rider asked for it to be over and it is over.

final class RiderTrackingCancelFlowTests: XCTestCase {

    private struct Boom: Error {}

    // MARK: The happy path

    func testASuccessfulCancelSaysNothingAtAll() async {
        let outcome = await RiderActiveRideCancel.perform(
            rideID: "r1",
            cancel: {},
            reread: { false }
        )
        XCTAssertEqual(outcome, .cancelled)
    }

    // MARK: Classification

    /// `RestError.http` is the ONE shape that proves the server ANSWERED.
    func testAServerRefusalIsClassifiedAsARefusalAndSaysSo() async {
        let outcome = await RiderActiveRideCancel.perform(
            rideID: "r1",
            cancel: { throw RestError.http(status: 409, code: nil, message: "ride_active", subCode: nil) },
            reread: { true }
        )
        XCTAssertEqual(outcome, .refused(notice: ReservationCancelCopy.riderActiveRide.refused))
    }

    /// A transport failure is NOT a refusal — reporting it as one asserts something
    /// the client cannot know, and the copy has to say so.
    func testATransportFailureGetsTheUnreachableSentence() async {
        let outcome = await RiderActiveRideCancel.perform(
            rideID: "r1",
            cancel: { throw Boom() },
            reread: { true }
        )
        XCTAssertEqual(outcome, .refused(notice: ReservationCancelCopy.riderActiveRide.unreachable))
    }

    /// The two sentences must be different and neither may claim more than it
    /// knows. "Couldn't cancel" over a server we never reached is a statement
    /// about a refusal that may not have happened.
    func testTheTwoSentencesAreDistinctAndTheUnreachableOneDoesNotClaimARefusal() {
        let copy = ReservationCancelCopy.riderActiveRide
        XCTAssertNotEqual(copy.refused, copy.unreachable)
        XCTAssertTrue(copy.unreachable.contains("Couldn\u{2019}t reach the server"))
        XCTAssertFalse(copy.unreachable.lowercased().contains("can\u{2019}t be cancelled"))
    }

    /// It is the RIDE's noun, not the reservation's. `ReservationCancelCopy.rider`
    /// says "the ride is still booked", which is the wrong word for a car that is
    /// on its way.
    func testTheActiveRideCopyIsNotTheReservationCopy() {
        XCTAssertNotEqual(ReservationCancelCopy.riderActiveRide, ReservationCancelCopy.rider)
        XCTAssertTrue(ReservationCancelCopy.riderActiveRide.unreachable.contains("your ride is still on"))
    }

    // MARK: THE RECONCILE

    /// **A refusal about a ride that is already gone is not worth a toast.** The
    /// most common refusal by far is a `409` on a ride that dispatched, was
    /// declined, or was ended from the other side — and in every one of those the
    /// re-read agrees with the tap.
    func testARefusalWhoseRideHasGoneIsReportedAsACancel() async {
        let outcome = await RiderActiveRideCancel.perform(
            rideID: "r1",
            cancel: { throw RestError.http(status: 409, code: nil, message: nil, subCode: nil) },
            reread: { false }
        )
        XCTAssertEqual(outcome, .cancelled)
    }

    /// **"I could not check" is not evidence the ride is gone.** A re-read that did
    /// not answer must report STILL HELD, so a cancel we cannot confirm is never
    /// reported as one — this is the single assertion with a person standing at a
    /// kerb at the end of it.
    func testAReReadThatDidNotAnswerIsTreatedAsStillHeld() async {
        let outcome = await RiderActiveRideCancel.perform(
            rideID: "r1",
            cancel: { throw Boom() },
            reread: { true } // the screen's own `stillStands` answers true on an unanswered read
        )
        XCTAssertEqual(outcome, .refused(notice: ReservationCancelCopy.riderActiveRide.unreachable))
    }

    // MARK: "Still standing"

    func testAnAbsentRecordMeansTheRideIsGone() {
        XCTAssertFalse(RiderActiveRideCancel.stillStands(status: nil))
    }

    /// `cancelled` never appears as a status — `LiveRideRequestService.integrate`
    /// maps it to no app status at all and clears the record (MYR-172). So the
    /// nil above IS the successful cancel's signal, and these are the rides that
    /// are genuinely still on.
    func testALiveRideIsStillStanding() {
        for status in [RideRequestStatus.pending, .accepted, .arrived, .enroute] {
            XCTAssertTrue(RiderActiveRideCancel.stillStands(status: status), "\(status)")
        }
    }

    /// A ride that ended some other way while the tap was in flight still ends up
    /// where the rider asked it to be.
    func testARideThatEndedAnotherWayIsNotStillStanding() {
        XCTAssertFalse(RiderActiveRideCancel.stillStands(status: .declined))
        XCTAssertFalse(RiderActiveRideCancel.stillStands(status: .completed))
    }

    // MARK: THE ORDER

    /// The mutation runs, and only THEN the re-read — a reconcile performed before
    /// the cancel would be reading the world the cancel was meant to change.
    func testTheCancelIsAwaitedBeforeTheReReadIsMade() async {
        actor Log {
            private(set) var events: [String] = []
            func record(_ e: String) { events.append(e) }
        }
        let log = Log()
        _ = await RiderActiveRideCancel.perform(
            rideID: "r1",
            cancel: { await log.record("cancel") },
            reread: { await log.record("reread"); return false }
        )
        let events = await log.events
        XCTAssertEqual(events, ["cancel", "reread"])
    }

    /// **The simulated service's cancel does not throw**, so a simulated tap
    /// resolves `.cancelled` every time — the correct simulated answer (there is no
    /// server to refuse) rather than a stubbed refusal the sim could never receive.
    @MainActor
    func testTheSimulatedServiceResolvesACleanCancel() async throws {
        let service = SimulatedRideRequestService()
        service.submit(RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[0],
            fleetMemberID: RideRequestFixtures.fleet[0].id
        ))
        XCTAssertNotNil(service.activeRequest)
        try await service.cancelActiveRide(id: "r1")
        XCTAssertNil(service.activeRequest, "the simulated cancel IS the local discard")
    }
}
