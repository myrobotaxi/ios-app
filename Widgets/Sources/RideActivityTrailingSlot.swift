import DesignSystem
import SwiftUI

// MARK: - The trailing slot's one rendering (MYR-398 §0 C/D + MYR-412 + MYR-420)
//
// ─────────────────────────────────────────────────────────────────────────────
// **THE SLOT IS A BARE GLYPH OR IT IS EMPTY. THERE IS NO RING ON THIS SURFACE.**
//
// §0 B built a progress ring for the half-pill v3 left empty; MYR-412 stripped its
// centre on the two trailing surfaces (*"why is there a circle around the hand thats
// not needed"*); **MYR-420 removed the ring outright, from all three.** The client's
// ruling, after the spinner he asked for was measured to be unbuildable here:
// *"remove the ring entirely then and if theres data it appears on the right side."*
//
// So there is one rendering of the ladder and one exception to it:
//
//   • `RideActivityIslandTrailingSlot` — the COMPACT trailing half-pill and the
//     EXPANDED `.trailing` region. The arrival glyph, or NOTHING AT ALL.
//   • `RideActivityIslandMark` — the MINIMAL island, which is a lone 37pt circle
//     another app's Activity leaves us. An empty slot there would be an empty
//     circle, so it renders the brand mark instead — the one thing on that surface
//     that says whose ride this is. §5's own centre composition, minus the ring that
//     used to be around it.
//
// **WHY THERE IS NO SPINNER, AND WHY THERE IS NOW NO RING**, is recorded in
// `design/Handoff-Live-Activity.md`'s MYR-420 mirror note: the four measurement
// rounds (§0 B's `repeatForever`, MYR-412's SF Symbol effects, MYR-417's timer ring
// and MYR-420's indeterminate `ProgressView`) and the ceiling they establish — **a
// self-updating element on this surface is a RAMP OVER A DATE RANGE, and a ramp
// cannot repeat.** It lives in the handoff rather than here because it outlived the
// component that carried it, and because the next person asked for motion on this
// surface will be reading the design mirror, not a deleted file.
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
// pure function of the resolved slot, and `.animation(_:value:)` fires only when it
// CHANGES. A re-push of the same completed frame changes nothing, so the beat is
// once-only by construction rather than by a flag somebody has to remember to clear.
// ─────────────────────────────────────────────────────────────────────────────

/// The compact island's trailing half-pill and the expanded island's `.trailing`
/// region: **a bare glyph, or nothing.**
///
/// One view for both, because the difference between them is two numbers and a
/// resolution — and two implementations of one rule are two ladders one edit apart
/// from disagreeing about a state, which is the mistake §0 D's single
/// `trailingSlot(…)` function exists to prevent one layer down.
///
/// **AN EMPTY SLOT RENDERS NOTHING, INCLUDING NO INSET.** The clear space belongs to
/// the glyph and is applied to the glyph, so the empty resolution has no size at all
/// and cannot widen the pill it sits in — an invisible 8pt box would be the ring's
/// footprint surviving the ring.
struct RideActivityIslandTrailingSlot: View {
    let slot: RideActivityTrailingSlot
    var waveSize: CGFloat = RideActivityMetrics.compactWaveGlyph
    var checkSize: CGFloat = RideActivityMetrics.compactCheckGlyph
    /// Clear space per side. The COMPACT slot pays it (MYR-412 — the region clips on
    /// the horizontal axis, and the client asked for room around this element); the
    /// EXPANDED slot passes 0 and keeps #168's own corner-safe padding at its call
    /// site.
    var horizontalInset: CGFloat = RideActivityMetrics.compactTrailingInset

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let glyph = slot.bareGlyph {
                RideActivityArrivalGlyph(
                    glyph: glyph,
                    size: size(for: glyph),
                    reduceMotion: reduceMotion
                )
                // ON THE GLYPH, not on the container — see the type's own note. The
                // padding is symmetric, so the glyph's centre and its scale
                // transition land exactly where MYR-412 measured them.
                .padding(.horizontal, horizontalInset)
            }
        }
        // The whole of §0 C that survives on a bare surface: whatever was there gives
        // way and the glyph lands a beat later. There is no completion sweep, because
        // there is no ring left anywhere for a glyph to sit inside.
        .mrtArrivalBeat(value: slot.bareGlyph, reduceMotion: reduceMotion)
        .accessibilityElement(children: .ignore)
        // **AN EMPTY SLOT IS NOT AN UNLABELLED ELEMENT — IT IS NOT AN ELEMENT.**
        // VoiceOver announcing "no route progress" over a slot that draws nothing
        // would be the deleted ring still talking.
        .accessibilityHidden(Self.accessibilityLabel(for: slot) == nil)
        .accessibilityLabel(Text(Self.accessibilityLabel(for: slot) ?? ""))
    }

    private func size(for glyph: RideActivityTrailingSlot.Glyph) -> CGFloat {
        switch glyph {
        case .wave: return waveSize
        case .check: return checkSize
        }
    }

    /// The board's two SF Symbols — real icons, not artwork.
    static func symbol(for glyph: RideActivityTrailingSlot.Glyph) -> String {
        switch glyph {
        case .wave: return "hand.wave.fill"
        case .check: return "checkmark.circle.fill"
        }
    }

    /// The slot renders no words, so the accessible name is the SENTENCE the same
    /// state puts on the card — never a second vocabulary invented for VoiceOver.
    /// `nil` where the slot draws nothing at all.
    static func accessibilityLabel(for slot: RideActivityTrailingSlot) -> String? {
        switch slot {
        case .figure(let figure):
            return figure
        case .glyph(.wave):
            return RideActivityCopy.arrivedHeadline
        case .glyph(.check):
            return RideActivityCopy.completedHeadline
        case .empty:
            return nil
        }
    }
}

