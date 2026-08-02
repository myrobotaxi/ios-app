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
            // The track. Drawn in EVERY mode, which is what makes "never empty"
            // structural: the ended states are this circle and nothing else.
            Circle()
                .stroke(
                    Color.mrtActivityRingTrack,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )

            if let arc = arcFraction {
                RideActivityRingArc(
                    fraction: arc,
                    stroke: stroke,
                    spins: isSpinning,
                    isLanded: isLanded,
                    reduceMotion: reduceMotion
                )
                // THE SPIN NEEDS A NEW VIEW. The rotation is armed in `onAppear`,
                // which fires when the arc is INSERTED — so entering the
                // indeterminate mode has to be an insertion. Keying identity on
                // `isSpinning` alone gives exactly that, and leaves determinate →
                // glyph on ONE identity, which is what lets the arc animate from `p`
                // to 1 rather than being replaced at full length.
                .id(isSpinning)
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

    private var isSpinning: Bool {
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
/// **never dashes**. The rotation stays applied: it costs nothing, and the day the
/// platform runs a repeating animation here this state becomes §0 B exactly.
/// ─────────────────────────────────────────────────────────────────────────────
private struct RideActivityRingArc: View {
    let fraction: Double
    let stroke: CGFloat
    let spins: Bool
    let isLanded: Bool
    let reduceMotion: Bool

    /// The indeterminate mode's rotation — see the note above for what the platform
    /// currently does with it.
    @State private var turn: Double = 0

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
            // is the design's starting point rather than a decoration; the spin rides
            // on top of it.
            .rotationEffect(.degrees(-90 + turn))
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
            .onAppear {
                guard spins, !reduceMotion else { return }
                withAnimation(
                    .linear(duration: RideActivityMetrics.ringSpin)
                        .repeatForever(autoreverses: false)
                ) {
                    turn = 360
                }
            }
    }
}
