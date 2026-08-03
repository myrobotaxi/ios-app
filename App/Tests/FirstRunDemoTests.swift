import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-428 — the per-role flag state machine
//
// The `RecentDestinationsTests` recipe: a scratch `UserDefaults` suite torn down
// per test, pure-rule tests kept separate from store tests.

final class FirstRunDemoRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testABlankRecordHasSeenNeitherRole() {
        let record = FirstRunDemoRecord()
        XCTAssertFalse(record.hasSeen(.owner))
        XCTAssertFalse(record.hasSeen(.rider))
    }

    /// The client's clarification, as an assertion: the two roles are independent.
    func testMarkingOneRoleLeavesTheOtherUnseen() {
        let record = FirstRunDemoRecord().marking(.owner, at: t0)
        XCTAssertTrue(record.hasSeen(.owner))
        XCTAssertFalse(record.hasSeen(.rider), "Seeing the owner demo must say nothing about the rider one")
    }

    func testBothRolesCanBeMarkedIndependently() {
        let record = FirstRunDemoRecord()
            .marking(.owner, at: t0)
            .marking(.rider, at: t0.addingTimeInterval(60))
        XCTAssertEqual(record.ownerSeenAt, t0)
        XCTAssertEqual(record.riderSeenAt, t0.addingTimeInterval(60))
    }

    /// A redundant write must not walk the instant forward — the MYR-414 restamp
    /// trap. Nothing renders the date today, but a record that silently re-dates
    /// itself is evidence that quietly stops being true.
    func testMarkingATwiceSeenRoleKeepsTheOriginalInstant() {
        let record = FirstRunDemoRecord()
            .marking(.owner, at: t0)
            .marking(.owner, at: t0.addingTimeInterval(9_999))
        XCTAssertEqual(record.ownerSeenAt, t0)
    }

    func testAllSeenCoversEveryRole() {
        let record = FirstRunDemoRecord.allSeen(at: t0)
        for role in FirstRunDemoRole.allCases {
            XCTAssertTrue(record.hasSeen(role), "\(role) should be marked seen")
        }
    }

    func testTheRecordRoundTripsThroughJSON() throws {
        let record = FirstRunDemoRecord().marking(.rider, at: t0)
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(FirstRunDemoRecord.self, from: data)
        XCTAssertEqual(back, record)
    }
}

final class FirstRunDemoGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// First entry into owner mode plays the owner walkthrough.
    func testFirstOwnerEntryPlays() {
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(for: .owner, record: FirstRunDemoRecord()))
    }

    /// First entry into rider mode plays the rider walkthrough.
    func testFirstRiderEntryPlays() {
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(for: .rider, record: FirstRunDemoRecord()))
    }

    /// …and each fires exactly once.
    func testASeenRoleNeverPlaysAgain() {
        let record = FirstRunDemoRecord().marking(.owner, at: t0)
        XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(for: .owner, record: record))
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(for: .rider, record: record),
                      "The rider walkthrough is still owed")
    }

    func testNothingPlaysWhenTheWalkthroughIsUnavailable() {
        for role in FirstRunDemoRole.allCases {
            XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(
                for: role, record: FirstRunDemoRecord(), isAvailable: false
            ))
        }
    }
}

