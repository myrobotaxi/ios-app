import XCTest
import SwiftUI
@testable import DesignSystem

// MARK: - MYR-326 — skeleton loading placeholders
//
// The blocks themselves are pure geometry; what is worth pinning is the
// RELATIONSHIPS between the fills, because those are what make a skeleton read
// as "nothing here yet" instead of as dim content or as a real, tappable row.
final class SkeletonTests: XCTestCase {

    private func alpha(_ color: Color) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        return a
    }

    /// What the color actually LOOKS like on screen — the only fair comparison
    /// now that some skeleton values are opaque and others are white at low
    /// alpha over the app background.
    private func luminanceOverBackground(_ color: Color) -> CGFloat {
        let bg: CGFloat = 0x0A / 255.0 // `mrtBg` #0A0A0A
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        return (r * a) + bg * (1 - a)
    }

    /// THE REGRESSION GUARD on the shimmer itself. `MRTSkeletonBar` composites
    /// its highlight sweep over the block and clips it to the block's shape — so
    /// a translucent fill lets the sweep light whatever sits BEHIND the
    /// placeholder, and under the masked composition this replaced it scaled the
    /// highlight to ~1% and the skeleton silently stopped shimmering at all
    /// (a still screenshot cannot tell a subtle sweep from no sweep).
    func testBlockFillsAreOpaqueSoTheSweepStaysInsideThePlaceholder() {
        XCTAssertEqual(
            alpha(.mrtSkeletonFill), 1.0, accuracy: 0.001,
            "a translucent block fill lets the shimmer bleed onto what's behind it"
        )
        XCTAssertEqual(alpha(.mrtSkeletonFillStrong), 1.0, accuracy: 0.001)
    }

    /// The row card's own values stay alpha compositions — it is a background,
    /// never a mask.
    func testRowChromeAlphas() {
        XCTAssertEqual(alpha(.mrtSkeletonRowFill), 0.025, accuracy: 0.001)
        XCTAssertEqual(alpha(.mrtSkeletonRowBorder), 0.07, accuracy: 0.001)
    }

    /// A placeholder must never be mistakable for CONTENT. Every skeleton fill
    /// sits below the app's most muted TEXT color, so a block reads as an empty
    /// slot rather than as an unreadably dim word.
    func testEveryPlaceholderIsQuieterThanTheMostMutedText() {
        let mutedText = luminanceOverBackground(.mrtTextMuted) // opaque #6B6B6B
        for (name, color) in [
            ("skeletonFill", Color.mrtSkeletonFill),
            ("skeletonFillStrong", Color.mrtSkeletonFillStrong),
            ("skeletonRowFill", Color.mrtSkeletonRowFill),
        ] {
            XCTAssertLessThan(
                luminanceOverBackground(color), mutedText,
                "\(name) is as bright as muted TEXT — a placeholder would read as content"
            )
        }
    }

    /// A block sitting INSIDE a row-shaped skeleton has to be visible against
    /// it, or the placeholder row is just an empty card. This is the ordering
    /// `DriveRowSkeleton` depends on.
    func testBlocksReadAgainstTheRowCardTheySitOn() {
        XCTAssertLessThan(
            luminanceOverBackground(.mrtSkeletonRowFill),
            luminanceOverBackground(.mrtSkeletonFill),
            "the row card is at least as bright as the blocks on it — they would disappear"
        )
        XCTAssertLessThan(
            luminanceOverBackground(.mrtSkeletonFill),
            luminanceOverBackground(.mrtSkeletonFillStrong),
            "the headline placeholder must out-weigh the body placeholder, as the real text does"
        )
    }

    /// `MRTSkeletonBar`'s default radius is a full capsule, which is what a text
    /// placeholder wants; an explicit radius is honored for card/tile shapes.
    func testBarDefaultsToACapsuleAndHonorsAnExplicitRadius() {
        // Exercised through the initializer's own arithmetic rather than a
        // rendered snapshot (there is no view-tree introspection here): the
        // default radius is half the height.
        XCTAssertEqual(MRTSkeletonBar(height: 18).radius, 9)
        XCTAssertEqual(MRTSkeletonBar(height: 18, radius: 6).radius, 6)
    }

    /// Emphasis maps to the two documented fills — the thing every skeleton in
    /// the app composes with.
    func testEmphasisSelectsTheDocumentedFill() {
        XCTAssertEqual(MRTSkeletonEmphasis.regular.fill, Color.mrtSkeletonFill)
        XCTAssertEqual(MRTSkeletonEmphasis.strong.fill, Color.mrtSkeletonFillStrong)
    }
}
