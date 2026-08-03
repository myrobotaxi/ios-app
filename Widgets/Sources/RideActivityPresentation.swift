import DesignSystem
import MyRobotaxiContracts
import SwiftUI
import WidgetKit

// MARK: - The rider's ride, as the lock screen and Dynamic Island see it
//
// r16 REDESIGN v3 (MYR-398, CLIENT-DIRECTED — the client re-designed this surface
// against the field report of the v2 build, with **Uber's ride Live Activity as the
// explicit structural and copy reference**: `design/Handoff-Live-Activity.md`,
// `design/la/la-data.jsx`, `design/la/la-kit.jsx`, all three mirrored into this repo
// by this PR and REPLACING the v2 mirrors).
//
// **The state machine, content-state decoding and push handling are unchanged.**
// What changed is what each state renders, and one lifecycle moment (the Activity
// now starts at REQUEST for an instant ride — `RideActivityStateMachine.startState`).
//
// ─────────────────────────────────────────────────────────────────────────────
// FOUR ROWS, ONE RAIL, FOUR SURFACES, ONE LAYOUT
//
//   1  wordmark   20pt   logo 20 + wordmark 10/500 uppercase @42%. NOTHING trails.
//   2  headline   24pt   20/600, ONE line: "Pickup in 8 min" · "3:42 PM dropoff"
//   3  subline    17pt   13.5/400 @58%, ONE line: the car, or the place
//   4  rail       18pt   ALWAYS drawn, ALWAYS gold when live
//
// `space-between` inside a **fixed 350 × 128 card**, in every single state. That
// footprint is the field report's fourth item ("all banners the same width and
// height") and it is why terminal states keep an idle rail instead of collapsing.
//
// `ActivityConfiguration` composes these and `DynamicIsland { }` reuses THE SAME
// views at different sizes. **Do not fork the layout per surface** — v1's expanded
// island had already drifted into a second composition that spelled the trip line
// differently from the card's, and the handoff forbids it by name.
// ─────────────────────────────────────────────────────────────────────────────
//
// WHAT WENT, AND IT IS MOST OF v2: the status CHIP and its 5pt tone dot, the five
// tones, the pulse, the stale notice row, the stale rail desaturation, the compact
// island's status words, and the second line's gold/62% split. One accent (gold),
// no status colours, no badges on any surface. Everything on the card is static
// except the rail interpolating on a real update.
//
// WHAT DECIDES WHAT: nothing in this file. `RideActivityCard.resolve` is the whole
// rule and is unit-tested against `la-data.jsx`'s own fourteen rows; these views lay
// out what it returns and never switch on `status`. That split is why any of this is
// assertable at all — a presentation that cannot be instantiated in a test cannot be
// the thing that decides.
//
// ─────────────────────────────────────────────────────────────────────────────
// **§0 — THE CLIENT'S CHANGE REQUEST AGAINST THE v3 BUILD IN TESTFLIGHT
// (`202608011331`).** Three items, all on the ISLAND; the lock-screen card is
// untouched by every one of them.
//
//   A. **The expanded island is rebuilt out of REGIONS** — see the §0 A block above
//      `RideActivityIslandExpandedLeading`. The tall black box was wide content in
//      the row the sensor housing splits.
//   B. **A progress ring** filled the slot that used to be empty — **and MYR-420 has
//      since deleted it entirely; see below.**
//   C. **The arrival glyphs get a completion beat** — once, on the transition, then
//      static.
//   D. The priority between them is `RideActivityTrailingSlot`, resolved in the pure
//      layer.
//
// **MYR-412 CORRECTED §0 B's COMPOSITION AGAINST THE CLIENT'S OWN BOARD** (build
// `202608011648`): the wave and the check stand ALONE on the two trailing slots, no
// ring around them, and the compact slot is inset. Both halves of that survive.
//
// **MYR-417 MADE THE WAITING RING MOVE** — the system's own
// `ProgressView(timerInterval:)`, the one mechanism on this surface the platform
// genuinely runs — **and CHANGED THE DISPATCH COPY**: `Ride requested from {car}`
// over the same vehicle descriptor the rest of the pickup leg carries. There is no
// matching in this product, so the board's Uber copy is deliberately not ported (see
// `RideActivityCopy.rideRequestedFrom`). The copy change stands; the ring does not.
//
// ─────────────────────────────────────────────────────────────────────────────
// **MYR-420 — THE RING IS REMOVED FROM ALL THREE ISLAND SURFACES** (CLIENT-DIRECTED,
// against build `202608020103`). He asked for a ring that SPINS rather than fills;
// measurement established that this surface can fill, drain or travel once per push
// interval and cannot spin at any rate a person reads as spinning (the verdict is in
// `design/Handoff-Live-Activity.md`'s MYR-420 mirror note). Offered the two real
// options — a ring that moves but reads as progress, or a correct one that is dead —
// he took neither: *"remove the ring entirely then and if theres data it appears on
// the right side."*
//
// So the trailing slot is **figure > arrival glyph > EMPTY** on every surface, the
// MINIMAL island is the bare mark again, and **the lock-screen card and the expanded
// island's RAIL are untouched** — the rail is where this surface says how far along a
// ride is, and it always was.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - The ground
//
// Two gradients, opaque, in a real `ZStack` — NOT a material (handoff §9). v1
// inherited the system's glass because that is what a Live Activity does when you
// do not give it a background: it was the default, not a choice. The card sits on
// the logo tile's own opaque brown-black now, which survives any wallpaper. The
// ISLAND stays true black — that one is the hardware.
struct RideActivityGround: View {
    var body: some View {
        ZStack {
            // linear-gradient(155deg, #1b1407 0%, #0d0b06 55%, #090806 100%)
            LinearGradient(
                stops: [
                    .init(color: .mrtActivityGroundTop, location: 0),
                    .init(color: .mrtActivityGroundMid, location: 0.55),
                    .init(color: .mrtActivityGroundBottom, location: 1),
                ],
                startPoint: HexLogo.tileGradientStart,
                endPoint: HexLogo.tileGradientEnd
            )
            // radial-gradient(120% 130% at 14% -20%, rgba(201,168,76,0.13), transparent 58%)
            EllipticalGradient(
                stops: [
                    .init(color: .mrtActivityGroundBloom, location: 0),
                    .init(color: .mrtActivityGroundBloom.opacity(0), location: 0.58),
                ],
                center: UnitPoint(x: 0.14, y: -0.20),
                startRadiusFraction: 0,
                endRadiusFraction: 1.2
            )
        }
    }
}

