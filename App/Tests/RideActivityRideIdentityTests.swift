import CoreLocation
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - Adoption across the two-id split (MYR-416)
//
// MYR-415 proved the REGISTRATION half of "a ride has two ids". This is the LOCK
// SCREEN half: the Activity's static `rideID` is the LOCAL draft UUID for every ride
// this device submitted, MYR-405's adoption compares against the record's id — which
// a relaunch rebuilds from the wire as the SERVER's — and the two never match. The
// consequence is not a missed optimisation: the reaper takes the rider's own live
// banner down and the start path puts a second one up, which is the duplicate-card
// class MYR-405 exists to close, re-entered through the id it never had to think
// about.
//
// These tests are the pure half. The end-to-end relaunch is in
// `RideActivityCoordinatorTests`, because only the coordinator holds the ledger, the
// restore budget and the adopt-before-reap order together.

@MainActor
final class RideActivityRideIdentityTests: XCTestCase {

    private let local = "1E572C40-LOCAL-DRAFT"
    private let server = "clride0000000000000001"

    // MARK: - The predicate

    func testAnUnmappedIdentityIsExactlyTheEqualityItReplaces() {
        let identity = RideActivityRideIdentity.unmapped
        XCTAssertTrue(identity.namesTheSameRide(activityRideID: "ride-1", as: "ride-1"))
        XCTAssertFalse(
            identity.namesTheSameRide(activityRideID: local, as: server),
            """
            With no mapping the answer must be plain `==`, which is what keeps every \
            pre-MYR-416 call site and every pre-MYR-416 test unchanged by \
            construction rather than by review.
            """
        )
    }

