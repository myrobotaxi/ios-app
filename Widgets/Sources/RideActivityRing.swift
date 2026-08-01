import DesignSystem
import SwiftUI

// MARK: - The progress ring (MYR-398 §0 B + §0 C)
//
// ─────────────────────────────────────────────────────────────────────────────
// **ONE COMPONENT, THREE SURFACES, THREE STATES — AND IT EXISTS BECAUSE THE SLOT
// USED TO BE EMPTY.**
//
// v3's compact island was "a figure or nothing", and "nothing" is a large share of
// the fourteen rows: Dispatch, both no-ETA states, the no-telemetry state and every
// ending. The client's screenshots show what that reads as on a live ride the car
// has not reported from yet — a bare mark and an empty half-pill, which is
// indistinguishable from an app that has stopped working. The ring fills exactly
// that space and never any other: **it never displaces a number** (§0 D).
//
// WHAT IT SAYS, IN THREE MODES:
//
//   • **determinate** — a gold arc of the RAIL'S OWN fraction. One source for the
//     card's rail and the island's ring, so the two surfaces cannot disagree about
//     how far along one leg is. Floored at 2% so a round cap is visible at all.
//   • **indeterminate** — a 25% arc turning on a 1.4s linear loop. This is the
//     substance of §0 B: "waiting on the car" versus "the app is dead". It is a
//     VIEW-LOCAL animation and therefore costs NO push budget — nothing about it
//     comes off the wire, so no update is needed to keep it moving.
//   • **track only** — an ended ride. Nothing is in progress and nothing is coming.
//
// WHAT DECIDES WHICH: nothing in this file. `RideActivityCard.resolve` hands over a
// `RideActivityTrailingSlot` and this view lays it out, the same split every other
// element on this surface keeps.
//
// ⚠️ **THE ARRIVAL BEAT IS KEYED TO THE CONTENT STATE, NEVER TO `onAppear`.**
// ActivityKit re-renders on every content update and the ticker re-pushes the same
// terminal state for the whole linger, so a beat armed by the view's appearance
// would either replay on every push or — worse, since the view is already on screen
// when the terminal state lands — never play at all. Every value the beat animates
// (`arcFraction`, `isLanded`) is a pure function of the resolved slot, and
// `.animation(_:value:)` fires only when one of them CHANGES. A re-push of the same
// completed frame changes neither, so the beat is once-only by construction rather
// than by a flag somebody has to remember to clear.
// ─────────────────────────────────────────────────────────────────────────────