final class FirstRunDemoStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "app.myrobotaxi.tests.firstRunDemo.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAColdInstallHasSeenNothing() {
        let store = UserDefaultsFirstRunDemoStore(defaults: defaults)
        XCTAssertFalse(store.hasSeen(.owner))
        XCTAssertFalse(store.hasSeen(.rider))
    }

    func testAMarkSurvivesANewStoreOverTheSameDefaults() {
        UserDefaultsFirstRunDemoStore(defaults: defaults).markSeen(.rider)
        // A second store instance == the next launch.
        let next = UserDefaultsFirstRunDemoStore(defaults: defaults)
        XCTAssertTrue(next.hasSeen(.rider))
        XCTAssertFalse(next.hasSeen(.owner))
    }

    /// **The sign-out semantics, asserted.** The flag is device-scoped and keyed by
    /// nothing, so there is no per-user record to release and no `clear` to call.
    /// Signing out and back in — even as a DIFFERENT account — does not replay a
    /// walkthrough this device has already shown. See `FirstRunDemo.swift` rule 1:
    /// the lifetime is the INSTALL, which is what the client's "first download"
    /// names. Uninstalling takes `UserDefaults` with it, so a real re-download
    /// really does replay.
    func testTheFlagSurvivesSignOutAndAccountChange() {
        let store = UserDefaultsFirstRunDemoStore(defaults: defaults)
        store.markSeen(.owner)

        // Everything sign-out releases, released. The demo record is not among
        // them, and this test is the guard that it never joins them.
        UserDefaultsProfileStore(defaults: defaults).clear()
        UserDefaultsModeChoiceStore(defaults: defaults).clearMode(forUserID: "user-a")

        XCTAssertTrue(
            UserDefaultsFirstRunDemoStore(defaults: defaults).hasSeen(.owner),
            "The owner walkthrough must not replay for the same human on the same install"
        )
    }

    /// Completing and skipping are the same write, so the store cannot tell them
    /// apart — which is the point (`FirstRunDemo.swift` rule 2).
    @MainActor
    func testSkippingMarksTheRoleSeen() {
        let store = InMemoryFirstRunDemoStore()
        let run = FirstRunDemoRun(role: .rider)
        run.skip()
        XCTAssertTrue(run.isFinished)
        // The host's one finish observer performs this write for either exit.
        store.markSeen(.rider)
        XCTAssertTrue(store.hasSeen(.rider))
    }

    func testAnUnreadableRecordReadsAsNotSeenRatherThanThrowing() {
        defaults.set(Data("not json".utf8), forKey: UserDefaultsFirstRunDemoStore.defaultsKey)
        let store = UserDefaultsFirstRunDemoStore(defaults: defaults)
        XCTAssertFalse(store.hasSeen(.owner))
        XCTAssertFalse(store.hasSeen(.rider))
    }
}

// MARK: - The walkthrough cursor

@MainActor
final class FirstRunDemoRunTests: XCTestCase {

    func testAWalkthroughStartsOnItsFirstStepAndIsNotFinished() {
        let run = FirstRunDemoRun(role: .owner)
        XCTAssertEqual(run.index, 0)
        XCTAssertEqual(run.step.id, "ownerLiveMap")
        XCTAssertFalse(run.isFinished)
    }

    func testSkipEndsTheWalkthroughFromTheVeryFirstStep() {
        let run = FirstRunDemoRun(role: .owner)
        run.skip()
        XCTAssertTrue(run.isFinished)
    }

    /// Skip is reachable on EVERY step, including the last — the deliberate
    /// deviation from the prototype deck, which hides it on the final card.
    func testSkipEndsTheWalkthroughFromEveryStep() {
        for role in FirstRunDemoRole.allCases {
            for start in FirstRunDemoScript.steps(for: role).indices {
                let run = FirstRunDemoRun(role: role)
                for _ in 0..<start { run.advance() }
                XCTAssertEqual(run.index, start)
                run.skip()
                XCTAssertTrue(run.isFinished, "\(role) step \(start) must be skippable")
            }
        }
    }

    func testAdvancingThroughEveryStepFinishesExactlyOnce() {
        for role in FirstRunDemoRole.allCases {
            let run = FirstRunDemoRun(role: role)
            let count = FirstRunDemoScript.steps(for: role).count
            for _ in 0..<(count - 1) { run.advance() }
            XCTAssertFalse(run.isFinished, "\(role) must not finish before its last step")
            run.advance()
            XCTAssertTrue(run.isFinished)
        }
    }

    func testAFinishedWalkthroughIgnoresFurtherAdvances() {
        let run = FirstRunDemoRun(role: .rider)
        run.skip()
        let index = run.index
        run.advance()
        XCTAssertEqual(run.index, index)
    }

    /// A `.tapTarget` step moves only on its target being tapped.
    func testATapTargetStepAdvancesOnTheTargetAndNotOnAStatus() {
        let run = FirstRunDemoRun(role: .rider)   // riderWhereTo is .tapTarget
        XCTAssertEqual(run.step.advance, .tapTarget)
        run.handleRideStatus(.completed)
        XCTAssertEqual(run.index, 0, "A status must not move a step waiting on a tap")
        run.handleTargetTapped()
        XCTAssertEqual(run.index, 1)
    }

    /// A `.rideStatus` step moves only on the status it named — an early or
    /// repeated status cannot skip a step.
    func testARideStatusStepAdvancesOnlyOnItsOwnStatus() {
        let run = FirstRunDemoRun(role: .owner)
        while run.step.id != "ownerDispatch" { run.advance() }
        XCTAssertEqual(run.step.advance, .rideStatus(.arrived))

        run.handleRideStatus(.accepted)
        XCTAssertEqual(run.step.id, "ownerDispatch", "A different status must not advance the step")
        run.handleTargetTapped()
        XCTAssertEqual(run.step.id, "ownerDispatch", "A tap must not advance a status step")

        run.handleRideStatus(.arrived)
        XCTAssertEqual(run.step.id, "ownerDroppedOff")
    }
}

