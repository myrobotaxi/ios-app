import DesignSystem
import MyRobotaxiContracts
import SwiftUI
import WidgetKit

// MARK: - The rider's ride, as the lock screen and Dynamic Island see it
//
// r16 REDESIGN v2 (MYR-398, CLIENT-DIRECTED — the client authored the board and the
// handoff himself: `design/Handoff-Live-Activity.md`, `design/la/la-data.jsx`,
// `design/la/la-kit.jsx`, mirrored into this repo by this PR).
//
// v1 answered the client's first ask — an ETA and a line showing the car's position
// — and he then designed what those two things should LOOK like. **The state
// machine did not change and does not change here.** Content-state decoding, push
// handling, the monotone clamp and every lifecycle rule are untouched; what changed
// is what each of the twelve states renders.
//
// ─────────────────────────────────────────────────────────────────────────────
// FIVE PARTS, FOUR SURFACES, ONE LAYOUT (handoff §2 + SwiftUI note 1)
//
//   1. `ActivityBrandTile`   — the 20/26pt tile + the wordmark row
//   2. `ActivityHeadline`    — `{n} min` / `{n} s`, or the state's sentence
//   3. `ActivitySecondLine`  — ONE place: the pickup, or the destination in gold
//   4. `ActivityRail`        — 5pt track, gold fill, the east-banked facet arrow
//   5. `ActivityChip`        — the word + its 5pt tone dot (+ `ActivityStaleNotice`)
//
// `ActivityConfiguration` composes them for the lock screen and `DynamicIsland { }`
// reuses THE SAME FIVE at different sizes. **Do not fork the layout per surface** —
// the handoff says so, and v1's expanded island had already drifted into a second
// composition that spelled the trip line differently from the card's.
// ─────────────────────────────────────────────────────────────────────────────
//
// WHAT DECIDES WHAT: nothing in this file. `RideActivityCard.resolve` is the whole
// rule and is unit-tested against `la-data.jsx`'s own twelve rows; these views lay
// out what it returns and never switch on `status`. That split is why any of this
// is assertable at all — a presentation that cannot be instantiated in a test
// cannot be the thing that decides.
//
// THREE THINGS THIS FILE IS RESPONSIBLE FOR, AND THEY ARE THE THREE THE BOARD
// SPENT ITS WORDS ON:
//
//   • THE CARD GROUND IS A REAL `ZStack` OF TWO GRADIENTS, NOT `.ultraThinMaterial`
//     (handoff SwiftUI note 2). v1 inherited the system's glass because that is
//     what a Live Activity does when you do not give it a background — it was the
//     default, not a choice. The card sits on the logo tile's own opaque brown-black
//     now, which survives any wallpaper. The ISLAND stays true black: that one is
//     the hardware.
//   • THE COUNTDOWN CANNOT USE `Text(timerInterval:)` (SwiftUI note 1). It renders
//     `mm:ss`, which is the format the board removed. A 1s `TimelineView(.periodic)`
//     emits `RideActivityCountdown.parts` instead.
//   • THE ARROW IS BANKED DUE EAST AS A FIXED ASSET (`ArrowMarkEast`, DesignSystem)
//     and is NEVER rotated at runtime and NEVER rotated per progress. It rides the
//     rail head in a 20pt `#0d0b06` disc. It is the brand mark's polygons verbatim —
//     the MYR-348 hexagon lesson: the moment a surface draws its own version of the
//     logo there are two logos.

// MARK: - Geometry
//
// `la-kit.jsx`'s numbers, in one place so a capture can be measured against the
// design rather than eyeballed against it. Every value here is quoted in the
// handoff's §3 geometry block.
enum RideActivityMetrics {
    // Card
    static let cardRadius: CGFloat = 22
    static let cardPaddingTop: CGFloat = 13
    static let cardPaddingHorizontal: CGFloat = 15
    static let cardPaddingBottom: CGFloat = 14
    static let cardGap: CGFloat = 10
    /// The gap INSIDE the text block — headline to second line.
    static let cardTextGap: CGFloat = 3
    static let cardBrandRowGap: CGFloat = 8
    static let cardTileSize: CGFloat = 20
    static let wordmarkSize: CGFloat = 10
    static let wordmarkTracking: CGFloat = 0.9

