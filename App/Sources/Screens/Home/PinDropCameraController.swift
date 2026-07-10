import CoreLocation
import DesignSystem
import Foundation
import MapKit

// MARK: - PinDropCameraController (MYR-217 — the ONE camera owner during pin-drop;
// re-designed MYR-222 — seat ONCE per entry, no wall clock)
//
// WHY THIS EXISTS (the MYR-213/215/216 recurrence): the rider-map camera had
// SIX independent programmatic writers racing each other and the user across
// async boundaries; MYR-217 subordinated them all to this single owner and
// pinned every write to the street span. See `PinDropCameraOwnershipTests` for
// the full history.
//
// WHY IT WAS RE-DESIGNED (MYR-222, the client's streaming-GPS feedback loop):
// MYR-217 was verified — four rounds deep — against a STATIC simulated fix.
// Real devices STREAM fixes (~1Hz, MYR-221 made devices default to live), and
// two MYR-217 decisions turned that stream into a camera feedback loop:
//
//   1. `fixChanged` re-armed a FULL re-seat (fresh budget, back to `.seating`)
//      on EVERY fix, from `.settled` too — so "seated" lasted at most one GPS
//      tick. Each re-seat wrote the analytic first guess, whose estimate error
//      (~130m: `visibleLatitudeDelta` models MapKit's inset fitting only
//      approximately) was then corrected by a refinement — TWO opposing
//      camera writes per second, forever. That is the client's "pin bounces
//      back and forth".
//   2. User takeover was inferred from a WALL-CLOCK write window
//      (`writeWindowUntil`, 1.2s) that every write extended. With writes
//      arriving faster than the window lapses, the window never expired —
//      the user's drag settles were consumed as seating refinements and
//      snapped back. `.userControlled` was UNREACHABLE under a streaming fix.
//      (Backgrounding "healed" the app precisely by starving the loop: no
//      fixes while suspended → the window finally lapsed → the first settle
//      after resume classified as the user's → the owner stood down.)
//
// THE MYR-222 DESIGN (client-approved):
//   • ONE seating sequence per ENTRY: `enter()` arms a single bounded pass
//     (entry write + at most `refinementBudgetPerSeat` further writes — refine
//     AND re-aim writes all draw from the same per-entry budget). Once
//     `.settled`, GPS fixes move the blue-dot annotation only — ZERO camera
//     writes, ZERO pin movement, at any fix rate. The only exception is a
//     LATE FIRST FIX: an entry that had no fix at all (cold authorize, fix
//     not yet delivered) completes its one real seat when the first fix
//     lands — once. A fix-seated entry is done for good.
//   • NO wall clock: settle attribution is token accounting
//     (`CameraSettleLedger`) — every owner write registers its expected
//     settle; a settle matching an outstanding expectation is ours, anything
//     else in `.settled` is the user (`.userTookOver`, owner stands down for
//     the entry). During the brief `.seating` pass an unmatched settle is
//     treated as pre-entry churn and refined over (budget-bounded, so it
//     always terminates); real gestures mid-seat are caught immediately by
//     `userGestureBegan()` (the map's gesture recognizers), which wins from
//     ANY phase.
//   • Background/foreground is handled BY DESIGN: `sceneWillBackground()`
//     drops expectations whose settles will never arrive; if the app was
//     suspended mid-seat, `sceneDidForeground()` re-arms ONE clean re-seat.
//     `.settled` / `.userControlled` survive a background round-trip
//     untouched — backgrounding is a no-op, not a healing ritual.
//
// Every write still carries the street span (`MRTMetrics.pinDropStreetSpanDelta`)
// — a span can NEVER be inherited from a settle context (the MYR-216 bug) —
// and MapProxy remains the authoritative source of the CONFIRMED pickup
// coordinate: seating is a courtesy, never a correctness requirement.
//
//   inactive ──enter()──▶ seating ──matched settle──▶ settled
//                            │  ▲                        │
//                            │  └── late FIRST fix ──────┘        (once)
//                            └──userGestureBegan / unmatched ──▶ userControlled
//                               settle while settled               (terminal
//                                                                   for entry)
@MainActor
@Observable
final class PinDropCameraController {

    // MARK: State machine

