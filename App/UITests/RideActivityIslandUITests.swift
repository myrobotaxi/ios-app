import UIKit
import XCTest

// MARK: - MYR-398 v3 — photographing a surface this app does not draw
//
// The redesigned Live Activity is rendered by the `MyRoboTaxiWidgets` process onto
// the SYSTEM's own surfaces, so booting a screen and screenshotting the app
// captures nothing (MYR-172 established that; the `riderLiveActivity` scene starts
// a real Activity and the picture is of the system).
//
// `simctl` reaches the COMPACT island and no further: backgrounding the app shows
// it, and `simctl io screenshot` takes the whole screen. The EXPANDED island needs
// a long press on a SpringBoard element, which is a gesture headless tooling cannot
// perform — the same `ExpandedRouteUITests` / `DriveSummaryCelebrationUITests`
// situation, and the same answer. This suite synthesizes that press and attaches
// what comes back.
//
// v3 SWEEPS ALL FOURTEEN BOARD ROWS, because the redesign changed what every one of
// them renders and two of them did not exist before this round. The rows are
// `design/la/la-data.jsx`'s, in its order, so the attachments can be read straight
// against the board.
//
// WHAT THIS SUITE DELIBERATELY DOES NOT CLAIM. The LOCK-SCREEN card still has no
// route: `simctl` has no lock command, XCUITest cannot lock a device, and the
// Simulator's own Device ▸ Lock is a menu a human clicks. That gap is stated in the
// PR rather than papered over — a capture of the expanded island is not a capture
// of the lock screen, and the two lay out differently (a 20pt tile vs a 28pt one, a
// ground we draw versus one the hardware owns, and the card's wordmark row, which
// the island has no equivalent of at all).
//
// It is also NOT a pass/fail assertion about pixels. What it asserts is that an
// Activity is genuinely RUNNING (so a green run cannot be a photograph of nothing)
// and that the press was delivered; the frames are evidence for the PR, read by a
// person.
//
// ⚠️ **WHAT v3 RETIRED FROM THIS SUITE.** v2's
// `testTheLongestCompactWordsFitTheSlot` measured a status-word width ladder in the
// compact trailing slot. **v3 has no status words there at all** — a figure
// (`8 min` / `1 min` / `3:42 PM`), a glyph, or nothing — so the ladder, the ~91pt
// ceiling it found, and the "Ride cancelled" truncation it caught are all moot. The
// width question moved to the CARD's fixed 24pt headline row and its
// `lineLimit(1)`, which `RideActivityGeometryTests` measures directly and
// `testTheLongestStringsAreCaptured` photographs.
//
// ⚠️ **MYR-412 CHANGES WHAT THESE FRAMES SHOW, ON PURPOSE.** `arrived` and
// `completed` render a BARE wave and a BARE check in the trailing slot (compact and
// expanded) instead of the same glyphs inside a ring, and every ring state renders a
// solid track plus a partial gold arc with nothing in its middle instead of #168's
// dashed full ring with the east arrow in it. Those frames are also where the
// CLIPPING fix is read: the ring's ink used to come back 23.00pt wide against
// 24.67pt tall — the horizontal axis shaved flat to its declared frame — and now
// comes back square. The FIGURE states are byte-identical (measured base vs branch:
// `accepted` bbox `None`; `enroute` differs only in the wall-clock minute its
// `{h:mm A}` is composed from).
final class RideActivityIslandUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The Dynamic Island's own rectangle on iPhone 17 Pro, in points from the
    /// physical top-left. Re-measured here rather than imported from anywhere: it
    /// is the SYSTEM's geometry, not this app's, and nothing in this repo may
    /// pretend to own it.
    private static let islandCentre = CGVector(dx: 0.5, dy: 0.0)
    private static let islandCentreYOffset: CGFloat = 22

    private func startActivity(state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderLiveActivity"
        app.launchEnvironment["MRT_ACTIVITY_STATE"] = state
        app.launch()
        // The scene starts the Activity from `RootView.init`, through the shipping
        // `SystemRideActivityPresenter`. Give it a beat to be requested before the
        // app leaves the foreground — an Activity that has not been granted yet
        // renders nothing at all, and the resulting empty island looks exactly like
        // a layout bug.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20),
            "the rider shell should be up before the Activity is photographed"
        )
        // The pre-start sweep costs up to ~1.5s on its own (`RideActivityDebugLauncher`
        // retries until ActivityKit's asynchronously-restored `activities` list is
        // empty), and the FIRST launch in a test method is the slow one. Measured:
        // 2.5s left the first iteration of each method photographing an island that
        // had not appeared yet — which looks exactly like a widget that renders
        // nothing.
        Thread.sleep(forTimeInterval: 5)
        return app
    }

    /// The same launch with one extra environment value — the §0 probes are
    /// orthogonal to `MRT_ACTIVITY_STATE`, exactly as `MRT_EXPAND_ROUTE` and
    /// `MRT_ROUTE_UNAVAILABLE` are to their scenes.
    private func startActivity(state: String, extra: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = "riderLiveActivity"
        app.launchEnvironment["MRT_ACTIVITY_STATE"] = state
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        return app
    }

    private func attach(_ screenshot: XCUIScreenshot, named: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = named
        add(attachment)
    }

    /// Background the app, photograph the COMPACT island, long-press for the
    /// EXPANDED one, photograph that, collapse.
    private func captureBothIslandStates(_ state: String) {
        let app = startActivity(state: state)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-\(state)")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard
            .coordinate(withNormalizedOffset: Self.islandCentre)
            .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            .press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1.5)
        attach(XCUIScreen.main.screenshot(), named: "island-expanded-\(state)")

        // Collapse again so the next iteration starts from a known place.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// la-data rows 1-6 — the PICKUP LEG, end to end.
    ///
    /// The set is chosen so every compact vocabulary is covered and can be told
    /// apart at a glance: `accepted` / `arriving` carry the FIGURE (15/600 tabular),
    /// `arrived` carries the WAVE glyph, and `dispatch` / `pickupNoETA` /
    /// `noTelemetry` carry the MARK ALONE with nothing trailing it.
    ///
    /// The pair that matters most is `pickupNoETA` vs `noTelemetry`: identical cards
    /// except the RAIL, which is live at 0.38 in one and idle at zero in the other.
    /// That distinction is the whole of "no ETA and no telemetry are two different
    /// states", and v2 could photograph neither of them.
    func testTheIslandRendersTheWholePickupLeg() throws {
        for state in ["dispatch", "accepted", "arriving", "pickupNoETA", "noTelemetry", "arrived"] {
            captureBothIslandStates(state)
        }
    }

    /// la-data rows 7, 8 and 10-14 — the TRIP LEG and the endings.
    ///
    /// `enroute` is the row the field report was about: it must read `3:42 PM` on the
    /// island and `3:42 PM dropoff` on the expanded card, and nothing anywhere may
    /// say "Arriving". The four endings differ from each other in exactly two lines
    /// of text and are otherwise identical — same footprint, same idle rail, same
    /// mark-only island — which is what the four frames are read for.
    func testTheIslandRendersTheTripLegAndEveryEnding() throws {
        for state in ["enroute", "enrouteNoETA", "completed", "declined", "cancelled", "expired", "unknown"] {
            captureBothIslandStates(state)
        }
    }

    /// la-data row 9 — staleness.
    ///
    /// ⚠️ **contracts 0.28.0 MADE THIS PHOTOGRAPHABLE FOR THE FIRST TIME, and the
    /// reason is worth reading before trusting the frames.** v2's only route to a
    /// stale card was `context.isStale`, which ActivityKit offers no way to force —
    /// a stale-date already in the past at `request` time is ignored or clamped
    /// (established by capture in MYR-172), and the island turned out not to be
    /// re-rendered when the deadline passes at all, so the presentation could never
    /// be photographed. **The `asOf` route does not depend on ActivityKit noticing
    /// anything**: the scene seeds an instant 4 minutes back, `RideActivityFreshness`
    /// puts that past the three-minute horizon at resolve time, and the card is
    /// stale in its FIRST frame.
    ///
    /// That is also the case the field exists for and the one a rider actually
    /// meets: the ETA ticker keeps pushing, `aps.stale-date` keeps being re-armed,
    /// ActivityKit never fires, and only `asOf` can say the server has stopped
    /// learning.
    ///
    /// **WHAT THE EXPANDED FRAME MUST SHOW**: "Dropoff soon" over
    /// **"Last updated {h:mm A}"**, with the rail HOLDING its fraction and still
    /// GOLD. The compact island must be unchanged and undimmed — it keeps the last
    /// figure, which v2 dropped to 45%. The stale time must read BEHIND the status
    /// bar's clock in the same screenshot; an `eta`-dated notice would read ahead of
    /// it, which is the v1 defect this field replaced.
    ///
    /// The ~8s ActivityKit stale-date is still armed and both sides of it are still
    /// photographed, so the pair also carries whatever that half does or does not
    /// do.
    func testTheStaleFrameIsPhotographedFromBothSidesOfItsDeadline() throws {
        let app = startActivity(state: "stale")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-stale-before")

        // Well past the ~8s deadline, and inside the ~60s window before iOS discards
        // a stale ephemeral Activity ("Ephemeral activity ended… no longer
        // relevant" — MYR-172's own finding).
        Thread.sleep(forTimeInterval: 18)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-stale-after")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard
            .coordinate(withNormalizedOffset: Self.islandCentre)
            .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            .press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1.5)
        attach(XCUIScreen.main.screenshot(), named: "island-expanded-stale")

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// **THE LONGEST STRINGS, PHOTOGRAPHED ON THE SURFACE THAT HAS TO HOLD THEM.**
    ///
    /// v3's card is a FIXED 350 × 128 with four FIXED rows and `lineLimit(1)`
    /// everywhere, so the failure mode is no longer a truncated island word — it is a
    /// headline or a subline that wraps and pushes the rail out of a card that cannot
    /// grow. `RideActivityGeometryTests` measures both rows against the widest
    /// strings through UIKit's text engine; this is the picture of the two worst
    /// cases actually rendering.
    ///
    ///   • `expired` — **"Reservation expired"**, the longest headline in the set.
    ///   • `enroute` — the trip subline over the scene's destination, plus the
    ///     `3:42 PM dropoff` headline, which is the widest of the two figure forms.
    ///
    /// Read the frames for an ellipsis in the headline row (there must not be one)
    /// and for a rail that is still on the card.
    func testTheLongestStringsAreCaptured() throws {
        for state in ["expired", "enroute"] {
            captureBothIslandStates(state)
        }
    }

    /// **THE PRE-0.28.0 FALLBACK, PHOTOGRAPHED AS ITS OWN ARM.**
    ///
    /// A server that predates the field omits `asOf` entirely, and absence means
    /// "this server does not say" rather than "just now" — so the card falls back to
    /// the wordless **"Waiting for an update"** instead of inventing an instant.
    /// The pair with `stale` is a clean one-key diff of exactly the subline, which is
    /// the only thing on either card that differs.
    ///
    /// It is an ordinary live arm rather than a legacy path: every installed build
    /// talking to an un-upgraded server takes it, and the alternative — dating the
    /// notice from the `eta` — is what v1 shipped and renders "in 4 minutes ago".
    ///
    /// ⚠️ Reaching it needs ActivityKit's own verdict, since there is no `asOf` to
    /// age out, so this one IS subject to the un-re-rendered-island finding and may
    /// photograph the fresh frame. The unit matrix covers the arm either way.
    func testTheStaleFallbackIsPhotographedForAServerWithNoInstant() throws {
        let app = startActivity(state: "staleNoInstant")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-staleNoInstant-before")

        Thread.sleep(forTimeInterval: 18)
        attach(XCUIScreen.main.screenshot(), named: "island-compact-staleNoInstant-after")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard
            .coordinate(withNormalizedOffset: Self.islandCentre)
            .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            .press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1.5)
        attach(XCUIScreen.main.screenshot(), named: "island-expanded-staleNoInstant")

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    // MARK: - §0 — the three items, photographed

    /// **§0 A — THE EXPANDED ISLAND'S HEIGHT FOLLOWS ITS CONTENT.**
    ///
    /// The client's acceptance, verbatim: *"the island's height DIFFERS between a
    /// two-line and three-line state (proves nothing is pinned)"*. So the pair is
    /// `enroute` — headline + a one-line subline — against `longPlace`, which is
    /// `enroute` with the client's own Galleria Dallas destination and therefore
    /// wraps the 12.5pt subline to two.
    ///
    /// **THE TWO EXPANDED FRAMES ARE THE MEASUREMENT**, and they are read by
    /// measuring the island's own black rounded rect in each: equal heights mean
    /// something in the builder is pinned, which is the whole defect. The compact
    /// frames come with them so the pair also shows the trailing slot resolving to a
    /// FIGURE on one surface and a ring on the other in the same instant.
    func testTheExpandedIslandHeightFollowsItsContent() throws {
        for state in ["enroute", "longPlace"] {
            captureBothIslandStates(state)
        }
    }

    /// **§0 A, THE FOLLOW-UP — CLEAR BLACK AT ALL FOUR CORNERS.**
    ///
    /// The client's report on the region rebuild: the mark (top-left) and the ring
    /// (top-right) intersect the pill's corner curvature, and the rail's origin puck
    /// and end cap run into the bottom two. So the acceptance is a picture — black
    /// between every piece of content and the pill's edge, at each corner — and the
    /// three states are chosen because between them they put the WIDEST thing this
    /// surface can draw into each corner in turn:
    ///
    ///   • `noTelemetry` — the rail is IDLE, so the 26pt ground disc of the puck
    ///     sits at the rail's ORIGIN, which is the bottom-LEFT case; the ring is in
    ///     its waiting mode, which draws ink all the way round the top-right.
    ///   • `completed` — `p = 1`, so the same disc sits at the rail's END, which is
    ///     the bottom-RIGHT case, with the destination pin removed from under it.
    ///   • `longPlace` — the three-line frame, i.e. the TALLEST island, where the
    ///     top and bottom corners are furthest apart and any inset that had been
    ///     absorbed into a fixed height would show up as a different clearance.
    ///
    /// The frames are read by measuring, per corner, the shortest distance from any
    /// non-black pixel to the pill's own boundary — see the PR body. A capture is
    /// not evidence on its own here: "looks clear" at 3× is exactly how a 2pt
    /// intersection survives review.
    func testTheExpandedIslandsFourCornersAreClear() throws {
        for state in ["noTelemetry", "completed", "longPlace"] {
            captureBothIslandStates(state)
        }
    }

    /// **MYR-417 — THE WAITING RING MOVES, AND THIS IS THE FRAME SEQUENCE THAT SAYS
    /// SO.**
    ///
    /// `noTelemetry` is the client's own screenshot: an accepted ride whose car has
    /// reported no fraction. §0 B gave that empty slot a ring; MYR-412 gave it the
    /// board's arc; **neither of them could make it move, and the client's video of
    /// a dead ring is what sent this round looking again.**
    ///
    /// ⚠️ **THE TWO EARLIER VERDICTS STAND AND THE CONCLUSION DRAWN FROM THEM DOES
    /// NOT.** §0 B measured `repeatForever` inert (six frames, bbox `None`); MYR-412
    /// measured SF Symbol effects inert (22 frames across two runs, bbox `None`).
    /// Both are about animations the APP arms, and a Live Activity's view is
    /// rendered out of process where none of those are run. **The system's own
    /// timer-driven elements are not animations** — they carry a DATE RANGE and the
    /// renderer re-derives them as the clock moves — and
    /// `ProgressView(timerInterval:)` in the circular style is one of them, which is
    /// what `RideActivityWaitingRing` now draws.
    ///
    /// So this test inverts its own predecessor: the frames must **DIFFER**. The
    /// assertion is on the trailing slot's own rectangle rather than on the whole
    /// screen, because the status bar's clock changes by itself and a whole-frame
    /// diff would pass over a motionless ring.
    ///
    /// Measured outside the suite on the same simulator, `simctl` frames 6s apart:
    /// bright-gold ink in the ring **116 → 192 → 270 → 348 px** across 18 seconds.
    /// Under Reduce Motion the same three frames are byte-identical (bbox `None`,
    /// max delta 0) — MYR-412's static arc, which is the fallback.
    func testTheWaitingRingMovesWhileALiveRideHasNoTelemetry() throws {
        let app = startActivity(state: "noTelemetry")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)

        // ≥5s apart against a 90s window — about 7% of the circle, which is many
        // times the antialiasing noise a static ring could produce.
        let first = XCUIScreen.main.screenshot()
        attach(first, named: "island-compact-noTelemetry-move-0")
        Thread.sleep(forTimeInterval: 6)
        let second = XCUIScreen.main.screenshot()
        attach(second, named: "island-compact-noTelemetry-move-1")

        XCTAssertNotEqual(
            Self.trailingSlotPixels(first),
            Self.trailingSlotPixels(second),
            "the waiting ring did not move in 6 seconds — the timer ring is not being run"
        )

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard
            .coordinate(withNormalizedOffset: Self.islandCentre)
            .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            .press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1.5)
        for index in 0..<2 {
            attach(XCUIScreen.main.screenshot(), named: "island-expanded-noTelemetry-move-\(index)")
            Thread.sleep(forTimeInterval: 6)
        }

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// The compact island's TRAILING slot, cropped out of a full-screen shot as raw
    /// pixels.
    ///
    /// The rectangle is the SYSTEM's geometry (iPhone 17 Pro), measured off a real
    /// frame exactly as `islandCentre` was, and deliberately generous: it holds the
    /// ring and nothing that changes for another reason. **Cropping is the whole
    /// point** — the status bar's own clock ticks, so a whole-screen comparison would
    /// report "changed" over a ring that never moved.
    private static func trailingSlotPixels(_ screenshot: XCUIScreenshot) -> Data? {
        guard let cgImage = screenshot.image.cgImage else { return nil }
        let scale = CGFloat(cgImage.width) / 402
        let rect = CGRect(x: 255 * scale, y: 15 * scale, width: 45 * scale, height: 35 * scale)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).pngData()
    }

    /// **§0 B — THE MINIMAL ISLAND, AND THE HONEST ANSWER THAT IT CANNOT BE
    /// PHOTOGRAPHED.**
    ///
    /// The minimal presentation is not a state of one Activity — it is what the
    /// island does with more than one. `MRT_ACTIVITY_MINIMAL` starts a second
    /// Activity (a DIFFERENT ride id: a duplicate would be MYR-405's defect wearing a
    /// capture hook's clothes) and the census proves both are live, `count=2
    /// [debug-ride/active, debug-ride-minimal/active]` — **and the island still
    /// renders ONE compact pill.** The split is for two different APPS; with two
    /// Activities of one app the system picks a presentation, and it picks compact.
    ///
    /// So this suite CANNOT claim a minimal frame, and the attachment is kept as the
    /// evidence of that rather than mislabelled as one.
    ///
    /// ⚠️ **MYR-412 WEAKENED WHAT CAN BE CLAIMED IN ITS PLACE, AND SAYING SO IS THE
    /// POINT.** This comment used to close by arguing that the minimal composition
    /// needs no frame because it is "the same `RideActivityProgressRing` over the same
    /// `expandedTrailing` resolution that the EXPANDED capture does show". That was
    /// true until the expanded slot went BARE: minimal is now the ONLY surface that
    /// draws a centre inside the ring, so **no capture in this repo shows the
    /// arrow-in-ring composition at all** — an unphotographed surface that used to
    /// borrow a photographed one's evidence. What survives is narrower and is stated
    /// rather than implied: the same component, the same slot resolution, the same
    /// 24pt/2.4, and `centre: .mark` is the parameter's DEFAULT, so the minimal call
    /// site is the un-parameterised one. The geometry is pinned by
    /// `RideActivityGeometryTests.testTheRingsCentreClearsItsOwnStroke`, which is now
    /// the minimal island's only guard.
    func testTheMinimalIslandRendersTheRing() throws {
        let app = startActivity(state: "accepted", extra: ["MRT_ACTIVITY_MINIMAL": "1"])

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        attach(XCUIScreen.main.screenshot(), named: "island-two-activities-still-compact")

        app.terminate()
    }

    /// **§0 C — THE ARRIVAL BEAT PLAYS ONCE, AND A RE-PUSH DOES NOT REPLAY IT.**
    ///
    /// The state lingers FIVE MINUTES (MYR-405) and the ETA ticker keeps pushing at
    /// it, so "plays once" is a claim about what happens on the SECOND, third and
    /// fourth arrival of the same frame — a claim no still can make and no unit test
    /// can reach, because the replay would live in the widget process's view tree.
    ///
    /// `MRT_ACTIVITY_REPUSH=6` re-pushes the IDENTICAL content state three times, six
    /// seconds apart. The frames straddle the second push: if the beat were armed by
    /// the view's appearance or by any flag the process holds, the glyph would drop
    /// back to 0.6 and spring in again and two consecutive frames would differ. They
    /// must not.
    ///
    /// The FIRST frame is deliberately taken before the first re-push, so the
    /// sequence also carries the settled beat to compare the rest against.
    func testTheArrivalBeatDoesNotReplayOnARepush() throws {
        let app = startActivity(state: "completed", extra: ["MRT_ACTIVITY_REPUSH": "6"])

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        attach(XCUIScreen.main.screenshot(), named: "island-beat-completed-settled")

        // Straddle the second re-push (t ≈ 12s from launch) at 0.25s intervals — a
        // spring that re-ran would be visibly mid-flight in at least one of these.
        Thread.sleep(forTimeInterval: 8)
        for index in 0..<8 {
            attach(XCUIScreen.main.screenshot(), named: "island-beat-completed-repush-\(index)")
            Thread.sleep(forTimeInterval: 0.25)
        }

        app.terminate()
    }

    /// **§0 C — THE BEAT ITSELF, ON A REAL TRANSITION.**
    ///
    /// No `MRT_ACTIVITY_STATE` value can show this: a scene starts the Activity
    /// already IN its state, and the beat is keyed to the CHANGE (which is the whole
    /// point — see `RideActivityRing.swift`), so a cold `arrived` scene correctly
    /// renders the settled frame and photographs nothing.
    /// `MRT_ACTIVITY_ADVANCE=16` pushes `accepted → arrived` through the shipping
    /// update path sixteen seconds in, with the island already EXPANDED, so the
    /// frames carry the full sequence: a determinate ring at 0.38 completing to 1,
    /// fading to 40%, and the wave scaling in over it.
    ///
    /// Shot back to back at ~0.2s so the beat (≈0.9s end to end) cannot fall between
    /// two frames.
    func testTheArrivalBeatPlaysOnTheTransition() throws {
        let app = startActivity(state: "accepted", extra: ["MRT_ACTIVITY_ADVANCE": "16"])

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard
            .coordinate(withNormalizedOffset: Self.islandCentre)
            .withOffset(CGVector(dx: 0, dy: Self.islandCentreYOffset))
            .press(forDuration: 1.1)
        Thread.sleep(forTimeInterval: 1.5)

        for index in 0..<30 {
            attach(XCUIScreen.main.screenshot(), named: "island-beat-arrived-\(index)")
            Thread.sleep(forTimeInterval: 0.2)
        }

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    /// **MYR-418 — THE SERVER SENDS THE COMPLETED STATE TWICE, AND THE CHECK MUST
    /// LAND ON THE FIRST AND HOLD THROUGH THE SECOND.**
    ///
    /// Apple silently ignores `aps.alert` on an END event, which is why the client's
    /// check mark never appeared: the single alerted end never expanded the island.
    /// The server now sends an alerted UPDATE carrying the completed state and the
    /// alert-free END carrying the SAME state ~1s later
    /// (`MRT_ACTIVITY_COMPLETE_SEQUENCE` performs exactly that against a running
    /// Activity).
    ///
    /// What the frames show, and it is worth being precise about which half of the
    /// sequence each surface can answer:
    ///
    ///   • **The UPDATE is photographable and is photographed here** — the bare white
    ///     check arrives in the trailing slot, which is (a).
    ///   • **THE END IS NOT.** An `.ended` Activity leaves the Dynamic Island
    ///     immediately — measured on this branch: 45 frames across the sequence, and
    ///     from ~1.4s after the end the pill is empty. The end's frame lives on the
    ///     LOCK-SCREEN card, which has no headless capture route at all (`simctl` has
    ///     no lock command). So (b) — that the identical re-delivery cannot replay the
    ///     beat — is proven where it CAN be: by
    ///     `testTheArrivalBeatDoesNotReplayOnARepush`, which re-delivers the identical
    ///     content state through the same update path, and by
    ///     `RideActivityCardTests`' equality of the two resolutions. A beat that
    ///     replayed on an identical frame would fail that repush test too; there is no
    ///     mechanism by which an END could replay one that an UPDATE cannot.
    func testTheCompletionSequenceLandsTheCheckOnTheUpdate() throws {
        let app = startActivity(state: "enroute", extra: ["MRT_ACTIVITY_COMPLETE_SEQUENCE": "8"])

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        attach(XCUIScreen.main.screenshot(), named: "island-418-before-the-update")

        // The update lands ~8s after launch and the end ~1s after it; sample across
        // both so the sequence is readable frame by frame.
        Thread.sleep(forTimeInterval: 4)
        for index in 0..<14 {
            attach(XCUIScreen.main.screenshot(), named: "island-418-sequence-\(index)")
            Thread.sleep(forTimeInterval: 0.25)
        }

        app.terminate()
    }

    /// **MYR-418 (c) — THE COLD END-ONLY DELIVERY STILL RENDERS THE CHECK.**
    ///
    /// An Activity started late, a dropped update, or a relaunch between the two
    /// deliveries all leave the widget meeting the completed state for the first time
    /// as the END. There is no transition, so there is nothing to animate and nothing
    /// may be invented: the frame is the settled check and it does not move.
    ///
    /// `MRT_ACTIVITY_END_ONLY=20` delivers the end with a completed state that was
    /// never pushed as an update. The two asserted frames are the COLD RENDER, and
    /// the assertion is that they are identical to each other, i.e. static.
    ///
    /// ⚠️ **THE DELAY IS TWENTY SECONDS FOR A MEASURED REASON.** An `.ended` Activity
    /// leaves the Dynamic Island immediately (it lives out its five-minute linger on
    /// the LOCK SCREEN, which has no headless capture route), so a frame taken after
    /// the end photographs an empty pill — the first version of this test used 8s,
    /// straddled the end, and failed for exactly that reason. The final frame is
    /// attached rather than asserted, as the record of that behaviour.
    func testAColdEndOnlyDeliveryRendersTheStaticCheck() throws {
        let app = startActivity(state: "completed", extra: ["MRT_ACTIVITY_END_ONLY": "20"])

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)

        let first = XCUIScreen.main.screenshot()
        attach(first, named: "island-418-endonly-0")
        Thread.sleep(forTimeInterval: 2)
        let second = XCUIScreen.main.screenshot()
        attach(second, named: "island-418-endonly-1")

        XCTAssertEqual(
            Self.trailingSlotPixels(first),
            Self.trailingSlotPixels(second),
            "a cold completed frame must be static — a beat here would be one keyed to appearance"
        )

        // The end lands at t ≈ 20s. Attached, not asserted: the island drops an
        // ended Activity, so this frame is the empty pill and the card it leaves
        // behind is on a surface nothing here can photograph.
        Thread.sleep(forTimeInterval: 14)
        attach(XCUIScreen.main.screenshot(), named: "island-418-endonly-after-the-end")

        app.terminate()
    }

    /// The settled frame on both stops, cold — what a rider sees for the minutes
    /// AFTER the beat, which is most of the time this state is on screen.
    func testTheArrivalStatesSettleStatically() throws {
        for state in ["arrived", "completed"] {
            captureBothIslandStates(state)
        }
    }

    /// **THE FIGURE HOLDS** — the client's 2026-07-31 ruling, photographed.
    ///
    /// *"We are pulling live data from Tesla ETA telemetry; counting down is
    /// inaccurate."* So between pushes the ETA figure must not move: what the card
    /// shows is what the CAR last said, and a phone decrementing it locally would be
    /// presenting an extrapolation as the car's own answer.
    ///
    /// One Activity, two frames ~70 seconds apart, over an ETA seeded 6 minutes out.
    /// Both frames must read the SAME figure while the status-bar clock in the same
    /// screenshots advances a minute — which is what makes the pair evidence rather
    /// than a still.
    ///
    /// It is also the regression guard for the mechanism, and it carried over from v2
    /// unchanged because the ruling did: this build has no clock in the widget
    /// process at all, and v2 measured that ActivityKit would not have ticked one
    /// anyway.
    func testTheCountdownFigureHOLDSBetweenPushes() throws {
        let app = startActivity(state: "accepted")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        attach(XCUIScreen.main.screenshot(), named: "island-hold-t0")

        // Just over a minute, so a figure that counted down locally could not
        // possibly still read the same.
        Thread.sleep(forTimeInterval: 70)
        attach(XCUIScreen.main.screenshot(), named: "island-hold-t70")

        app.terminate()
    }
}