    // Headline — ONE type size for both kinds, which is the whole point of §1
    // change 3: the mixed sizes were what made the line look broken.
    static let headlineSize: CGFloat = 17.5
    static let headlineGap: CGFloat = 6
    static let headlineTracking: CGFloat = -0.3
    static let headlinePrefixTracking: CGFloat = -0.2
    /// `line-height: 1.25` at 17.5pt ≈ 21.9pt; SF's own 17.5pt line box is ≈20.9pt,
    /// so the extra pt is added as leading rather than by overriding the line box.
    static let sentenceLineSpacing: CGFloat = 1

    // Second line
    static let secondLineSize: CGFloat = 13.5
    static let secondLineTracking: CGFloat = -0.1

    // Rail
    static let railHeight: CGFloat = 5
    /// The row the rail sits in. The 20pt disc is CENTRED in it and overhangs by
    /// 1pt top and bottom — la-kit's own `height: 18` with an absolutely-positioned
    /// disc, and nothing clips it.
    static let railRowHeight: CGFloat = 18
    static let railDisc: CGFloat = 20
    static let railArrow: CGFloat = 13
    static let railCap: CGFloat = 5
    /// The cap only reaches full strength at the end of the leg.
    static let railCapRestingOpacity: Double = 0.55
    static let railStaleOpacity: Double = 0.55
    /// `transition: .5s cubic-bezier(.2,.8,.2,1)` — la-kit's own rail curve.
    static let railTravel: TimeInterval = 0.5

    // Chip
    static let chipHeight: CGFloat = 20
    static let chipDot: CGFloat = 5
    static let chipGap: CGFloat = 5
    static let chipPaddingLeading: CGFloat = 7
    static let chipPaddingTrailing: CGFloat = 8
    static let chipLabelSize: CGFloat = 10.5
    static let chipLabelTracking: CGFloat = 0.2
    /// The `arrived` dot's breath: 1.6s ease-in-out, opacity 1 → 0.35 (handoff §7).
    static let pulseHalfPeriod: TimeInterval = 0.8
    static let pulseFloor: Double = 0.35

    // Stale notice
    static let staleGap: CGFloat = 6
    static let staleRing: CGFloat = 5
    static let staleTextSize: CGFloat = 11.5

    // Dynamic Island
    static let compactArrow: CGFloat = 16
    static let compactFigureSize: CGFloat = 15
    static let compactWordSize: CGFloat = 14.5
    static let compactTerminalArrowOpacity: Double = 0.45
    static let minimalArrow: CGFloat = 17

    static let expandedGap: CGFloat = 12
    static let expandedHeaderGap: CGFloat = 10
    static let expandedTextGap: CGFloat = 2
    static let expandedTile: CGFloat = 26
    static let expandedKickerSize: CGFloat = 12.5
    static let expandedSentenceSize: CGFloat = 14.5
    static let expandedSecondLineSize: CGFloat = 12
    static let expandedValueSize: CGFloat = 22
    static let expandedUnitSize: CGFloat = 14
    static let expandedUnitGap: CGFloat = 4
    static let expandedBottomGap: CGFloat = 8
    static let expandedBottomMinHeight: CGFloat = 20
    static let expandedPaddingTop: CGFloat = 14
    static let expandedPaddingBottom: CGFloat = 4
}

// MARK: - Part 0: the ground
//
// Two gradients, opaque, in a real `ZStack` — NOT a material (handoff SwiftUI
// note 2). Same values as the logo tile in `app/components.jsx`, which is why the
// card reads as the brand tile enlarged rather than as a card with a brand tile on
// it.
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

// MARK: - Part 1: the brand tile + wordmark row

