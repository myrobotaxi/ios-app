import XCTest

// MARK: - MYR-428 — the walkthrough, driven in a running app
//
// **THESE EXIST BECAUSE THE UNIT TESTS PASSED WHILE THE FEATURE WAS BROKEN**, and
// they have now caught that twice, in two different ways.
//
// The first cut of this issue shipped a green 1951-test suite in which four of the
// twelve steps could never advance: their `.tapTarget` advance was moved by a
// `handleTargetTapped()` that nothing called, because the coach-mark layer
// deliberately does not modify the screens it tours and so never sees their taps.
// A brand-new rider would have been stranded on step one of six.
//
// The second round found two more that no pure test could:
//
//  • **The walkthrough renamed every control in the app while it ran.** A single
//    `.accessibilityIdentifier("mrt.demo.host")` on the host's container was
//    applied by SwiftUI to every element beneath it, so Skip, Next, the tab bar,
//    the recenter button and the incoming card's own "Accept & send" all reported
//    `mrt.demo.host`. Only a dump of the real accessibility tree shows that; the
//    screen looks perfect and VoiceOver reads it correctly.
//  • **The caption sat on top of the button it told the tester to tap.** The
//    placement table called the incoming card "top chrome"; it is a bottom sheet.
//    The unit guard for this was a tautology (`x == x`), so only a measurement of
//    two frames in a running app could say so — which is `assertCaptionClears`
//    below, applied at every step that names an addressable control.
//
// So what these assert is not the state machine (that is `FirstRunDemoTests`) but
// the four things only a running app can show:
//
//  1. the coach-mark overlay PASSES TAPS THROUGH to the real control underneath —
//     the layer holds nothing that takes a touch except the caption card, and that
//     is a claim about UIKit hit testing that has to be demonstrated;
//  2. tapping that real control ADVANCES the walkthrough to the named next step,
//     through the app state the control mutates;
//  3. the caption does not COVER the control it names, measured frame to frame;
//  4. Skip, from mid-walkthrough, lands on the role's REAL home surface.
//
// Every step also files its full-frame screenshot as an attachment, which is how
// the PR's twelve-frame capture strip is produced.