    enum Phase: Equatable {
        /// Not in pin-drop — the controller owns nothing.
        case inactive
        /// The one bounded seating pass is converging on the fix.
        case seating
        /// Seated (or accepted) — reporting-only; fixes move the blue dot only.
        case settled
        /// A user gesture moved the camera — the owner NEVER writes again for
        /// this pin-drop entry ("user zoom/pan wins", no fighting).
        case userControlled
    }

    /// A camera write the controller wants applied. The view applies it to the
    /// binding verbatim — the controller is the only source of these during
    /// pin-drop, and `region.span` is ALWAYS the street span.
    struct Write: Equatable {
        var region: MKCoordinateRegion
        var animated: Bool

        static func == (lhs: Write, rhs: Write) -> Bool {
            lhs.animated == rhs.animated
                && lhs.region.center.latitude == rhs.region.center.latitude
                && lhs.region.center.longitude == rhs.region.center.longitude
                && lhs.region.span.latitudeDelta == rhs.region.span.latitudeDelta
                && lhs.region.span.longitudeDelta == rhs.region.span.longitudeDelta
        }
    }

    /// What the view should do with a camera settle during pin-drop.
    enum SettleOutcome: Equatable {
        /// Owner refinement — apply this write; do NOT report the coordinate
        /// yet (the framing is still converging on the fix).
        case refine(Write)
        /// Seating finished — report the glyph coordinate as the pickup.
        case seated
        /// A settle the owner didn't write — the user panned/zoomed. Report
        /// the coordinate; the owner stands down for this entry.
        case userTookOver
        /// Nothing for the owner to do — just report the glyph coordinate.
        case report
    }

    private(set) var phase: Phase = .inactive

    // MARK: Tuning (injectable for tests; defaults are the product values)

    /// The street-level entry span — the ONLY span this controller ever writes.
    let streetSpanDelta: Double
    /// The glyph's vertical screen fraction (above the optical center).
    let glyphScreenFraction: Double
    /// Glyph-on-fix tolerance (degrees) — ~2m latitude, matches MYR-216.
    let alignmentEpsilonDegrees: Double

    /// Camera writes allowed per entry AFTER the entry write itself — refine
    /// and re-aim writes all draw from this one budget, so a seating pass can
    /// never loop (MYR-222: the budget is per-ENTRY; the MYR-217 design reset
    /// it on every fix, which is what let a streaming fix re-arm seating
    /// forever). Three covers the worst case: a stale pre-entry settle
    /// re-issuing the analytic target, a mid-seat fix re-aim, then one exact
    /// delta-shift at street geometry.
    private static let refinementBudgetPerSeat = 3

    // MARK: Per-entry state

    private var entryFix: CLLocationCoordinate2D?
    private var fallbackCenter = CLLocationCoordinate2D()
    private var viewportSize = CGSize.zero
    private var refinementBudget = 0
    /// Token accounting for the owner's own writes — no wall clock (MYR-222).
    private var ledger = CameraSettleLedger()

    init(
        streetSpanDelta: Double = MRTMetrics.pinDropStreetSpanDelta,
        glyphScreenFraction: Double = Double(MRTMetrics.ridePinDropGlyphScreenFraction),
        alignmentEpsilonDegrees: Double = 0.00002
    ) {
        self.streetSpanDelta = streetSpanDelta
        self.glyphScreenFraction = glyphScreenFraction
        self.alignmentEpsilonDegrees = alignmentEpsilonDegrees
    }

    // MARK: Events

    /// Pin-drop entered (warm `.onChange` transition or cold `onAppear` mount —
    /// ONE shared path, closing the MYR-215 cold-vs-warm split). Arms the
    /// single per-entry seating pass and returns the entry write: street span,
    /// fix under the glyph (analytic first guess), or the fallback center when
    /// there is no fix (sim / unauthorized).
    func enter(
        fix: CLLocationCoordinate2D?,
        fallbackCenter: CLLocationCoordinate2D,
        viewportSize: CGSize,
        animated: Bool
    ) -> Write {
        entryFix = fix
        self.fallbackCenter = fallbackCenter
        self.viewportSize = viewportSize
        refinementBudget = Self.refinementBudgetPerSeat
        phase = .seating
        ledger.clear()
        return expected(Write(region: analyticRegion(), animated: animated))
    }

    /// Pin-drop exited — the owner releases the camera.
    func exit() {
        phase = .inactive
        entryFix = nil
        ledger.clear()
    }

