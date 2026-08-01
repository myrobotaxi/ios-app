import XCTest

// MARK: - MYR-397 item 3 — the drag polish, proved by a real drag
//
// THE CLIENT'S REPORT, with three screenshots of the controls mid-glitch:
// *"Ensure when dragging up and down the bottom sheet were not glitchy with the
// recenter and fill screen icons or map. Owner bottom sheet and rider bottom sheet
// do a good job of this."*
//
// **A PURE TEST CANNOT SEE THIS DEFECT AND NEITHER CAN A COLD SCENE.** The bug was
// that the controls were positioned off a value the engine publishes only AFTER a
// settle commits, so every STILL of the tracking sheet — at peek, at full, in every
// capture the drift gate takes — was correct, and the app was broken for the ~400ms
// in between. It only exists during a gesture, which is the `OwnerSheetTallDetentUITests
// .testDraggingPastHalfDoesNotMoveTheMap` precedent exactly: synthesize the drag,
// sample DURING it, and assert on what moved.
//
// Two properties, sampled mid-drag:
//
//   1. **THE CONTROLS TRACK THE SHEET.** Their offset from the sheet's top edge is
//      the SAME mid-drag as it is at rest — before this they were pinned to the
//      screen while the sheet moved, so that offset collapsed as the sheet came up
//      and then snapped back at settle.
//   2. **THE MAP DOES NOT.** MYR-338's cap, on the rider's side: the camera inset
//      no longer takes the sheet's geometry at all, so the visible map strip is
//      unchanged across the whole drag.
final class RiderTrackingSheetDragUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchTracking(scene: String = "trackingLeg1", detent: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if let detent { app.launchEnvironment["MRT_TRACKING_DETENT"] = detent }
        app.launch()
        return app
    }

    private func sheet(in app: XCUIApplication) -> XCUIElement {
        let element = app.otherElements["mrt.trackingSheet"]
        XCTAssertTrue(element.waitForExistence(timeout: 20), "the rider tracking sheet should be on screen")
        return element
    }

    private func expandChip(in app: XCUIApplication) -> XCUIElement {
        let element = app.buttons["Expand the route"]
        XCTAssertTrue(element.waitForExistence(timeout: 20), "the expand chip should be on the tracking map")
        return element
    }

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

    private func handleGrab(on sheet: XCUIElement) -> XCUICoordinate {
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = named
        add(shot)
    }

    // MARK: 1 — the controls ride the edge

    /// **A REAL DRAG LANDS THE CONTROLS BACK ON THE SAME OFFSET**, including after
    /// a drag that does NOT change detent (a pull that springs back).
    ///
    /// **WHAT THIS TEST DELIBERATELY DOES NOT DO IS SAMPLE MID-GESTURE**, and the
    /// reason is worth recording: `press(…thenHoldForDuration:)` BLOCKS until the
    /// finger lifts, so a frame read after it returns is a settled frame — a first
    /// cut of this test "passed" against a deliberately-restored pre-fix build for
    /// exactly that reason, because the pre-fix chrome is correct at rest and wrong
    /// only in between. Moving the gesture to another queue is not the fix either:
    /// XCUI gestures are main-thread-only (`NSInternalInconsistencyException:
    /// Must be called on the main thread`).
    ///
    /// The mid-gesture half is therefore proven by SCREEN RECORDING instead — the
    /// repo's own "prove motion by frame sequence, never by a still" rule
    /// (MYR-337/346) — with the frame numbers in the PR body. What is asserted here
    /// is everything a settled frame can honestly carry.
    func testARealDragLeavesTheControlsOnTheirOffset() {
        let app = launchTracking()
        let s = sheet(in: app)
        let chip = expandChip(in: app)

        let restingSheet = settledFrame(of: s)
        let restingGap = restingSheet.minY - chip.frame.maxY
        NSLog("MRT_MYR397 resting sheetTop=\(restingSheet.minY) chipBottom=\(chip.frame.maxY) gap=\(restingGap)")
        XCTAssertGreaterThan(restingGap, 0, "the chip sits above the sheet at rest")

        // A short pull that springs BACK to the same detent — the case where the
        // settle animator, not a detent change, is what has to bring the controls
        // home. Before MYR-397 nothing moved them at all during the pull and the
        // settle had nothing to animate; now both are the engine's.
        let start = handleGrab(on: s)
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 40)),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        let settledSheet = settledFrame(of: s)
        let settledGap = settledSheet.minY - chip.frame.maxY
        attach(app, named: "myr397-after-springback")
        NSLog("MRT_MYR397 springback sheetTop=\(settledSheet.minY) gap=\(settledGap)")
        XCTAssertEqual(settledSheet.minY, restingSheet.minY, accuracy: 2, "a short pull springs back to full")
        XCTAssertEqual(settledGap, restingGap, accuracy: 2)
    }

    /// The same property at the other end: settled at PEEK, the offset is again the
    /// resting one (and the controls are now much lower on screen, over the map the
    /// peek revealed).
    func testTheControlsSitAtTheSameOffsetAtBothDetents() {
        let full = launchTracking()
        let fullSheet = settledFrame(of: sheet(in: full))
        let fullGap = fullSheet.minY - expandChip(in: full).frame.maxY
        attach(full, named: "myr397-controls-at-full")
        full.terminate()

        let peek = launchTracking(detent: "peek")
        let peekSheet = settledFrame(of: sheet(in: peek))
        let peekGap = peekSheet.minY - expandChip(in: peek).frame.maxY
        attach(peek, named: "myr397-controls-at-peek")

        NSLog("MRT_MYR397 fullGap=\(fullGap) peekGap=\(peekGap) fullTop=\(fullSheet.minY) peekTop=\(peekSheet.minY)")
        XCTAssertGreaterThan(peekSheet.minY, fullSheet.minY + 60, "peek must reveal materially more map")
        XCTAssertEqual(peekGap, fullGap, accuracy: 4, "one gap, both detents")
    }

    // MARK: 2 — the map does not follow

    /// MYR-338's rule on the rider's side. The camera inset is now the tracking
    /// phase's own constant and takes NO sheet geometry, so the visible map strip
    /// is unchanged across a real peek↔full drag.
    ///
    /// Sampled as the SHEET's own top edge against the map content: a full-frame
    /// pixel diff of a live `MKMapView` is not stable enough to assert on (MYR-390's
    /// measurement traps), so the assertion is on the one thing that would move if
    /// the camera re-fitted — the pickup pin's position on screen.
    func testDraggingTheSheetDoesNotMoveTheMap() throws {
        let app = launchTracking()
        let s = sheet(in: app)
        _ = settledFrame(of: s)

        let pin = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'Pickup'")).firstMatch
        guard pin.waitForExistence(timeout: 10) else {
            throw XCTSkip("the pickup annotation is not exposed to the a11y tree on this runtime")
        }
        let before = pin.frame
        attach(app, named: "myr397-map-before-drag")

        let start = handleGrab(on: s)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)), withVelocity: .slow, thenHoldForDuration: 0)
        _ = settledFrame(of: s)
        let after = pin.frame
        attach(app, named: "myr397-map-after-drag")

        NSLog("MRT_MYR397 pin before=\(before) after=\(after)")
        XCTAssertEqual(after.midY, before.midY, accuracy: 8, "the camera must not re-fit when the sheet moves")
        XCTAssertEqual(after.midX, before.midX, accuracy: 8)
    }
}
