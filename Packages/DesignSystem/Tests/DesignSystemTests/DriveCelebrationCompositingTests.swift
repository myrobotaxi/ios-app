import XCTest
import SwiftUI
@testable import DesignSystem

// MARK: - MYR-339 — the 100%-FSD celebration must not flood the hero map
//
// A screenshot is not evidence for this defect: the client's stills looked right
// while his phone did not, because a screenshot flattens the layer tree into one
// offscreen buffer where a blend mode over MapKit resolves, and the live display
// path does not guarantee it. So the guard is arithmetic, not pixels — these
// tests recompute what the celebration actually composites to over the hero's own
// dark map ground, and fail if it ever stops being subtle.
final class DriveCelebrationCompositingTests: XCTestCase {

    // MARK: The one thing that caused MYR-339

    /// The hero tint may not depend on a blend mode resolving against MapKit's
    /// own compositing surface. `.softLight` here (the prototype's literal CSS,
    /// which is safe only because its parent creates a stacking context) degrades
    /// to source-over on device — gold at the layer's alpha, flat across the map.
    func testHeroTintUsesNormalCompositing() {
        XCTAssertEqual(
            MRTDriveCelebration.heroTintBlendMode, .normal,
            "the hero map tint must composite normally — a blend mode over the hosted MKMapView is what MYR-339 was"
        )
    }

    /// With normal compositing the tint's own alpha is the whole story, so it has
    /// to be the RESOLVED (subtle) value, not the prototype's soft-light source
    /// alpha of 0.5→0.85. Those two numbers reaching this layer unresolved is the
    /// exact shape of the client's photo.
    func testHeroTintOpacitiesAreTheResolvedSubtleValues() {
        for opacity in [MRTDriveCelebration.heroTintTopOpacity, MRTDriveCelebration.heroTintBottomOpacity] {
            XCTAssertGreaterThan(opacity, 0, "the celebration must still be visible")
            XCTAssertLessThanOrEqual(
                opacity, 0.12,
                "a normal-blend gold tint above ~0.12 stops being a tint and starts being a flood"
            )
        }
    }

    // MARK: What it actually composites to

    /// Measured off the real hero: the un-tinted map's mean is RGB(27,37,53) and
    /// the prototype's soft-light output is RGB(44,48,43) — luminance 0.143 →
    /// 0.184. The shipped tint has to land there, and NOT at the dropped-blend
    /// RGB(145,127,70) / luminance 0.496.
    func testHeroTintLandsOnThePrototypesOwnLuminance() {
        let map = (r: 27.0 / 255, g: 37.0 / 255, b: 53.0 / 255)
        let prototypeSoftLightLuminance = 0.184

        for (label, alpha) in [
            ("top", MRTDriveCelebration.heroTintTopOpacity),
            ("bottom", MRTDriveCelebration.heroTintBottomOpacity),
        ] {
            let out = Self.compositeGoldOverNormally(map, alpha: alpha)
            let luminance = Self.luminance(out)
            XCTAssertEqual(
                luminance, prototypeSoftLightLuminance, accuracy: 0.02,
                "the \(label) of the hero tint must land on the prototype's own resolved luminance"
            )
        }
    }

    /// The client's words were "gold even overlaying the map" — i.e. the map
    /// stopped being readable. Readability is contrast, so assert it directly:
    /// the tint must preserve most of the spread between the map's dark ground
    /// and its bright labels. The dropped blend collapsed it to 53%.
    func testHeroTintKeepsTheMapReadable() {
        let darkGround = (r: 20.0 / 255, g: 24.0 / 255, b: 34.0 / 255)
        let brightLabel = (r: 205.0 / 255, g: 205.0 / 255, b: 205.0 / 255)
        let before = Self.luminance(brightLabel) - Self.luminance(darkGround)

        let alpha = MRTDriveCelebration.heroTintBottomOpacity   // the heavier end
        let after = Self.luminance(Self.compositeGoldOverNormally(brightLabel, alpha: alpha))
            - Self.luminance(Self.compositeGoldOverNormally(darkGround, alpha: alpha))

        XCTAssertGreaterThan(
            after / before, 0.85,
            "the celebration must keep at least 85% of the hero map's contrast (the shipped defect kept 53%)"
        )
    }

    /// The same arithmetic run on what the device was doing, as a live check that
    /// the assertions above can actually fail. If this ever passes, the tests
    /// above have stopped guarding anything.
    func testTheDroppedBlendWouldFailTheseGuards() {
        let map = (r: 27.0 / 255, g: 37.0 / 255, b: 53.0 / 255)
        let droppedBlendLuminance = Self.luminance(Self.compositeGoldOverNormally(map, alpha: 0.85))
        XCTAssertGreaterThan(
            droppedBlendLuminance, 0.4,
            "sanity: gold at the prototype's SOURCE alpha really is a flood, so the guards above are real"
        )
    }

    // MARK: Terminal values

    /// The wash's terminal on the real transition. Every celebration layer reads
    /// this one resolver, so this is the settled opacity of all four.
    func testWashTerminalOpacityIsClampedToOne() {
        XCTAssertEqual(MRTDriveCelebration.layerOpacity(goldMode: true), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.layerOpacity(goldMode: false), 0.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            MRTDriveCelebration.layerOpacity(goldMode: true), 1.0,
            "an over-unity terminal is the bloom class of defect and must not be expressible here"
        )
    }

    /// Reduce Motion snaps (the prototype sets `transition: none`) and shortens
    /// the wait; neither may change the terminal the layers settle on.
    func testReduceMotionSnapsWithoutChangingTheTerminal() {
        XCTAssertNil(MRTDriveCelebration.washAnimation(reduceMotion: true))
        XCTAssertNotNil(MRTDriveCelebration.washAnimation(reduceMotion: false))
        XCTAssertEqual(MRTDriveCelebration.washDelay(reduceMotion: true), .milliseconds(200))
        XCTAssertEqual(MRTDriveCelebration.washDelay(reduceMotion: false), .milliseconds(2700))
        XCTAssertEqual(MRTDriveCelebration.layerOpacity(goldMode: true), 1.0, accuracy: 0.0001)
    }

    /// The page wash keeps the prototype's own numbers verbatim — it composites
    /// normally in the prototype too, and never overlaps the opaque hero map.
    func testPageWashKeepsThePrototypesOpacities() {
        XCTAssertEqual(MRTDriveCelebration.washRadialInnerOpacity, 0.22, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.washRadialMidOpacity, 0.08, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.washLinearMidOpacity, 0.05, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.washLinearEndOpacity, 0.12, accuracy: 0.0001)
        XCTAssertEqual(MRTDriveCelebration.heroHighlightOpacity, 0.18, accuracy: 0.0001)
    }

    // MARK: Helpers — sRGB source-over with the gold token, and Rec.709 luma

    private typealias RGB = (r: Double, g: Double, b: Double)
    /// `Hex.gold` #C9A84C, the sacred accent the celebration tints with.
    private static let gold: RGB = (201.0 / 255, 168.0 / 255, 76.0 / 255)

    private static func compositeGoldOverNormally(_ backdrop: RGB, alpha: Double) -> RGB {
        (
            r: (1 - alpha) * backdrop.r + alpha * gold.r,
            g: (1 - alpha) * backdrop.g + alpha * gold.g,
            b: (1 - alpha) * backdrop.b + alpha * gold.b
        )
    }

    private static func luminance(_ c: RGB) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }
}