// MARK: - Row 1: the wordmark
//
/// Logo + wordmark, and **nothing trailing** — the board's own §2 rule, and the one
/// v2 broke by parking the status chip there.
struct RideActivityWordmarkRow: View {
    var tileSize: CGFloat = RideActivityMetrics.cardTileSize

    var body: some View {
        HStack(spacing: RideActivityMetrics.cardBrandRowGap) {
            HexLogo(size: tileSize)

            Wordmark(
                size: RideActivityMetrics.wordmarkSize,
                color: .mrtActivityTextQuiet,
                tracking: RideActivityMetrics.wordmarkTracking
            )
            .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(height: RideActivityMetrics.wordmarkRowHeight)
    }
}

// MARK: - Row 2: the headline

/// `Pickup in 8 min` · `3:42 PM dropoff` · a sentence. **One line, always.**
///
/// **NO CLOCK RUNS IN THIS PROCESS.** `Text(timerInterval:countsDown:)` renders
/// `mm:ss`, which the board removed; and the client's standing ruling
/// (2026-07-31 — *"We are pulling live data from Tesla ETA telemetry; counting down
/// is inaccurate"*) rules out a local `TimelineView` too, superseding the v3
/// handoff's own §9 note. Both figure forms arrive already composed on the card, so
/// this view is plain `Text` and re-derivation is not switched off — it is absent.
struct RideActivityHeadlineView: View {
    let headline: RideActivityHeadline
    var size: CGFloat = RideActivityMetrics.headlineSize