/// Tile, wordmark, and the chip trailing — the card's top line.
///
/// The tile is `HexLogo` and the wordmark is `Wordmark`, both verbatim from
/// DesignSystem. The row is assembled here rather than using `Wordmark(withLogo:)`
/// because that pairing sizes the tile at `size × 1.25` (12.5pt beside a 10pt
/// wordmark) and this row is a 20pt tile beside a 10pt kicker — a different
/// relationship, not a different mark.
struct RideActivityBrandRow: View {
    let card: RideActivityCard
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

            Spacer(minLength: RideActivityMetrics.cardBrandRowGap)

            // "Reservation expired" is the widest chip in the set and therefore
            // sets this row's minimum width. `fixedSize` inside the chip keeps it
            // from being the thing that truncates — the wordmark gives way first,
            // which is correct: the word is the state and the wordmark is furniture.
            RideActivityChip(card: card)
        }
    }
}

// MARK: - Part 2: the headline

/// `Pick up in` + `4` + `min`, or the state's own sentence — both at ONE type size.
///
/// **`Text(timerInterval:countsDown:)` CANNOT BE USED HERE.** It renders `mm:ss`,
/// and `4:12` after "Pick up in" reads as a clock time — which is the defect §1
/// change 3 exists to remove.
///
/// **AND THE FIGURE DOES NOT TICK — CLIENT DECISION, 2026-07-31**, superseding the
/// handoff's own SwiftUI note 1 (which asked for a 1s `TimelineView(.periodic)`).
/// *"We are pulling live data from Tesla ETA telemetry; counting down is
/// inaccurate."* The figure arrives already resolved on the card
/// (`RideActivityHeadline.countdown(prefix:figure:)`) and this view is a plain
/// `Text` — there is no clock in the widget process at all, which is the strongest
/// available form of "no local extrapolation": it is not switched off, it is
/// absent. See `RideActivityCountdown` for the reasoning and for the measurement
/// that showed ActivityKit would not have ticked the timeline anyway.
struct RideActivityHeadlineView: View {
    let headline: RideActivityHeadline
    var size: CGFloat = RideActivityMetrics.headlineSize

