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

    /// The documented alphas, so a later "tidy-up" can't quietly darken or
    /// brighten a placeholder past the thresholds the next two tests protect.
    func testSkeletonFillAlphas() {
        XCTAssertEqual(alpha(.mrtSkeletonFill), 0.06, accuracy: 0.001)
        XCTAssertEqual(alpha(.mrtSkeletonFillStrong), 0.10, accuracy: 0.001)
        XCTAssertEqual(alpha(.mrtSkeletonRowFill), 0.025, accuracy: 0.001)
        XCTAssertEqual(alpha(.mrtSkeletonRowBorder), 0.07, accuracy: 0.001)
    }

    /// A placeholder must never be mistakable for CONTENT. Every skeleton fill
    /// sits below the app's most muted TEXT color, so a block reads as an empty
    /// slot rather than as an unreadably dim word.
    func testEveryPlaceholderIsQuieterThanTheMostMutedText() {
        // `mrtTextMuted` is opaque `#6B6B6B`; compare on rendered luminance
        // against the app background rather than on alpha, since one is a solid
        // color and the others are white at low alpha over `#0A0A0A`.
        let bg: CGFloat = 0x0A / 255.0
        func luminance(_ color: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
            return (r * a) + bg * (1 - a)
        }
        let mutedText = luminance(.mrtTextMuted)
        for (name, color) in [
            ("skeletonFill", Color.mrtSkeletonFill),
            ("skeletonFillStrong", Color.mrtSkeletonFillStrong),
            ("skeletonRowFill", Color.mrtSkeletonRowFill),
        ] {
            XCTAssertLessThan(
                luminance(color), mutedText,
                "\(name) is as bright as muted TEXT — a placeholder would read as content"
            )
        }
    }

    /// A block sitting INSIDE a row-shaped skeleton has to be visible against
    /// it, or the placeholder row is just an empty card. This is the ordering
    /// `DriveRowSkeleton` depends on.
    func testBlocksReadAgainstTheRowCardTheySitOn() {
        XCTAssertLessThan(
            alpha(.mrtSkeletonRowFill), alpha(.mrtSkeletonFill),
            "the row card is at least as bright as the blocks on it — they would disappear"
        )
        XCTAssertLessThan(
            alpha(.mrtSkeletonFill), alpha(.mrtSkeletonFillStrong),
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
        XCTAssertEqual(alpha(MRTSkeletonEmphasis.regular.fill), 0.06, accuracy: 0.001)
        XCTAssertEqual(alpha(MRTSkeletonEmphasis.strong.fill), 0.10, accuracy: 0.001)
    }
}
