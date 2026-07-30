import XCTest

// MARK: - MYR-345 — the freshness stamp's refresh tap (client defect)
//
// *"When I select the refresh icon to refresh the data it doesn't work"* — on an
// IN-SERVICE car whose stamp read "Synced just now".
//
// Nothing headless can prove this: the phase transition IS the deliverable, and a
// seeded phase (`ownerFreshnessWaking`, MYR-315) proves only that the state
// renders, never that a finger reaches it. These tests synthesize the actual
// touch on the actual sheet at PEEK — the same "cold scenes passing while the real
// path fails" lesson the repo has already paid for twice (MYR-339's celebration,
// MYR-338's drag).
//
// Three things are under test, one per suspect the issue named:
//   1. the TAP TARGET — a finger 14pt below the ink still lands, and the region
//      stops short of the floating nav's own top edge;
//   2. the EXECUTOR CALL — a stale car's tap reaches §7.15 and shows "Waking …";
//   3. the SETTLE — an already-current car SAYS it is current, and a server that
//      refuses names the reason. Silence is the bug even when the refusal is right.
final class OwnerFreshnessStampUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// `MRTMetrics.bottomNavTopEdge` — the floating nav's top edge, measured from
    /// the PHYSICAL bottom. Re-stated rather than imported: a UI test that could
    /// read the constant would prove nothing about what landed on screen.
    private static let bottomNavTopEdge: CGFloat = 86
    private static let minTapTarget: CGFloat = 44

    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    private func stamp(in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)["mrt.freshnessStamp"]
        XCTAssertTrue(element.waitForExistence(timeout: 20), "the freshness stamp should be on the peek hero")
        return element
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = named
        add(shot)
    }

    /// Wait for the stamp's rendered copy to become something other than `label`.
    @discardableResult
    private func awaitLabelChange(from label: String, on element: XCUIElement, timeout: TimeInterval = 6) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = element.label
            if now != label { return now }
            usleep(80_000)
        }
        return element.label
    }

    // MARK: 1 — the tap target

    /// The stamp is 11pt text: its ink lays out at ~13pt, so the touch region is
    /// grown around it with a `contentShape` inset.
    ///
    /// The assertion is on the frame the system REPORTS — which is the grown
    /// region, not the label — because that is the thing a finger hits. MYR-315
    /// reasoned about the inset instead and shipped a 43⅓pt target. And the same
    /// frame must stop short of the floating nav's top edge, or the two overlap
    /// and one of them swallows the other.
    func testTheTouchTargetIsBigEnoughAndStopsShortOfTheNav() {
        let app = launch(scene: "ownerFreshnessInService")
        let element = stamp(in: app)
        let frame = element.frame
        let screen = app.windows.firstMatch.frame

        NSLog("MRT_MYR345 stamp=\(frame) screen=\(screen) bottomGap=\(screen.maxY - frame.maxY)")
        XCTAssertGreaterThanOrEqual(
            frame.height, Self.minTapTarget,
            "the touch region must clear the 44pt minimum (CLAUDE.md hard rule)"
        )
        XCTAssertLessThanOrEqual(
            frame.maxY, screen.maxY - Self.bottomNavTopEdge,
            "the touch region must not reach under the floating nav (MYR-315)"
        )

        // A finger BELOW the ink, inside the grown region only.
        let before = element.label
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)).tap()
        let after = awaitLabelChange(from: before, on: element)
        attach(app, named: "myr345-touch-target")
        XCTAssertNotEqual(after, before, "a tap inside the grown region must reach the stamp")
    }

    // MARK: 2 + 3 — the tap the client made

    /// THE DEFECT. His car had been read moments earlier, so the tap is a
    /// legitimate no-op — and before this issue a no-op rendered NOTHING: same
    /// glyph, same text, no spin. The stamp must answer.
    func testTappingAnAlreadyCurrentStampSaysSomething() {
        let app = launch(scene: "ownerFreshnessInService")
        let element = stamp(in: app)
        let before = element.label
        XCTAssertTrue(before.hasPrefix("Synced"), "expected the client's resting stamp, got \(before)")
        attach(app, named: "myr345-uptodate-before")

        element.tap()
        let after = awaitLabelChange(from: before, on: element, timeout: 3)
        attach(app, named: "myr345-uptodate-after")
        XCTAssertNotEqual(after, before, "the tap produced no visible change \u{2014} the client's report")

        // …and it hands the line back, rather than parking on a claim that ages.
        let settled = awaitLabelChange(from: after, on: element, timeout: 6)
        XCTAssertEqual(settled, before)
    }

    /// A genuinely stale car spends the §7.15 call: the executor is reached and
    /// the seconds a wake takes are announced rather than silent.
    func testTappingAStaleStampEntersTheWakingPhase() {
        let app = launch(scene: "ownerFreshnessRefused")
        let element = stamp(in: app)
        let before = element.label
        element.tap()

        let waking = awaitLabelChange(from: before, on: element, timeout: 3)
        attach(app, named: "myr345-waking")
        XCTAssertTrue(waking.hasPrefix("Waking"), "expected the in-flight line, got \(waking)")
    }

    /// The settle. The server legitimately refuses a refresh on a car in service
    /// mode, and says so by name (§7.9 `command_failed` + MYR-329's
    /// `vehicle_in_service`). The stamp must repeat the reason, not flatten it to
    /// "Couldn't reach the car" — the wrong-guess problem MYR-329 already fixed
    /// once on the command path.
    func testARefusedRefreshNamesTheReason() {
        let app = launch(scene: "ownerFreshnessRefused")
        let element = stamp(in: app)
        element.tap()

        let deadline = Date().addingTimeInterval(10)
        var settled = element.label
        while Date() < deadline {
            settled = element.label
            if !settled.hasPrefix("Waking") && !settled.hasPrefix("Synced") { break }
            usleep(80_000)
        }
        attach(app, named: "myr345-refused-settle")
        XCTAssertEqual(settled, "Car is in service \u{2014} commands are limited")
    }
}
