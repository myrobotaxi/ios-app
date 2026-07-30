import SwiftUI

// MARK: - The 100%-FSD celebration, stated as data
//
// ## MYR-339 — a blend mode over MapKit is not a blend mode
//
// The client photographed his PHONE, not a screenshot, because a screenshot of
// this screen looked right: *"When I screenshot the page looks normal with the
// gold for 100% FSD, but on the actual app on my phone it's gold even overlaying
// the map."*
//
// The cause was the hero map tint. The prototype draws it as `mix-blend-mode:
// soft-light` over gold at α 0.5→0.85 (screens.jsx:885), and the port copied both
// the blend mode and those alphas verbatim. In CSS that is safe: the tint's
// parent (screens.jsx:873, `position: relative; z-index: 1; overflow: hidden`)
// creates a **stacking context**, which isolates the blend to a group of ordinary
// painted DOM. In SwiftUI the same layer sat in a plain `ZStack` directly above a
// `Map` — a UIKit-hosted `MKMapView` the system composites on its own surface. A
// blend mode there is resolved by whatever backdrop the compositor happens to
// have in hand, and when it has none the layer simply paints **source-over**:
// gold at α 0.5→0.85, flat across the map. Measured over the real hero pixels,
// that cost 45% of the map's contrast.
//
// MYR-339 fixed the compositing by pre-resolving the tint to normal blending at
// α 0.07→0.09.
//
// ## MYR-346 — the client rejected the aesthetic, not just the bug
//
// TestFlight, Jul 29, on the FIXED build: *"I know we fixed this and the
// prototype looks like this but it literally looks like someone puked on the
// screen and it's hard to read. I still want a special look to the page with 100%
// FSD but something cleaner with the gold. Try something cleaner, crisper, and
// more rewarding."* **Client outranks prototype** (standing precedent), and he
// said it twice.
//
// So the full-surface treatment is **gone entirely** — no hero map tint, no hero
// highlight, no page wash, no confetti. On a 100% drive the map, the header and
// every other tile render **exactly** as they do on a 97% drive. That is also the
// strongest possible form of the MYR-339 fix: the layer whose compositing was the
// defect no longer exists, so it cannot regress in any compositing environment.
//
// What is left is a celebration concentrated in the ELEMENTS, and shaped as a
// MOMENT on entry rather than a permanent state:
//
//   1. The ring **draws itself** in the app's own trace grammar — a bright
//      `goldTraceBright` head riding the leading edge (the ride-CTA
//      `MRTTraceBorder` / route-etch lineage) — ending in a brief glint at 12
//      o'clock, `momentDuration` (1.72s) from mount.
//   2. It **settles** to a slightly richer ring than the 97% variant: the same
//      gold, with a light highlight at 12 o'clock where the glint landed. Static.
//   3. The "100%" numeral and the "FULL SELF-DRIVING" kicker carry a permanent
//      gold gradient — but only inside the stat block.
//   4. One fine gold hairline replaces the stat card's neutral border. Static.
//
// Reduce Motion boots straight to the settled state: no draw, no glint.
//
// Nothing here needs a backdrop read, and nothing here is over the map.
public enum MRTDriveCelebration {

    // MARK: The predicate

    /// A drive celebrates only when it was flawless (screens.jsx:852 `isFull`).
    /// ONE definition, consumed by the ring, the tile and the screen, so the
    /// richer ring, the gold numeral and the gold hairline can never disagree
    /// about which drive they are decorating.
    public static func celebrates(fsdPercent: Int) -> Bool { fsdPercent >= 100 }

    // MARK: The entry moment

    /// Delay from mount to the ring starting to draw. This is the 97% ring's own
    /// sweep delay (screens.jsx:1115), unchanged — both variants draw on the
    /// identical schedule, and only the 100% one carries the head and the glint.
    public static let ringDrawDelay: Double = 0.12

    /// The draw itself — again the 97% ring's own duration, unchanged.
    public static let ringDrawDuration: Double = 1.15

    /// The glint's flare-and-fade once the head lands at 12 o'clock.
    public static let ringGlintDuration: Double = 0.45

    /// The whole moment, mount → settled. Deliberately short: the client asked
    /// for a moment, not a state.
    public static var momentDuration: Double {
        ringDrawDelay + ringDrawDuration + ringGlintDuration
    }

