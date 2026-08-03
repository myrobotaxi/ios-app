import XCTest

// MARK: - MYR-428 — the walkthrough, driven in a running app
//
// **THESE EXIST BECAUSE THE UNIT TESTS PASSED WHILE THE FEATURE WAS BROKEN.**
// The first cut of this issue shipped a green 1951-test suite in which four of
// the twelve steps could never advance: their `.tapTarget` advance was moved by a
// `handleTargetTapped()` that nothing called, because the coach-mark layer
// deliberately does not modify the screens it tours and so never sees their taps.
// A brand-new rider would have been stranded on step one of six, in the first
// minute of the first launch. No pure test could see it — the defect was in the
// wiring between the cursor and the app, which is precisely the seam a unit test
// substitutes away. MYR-387's lesson, paid for again.
//
// So what these assert is not the state machine (that is
// `FirstRunDemoTests`) but the three things only a running app can show:
//
//  1. the coach-mark overlay PASSES TAPS THROUGH to the real control underneath —
//     the layer is a full-bleed `Color.clear` with `allowsHitTesting(false)` and
//     only the caption card taking touches, and that is a claim about UIKit hit
//     testing that has to be demonstrated, not reasoned about;
//  2. tapping that real control ADVANCES the walkthrough to the named next step,
//     through the app state the control mutates;
//  3. Skip, from mid-walkthrough, lands on the role's REAL home surface.
//
// Every step also files its full-frame screenshot as an attachment, which is how
// the PR's capture strip is produced — and how the caption-over-the-switcher
// defect was caught with the first two frames.

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

    private func step(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "mrt.demo.step.\(id)").firstMatch
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

    // MARK: - Owner

    /// Step 1 renders, and the caption's own Next advances it.
    func testOwnerWalkthroughOpensOnStepOneAndNextAdvances() {
        let app = launch("ownerDemo")
        assertOnStep(app, "ownerLiveMap", capture: "owner-1-ownerLiveMap")

        XCTAssertTrue(control(app, "mrt.demo.skip").exists, "Skip must be present on step 1")

        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "ownerIncoming", capture: "owner-2-ownerIncoming")
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
        XCTAssertTrue(arrived.isHittable)
        arrived.tap()
        assertOnStep(app, "ownerDroppedOff", capture: "owner-5-ownerDroppedOff")

        let droppedOff = app.buttons["Dropped off"].firstMatch
        XCTAssertTrue(
            droppedOff.waitForExistence(timeout: 20),
            "Dropped off must be reachable — the walkthrough plays the rider's startRide so it can be"
        )
        droppedOff.tap()
        assertOnStep(app, "ownerTabs", capture: "owner-6-ownerTabs")

        // The last step still offers Skip, and its Next carries the closing CTA.
        XCTAssertTrue(control(app, "mrt.demo.skip").exists, "Skip must survive to the last step")
        XCTAssertTrue(control(app, "mrt.demo.next").exists)
    }

    /// Skip mid-walkthrough lands on the owner's real home surface.
    func testOwnerSkipLandsOnTheRealOwnerHome() {
        let app = launch("ownerDemo")
        assertOnStep(app, "ownerLiveMap")
        control(app, "mrt.demo.next").tap()
        assertOnStep(app, "ownerIncoming")

        control(app, "mrt.demo.skip").tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "mrt.demo.host")
                .firstMatch.waitForNonExistence(timeout: 10),
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

    /// **The hit-testing proof, rider side.** The idle sheet's search bar carries
    /// no identifier of its own (and this issue must not modify the screens it
    /// tours — MYR-379 is editing them), so it is reached by its position inside
    /// the sheet the way a thumb reaches it.
    func testRiderSearchTapPassesThroughTheOverlayAndAdvances() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo")

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "mrt.riderSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        // The gold search bar sits just under the greeting line, in the sheet's
        // upper third — under the coach-mark card's band, which is the point.
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).tap()

        assertOnStep(app, "riderDestination", capture: "rider-2-riderDestination")
    }

    /// The destination row is a real, identified control (`mrt.search.dest.<id>`)
    /// and picking one must carry the walkthrough to the request step.
    func testRiderDestinationPickAdvancesToTheRequestStep() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo")

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "mrt.riderSheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).tap()
        assertOnStep(app, "riderDestination")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "mrt.search.dest."))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "a real destination row must be offered")
        XCTAssertTrue(row.isHittable, "the coach-mark overlay must not block the destination list")
        row.tap()

        assertOnStep(app, "riderRequest", capture: "rider-3-riderRequest")
    }

    func testRiderSkipLandsOnTheRealRiderHome() {
        let app = launch("riderDemo")
        assertOnStep(app, "riderWhereTo")

        control(app, "mrt.demo.skip").tap()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "mrt.demo.host")
                .firstMatch.waitForNonExistence(timeout: 10),
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
    // and photographs both sides.

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
