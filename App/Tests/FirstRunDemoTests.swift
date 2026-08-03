import XCTest
import DesignSystem
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

// MARK: - MYR-444 — the kill switch

/// The client's ask, as assertions: the walkthrough must not fire on ANY first
/// entry, and re-enabling it must be one constant.
///
/// These are written against the SHIPPING default — no `enabled:` argument — so
/// they fail the moment the constant is flipped back without the client's say-so,
/// which is precisely the guard this issue wants. Every MYR-428 rule underneath
/// is still asserted, one suite down, with the switch passed explicitly.
final class FirstRunDemoKillSwitchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testTheSwitchIsOff() {
        XCTAssertFalse(
            FirstRunDemo.enabled,
            "MYR-444: the first-run demo is disabled until the client has refined it"
        )
    }

    /// No demo on a first OWNER entry — a fresh sign-in, a mode switch, or the
    /// hand-off after pairing a Tesla. All of them ask this one function.
    func testNoDemoOnAFirstOwnerEntry() {
        XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(for: .owner, record: FirstRunDemoRecord()))
    }

    /// No demo on a first RIDER entry — a fresh sign-in, a switch into rider
    /// mode, or MYR-426's invite-link arrival.
    func testNoDemoOnAFirstRiderEntry() {
        XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(for: .rider, record: FirstRunDemoRecord()))
    }

    /// The sweep, over the whole role set and over every record shape a first
    /// entry can arrive with: nothing plays, for anybody, on any path.
    func testNothingPlaysForAnyRoleOnAnyRecord() {
        let records = [
            FirstRunDemoRecord(),
            FirstRunDemoRecord().marking(.owner, at: t0),
            FirstRunDemoRecord().marking(.rider, at: t0),
            FirstRunDemoRecord.allSeen(at: t0)
        ]
        for role in FirstRunDemoRole.allCases {
            for record in records {
                XCTAssertFalse(
                    FirstRunDemoGate.playsWalkthrough(for: role, record: record),
                    "\(role) must not play while the demo is disabled"
                )
            }
        }
    }

    /// **RE-ENABLING IS ONE CONSTANT.** Passing the switch back on restores the
    /// MYR-428 behaviour whole, with nothing else changed — which is what makes
    /// this a disable rather than a removal, and what the refinement round will
    /// flip. It also proves the code under the switch is still live rather than
    /// unreachable.
    func testFlippingTheOneSwitchRestoresTheWholeFeature() {
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(
            for: .owner, record: FirstRunDemoRecord(), enabled: true
        ))
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(
            for: .rider, record: FirstRunDemoRecord(), enabled: true
        ))
    }
}

