import CoreGraphics
import Foundation

// MARK: - The v3 board's geometry (MYR-398)
//
// Lives in `App/ActivityShared` — compiled into BOTH the widget (which lays out
// with it) and the app's test bundle (which MEASURES against it). v2 kept these
// numbers beside the views, where nothing could assert on them; the v3 card's whole
// promise is a FIXED footprint and four FIXED rows, and a promise about geometry
// that no test can read is a promise about a comment.

// MARK: - Geometry
//
// `la-kit.jsx`'s numbers, in one place so a capture can be MEASURED against the
// design rather than eyeballed against it. Every value here is quoted in the
// handoff's §5 geometry block.
enum RideActivityMetrics {
    // Card — fixed, every state.
    static let cardWidth: CGFloat = 350
    static let cardHeight: CGFloat = 128
    static let cardRadius: CGFloat = 22
    static let cardPaddingTop: CGFloat = 12
    static let cardPaddingHorizontal: CGFloat = 15
    static let cardPaddingBottom: CGFloat = 13

    // The four fixed row heights. NOTHING a state does may change one of these —
    // that is the whole of "every state, same footprint".
    static let wordmarkRowHeight: CGFloat = 20
    static let headlineRowHeight: CGFloat = 24
    static let sublineRowHeight: CGFloat = 17
    static let railRowHeight: CGFloat = 18

    static let cardBrandRowGap: CGFloat = 8
    static let cardTileSize: CGFloat = 20
    static let wordmarkSize: CGFloat = 10
    static let wordmarkTracking: CGFloat = 0.9

    // Headline — 20/600, tracking −0.45. `in` / the unit / `dropoff` are 500 @62%.
    static let headlineSize: CGFloat = 20
    static let headlineGap: CGFloat = 5
    static let headlineTracking: CGFloat = -0.45

    // Subline — 13.5/400 @58%, tracking −0.1, one line, tail ellipsis.
    static let sublineSize: CGFloat = 13.5
    static let sublineTracking: CGFloat = -0.1

    // Rail — track 5 (r 2.5) · dest pin 11 (2px ring) · arrow 14 in a 22pt puck.
    static let railHeight: CGFloat = 5
    static let railPuck: CGFloat = 22
    static let railPuckRing: CGFloat = 2
    static let railArrow: CGFloat = 14
    static let railPin: CGFloat = 11
    static let railPinRing: CGFloat = 2
    /// The puck's opacity on the IDLE variant. Not "dimmed to signal a problem" —
    /// half-strength is what an UNTRAVELLED route looks like.
    static let railIdlePuckOpacity: Double = 0.5
    /// `transition: .5s cubic-bezier(.2,.8,.2,1)` — la-kit's own rail curve.
    static let railTravel: TimeInterval = 0.5

    // Compact Dynamic Island — a figure, a glyph, or (§0 B) the ring.
    static let compactArrow: CGFloat = 16
    static let compactFigureSize: CGFloat = 15
    static let compactWaveGlyph: CGFloat = 17
    static let compactCheckGlyph: CGFloat = 15

    // MARK: - §0 B · the progress ring
    //
    // ONE component, two sizes. 24 on the minimal island and in the expanded
    // island's `.trailing` slot; 22 in the compact trailing half-pill, where the
    // pill is shorter than the island is tall. The stroke follows the diameter
    // (2.4 / 2.2) so the two read as the same ring at two scales rather than as two
    // rings.
    static let ringDiameter: CGFloat = 24
    static let ringDiameterCompact: CGFloat = 22
    static let ringStroke: CGFloat = 2.4
    static let ringStrokeCompact: CGFloat = 2.2
    /// The east arrow in the ring's centre.
    static let ringArrow: CGFloat = 12
    /// A glyph in the ring's centre, where one replaces the arrow. A point larger
    /// than the arrow because an SF Symbol's optical size sits inside its bounding
    /// box in a way the mark's polygons do not.
    static let ringGlyph: CGFloat = 13

