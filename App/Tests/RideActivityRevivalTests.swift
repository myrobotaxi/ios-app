import CoreLocation
import MyRobotaxiContracts
import SwiftUI
import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-479: the pure half of "a live ride with no card gets one back"
//
// The MYR-405 matrix idiom: the DECISION is a pure function and is swept here, and
// `RideActivityCoordinatorTests` proves the coordinator consults it. The split
// matters on this feature more than most — ActivityKit cannot be reached from a
// unit test at all — but it is also exactly the shape that let
// `VehicleRideShare.display` keep passing every test it had while having no callers,
// so neither suite stands alone.

@MainActor
final class RideActivityRevivalTests: XCTestCase {

    // MARK: - The one thing it says yes to

    func testALiveRideWithNoCardOnScreenIsREVIVED() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [],
                account: account(record(status: .enroute))
            ),
            .start(rideID: "ride-1")
        )
    }

    func testEveryNonTerminalStatusIsRevivable() {
        for status in [MyRoboTaxi.RideRequestStatus.pending, .accepted, .arrived, .enroute] {
            XCTAssertEqual(
                RideActivityStateMachine.revival(snapshots: [], account: account(record(status: status))),
                .start(rideID: "ride-1"),
                "\(status) is a ride in progress and may hold a card"
            )
        }
    }

    // MARK: - The four things it says no to

    /// The reaper's liveness answer says `.live` for a COMPLETED ride on purpose
    /// (MYR-425 — it is still the ride the lingering arrival card is about), so an arm
    /// that keyed on that alone would put a fresh "You've arrived" on the lock screen
    /// after the card had come down. The eligibility question is
    /// `mayStartActivity`'s, and it is the SAME one `startState` asks.
    func testATerminalRideIsNeverRevived() {
        for status in [MyRoboTaxi.RideRequestStatus.completed, .declined] {
            XCTAssertEqual(
                RideActivityStateMachine.revival(snapshots: [], account: account(record(status: status))),
                .none,
                "\(status) finished before any new card could appear"
            )
        }
    }

    func testADormantReservationIsNeverRevived() {
        var reservation = record(status: .accepted)
        // BOTH facts, because `RideReservation.isReservation` reads the DISPLAY pair
        // and `isPastDue` reads the instant — a record carrying only one of them is
        // an instant ride with a stray date, which is live at every status.
        reservation.input.schedule = RideSchedule(day: "Saturday", time: "2:00 PM")
        reservation.scheduledFor = Date().addingTimeInterval(48 * 60 * 60)

        XCTAssertEqual(
            RideActivityStateMachine.revival(snapshots: [], account: account(reservation)),
            .none,
            "a reservation accepted for Saturday holds no card today"
        )
    }

    /// MYR-405's third arm, pointed the other way: a `nil` record before the §7.8 read
    /// has answered is "we have not asked", and starting a card on it would put one up
    /// for a ride the account may not hold.
    func testAnUnresolvedPipelineRevivesNothing() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [],
                account: RideActivityAccountRide(record: record(status: .enroute), isResolved: false)
            ),
            .none
        )
        XCTAssertEqual(
            RideActivityStateMachine.revival(snapshots: [], account: account(nil)),
            .none
        )
    }

    /// **THE LEG-TRANSITION DECISION, IN THE PURE LAYER.** The finality set is keyed on
    /// the RIDE and nothing about the ride's leg is an input here — which is the
    /// decision made structural rather than remembered: there is no parameter a future
    /// edit could thread a "but the leg changed" exception through.
    func testTheRidersSwipeBarsRevivalAtEveryStatusOfTheSameRide() {
        for status in [MyRoboTaxi.RideRequestStatus.accepted, .arrived, .enroute] {
            XCTAssertEqual(
                RideActivityStateMachine.revival(
                    snapshots: [],
                    account: account(record(status: status)),
                    dismissedRideIDs: ["ride-1"]
                ),
                .none,
                "a swipe is a decision about the ride, and \(status) is the same ride"
            )
        }
    }

    func testADifferentRideAfterASwipeIsStillRevivable() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [],
                account: account(record(id: "ride-2", status: .enroute)),
                dismissedRideIDs: ["ride-1"]
            ),
            .start(rideID: "ride-2"),
            "the client's own 'or if new ride begins'"
        )
    }

    // MARK: - What counts as "already has a card"

    func testACardOnScreenIsAdoptionsBusinessAndIsNeverDoubled() {
        for lifecycle in [RideActivitySnapshot.Lifecycle.active, .stale] {
            XCTAssertEqual(
                RideActivityStateMachine.revival(
                    snapshots: [RideActivitySnapshot(rideID: "ride-1", lifecycle: lifecycle)],
                    account: account(record(status: .enroute))
                ),
                .none
            )
        }
    }

    /// An `.ended` card is living out a dismissal policy and MAY STILL BE VISIBLE —
    /// MYR-405's own reason for skipping it in the reaper. Starting a second one
    /// beside it is the duplicate banner this feature spent an issue removing.
    func testAnEndedCardStillCountsAsACard() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [RideActivitySnapshot(rideID: "ride-1", lifecycle: .ended)],
                account: account(record(status: .enroute))
            ),
            .none
        )
    }

    /// A `.dismissed` row is the one lifecycle that is NOT a card: nothing is on
    /// screen. Whether it BARS a revival is the finality set's question, and the
    /// coordinator answers it with provenance the restore list does not carry — see
    /// `RideActivityCoordinator.endedByAppRideIDs`.
    func testADismissedRowIsNotACardAndDoesNotBlockOnItsOwn() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [RideActivitySnapshot(rideID: "ride-1", lifecycle: .dismissed)],
                account: account(record(status: .enroute))
            ),
            .start(rideID: "ride-1")
        )
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [RideActivitySnapshot(rideID: "ride-1", lifecycle: .dismissed)],
                account: account(record(status: .enroute)),
                dismissedRideIDs: ["ride-1"]
            ),
            .none,
            "and once the coordinator has recorded it as the rider's, it bars"
        )
    }

    /// Another ride's card is not this ride's card.
    func testAnOrphanForSomeOtherRideDoesNotSatisfyThisOne() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [RideActivitySnapshot(rideID: "some-other-ride", lifecycle: .active)],
                account: account(record(status: .enroute))
            ),
            .start(rideID: "ride-1")
        )
    }

    // MARK: - MYR-416: both questions go through the mapping

    /// The card carries the LOCAL draft UUID and the relaunched record carries the
    /// SERVER's. With `==` the revival arm would read the rider's own live banner as
    /// somebody else's card and start a second one beside it — MYR-416's defect,
    /// re-entered by the arm added to fix a different one.
    func testTheCardIsRECOGNISEDAcrossTheIDSplit() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: ["local-draft": "server-ride-1"])

        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [RideActivitySnapshot(rideID: "local-draft", lifecycle: .active)],
                account: account(record(id: "server-ride-1", status: .enroute)),
                identity: identity
            ),
            .none,
            "the rider's own banner is already up under the id this device stamped"
        )
    }

    func testTheSWIPEIsRecognisedAcrossTheIDSplitToo() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: ["local-draft": "server-ride-1"])

        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [],
                account: account(record(id: "server-ride-1", status: .enroute)),
                dismissedRideIDs: ["local-draft"],
                identity: identity
            ),
            .none
        )
    }

    /// The started card is stamped with the RECORD's id, which after a relaunch is the
    /// SERVER's — the id §7.21 keys the registration on (MYR-415).
    func testTheRevivedCardIsNamedByTheRecordsID() {
        XCTAssertEqual(
            RideActivityStateMachine.revival(
                snapshots: [],
                account: account(record(id: "server-ride-1", status: .arrived))
            ),
            .start(rideID: "server-ride-1")
        )
    }

    // MARK: - MYR-479: the Settings hint

    /// `.unknown` is what the SIMULATED path reports for ever, so the notice must
    /// render nothing at all there — a slot that spent a single point would move every
    /// DEBUG Settings capture.
    func testTheAuthorizationNoticeRendersNOTHINGUnlessLiveActivitiesAreOff() {
        XCTAssertEqual(height(of: LiveActivityDeniedNotice(state: .unknown)), 0, accuracy: 0.5)
        XCTAssertEqual(height(of: LiveActivityDeniedNotice(state: .enabled)), 0, accuracy: 0.5)
        XCTAssertGreaterThan(
            height(of: LiveActivityDeniedNotice(state: .disabled)),
            44,
            "the sentence plus a 44pt tap target"
        )
    }

    func testTheNoticeNamesTheSurfacesARiderWouldMiss() {
        XCTAssertTrue(LiveActivityDeniedNotice.message.contains("Lock Screen"))
        XCTAssertTrue(LiveActivityDeniedNotice.message.contains("Dynamic Island"))
    }

    // MARK: - Helpers

    private func height(of view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: 361))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 361, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private func account(_ record: RideRequestRecord?) -> RideActivityAccountRide {
        RideActivityAccountRide(record: record, isResolved: true)
    }

    private func record(
        id: String = "ride-1",
        status: MyRoboTaxi.RideRequestStatus
    ) -> RideRequestRecord {
        let place = RidePlace(
            id: "dest", label: "Home", subtitle: nil, miles: 4.2, minutes: 12,
            icon: "house.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
        )
        var record = RideRequestRecord(
            id: id,
            input: RideRequestInput(pickup: place, destination: place, fleetMemberID: "vehicle-1"),
            status: status
        )
        record.status = status
        return record
    }
}
