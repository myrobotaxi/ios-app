import XCTest
import SwiftUI
import UIKit
@testable import DesignSystem

// MARK: - MYR-339 / MYR-346 — the 100%-FSD celebration
//
// MYR-339: a screenshot is not evidence for the defect this file started as. The
// client's stills looked right while his phone did not, because a screenshot
// flattens the layer tree into one offscreen buffer where a blend mode over
// MapKit resolves, and the live display path does not guarantee it. So the guard
// was arithmetic, not pixels.
//
// MYR-346 removed the layer that arithmetic guarded. The client rejected the
// TREATMENT — *"it literally looks like someone puked on the screen and it's hard
// to read… something cleaner, crisper, and more rewarding"* — so there is no
// full-surface tint left to be subtle about: the hero map, the page and every
// non-FSD tile on a 100% drive render exactly as a 97% drive's do. What these
// tests guard is the celebration that replaced it — a bounded MOMENT, and a
// settled treatment that is richer WITHOUT being dimmer.
final class DriveCelebrationCompositingTests: XCTestCase {

    // MARK: The one thing that caused MYR-339

    /// Nothing the celebration draws is over the map any more, so this is
    /// belt-and-braces — but it stays a stored constant, asserted here, because
    /// the ONE thing that caused MYR-339 was a blend mode written as a literal in
    /// a view body. `.softLight` there (the prototype's own CSS, safe only
    /// because its parent creates a stacking context) degraded to source-over on
    /// device: gold at the layer's alpha, flat across the map.
    func testCelebrationUsesNormalCompositing() {
        XCTAssertEqual(
            MRTDriveCelebration.celebrationBlendMode, .normal,
            "the celebration must composite normally — a blend mode resolved against a hosted surface is what MYR-339 was"
        )
    }

    // MARK: The predicate

    /// One definition of "this drive celebrates", so the richer ring, the gold
    /// numeral and the gold hairline cannot disagree about which drive they are
    /// decorating. 97% is the control state and must stay uncelebrated.
    func testOnlyAFlawlessDriveCelebrates() {
        XCTAssertTrue(MRTDriveCelebration.celebrates(fsdPercent: 100))
        XCTAssertTrue(MRTDriveCelebration.celebrates(fsdPercent: 101), "an over-100 reading still celebrates")
        XCTAssertFalse(MRTDriveCelebration.celebrates(fsdPercent: 99))
        XCTAssertFalse(MRTDriveCelebration.celebrates(fsdPercent: 97), "the 97% control is the byte-identical variant")
        XCTAssertFalse(MRTDriveCelebration.celebrates(fsdPercent: 0))
    }

    // MARK: A moment, not a state

    /// The client asked for "a special look… as a moment". The whole thing —
    /// arming delay, draw, glint — has to fit inside the window a person reads as
    /// an entry animation. Anything longer is a state again.
    func testTheEntryMomentIsBounded() {
        XCTAssertGreaterThanOrEqual(MRTDriveCelebration.momentDuration, 1.2)
        XCTAssertLessThanOrEqual(
            MRTDriveCelebration.momentDuration, 1.8,
            "past ~1.8s the celebration stops being a moment and starts being a state — the thing the client rejected"
        )
    }

    /// The draw is the 97% ring's own sweep, unchanged. If these drift, the two
    /// variants stop drawing on the same schedule and the "byte-identical 97%"
    /// claim quietly stops being true in motion.
    func testTheDrawKeepsThe97PercentRingsOwnSchedule() {
        XCTAssertEqual(MRTDriveCelebration.ringDrawDelay, 0.12, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.ringDrawDuration, 1.15, accuracy: 0.0001)
    }

    /// The glint is armed exactly when the head lands at 12 o'clock — i.e. at the
    /// end of the draw, not on a hand-tuned literal that can drift away from it.
    func testTheGlintIsArmedWhenTheDrawLands() {
        XCTAssertEqual(
            MRTDriveCelebration.glintOnset, .milliseconds(1270),
            "delay + duration; the glint must fire as the head arrives, not before or after it"
        )
        XCTAssertEqual(
            MRTDriveCelebration.momentDuration,
            MRTDriveCelebration.ringDrawDelay + MRTDriveCelebration.ringDrawDuration + MRTDriveCelebration.ringGlintDuration,
            accuracy: 0.0001
        )
    }

    /// Reduce Motion boots straight to the settled state: both passes resolve to
    /// `nil`, so the ring snaps and the glint never runs.
    func testReduceMotionBootsStraightToTheSettledState() {
        XCTAssertNil(MRTDriveCelebration.ringDrawAnimation(reduceMotion: true))
        XCTAssertNil(MRTDriveCelebration.ringGlintAnimation(reduceMotion: true))
        XCTAssertNotNil(MRTDriveCelebration.ringDrawAnimation(reduceMotion: false))
        XCTAssertNotNil(MRTDriveCelebration.ringGlintAnimation(reduceMotion: false))
    }

    // MARK: The head + glint, clamped