    /// A device fix arrived during pin-drop. MYR-222: fixes NEVER re-arm a
    /// finished seat — after `.settled` they move the blue-dot annotation
    /// only. The two cases that still write, both bounded by the per-entry
    /// budget:
    ///   • mid-seat (`.seating`): re-aim the in-flight pass at the fresh fix
    ///     (the `enterPinDrop()` `refresh()` fix routinely lands here);
    ///   • late FIRST fix: the entry had no fix at all, so the fallback
    ///     framing settled without ever seating a fix — the first fix to
    ///     arrive completes the entry's one real seat, once.
    func fixChanged(_ fix: CLLocationCoordinate2D) -> Write? {
        switch phase {
        case .inactive, .userControlled:
            return nil
        case .seating:
            entryFix = fix
            guard refinementBudget > 0 else { return nil }
            refinementBudget -= 1
            return expected(Write(region: analyticRegion(), animated: true))
        case .settled:
            // Seated on a fix → done for good; fixes are blue-dot-only now.
            guard entryFix == nil else { return nil }
            // Late first fix: the one real seat this entry never got.
            entryFix = fix
            refinementBudget = Self.refinementBudgetPerSeat
            phase = .seating
            return expected(Write(region: analyticRegion(), animated: true))
        }
    }

    /// The user's finger moved the map (gesture recognizer, not settle
    /// inference) — the user wins from ANY phase, immediately and permanently
    /// for this entry. Mid-seat this aborts the pass outright: no budget
    /// fighting, no waiting for a settle to classify.
    func userGestureBegan() {
        guard phase == .seating || phase == .settled else { return }
        phase = .userControlled
        ledger.clear()
    }

