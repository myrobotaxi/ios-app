import SwiftUI

// MARK: - MYR-339 — the 100%-FSD celebration's compositing, stated as data
//
// The client photographed his PHONE because a screenshot of this screen looks
// right: *"When I screenshot the page looks normal with the gold for 100% FSD,
// but on the actual app on my phone it's gold even overlaying the map."*
//
// The cause was the hero map tint (`DriveSummaryScreen`). The prototype draws it
// as `mix-blend-mode: soft-light` over gold at α 0.5→0.85 (screens.jsx:885), and
// the port copied both the blend mode and those alphas verbatim. In CSS that is
// safe: the tint's parent (screens.jsx:873, `position: relative; z-index: 1;
// overflow: hidden`) creates a **stacking context**, which isolates the blend to
// a group of ordinary painted DOM. In SwiftUI the same layer sits in a plain
// `ZStack` directly above a `Map` — a UIKit-hosted `MKMapView` that the system
// composites on its own surface. A blend mode there is resolved by whatever
// backdrop the compositor happens to have in hand, and when it has none the
// layer simply paints **source-over** — gold at α 0.5→0.85, flat across the map.
//
// Measured over the real hero pixels (see the PR body):
//
//   map, un-tinted        mean RGB (27, 37, 53)   luminance 0.143  contrast 0.109
//   prototype soft-light  mean RGB (44, 48, 43)   luminance 0.184  contrast 0.112
//   blend dropped         mean RGB (145,127, 70)  luminance 0.496  contrast 0.060
//
// The third row is the photo: 3.5× the luminance and 45% of the map's contrast
// gone. A still cannot catch it, because a screenshot is taken by flattening the
// whole layer tree into one offscreen buffer — a pass in which the backdrop IS
// available and the blend DOES resolve.
//
// So the tint no longer asks a blend mode to resolve at all. It is the same
// treatment, **pre-resolved to normal compositing**: the single gold opacity ramp
// that best reproduces soft-light's own output over this hero (least squares over
// the real pixels — 0.084 → 0.076, taken as the prototype's own downward ramp
// 0.07 → 0.09). That lands mean luminance 0.184 (prototype: 0.184) and keeps 90%
// of the map's contrast, and — the point — it has no failure mode, because normal
// compositing needs no backdrop read.
public enum MRTDriveCelebration {

    // MARK: Hero map tint (screens.jsx:885)

    /// Gold opacity at the TOP of the hero tint. Resolved from the prototype's
    /// soft-light output; see the note above.
    public static let heroTintTopOpacity: Double = 0.07
    /// Gold opacity at the BOTTOM of the hero tint.
    public static let heroTintBottomOpacity: Double = 0.09

    /// The hero tint's blend mode. **This must stay `.normal`.** It is a stored
    /// constant, not a literal at the call site, so that the one thing that
    /// caused MYR-339 is a value a test can assert on rather than a modifier
    /// buried in a view body. Anything other than `.normal` reintroduces a
    /// dependency on a blend resolving against MapKit's own surface.
    public static let heroTintBlendMode: BlendMode = .normal

    /// The soft radial highlight over the hero (screens.jsx:886). The prototype
    /// gives this one NO `mix-blend-mode` — it is already normal compositing —
    /// so its opacity is the prototype's own.
    public static let heroHighlightOpacity: Double = 0.18

    // MARK: Page wash (screens.jsx:866-871) — normal compositing in the
    // prototype too, and it never overlaps the map (it is painted behind the
    // scrolling page, and the hero map is opaque).

    public static let washRadialInnerOpacity: Double = 0.22
    public static let washRadialMidOpacity: Double = 0.08
    public static let washLinearMidOpacity: Double = 0.05
    public static let washLinearEndOpacity: Double = 0.12

    // MARK: Motion (screens.jsx:852-861)

    /// Delay from mount to the wash easing in.
    public static let washDelayDefault: Duration = .milliseconds(2700)
    /// Reduce Motion cuts the wait and drops the fade entirely.
    public static let washDelayReduceMotion: Duration = .milliseconds(200)
    /// `transition: opacity 1.4s cubic-bezier(0.4,0,0.2,1)`.
    public static let washFadeDuration: Double = 1.4

    /// The opacity every celebration layer animates to, **clamped**.
    ///
    /// The fade is driven by a `Bool`, so the terminal value can only be 0 or 1
    /// — but it is resolved through here rather than written as `goldMode ? 1 : 0`
    /// at four call sites, so "what does the celebration settle at" is one
    /// testable answer instead of four literals that can drift apart. The clamp
    /// is what makes an over-unity terminal (the bloom class of defect) not
    /// expressible on this screen.
    public static func layerOpacity(goldMode: Bool) -> Double {
        min(1, max(0, goldMode ? 1 : 0))
    }

    /// The animation the wash fades in on, or `nil` under Reduce Motion (the
    /// prototype sets `transition: none` there and snaps).
    public static func washAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: washFadeDuration)
    }

    /// How long to wait after mount before easing the wash in.
    public static func washDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? washDelayReduceMotion : washDelayDefault
    }
}
