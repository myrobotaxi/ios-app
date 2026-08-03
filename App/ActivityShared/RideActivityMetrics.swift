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

    // Compact Dynamic Island — a figure, a glyph, or (MYR-420) nothing.
    static let compactArrow: CGFloat = 16
    static let compactFigureSize: CGFloat = 15

    // MARK: - MYR-412 · THE BARE ARRIVAL GLYPHS
    //
    // ─────────────────────────────────────────────────────────────────────────────
    // **THE GLYPH STANDS ALONE. THERE IS NO CIRCLE AROUND IT.** §0 B put the wave and
    // the check in the RING's centre, reading the handoff's "centre — the east arrow,
    // swapped for the arrival glyph at 13pt" as applying to every surface. The
    // client's board says otherwise and he sent it to prove it: on the compact
    // trailing slot the wave and the check are BARE white marks, and the ring appears
    // there only when there is no glyph and no figure. His words: *"why is there a
    // circle around the hand thats not needed"*.
    //
    // Two sizes per glyph, because the two bare surfaces carried two different rings
    // (22 compact, 24 expanded) and the glyph has to read at the weight of the thing
    // it replaces. Both pairs sit inside the mirror's stated ranges — wave 17-19,
    // check 15-19 — and the CHECK is the smaller of each pair on purpose: it is a
    // filled disc where the wave is an open hand, so it carries more ink per point.
    //
    // **MYR-420 DELETED THE RINGS AND KEPT THESE FOUR NUMBERS EXACTLY.** The glyph
    // states are the half of this surface the client did NOT change, so they are
    // byte-identical to the shipped build — a glyph re-sized "now that it has more
    // room" would be this issue quietly redesigning the states it was told to leave
    // alone. `minimalGlyph` (13) is the one that is not one of these: see the minimal
    // island's own block at the foot of this file.
    // ─────────────────────────────────────────────────────────────────────────────

    /// `hand.wave.fill`, bare, in the compact trailing slot.
    static let compactWaveGlyph: CGFloat = 17
    /// `checkmark.circle.fill`, bare, in the compact trailing slot.
    static let compactCheckGlyph: CGFloat = 15
    /// The same two on the EXPANDED island's `.trailing`, which carries the larger
    /// ring and therefore the larger glyph. 19 is the board's own compact number
    /// (§5), which is the right weight one surface up.
    static let expandedWaveGlyph: CGFloat = 19
    static let expandedCheckGlyph: CGFloat = 17

    // MARK: - THE COMPACT TRAILING SLOT IS INSET — MYR-412's FIX, MYR-420's REASON
    //
    // ─────────────────────────────────────────────────────────────────────────────
    // **THE INSET SURVIVES THE RING, AND ITS JUSTIFICATION CHANGED WITH IT.**
    //
    // MYR-412 introduced it as a CLIPPING FIX. `Circle().stroke` centres the line on
    // the path, so a 22pt ring in a 22pt frame drew to 24.2pt, and the compact
    // trailing region — which clips on the HORIZONTAL axis and not the vertical —
    // shaved the outer 1.1pt off each side: the ring's ink measured **23.00pt wide
    // against 24.00-24.67pt tall**, which is the client's *"cut off on the leading
    // edge"*. **That reason is gone with the ring** (MYR-420): an SF Symbol draws
    // INSIDE its own bounds, so nothing this slot renders overflows the frame the
    // region clips to, and the stroke-overhang arithmetic has no subject left.
    //
    // **IT STAYS BECAUSE IT IS ALSO THE GLYPH'S CLEAR SPACE, AND BECAUSE REMOVING IT
    // WOULD MOVE THE GLYPH.** The wave and the check are the states MYR-420 did not
    // change; they clear the pill's edge by 9.2-9.4pt as shipped, and 4pt of that is
    // this inset. Dropping it would shift both marks 4pt outward toward the boundary
    // the system clips at — a visible change to two states nobody asked to change, in
    // the name of tidying up a constant. **An inset serving the glyph stays; the one
    // serving only the ring was the arithmetic, and that is what went** (see
    // `strokeOverhang`, deleted).
    //
    // **THE SLOT HAS ROOM AND THAT WAS MEASURED** — rulers of known width rendered in
    // this very region came back whole at **34pt** (pill 191.0) and **46pt** (pill
    // 212.0), and the shipping `3:42 PM` figure measures 65.3pt of ink and renders
    // whole (pill 251.7). The widest thing the slot can now hold is a 17pt glyph plus
    // 8pt of inset.
    //
    // **THE FIGURE IS DELIBERATELY NOT INSET.** §0 D's promise is that the ETA figures
    // are byte-identical to the pre-§0 build, and padding them would move them.
    // ─────────────────────────────────────────────────────────────────────────────

    /// The clear space the compact trailing GLYPH carries on each side, unchanged
    /// from the build MYR-412 measured it into — so the two glyph states are
    /// pixel-identical across MYR-420.
    static let compactTrailingInset: CGFloat = 4
    /// The narrowest RULER measured to render whole in this slot (see the block
    /// above). Deliberately the narrowest of the three measurements rather than the
    /// widest: it is the conservative bound, it is not a system constant, and it is
    /// not a promise about any device but the one it was measured on. The inset
    /// arithmetic is checked against it.
    static let compactTrailingMeasuredBudget: CGFloat = 34

    // MARK: - §0 B's PROGRESS RING — DELETED BY MYR-420
    //
    // ─────────────────────────────────────────────────────────────────────────────
    // **EVERY RING CONSTANT IS GONE, AND THIS BLOCK IS THE RECEIPT.** `ringDiameter`
    // 24 / `ringDiameterCompact` 22 / `ringStroke` 2.4 / `ringStrokeCompact` 2.2 /
    // `ringArrow` 12 / `ringGlyph` 13 / `ringMinimumArc` 0.02 /
    // `ringIndeterminateArc` 0.25 / `waitingWindow` 90 / `ringSpin` 1.4 /
    // `strokeOverhang(_:)` — all deleted with the component that read them, along with
    // the `arrivalRing*` half of the §0 C beat (`arrivalRingCompletion`,
    // `arrivalRingFadeDelay`, `arrivalRingFade`, `arrivalRingSettledOpacity`), which
    // timed an arc completing and fading under a glyph that no longer lands inside
    // one.
    //
    // The client removed the ring outright rather than choosing between MYR-417's
    // fill and MYR-412's static arc: *"remove the ring entirely then and if theres
    // data it appears on the right side."* **WHY THERE IS NO SPINNER, AND NOW NO RING
    // EITHER, IS RECORDED IN `design/Handoff-Live-Activity.md`'s MYR-420 mirror
    // note** — including the ceiling that made the ask impossible (a self-updating
    // element on this surface is a RAMP OVER A DATE RANGE, and a ramp cannot repeat).
    // It is kept there rather than here because the measurement outlives the
    // constants: the next person to be asked for motion on this surface needs it, and
    // there is no longer a file of ours for it to live beside.
    // ─────────────────────────────────────────────────────────────────────────────

    // MARK: - §0 C · the arrival beat
    //
    // Plays ONCE, on the transition into `arrived` / `completed`, then static — the
    // state lingers minutes (five, for `completed`: MYR-405) and a glyph that
    // pulsed throughout would be motion about nothing.
    //
    // **MYR-420 LEFT THE BEAT'S SHAPE EXACTLY WHERE MYR-412 PUT IT.** That issue had
    // already reduced the two trailing slots to "what was there gives way, the glyph
    // lands 0.1s later" — there was no arc to sweep on a bare surface — and the only
    // change here is that the MINIMAL island joins them, because its ring is gone too.
    // The three surfaces now run one beat with one delay, which is what
    // `bareArrivalGlyphDelay` was named for and is why the "bare" qualifier has been
    // dropped: nothing is left for it to contrast with.

    /// The interval between the slot's previous content giving way and the glyph
    /// landing. MYR-412's `bareArrivalGlyphDelay`, renamed now that every surface
    /// takes it — the VALUE is unchanged, so the arrival states animate exactly as
    /// they shipped.
    static let arrivalGlyphDelay: TimeInterval = 0.1
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
    /// The tallest thing the `.trailing` region can now hold. It was the 24pt RING;
    /// with the ring deleted (MYR-420) the widest resolution left is the bare wave,
    /// and the row this is measured against is unchanged.
    static let expandedTrailingSlot: CGFloat = expandedWaveGlyph
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
    // ─────────────────────────────────────────────────────────────────────────────
    // §5 drew this surface as "Minimal 37×37 · ring d24 stroke 2.4 · center arrow 12
    // / glyph 13", and §0 B built exactly that: the mark inside the ring. **MYR-420
    // removes the ring here as well** — the client's ruling is about the element, not
    // about one surface, and a ring kept on the one surface nothing in this repo can
    // photograph would be the least reviewable place to leave it.
    //
    // What remains is the CENTRE, alone: the brand mark, swapped for the arrival
    // glyph at the two stops on the same beat the trailing slots run. Both numbers
    // are §5's own (12 and 13) and are unchanged — they were sized to sit inside a
    // 19.2pt hole and are now simply what the surface holds. **The glyph is a point
    // larger than the arrow** because an SF Symbol's optical size sits inside its
    // bounding box in a way the mark's polygons do not.
    // ─────────────────────────────────────────────────────────────────────────────

    /// §5's 37×37 — **THE SYSTEM'S CIRCLE, NOT OURS TO SET.** Nothing applies this;
    /// it is the design's stated size for the surface, kept so the two marks below
    /// can be MEASURED against the space they now stand in alone (the
    /// `expandedTopRowHeight` pattern).
    static let minimalCircle: CGFloat = 37
    /// The east arrow — what minimal renders whenever the slot is EMPTY, which after
    /// MYR-420 is every state but the two arrivals.
    static let minimalArrow: CGFloat = 12
    /// The arrival glyph that replaces it. §5's `glyph 13`, kept at the centre size
    /// rather than raised to the bare trailing sizes (17/19): the minimal circle is
    /// 37pt against the compact pill's own band, and this mark has never been the
    /// slot-filling one.
    static let minimalGlyph: CGFloat = 13
}
