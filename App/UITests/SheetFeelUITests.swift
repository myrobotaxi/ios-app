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
        let byId = app.otherElements["mrt.detentSheet"]
        if byId.waitForExistence(timeout: 12) { return byId }
        // Fallback: some SwiftUI accessibility groupings surface the id on a
        // different element class.
        return app.descendants(matching: .any)["mrt.detentSheet"]
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
}