struct RideActivityProgressRing: View {
    let slot: RideActivityTrailingSlot
    var diameter: CGFloat = RideActivityMetrics.ringDiameter
    var stroke: CGFloat = RideActivityMetrics.ringStroke

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
                    diameter: diameter,
                    spins: isSpinning,
                    isLanded: isLanded,
                    reduceMotion: reduceMotion
                )
                // THE SPIN NEEDS A NEW VIEW AND THE BEAT NEEDS THE SAME ONE.
                //
                // The rotation is armed in `onAppear`, which fires when the arc is
                // INSERTED — so entering the indeterminate mode has to be an
                // insertion. Keying identity on `isSpinning` alone gives exactly
                // that, and leaves determinate → glyph on ONE identity, which is
                // what lets the arc animate from `p` to 1 rather than being
                // replaced at full length.
                .id(isSpinning)
            }

            centre
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityLabel(for: slot)))
    }

    // MARK: - What the slot means to this view

    /// `nil` where no arc is drawn at all — the ended states, and the compact
    /// slot's figure (which is not this view's business, but the mapping is total
    /// on purpose: a slot this view cannot render is a slot somebody added without
    /// deciding what it looks like).
    private var arcFraction: Double? {
        switch slot {
        case .figure, .ringTrackOnly:
            return nil
        case .ringIndeterminate:
            // A FULL circle, drawn DASHED — see `RideActivityRingArc` for why the
            // handoff's quarter arc could not survive contact with ActivityKit.
            return 1
        case .ringDeterminate(let progress):
            return min(1, max(0, progress))
        case .glyph:
            // **THE LEG IS OVER, SO THE RING IS FULL** — and it completes to full
            // from wherever the previous frame left it, which is the first half of
            // the §0 C beat.
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

    // MARK: - The centre

    /// The east arrow, or the arrival glyph that replaces it.
    ///
    /// **BOTH ARE WHITE** (the glyph explicitly so — "gold stays the route's"), and
    /// the swap is the second half of the beat: the arrow leaves as the glyph
    /// springs in over the faded ring.
    @ViewBuilder
    private var centre: some View {
        ZStack {
            if let glyph {
                Image(systemName: Self.symbol(for: glyph))
                    .font(.system(size: RideActivityMetrics.ringGlyph, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                    // 0.6 → 1.0 on the client's own spring. **REDUCE MOTION GETS
                    // `.identity`** — the glyph is simply there, which is §0 C's own
                    // fallback and the repo's standing rule.
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

    /// The ring renders no words, so the accessible name is the SENTENCE the same
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

/// The gold half of the ring — one view for all three modes, so the completion
/// sweep of the §0 C beat has something to animate FROM.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ⚠️ **THE WAITING ARC IS DASHED, AND THAT IS A MEASURED DEVIATION FROM §0 B.**
///
/// §0 B asks for a 25% arc rotating at 1.4s linear, `repeatForever`, armed from the
/// view. It is implemented below — and **ActivityKit does not run it.** Measured on
/// this branch, iOS 26.5 simulator: six `simctl io screenshot`s 0.3s apart over a
/// live `noTelemetry` Activity are BYTE-IDENTICAL (`ImageChops.difference` bbox
/// `None` across all five pairs), i.e. the arc never moves. That is the documented
/// behaviour rather than a bug in the loop: a Live Activity's view is rendered by the
/// system out of process, animations that start on APPEARANCE are not run, and
/// repeating animations are not run at all. The only animations that DO run are the
/// ones a content UPDATE triggers, which is exactly why the rail's travel and the
/// §0 C beat work.
///
/// **A STATIC QUARTER ARC IS NOT A NEUTRAL FALLBACK — IT IS A WRONG NUMBER.** It is
/// pixel-for-pixel what `ringDeterminate(0.25)` draws, so the state that means "the
/// car has reported NOTHING" would render as "a quarter of the way there", on the
/// same frame whose CARD is drawing the idle rail: two surfaces contradicting each
/// other about one leg, which is the one thing §0 B's single-source rule exists to
/// prevent.
///
/// So the waiting state is drawn as a DASHED FULL RING instead. It cannot be read as
/// a fraction from any angle, it is unmistakably not the determinate arc, and it
/// keeps the client's actual requirement — "waiting on the car" is visibly different
/// from "the app is dead". The rotation is left applied to it: it costs nothing, it
/// is what the handoff asks for, and the day the platform runs it the dashes chase
/// round the ring with no code change. The dash period is derived from the diameter
/// so the seam lands exactly at 12 o'clock at both sizes.
/// ─────────────────────────────────────────────────────────────────────────────
private struct RideActivityRingArc: View {
    let fraction: Double
    let stroke: CGFloat
    let diameter: CGFloat
    let spins: Bool
    let isLanded: Bool
    let reduceMotion: Bool

    /// The indeterminate mode's rotation — see the note above for what the platform
    /// currently does with it.
    @State private var turn: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(Color.mrtGold, style: strokeStyle)
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
            // **12 O'CLOCK IS THE START.** SwiftUI trims from 3 o'clock, so the
            // −90° is the design's starting point rather than a decoration; the
            // spin rides on top of it.
            .rotationEffect(.degrees(-90 + turn))
            // The ring stops being the subject once the glyph is in it.
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

    /// Solid for a measurement, dashed for the absence of one.
    private var strokeStyle: StrokeStyle {
        guard spins else {
            return StrokeStyle(lineWidth: stroke, lineCap: .round)
        }
        // The period divides the circumference a whole number of times, so the seam
        // sits at 12 o'clock rather than wherever the arithmetic landed.
        let period = .pi * diameter / RideActivityMetrics.ringWaitingDashCount
        return StrokeStyle(
            lineWidth: stroke,
            lineCap: .round,
            dash: [period * RideActivityMetrics.ringWaitingDashDuty, period * (1 - RideActivityMetrics.ringWaitingDashDuty)]
        )
    }
}
