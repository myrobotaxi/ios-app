import XCTest

// MARK: - MYR-390 — the drawn route survives the step it was drawn on
//
// r15 clip: the route is fully etched and breathing on the destination-selected
// search sheet; tapping "Continue" to the "Schedule with Lunar" sheet makes the
// drawn line VANISH for ~0.5s (only the pickup glow dot survives) and then
// replay its 1.6s etch from zero. Same trip, same camera.
//
// **THIS HAS TO BE A UI TEST, AND ON A SCENE THAT DRIVES THE REAL TRANSITION.**
// `RouteEtchContinuityTests` pins the rule — a route the ledger has already seen
// opens `.pulsing` at full progress — and a pure test cannot show that the
// SCREEN consults it. It also cannot show the symptom at all: the collapse is
// `RideRequestRouteMap.mapContent` answering `EmptyMapContent()` while
// `.etching`, which is pixels. A cold `review`/`riderScheduledReview` scene boots
// straight into the destination phase, so the only etch it can ever show is a
// first arrival — CLAUDE.md's "cold scenes passing while real paths fail" in its
// purest form, and MYR-217's rule about exactly this.
//
// `riderScheduledReviewRealPath` therefore seeds the client's draft on SEARCH,
// waits for MKDirections and the whole 1.6s pass, and then calls the shipping
// `proceedFromSearch()` — the method the Continue button calls.
//
// **The measurement is the ROUTE'S COVERAGE of the map band** — the fraction of
// image rows its core gold stroke crosses — sampled back-to-back across the
// flip. Choosing that number over the obvious one cost two rounds, and both are
// worth recording. Gold INK (the count of route-coloured pixels) is dominated by
// the settled route's own breathing glow, which modulates it 2–3× on a 2.6s
// period; a floor set wide enough for that swing cannot also be tight enough to
// catch a collapse. And a LOOSE gold predicate finds the dark map's own warm
// road casings scattered over the whole band, which held a top-to-bottom
// "extent" of 0.652 straight through a collapse the ink showed plainly.
//
// Coverage of the CORE stroke has neither problem. It is flat to ±0.004 across
// the whole sequence while the ink swings 2× underneath, because what breathes
// is a halo drawn OVER a polyline that does not move — and the defect is exactly
// a loss of the polyline: `.etching` at progress 0 draws no line at all
// (`mapContent` answers `EmptyMapContent()`), leaving only the head bloom at the
// pickup, and coverage then ramps back from zero over the 1.6s replay.
final class RouteEtchContinuityUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// The scheduled CTA on the sheet the flip lands on — `RideRequestFixtures
    /// .fleet[0]`'s owner. Its appearance IS the flip, observed from outside.
    private static let scheduledCTA = "Schedule with Alex"

    private func attach(_ shot: XCUIScreenshot, named name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// What the gold route occupies in the sampled band, on a grid, in image
    /// pixels — the `OwnerSheetTallDetentUITests.changedFraction` precedent.
    private struct RouteInk {
        /// Fraction of sampled pixels that read as route gold. Breathes with the
        /// glow; logged for context, not asserted on.
        let fraction: Double
        /// Fraction of the band's sampled ROWS that the route's own core stroke
        /// crosses. **This is the assertion.** It does not breathe: the settled
        /// map-space polyline crosses the same rows at every point of the glow
        /// cycle, because what breathes is a halo drawn over it.
        let coverage: Double
    }

    /// The route is drawn over a dark muted map as an 8pt `mrtGoldGlowSoft` halo
    /// under a 3.5pt `mrtGold` @0.95 CORE, with the glow overlay's own layers
    /// above that. **Coverage keys on the CORE only** — saturated gold, `#C9A84C`
    /// ≈ rgb(201,168,76), r−b ≈ 125 — because the halo and the breathing glow are
    /// exactly the parts that come and go with the pulse. A loose predicate also
    /// picks up the dark map's own warm road casings, which are scattered over
    /// the whole band and, at a low enough threshold, make an empty map look like
    /// a route that spans it (cost a round: they held a top-to-bottom "span" at
    /// 0.652 through a collapse the ink shows plainly).
    ///
    /// A row counts only at ≥2 core samples, so a single antialiased pixel cannot
    /// claim one.
    private static func routeInk(_ shot: XCUIScreenshot, top: Int, bottom: Int) -> RouteInk {
        guard let image = shot.image.cgImage, bottom > top,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return RouteInk(fraction: 0, coverage: 0) }
        let rowStride = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        let first = max(0, top), last = min(bottom, image.height)
        var gold = 0, sampled = 0, rows = 0, rowsWithRoute = 0
        for y in stride(from: first, to: last, by: 2) {
            var warm = 0, core = 0
            for x in stride(from: 0, to: image.width, by: 2) {
                let i = y * rowStride + x * bpp
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                sampled += 1
                guard r >= g, g >= b else { continue }
                if r > 90, r - b > 40 { warm += 1 }
                if r > 140, r - b > 85 { core += 1 }
            }
            gold += warm
            rows += 1
            if core >= 2 { rowsWithRoute += 1 }
        }
        return RouteInk(
            fraction: sampled == 0 ? 0 : Double(gold) / Double(sampled),
            coverage: rows == 0 ? 0 : Double(rowsWithRoute) / Double(rows)
        )
    }

    /// THE TEST. Sample the map continuously from before the flip to well after
    /// it, and assert the drawn route never leaves the screen.
    ///
    /// Verdicts (iPhone 17 Pro, iOS 26.5). On this branch coverage holds
    /// 0.699–0.703 through the flip while the ink swings 2.0×: min/settled =
    /// 1.000, zero collapsed frames. With the defect restored — a `replayKey`
    /// `onChange` plus a presentation that ignores the ledger — the SAME sequence
    /// reads 0.699 → **0.000** on the frame after the flip, then 0.015, 0.078,
    /// 0.217, 0.421, 0.563, 0.683, 0.756: the client's ~0.5s vanish and 1.6s
    /// replay, measured.
    func testTheEtchedRouteDoesNotCollapseOnTheContinueFlip() {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderScheduledReviewRealPath"
        app.launch()

        // The map band: below the status bar, above the sheet. Both sheets in
        // this transition resolve to `rideRequestRouteMapBottomInset`, so the band
        // is the same one either side of the flip — which is the client's own
        // "same camera" observation, made into the sampling window.
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        // Scale off the CGImage's PIXEL width, not `UIImage.size` — a screenshot's
        // `size` is already in points, so dividing it by the window's width gives
        // 1 and the band lands on the top eighth of the screen. (Cost a round.)
        let probe = XCUIScreen.main.screenshot()
        let pixelWidth = CGFloat(probe.image.cgImage?.width ?? 0)
        let scale = window.frame.width > 0 && pixelWidth > 0 ? pixelWidth / window.frame.width : 1
        let top = Int(70 * scale)
        let bottom = Int((window.frame.height - MRTRideRequestRouteMapBottomInset - 8) * scale)

        // Wait until the route is DRAWN. The scene drives Continue on its own
        // `reviewEtchSettleAllowance` after MKDirections answers, so this loop is
        // watching for the same settled state it is.
        var drawn = 0.0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let ink = Self.routeInk(XCUIScreen.main.screenshot(), top: top, bottom: bottom)
            if ink.coverage > 0.6 { drawn = ink.coverage; break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertGreaterThan(drawn, 0.6, "precondition: the search preview drew a real route end to end")
        attach(XCUIScreen.main.screenshot(), named: "myr390-1-etched-on-search")

        // Sample straight through the flip. No sleep between frames — the collapse
        // is ~0.5s and a polled sampler with a delay can step over it.
        let cta = app.buttons[Self.scheduledCTA]
        var samples: [(offset: Double, ink: RouteInk, onReview: Bool)] = []
        var preFlip: [RouteInk] = []
        var postFlip: [RouteInk] = []
        var flipSeen = false
        var flipAt: Date?
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 10 {
            let ink = Self.routeInk(XCUIScreen.main.screenshot(), top: top, bottom: bottom)
            let onReview = cta.exists
            if onReview, !flipSeen { flipSeen = true; flipAt = Date() }
            samples.append((Date().timeIntervalSince(t0), ink, onReview))
            if flipSeen { postFlip.append(ink) } else { preFlip.append(ink) }
            // MYR-395 — stop on TIME, not on a frame count. `postFlip.count > 45`
            // stopped a fast machine after ~2.2s, which is inside the 0.5s + 1.6s
            // window the sampling exists to cover, and let a slow one run the full
            // budget. Three seconds past the flip covers the whole replay on any
            // machine, and the span is asserted below rather than assumed.
            if let flipAt, Date().timeIntervalSince(flipAt) > 3 { break }
        }

        for s in samples {
            NSLog(String(format: "MRT_MYR390 t=%.2f coverage=%.3f ink=%.5f review=%@",
                         s.offset, s.ink.coverage, s.ink.fraction, s.onReview ? "Y" : "N"))
        }
        attach(XCUIScreen.main.screenshot(), named: "myr390-2-after-the-flip")

        XCTAssertTrue(flipSeen, "precondition: the scene must have driven Continue to the scheduled sheet")

        // MYR-395 — THE TWO PRECONDITIONS NOW MEASURE WHAT THEY MEAN, because as
        // written they measured FRAME COUNT, which is a property of how loaded the
        // machine is rather than of the app. Hit in a full-suite run on this
        // branch: `preFlip.count > 2` failed with exactly 2 while the assertion it
        // is a precondition FOR never ran, and the same test passed 3/3 in
        // isolation at 0.732 → 0.719. Screenshot capture simply got slower, so
        // fewer frames fitted in the same ~1s window between "route drawn" and the
        // scene's own `reviewEtchSettleAllowance` flip. Neither the real assertion
        // nor any threshold in it is touched.
        //
        // (1) What the pre-flip count stood in for is "we have a trustworthy
        // SETTLED BASELINE". Assert that directly: the baseline has to agree with
        // the `drawn` coverage measured before sampling began — which is a
        // STRONGER claim than a frame count, and rests on this test's own finding
        // that settled coverage is flat to ±0.004 while the glow swings 2×
        // underneath. Two samples of a flat quantity are a fine median.
        XCTAssertGreaterThanOrEqual(preFlip.count, 1, "precondition: at least one settled frame before the flip")
        let settled = preFlip.map(\.coverage).sorted()[preFlip.count / 2]
        // `drawn` is the coverage at the moment the wait loop's 0.6 THRESHOLD was
        // crossed, so it is a point on the etch's ramp (measured: 0.681) and not
        // the settled value (0.732). The relationship that always holds is
        // MONOTONIC — the etch only ever adds line — so the baseline must be at
        // least what was already on screen. That rules out the failure this
        // precondition exists for (a baseline taken from a collapsed frame) without
        // pretending the two numbers are the same measurement.
        XCTAssertGreaterThanOrEqual(
            settled, drawn - 0.02,
            "precondition: the pre-flip baseline must be a settled route, not less line than the wait loop already saw"
        )

        // (2) What the post-flip count stood in for is "we sampled ACROSS the whole
        // 0.5s vanish + 1.6s replay the defect would occupy". That is a span of
        // wall-clock time, not a number of frames, and stating it as time is
        // load-independent: a slower machine takes fewer, later screenshots over
        // the same 2.1s and still cannot miss a collapse that lasts all of it.
        let postFlipSpan = (samples.filter(\.onReview).map(\.offset).max() ?? 0)
            - (samples.filter(\.onReview).map(\.offset).min() ?? 0)
        XCTAssertGreaterThan(
            postFlipSpan, 2.5,
            "precondition: sampling must span the 0.5s vanish + 1.6s replay (spanned \(postFlipSpan)s over \(postFlip.count) frames)"
        )
        XCTAssertGreaterThan(postFlip.count, 6, "precondition: enough frames in that span to see a ramp")
        let floor = postFlip.map(\.coverage).min() ?? 0
        let inkSwing = (postFlip.map(\.fraction).max() ?? 0) / max(postFlip.map(\.fraction).min() ?? 1, 0.00001)
        NSLog(String(format: "MRT_MYR390 settled-coverage=%.3f post-flip min=%.3f ratio=%.3f (ink swung %.1fx)",
                     settled, floor, settled > 0 ? floor / settled : 0, inkSwing))

        // 0.85, with a wide margin either side, and stated as a COUNT so one
        // anomalous frame cannot fail a healthy run: the settled route measures
        // flat to ±0.004 across the whole sequence, and the defect puts SIX
        // consecutive frames under this line (0.000 → 0.015 → 0.078 → 0.217 →
        // 0.421 → 0.563) before it climbs back out.
        let collapsed = postFlip.filter { $0.coverage < settled * 0.85 }.count
        XCTAssertLessThanOrEqual(
            collapsed, 1,
            "the drawn route must survive the flip — \(collapsed) frames lost it, bottoming at \(floor) from a settled \(settled)"
        )
    }
}

/// `MRTMetrics.rideRequestRouteMapBottomInset` — the sheet inset BOTH sides of
/// this transition resolve to. Literal because the UI-test bundle does not link
/// DesignSystem, and stated here rather than guessed at because the whole point
/// of the sampling band is that it does not move when the sheet does.
private let MRTRideRequestRouteMapBottomInset: CGFloat = 430