    /// The CARD's fixed 24pt row — and **`nil` on the expanded island**, where §0 A
    /// forbids a height anywhere in the builder. A fixed row is right on a surface
    /// whose whole promise is a fixed 350 × 128 footprint and wrong on one whose
    /// height the system derives from its content: pinning a row there is one of the
    /// two ways to get back the tall black box §0 A is about.
    var height: CGFloat? = RideActivityMetrics.headlineRowHeight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RideActivityMetrics.headlineGap) {
            switch headline {
            case .pickupCountdown(let figure):
                lead(RideActivityCopy.pickupPhase)
                soft(RideActivityCopy.countdownJoin)
                value(figure.value)
                soft(figure.unit)

            case .dropoffClock(let clock):
                value(clock)
                soft(RideActivityCopy.dropoffWord)

            case .sentence(let text):
                lead(text)
            }

            Spacer(minLength: 0)
        }
        // ONE LINE IN EVERY STATE. The row is a fixed 24pt and a headline that wrapped
        // would either clip or push the card past 128 — "Reservation expired" is the
        // longest sentence in the set and is what this is measured against.
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(height: height)
    }

    private func lead(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .tracking(RideActivityMetrics.headlineTracking)
            .foregroundStyle(Color.mrtText)
    }

    /// The figure itself — WHITE and tabular, never gold. Gold belongs to the rail;
    /// the answer to "when" is not an accent.
    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .tracking(RideActivityMetrics.headlineTracking)
            .foregroundStyle(Color.mrtText)
    }

    /// `in`, the unit, and `dropoff` — 500 at 62%. The unit is NEVER dropped: it is
    /// what stops a duration being read as a time.
    private func soft(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.mrtActivityTextSecondary)
    }
}

// MARK: - Row 3: the subline

/// **A PLACE OR AN IDENTIFICATION, NEVER A STATUS.** 13.5/400 at 58%, one line,
/// tail ellipsis — and the row keeps its 17pt whether or not there is anything to
/// put in it, because the card's footprint is fixed in every state.
struct RideActivitySublineView: View {
    let subline: String?
    var size: CGFloat = RideActivityMetrics.sublineSize
    /// Fixed on the card, `nil` on the expanded island — see the headline's own
    /// `height` for why the two surfaces answer this differently.
    var height: CGFloat? = RideActivityMetrics.sublineRowHeight

    /// ONE line on the card, where the row is 17pt and cannot grow. **TWO on the
    /// expanded island** (§0 A), where the height is content-driven and there is
    /// therefore room to say the whole place name instead of ellipsizing it — and
    /// where the second line is also what makes "the island's height differs between
    /// a two-line and a three-line state" observable at all.
    var lineLimit: Int = 1

    var body: some View {
        HStack(spacing: 0) {
            Text(subline ?? "")
                .font(.system(size: size))
                .tracking(RideActivityMetrics.sublineTracking)
                .foregroundStyle(Color.mrtActivityTextSubline)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: height)
    }
}

// MARK: - Row 4: the route line

/// **ALWAYS RENDERED, AND ALWAYS GOLD WHEN LIVE.**
///
/// Track, gold fill, the brand arrow riding the head in a 22pt puck, and an 11pt
/// destination pin at the end. Unlabelled — the subline already names where you are
/// going, so labels under the rail were redundant and are gone.
///
/// FOUR THINGS THE BOARD ASKED FOR AND THIS DRAWS:
///
///   • **The `idle` variant is a state, not an absence.** No gold fill and a
///     half-strength puck at the origin: an untravelled route, not an error. It is
///     what dispatch, no-telemetry and every ending render, and it is why every
///     state has the same footprint. Drawing NO rail (v2) or a zero-width GOLD fill
///     would be the two ways to get this wrong.
///   • **The puck is CLAMPED to the track** — `11 + (W − 22) × p` for its centre,
///     i.e. `(W − 22) × p` for its leading edge — so it never overhangs either end.
///     v2 centred a disc on the fraction and had to inset the whole rail on the
///     island to stop it being cut in half by the corner radius; a clamped puck needs
///     no clearance anywhere and the geometry is the same on both surfaces.
///   • **At `p = 1` the destination pin is REMOVED** and the mark stands in its
///     place — the car has become the marker. Two markers stacked on one point reads
///     as a rendering bug.
///   • **The arrow is `ArrowMarkEast`** — the mark's own polygons banked 90° ONCE, in
///     DesignSystem, as a fixed asset. Nothing here rotates it, and in particular
///     nothing rotates it per progress: an arrow whose angle tracked the rail would
///     claim a heading the content state does not carry (MYR-348's one-hexagon rule).
///
/// **STALENESS DOES NOTHING TO THIS VIEW.** It takes no `isStale` at all, which is
/// the structural form of the board's ruling: a fraction is a claim about the PAST —
/// the car really was that far along when we last heard — and it does not rot while
/// nobody is looking. The card admits the staleness in the SUBLINE, in words.
struct RideActivityRail: View {
    let rail: RideActivityRailState
    let leg: RideActivityLeg?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(1, max(0, rail.progress))
            let travel = max(0, width - RideActivityMetrics.railPuck)

