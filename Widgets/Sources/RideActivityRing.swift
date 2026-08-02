import DesignSystem
import SwiftUI

// MARK: - The trailing slot's two renderings (MYR-398 §0 B/C + MYR-412)
//
// ─────────────────────────────────────────────────────────────────────────────
// **THE SLOT IS A BARE GLYPH OR A BARE RING — EXCEPT ON THE MINIMAL ISLAND.**
//
// §0 B built ONE component for three surfaces: a ring with the east arrow in its
// centre, and the arrival glyph replacing that arrow at the two stops. The client's
// board (MYR-412, the "ENROUTE · NO TELEMETRY" mock he sent to prove it) reads the
// compact island the other way round:
//
//   LEADING   the east arrow — as shipped
//   TRAILING  a BARE ring: solid track, partial gold arc, **nothing inside it**
//
// and at the two stops, a BARE glyph — *"why is there a circle around the hand thats
// not needed"*. So there are two renderings of one resolution, not one:
//
//   • `RideActivityIslandTrailingSlot` — the COMPACT trailing half-pill and the
//     EXPANDED `.trailing` region. Glyph OR ring, never both, nothing in the ring's
//     centre.
//   • `RideActivityProgressRing(centre: .mark)` — the MINIMAL island, which keeps the
//     centre content. That reading stands and is not an oversight: minimal is the
//     lone 37pt circle another app's Activity leaves us, and the mark inside the ring
//     is the only thing on it that says whose ride this is. The handoff's own §5
//     spells it out — "Minimal 37×37 · ring d24 · center arrow 12 / glyph 13".
//
// WHAT DECIDES WHICH RESOLUTION: nothing in this file. `RideActivityCard.resolve`
// hands over a `RideActivityTrailingSlot` and these views lay it out — the same split
// every other element on this surface keeps, and the reason the §0 D ladder is
// assertable at all.
//
// ⚠️ **THE ARRIVAL BEAT IS KEYED TO THE CONTENT STATE, NEVER TO `onAppear`.**
// ActivityKit re-renders on every content update and the ticker re-pushes the same
// terminal state for the whole linger, so a beat armed by the view's appearance would
// either replay on every push or — worse, since the view is already on screen when
// the terminal state lands — never play at all. Every value the beat animates is a
// pure function of the resolved slot, and `.animation(_:value:)` fires only when one
// of them CHANGES. A re-push of the same completed frame changes neither, so the beat
// is once-only by construction rather than by a flag somebody has to remember to
// clear.
// ─────────────────────────────────────────────────────────────────────────────

/// The compact island's trailing half-pill and the expanded island's `.trailing`
/// region: **a bare glyph, or a bare ring.**
///
/// One view for both, because the difference between them is four numbers and a
/// resolution — and two implementations of "glyph or ring" are two ladders one edit
/// apart from disagreeing about a state, which is the mistake §0 D's single
/// `trailingSlot(…)` function exists to prevent one layer down.
struct RideActivityIslandTrailingSlot: View {
    let slot: RideActivityTrailingSlot
    var diameter: CGFloat = RideActivityMetrics.ringDiameterCompact
    var stroke: CGFloat = RideActivityMetrics.ringStrokeCompact
    var waveSize: CGFloat = RideActivityMetrics.compactWaveGlyph
    var checkSize: CGFloat = RideActivityMetrics.compactCheckGlyph
    /// Clear space per side. The COMPACT slot pays it (MYR-412 — the region clips on
    /// the horizontal axis and a centred stroke reaches outside its own frame); the
    /// EXPANDED slot passes 0 and keeps #168's own corner-safe padding at its call
    /// site, which already exceeds the overhang.
    var horizontalInset: CGFloat = RideActivityMetrics.compactTrailingInset

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let glyph = arrivalGlyph {
                Image(systemName: RideActivityProgressRing.symbol(for: glyph))
                    .font(.system(size: size(for: glyph), weight: .semibold))
                    // WHITE. Gold stays the route's — the rail and the ring's arc are
                    // the only things on these four surfaces that carry the accent.
                    .foregroundStyle(Color.mrtText)
                    // 0.6 → 1.0 on the client's own spring. **REDUCE MOTION GETS
                    // `.identity`** — the glyph is simply there.
                    .transition(
                        reduceMotion
                            ? .identity
                            : .scale(scale: RideActivityMetrics.arrivalGlyphFromScale)
                                .combined(with: .opacity)
                    )
            } else {
                RideActivityProgressRing(
                    slot: slot,
                    diameter: diameter,
                    stroke: stroke,
                    centre: .bare
                )
                .transition(.opacity)
            }
        }
        // The whole of §0 C that survives on a bare surface: the ring gives way and
        // the glyph lands a beat later. There is no completion sweep here because
        // there is no ring left for the glyph to sit inside — see
        // `bareArrivalGlyphDelay`.
        .animation(
            reduceMotion
                ? nil
                : .spring(
                    response: RideActivityMetrics.arrivalSpringResponse,
                    dampingFraction: RideActivityMetrics.arrivalSpringDamping
                )
                .delay(RideActivityMetrics.bareArrivalGlyphDelay),
            value: arrivalGlyph
        )
        // **THE INSET IS THE MYR-412 CLIPPING FIX AND IT IS HORIZONTAL ONLY**, because
        // that is the axis the measurement showed being cut: the ring's ink came back
        // 23.00pt wide (the declared 22pt frame plus antialiasing) and 24.0-24.67pt
        // tall (the honest 22 + stroke). A vertical inset would buy nothing and would
        // move an element that is not being clipped.
        .padding(.horizontal, horizontalInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(RideActivityProgressRing.accessibilityLabel(for: slot)))
    }

    private var arrivalGlyph: RideActivityTrailingSlot.Glyph? {
        if case .glyph(let glyph) = slot { return glyph }
        return nil
    }

    private func size(for glyph: RideActivityTrailingSlot.Glyph) -> CGFloat {
        switch glyph {
        case .wave: return waveSize
        case .check: return checkSize
        }
    }
}