    var body: some View {
        switch headline {
        case .countdown(let prefix, let figure):
            HStack(alignment: .firstTextBaseline, spacing: RideActivityMetrics.headlineGap) {
                Text(prefix)
                    .font(.system(size: size, weight: .medium))
                    .tracking(RideActivityMetrics.headlinePrefixTracking)
                    .foregroundStyle(Color.mrtActivityTextSecondary)

                // WHITE, NOT GOLD (handoff §1 change 5). Gold stays on the rail,
                // the destination and the arrow; the answer to "when" is not an
                // accent.
                Text(figure.value)
                    .font(.system(size: size, weight: .semibold))
                    .monospacedDigit()
                    .tracking(RideActivityMetrics.headlineTracking)
                    .foregroundStyle(Color.mrtText)

                // The unit is NEVER dropped — it is what stops a duration being
                // read as a time.
                Text(figure.unit)
                    .font(.system(size: size, weight: .medium))
                    .tracking(RideActivityMetrics.headlinePrefixTracking)
                    .foregroundStyle(Color.mrtActivityTextSecondary)
            }
            .lineLimit(1)
            // The countdown NEVER wraps (handoff §2 part 1). At the chip's widest
            // the line still fits, but a long prefix in a future locale must shrink
            // rather than break.
            .minimumScaleFactor(0.85)

        case .sentence(let text):
            Text(text)
                .font(.system(size: size, weight: .medium))
                .tracking(RideActivityMetrics.headlineTracking)
                .lineSpacing(RideActivityMetrics.sentenceLineSpacing)
                .foregroundStyle(Color.mrtText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Part 3: the second line

/// ONE place, never a pair (handoff §1 change 10).
///
/// Leg 1 is the pickup at 62%; leg 2 is the destination IN GOLD. There is no
/// "Meet at " prefix, no vehicle name and no arrow — the headline already says
/// which leg you are on and the rail already shows the span.
struct RideActivitySecondLineView: View {
    let place: RideActivitySecondLine
    var size: CGFloat = RideActivityMetrics.secondLineSize

    var body: some View {
        Text(label)
            .font(.system(size: size))
            .tracking(RideActivityMetrics.secondLineTracking)
            .foregroundStyle(colour)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var label: String {
        switch place {
        case .pickup(let name), .destination(let name): return name
        }
    }

    private var colour: Color {
        switch place {
        case .pickup: return .mrtActivityTextSecondary
        case .destination: return .mrtGold
        }
    }
}

// MARK: - Part 4: the progress rail

/// The rail, its end cap, and the east-banked facet arrow riding the head.
///
/// Rendered ONLY when the server sent a fraction — the caller decides, so there is
/// no "absent" arm in here to get backwards. An absent `progress` is a TRACKLESS
/// card, never an empty rail and never a rail at zero.
///
/// FOUR THINGS THE BOARD ASKED FOR AND THIS DRAWS:
///
///   • The arrow is `ArrowMarkEast` — the mark's own polygons banked 90° ONCE, in
///     DesignSystem, as a fixed asset. Nothing here rotates it, and in particular
///     nothing rotates it per progress: an arrow whose angle tracked the rail would
///     be claiming a heading the content state does not carry.
///   • It rides in a 20pt `#0d0b06` disc whose CENTRE sits at the fraction, so at
///     `1` the disc parks over the end cap. That is the completed state's whole
///     arrival beat (board decision 3) and the reason the cap is where it is.
///   • The END CAP reads which leg you are on without a word: `goldDeepSoft` on
///     leg 1, `gold` on leg 2, and full opacity ONLY at 100%.
///   • STALE DESATURATES rather than removing (handoff §5). A fraction is a claim
///     about the PAST — the car really was that far along when we last heard — and
///     it does not rot into a different number while nobody is looking. Removing it
///     would also make staleness look identical to the server's honest "no fraction
///     to give you" arm, which is a different situation.
struct RideActivityRail: View {
    let progress: Double
    let leg: RideActivityLeg?
    let isStale: Bool

    /// How far in from the row's own edges the RAIL is drawn, so the head's disc —
    /// which is centred on the fraction and therefore overhangs the rail's ends by
    /// half its width — has somewhere to hang.
    ///
    /// **0 ON THE LOCK CARD, WHICH IS la-kit's OWN GEOMETRY**: the rail spans the
    /// full content width and the disc overhangs into the card's 15pt side padding,
    /// which is wider than the 10pt it needs. **`railDisc / 2` ON THE EXPANDED
    /// ISLAND**, and that is not a preference — it was measured. The island's
    /// container has a 44pt corner radius and the rail sits near its bottom edge,
    /// so at `progress == 1` the disc landed inside the corner curve and was cut in
    /// half (visible in the first `arrived` and `completed` captures of this
    /// branch). Insetting the rail moves the CAP with it, so the completed state's
    /// "arrow parked on the destination cap" beat stays concentric — which
    /// clamping the disc's offset instead would have broken by 7.5pt.
    var headClearance: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(1, max(0, progress))

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

                Capsule()
                    .fill(fillColour)
                    .frame(width: width * fraction, height: RideActivityMetrics.railHeight)

                // End cap, at the far end of the leg.
                Circle()
                    .fill(capColour)
                    .frame(width: RideActivityMetrics.railCap, height: RideActivityMetrics.railCap)
                    .opacity(fraction >= 1 ? 1 : RideActivityMetrics.railCapRestingOpacity)
                    .offset(x: width - RideActivityMetrics.railCap)

                // The head. OFFSET, not layout — the disc is laid out once at the
                // origin and translated, so a moving fraction re-composites one
                // small layer instead of re-laying out the row.
                ZStack {
                    Circle().fill(Color.mrtActivityGroundMid)
                    ArrowMarkEast(size: RideActivityMetrics.railArrow)
                }
                .frame(width: RideActivityMetrics.railDisc, height: RideActivityMetrics.railDisc)
                .opacity(isStale ? RideActivityMetrics.railStaleOpacity : 1)
                .offset(x: width * fraction - RideActivityMetrics.railDisc / 2)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
        }
        .padding(.horizontal, headClearance)
        .frame(height: RideActivityMetrics.railRowHeight)
        .opacity(isStale ? RideActivityMetrics.railStaleOpacity : 1)
        // REDUCE MOTION → NO TRAVEL. The fill and the head are drawn at their new
        // positions with no interpolation; the rail still tells the truth, it just
        // does not move to get there.
        .animation(
            reduceMotion
                ? nil
                : .timingCurve(0.2, 0.8, 0.2, 1, duration: RideActivityMetrics.railTravel),
            value: progress
        )
        // THE LEG IS THE VIEW'S IDENTITY. Leg one ends at exactly 1 and leg two
        // opens near 0, so without this the flip animates a full rail collapsing
        // backwards — the one thing a progress arrow must never appear to do. A new
        // identity replaces the view instead, and the new leg's rail is simply the
        // new leg's rail.
        .id(leg)
        .accessibilityLabel(Text(Self.accessibilityLabel(progress: progress, leg: leg)))
    }

    private var fillColour: Color {
        isStale ? .mrtActivityRailStale : .mrtGold
    }

    private var capColour: Color {
        if isStale { return .mrtActivityRailStale }
        return leg == .dropoff ? .mrtGold : .mrtGoldDeepSoft
    }

    static func accessibilityLabel(progress: Double, leg: RideActivityLeg?) -> String {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        switch leg {
        case .pickup: return "\(percent)% of the way to your pickup"
        case .dropoff, .none: return "\(percent)% of the way there"
        }
    }
}

// MARK: - Part 5: the status chip (+ the stale notice)

/// 20pt tall, radius 10, a 5pt tone dot and a 10.5/500 label at 82% white.
///
/// **THE STATE'S COLOUR LIVES IN THE DOT AND NOWHERE ELSE** (handoff §1 change 4).
/// Twelve states × coloured text is a dozen colours competing with gold; the label
/// is always 82% white whatever the state, so the chip reads as one component
/// rather than as twelve.
struct RideActivityChip: View {
    let card: RideActivityCard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: RideActivityMetrics.chipGap) {
            toneDot
            Text(card.chipWord)
                .font(.system(size: RideActivityMetrics.chipLabelSize, weight: .medium))
                .tracking(RideActivityMetrics.chipLabelTracking)
                .foregroundStyle(Color.mrtActivityChipLabel)
                .lineLimit(1)
        }
        .padding(.leading, RideActivityMetrics.chipPaddingLeading)
        .padding(.trailing, RideActivityMetrics.chipPaddingTrailing)
        .frame(height: RideActivityMetrics.chipHeight)
        .background(Color.mrtActivityChipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtActivityChipHairline, lineWidth: MRTMetrics.hairline))
        // The chip never truncates and never wraps — it is the shortest true thing
        // on the card and the widest of the twelve sets the row's width.
        .fixedSize()
    }