            ZStack(alignment: .leading) {
                // Track — 5pt, rgba(255,255,255,0.13), with the inset top highlight
                // that makes it read as recessed.
                Capsule()
                    .fill(Color.mrtActivityRailTrack)
                    .frame(height: RideActivityMetrics.railHeight)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.mrtActivityRailTrackHighlight)
                            .frame(height: MRTMetrics.hairline)
                    }

                // GOLD, and only on the live variant. `idle` draws no fill at all —
                // not a zero-width one, which would be a fill the card is keeping to
                // itself.
                if !rail.isIdle {
                    Capsule()
                        .fill(Color.mrtGold)
                        .frame(width: width * fraction, height: RideActivityMetrics.railHeight)
                }

                // The destination pin, until the mark takes its place.
                if fraction < 1 {
                    Circle()
                        .strokeBorder(Color.mrtActivityRailPin, lineWidth: RideActivityMetrics.railPinRing)
                        .background(Circle().fill(Color.mrtActivityGroundMid))
                        .frame(width: RideActivityMetrics.railPin, height: RideActivityMetrics.railPin)
                        .offset(x: width - RideActivityMetrics.railPin)
                }

                // The puck. OFFSET, not layout — it is laid out once at the origin
                // and translated, so a moving fraction re-composites one small layer
                // instead of re-laying out the row.
                puck
                    .offset(x: travel * fraction)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: RideActivityMetrics.railRowHeight)
        // REDUCE MOTION → NO TRAVEL. The fill and the puck are drawn at their new
        // positions with no interpolation; the rail still tells the truth, it just
        // does not move to get there.
        .animation(
            reduceMotion
                ? nil
                : .timingCurve(0.2, 0.8, 0.2, 1, duration: RideActivityMetrics.railTravel),
            value: rail.progress
        )
        // THE LEG IS THE VIEW'S IDENTITY. Leg one ends at exactly 1 and leg two opens
        // near 0, so without this the flip animates a full rail collapsing backwards
        // — the one thing a progress arrow must never appear to do. A new identity
        // replaces the view instead, and the new leg's rail is simply the new leg's
        // rail.
        .id(leg)
        .accessibilityLabel(Text(Self.accessibilityLabel(rail: rail, leg: leg)))
    }

    private var puck: some View {
        ArrowMarkEast(size: RideActivityMetrics.railArrow)
            .frame(width: RideActivityMetrics.railPuck, height: RideActivityMetrics.railPuck)
            // The 22pt puck plus la-kit's own `0 0 0 2px` ring of the same colour —
            // one 26pt disc of the ground, so the puck punches a hole in the fill it
            // is riding rather than sitting on top of it.
            .background {
                Circle()
                    .fill(Color.mrtActivityGroundMid)
                    .frame(
                        width: RideActivityMetrics.railPuck + RideActivityMetrics.railPuckRing * 2,
                        height: RideActivityMetrics.railPuck + RideActivityMetrics.railPuckRing * 2
                    )
            }
            .opacity(rail.isIdle ? RideActivityMetrics.railIdlePuckOpacity : 1)
    }

    static func accessibilityLabel(rail: RideActivityRailState, leg: RideActivityLeg?) -> String {
        guard !rail.isIdle else {
            return leg == .pickup ? "Your ride has not started moving yet" : "No route progress yet"
        }
        let percent = Int((min(1, max(0, rail.progress)) * 100).rounded())
        switch leg {
        case .pickup: return "\(percent)% of the way to your pickup"
        case .dropoff, .none: return "\(percent)% of the way there"
        }
    }
}

// MARK: - Surface 1: the lock screen / banner card