// MARK: - The ring

/// **THE RING, AND IT EXISTS BECAUSE THE SLOT USED TO BE EMPTY.**
///
/// v3's compact island was "a figure or nothing", and "nothing" is a large share of
/// the fourteen rows: Dispatch, both no-ETA states, the no-telemetry state and every
/// ending. The client's screenshots show what that reads as on a live ride the car
/// has not reported from yet — a bare mark and an empty half-pill, which is
/// indistinguishable from an app that has stopped working. The ring fills exactly
/// that space and never any other: **it never displaces a number** (§0 D).
///
/// WHAT IT SAYS, IN THREE MODES:
///
///   • **determinate** — a gold arc of the RAIL'S OWN fraction. One source for the
///     card's rail and the island's ring, so the two surfaces cannot disagree about
///     how far along one leg is. Floored at 2% so a round cap is visible at all.
///   • **indeterminate** — the board's loading ring: solid track, a partial gold arc,
///     round cap, from 12 o'clock. "Waiting on the car" rather than "the app is
///     dead". See `RideActivityRingArc` for what the platform does with the rotation
///     this was designed to have.
///   • **track only** — an ended ride. Nothing is in progress and nothing is coming.
struct RideActivityProgressRing: View {
    /// What sits in the middle of the ring.
    enum Centre {
        /// The east arrow, swapped for the arrival glyph at the two stops. **The
        /// MINIMAL island only** — see the file header.
        case mark
        /// Nothing at all: the board's bare loading ring (MYR-412). The two island
        /// trailing slots, which draw the arrival glyph instead of the ring rather
        /// than inside it.
        case bare
    }

    let slot: RideActivityTrailingSlot
    var diameter: CGFloat = RideActivityMetrics.ringDiameter
    var stroke: CGFloat = RideActivityMetrics.ringStroke
    /// Defaults to the MINIMAL island's composition, which is the only surface that
    /// still has one.
    var centre: Centre = .mark

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // **THE WAITING RING IS THE SYSTEM'S, AND THAT IS WHY IT MOVES**
            // (MYR-417). It draws its own track, so it replaces the pair below
            // rather than layering over it. Reduce Motion keeps the static arc,
            // which is exactly what shipped before this issue.
            if isWaiting, !reduceMotion {
                RideActivityWaitingRing()
            } else {
                // The track. Drawn in EVERY other mode, which is what makes "never
                // empty" structural: the ended states are this circle and nothing
                // else.
                Circle()
                    .stroke(
                        Color.mrtActivityRingTrack,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )

                if let arc = arcFraction {
                    RideActivityRingArc(
                        fraction: arc,
                        stroke: stroke,
                        isLanded: isLanded,
                        reduceMotion: reduceMotion
                    )
                }
            }