    @ViewBuilder
    private var toneDot: some View {
        // THE ONLY ANIMATION ON THIS CARD BESIDES THE RAIL'S OFFSET, and it is on
        // the one state where something is waiting for the RIDER rather than the
        // other way round. Live Activities are budget-limited, so everything else is
        // static — including a stale `arrived`, which must not pulse: motion is a
        // claim to be live.
        if card.pulsesToneDot && !reduceMotion {
            // ⚠️ PHASED FROM THIS FRAME, NOT FROM THE ABSOLUTE CLOCK, and that is
            // the whole safety of it.
            //
            // The ETA measurement on this branch established that ActivityKit does
            // not tick a periodic timeline between content updates (see
            // `RideActivityCountdown`). This one is kept because the handoff asks
            // for it explicitly and the lock screen is a different render path from
            // the island — but it must DEGRADE to a full-strength dot, never to a
            // randomly dimmed one. `from: .now` emits its first entry at the anchor,
            // so a schedule that is sampled once is sampled at step 0, which is
            // opacity 1. Phasing off `timeIntervalSinceReferenceDate` instead would
            // make a single sample a coin toss between 1 and 0.35, and a tone dot
            // sitting at 35% for no reason reads as a state we do not have.
            //
            // The cost of the local anchor is that the breath restarts on each push.
            // Pushes are 60–90s apart and a 1.6s cycle restarting at full is
            // invisible; a dot that is dim on arrival is not.
            let anchor = Date()
            TimelineView(.periodic(from: anchor, by: RideActivityMetrics.pulseHalfPeriod)) { context in
                let half = RideActivityMetrics.pulseHalfPeriod
                let step = Int(context.date.timeIntervalSince(anchor) / half) % 2
                dot
                    .opacity(step == 0 ? 1 : RideActivityMetrics.pulseFloor)
                    // Each half is eased, so the pair is the handoff's 1.6s
                    // ease-in-out 1 → 0.35 → 1.
                    .animation(.easeInOut(duration: half), value: step)
            }
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle()
            .fill(Self.colour(for: card.tone))
            .frame(width: RideActivityMetrics.chipDot, height: RideActivityMetrics.chipDot)
    }

    /// The handoff's §4 table, and ONLY the handoff's §4 table — every one of these
    /// is an existing DesignSystem token. This redesign introduces no status colour.
    static func colour(for tone: RideActivityTone) -> Color {
        switch tone {
        case .pending: return .mrtGoldDeepSoft
        case .active: return .mrtGold
        case .riding: return .mrtDriving
        case .complete: return .mrtParked
        case .terminal: return .mrtOffline
        }
    }
}

/// The hollow ring + "Last update {t}" line, at the quietest step on the card.
///
/// The chip is what carries the warning now (board decision 2); this is the receipt
/// under it. **The word "stale" never renders** — that is ActivityKit's vocabulary,
/// not a rider's.
///
/// See `RideActivityCopy.staleNotice(lastUpdate:formatter:)` for why `{t}` has no
/// source on today's wire and what this renders instead.
struct RideActivityStaleNotice: View {
    let card: RideActivityCard