    /// **THE ARC'S FLOOR.** A round cap on a zero-length arc draws nothing, so a
    /// determinate ring at `p = 0` would be indistinguishable from the track-only
    /// state — which is a different claim entirely. 2% is one visible cap.
    static let ringMinimumArc: Double = 0.02
    /// The rotating arc's length, for the "route known, no telemetry yet" state.
    ///
    /// ⚠️ **KEPT AS THE HANDOFF'S NUMBER, AND NOT WHAT SHIPS** — see
    /// `RideActivityRingArc`. ActivityKit runs neither repeating nor
    /// appearance-armed animations (measured: six frames 0.3s apart, byte-identical),
    /// and a STATIC quarter arc is pixel-for-pixel `ringDeterminate(0.25)` — a wrong
    /// number on the one state that means "nothing has been reported". The waiting
    /// ring is drawn DASHED instead.
    static let ringIndeterminateArc: Double = 0.25
    /// One full turn. Linear and `repeatForever` — a view-local animation that costs
    /// NO push budget, which is the whole point of it, and which the platform
    /// currently ignores.
    static let ringSpin: TimeInterval = 1.4
    /// The waiting ring's dashes. A count rather than a length, so the period divides
    /// the circumference exactly and the seam lands at 12 o'clock at BOTH diameters.
    static let ringWaitingDashCount: CGFloat = 10
    /// How much of each period is ink. A third reads as "unsettled" without thinning
    /// the ring into a dotted line.
    static let ringWaitingDashDuty: CGFloat = 0.34

    // MARK: - §0 C · the arrival beat
    //
    // Plays ONCE, on the transition into `arrived` / `completed`, then static — the
    // state lingers minutes (five, for `completed`: MYR-405) and a glyph that
    // pulsed throughout would be motion about nothing.

    /// The ring completing to 100%, on the rail's own curve.
    static let arrivalRingCompletion: TimeInterval = railTravel
    /// What the ring settles to once the glyph is in it. The ring is still the
    /// truth — the leg IS finished — it just stops being the subject.
    static let arrivalRingSettledOpacity: Double = 0.4
    /// The fade, which starts once the arc has landed.
    static let arrivalRingFadeDelay: TimeInterval = arrivalRingCompletion
    static let arrivalRingFade: TimeInterval = 0.5
    /// The glyph springs in a beat after the fade begins — the handoff's "then fades
    /// … while the glyph scales in … on a 0.1s delay", read as 0.1s after the fade
    /// rather than 0.1s after the beat began (the two readings differ by exactly the
    /// completion, and only this one leaves the ring's sweep visible underneath).
    static let arrivalGlyphDelay: TimeInterval = arrivalRingFadeDelay + 0.1
    static let arrivalGlyphFromScale: Double = 0.6
    static let arrivalSpringResponse: Double = 0.34
    static let arrivalSpringDamping: Double = 0.72

    // MARK: - Expanded island (§0 A — the region rebuild)
    //
    // r 38 · padding 10/20/15 · gap 10 · TOP ROW 34 · logo 26 · headline 19/600.
    //
    // **THE BOX IS THE SYSTEM'S AND SO IS THE TOP ROW.** Nothing here may set an
    // island's width, its height or its corner radius, and after §0 A nothing may
    // set a height ANYWHERE in the expanded builder: the whole defect was wide
    // content in a row the sensor housing splits, padded out to a tall black box.
    // `expandedTopRowHeight` is therefore the design's TARGET for the row the two
    // small regions produce, measured against rather than applied
    // (`RideActivityGeometryTests`).
    static let expandedGap: CGFloat = 10
    static let expandedHeaderGap: CGFloat = 11
    static let expandedTopRowHeight: CGFloat = 34
    static let expandedLogo: CGFloat = 26
    static let expandedTrailingSlot: CGFloat = ringDiameter
    static let expandedHeadlineSize: CGFloat = 19
    static let expandedSublineSize: CGFloat = 12.5
    /// TWO on this surface, one on the card. The island's height follows its
    /// content, so a long "Heading to {place}" says the place instead of ellipsizing
    /// it — and the second line is what makes the height difference between a
    /// two-line and a three-line state visible, which is §0 A's own acceptance test
    /// for "nothing is pinned".
    static let expandedSublineLineLimit = 2
    /// The gap between the headline and the subline in the `.bottom` region — 2, not
    /// the card's zero, because nothing here is on a fixed row grid any more.
    static let expandedBlockSpacing: CGFloat = 2
    /// The rail's own separation from the two lines above it.
    static let expandedRailTopGap: CGFloat = 8
    static let expandedPaddingTop: CGFloat = 10
    static let expandedPaddingHorizontal: CGFloat = 20
    static let expandedPaddingBottom: CGFloat = 15