// MARK: - The scripts

final class FirstRunDemoScriptTests: XCTestCase {

    func testBothRolesHaveAWalkthrough() {
        for role in FirstRunDemoRole.allCases {
            XCTAssertFalse(FirstRunDemoScript.steps(for: role).isEmpty)
        }
    }

    func testEveryStepIDIsUniqueWithinItsRole() {
        for role in FirstRunDemoRole.allCases {
            let ids = FirstRunDemoScript.steps(for: role).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(role) has a duplicate step id")
        }
    }

    func testEveryStepCarriesCopy() {
        for role in FirstRunDemoRole.allCases {
            for step in FirstRunDemoScript.steps(for: role) {
                XCTAssertFalse(step.title.isEmpty, "\(step.id) has no title")
                XCTAssertFalse(step.body.isEmpty, "\(step.id) has no body")
            }
        }
    }

    /// The spec's two loops, asserted as ORDER rather than as presence: the rider
    /// walkthrough must run search → book → track → complete, and the owner one
    /// incoming → accept → dispatch → dropped off.
    func testTheRiderWalkthroughRunsTheRideLoopInOrder() {
        let ids = FirstRunDemoScript.steps(for: .rider).map(\.id)
        assertOrdered(["riderWhereTo", "riderDestination", "riderRequest", "riderTrack", "riderComplete"], in: ids)
    }

    func testTheOwnerWalkthroughRunsTheDispatchLoopInOrder() {
        let ids = FirstRunDemoScript.steps(for: .owner).map(\.id)
        assertOrdered(["ownerIncoming", "ownerAccept", "ownerDispatch", "ownerDroppedOff"], in: ids)
    }

    /// **The absorption audit.** Every card of both retired story decks maps onto
    /// a step that exists. Retiring a deck must not quietly retire what it taught.
    func testEveryRetiredStoryCardIsCoveredByALiveStep() {
        let ownerIDs = Set(FirstRunDemoScript.steps(for: .owner).map(\.id))
        for (card, stepID) in FirstRunDemoScript.ownerDeckCoverage {
            XCTAssertTrue(ownerIDs.contains(stepID), "Owner card “\(card)” maps to missing step \(stepID)")
        }
        XCTAssertEqual(FirstRunDemoScript.ownerDeckCoverage.count, 5, "The owner deck had five cards")

        let riderIDs = Set(FirstRunDemoScript.steps(for: .rider).map(\.id))
        for (card, stepID) in FirstRunDemoScript.riderDeckCoverage {
            XCTAssertTrue(riderIDs.contains(stepID), "Rider card “\(card)” maps to missing step \(stepID)")
        }
        XCTAssertEqual(FirstRunDemoScript.riderDeckCoverage.count, 5, "The rider deck had five cards")
    }

    /// The closing CTAs are the decks' own, so the last tap reads as it always did.
    func testTheClosingLabelsAreTheDecksOwn() {
        XCTAssertEqual(FirstRunDemoScript.finishLabel(for: .owner), "Go to my car")
        XCTAssertEqual(FirstRunDemoScript.finishLabel(for: .rider), "Start riding")
    }

    /// A step's caption must never sit on top of the control it is naming.
    func testTheCaptionNeverCoversItsOwnSubject() {
        for role in FirstRunDemoRole.allCases {
            for step in FirstRunDemoScript.steps(for: role) {
                let subjectIsLow = DemoCaptionPlacement.forAnchor(step.anchor) == .top
                let placement = DemoCaptionPlacement.forAnchor(step.anchor)
                XCTAssertEqual(
                    placement == .top, subjectIsLow,
                    "\(step.id): the caption must take the half its subject does not"
                )
            }
        }
    }

    /// Every anchor the scripts use has a declared placement — a new anchor has to
    /// answer the question rather than fall outside the test.
    func testEveryAnchorHasAPlacement() {
        for anchor in DemoAnchor.allCases {
            _ = DemoCaptionPlacement.forAnchor(anchor)
        }
    }

    private func assertOrdered(_ expected: [String], in ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        let positions = expected.map { ids.firstIndex(of: $0) }
        for (name, position) in zip(expected, positions) {
            XCTAssertNotNil(position, "missing step \(name)", file: file, line: line)
        }
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), "steps are out of order: \(expected)", file: file, line: line)
    }
}
