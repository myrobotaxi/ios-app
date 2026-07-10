import CoreLocation
import DesignSystem
import Foundation
import MapKit

// MARK: - PinDropCameraController (MYR-217 — the ONE camera owner during pin-drop)
//
// WHY THIS EXISTS (the MYR-213/215/216 recurrence): the rider-map camera had
// SIX independent programmatic writers (`VehicleMapView`: onAppear framing, the
// progress-tick follow recenter, the follow re-engage recenter, the device-fix
// recenter, the MYR-215 pin-drop entry re-frame, and the MYR-216 pin-on-fix
// one-shot correction) racing each other and the user across async boundaries.
// The killer interleaving: the MYR-216 correction wrote
// `span: context.region.span` — the span of WHATEVER SETTLE TRIGGERED IT. On
// the real entry path (idle → search → Continue → pinDrop) the map arrives
// with pre-entry motion still in flight, so the first `.onEnd` settle after
// entry carries the WIDE idle/search span; the correction fired on it,
// interrupted the in-flight street-span entry animation, and re-asserted the
// stale span while seating the fix under the glyph — pin on the dot, label
// right, city-scale zoom (the client's 7:41 AM evidence). Cold probe launches
// have no pre-entry motion, which is why four rounds of probes passed while
// the client kept regressing.
//
// THE FIX: while the pin-drop phase is up, this controller is the ONLY thing
// allowed to write the camera. Every write it emits carries the street span
// (`MRTMetrics.pinDropStreetSpanDelta`) — a span can NEVER be inherited from a
// settle context again, so no interleaving can produce a wide entry. All other
// programmatic writers are subordinated (see `VehicleMapView
// .cameraWritePermitted`); the user's own zoom/pan wins the moment a settle
// arrives outside the controller's write window (`.userControlled` — the owner
// then never writes again for that entry).
//
// It is a small explicit state machine, pure enough to unit-test the REAL
// entry interleaving (stale wide settles, async fix updates, user gestures)
// without mounting a map — see `PinDropCameraOwnershipTests`.
//
//   inactive ──enter()──▶ seating ──aligned settle──▶ settled
//                            │  ▲                        │
//                            │  └─fixChanged (re-seat)───┘
//                            └──late settle / user pan──▶ userControlled
//
// Seating strategy (replaces the MYR-216 layered one-shot): the entry write is
// an ANALYTIC first guess — the region whose center puts the fix under the
// glyph at the street span (aspect-aware; the glyph sits above the map's
// optical center by `ridePinDropGlyphScreenFraction`). Each programmatic
// settle is then VERIFIED against MapKit's ground truth (`MapProxy.convert` of
// the glyph's real rendered point, reported by `VehicleMapView`): if the glyph
// coordinate is off the fix, the controller emits ONE bounded refinement
// (street span, never the settle's span), up to `refinementBudget` times, then
// accepts. MapProxy remains the authoritative source of the CONFIRMED pickup
// coordinate — seating is a courtesy (open on the rider), never a correctness
// requirement.
@MainActor
@Observable
final class PinDropCameraController {

    // MARK: State machine

    enum Phase: Equatable {
        /// Not in pin-drop — the controller owns nothing.
        case inactive
        /// Entry/re-seat write issued; verifying the glyph lands on the fix.
        case seating
        /// Framing verified (or accepted) — reporting-only from here.
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
        /// Settle outside the owner's write window — the user panned/zoomed.
        /// Report the coordinate; the owner stands down for this entry.
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
    /// Rolling write window: settles landing within it are attributed to the
    /// owner's own writes; later ones are the user's (same tolerance the
    /// legacy follow logic used — 0.8s animation + `.onEnd` delivery slack).
    let writeWindow: TimeInterval
    /// Glyph-on-fix tolerance (degrees) — ~2m latitude, matches MYR-216.
    let alignmentEpsilonDegrees: Double

    /// Verified refinements allowed per seating pass. Three covers the worst
    /// case: a couple of queued stale wide settles re-issuing the analytic
    /// target, then one exact delta-shift at street geometry.
    private static let refinementBudgetPerSeat = 3

    /// A settle whose latitude span is within this factor of the street span
    /// is at STREET-SCALE geometry (our own write — insets/aspect stretch the
    /// visible span up to ~2.6× the requested one on a portrait phone with the
    /// pin-drop sheet inset, empirically ~0.010° for the 0.004° request), so
    /// the observed (fix − glyph) residual delta-shifts exactly. Anything
    /// wider is a stale pre-entry settle (idle/search span is 15×) — its
    /// deltas are measured at the wrong zoom and are NOT trusted; the analytic
    /// street target is re-issued instead. Deliberately NOT derived from the
    /// analytic visible-span estimate: the estimate can't model MapKit's
    /// inset-fitting exactly, and mis-classifying our own settle as "wide"
    /// loops the analytic target without ever converging (found empirically
    /// in the MYR-217 real-path probe).
    static let streetScaleFactor: Double = 4