            if centre == .mark { markCentre }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityLabel(for: slot)))
    }

    // MARK: - What the slot means to this view

    /// `nil` where no arc is drawn at all — the ended states, and the compact slot's
    /// figure (which is not this view's business, but the mapping is total on
    /// purpose: a slot this view cannot render is a slot somebody added without
    /// deciding what it looks like).
    private var arcFraction: Double? {
        switch slot {
        case .figure, .ringTrackOnly:
            return nil
        case .ringIndeterminate:
            return RideActivityMetrics.ringIndeterminateArc
        case .ringDeterminate(let progress):
            return min(1, max(0, progress))
        case .glyph:
            // **THE LEG IS OVER, SO THE RING IS FULL** — and it completes to full from
            // wherever the previous frame left it, which is the first half of the
            // §0 C beat. Only reachable with `centre == .mark`: the bare surfaces
            // route a `.glyph` slot away from this view entirely.
            return 1
        }
    }

    /// The one mode MYR-417 hands to the system's own timer-driven ring.
    private var isWaiting: Bool {
        if case .ringIndeterminate = slot { return true }
        return false
    }

    private var isLanded: Bool {
        if case .glyph = slot { return true }
        return false
    }

    private var glyph: RideActivityTrailingSlot.Glyph? {
        if case .glyph(let glyph) = slot { return glyph }
        return nil
    }

    // MARK: - The centre (minimal island only)

    /// The east arrow, or the arrival glyph that replaces it.
    ///
    /// **BOTH ARE WHITE** (the glyph explicitly so — "gold stays the route's"), and
    /// the swap is the second half of the beat: the arrow leaves as the glyph springs
    /// in over the faded ring.
    @ViewBuilder
    private var markCentre: some View {
        ZStack {
            if let glyph {
                Image(systemName: Self.symbol(for: glyph))
                    .font(.system(size: RideActivityMetrics.ringGlyph, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .scale(scale: RideActivityMetrics.arrivalGlyphFromScale)
                                .combined(with: .opacity)
                    )
            } else {
                ArrowMarkEast(size: RideActivityMetrics.ringArrow)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion
                ? nil
                : .spring(
                    response: RideActivityMetrics.arrivalSpringResponse,
                    dampingFraction: RideActivityMetrics.arrivalSpringDamping
                )
                .delay(RideActivityMetrics.arrivalGlyphDelay),
            value: isLanded
        )
    }

    // MARK: - Names

    /// The board's two SF Symbols — real icons, not artwork.
    static func symbol(for glyph: RideActivityTrailingSlot.Glyph) -> String {
        switch glyph {
        case .wave: return "hand.wave.fill"
        case .check: return "checkmark.circle.fill"
        }
    }

    /// The slot renders no words, so the accessible name is the SENTENCE the same
    /// state puts on the card — never a second vocabulary invented for VoiceOver.
    static func accessibilityLabel(for slot: RideActivityTrailingSlot) -> String {
        switch slot {
        case .figure(let figure):
            return figure
        case .glyph(.wave):
            return RideActivityCopy.arrivedHeadline
        case .glyph(.check):
            return RideActivityCopy.completedHeadline
        case .ringDeterminate(let progress):
            return "\(Int((min(1, max(0, progress)) * 100).rounded()))% of the way there"
        case .ringIndeterminate:
            return "Waiting for your ride's position"
        case .ringTrackOnly:
            return "No route progress"
        }
    }
}

// MARK: - The waiting ring · MYR-417

/// **THE ONE THING ON THIS SURFACE THAT MOVES, AND IT IS NOT AN ANIMATION.**
///
/// ─────────────────────────────────────────────────────────────────────────────
/// §0 B measured that ActivityKit runs no `repeatForever` and no appearance-armed
/// animation; MYR-412 measured that it runs no SF Symbol effect either. Both were
/// right about their mechanism and both drew the general conclusion — that this
/// surface cannot move — which is **false**, and the client's video of a dead ring
/// is what forced the third measurement.
///
/// A Live Activity's view is rendered OUT OF PROCESS from an archived view tree, so
/// nothing the app animates is ever run. But two of SwiftUI's elements are not
/// animated by the app at all: they carry a DATE RANGE and the system re-derives
/// them as the clock moves. `Text(timerInterval:)` is the one everybody knows.
/// **`ProgressView(timerInterval:countsDown:)` is the other, and in the circular
/// style it is a ring** — which is what this state needed all along.
///
/// **MEASURED, ON A LIVE ACTIVITY IN THIS VERY SLOT** (iPhone 17 Pro, iOS 26.5,
/// `MRT_ACTIVITY_STATE=noTelemetry`, frames 8s apart): the gold arc's bright-ink
/// pixel count goes **102 → 202 → 304**. For comparison, a CUSTOM `ProgressViewStyle`
/// wrapping the identical `ProgressView` is **inert** — `configuration
/// .fractionCompleted` is `nil` there, so the style draws the floor arc and never
/// moves. That is the whole reason this is the stock style with a tint rather than
/// the board's own `Circle().trim`: **the moment the ring's geometry becomes ours,
/// the motion stops being the system's.**
///
/// **THE TWO EMPTY LABELS ARE LOAD-BEARING.** The default composition puts the
/// system's own timer TEXT in the middle of the ring ("0:27", counting the window
/// nobody asked about). `.labelsHidden()` does NOT remove it — measured, same slot,
/// same build. Supplying `label:` and `currentValueLabel:` as `EmptyView()` does,
/// and the arc keeps animating, which is the board's bare ring exactly.
///
/// **WHAT THE STOCK STYLE COSTS US**, stated rather than glossed: the stroke is the
/// system's (measured 2.0pt inside a 22pt frame against the board's 2.2) and so is
/// the TRACK, which comes out as the tint at ~35% (rgb 70,59,27) where the board's
/// is white 20% (rgb 51,51,51). The arc itself is `.tint`ed and measures **rgb(201,
/// 168, 76) — `#C9A84C`, `mrtGold` exactly** — round-capped and starting at 12
/// o'clock, i.e. the board's own arc. And unlike `Circle().stroke` it draws INSIDE
/// its frame (measured 22.0 × 22.0pt of ink for a 22pt frame), so MYR-412's
/// clipping trap does not apply to it.
///
/// ⚠️ **MYR-420 — THE CLIENT REJECTED THIS RING AND THE REPLACEMENT DOES NOT EXIST.**
/// *"The loading icon should just be a ring spinning not slowly filling. It
/// essentially means we're waiting for live data."* The objection is exact: a ring
/// creeping 0 → 100% over 90s is the DETERMINATE ring's own grammar, spent on the one
/// state that means the car has said nothing.
///
/// The last untested candidate was the plain indeterminate
/// `ProgressView().progressViewStyle(.circular)` — a fair hypothesis, since the timer
/// ring below proves the surface runs SOME stock `ProgressView` behaviour. **Measured
/// in this exact slot on a live Activity and it is dead twice over**: WidgetKit draws
/// the indeterminate circular style as an EMPTY GAUGE RING (no spokes at all — the
/// tint at ~35%, i.e. the track the ended states already draw), and it never moves —
/// 5 lossless frames 12s apart, bbox `None`, max delta 0, 185 gold px in every one,
/// with `.fixedSize()` byte-identical so the 22pt parent frame was not the reason.
/// The control is this file's own `ProgressView(timerInterval:)` in the same build
/// and slot: 297 → 457 → 618 → 775 → 935 px across the identical frames.
///
/// **THE CEILING, STATED SO IT IS NOT RE-DISCOVERED: a self-updating element here is
/// a RAMP OVER A DATE RANGE, and a ramp cannot repeat.** Everything the renderer
/// re-derives out of process is the dynamic-date family plus this `ProgressView`, all
/// monotone in the clock over a range fixed when the frame composes. A spinner needs
/// a REPEATING clock and only the app can arm one, which is what §0 B and MYR-412
/// each measured inert. This surface can fill, drain or travel ONCE per push interval
/// (60–90s); it cannot spin. So this ring stands unchanged until the client chooses
/// between it and MYR-412's static arc — the two real options, neither invented.
/// ─────────────────────────────────────────────────────────────────────────────
private struct RideActivityWaitingRing: View {
    var body: some View {
        // A ROLLING WINDOW, OPENED WHEN THIS FRAME IS COMPOSED. Every content-state
        // update re-composes the view and therefore restarts it, which is what makes
        // the arc read as a loop rather than as a fill that finished. `Date()` here
        // is NOT the clock the client's ETA ruling bans: nothing about this ring is
        // derived from ride data, and it makes no claim about when anything arrives.
        let now = Date()
        ProgressView(
            timerInterval: now...now.addingTimeInterval(RideActivityMetrics.waitingWindow),
            countsDown: false,
            label: { EmptyView() },
            currentValueLabel: { EmptyView() }
        )
        .progressViewStyle(.circular)
        .tint(Color.mrtGold)
    }
}

// MARK: - The arc

/// The gold half of the ring — one view for all three modes, so the completion sweep
/// of the §0 C beat has something to animate FROM.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ⚠️ **NOTHING ANIMATES THIS ARC ON ITS OWN, AND MYR-412 CLOSED THE LAST ROUTE.**
///
/// §0 B asks for a 25% arc rotating at 1.4s linear, `repeatForever`, armed from the
/// view. It is implemented below and **ActivityKit does not run it** — measured on the
/// #168 build, six `simctl io` frames 0.3s apart over a live `noTelemetry` Activity,
/// `ImageChops.difference` bbox `None` across all five pairs. A Live Activity's view
/// is rendered by the system out of process; animations armed on APPEARANCE are not
/// run and repeating ones are not run at all. The only animations that DO run are the
/// ones a content UPDATE triggers, which is why the rail's travel and the §0 C beat
/// work.
///
/// **MYR-412 TESTED THE OTHER MECHANISM, BECAUSE SF SYMBOL EFFECTS ARE NOT
/// `withAnimation`.** Symbol effects are declared on the symbol and driven by the
/// rendering system rather than by a SwiftUI animation transaction, so they were
/// genuinely worth a measurement rather than an assumption. Three of them were
/// rendered in this very slot on a live Activity —
/// `Image("progress.indicator").symbolEffect(.variableColor.iterative.reversing)`,
/// `Image("ellipsis").symbolEffect(.variableColor.iterative)` and
/// `Image("arrow.trianglehead.clockwise").symbolEffect(.rotate)` (iOS 18+). All three
/// DRAW (the spokes, the dots and the arrow are all in frame, confirming the symbols
/// resolve and the modifier is not refusing the build) and **none of them moves**:
/// 12 frames ~130ms apart spanning 1.52s, plus a 10-frame run a minute earlier, all
/// byte-identical — bbox `None`, max delta 0, including frame 1 of the first run
/// against frame 12 of the second. Every spoke of `progress.indicator` renders at
/// full opacity, which is the inert base state of `.variableColor`.
///
/// **SO THE WAITING RING IS STATIC, AND IT IS THE BOARD'S OWN ARC.** §0 B's first
/// implementation drew it DASHED, on the reasoning that a static quarter arc is
/// pixel-for-pixel `ringDeterminate(0.25)`. The client overruled that with the mock in
/// hand — *"it should just be a loading icon bc no data from telemetry was found"* —
/// and MYR-412's instruction is explicit: solid track, ~25-35% gold arc, round cap,
/// **never dashes**.
///
/// ⚠️ **MYR-417 FOUND THE MECHANISM, AND IT IS NOT AN ANIMATION AT ALL.** Both
/// measurements above stand; the general conclusion drawn from them ("this surface
/// cannot move") does not. The system's own TIMER-DRIVEN elements are re-derived by
/// the renderer from a date range rather than animated by the app, and
/// `ProgressView(timerInterval:)` in the circular style is one of them — see
/// `RideActivityWaitingRing`, which now owns the `.ringIndeterminate` mode whenever
/// Reduce Motion is off. **THE DEAD `repeatForever` ROTATION IS DELETED WITH IT**: a
/// mechanism that has been measured inert twice is not "kept applied in case", it is
/// dead code making a promise, and the promise now has a real implementation
/// elsewhere. This view keeps the DETERMINATE arc, the §0 C completion sweep, and
/// the static waiting arc that Reduce Motion falls back to.
/// ─────────────────────────────────────────────────────────────────────────────
private struct RideActivityRingArc: View {
    let fraction: Double
    let stroke: CGFloat
    let isLanded: Bool
    let reduceMotion: Bool

    var body: some View {
        Circle()
            .trim(from: 0, to: fraction)
            // SOLID AND ROUND-CAPPED IN EVERY MODE (MYR-412). There is one stroke
            // style on this surface now, so the waiting ring and the determinate ring
            // differ only in how much of the circle is drawn — which is what the
            // board shows.
            .stroke(Color.mrtGold, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            // The rail's own curve, on the rail's own duration — the ring and the
            // rail move together because they are drawing the same number.
            .animation(
                reduceMotion
                    ? nil
                    : .timingCurve(
                        0.2, 0.8, 0.2, 1,
                        duration: RideActivityMetrics.arrivalRingCompletion
                    ),
                value: fraction
            )
            // **12 O'CLOCK IS THE START.** SwiftUI trims from 3 o'clock, so the −90°
            // is the design's starting point rather than a decoration — and it is
            // also where the system's own timer ring starts, which is what lets the
            // Reduce Motion fallback and the moving ring read as one mark.
            .rotationEffect(.degrees(-90))
            // The ring stops being the subject once the glyph is in it. Only
            // reachable on the MINIMAL island, the one surface where the glyph lands
            // inside the ring.
            .opacity(isLanded ? RideActivityMetrics.arrivalRingSettledOpacity : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: RideActivityMetrics.arrivalRingFade)
                        .delay(RideActivityMetrics.arrivalRingFadeDelay),
                value: isLanded
            )
    }
}
