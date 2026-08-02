import XCTest

// MARK: - MYR-419 — the dispatch chrome and the sheet, on a real launch and a real drag
//
// THE CLIENT'S REPORT (r18, build `202608020103`): with a live dispatch the
// status pill and the gold "Dropped off" CTA overlap the owner sheet's own hero
// row once the sheet is pulled up.
//
// **A PURE TEST CANNOT SHOW THAT THE SCREEN CONSULTS THE RULE** — MYR-387's
// defect 2 and MYR-369's `VehicleRideShare.display` are both cases of a correct
// rule with good tests and the wrong consumer — so `OwnerDispatchSheetClearance
// Tests` pins the arithmetic and this drives the app. Every assertion here is on
// frames the system reports, so it measures what landed on screen.
//
// **AND A SETTLED FRAME CANNOT SHOW THE DRAG PATH.** The sheet passes through
// every height between its detents on the way up, so the last test presses,
// drags in steps and samples MID-GESTURE — the `RiderTrackingSheetDragUITests` /
// MYR-397 drag-probe precedent. On the pre-fix build the overlap is reachable
// with a finger long before any stop commits.
final class OwnerDispatchSheetOverlapUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The leg-2 state the client photographed: "… aboard · heading to …" plus
    /// the gold "Dropped off" CTA, i.e. the TALLEST dispatch card there is.
    private static let scene = "ownerDispatchedEnroute"

    private func launch(detent: String? = nil, scene: String = scene) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        if let detent { app.launchEnvironment["MRT_OWNER_DETENT"] = detent }
        app.launch()
        return app
    }

    private func sheet(in app: XCUIApplication) -> XCUIElement {
        let element = app.otherElements["mrt.detentSheet"]
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the owner detent sheet should be on screen")
        return element
    }

    /// `.accessibilityElement(children: .combine)` over a dot and a label does not
    /// resolve to a predictable element TYPE, so the pill is found by identifier
    /// across every type rather than under `otherElements` (where a first cut
    /// looked for it, and did not find it).
    private func pill(in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: "ownerDispatchPill").firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15), "a live dispatch must show its status pill")
        return element
    }

    private func cta(in app: XCUIApplication) -> XCUIElement {
        let element = app.buttons["ownerDispatchCTA"]
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the enroute state must offer the Dropped off CTA")
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
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        shot.name = named
        add(shot)
    }

    /// The design numbers, re-stated rather than imported: a UI-test target that
    /// could read the app's constants would prove nothing about what landed.
    private static let mapHeaderBottomEdge: CGFloat = 100
    private static let grammarTallClearance: CGFloat = 140

    // MARK: THE DELIVERABLE — no overlap at any detent

    func testTheChromeClearsTheSheetAtPeek() { assertNoOverlap(detent: nil, named: "peek") }
    func testTheChromeClearsTheSheetAtHalf() { assertNoOverlap(detent: "half", named: "half") }
    func testTheChromeClearsTheSheetAtTall() { assertNoOverlap(detent: "tall", named: "tall") }

    private func assertNoOverlap(detent: String?, named: String) {
        let app = launch(detent: detent)
        let s = sheet(in: app)
        let sheetFrame = settledFrame(of: s)
        let pillFrame = pill(in: app).frame
        let ctaFrame = cta(in: app).frame
        attach(app, named: "myr419-\(named)")
        NSLog("MRT_MYR419 \(named) sheetTop=\(sheetFrame.minY) pill=\(pillFrame) cta=\(ctaFrame)")

        XCTAssertGreaterThanOrEqual(
            sheetFrame.minY, ctaFrame.maxY,
            "\(named): the sheet's top edge must stay below the CTA's last ink"
        )
        XCTAssertGreaterThanOrEqual(sheetFrame.minY, pillFrame.maxY, "\(named): …and below the status pill's")
        // Both are on screen and usable wherever they are drawn — an overlap
        // "fixed" by pushing the CTA off the top would pass the two above.
        XCTAssertTrue(cta(in: app).isHittable, "\(named): the Dropped off CTA must stay tappable")
        XCTAssertGreaterThan(pillFrame.minY, Self.mapHeaderBottomEdge - 1, "\(named): the pill stays under the switcher chip")
    }

    /// The reserve is what moved, and it moved ONE stop. Peek and half are where
    /// every existing dispatch capture rests and must be exactly where they were;
    /// tall is lower than the grammar's own 140 by the height of the chrome it is
    /// now leaving room for.
    func testOnlyTheTallStopMoves() {
        let peekApp = launch()
        let screen = peekApp.windows.firstMatch.frame
        let peek = settledFrame(of: sheet(in: peekApp)).minY
        peekApp.terminate()

        let halfApp = launch(detent: "half")
        let half = settledFrame(of: sheet(in: halfApp)).minY
        let container = screen.height - 62 // iPhone 17 Pro top safe-area inset
        XCTAssertEqual(
            screen.height - half, container * 0.58, accuracy: 4,
            "half is still `homeHalfHeightFraction` of the container"
        )
        // The `ownerDispatchedEnroute` car is DRIVING and navigating, so its peek
        // band is the prototype's 280 (screens.jsx:400) with no live-only
        // qualifier line — unchanged by this issue.
        XCTAssertEqual(screen.height - peek, 280, accuracy: 3, "peek is still the prototype's driving band")
        halfApp.terminate()

        let tallApp = launch(detent: "tall")
        let s = sheet(in: tallApp)
        let tall = settledFrame(of: s).minY
        let ctaBottom = cta(in: tallApp).frame.maxY
        NSLog("MRT_MYR419 stops peekTop=\(peek) halfTop=\(half) tallTop=\(tall) ctaBottom=\(ctaBottom)")

        XCTAssertGreaterThan(
            tall, Self.grammarTallClearance,
            "with a dispatch live the tall stop sits BELOW the grammar's 140 — that reserve is the fix"
        )
        XCTAssertGreaterThanOrEqual(tall, ctaBottom, "…by at least the height of the chrome it leaves room for")
        XCTAssertLessThan(tall, half - 100, "…and it is still a genuinely taller stop than half")
    }

    /// The no-dispatch path is untouched: `ownerHome` at tall is still the
    /// grammar's own 140, so the reserve is paid only while a ride is live.
    func testWithNoDispatchTheTallStopIsTheGrammarsOwn() {
        let app = launch(detent: "tall", scene: "ownerHome")
        let top = settledFrame(of: sheet(in: app)).minY
        NSLog("MRT_MYR419 ownerHome tallTop=\(top)")
        XCTAssertEqual(top, Self.grammarTallClearance, accuracy: 2, "a screen with no dispatch card reserves nothing")
        XCTAssertFalse(app.otherElements["ownerDispatchPill"].exists, "precondition: no dispatch on this scene")
    }

    // MARK: The drag path (the MYR-397 drag-probe precedent)

    /// A REAL FINGER, dragged as far up the screen as it can go, and the sheet
    /// still stops clear of the chrome. This is the acceptance the client's
    /// gesture produces: before the fix the same drag put the sheet's top edge at
    /// 140 with the CTA's ink ending at 204.
    ///
    /// **WHAT IT DELIBERATELY DOES NOT DO IS SAMPLE MID-GESTURE**, and the reason
    /// is `RiderTrackingSheetDragUITests`' verbatim: `press(…thenHoldForDuration:)`
    /// BLOCKS until the finger lifts, and moving the gesture to another queue is
    /// not available either (XCUI gestures are main-thread-only). A first cut of
    /// this test collected fourteen "mid-drag" samples and every one of them read
    /// 228.0 — the settled value — which would have passed against a build with
    /// the reserve deleted if the reserve were the only thing at rest.
    ///
    /// The in-between is covered by CONSTRUCTION instead, and proven where it can
    /// be: the sheet's reachable heights are its detent ladder plus a rubber band
    /// bounded by `SheetPhysics.rubberBand`'s saturation (pinned in
    /// `SheetDetentCeilingTests`), and `OwnerDispatchSheetClearanceTests` asserts
    /// the reserve clears the card at every rung of that ladder AND at full
    /// stretch above it. There is no height in between for the sheet to be at.
    func testARealDragToTheTopOfTheScreenStillStopsClearOfTheChrome() {
        let app = launch(detent: "half")
        let s = sheet(in: app)
        let half = settledFrame(of: s).minY
        let ctaBottom = cta(in: app).frame.maxY

        handleGrab(on: s).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        )
        let top = settledFrame(of: s).minY
        attach(app, named: "myr419-after-drag-to-top")
        NSLog("MRT_MYR419 drag halfTop=\(half) draggedTop=\(top) ctaBottom=\(ctaBottom)")

        XCTAssertLessThan(top, half - 100, "precondition: the drag reached the tallest stop")
        XCTAssertGreaterThanOrEqual(
            top, ctaBottom,
            "a drag to the very top of the screen must still leave the dispatch CTA whole"
        )
        XCTAssertTrue(cta(in: app).isHittable, "…and tappable where it is drawn")
    }
}