    var body: some View {
        HStack(spacing: RideActivityMetrics.staleGap) {
            Circle()
                .strokeBorder(Color.mrtActivityStaleRing, lineWidth: 1)
                .frame(width: RideActivityMetrics.staleRing, height: RideActivityMetrics.staleRing)

            Text(card.staleNoticeText)
                .font(.system(size: RideActivityMetrics.staleTextSize))
                .foregroundStyle(Color.mrtActivityTextQuiet)
                .lineLimit(1)
        }
    }
}

extension RideActivityCard {
    /// The stale line, rendered. Lives here rather than in `RideActivityCopy`
    /// because it is the only string on this surface that needs a LOCALE — `{t}` is
    /// a wall-clock time and `.shortened` is the system's 12/24-hour answer, not
    /// ours. The copy table supplies the sentence and takes the formatter as an
    /// argument, so the wording and its formatting stay separable.
    var staleNoticeText: String {
        RideActivityCopy.staleNotice(lastUpdate: staleLastUpdate) { instant in
            instant.formatted(date: .omitted, time: .shortened)
        }
    }
}

// MARK: - Surface 1: the lock screen / banner card

struct RideActivityLockScreenView: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: RideActivityMetrics.cardGap) {
            RideActivityBrandRow(card: card)

            VStack(alignment: .leading, spacing: RideActivityMetrics.cardTextGap) {
                RideActivityHeadlineView(headline: card.headline)
                if let place = card.secondLine {
                    RideActivitySecondLineView(place: place)
                }
            }

            // NO RAIL AND NO EMPTY TRACK when the server sent no fraction. The
            // `VStack` simply has one fewer child, so the card composes to its own
            // shorter height rather than reserving a rule with nothing on it —
            // which is the difference between "we cannot say where the car is" and
            // "the car is at the start", and the second one is a lie.
            if let track = card.track {
                RideActivityRail(progress: track, leg: card.leg, isStale: card.isStale)
            }