final class FirstRunDemoUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scene: String, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if reduceMotion {
            // The scene list documents the `simctl` route for a human capturing
            // by hand; inside a test the launch argument is the deterministic one.
            app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "1"]
        }
        app.launch()
        return app
    }

    /// Matched across element types, the way `RiderIdleBannerUITests` does and
    /// for the same reason: which element type a SwiftUI control resolves to is
    /// not this test's business, and asserting on `.buttons` specifically is what
    /// made the first run of this file fail against a perfectly visible Skip.
    private func control(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func stepElements(_ app: XCUIApplication, _ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "mrt.demo.step.\(id)")
    }

    private func step(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        stepElements(app, id).firstMatch
    }

    /// Full-frame, kept always — these are the PR's capture strip.
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func assertOnStep(_ app: XCUIApplication, _ id: String, capture name: String? = nil) {
        XCTAssertTrue(
            step(app, id).waitForExistence(timeout: 20),
            "expected the walkthrough to be on step \(id)"
        )
        if let name { capture(app, name) }
    }

    /// The coach-mark CARD's footprint, as the union of everything it draws that
    /// the tree can see: the caption's text group plus whichever of Skip / Next is
    /// present. Deliberately not the caption text alone — the card's padding and
    /// its footer row are what actually reach down over a control, and measuring
    /// only the prose would have called the shipped overlap clean.
    private func coachCardFrame(_ app: XCUIApplication, _ stepID: String) -> CGRect {
        var rect = CGRect.null
        let texts = stepElements(app, stepID)
        for index in 0..<texts.count {
            rect = rect.union(texts.element(boundBy: index).frame)
        }
        for id in ["mrt.demo.skip", "mrt.demo.next"] {
            let element = control(app, id)
            if element.exists { rect = rect.union(element.frame) }
        }
        return rect
    }

    /// **The overlap guard, measured rather than declared.** A caption that covers
    /// the control its own copy names is the defect this replaces a tautological
    /// unit test with.
    private func assertCaptionClears(
        _ app: XCUIApplication,
        step stepID: String,
        control element: XCUIElement,
        named: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let card = coachCardFrame(app, stepID)
        XCTAssertFalse(card.isNull, "no coach-mark card found on step \(stepID)", file: file, line: line)
        XCTAssertFalse(
            card.intersects(element.frame),
            """
            \(stepID): the caption \(card) covers \(named) \(element.frame) — \
            the coach mark must take the half of the screen its subject does not
            """,
            file: file,
            line: line
        )
    }

    // MARK: - Owner

    /// Step 1 renders, and the caption's own Next advances it.
    ///
    /// `mrt.demo.next` resolving AT ALL is the regression guard for the identifier
    /// smear: before the host's container identifier was removed, this query
    /// matched nothing on any step, while the button sat on screen reading "Next".
    func testOwnerWalkthroughOpensOnStepOneAndNextAdvances() {
        let app = launch("ownerDemo")
        assertOnStep(app, "ownerLiveMap", capture: "owner-1-ownerLiveMap")

        XCTAssertTrue(control(app, "mrt.demo.skip").exists, "Skip must be present on step 1")
        XCTAssertTrue(control(app, "mrt.demo.next").exists,
                      "Next must be addressable by its own identifier, not the host's")

        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "ownerIncoming", capture: "owner-2-ownerIncoming")
    }

    /// **The identifier-smear regression guard, stated over the TOURED screen.**
    /// The walkthrough is an overlay: while it runs, the screens underneath must
    /// keep publishing their own identifiers. A container identifier on the host
    /// overwrote all of them, which is invisible to a user and fatal to every test
    /// those screens have.
    func testTheWalkthroughDoesNotRenameTheControlsOfTheScreenItTours() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo")

        XCTAssertTrue(
            control(app, "mrt.riderSheet").waitForExistence(timeout: 10),
            "the toured rider sheet must keep its own identifier while the demo is up"
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "mrt.demo.host").count, 0,
            "no element may carry the host's identifier — it smears onto the whole subtree"
        )
    }

    /// **The hit-testing proof, owner side.** Reaching step 3 and tapping the
    /// REAL "Accept & send" button — a control the coach-mark layer is drawn over
    /// and does not own — must advance the walkthrough to `ownerDispatch`.
    func testOwnerAcceptTapPassesThroughTheOverlayAndAdvances() {
        let app = launch("ownerDemo")
        assertOnStep(app, "ownerLiveMap")
        control(app, "mrt.demo.next").tap()          // → ownerIncoming (seeds the request)
        assertOnStep(app, "ownerIncoming")
        control(app, "mrt.demo.next").tap()          // → ownerAccept
        assertOnStep(app, "ownerAccept", capture: "owner-3-ownerAccept")

        // No advance affordance on an interactive step — the real control is the
        // only way on. This is the regression guard for the shipped defect.
        XCTAssertFalse(control(app, "mrt.demo.next").exists,
                       "an interactive step must not offer a Next shortcut")

        let accept = app.buttons["Accept & send"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "the real accept button must be on screen")
        assertCaptionClears(app, step: "ownerAccept", control: accept, named: "Accept & send")
        XCTAssertTrue(accept.isHittable, "the coach-mark overlay must not block the control it names")
        accept.tap()

        assertOnStep(app, "ownerDispatch", capture: "owner-4-ownerDispatch")
    }

    /// **The second owner hit-test, and the reachability proof.** `arrived` has no
    /// owner action by design (MYR-411), so the walkthrough plays the absent
    /// rider's `startRide` as a cue — without which "Dropped off" never appears
    /// and this step could never end. Driving it is what found that.
    func testOwnerDispatchAndDropOffAdvanceOnTheirRealControls() {
        let app = launch("ownerDemo")
        assertOnStep(app, "ownerLiveMap")
        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "ownerIncoming")
        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "ownerAccept")

        let accept = app.buttons["Accept & send"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        assertOnStep(app, "ownerDispatch")

        let arrived = app.buttons["Arrived at pickup"].firstMatch
        XCTAssertTrue(arrived.waitForExistence(timeout: 20), "the dispatch card's real action must appear")
        assertCaptionClears(app, step: "ownerDispatch", control: arrived, named: "Arrived at pickup")
        // These two steps are the only BOTTOM-placed captions, so they are the only
        // ones that can run under the floating tab bar — which the first capture of
        // `ownerDroppedOff` showed the SKIP row doing.
        assertCaptionClears(app, step: "ownerDispatch",
                            control: app.buttons["Drives"].firstMatch, named: "the floating tab bar")
        XCTAssertTrue(arrived.isHittable)
        arrived.tap()
        assertOnStep(app, "ownerDroppedOff", capture: "owner-5-ownerDroppedOff")

        let droppedOff = app.buttons["Dropped off"].firstMatch
        XCTAssertTrue(
            droppedOff.waitForExistence(timeout: 20),
            "Dropped off must be reachable — the walkthrough plays the rider's startRide so it can be"
        )
        assertCaptionClears(app, step: "ownerDroppedOff", control: droppedOff, named: "Dropped off")
        assertCaptionClears(app, step: "ownerDroppedOff",
                            control: app.buttons["Drives"].firstMatch, named: "the floating tab bar")
        droppedOff.tap()
        assertOnStep(app, "ownerTabs", capture: "owner-6-ownerTabs")

        // The last step still offers Skip, and its Next carries the closing CTA.
        XCTAssertTrue(control(app, "mrt.demo.skip").exists, "Skip must survive to the last step")
        XCTAssertTrue(control(app, "mrt.demo.next").exists)
        assertCaptionClears(app, step: "ownerTabs",
                            control: app.buttons["Drives"].firstMatch, named: "the Drives tab")
    }

    /// Skip mid-walkthrough lands on the owner's real home surface.
    func testOwnerSkipLandsOnTheRealOwnerHome() {
        let app = launch("ownerDemo")
        assertOnStep(app, "ownerLiveMap")
        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "ownerIncoming")

        control(app, "mrt.demo.skip").tap()

        // The step element IS the walkthrough's presence — see the note in
        // `FirstRunDemoHost` on why there is no container identifier to ask about.
        XCTAssertTrue(
            step(app, "ownerIncoming").waitForNonExistence(timeout: 10),
            "skipping must dismiss the walkthrough"
        )
        // The owner shell's own nav is the evidence we are on the real surface.
        XCTAssertTrue(app.buttons["Drives"].firstMatch.waitForExistence(timeout: 10),
                      "skip must land on the owner's real home surface")
        capture(app, "owner-skip-lands-on-home")
    }

    // MARK: - Rider

    func testRiderWalkthroughOpensOnStepOne() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo", capture: "rider-1-riderWhereTo")
        XCTAssertTrue(control(app, "mrt.demo.skip").exists)
        XCTAssertFalse(control(app, "mrt.demo.next").exists,
                       "step 1 is interactive — the real search bar is the only way on")
    }

    /// **The hit-testing proof, rider side, run end to end.** Every step is driven
    /// by the real control or by the ride itself, and each files its frame for the
    /// capture strip.
    ///
    /// The search bar carries no identifier of its own (and this issue must not
    /// modify the screens it tours — MYR-379 is editing them), but it does carry a
    /// fixed `accessibilityLabel("Where to?")`, so it is reached exactly the way
    /// VoiceOver reaches it. **A sheet-relative COORDINATE was the first attempt
    /// and it silently missed**: `mrt.riderSheet` reports a 760pt frame on an 874pt
    /// screen starting at y 588, i.e. it runs far off the bottom, so a "30% down
    /// the sheet" tap landed at y≈816 — below the Home/Work chips, on nothing. The
    /// step never advanced and the failure read as a hit-testing problem.
    func testRiderWalkthroughRunsEndToEndOnRealControls() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo")

        let searchBar = app.buttons["Where to?"].firstMatch
        XCTAssertTrue(searchBar.waitForExistence(timeout: 10), "the real search bar must be on screen")
        assertCaptionClears(app, step: "riderWhereTo", control: searchBar, named: "the search bar")
        XCTAssertTrue(searchBar.isHittable, "the coach-mark overlay must not block the search bar")
        searchBar.tap()
        assertOnStep(app, "riderDestination", capture: "rider-2-riderDestination")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "mrt.search.dest."))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "a real destination row must be offered")
        assertCaptionClears(app, step: "riderDestination", control: row, named: "a destination row")
        XCTAssertTrue(row.isHittable, "the coach-mark overlay must not block the destination list")
        row.tap()

        // The row tap FILLS the field; the gold "Continue" is what carries on
        // (MYR-215/MYR-356). The step's copy names both taps for that reason.
        //
        // ⚠️ Matched by WIDTH, not by label alone: iOS's own QuickPath keyboard
        // tutorial puts a button labelled "Continue" on screen and `app.buttons
        // ["Continue"]` finds it first — the documented trap that has already
        // produced one green-looking assertion about a system dialog in this repo.
        // The app's CTA is the sheet-width gold button; the tutorial's is not.
        // (A predicate cannot express this — `frame.size.width` is not a key path
        // XCUITest will evaluate — so the widest match is picked in Swift.)
        let continueMatches = app.buttons.matching(NSPredicate(format: "label == %@", "Continue"))
        XCTAssertTrue(continueMatches.firstMatch.waitForExistence(timeout: 15),
                      "choosing a destination must reveal the sheet's own Continue CTA")
        var continueCTA = continueMatches.firstMatch
        for index in 0..<continueMatches.count {
            let candidate = continueMatches.element(boundBy: index)
            if candidate.frame.width > continueCTA.frame.width { continueCTA = candidate }
        }
        XCTAssertGreaterThan(continueCTA.frame.width, 200,
                             "the widest Continue on screen must be the sheet's gold CTA, not a system dialog's")
        assertCaptionClears(app, step: "riderDestination", control: continueCTA, named: "the Continue CTA")
        continueCTA.tap()

        // …and Continue lands on the PIN-DROP pickup confirmation, not on Review —
        // the shipping path `pinDropRealPath` captures. The step's copy names this
        // tap too; it is the second control standing between a destination row and
        // the sheet the step actually ends on.
        let confirmPickup = app.buttons["Confirm pickup here"].firstMatch
        XCTAssertTrue(confirmPickup.waitForExistence(timeout: 15),
                      "Continue must reach the pickup confirmation the step's copy names")
        assertCaptionClears(app, step: "riderDestination",
                            control: confirmPickup, named: "Confirm pickup here")
        confirmPickup.tap()
        assertOnStep(app, "riderRequest", capture: "rider-3-riderRequest")

        let request = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Request from")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 15), "the real request CTA must be on screen")
        assertCaptionClears(app, step: "riderRequest", control: request, named: "the request CTA")
        XCTAssertTrue(request.isHittable)
        request.tap()

        // `riderTrack` ends when the simulated owner takes the request — the ride
        // itself, not a tap. Its own timers are `RideRequestTiming`'s, so this is
        // the one step whose wait is genuinely long.
        assertOnStep(app, "riderTrack", capture: "rider-4-riderTrack")
        assertOnStep(app, "riderComplete", capture: "rider-5-riderComplete")

        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "riderBoundaries", capture: "rider-6-riderBoundaries")
        XCTAssertTrue(control(app, "mrt.demo.skip").exists, "Skip must survive to the last step")
        assertCaptionClears(app, step: "riderBoundaries",
                            control: app.buttons["Ride History"].firstMatch, named: "the Ride History tab")
    }

    func testRiderSkipLandsOnTheRealRiderHome() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo")

        control(app, "mrt.demo.skip").tap()

        XCTAssertTrue(
            step(app, "riderWhereTo").waitForNonExistence(timeout: 10),
            "skipping must dismiss the walkthrough"
        )
        XCTAssertTrue(app.buttons["Ride History"].firstMatch.waitForExistence(timeout: 10),
                      "skip must land on the rider's real home surface")
        capture(app, "rider-skip-lands-on-home")
    }

    // MARK: - Reduce Motion
    //
    // The coach mark's only motion is the step transition, which falls back to a
    // cut. What matters for a first-run surface is that the caption is READABLE
    // with the animation gone, so this drives a step change under Reduce Motion
    // and photographs one frame per role.

    func testWalkthroughsRenderReadablyUnderReduceMotion() {
        let owner = launch("ownerDemo", reduceMotion: true)
        assertOnStep(owner, "ownerLiveMap", capture: "owner-reduceMotion-step1")
        control(owner, "mrt.demo.next").tap()
        assertOnStep(owner, "ownerIncoming", capture: "owner-reduceMotion-step2")
        owner.terminate()

        let rider = launch("riderDemo", reduceMotion: true)
        assertOnStep(rider, "riderWhereTo", capture: "rider-reduceMotion-step1")
    }
}
