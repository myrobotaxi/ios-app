import XCTest

// MARK: - Sheet-feel measurement harness (MYR-236 round 2)
//
// Round 1 rewrote the drag physics with unit-tested math but never MEASURED
// feel, and it shipped still-janky on the client's device. This target makes
// fluidity objective: it synthesizes real touches on the one genuinely
// draggable peek↔half sheet in the app — the owner Live Map `MRTDetentSheet`
// (`ownerHome` scene) — and asserts it tracks the finger and crosses detents.
//
// Why `ownerHome` and not `idle`/`search`: the rider `idle` greeting sheet is a
// FIXED-height card (no height drag) and `search` only has a drag-to-DISMISS
// handle. The peek↔half "moved up and down" sheet the client is dragging ships
// only in the owner Live Map. See the PR body.
//
// XCUITest cannot read a view mid-continuous-gesture (the gesture blocks the
// test thread until lift-off), so per-frame tracking numbers come from the
// app's own `MRT_SHEET_TRACE=1` log (a `(requested, rendered)` height sample
// per drag frame) which the CI step parses. These tests assert the OBSERVABLE
// outcomes — the sheet grows/shrinks to the right detent — that prove tracking
// and velocity-projected snapping end-to-end.
final class SheetFeelUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchOwnerHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "ownerHome"
        app.launchEnvironment["MRT_SHEET_TRACE"] = "1"
        app.launch()
        return app
    }

    private func sheet(in app: XCUIApplication) -> XCUIElement {
        element(id: "mrt.detentSheet", in: app)
    }

    private func element(id: String, in app: XCUIApplication) -> XCUIElement {
        let byId = app.otherElements[id]
        if byId.waitForExistence(timeout: 12) { return byId }
        // Fallback: some SwiftUI accessibility groupings surface the id on a
        // different element class.
        return app.descendants(matching: .any)[id]
    }

    // MARK: Rider idle↔search engine (MYR-236 round 4)

    private func launchRider(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launchEnvironment["MRT_SHEET_TRACE"] = "1"
        app.launch()
        return app
    }

    private func riderSheet(in app: XCUIApplication) -> XCUIElement {
        element(id: "mrt.riderSheet", in: app)
    }

    /// A grab point 12pt below the sheet's top edge — inside the handle strip
    /// regardless of the element's frame height. (Round 3 made the frame a
    /// constant surface height with the below-screen part clipped, so a
    /// normalized fraction of it no longer lands on the handle reliably.)
    private func handleGrab(on sheet: XCUIElement) -> XCUICoordinate {
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
    }

    /// The sheet's frame once its settle spring has finished — reading
    /// `frame` immediately after a fast synthesized flick races the ~0.42s
    /// snap animation and asserts against a mid-flight position. Polls until
    /// two consecutive samples agree within half a point (max ~2.5s).
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        for _ in 0..<24 {
            usleep(100_000)
            let now = element.frame
            if abs(now.minY - last.minY) < 0.5 { return now }
            last = now
        }
        return last
    }

    /// SLOW drag up (press-and-hold, ~20 sample frames) must track the finger
    /// and settle at the taller `half` detent — the sheet's top rises well
    /// above where it rested. During this drag the app logs the per-frame
    /// tracking series the CI step turns into a max-tracking-error number.
    func testSlowDragUpReachesHalfDetent() {
        let app = launchOwnerHome()
        let s = sheet(in: app)
        XCTAssertTrue(s.exists, "detent sheet should be on screen in ownerHome")

        let startFrame = s.frame
        // Grab the handle strip and drag toward the top of the screen. A long
        // press duration makes the synthesized drag slow (many intermediate
        // touch samples).
        let grab = handleGrab(on: s)
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        grab.press(forDuration: 1.3, thenDragTo: target)

        let endFrame = settledFrame(of: s)
        NSLog("MRT_HARNESS slowDragUp startMinY=\(startFrame.minY) endMinY=\(endFrame.minY) startH=\(startFrame.height) endH=\(endFrame.height)")
        XCTAssertLessThan(
            endFrame.minY, startFrame.minY - 80,
            "a slow drag up should track to the half detent (sheet top rises)"
        )
    }

    /// FAST up-flick from peek must cross the midpoint to `half` — the
    /// velocity-projected release (`SheetPhysics.projection`). A short-duration
    /// coordinate drag is a real high-velocity flick that the SwiftUI
    /// `DragGesture` recognizes (XCUI's `swipeUp` flick does not register with a
    /// non-priority `.gesture`, so we drive coordinates directly).
    func testFastFlickUpCrossesToHalf() {
        let app = launchOwnerHome()
        let s = sheet(in: app)
        XCTAssertTrue(s.exists)

        let startFrame = s.frame
        let up = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        // Explicit fast velocity: the plain thenDragTo variant sometimes ends
        // the synthesized gesture with a stationary hold, releasing at ~zero
        // velocity and turning the "flick" into a slow drag (flaky).
        handleGrab(on: s).press(
            forDuration: 0.05, thenDragTo: up, withVelocity: .fast, thenHoldForDuration: 0
        )

        let endFrame = settledFrame(of: s)
        NSLog("MRT_HARNESS flickUp startMinY=\(startFrame.minY) endMinY=\(endFrame.minY)")
        XCTAssertLessThan(
            endFrame.minY, startFrame.minY - 80,
            "a fast up-flick should cross to the half detent"
        )
    }

    /// FAST down-flick from `half` must return to `peek` — the sheet shrinks
    /// back to its resting height.
    func testFastFlickDownReturnsToPeek() {
        let app = launchOwnerHome()
        let s = sheet(in: app)
        XCTAssertTrue(s.exists)
        let peekFrame = s.frame

        // Get to half first (slow drag up), then flick down.
        handleGrab(on: s)
            .press(forDuration: 1.0, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
        let halfFrame = settledFrame(of: s)
        XCTAssertLessThan(halfFrame.minY, peekFrame.minY - 80, "precondition: sheet is at half")

        // Grab the handle of the now-raised sheet and flick down fast (explicit
        // velocity — see testFastFlickUpCrossesToHalf).
        handleGrab(on: s).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)),
            withVelocity: .fast, thenHoldForDuration: 0
        )
        let endFrame = settledFrame(of: s)
        NSLog("MRT_HARNESS flickDown peekMinY=\(peekFrame.minY) halfMinY=\(halfFrame.minY) endMinY=\(endFrame.minY)")
        XCTAssertLessThan(
            abs(endFrame.minY - peekFrame.minY), 30,
            "a fast down-flick should return the sheet to the peek detent"
        )
    }

    /// From the `search` debug scene, a SLOW drag DOWN on the rider sheet tracks
    /// continuously and settles to the idle greeting card — the sheet's top edge
    /// (its `minY`) descends well below the tall search position. Proves the
    /// continuous search→idle drag the client asked for (round 3: it "just re-
    /// renders to the good-morning card" with no motion).
    func testRiderSearchSlowDragDownCollapsesToIdle() {
        let app = launchRider(scene: "search")
        let s = riderSheet(in: app)
        XCTAssertTrue(s.exists, "rider sheet should be on screen in the search scene")

        let searchFrame = s.frame
        // Grab the handle strip at the sheet's top edge and drag toward the
        // bottom. A long press makes the synthesized drag slow (many samples).
        let grab = handleGrab(on: s)
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        grab.press(forDuration: 1.3, thenDragTo: target)

        let endFrame = settledFrame(of: s)
        NSLog("MRT_HARNESS riderDragDown searchMinY=\(searchFrame.minY) endMinY=\(endFrame.minY)")
        XCTAssertGreaterThan(
            endFrame.minY, searchFrame.minY + 120,
            "a slow drag down should collapse the search sheet to the idle card (top edge descends)"
        )
    }

    /// Capture a full-frame screenshot into the result bundle (kept always) — the
    /// PR's fixed-state evidence, straight from the driven flow (MYR-248).
    private func attachFullFrame(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = named
        add(shot)
    }

    /// Whether ANY text field currently carries `substring` as its value — the
    /// search destination row is a `TextField`, so its content is a field value,
    /// not a static text. Used to detect a stale/fresh destination on reopen.
    private func destinationFieldShows(_ substring: String, in app: XCUIApplication) -> Bool {
        for i in 0..<app.textFields.count {
            if let value = app.textFields.element(boundBy: i).value as? String, value.contains(substring) {
                return true
            }
        }
        return false
    }

    // MARK: MYR-248 — regressions from the round-4/5 continuous idle↔search sheet

    /// BUG 1 — back-nav from pin-drop must restore the search sheet to its
    /// BOTTOM-ANCHORED search detent, not strand it at the TOP of the screen.
    ///
    /// The `pinDropBackRealPath` scene replays the real path through the pin-drop
    /// back-nav (idle → search → choose destination + Continue → pinDrop → "Change
    /// trip" back → search) with a seeded simulated fix so the route-preview map
    /// is behind the sheet (the exact `routePreviewActive` relayout that triggered
    /// the client's strand). Before the PanSheet fix a transient over-measurement
    /// settled the surface toward a stale tall detent that the corrected detent
    /// never replaced (the mid-settle `update` bail), leaving the surface
    /// translated far UP — the sheet's top edge near y≈0. After the fix the sheet
    /// rests bottom-anchored, its top edge well into the lower half of the screen.
    func testPinDropBackNavRestoresBottomAnchoredSheet() {
        let app = launchRider(scene: "pinDropBackRealPath")
        let s = riderSheet(in: app)
        XCTAssertTrue(s.exists, "rider sheet should be on screen after the back-nav replay")

        // The replay drives idle → search → Continue → pinDrop → back over ~9s;
        // wait for the returned search sheet's CTA to land, then let it settle.
        XCTAssertTrue(
            app.buttons["Continue"].waitForExistence(timeout: 20),
            "the returned search sheet should show its Continue CTA"
        )
        let endFrame = settledFrame(of: s)
        let screen = app.windows.firstMatch.frame
        NSLog("MRT_HARNESS pinDropBack sheetMinY=\(endFrame.minY) sheetMaxY=\(endFrame.maxY) screenH=\(screen.height)")

        // BOTTOM-ANCHORED invariant (height-agnostic): the sheet's bottom edge
        // reaches the physical bottom of the screen (the surface runs flush to the
        // bottom, its overshoot pad hanging just past it → maxY ≥ screen bottom).
        // The stranded-at-top bug pushed the whole surface UP, so its bottom edge
        // sat well ABOVE the screen bottom with the map showing beneath it.
        XCTAssertGreaterThan(
            endFrame.maxY, screen.height - 10,
            "after pin-drop back-nav the search sheet must be bottom-anchored (bottom edge at the physical bottom), not stranded at the top with the map below it"
        )
        // And its top edge is on-screen, not shoved off the top (the strand parked
        // the surface top near/above y≈0).
        XCTAssertGreaterThan(
            endFrame.minY, 40,
            "the bottom-anchored search sheet's top edge is on-screen, not stranded above the top"
        )
        attachFullFrame(app, named: "myr248-bug1-after-backnav-restored")
    }

    /// BUG 2 — collapsing the search sheet to idle must FULLY reset the draft, so
    /// reopening search is FRESH (empty destination), never resurrecting the prior
    /// choice with a dead Continue.
    ///
    /// From `searchSelected` (a destination chosen, "Continue" CTA), drag the
    /// sheet DOWN to collapse it to the idle greeting, then drag back UP to reopen
    /// search. Before the fix the persistently-hosted search content kept its
    /// local field/CTA state across the collapse, so the reopened sheet showed the
    /// stale "SFO · Terminal 2" + an enabled-but-inert Continue. After the fix the
    /// reopened search is fresh: no stale destination text, no Continue CTA.
    func testCollapseToIdleThenReopenSearchIsFresh() {
        let app = launchRider(scene: "searchSelected")
        let s = riderSheet(in: app)
        XCTAssertTrue(s.exists, "rider sheet should be on screen in the searchSelected scene")
        // The chosen-destination state renders the Continue CTA and fills the
        // destination field with the picked place — both are the precondition.
        XCTAssertTrue(
            app.buttons["Continue"].waitForExistence(timeout: 12),
            "precondition: the Continue CTA is shown for the chosen destination before collapse"
        )
        XCTAssertTrue(
            destinationFieldShows("SFO", in: app),
            "precondition: the destination field carries the chosen place before collapse"
        )

        // Collapse to idle (slow drag down on the handle — the round-4 continuous
        // collapse that must run the full `closeToIdle` draft reset).
        handleGrab(on: s).press(
            forDuration: 1.3,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        )
        _ = settledFrame(of: s)

        // Reopen search by dragging the greeting card back up.
        handleGrab(on: s).press(
            forDuration: 1.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        )
        _ = settledFrame(of: s)

        NSLog("MRT_HARNESS freshReopen staleDest=\(destinationFieldShows("SFO", in: app)) continue=\(app.buttons["Continue"].exists)")
        // FRESH: the reopened search must not render the (dead) Continue CTA — its
        // guard blocks after the reset (enabled iff actionable) — and must not
        // resurrect the prior destination in the field.
        XCTAssertFalse(
            app.buttons["Continue"].exists,
            "reopened search must not render an enabled-but-inert Continue CTA (enabled iff actionable)"
        )
        XCTAssertFalse(
            destinationFieldShows("SFO", in: app),
            "reopened search must be fresh — the prior destination must not be restored in the field"
        )
        attachFullFrame(app, named: "myr248-bug2-after-fresh-reopen")
    }

    /// From the `idle` debug scene, a drag UP on the greeting card reaches the
    /// taller search height — the sheet's top edge rises well above the idle
    /// resting position. Proves the continuous idle→search drag.
    func testRiderIdleDragUpReachesSearch() {
        let app = launchRider(scene: "idle")
        let s = riderSheet(in: app)
        XCTAssertTrue(s.exists, "rider sheet should be on screen in the idle scene")

        let idleFrame = s.frame
        let grab = handleGrab(on: s)
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        grab.press(forDuration: 1.1, thenDragTo: target)

        let endFrame = settledFrame(of: s)
        NSLog("MRT_HARNESS riderDragUp idleMinY=\(idleFrame.minY) endMinY=\(endFrame.minY)")
        XCTAssertLessThan(
            endFrame.minY, idleFrame.minY - 120,
            "a drag up from idle should reach the search height (top edge rises)"
        )
    }
}