/// The MYR-428 rules, unchanged and still asserted — **gated on the switch
/// rather than deleted**, so the record semantics the refinement round inherits
/// are still proven rather than merely present.
final class FirstRunDemoGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// First entry into owner mode plays the owner walkthrough.
    func testFirstOwnerEntryPlays() {
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(
            for: .owner, record: FirstRunDemoRecord(), enabled: true
        ))
    }

    /// First entry into rider mode plays the rider walkthrough.
    func testFirstRiderEntryPlays() {
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(
            for: .rider, record: FirstRunDemoRecord(), enabled: true
        ))
    }

    /// …and each fires exactly once.
    func testASeenRoleNeverPlaysAgain() {
        let record = FirstRunDemoRecord().marking(.owner, at: t0)
        XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(
            for: .owner, record: record, enabled: true
        ))
        XCTAssertTrue(FirstRunDemoGate.playsWalkthrough(
            for: .rider, record: record, enabled: true
        ), "The rider walkthrough is still owed")
    }

    func testNothingPlaysWhenTheWalkthroughIsUnavailable() {
        for role in FirstRunDemoRole.allCases {
            XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(
                for: role, record: FirstRunDemoRecord(), isAvailable: false, enabled: true
            ))
        }
    }

    /// **THE DEBUG SCENES STILL BOOT THE WALKTHROUGH**, which is the other half of
    /// "disable, don't delete": they seed `initialScreen` directly and never ask
    /// the gate, so the refinement round can still drive and photograph the demo
    /// on a build where no tester can reach it. `FirstRunDemoUITests` proves it in
    /// a running app; this is the structural pin that the routing did not move.
    func testTheDebugScenesStillBootTheWalkthrough() {
        XCTAssertEqual(DebugScene.initialScreen(for: .ownerDemo), .ownerTutorial)
        XCTAssertEqual(DebugScene.initialScreen(for: .riderDemo), .riderTutorial)
    }

    /// …and no OTHER scene grew one on the way past. The demo scenes are the two
    /// arms MYR-428 named, and they are still the only two.
    func testNoOtherSceneRoutesToATutorial() {
        for scene in DebugScene.allCases where scene != .ownerDemo && scene != .riderDemo {
            let screen = DebugScene.initialScreen(for: scene)
            XCTAssertNotEqual(screen, .ownerTutorial, "\(scene) must not boot a walkthrough")
            XCTAssertNotEqual(screen, .riderTutorial, "\(scene) must not boot a walkthrough")
        }
    }

    /// The switch OUTRANKS an available walkthrough and an unseen record both —
    /// i.e. it is checked first and cannot be talked past by the two inputs that
    /// used to decide this alone.
    func testTheSwitchOutranksEveryOtherInput() {
        for role in FirstRunDemoRole.allCases {
            XCTAssertFalse(FirstRunDemoGate.playsWalkthrough(
                for: role, record: FirstRunDemoRecord(), isAvailable: true, enabled: false
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

    /// An interactive step moves only on the milestone it named.
    func testAnInteractiveStepAdvancesOnlyOnItsOwnMilestone() {
        let run = FirstRunDemoRun(role: .rider)   // riderWhereTo waits on .searchOpened
        XCTAssertEqual(run.step.advance, .appReaches(.searchOpened))
        run.handleMilestone(.rideCompleted)
        XCTAssertEqual(run.index, 0, "An unrelated milestone must not move the step")
        run.handleMilestone(.searchOpened)
        XCTAssertEqual(run.index, 1)
    }

    func testAnOwnerStatusStepAdvancesOnlyOnItsOwnMilestone() {
        let run = FirstRunDemoRun(role: .owner)
        while run.step.id != "ownerDispatch" { run.advance() }
        XCTAssertEqual(run.step.advance, .appReaches(.rideArrived))

        run.handleMilestone(.rideAccepted)
        XCTAssertEqual(run.step.id, "ownerDispatch", "A different milestone must not advance the step")

        run.handleMilestone(.rideArrived)
        XCTAssertEqual(run.step.id, "ownerDroppedOff")
    }

    /// The host re-delivers the observed state on every change, not once per
    /// transition, so a repeat must be a no-op.
    func testARepeatedMilestoneAdvancesOnlyOnce() {
        let run = FirstRunDemoRun(role: .rider)
        run.handleMilestone(.searchOpened)
        run.handleMilestone(.searchOpened)
        run.handleMilestone(.searchOpened)
        XCTAssertEqual(run.index, 1, "A milestone re-delivered must not walk the cursor forward")
    }

    /// **Regression, and the reason this file's advance model changed.** The first
    /// cut had a `.tapTarget` case whose only mover was a `handleTargetTapped()`
    /// that NOTHING called — the coach-mark layer does not modify the screens it
    /// tours, so it never sees their taps. Four of twelve steps rendered no Next
    /// and could never advance; a new rider was stranded on step one of six.
    ///
    /// The structural guarantee that replaces it: **every step is either
    /// `.next` (and so carries a button) or `.appReaches` (and so is moved by
    /// state the host actually observes).** There is no third kind, and
    /// `FirstRunDemoHostMilestoneTests` pins that the host can produce each
    /// milestone the scripts wait on.
    func testEveryStepHasAWorkingWayForward() {
        for role in FirstRunDemoRole.allCases {
            for step in FirstRunDemoScript.steps(for: role) {
                switch step.advance {
                case .next:
                    continue // the caption renders a button
                case .appReaches(let milestone):
                    let run = FirstRunDemoRun(role: role)
                    while run.step.id != step.id { run.advance() }
                    let before = run.index
                    run.handleMilestone(milestone)
                    XCTAssertEqual(
                        run.index, before + 1,
                        "\(step.id) cannot be advanced by the milestone it waits on"
                    )
                }
            }
        }
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

    /// A step's caption must never sit in the half of the screen its subject
    /// occupies.
    ///
    /// **This test used to be a tautology, and that is how the defect it now
    /// catches shipped.** It read `let subjectIsLow = (placement == .top)` and then
    /// asserted `placement == .top` equalled it — i.e. `x == x`, green for any
    /// table whatsoever, including the one that filed the bottom-sheet incoming
    /// card as top chrome and put the caption over its own "Accept & send".
    /// The subject half is a SEPARATE declaration now (`DemoAnchor.subjectHalf`),
    /// so this compares two things instead of one thing with itself.
    ///
    /// It is still only half the guard — a table can be independently stated and
    /// still wrong about a screen. `FirstRunDemoUITests
    /// .testNoCaptionOverlapsTheControlItNames` is the other half: it measures the
    /// two frames in a running app.
    func testTheCaptionNeverCoversItsOwnSubject() {
        for role in FirstRunDemoRole.allCases {
            for step in FirstRunDemoScript.steps(for: role) {
                let placement = DemoCaptionPlacement.forAnchor(step.anchor)
                switch step.anchor.subjectHalf {
                case .lower:
                    XCTAssertEqual(placement, .top,
                                   "\(step.id): subject is in the lower half, so the caption must take the top")
                case .upper:
                    XCTAssertEqual(placement, .bottom,
                                   "\(step.id): subject is in the upper half, so the caption must take the bottom")
                }
            }
        }
    }

    /// **Both clearances are DERIVED from the chrome they clear, not chosen.** The
    /// top edge always was (`OwnerMapTopChrome.dispatchCardTop`); the bottom edge
    /// was a bare 18 from the physical edge, which put the caption's SKIP row under
    /// the floating tab bar — seen in the `ownerDroppedOff` capture, not in any
    /// test. A number that is not read off the chrome stops being true the moment
    /// the chrome moves.
    func testBothCaptionClearancesAreReadOffTheChromeTheyClear() {
        XCTAssertEqual(DemoCoachMarkOverlay.topChromeClearance, OwnerMapTopChrome.dispatchCardTop,
                       "the top clearance is the map's own below-the-switcher constant")
        XCTAssertEqual(DemoCoachMarkOverlay.bottomChromeClearance,
                       MRTMetrics.bottomNavTopEdge + DemoCoachMarkOverlay.captionGutter,
                       "the bottom clearance is the floating nav's own top edge plus one gutter")
        XCTAssertGreaterThan(DemoCoachMarkOverlay.bottomChromeClearance, MRTMetrics.bottomNavTopEdge,
                             "a bottom-placed caption must sit entirely above the tab bar")
    }

    /// The two anchors whose subject is the OWNER DISPATCH CARD are the only upper
    /// ones, and every anchor that names a bottom sheet or a tab bar is lower.
    /// Pinned explicitly because `subjectHalf` is the input the rule above derives
    /// from — a rule cannot check its own premise, so the premise is asserted
    /// against the screens' layout grammar here, by name.
    func testTheSubjectHalvesMatchTheScreensTheyName() {
        XCTAssertEqual(DemoAnchor.ownerDispatchCard.subjectHalf, .upper,
                       "the dispatch card is pinned at OwnerMapTopChrome.dispatchCardTop")
        XCTAssertEqual(DemoAnchor.ownerDispatchAction.subjectHalf, .upper,
                       "the dispatch action rides on the dispatch card")

        // IncomingRequestSheet is a BOTTOM sheet — top-radii only, bottom safe area
        // ignored, CTA row last. Both of these were filed as upper and shipped a
        // caption over the button the step tells the tester to tap.
        XCTAssertEqual(DemoAnchor.ownerIncomingCard.subjectHalf, .lower)
        XCTAssertEqual(DemoAnchor.ownerAcceptButton.subjectHalf, .lower)

        for anchor in [DemoAnchor.ownerVehicleHero, .ownerTabBar, .riderSearchBar,
                       .riderDestinationList, .riderRequestButton, .riderTrackingSheet,
                       .riderSummaryCard, .riderTabBar] {
            XCTAssertEqual(anchor.subjectHalf, .lower,
                           "\(anchor.rawValue) names a bottom sheet or a bottom nav")
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