    /// When the head reaches 12 o'clock and the glint is armed.
    public static var glintOnset: Duration {
        .milliseconds(Int(((ringDrawDelay + ringDrawDuration) * 1000).rounded()))
    }

    /// cubic-bezier(0.32,0.72,0,1) — the prototype's own ring-sweep curve
    /// (screens.jsx:1115 `stroke-dashoffset 1.15s`). `nil` under Reduce Motion,
    /// so the ring snaps to its settled trim.
    public static func ringDrawAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: ringDrawDuration).delay(ringDrawDelay)
    }

    /// The glint's fade. `nil` under Reduce Motion — where the glint is never
    /// armed at all, so it is also never drawn.
    public static func ringGlintAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: ringGlintDuration)
    }

    /// The trace head's brightness: a short ramp off the start point so it does
    /// not pop into existence at 12 o'clock, times the glint's remaining life.
    /// Both inputs are clamped, so no animator sample can drive an out-of-range
    /// opacity (the MYR-227 lesson, kept).
    public static func headOpacity(drawProgress: Double, glintPhase: Double) -> Double {
        let ramp = min(1, max(0, drawProgress) * 12)
        return min(1, max(0, ramp * (1 - min(1, max(0, glintPhase)))))
    }

    /// The glint's flare — the head SWELLS as it burns out, so the moment ends on
    /// a brightening rather than on a fade.
    public static func glintScale(glintPhase: Double) -> Double {
        1 + 0.6 * min(1, max(0, glintPhase))
    }

    // MARK: Compositing (the MYR-339 invariant, kept)
    //
    // Nothing the celebration draws is over the map any more, so this is now
    // belt-and-braces rather than the fix itself. It stays a stored constant,
    // asserted by a test, because the ONE thing that caused MYR-339 was a blend
    // mode written as a literal in a view body.

    /// **This must stay `.normal`.** Any effect needing a backdrop read is
    /// forbidden on this screen.
    public static let celebrationBlendMode: BlendMode = .normal

    // MARK: The settled treatment

    /// The settled 100% ring: the same gold as the 97% ring, with a light
    /// highlight at the trim's origin — 12 o'clock, where the glint landed. The
    /// ring already carries a −90° rotation, so stop 0 lands at the top.
    ///
    /// Every stop is `gold` or LIGHTER, which is this gradient's readability
    /// rule: "richer" may never mean "dimmer than the 97% ring".
    public static let celebratedRingStops: [Gradient.Stop] = [
        .init(color: .mrtGoldLight, location: 0),
        .init(color: .mrtGold, location: 0.14),
        .init(color: .mrtGold, location: 0.86),
        .init(color: .mrtGoldLight, location: 1),
    ]

    public static var celebratedRingGradient: AngularGradient {
        AngularGradient(stops: celebratedRingStops, center: .center)
    }

    /// A faint static halo hugging the settled ring — the glint's residue, and
    /// all that is left of MYR-227's glow / ring-flash / 34-particle burst.
    /// Local to the ring, normal compositing, no motion.
    public static let celebratedRingHalo = Color.mrtGoldGlowFaint
    public static let celebratedRingHaloBlur: CGFloat = 5

    /// The celebrated "100%" numeral and "FULL SELF-DRIVING" kicker: struck-metal
    /// gold, `goldLight → gold → goldDeep`. The `goldDeep` stop is held to the
    /// bottom 30% so the gradient's mean luminance stays ABOVE flat gold's — the
    /// numeral gets richer without getting harder to read, which is the client's
    /// actual complaint.
    public static let celebratedTextStops: [Gradient.Stop] = [
        .init(color: .mrtGoldLight, location: 0),
        .init(color: .mrtGold, location: 0.7),
        .init(color: .mrtGoldDeep, location: 1),
    ]

    public static var celebratedTextGradient: LinearGradient {
        LinearGradient(stops: celebratedTextStops, startPoint: .top, endPoint: .bottom)
    }

    /// The stat card's border on a celebrated drive — `mrtBorder` → gold at low
    /// opacity (rgba(201,168,76,0.18), the existing `mrtGoldBorderQuiet`). One
    /// fine hairline; the card's fill, radius and geometry are untouched.
    public static let celebratedCardBorder = Color.mrtGoldBorderQuiet
}