// MARK: - The minimal island

/// **THE MARK, ALONE** — the minimal island's whole composition after MYR-420.
///
/// Minimal is the lone 37pt circle another app's Activity leaves us, so it is the one
/// surface an empty slot cannot serve: a blank circle says nothing, where the mark
/// says whose ride is running. §5's centre pair survives here unchanged (arrow 12,
/// glyph 13); the ring that used to enclose them does not.
///
/// It renders the FIGURE-LESS resolution, for the obvious reason: `3:42 PM` does not
/// fit in a 37pt circle, and the ladder's answer to "no figure here" is already
/// written down.
struct RideActivityIslandMark: View {
    let slot: RideActivityTrailingSlot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let glyph = slot.bareGlyph {
                RideActivityArrivalGlyph(
                    glyph: glyph,
                    size: RideActivityMetrics.minimalGlyph,
                    reduceMotion: reduceMotion
                )
            } else {
                ArrowMarkEast(size: RideActivityMetrics.minimalArrow)
                    .transition(.opacity)
            }
        }
        // THE SAME BEAT THE TRAILING SLOTS RUN, and it is the same call because it is
        // the same rule: the arrow leaves as the glyph springs in over it. Before
        // MYR-420 this surface ran a longer version of it, waiting out a ring
        // completion and fade that no longer happen anywhere.
        .mrtArrivalBeat(value: slot.bareGlyph, reduceMotion: reduceMotion)
    }
}

// MARK: - The one glyph, and the one beat

/// The arrival glyph itself. **WHITE** — gold stays the route's; the rail is the only
/// thing on these surfaces that carries the accent.
private struct RideActivityArrivalGlyph: View {
    let glyph: RideActivityTrailingSlot.Glyph
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Image(systemName: RideActivityIslandTrailingSlot.symbol(for: glyph))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.mrtText)
            // 0.6 → 1.0 on the client's own spring. **REDUCE MOTION GETS `.identity`**
            // — the glyph is simply there.
            .transition(
                reduceMotion
                    ? .identity
                    : .scale(scale: RideActivityMetrics.arrivalGlyphFromScale)
                        .combined(with: .opacity)
            )
    }
}

private extension View {
    /// §0 C, as one modifier, so the three surfaces cannot drift into three beats.
    func mrtArrivalBeat(
        value: RideActivityTrailingSlot.Glyph?,
        reduceMotion: Bool
    ) -> some View {
        animation(
            reduceMotion
                ? nil
                : .spring(
                    response: RideActivityMetrics.arrivalSpringResponse,
                    dampingFraction: RideActivityMetrics.arrivalSpringDamping
                )
                .delay(RideActivityMetrics.arrivalGlyphDelay),
            value: value
        )
    }
}
