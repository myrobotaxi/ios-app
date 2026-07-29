import XCTest

// MARK: - MYR-331 — the rider search sheet must own vertical drags on its own
// surface (the drag that fell through to the map)
//
// THE CLIENT'S REPORT: on the rider request sheet — Now/Schedule chips, the
// destination search, keyboard up — a downward drag ON THE SHEET pans the MAP
// instead of collapsing the sheet.
//
// THE MECHANISM (probed, not guessed). `PanSheetController` hosts each sheet
// layer in a `UIHostingController` whose view frame IS the draggable
// `PanSheetSurfaceView`. A hosting controller applies SwiftUI's automatic
// KEYBOARD AVOIDANCE by default, and avoidance TRANSLATES the hosted content —
// so with the keyboard up the drawn sheet left the surface behind. Measured on
// `MRT_SCENE=search`, iPhone 17 Pro, before the fix:
//
//     surface (hit-testable)     window y 162 … 922
//     hosted SwiftUI content     window y  −5 … 707      (168pt higher)
//     "Now" chip                 window y  15.7
//
// Everything drawn above `surface.minY − topGrabMargin` LOOKED like sheet and
// hit-tested as nothing: `PanSheetPassthroughView` returned nil, the touch
// reached the MapKit view behind, and the drag panned the map. After the fix
// (`safeAreaRegions = .container`) the same chip sits at y 186 — inside the
// surface — and the drag collapses the sheet.
//
// These tests assert BOTH halves, keyboard up and keyboard down: the geometric
// invariant (nothing the sheet draws may sit outside the surface that owns its
// pan) and the behaviour it exists for (a drag on the chip band collapses the
// sheet). Both fail on `main` with the keyboard up.
final class RiderSearchSheetDragUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchSearch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "search"
        app.launch()
        return app
    }

    private func sheet(in app: XCUIApplication) -> XCUIElement {
        let element = app.otherElements["mrt.riderSheet"]
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the rider sheet should be on screen in the search scene")
        return element
    }

    /// The sheet's frame once its settle spring has finished (see
    /// `SheetFeelUITests.settledFrame` — same polling contract).
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

    /// The chip row (`Now` / `Schedule` / `Me` / `Someone else`) is the topmost
    /// INTERACTIVE band the client drags on, and the first thing the keyboard
    /// shift pushed off the surface — so it is the probe for "is what I see
    /// still what I can grab".
    private func chipRow(in app: XCUIApplication) -> CGRect {
        let now = app.buttons["Now"]
        XCTAssertTrue(now.waitForExistence(timeout: 10), "the Now chip should be on the search sheet")
        return now.frame
    }

    /// Force the keyboard down WITHOUT leaving the search phase: the engine
    /// resigns first responder on drag start (`PanSheetController.beginDrag`), so
    /// a drag too small to cross the midpoint dismisses the keyboard and settles
    /// straight back at the search detent.
    private func dismissKeyboardByNudge(_ app: XCUIApplication, sheet: XCUIElement) {
        let frame = sheet.frame
        let grab = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.minY + 12))
        // UPWARD, from the sheet's own top: far enough to be recognised as a pan
        // (a few points never crosses the recognizer's slop) but in the one
        // direction that cannot change the detent — the sheet is already at its
        // tallest, so this only rubber-bands and springs straight back, while
        // `beginDrag`'s `endEditing(true)` drops the keyboard.
        grab.press(
            forDuration: 0.6,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.minY - 40))
        )
        _ = settledFrame(of: sheet)
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = named
        add(shot)
    }

    // MARK: The geometric invariant

    /// THE REGRESSION. Whatever the sheet DRAWS must live inside the surface that
    /// owns its pan — otherwise those pixels are a fall-through hole onto the map.
    /// Asserted with the keyboard UP, which is the state that broke it.
    func testSheetContentStaysInsideItsDraggableSurfaceWithKeyboardUp() {
        let app = launchSearch()
        let s = sheet(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "precondition: the search scene raises the keyboard on the destination field")
        let sheetFrame = settledFrame(of: s)
        let chips = chipRow(in: app)
        attach(app, named: "myr331-keyboard-up-rest")
        NSLog("MRT_MYR331 kbUp sheet=\(sheetFrame) chips=\(chips)")

        XCTAssertGreaterThanOrEqual(
            chips.minY, sheetFrame.minY,
            "the chip row is drawn \(sheetFrame.minY - chips.minY)pt ABOVE the draggable surface — those pixels look like sheet but hit-test to the map behind it (MYR-331)"
        )
        XCTAssertLessThanOrEqual(
            chips.maxY, sheetFrame.maxY,
            "the chip row must sit inside the draggable surface"
        )
    }

    // MARK: The behaviour

    /// KEYBOARD UP — a slow drag DOWN starting on the chip band must collapse the
    /// sheet to the idle greeting card. Before the fix this dragged the MAP and
    /// the sheet did not move at all.
    func testDragDownOnTheChipBandCollapsesTheSheetWithKeyboardUp() {
        let app = launchSearch()
        let s = sheet(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "precondition: the keyboard is up")
        let before = settledFrame(of: s)
        let chips = chipRow(in: app)

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chips.midX, dy: chips.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chips.midX, dy: chips.midY + 380))
        start.press(forDuration: 1.2, thenDragTo: end)

        let after = settledFrame(of: s)
        attach(app, named: "myr331-keyboard-up-after-drag-down")
        NSLog("MRT_MYR331 kbUpDrag before=\(before.minY) after=\(after.minY)")
        XCTAssertGreaterThan(
            after.minY, before.minY + 120,
            "a downward drag on the sheet's own chip band must collapse the sheet, not pan the map (MYR-331)"
        )
    }

    /// KEYBOARD DOWN — the same drag, on the same band, once the keyboard has been
    /// dismissed. This half already worked; it is here so the fix can never be
    /// "corrected" into breaking the case that was fine.
    func testDragDownOnTheChipBandCollapsesTheSheetWithKeyboardDown() {
        let app = launchSearch()
        let s = sheet(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        dismissKeyboardByNudge(app, sheet: s)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
                      "precondition: the nudge drag resigned the keyboard and stayed on search")

        let before = settledFrame(of: s)
        let chips = chipRow(in: app)
        XCTAssertGreaterThanOrEqual(
            chips.minY, before.minY,
            "keyboard down, the chip row must also sit inside the draggable surface"
        )

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chips.midX, dy: chips.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chips.midX, dy: chips.midY + 380))
        start.press(forDuration: 1.2, thenDragTo: end)

        let after = settledFrame(of: s)
        attach(app, named: "myr331-keyboard-down-after-drag-down")
        NSLog("MRT_MYR331 kbDownDrag before=\(before.minY) after=\(after.minY)")
        XCTAssertGreaterThan(
            after.minY, before.minY + 120,
            "a downward drag on the chip band must collapse the sheet with the keyboard down too"
        )
    }
}
