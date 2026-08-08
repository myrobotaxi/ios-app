import XCTest

// MARK: - MYR-460 — the follow camera, driven by a real finger
//
// The pure suites (`TrackingFollowCameraTests`) pin the state machine, and a
// pure suite is the wrong instrument for the two things this feature can
// silently get wrong, both of which live between SwiftUI's gesture arbitration
// and MapKit:
//
//   1. the rider's pan never reaches `handleUserGesture`, so the follow camera
//      keeps writing underneath their finger — MYR-222's complaint, which this
//      issue is one wrong guard away from re-introducing;
//   2. the idle re-arm never fires (or fires while they are still panning).
//
// XCUITest is also the ONLY way to produce the gesture half of the mandatory
// MYR-222 probe trace: `simctl` cannot pan a map. Run this with the camera log
// streaming to capture the trace the PR attaches —
//
//   xcrun simctl spawn <udid> log stream --level=info \
//     --predicate 'subsystem == "app.myrobotaxi.ios" AND category == "camera"'
//
// — and read it for: writes at fix cadence while armed, ZERO between
// `follow off` and `follow re-arm`, and writes resuming after it.
final class TrackingFollowCameraUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The tracking scene with MYR-460's moving-car probe streaming ~1Hz fixes
    /// into the shipping telemetry seam. Without the probe the simulated scene
    /// holds still by design, and a still car cannot show a follow camera doing
    /// anything at all.
    private func launchFollowing() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "trackingLeg2"
        app.launchEnvironment["MRT_FOLLOW_PROBE"] = "1"
        app.launch()
        return app
    }

    /// Whether the recenter control is BEING OFFERED — i.e. the follow camera
    /// has been stood down and the rider is being shown the way back.
    ///
    /// ⚠️ NEITHER OF THE TWO OBVIOUS SIGNALS WORKS ON THIS SURFACE, and both
    /// fail SILENTLY — they answer "never offered" and "always offered"
    /// respectively whatever the camera is doing, so a test written on either
    /// passes on a build where the pan never lands:
    ///
    ///   • `isHittable` is uniformly FALSE for every control here. Measured on
    ///     this scene: the three tab-bar buttons, the expand chip and this
    ///     button all report non-hittable under the full-bleed map chrome.
    ///   • `exists` is uniformly TRUE. `FloatingMapButtonControl` hides itself
    ///     with `opacity` + `allowsHitTesting`, so it never leaves the tree.
    ///     (`.accessibilityHidden(hidden)` was tried here and MEASURED not to
    ///     remove it either, so it was not kept — a modifier that compiles,
    ///     reads correctly and changes nothing is the quietest way to ship a fix
    ///     un-shipped, which this repo has already paid for once with
    ///     `.contentMargins` on the Dynamic Island.)
    ///
    /// What DOES flip is the control's own `scaleEffect(hidden ? 0.9 : 1)`,
    /// which XCUITest reports as a real frame: measured **39.6 × 39.6 hidden vs
    /// 44 × 44 offered**, 44 being the designed tap target. So the question
    /// "is the way back on screen" is asked as "is the button at full size".
    private func recenterIsOffered(_ app: XCUIApplication) -> Bool {
        let button = app.buttons["Recenter map on vehicle"]
        guard button.exists else { return false }
        return button.frame.width >= 43
    }

    private func waitForRecenter(_ app: XCUIApplication, offered: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recenterIsOffered(app) == offered { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return recenterIsOffered(app) == offered
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The map band above the tracking sheet — the only part of the map a rider
    /// can actually reach with a finger.
    private func mapPoint(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
    }

    // MARK: the whole client interaction, in one pass

    func testPanningDethronesTheFollowCameraAndItComesBackOnItsOwn() {
        let app = launchFollowing()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // Let the follow camera run armed for a few fixes first, so the trace
        // has a "writing at fix cadence" stretch to compare the silence against.
        Thread.sleep(forTimeInterval: 6)
        attach(named: "myr460-01-following-armed")

        // The rider drags the map. A real drag over the map band, not a tap:
        // `TrackingMapView` claims pans with an 8pt-minimum `DragGesture`, and a
        // shorter one would be arbitrated as the expand TAP instead.
        let start = mapPoint(app, dx: 0.5, dy: 0.30)
        let end = mapPoint(app, dx: 0.22, dy: 0.14)
        start.press(forDuration: 0.1, thenDragTo: end)
        attach(named: "myr460-02-dethroned-by-pan")

        // The recenter control is the rider's explicit way back, and its state is
        // the observable proof the gesture was received: it is offered only once
        // the camera has been stood down. See `recenterIsOffered` for why the
        // measured FRAME is the signal and neither `exists` nor `isHittable` is.
        XCTAssertTrue(waitForRecenter(app, offered: true, timeout: 5),
                      "a pan that reached the map stands the follow camera down and offers the way back")

        // A SECOND drag, a beat later: the idle window must restart from THIS
        // one. If it did not, the camera would come back mid-interaction, which
        // is the MYR-222 complaint wearing this issue's fix as a disguise.
        Thread.sleep(forTimeInterval: 3)
        let secondEnd = mapPoint(app, dx: 0.72, dy: 0.34)
        start.press(forDuration: 0.1, thenDragTo: secondEnd)
        XCTAssertTrue(recenterIsOffered(app), "still the rider's camera, three seconds into the first window")

        // Now leave it completely alone for longer than the idle window and it
        // must return to the car by itself — the client's "after a few seconds
        // it will snap right back".
        let reArmed = waitForRecenter(app, offered: false, timeout: 20)
        attach(named: "myr460-03-re-armed-after-idle")
        XCTAssertTrue(reArmed,
                      "the camera re-armed itself, so there is nothing left to recentre")
    }

    /// The negative that makes the test above mean something: an UNTOUCHED map
    /// never offers the recenter control, so its appearance in the test above is
    /// evidence of the gesture rather than of the screen.
    func testAnUntouchedFollowCameraNeverOffersRecenter() {
        let app = launchFollowing()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        Thread.sleep(forTimeInterval: 8)
        XCTAssertFalse(recenterIsOffered(app),
                       "nothing has dethroned the camera, so it is still following and has nothing to offer")
    }
}