    // MARK: - §0 A · the CORNER-SAFE insets (client feedback on the region rebuild)
    //
    // ─────────────────────────────────────────────────────────────────────────────
    // **THE PILL IS A SQUIRCLE AND ITS CORNERS EAT THE FIRST TEN POINTS OF EVERY
    // EDGE.** Measured off a real expanded frame (iPhone 17 Pro, iOS 26.5): the
    // island's horizontal inset is 18.7pt 10pt down from the top edge, 10.3pt at
    // 18pt down, and only reaches ~1pt at 42pt down. So a 26pt mark or a 24pt ring
    // parked at the region's own leading/trailing edge sits against a boundary that
    // is still curving hard, and on the client's device it crosses it — his report:
    // the mark and the ring intersect the corner curvature, and the rail's origin
    // puck and end cap run into the bottom two.
    //
    // **THESE ARE INSETS, NOT A SMALLER LAYOUT.** Nothing here sets a width, a
    // height or a frame — §0 A's rule is unchanged and is what keeps the island's
    // height content-driven. Each value is added as PADDING at exactly one call
    // site, and only to the element that meets a corner:
    //
    //   • the top row's two regions move in and down (the mark and the ring);
    //   • the RAIL's two ends move in (the puck at `p = 0` and the cap at `p = 1`
    //     are the widest things in the bottom row and the only ones that reach a
    //     bottom corner);
    //   • the HEADLINE AND SUBLINE ARE NOT TOUCHED. They sit in the middle band
    //     where the pill's edge is straight, they are the column the eye reads down,
    //     and moving them would be re-laying out the surface to fix two corners.
    //
    // The mark and the rail therefore no longer align with the headline's gutter,
    // by design and by the client's own instruction: the two bands that touch the
    // curve pay for it, and the band that does not keeps the layout it had.
    //
    // ⚠️ **`.contentMargins` COMPILES HERE AND DOES NOTHING — MEASURED, NOT ASSUMED.**
    // The obvious alternative spelling is `.contentMargins(.leading, 6)`, and it
    // type-checks on any `View`. Built and captured both ways on the same simulator,
    // same three expanded states: the `.contentMargins` build is byte-identical to
    // the build with NO inset at all — the island returns to 137pt / 152pt and every
    // corner clearance returns to its pre-fix value, while `.padding` gives 141pt /
    // 156pt and clears every corner. Its default `.automatic` placement resolves to
    // scroll-view content margins, and a `DynamicIslandExpandedRegion` has none, so
    // the modifier is dropped silently. **A modifier that compiles, reads correctly
    // and is discarded is the quietest way to ship this fix un-shipped** — the same
    // shape as `VehicleRideShare.display`'s missing call site. `.padding` is the
    // only mechanism that reaches this surface.
    // ─────────────────────────────────────────────────────────────────────────────

    /// How far IN the top row's mark and ring move, per side. 6 buys the ring's cap
    /// ~7pt of extra clearance against the arc without moving the row's content far
    /// enough for the two small regions to stop reading as the row's two ends.
    static let expandedCornerSafeHorizontal: CGFloat = 6
    /// How far DOWN they move. The arc slackens fastest in the first 20pt, so 4pt of
    /// descent is worth about as much clearance as the 6pt sideways and costs the
    /// content-driven height exactly 4pt.
    static let expandedCornerSafeTop: CGFloat = 4
    /// How far in each END of the rail moves. It is the RAIL's own inset and not the
    /// bottom block's, because the headline and subline above it must not move —
    /// applied to the block it would shift the whole column to fix two corners.
    ///
    /// The puck is 22pt wide in a 26pt ground disc and rides `0 … W − 22`, so its
    /// leading edge at `p = 0` and its trailing edge at `p = 1` ARE the rail's ends:
    /// insetting the rail is insetting exactly the two things the client saw run
    /// into the bottom corners.
    static let expandedRailCornerSafeInset: CGFloat = 6

    // MARK: - Minimal island
    //
    // §5: "Minimal 37×37 · ring d24 stroke 2.4 · center arrow 12 / glyph 13". The
    // bare 17pt arrow v3 shipped is replaced BY the ring — the mark is still there,
    // in the middle of it.
    static let minimalArrow: CGFloat = ringArrow
}