    /// MYR-227's lesson kept: no animator sample may reach CALayer as an
    /// out-of-range opacity.
    func testHeadOpacityIsClampedAcrossTheWholePass() {
        for step in 0...40 {
            let p = Double(step) / 40
            for glint in [0.0, 0.5, 1.0] {
                let o = MRTDriveCelebration.headOpacity(drawProgress: p, glintPhase: glint)
                XCTAssertTrue((0...1).contains(o), "head opacity \(o) out of range at p=\(p) glint=\(glint)")
            }
        }
        XCTAssertEqual(MRTDriveCelebration.headOpacity(drawProgress: -5, glintPhase: -5), 0, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.headOpacity(drawProgress: 9, glintPhase: 0), 1, accuracy: 0.0001)
    }

    /// The head is invisible at rest and invisible once the glint is spent —
    /// which is what makes the settled state STATIC. A head that lingered would
    /// be a permanent bright dot parked on a stat tile.
    func testTheHeadIsGoneOnceTheGlintIsSpent() {
        XCTAssertEqual(MRTDriveCelebration.headOpacity(drawProgress: 0, glintPhase: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.headOpacity(drawProgress: 1, glintPhase: 1), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(MRTDriveCelebration.headOpacity(drawProgress: 0.5, glintPhase: 0), 0.9)
    }

    /// The moment ends on a brightening: the head swells as it burns out.
    func testTheGlintFlaresOutward() {
        XCTAssertEqual(MRTDriveCelebration.glintScale(glintPhase: 0), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(MRTDriveCelebration.glintScale(glintPhase: 1), 1.4)
        XCTAssertEqual(
            MRTDriveCelebration.glintScale(glintPhase: 12),
            MRTDriveCelebration.glintScale(glintPhase: 1),
            accuracy: 0.0001
        )
    }

    // MARK: The settled treatment — richer must never mean dimmer

    /// The client's complaint was half aesthetics and half READABILITY ("it's
    /// hard to read"). So the settled ring's rule is arithmetic, not taste: every
    /// stop of the celebrated ring is `gold` or lighter, so a 100% ring is never
    /// harder to see than the 97% ring it is supposed to out-rank.
    func testTheCelebratedRingIsNeverDimmerThanThe97PercentRing() {
        let flatGold = Self.luminance(Self.gold)
        for stop in MRTDriveCelebration.celebratedRingStops {
            let l = Self.luminance(Self.components(of: stop.color))
            XCTAssertGreaterThanOrEqual(
                l, flatGold - 0.001,
                "a celebrated ring stop is dimmer than the 97% ring's flat gold — 'richer' may not mean 'harder to read'"
            )
        }
        XCTAssertEqual(MRTDriveCelebration.celebratedRingStops.first?.location, 0)
        XCTAssertEqual(MRTDriveCelebration.celebratedRingStops.last?.location, 1)
    }

    /// The numeral's gradient DOES reach `goldDeep`, which is darker than gold —
    /// that is the struck-metal look. What keeps it honest is where the stop
    /// sits: held to the bottom 30%, so the gradient's mean luminance still lands
    /// above flat gold's. Move that stop up and this fails, which is the point.
    func testTheCelebratedNumeralIsBrighterOnAverageThanFlatGold() {
        let mean = Self.meanLuminance(of: MRTDriveCelebration.celebratedTextStops)
        XCTAssertGreaterThan(
            mean, Self.luminance(Self.gold),
            "the celebrated numeral must average BRIGHTER than the flat gold it replaces — the client said it was hard to read"
        )
    }

    /// The hairline is the whole of the card treatment: a gold tint at low
    /// opacity replacing the neutral border, and nothing else. A heavy border
    /// would be the wash again, drawn as a rectangle.
    func testTheCardHairlineIsAHairline() {
        let alpha = Self.alpha(of: MRTDriveCelebration.celebratedCardBorder)
        XCTAssertGreaterThan(alpha, 0.05, "the hairline must be visible")
        XCTAssertLessThanOrEqual(
            alpha, 0.25,
            "past ~0.25 a gold border stops reading as a hairline and starts reading as a tinted card"
        )
    }

    /// The halo is faint and static — the last survivor of the prototype's
    /// glow/flash/burst, and it must not grow back into them.
    func testTheSettledHaloStaysFaint() {
        XCTAssertLessThanOrEqual(Self.alpha(of: MRTDriveCelebration.celebratedRingHalo), 0.2)
        XCTAssertGreaterThan(MRTDriveCelebration.celebratedRingHaloBlur, 0)
    }

    // MARK: Helpers — sRGB components and Rec.709 luma

    private typealias RGB = (r: Double, g: Double, b: Double)
    /// `Hex.gold` #C9A84C, the accent both variants of the ring are drawn in.
    private static let gold: RGB = (201.0 / 255, 168.0 / 255, 76.0 / 255)

    private static func resolve(_ color: Color) -> (RGB, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return ((Double(r), Double(g), Double(b)), Double(a))
    }

    private static func components(of color: Color) -> RGB { resolve(color).0 }
    private static func alpha(of color: Color) -> Double { resolve(color).1 }

    private static func luminance(_ c: RGB) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// Area-weighted mean luminance of a piecewise-linear gradient.
    private static func meanLuminance(of stops: [Gradient.Stop]) -> Double {
        guard stops.count > 1 else { return stops.first.map { luminance(components(of: $0.color)) } ?? 0 }
        var total = 0.0
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            let width = Double(b.location - a.location)
            total += (luminance(components(of: a.color)) + luminance(components(of: b.color))) / 2 * width
        }
        return total
    }
}