            if card.isStale {
                RideActivityStaleNotice(card: card)
            }
        }
        .padding(.top, RideActivityMetrics.cardPaddingTop)
        .padding(.horizontal, RideActivityMetrics.cardPaddingHorizontal)
        .padding(.bottom, RideActivityMetrics.cardPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        // THE GROUND IS OURS AND IT IS OPAQUE (handoff SwiftUI note 2). Drawn as a
        // real background under the whole card rather than left to the system's
        // default material, which is what v1 was rendering on — the glass was never
        // a choice, it was what a Live Activity does when you give it no background.
        .background { RideActivityGround() }
        // The system's own container tint, set to the ground's last stop so any
        // pixel the container owns outside our background matches it rather than
        // falling back to glass.
        .activityBackgroundTint(Color.mrtActivityGroundBottom)
        .activitySystemActionForegroundColor(Color.mrtGold)
    }
}

// MARK: - Surface 2: the compact Dynamic Island

/// COMPACT LEADING — the east-banked arrow, and nothing else.
struct RideActivityIslandLeading: View {
    let card: RideActivityCard

    var body: some View {
        ArrowMarkEast(size: RideActivityMetrics.compactArrow)
            .opacity(
                card.tone == .terminal
                    ? RideActivityMetrics.compactTerminalArrowOpacity
                    : 1
            )
            .accessibilityLabel(card.chipWord)
    }
}

/// COMPACT TRAILING — the figure, or the SHORT status word.
///
/// Board decision 1: a sentence state gets ONE WORD here, never the chip's word.
/// v1 fell back to the chip's, which put "Reservation expired" into a slot that
/// fits "Ended". Rejected on the board: the vehicle name (reads as branding, and
/// repeats across five states) and arrow-only (the island already has a minimal
/// presentation).
///
/// **A figure is 15/600 tabular; a word is 14.5/500 and must NOT be
/// `monospacedDigit`** (handoff SwiftUI note 3) — tabular figures in a word open
/// its letter-spacing and make "Driving" look mis-set.
struct RideActivityIslandTrailing: View {
    let card: RideActivityCard

    var body: some View {
        switch card.compact {
        case .figure(let figure, let isStale):
            // THE FIGURE SURVIVES STALENESS, at 45% (handoff §1 change 7). The lock
            // card has room to explain itself and swaps its headline for a sentence;
            // the island has room for one thing, and the last figure dimmed says
            // more to a rider than a confident word.
            //
            // HELD, exactly as the headline's is — same client ruling, same absence
            // of a clock in this process.
            Text(figure.text)
                .font(.system(size: RideActivityMetrics.compactFigureSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isStale ? Color.mrtActivityCompactStale : Color.mrtText)
                .lineLimit(1)

        case .word(let word):
            Text(word)
                .font(.system(size: RideActivityMetrics.compactWordSize, weight: .medium))
                .foregroundStyle(
                    card.isStale
                        ? Color.mrtActivityCompactStale
                        : (card.tone == .terminal ? Color.mrtActivityCompactTerminal : Color.mrtText)
                )
                .lineLimit(1)
        }
    }
}

/// MINIMAL — the east arrow alone.
///
/// This is what the rider sees when another app owns the island, so it has exactly
/// one job: say WHOSE ride is running.
struct RideActivityIslandMinimal: View {
    let card: RideActivityCard