    /// A camera settle during pin-drop. `glyphCoordinate` is MapKit's ground
    /// truth for the glyph's rendered point (`MapProxy.convert`);
    /// `cameraCenter`/`cameraLatitudeDelta` are the settle context's region.
    /// NOTE the settle context's span is used ONLY for ledger matching — it
    /// never flows into a write (the MYR-216 bug).
    func cameraSettled(
        glyphCoordinate: CLLocationCoordinate2D,
        cameraCenter: CLLocationCoordinate2D,
        cameraLatitudeDelta: Double
    ) -> SettleOutcome {
        switch phase {
        case .inactive, .userControlled:
            return .report
        case .settled:
            if ledger.classifySettle(center: cameraCenter, latitudeDelta: cameraLatitudeDelta) {
                return .report // our own trailing/duplicate settle
            }
            // A settle the owner didn't write — the user moved the map.
            phase = .userControlled
            ledger.clear()
            return .userTookOver
        case .seating:
            let isOwnWrite = ledger.classifySettle(center: cameraCenter, latitudeDelta: cameraLatitudeDelta)
            guard let fix = entryFix else {
                // No fix to seat (sim / no authorization): the entry framing
                // itself is the destination — done on the first settle.
                phase = .settled
                return .seated
            }
            if isAligned(glyphCoordinate, with: fix) {
                phase = .settled
                return .seated
            }
            guard refinementBudget > 0 else {
                // Accept: MapProxy ground truth keeps the CONFIRMED pickup
                // honest even when seating couldn't converge (e.g. the fix sits
                // outside a hard MapKit camera constraint).
                phase = .settled
                return .seated
            }
            refinementBudget -= 1
            let region: MKCoordinateRegion
            if isOwnWrite {
                // OUR street-geometry settle: shift the center by the observed
                // (fix − glyph) residual. Exact for a fixed geometry (the write
                // requests the same street span the camera already has, so the
                // projection doesn't change under the shift).
                region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: cameraCenter.latitude + (fix.latitude - glyphCoordinate.latitude),
                        longitude: cameraCenter.longitude + (fix.longitude - glyphCoordinate.longitude)
                    ),
                    span: streetSpan // NEVER the settle's span
                )
            } else {
                // A settle we didn't write, mid-seat: pre-entry camera motion
                // still landing (the MYR-217 four-round interleaving) or an
                // unrecognized layout re-fit. Its deltas are measured at an
                // unknown geometry and are NOT trusted — re-issue the analytic
                // street-span target. Budget-bounded, so churn can never loop
                // the pass; a real user gesture lands as `userGestureBegan()`
                // (immediate) or, at the latest, as the first unmatched settle
                // after `.settled`.
                region = analyticRegion()
            }
            return .refine(expected(Write(region: region, animated: true)))
        }
    }

    // MARK: Scene lifecycle (MYR-222 — background/foreground safe BY DESIGN)

    /// The app is being suspended. Settles for in-flight writes may never
    /// arrive (MapKit stops delivering while backgrounded) — drop the
    /// expectations so they can't misattribute anything after resume.
    /// `.settled` / `.userControlled` carry no expectations and are untouched:
    /// a background round-trip in those phases is a designed no-op.
    func sceneWillBackground() {
        guard phase == .seating else { return }
        ledger.clear()
    }

    /// The app returned to the foreground. If suspension interrupted the
    /// seating pass, re-arm ONE clean re-seat (fresh budget, un-animated —
    /// the user is looking at a fresh appearance, not a camera move); in any
    /// other phase this is a no-op — the states survive the round-trip.
    func sceneDidForeground() -> Write? {
        guard phase == .seating else { return nil }
        refinementBudget = Self.refinementBudgetPerSeat
        ledger.clear()
        return expected(Write(region: analyticRegion(), animated: false))
    }

    // MARK: Geometry (pure, unit-tested)

    private var streetSpan: MKCoordinateSpan {
        MKCoordinateSpan(latitudeDelta: streetSpanDelta, longitudeDelta: streetSpanDelta)
    }

    /// Register the write's expected settle before handing it out.
    private func expected(_ write: Write) -> Write {
        ledger.expect(center: write.region.center, spanDelta: write.region.span.latitudeDelta)
        return write
    }

    private func analyticRegion() -> MKCoordinateRegion {
        Self.entryRegion(
            fix: entryFix,
            fallbackCenter: fallbackCenter,
            spanDelta: streetSpanDelta,
            glyphScreenFraction: glyphScreenFraction,
            viewportSize: viewportSize
        )
    }

    private func isAligned(_ a: CLLocationCoordinate2D, with b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) <= alignmentEpsilonDegrees
            && abs(a.longitude - b.longitude) <= alignmentEpsilonDegrees
    }

    /// The entry region: street span, centered so the FIX renders under the
    /// glyph (which sits `glyphScreenFraction` down the screen — above the
    /// optical center, so the camera center goes SOUTH of the fix by the same
    /// on-screen distance). Pure + static so the math is unit-testable.
    /// With no fix, the fallback center at the street span (sim framing —
    /// byte-identical to the MYR-215 cold `recenter`).
    static func entryRegion(
        fix: CLLocationCoordinate2D?,
        fallbackCenter: CLLocationCoordinate2D,
        spanDelta: Double,
        glyphScreenFraction: Double,
        viewportSize: CGSize
    ) -> MKCoordinateRegion {
        let span = MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
        guard let fix else {
            return MKCoordinateRegion(center: fallbackCenter, span: span)
        }
        let visibleLat = visibleLatitudeDelta(
            requestedSpanDelta: spanDelta, latitude: fix.latitude, viewportSize: viewportSize
        )
        // Screen y grows downward; latitude grows upward. The glyph is
        // (0.5 − fraction) of the viewport ABOVE center, so the coordinate
        // under it is that fraction of the visible span NORTH of center:
        // center.lat = fix.lat − (0.5 − fraction) · visibleLat.
        let center = CLLocationCoordinate2D(
            latitude: fix.latitude - (0.5 - glyphScreenFraction) * visibleLat,
            longitude: fix.longitude
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// The latitude span the viewport will actually SHOW for a requested
    /// square-degree span: MapKit fits the whole requested region, and in a
    /// portrait viewport the longitude edge binds (longitude degrees shrink by
    /// cos(latitude)), so the visible latitude span stretches by the aspect
    /// ratio. An estimate — each seating pass verifies against MapProxy ground
    /// truth, so residual error only costs a (budgeted) refinement.
    static func visibleLatitudeDelta(
        requestedSpanDelta: Double,
        latitude: Double,
        viewportSize: CGSize
    ) -> Double {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return requestedSpanDelta }
        let aspect = Double(viewportSize.height / viewportSize.width)
        let latShownIfLongitudeBinds = requestedSpanDelta * cos(latitude * .pi / 180) * aspect
        return max(requestedSpanDelta, latShownIfLongitudeBinds)
    }
}