/// **FIXED 350 × 128 IN EVERY STATE**, four fixed-height rows, `space-between`.
///
/// The width is the system's to give (a Live Activity is laid out into the banner's
/// own width, which is 350 on the phones this ships to); the HEIGHT and the rows are
/// ours, and they are pinned. Nothing a state does may change the footprint — that is
/// the field report's fourth item, and it is why the endings keep an idle rail
/// instead of collapsing to a shorter card.
struct RideActivityLockScreenView: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RideActivityWordmarkRow()

            Spacer(minLength: 0)

            // Headline and subline are ONE block with no gap between them —
            // la-kit's own `space-between` over three children, not four.
            VStack(alignment: .leading, spacing: 0) {
                RideActivityHeadlineView(headline: card.headline)
                RideActivitySublineView(subline: card.subline)
            }

            Spacer(minLength: 0)

            RideActivityRail(rail: card.rail, leg: card.leg)
        }
        .padding(.top, RideActivityMetrics.cardPaddingTop)
        .padding(.horizontal, RideActivityMetrics.cardPaddingHorizontal)
        .padding(.bottom, RideActivityMetrics.cardPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: RideActivityMetrics.cardHeight)
        // THE GROUND IS OURS AND IT IS OPAQUE (handoff §9). Drawn as a real
        // background under the whole card rather than left to the system's default
        // material, which is what v1 was rendering on.
        .background { RideActivityGround() }
        // The system's own container tint, set to the ground's last stop so any pixel
        // the container owns outside our background matches it rather than falling
        // back to glass.
        .activityBackgroundTint(Color.mrtActivityGroundBottom)
        .activitySystemActionForegroundColor(Color.mrtGold)
    }
}

// MARK: - Surface 2: the compact Dynamic Island

/// COMPACT LEADING — the east-banked arrow, at full strength in every state.
///
/// v2 dimmed it to 45% on the endings. v3 has one accent and no dimming vocabulary:
/// the mark says WHOSE ride this is, and that is equally true of a ride that ended.
struct RideActivityIslandLeading: View {
    let card: RideActivityCard

    var body: some View {
        ArrowMarkEast(size: RideActivityMetrics.compactArrow)
            .accessibilityLabel(Self.label(for: card))
    }

    /// The island renders no words, so the accessible name is the CARD's headline —
    /// the same sentence a sighted rider reads one surface over, rather than a
    /// second vocabulary invented for VoiceOver.
    static func label(for card: RideActivityCard) -> String {
        switch card.headline {
        case .pickupCountdown(let figure):
            return "\(RideActivityCopy.pickupPhase) \(RideActivityCopy.countdownJoin) \(figure.text)"
        case .dropoffClock(let clock):
            return "\(clock) \(RideActivityCopy.dropoffWord)"
        case .sentence(let text):
            return text
        }
    }
}

/// COMPACT TRAILING — **a figure, a BARE glyph, or NOTHING** (§0 D, as corrected by
/// MYR-412 and cut back by MYR-420).
///
/// `8 min` / `1 min` / `3:42 PM` at 15/600 tabular, exactly as before §0: nothing has
/// ever displaced a number here, and the figure is the ONE branch that carries no
/// inset, so those four states stay byte-identical. Where there IS no number the slot
/// is EMPTY again — §0 B filled it with a ring and the client removed it: *"remove
/// the ring entirely then and if theres data it appears on the right side."*
///
/// **THE GLYPH AND THE EMPTY RESOLUTION SHARE ONE VIEW ON PURPOSE.** The arrival beat
/// is a transition BETWEEN them (an accepted ride with no ETA is empty; the moment it
/// arrives it is a wave), so splitting them at this switch would give the beat two
/// view identities and nothing to animate.
struct RideActivityIslandTrailing: View {
    let card: RideActivityCard

