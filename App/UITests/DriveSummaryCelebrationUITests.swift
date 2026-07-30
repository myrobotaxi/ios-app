import XCTest

// MARK: - MYR-339 / MYR-346 — the 100%-FSD celebration, driven on the REAL path
//
// **The celebration has no cold-scene route at all.** The only headless way into
// a Drive Summary (`MRT_SCENE=ownerDrives MRT_OPEN_FIRST_DRIVE=1`) opens
// `DriveFixtures.drives[0]` — 14.2 of 14.6 mi, **97%** — where `celebrates` is
// false and not one celebration branch is ever constructed. That is CLAUDE.md's
// own "cold scenes passing while real paths fail" trap in its purest form: the
// scene that exists for this screen cannot render the state the issue is about.
// The 100% drive is the SECOND row, reachable only by tapping it, which is what
// these tests do (the same `ExpandedRouteUITests` precedent).
//
// MYR-346 also changed what has to be PROVEN. The old celebration was a wash
// that faded in at t=2.7s and then simply stayed, so three stills covered it.
// The new one is a MOMENT — the ring draws behind a bright trace head and glints
// once at 12 o'clock, all inside `MRTDriveCelebration.momentDuration` (1.72s) —
// and a still of a moment is worth nothing. So the evidence is a FRAME SEQUENCE
// captured in-process across the whole entry, attached to the xcresult and
// exported with `xcrun xcresulttool export attachments`.
final class DriveSummaryCelebrationUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// `DriveFixtures.drives[1]` — 3.8 of 3.8 mi = 100% FSD, the celebration case.
    private static let fullFSDRow = "Embarcadero Center → Mission · Tartine"
    /// `DriveFixtures.drives[0]` — 14.2 of 14.6 mi = 97%, the control. No
    /// celebration may appear here, and this screen must stay byte-identical
    /// across this issue.
    private static let partialFSDRow = "Home → Embarcadero Center"

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func attach(named name: String) {
        attach(XCUIScreen.main.screenshot(), named: name)
    }

    /// Owner ⇢ Drives ⇢ a drive row, by real taps on the real navigation path.
    /// Returns WITHOUT waiting for anything on the summary, so a caller can start
    /// capturing frames from the first one the pushed screen draws.
    @discardableResult
    private func openDrive(_ row: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "ownerDrives"
        app.launch()

        let cell = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", row)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the drive row \"\(row)\" must be on the Drives tab")
        cell.tap()
        return app
    }

    private func assertSummaryIsUp(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["FULL SELF-DRIVING"].waitForExistence(timeout: 10),
            "tapping a drive row must push its Drive Summary"
        )
    }

    /// Frames captured back-to-back with no sleep — `XCUIScreen.screenshot()`
    /// costs tens of milliseconds, which is a finer sampling than any
    /// `Thread.sleep` cadence and needs no assumption about how long a capture
    /// takes. Each frame carries its WALL-CLOCK offset from the tap, so the
    /// sequence reads against `MRTDriveCelebration`'s own numbers (draw
    /// 0.12→1.27s, glint 1.27→1.72s) rather than against a frame index.
    private func captureSequence(seconds: Double) -> [(offset: Double, shot: XCUIScreenshot)] {
        let t0 = Date()
        var frames: [(Double, XCUIScreenshot)] = []
        while Date().timeIntervalSince(t0) < seconds {
            frames.append((Date().timeIntervalSince(t0), XCUIScreen.main.screenshot()))
        }
        return frames
    }

    private func attach(sequence: [(offset: Double, shot: XCUIScreenshot)], prefix: String) {
        for (index, frame) in sequence.enumerated() {
            let ms = Int((frame.offset * 1000).rounded())
            attach(frame.shot, named: String(format: "%@-f%02d-t%04dms", prefix, index, ms))
        }
    }

    // MARK: The moment

    /// The whole entry, frame by frame: the ring drawing, the `goldTraceBright`
    /// head riding its leading edge, the glint at 12 o'clock, and the settle.
    /// 2.4s of capture — comfortably past `momentDuration` (1.72s), so the tail
    /// of the sequence IS the settled state and the frames show it holding still.
    func testFullFSDCelebrationEntryMomentFrameSequence() {
        let app = openDrive(Self.fullFSDRow)
        let frames = captureSequence(seconds: 2.4)
        assertSummaryIsUp(app)
        attach(sequence: frames, prefix: "myr346-moment")
        XCTAssertGreaterThan(frames.count, 12, "the sequence needs enough frames to read the draw as motion")
    }

    /// The settled state, as a still: a slightly richer static ring, a gold
    /// numeral and kicker, one gold hairline on the tile — and a hero map with no
    /// celebration layer over it at all.
    func testFullFSDDriveSummarySettles() {
        let app = openDrive(Self.fullFSDRow)
        assertSummaryIsUp(app)
        Thread.sleep(forTimeInterval: 4.0)
        attach(named: "myr346-100pct-settled")
        // A MOMENT settles and then stops. Two stills 3s apart prove the
        // celebration is not still running — the old wash's whole defect was that
        // it arrived at 2.7s and then simply stayed.
        Thread.sleep(forTimeInterval: 3.0)
        attach(named: "myr346-100pct-settled-held")
    }

    /// The control the pair is read against. A 97% drive celebrates nothing, so
    /// this screen must be unchanged by this issue — the byte-comparison anchor.
    func testPartialFSDDriveSummaryStaysUncelebrated() {
        let app = openDrive(Self.partialFSDRow)
        assertSummaryIsUp(app)
        Thread.sleep(forTimeInterval: 6.0)
        attach(named: "myr346-97pct-t6-no-celebration")
    }

    /// Reduce Motion boots STRAIGHT to the settled state — no draw, no glint. Run
    /// this with `xcrun simctl spawn <udid> defaults write
    /// com.apple.Accessibility ReduceMotionEnabled -bool true` in force
    /// (CLAUDE.md: `simctl ui reduce_motion` does not take on this runtime). The
    /// frames are captured on the same schedule as the moment above, so the pair
    /// is a clean comparison: with motion the early frames show a partial ring,
    /// without it every frame is already the settled one.
    func testFullFSDUnderReduceMotionBootsSettled() {
        let app = openDrive(Self.fullFSDRow)
        let frames = captureSequence(seconds: 2.4)
        assertSummaryIsUp(app)
        attach(sequence: frames, prefix: "myr346-reducemotion")
    }
}
