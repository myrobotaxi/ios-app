import XCTest

// MARK: - MYR-332 — the owner sheet's tall detent
//
// THE CLIENT'S ASK: the owner sheet tops out at the half/controls detent and the
// rest of the stack is reachable only by scrolling INSIDE it; he wants to pull
// the sheet itself higher to see the controls.
//
// The new stop is the sheet grammar's own tallest surface — the physical screen
// less `MRTMetrics.sheetTallTopClearance` (140, = 852 − `SHEET_HEIGHTS.search`),
// which still leaves the `MapHeader` switcher showing so the controls stay
// attached to a named car.
//
// These tests assert the stop EXISTS and is reachable by finger, and — the part
// that matters for the drift gate — that peek and half are exactly where they
// were. `MRT_OWNER_DETENT=tall` is the headless capture route (tooling can no
// more drag to tall than it could to half).
final class OwnerSheetTallDetentUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchOwnerHome(detent: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "ownerHome"
        if let detent { app.launchEnvironment["MRT_OWNER_DETENT"] = detent }
        app.launch()
        return app
    }

    private func sheet(in app: XCUIApplication) -> XCUIElement {
        let element = app.otherElements["mrt.detentSheet"]
        XCTAssertTrue(element.waitForExistence(timeout: 15), "the owner detent sheet should be on screen")
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

    /// The design number this detent is derived from (`MRTMetrics
    /// .sheetTallTopClearance`). Re-stated here rather than imported: a UI test
    /// target that could read the constant would prove nothing about what landed
    /// on screen.
    private static let tallTopClearance: CGFloat = 140

    /// THE DELIVERABLE. Booted at tall, the sheet's top edge sits the design's
    /// clearance below the PHYSICAL top — and the vehicle switcher is still
    /// visible above it.
    func testTallDetentStopsAtTheGrammarsTopClearance() {
        let app = launchOwnerHome(detent: "tall")
        let s = sheet(in: app)
        let frame = settledFrame(of: s)
        let screen = app.windows.firstMatch.frame
        attach(app, named: "myr332-tall-detent")
        NSLog("MRT_MYR332 tall sheet=\(frame) screen=\(screen)")

        XCTAssertEqual(
            frame.minY, Self.tallTopClearance, accuracy: 2,
            "the tall detent's top edge is the physical screen less \(Self.tallTopClearance)pt"
        )
        // The MapHeader switcher (top 60, 40pt chip) must survive the stop —
        // otherwise this is a full-screen takeover, not a detent.
        XCTAssertLessThan(
            MRTMapHeaderBottomEdge, frame.minY,
            "the vehicle switcher must stay visible above a sheet at its tallest detent"
        )
    }

    /// A finger can get there: a slow drag up from HALF settles at tall, well
    /// above where half rested.
    func testDragUpFromHalfReachesTheTallDetent() {
        let app = launchOwnerHome(detent: "half")
        let s = sheet(in: app)
        let half = settledFrame(of: s)

        handleGrab(on: s).press(
            forDuration: 1.2,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        )
        let tall = settledFrame(of: s)
        attach(app, named: "myr332-after-drag-half-to-tall")
        NSLog("MRT_MYR332 dragUp halfMinY=\(half.minY) tallMinY=\(tall.minY)")

        XCTAssertLessThan(tall.minY, half.minY - 100, "a drag up from half must reach a genuinely taller stop")
        XCTAssertEqual(tall.minY, Self.tallTopClearance, accuracy: 4, "…and that stop is the tall detent")
    }

    /// …and back down: a drag down from tall returns to HALF, not straight to
    /// peek. A three-detent sheet that skips its middle stop is worse than a
    /// two-detent one.
    func testDragDownFromTallReturnsToHalfNotPeek() {
        let app = launchOwnerHome(detent: "half")
        let s = sheet(in: app)
        let half = settledFrame(of: s)
        handleGrab(on: s).press(
            forDuration: 1.2,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        )
        let tall = settledFrame(of: s)
        XCTAssertLessThan(tall.minY, half.minY - 100, "precondition: at tall")

        // Down by roughly one detent step, released at REST — an explicit slow
        // velocity plus a hold, so the settle is decided by where the finger
        // stopped rather than by `SheetPhysics.projection` (a flick down from
        // tall legitimately crosses to peek; that is not what this asserts).
        handleGrab(on: s).press(
            forDuration: 0.2,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: half.midX, dy: tall.minY + (half.minY - tall.minY) + 20)),
            withVelocity: .slow,
            thenHoldForDuration: 0.6
        )
        let back = settledFrame(of: s)
        NSLog("MRT_MYR332 dragDown tallMinY=\(tall.minY) backMinY=\(back.minY) halfMinY=\(half.minY)")
        XCTAssertEqual(back.minY, half.minY, accuracy: 12, "a drag down of one step lands on half, not peek")
    }

    /// THE BYTE-IDENTITY GUARD. Adding a third detent must not move the two that
    /// existed: peek is the prototype's parked band and half is the 0.58 fraction,
    /// exactly as before. Values are read off the running app rather than
    /// asserted against constants, then checked against the geometry the
    /// drift-gate captures were taken at.
    func testPeekAndHalfAreUnmovedByTheNewDetent() {
        let peekApp = launchOwnerHome()
        let peek = settledFrame(of: sheet(in: peekApp))
        let screen = peekApp.windows.firstMatch.frame
        // The `ownerHome` scene is DRIVING, so its peek band is the prototype's
        // 280 (screens.jsx:400) with no live-only qualifier line (MYR-315).
        XCTAssertEqual(screen.height - peek.minY, 280, accuracy: 2, "peek is still the prototype's driving band")
        peekApp.terminate()

        let halfApp = launchOwnerHome(detent: "half")
        let half = settledFrame(of: sheet(in: halfApp))
        // 0.58 of the sheet's CONTAINER (the screen less the top safe area).
        let container = screen.height - MRTTopSafeAreaInset
        XCTAssertEqual(
            screen.height - half.minY, container * 0.58, accuracy: 4,
            "half is still `homeHalfHeightFraction` of the container"
        )
        NSLog("MRT_MYR332 peekH=\(screen.height - peek.minY) halfH=\(screen.height - half.minY)")
    }
}

/// The `MapHeader` chip's bottom edge from the physical top: `mapHeaderTop` (60)
/// + `mapChipHeight` (40). Literal, for the reason the clearance is (see above).
private let MRTMapHeaderBottomEdge: CGFloat = 100

/// The device top safe-area inset on the test destination (iPhone 17 Pro). Read
/// from the app's own window rather than hardcoded would be better, but XCUITest
/// exposes no safe-area query; the half-detent assertion carries a tolerance
/// wide enough that this only needs to be right to a few points.
private let MRTTopSafeAreaInset: CGFloat = 62