    var body: some View {
        switch card.compact {
        case .figure(let figure):
            // HELD, not ticking — the client's ruling, and there is no clock in this
            // process to tick it with. NOT dimmed on stale either: v2 dropped it to
            // 45%, and v3 admits staleness in the card's subline in words.
            Text(figure)
                .font(.system(size: RideActivityMetrics.compactFigureSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.mrtText)
                .lineLimit(1)

        case .glyph, .empty:
            RideActivityIslandTrailingSlot(
                slot: card.compact,
                waveSize: RideActivityMetrics.compactWaveGlyph,
                checkSize: RideActivityMetrics.compactCheckGlyph,
                horizontalInset: RideActivityMetrics.compactTrailingInset
            )
        }
    }
}

/// MINIMAL — **the mark, and nothing around it** (MYR-420).
///
/// This is what the rider sees when another app owns the island, and it says one
/// thing: WHOSE ride is running. §0 B wrapped that mark in the progress ring, per §5's
/// "Minimal 37×37 · ring d24 stroke 2.4 · center arrow 12 / glyph 13"; MYR-412 kept it
/// here after stripping the two trailing slots, on the reading that a BARE ring on
/// this surface would be an anonymous circle. **The client then removed the ring
/// itself**, which settles that argument from the other end: what is left is the
/// centre — the mark, swapping for the arrival glyph at the two stops on the same beat
/// the trailing slots run.
///
/// See `RideActivityIslandMark`. The composition is a lone mark on a black circle now,
/// which is exactly what v3 shipped before §0 B.
struct RideActivityIslandMinimal: View {
    let card: RideActivityCard

    var body: some View {
        RideActivityIslandMark(slot: card.expandedTrailing)
            .accessibilityLabel(RideActivityIslandLeading.label(for: card))
    }
}

// MARK: - Surface 3: the expanded Dynamic Island · §0 A
//
// ─────────────────────────────────────────────────────────────────────────────
// **THE TALL BLACK BOX WAS WIDE CONTENT IN THE TOP ROW, AND THE FIX IS WHICH REGION
// EACH THING GOES IN.**
//
// v3 put the WHOLE composition — logo, headline, subline and rail — into
// `DynamicIslandExpandedRegion(.center)`. The sensor housing splits that row: only
// narrow leading and trailing content survives beside it, so the system pushes wide
// content around the housing and pads the difference. What the client photographed
// is exactly that — content crowded into the top, an empty field below and to the
// right, and a card far taller than its content. A `.frame(height:)` or a `Spacer()`
// makes it worse, because both give the system more to pad.
//
// So the top row is now TWO SMALL THINGS and nothing else:
//
//   `.leading`   the brand mark, 26
//   `.trailing`  the arrival glyph (19/17) — or, after MYR-420, nothing
//   `.center`    **DELIBERATELY UNUSED — the housing owns it.**
//
// and EVERYTHING WIDE moves to `.bottom`, which is the one region that spans the
// island's full width: headline, subline, rail.
//
// ⚠️ **NOTHING IN THIS SECTION MAY SET A WIDTH OR A HEIGHT.** The island's height is
// content-driven, and the acceptance test for that is behavioural rather than
// numeric: a two-line state and a three-line state must render at DIFFERENT heights.
// If they match, something is pinned. That is also why the headline and subline are
// built with `height: nil` here while the CARD keeps its fixed rows — the card's
// promise is a fixed footprint, and the island's is the opposite one.
//
// ⚠️ **AND THE CORNERS ARE THE SECOND HALF OF §0 A** — the client's follow-up on
// this very rebuild: *the mark (top-left) and the ring (top-right) intersect the
// pill's corner curvature, and the rail's origin puck and end cap run into the
// bottom two.* The pill is a SQUIRCLE, so its edge is still curving hard 15pt in
// from any corner, and the four things that reach a corner are exactly the four
// things §0 A moved there. The fix is three INSETS at three call sites
// (`expandedCornerSafeHorizontal` / `expandedCornerSafeTop` /
// `expandedRailCornerSafeInset`) and nothing else: no frame, no width, no height,
// and **the headline and subline do not move** — they sit where the pill's edge is
// straight, and re-laying out the column to fix two corners is the change this is
// deliberately not.
//
// The gap and the type are the kit's. **THE BOX PADDING (10/20/15) IS THE SYSTEM'S
// AND IS NOT RE-APPLIED HERE**: `DynamicIslandExpandedRegion` already insets its
// content from the island's edges, and a second inset on top of it is how a
// full-width region stops being one — which is the same class of mistake as the
// crowding this issue is fixing. The numbers stay named in `RideActivityMetrics` as
// the design's own box, where `RideActivityGeometryTests` can check the arithmetic
// they imply.
// ─────────────────────────────────────────────────────────────────────────────

/// `.leading` — the brand mark alone.
///
/// The one thing the housing leaves room for on this side, and the one thing that
/// has to be here: the island's ground is the hardware's true black, so without the
/// mark nothing on the expanded surface says whose ride this is.
struct RideActivityIslandExpandedLeading: View {
    var body: some View {
        HexLogo(size: RideActivityMetrics.expandedLogo)
            .accessibilityHidden(true)
            // CORNER-SAFE, and nothing more than that. `.padding` and NOT a frame:
            // the mark keeps its 26pt, the region keeps its own size, and the only
            // thing that changed is where inside the region the mark sits.
            .padding(.leading, RideActivityMetrics.expandedCornerSafeHorizontal)
            .padding(.top, RideActivityMetrics.expandedCornerSafeTop)
    }
}

/// `.trailing` — **the BARE glyph, or nothing.** Never the ETA.
///
/// The expanded headline already carries the figure, so a second copy of it here
/// would be the badge the whole redesign removed; the slot instead answers the one
/// question the headline cannot — which stop we reached. **On every other state it is
/// now empty** (MYR-420), and the region is simply unoccupied: the rail below it is
/// what says how far along the ride is, on this surface and on the card alike.
///
/// **IT RUNS THE COMPACT SLOT'S OWN VIEW.** The rule is about the composition rather
/// than about one surface, and forking it would be two spellings of one rule — which
/// is what §0 D's single ladder and MYR-412's single view both exist to stop. The only
/// difference is the pair of glyph sizes, because this surface is larger.
///
/// It passes **no horizontal inset of its own**: #168's corner-safe padding below is
/// already 6pt, and re-measuring that surface's four corner clearances is not this
/// issue's change to make.
struct RideActivityIslandExpandedTrailing: View {
    let card: RideActivityCard