    var body: some View {
        ArrowMarkEast(size: RideActivityMetrics.minimalArrow)
            .opacity(
                card.tone == .terminal
                    ? RideActivityMetrics.compactTerminalArrowOpacity
                    : 1
            )
            .accessibilityLabel(card.chipWord)
    }
}

// MARK: - Surface 3: the expanded Dynamic Island

/// The same five parts at island proportions — `la-kit.jsx`'s `LAIslandExpanded`.
///
/// TRUE BLACK, deliberately: the island's ground is the hardware, so unlike the
/// lock card this surface draws no background at all.
///
/// The one composition difference from the card is WHERE THE CHIP SITS, and it is
/// the kit's: on a countdown state the trailing slot holds the big 22/600 figure
/// and the chip drops to the bottom row; on a sentence state there is no figure, so
/// the chip takes the trailing slot and the bottom row carries the stale notice or
/// the affordance line. Both are the same five views.
struct RideActivityIslandExpanded: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: RideActivityMetrics.expandedGap) {
            header

            if let track = card.track {
                RideActivityRail(
                    progress: track,
                    leg: card.leg,
                    isStale: card.isStale,
                    headClearance: RideActivityMetrics.railDisc / 2
                )
            }

            bottomRow
        }
        .padding(.top, RideActivityMetrics.expandedPaddingTop)
        .padding(.bottom, RideActivityMetrics.expandedPaddingBottom)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: RideActivityMetrics.expandedHeaderGap) {
            HexLogo(size: RideActivityMetrics.expandedTile)

            VStack(alignment: .leading, spacing: RideActivityMetrics.expandedTextGap) {
                switch card.headline {
                case .countdown(let prefix, _):
                    Text(prefix)
                        .font(.system(size: RideActivityMetrics.expandedKickerSize))
                        .foregroundStyle(Color.mrtActivityIslandKicker)
                        .lineLimit(1)
                    if let place = card.secondLine {
                        RideActivitySecondLineView(
                            place: place,
                            size: RideActivityMetrics.expandedKickerSize
                        )
                    }
                case .sentence(let text):
                    Text(text)
                        .font(.system(size: RideActivityMetrics.expandedSentenceSize, weight: .medium))
                        .tracking(-0.25)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let place = card.secondLine {
                        RideActivitySecondLineView(
                            place: place,
                            size: RideActivityMetrics.expandedSecondLineSize
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch card.headline {
        case .countdown(_, let figure):
            HStack(alignment: .firstTextBaseline, spacing: RideActivityMetrics.expandedUnitGap) {
                Text(figure.value)
                    .font(.system(size: RideActivityMetrics.expandedValueSize, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.4)
                    .foregroundStyle(Color.mrtText)
                Text(figure.unit)
                    .font(.system(size: RideActivityMetrics.expandedUnitSize, weight: .medium))
                    .foregroundStyle(Color.mrtActivityTextSecondary)
            }
            .lineLimit(1)
            .fixedSize()

        case .sentence:
            RideActivityChip(card: card)
        }
    }

    /// The chip when the trailing slot is spoken for, the stale notice, or the
    /// affordance line — and NOTHING when none of the three applies.
    ///
    /// la-kit reserves a 20pt row unconditionally. We render it only when it has
    /// something in it: an empty band costs the island 20pt plus a 12pt gap, and the
    /// island's height is the system's to manage. This is the one place the port
    /// does not follow the kit's box model, and it is a subtraction rather than an
    /// invention.
    @ViewBuilder
    private var bottomRow: some View {
        let showsChip = isCountdown
        let showsStale = card.isStale
        let showsHint = !isCountdown && !card.isStale && card.track == nil

        if showsChip || showsStale || showsHint {
            HStack(spacing: RideActivityMetrics.expandedBottomGap) {
                if showsChip { RideActivityChip(card: card) }
                if showsStale {
                    Text(card.staleNoticeText)
                        .font(.system(size: RideActivityMetrics.staleTextSize))
                        .foregroundStyle(Color.mrtActivityTextQuiet)
                        .lineLimit(1)
                }
                if showsHint {
                    Text(RideActivityCopy.islandHint)
                        .font(.system(size: RideActivityMetrics.staleTextSize))
                        .foregroundStyle(Color.mrtActivityIslandHint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: RideActivityMetrics.expandedBottomMinHeight)
        }
    }

    private var isCountdown: Bool {
        if case .countdown = card.headline { return true }
        return false
    }
}