    // MARK: Per-entry state

    private var entryFix: CLLocationCoordinate2D?
    private var fallbackCenter = CLLocationCoordinate2D()
    private var viewportSize = CGSize.zero
    private var refinementBudget = 0
    private var writeWindowUntil = Date.distantPast

    init(
        streetSpanDelta: Double = MRTMetrics.pinDropStreetSpanDelta,
        glyphScreenFraction: Double = Double(MRTMetrics.ridePinDropGlyphScreenFraction),
        writeWindow: TimeInterval = 1.2,
        alignmentEpsilonDegrees: Double = 0.00002
    ) {
        self.streetSpanDelta = streetSpanDelta
        self.glyphScreenFraction = glyphScreenFraction
        self.writeWindow = writeWindow
        self.alignmentEpsilonDegrees = alignmentEpsilonDegrees
    }

    // MARK: Events

    /// Pin-drop entered (warm `.onChange` transition or cold `onAppear` mount —
    /// ONE shared path, closing the MYR-215 cold-vs-warm split). Returns the
    /// entry write: street span, fix under the glyph (analytic first guess),
    /// or the fallback center when there is no fix (sim / unauthorized).
    func enter(
        fix: CLLocationCoordinate2D?,
        fallbackCenter: CLLocationCoordinate2D,
        viewportSize: CGSize,
        animated: Bool,
        now: Date = Date()
    ) -> Write {
        entryFix = fix
        self.fallbackCenter = fallbackCenter
        self.viewportSize = viewportSize
        refinementBudget = Self.refinementBudgetPerSeat
        phase = .seating
        writeWindowUntil = now.addingTimeInterval(writeWindow)
        return Write(region: analyticRegion(), animated: animated)
    }

    /// Pin-drop exited — the owner releases the camera.
    func exit() {
        phase = .inactive
        entryFix = nil
    }

    /// A fresh device fix arrived during pin-drop (`enterPinDrop()`'s
    /// `refresh()`, or the device moved). Re-seat on it ONLY while the owner
    /// still holds the camera — a user who has taken over is never fought.
    func fixChanged(_ fix: CLLocationCoordinate2D, now: Date = Date()) -> Write? {
        switch phase {
        case .inactive, .userControlled:
            return nil
        case .seating, .settled:
            entryFix = fix
            refinementBudget = Self.refinementBudgetPerSeat
            phase = .seating
            writeWindowUntil = now.addingTimeInterval(writeWindow)
            return Write(region: analyticRegion(), animated: true)
        }
    }

    /// A camera settle during pin-drop. `glyphCoordinate` is MapKit's ground
    /// truth for the glyph's rendered point (`MapProxy.convert`);
    /// `cameraCenter`/`cameraLatitudeDelta` are the settle context's region.
    /// NOTE the settle context's span is used ONLY to pick a refinement
    /// strategy — it never flows into a write (the MYR-216 bug).
    func cameraSettled(
        glyphCoordinate: CLLocationCoordinate2D,
        cameraCenter: CLLocationCoordinate2D,
        cameraLatitudeDelta: Double,
        now: Date = Date()
    ) -> SettleOutcome {
        switch phase {
        case .inactive:
            return .report
        case .userControlled:
            return .report
        case .settled:
            if now > writeWindowUntil {
                phase = .userControlled
                return .userTookOver
            }
            return .report
        case .seating:
            guard now <= writeWindowUntil else {
                // A settle the owner didn't cause — the user moved the map.
                phase = .userControlled
                return .userTookOver
            }
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
            writeWindowUntil = now.addingTimeInterval(writeWindow)
            let region: MKCoordinateRegion
            if cameraLatitudeDelta < streetSpanDelta * Self.streetScaleFactor {
                // Geometry is already street-scale: shift the center by the
                // observed (fix − glyph) residual. Exact for a fixed geometry
                // (the write requests the same street span the camera already
                // has, so the projection doesn't change under the shift).
                region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: cameraCenter.latitude + (fix.latitude - glyphCoordinate.latitude),
                        longitude: cameraCenter.longitude + (fix.longitude - glyphCoordinate.longitude)
                    ),
                    span: streetSpan // NEVER the settle's span
                )
            } else {
                // A stale settle from pre-entry (wide) geometry hijacked the
                // pass — re-issue the analytic street-span target instead of
                // trusting deltas measured at the wrong zoom. THIS branch is
                // the structural fix for the four-round recurrence.
                region = analyticRegion()
            }
            return .refine(Write(region: region, animated: true))
        }
    }

    // MARK: Geometry (pure, unit-tested)

    private var streetSpan: MKCoordinateSpan {
        MKCoordinateSpan(latitudeDelta: streetSpanDelta, longitudeDelta: streetSpanDelta)
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
