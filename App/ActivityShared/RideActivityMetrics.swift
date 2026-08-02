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
    // Two sizes per glyph, because the two bare surfaces carry two different rings
    // (22 compact, 24 expanded) and the glyph has to read at the weight of the thing
    // it replaces. Both pairs sit inside the mirror's stated ranges — wave 17-19,
    // check 15-19 — and the CHECK is the smaller of each pair on purpose: it is a
    // filled disc where the wave is an open hand, so it carries more ink per point.
    //
    // `ringGlyph` (13) survives and is NOT one of these: it is the glyph INSIDE the
    // ring, which only the MINIMAL island still draws.
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

    // MARK: - MYR-412 · THE COMPACT TRAILING SLOT IS INSET, AND WHY IT HAD TO BE
    //
    // ─────────────────────────────────────────────────────────────────────────────
    // **`Circle().stroke` OVERFLOWS ITS FRAME BY HALF THE LINE WIDTH, AND THE COMPACT
    // TRAILING REGION CLIPS TO THE CONTENT'S DECLARED BOUNDS — SO THE RING WAS BEING
    // SHAVED FLAT ON BOTH SIDES.** Measured on the shipped build (iPhone 17 Pro
    // simulator, iOS 26.5, `arrived` / `completed` / `noTelemetry`): the ring's ink is
    // **23.00pt wide and 24.00-24.67pt tall** where an unclipped 22pt ring drawn with
    // a 2.2pt centred stroke measures **24.2pt in both axes**. The vertical figure is
    // the honest one; the horizontal is 22pt plus antialiasing, i.e. exactly the
    // declared frame. The region clips on the horizontal axis and not the vertical,
    // which is why the client's frame reads as the element being *cut off on its
    // leading edge* rather than as a smaller ring.
    //
    // **THE SLOT HAS ROOM AND ALWAYS DID** — so the inset costs nothing, which had to
    // be established BEFORE choosing one: on a surface that clips, padding is exactly
    // the change that can make the symptom worse. Probed by rendering rulers of known
    // width in this very region and measuring what survived: **34pt renders whole**
    // (pill grows to 191.0pt, both end markers visible) and **46pt renders whole**
    // (pill 212.0pt). The shipping `3:42 PM` figure measures **65.3pt** of ink and
    // renders whole (pill 251.7pt), so the ceiling is not a plain width limit. One
    // probe DID get cut — 57pt of stripes carrying their own fixed
    // `.frame(width: 57)`, which came back showing only the leading 6.7pt in a pill
    // that grew to 180.3pt. A fixed frame on the slot's content is the difference
    // between that probe and every other measurement here, and nothing this file
    // renders sets one.
    //
    // A 22pt ring plus its stroke plus 4pt each side is 32.2pt, inside the narrowest
    // width proved to render whole.
    //
    // **THE FIGURE IS DELIBERATELY NOT INSET.** §0 D's promise is that the ETA figures
    // are byte-identical to the pre-§0 build, and padding them would move them.
    // Nothing about a `Text` overflows its own bounds, so it never needed this.
    // ─────────────────────────────────────────────────────────────────────────────

    /// The clear space the compact trailing GLYPH-OR-RING carries on each side.
    ///
    /// It must exceed the ring's own stroke overhang (`ringStrokeCompact / 2` = 1.1)
    /// or the shave comes straight back; the rest is the clear space the client asked
    /// for, so the element never sits flush against the boundary the system clips at.
    static let compactTrailingInset: CGFloat = 4
    /// The narrowest RULER measured to render whole in this slot (see the block
    /// above). Deliberately the narrowest of the three measurements rather than the
    /// widest: it is the conservative bound, it is not a system constant, and it is
    /// not a promise about any device but the one it was measured on. The inset
    /// arithmetic is checked against it.
    static let compactTrailingMeasuredBudget: CGFloat = 34

    /// How far a centred stroke of `stroke` reaches OUTSIDE the shape it is drawn on.
    /// `Circle().stroke(lineWidth:)` centres the line on the path, so a ring in a
    /// `frame(width: d)` draws to `d + stroke` and the last `stroke / 2` on each side
    /// lands outside the bounds any host is entitled to clip to.
    static func strokeOverhang(_ stroke: CGFloat) -> CGFloat { stroke / 2 }

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
    /// The waiting arc's length, for the "route known, no telemetry yet" state — the
    /// board's LOADING RING, and **what now ships** (MYR-412).
    ///
    /// §0 B asked for this arc turning on a 1.4s loop. It does not turn: the platform
    /// runs no repeating animation here and no appearance-armed one either, and
    /// MYR-412 measured that SF Symbol effects are no exception (see
    /// `RideActivityRingArc`). §0 B's first implementation answered that by drawing
    /// the waiting ring DASHED, reasoning that a static quarter arc is
    /// pixel-for-pixel `ringDeterminate(0.25)` and therefore a wrong NUMBER on the one
    /// state that means the car has reported nothing.
    ///
    /// **THE CLIENT OVERRULED THAT WITH THE BOARD IN HAND** — *"it should just be a
    /// loading icon bc no data from telemetry was found"*, over a mock that draws a
    /// solid track and a partial gold arc. Client outranks the deduction, and the
    /// ambiguity it was avoiding is bounded: the card beside the island draws the
    /// IDLE rail in this state, and a determinate ring is never at rest on exactly a
    /// quarter for long. 0.25 is the handoff's own number and sits inside the board's
    /// stated 25-35%.
    static let ringIndeterminateArc: Double = 0.25
    /// **THE WAITING RING'S ROLLING WINDOW — MYR-417, AND THE RING MOVES NOW.**
    ///
    /// ─────────────────────────────────────────────────────────────────────────────
    /// §0 B measured that ActivityKit runs no repeating animation and MYR-412 measured
    /// that it runs no SF Symbol effect either, and both concluded the platform simply
    /// does not animate this surface. **Both measurements were right and the
    /// conclusion was too narrow.** ActivityKit renders a Live Activity's view out of
    /// process, so nothing the app ANIMATES is run — but the system's own
    /// timer-driven elements are not animations, they are values the renderer
    /// re-derives from a date range it was handed. `Text(timerInterval:)` has always
    /// been one. `ProgressView(timerInterval:countsDown:)` is the other, and its
    /// CIRCULAR style is a ring.
    ///
    /// So the waiting ring is a real `ProgressView(timerInterval:)` over
    /// `now ... now + window`, restarted every time a content state composes a frame.
    /// The arc creeps, which is the difference between "we are waiting on the car"
    /// and "this app has stopped" that §0 B asked for and could not get.
    ///
    /// **90 SECONDS IS THE PUSH CADENCE'S OWN CEILING** (§7.21's ETA ticker pushes
    /// every 60–90s), so on a healthy ride the window is restarted at or before it
    /// completes and the arc reads as a loop rather than as a fill that finished. It
    /// is not tuned tighter than that on purpose: a shorter window spends more of its
    /// life sitting full, and a much longer one creeps too slowly to read as motion at
    /// a glance.
    ///
    /// ⚠️ **THE ONE THING IT CANNOT SAY IS HOW LONG.** A ride whose pushes stop
    /// entirely leaves the arc parked at full, which is the same picture a determinate
    /// ring at `p = 1` draws. That ambiguity is bounded and is named rather than
    /// hidden: the CARD beside the island draws the IDLE rail in this state, and the
    /// waiting ring's track is the system's tint-derived one rather than the
    /// determinate ring's white 20%, so the two are not pixel-identical even at the
    /// same fraction.
    /// ─────────────────────────────────────────────────────────────────────────────
    static let waitingWindow: TimeInterval = 90

    /// One full turn, for the STATIC fallback's arc. Kept as the design's own number
    /// — the Reduce Motion rendering does not turn and never did, and neither did the
    /// motion-on one before MYR-417 found a mechanism the platform runs.
    static let ringSpin: TimeInterval = 1.4

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
    /// **THE SAME BEAT ON A SURFACE WITH NO RING TO COMPLETE** (MYR-412). The compact
    /// and expanded trailing slots draw the glyph BARE, so there is no arc to sweep to
    /// full first — the ring simply gives way. The glyph still follows it by the
    /// beat's own 0.1s, so the interval between "the ring leaves" and "the glyph
    /// lands" is identical on all three surfaces; only the completion sweep, which is
    /// meaningful solely where the glyph ends up INSIDE the ring, is absent.
    ///
    /// Derived rather than typed, so a change to the beat cannot move one surface and
    /// leave the other behind.
    static let bareArrivalGlyphDelay: TimeInterval = arrivalGlyphDelay - arrivalRingFadeDelay
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