    var body: some View {
        RideActivityIslandTrailingSlot(
            slot: card.expandedTrailing,
            waveSize: RideActivityMetrics.expandedWaveGlyph,
            checkSize: RideActivityMetrics.expandedCheckGlyph,
            horizontalInset: 0
        )
        // The MIRROR of the leading mark's inset — same two numbers, opposite
        // side, so the top row stays symmetric about the housing.
        .padding(.trailing, RideActivityMetrics.expandedCornerSafeHorizontal)
        .padding(.top, RideActivityMetrics.expandedCornerSafeTop)
    }
}

/// `.bottom` — everything wide.
///
/// Headline (19/600), subline (12.5 @58%), rail. Two lines and a rail, laid out once
/// at their own size, with the rail separated by 8 rather than by a `Spacer` — a
/// spacer here would expand to whatever the system offered and re-create the empty
/// band it was supposed to remove.
struct RideActivityIslandExpandedBottom: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: RideActivityMetrics.expandedBlockSpacing) {
            RideActivityHeadlineView(
                headline: card.headline,
                size: RideActivityMetrics.expandedHeadlineSize,
                height: nil
            )
            // **ONLY WHEN THERE IS ONE.** The card renders an empty 17pt row here
            // because its footprint is fixed; on a content-driven surface that same
            // row is a pinned blank line, which is one of the two ways §0 A's black
            // box comes back.
            if let subline = card.subline {
                RideActivitySublineView(
                    subline: subline,
                    size: RideActivityMetrics.expandedSublineSize,
                    height: nil,
                    lineLimit: RideActivityMetrics.expandedSublineLineLimit
                )
            }

            RideActivityRail(rail: card.rail, leg: card.leg)
                .padding(.top, RideActivityMetrics.expandedRailTopGap)
                // CORNER-SAFE, ON THE RAIL ALONE. The two lines above keep the
                // column they had — insetting the whole block would move the
                // headline to fix a corner the headline never reaches, and the
                // client's instruction is explicit that the text column stays put.
                // The rail's own `GeometryReader` simply reads a narrower width and
                // clamps the puck into it, so the ends move and nothing is pinned.
                .padding(.horizontal, RideActivityMetrics.expandedRailCornerSafeInset)
        }
        // `maxWidth: .infinity` is a FILL, not a size: it is what makes the region's
        // own full width available to a leading-aligned stack. It is the one frame
        // in this section, it constrains nothing, and it names no number.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