    func testTheMappingIsREADBOTHWAYSRound() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        XCTAssertTrue(identity.namesTheSameRide(activityRideID: local, as: server))
        XCTAssertTrue(
            identity.namesTheSameRide(activityRideID: server, as: local),
            """
            The caller does not always know which of the two ids it holds — the \
            coordinator's phase names the CARD's, the record names the SERVER's after \
            a relaunch and the LOCAL one in the process that submitted it. A \
            one-directional predicate would be right at three call sites and wrong at \
            the fourth.
            """
        )
        XCTAssertEqual(identity.identities(of: server), [local, server])
        XCTAssertEqual(identity.identities(of: local), [local, server])
    }

    func testAStrangersIDIsNOTFoldedInByTheMapping() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        XCTAssertFalse(identity.namesTheSameRide(activityRideID: "somebody-elses-card", as: server))
        XCTAssertFalse(identity.namesTheSameRide(activityRideID: local, as: "another-server-ride"))
        XCTAssertEqual(identity.identities(of: "unknown"), ["unknown"])
    }

    // MARK: - Reconciliation: the defect, as one assertion

    /// **THE WHOLE BUG.** One live ride, one card, and before MYR-416 the plan reaped
    /// it and adopted nothing — so the start path that runs immediately afterwards
    /// requested a SECOND Activity for the ride whose banner had just been taken down.
    func testARELAUNCHAdoptsTheLocalIDCardForAServerIDRide() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])

        let plan = RideActivityStateMachine.reconcile(
            snapshots: [RideActivitySnapshot(rideID: local, lifecycle: .active)],
            liveRide: .live(rideID: server),
            identity: identity
        )

        XCTAssertEqual(plan.adopt, local, "the card keeps the id it was STAMPED with — attributes are immutable")
        XCTAssertTrue(plan.reap.isEmpty, "reaping here is the second-banner generator")
    }

    func testWithoutTheMappingTheSameInputsReapTheRidersOwnCard() {
        // The pre-fix behaviour, asserted so the fix cannot be quietly reverted to
        // "it was fine anyway".
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [RideActivitySnapshot(rideID: local, lifecycle: .active)],
            liveRide: .live(rideID: server)
        )
        XCTAssertNil(plan.adopt)
        XCTAssertEqual(plan.reap, [local])
    }

    /// A ride ADOPTED from the wire (MYR-230) has ONE id, so nothing about it moves.
    func testARideWhoseTwoIDsCoincideIsUnchanged() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [RideActivitySnapshot(rideID: "srv-only", lifecycle: .active)],
            liveRide: .live(rideID: "srv-only"),
            identity: identity
        )
        XCTAssertEqual(plan.adopt, "srv-only")
        XCTAssertTrue(plan.reap.isEmpty)
    }

    /// **ORPHAN REAPING IS UNTOUCHED**, which is the property most at risk from a
    /// looser comparison: a mapping that made everything adoptable would leave a
    /// stranger's card on the lock screen for ever.
    func testAGenuinelyFOREIGNCardIsStillReapedWithAMappingPresent() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [
                RideActivitySnapshot(rideID: local, lifecycle: .active),
                RideActivitySnapshot(rideID: "foreign-ride", lifecycle: .active)
            ],
            liveRide: .live(rideID: server),
            identity: identity
        )
        XCTAssertEqual(plan.adopt, local)
        XCTAssertEqual(plan.reap, ["foreign-ride"])
    }

    func testTheUNRESOLVEDThirdArmStillReapsNothingWhateverTheMappingSays() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [
                RideActivitySnapshot(rideID: local, lifecycle: .active),
                RideActivitySnapshot(rideID: "foreign-ride", lifecycle: .active)
            ],
            liveRide: .unresolved,
            identity: identity
        )
        XCTAssertNil(plan.adopt)
        XCTAssertTrue(plan.reap.isEmpty, "§7.8 has not answered — nothing is evidence about anything yet")
    }

    func testTheTwoSKIPSSurviveTheMapping() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [
                RideActivitySnapshot(rideID: "ended-card", lifecycle: .ended),
                RideActivitySnapshot(rideID: local, lifecycle: .dismissed)
            ],
            liveRide: .live(rideID: server),
            identity: identity
        )
        XCTAssertTrue(plan.reap.isEmpty, "`.ended` is living out its dismissal policy")
        XCTAssertEqual(plan.dismissed, [local], "and the rider's swipe is recorded under the CARD's id")
        XCTAssertNil(plan.adopt, "a dismissed card is not adopted back")
    }

    /// A SECOND card for the same ride is still a duplicate when the two cards carry
    /// the local id and the ride is named by the server's.
    func testADuplicateIsStillReapedAcrossTheSplit() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let plan = RideActivityStateMachine.reconcile(
            snapshots: [
                RideActivitySnapshot(rideID: local, lifecycle: .active),
                RideActivitySnapshot(rideID: local, lifecycle: .active)
            ],
            liveRide: .live(rideID: server),
            identity: identity
        )
        XCTAssertEqual(plan.adopt, local)
        XCTAssertEqual(plan.reap, [local])
        XCTAssertTrue(
            plan.isDuplicateOfAdopted(local),
            "and it must be spared the §7.21 DELETE, or the fix starves the card it just kept"
        )
    }

    // MARK: - The per-tick decision

    /// **THE OTHER DOOR TO THE SAME DUPLICATE.** Even with the adoption fixed, the
    /// very next tick asked `record.id == liveID` and answered "a different ride is
    /// open" — ending the card it had just adopted and starting another.
    func testTheHELDCardIsNotRESTARTEDWhenTheRecordArrivesUnderTheServerID() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let held = RideActivityAttributes.ContentState(
            status: .enroute, eta: nil, vehicleName: "Lunar", destination: "Home", progress: nil, asOf: nil
        )

        let action = RideActivityStateMachine.action(
            phase: .live(rideID: local, state: held),
            record: makeRecord(id: server, status: .enroute),
            vehicleName: "Lunar",
            identity: identity
        )

        switch action {
        case .none, .update: break
        default: XCTFail("a relaunched rider-submitted ride must not restart its own card: \(action)")
        }
    }

    func testWithoutTheMappingThatSameTickRestartsTheCard() {
        let held = RideActivityAttributes.ContentState(
            status: .enroute, eta: nil, vehicleName: "Lunar", destination: "Home", progress: nil, asOf: nil
        )
        let action = RideActivityStateMachine.action(
            phase: .live(rideID: local, state: held),
            record: makeRecord(id: server, status: .enroute),
            vehicleName: "Lunar"
        )
        guard case .restart = action else {
            return XCTFail("expected the pre-fix `.restart`, got \(action)")
        }
    }

    /// A genuinely DIFFERENT ride still replaces the card — the mapping narrows
    /// nothing.
    func testAGenuinelyDifferentRideStillRestarts() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let held = RideActivityAttributes.ContentState(
            status: .enroute, eta: nil, vehicleName: "Lunar", destination: "Home", progress: nil, asOf: nil
        )
        let action = RideActivityStateMachine.action(
            phase: .live(rideID: local, state: held),
            record: makeRecord(id: "a-completely-different-ride", status: .accepted),
            vehicleName: "Lunar",
            identity: identity
        )
        guard case .restart(let ending, _, let starting, _) = action else {
            return XCTFail("expected a restart, got \(action)")
        }
        XCTAssertEqual(ending, local)
        XCTAssertEqual(starting, "a-completely-different-ride")
    }

    /// **THE RIDER'S SWIPE OUTLIVES THE PROCESS IT HAPPENED IN.** A dismissal can
    /// only ever be recorded under the CARD's id, and after a relaunch the record
    /// carries the server's — so with `==` the app would hand back a card the rider
    /// deliberately removed, on the one launch most likely to notice.
    func testADismissalRecordedUnderTheCARDSIDBlocksAStartUnderTheSERVERS() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])

        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: makeRecord(id: server, status: .enroute),
            vehicleName: "Lunar",
            dismissedRideIDs: [local],
            identity: identity
        )

        XCTAssertEqual(action, .none)
    }

    func testANEWRideStillStartsAfterADismissalAcrossTheSplit() {
        let identity = RideActivityRideIdentity(serverIDsByActivityID: [local: server])
        let action = RideActivityStateMachine.action(
            phase: .idle,
            record: makeRecord(id: "the-next-ride", status: .accepted),
            vehicleName: "Lunar",
            dismissedRideIDs: [local],
            identity: identity
        )
        guard case .start(let rideID, _) = action else {
            return XCTFail("a dismissal is a decision about ONE ride, got \(action)")
        }
        XCTAssertEqual(rideID, "the-next-ride")
    }

    // MARK: - The ledger

    func testThePairRoundTripsThroughUserDefaults() {
        let defaults = scratchDefaults()
        let store = UserDefaultsRideActivityRideIDs(defaults: defaults)

        store.note(activityRideID: local, serverRideID: server)

        XCTAssertTrue(
            UserDefaultsRideActivityRideIDs(defaults: defaults)
                .identity()
                .namesTheSameRide(activityRideID: local, as: server),
            """
            A SECOND store over the same defaults is the whole point: the process that \
            writes the pair is never the process that reads it.
            """
        )
    }

    func testAPairOLDERThanADayIsNotBelieved() {
        let defaults = scratchDefaults()
        let store = UserDefaultsRideActivityRideIDs(defaults: defaults)
        let now = Date()

        store.note(activityRideID: local, serverRideID: server, now: now)

        XCTAssertTrue(store.identity(now: now.addingTimeInterval(23 * 60 * 60))
            .namesTheSameRide(activityRideID: local, as: server))
        XCTAssertFalse(
            store.identity(now: now.addingTimeInterval(25 * 60 * 60))
                .namesTheSameRide(activityRideID: local, as: server),
            "a Live Activity does not survive a day — a pair older than that names no card"
        )
    }

    func testTheLedgerIsCappedAndKeepsTheNEWESTPairs() {
        let defaults = scratchDefaults()
        let store = UserDefaultsRideActivityRideIDs(defaults: defaults)

        for index in 0..<(UserDefaultsRideActivityRideIDs.capacity + 3) {
            store.note(activityRideID: "local-\(index)", serverRideID: "server-\(index)")
        }

        let identity = store.identity()
        XCTAssertFalse(identity.namesTheSameRide(activityRideID: "local-0", as: "server-0"))
        XCTAssertTrue(
            identity.namesTheSameRide(
                activityRideID: "local-\(UserDefaultsRideActivityRideIDs.capacity + 2)",
                as: "server-\(UserDefaultsRideActivityRideIDs.capacity + 2)"
            )
        )
    }

    func testRenotingTheSameCardREPLACESRatherThanAccumulates() {
        let defaults = scratchDefaults()
        let store = UserDefaultsRideActivityRideIDs(defaults: defaults)

        store.note(activityRideID: local, serverRideID: "first")
        store.note(activityRideID: local, serverRideID: "second")

        XCTAssertEqual(store.identity().identities(of: local), [local, "second"])
    }

    func testClearingForgetsEverything() {
        let defaults = scratchDefaults()
        let store = UserDefaultsRideActivityRideIDs(defaults: defaults)
        store.note(activityRideID: local, serverRideID: server)
        store.clear()
        XCTAssertEqual(store.identity(), .unmapped)
    }

    func testTheDefaultsKeyIsReverseDNSLikeEveryOtherStoreInThisApp() {
        XCTAssertEqual(
            UserDefaultsRideActivityRideIDs.defaultsKey,
            "app.myrobotaxi.ios.liveActivityRideIDs"
        )
    }

    // MARK: - Harness

    /// A private suite, so nothing here can reach `UserDefaults.standard` — the
    /// `RecentDestinationsTests` / `OwnerDispatchColdLaunchTests` precedent.
    private func scratchDefaults(
        _ name: String = "myr416.\(UUID().uuidString)"
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeRecord(id: String, status: MyRoboTaxi.RideRequestStatus) -> RideRequestRecord {
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
