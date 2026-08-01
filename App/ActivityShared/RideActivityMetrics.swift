import CoreGraphics
import Foundation

// MARK: - The v3 board's geometry (MYR-398)
//
// Lives in `App/ActivityShared` — compiled into BOTH the widget (which lays out
// with it) and the app's test bundle (which MEASURES against it). v2 kept these
// numbers beside the views, where nothing could assert on them; the v3 card's whole
// promise is a FIXED footprint and four FIXED rows, and a promise about geometry
// that no test can read is a promise about a comment.

// MARK: - Geometry
//
// `la-kit.jsx`'s numbers, in one place so a capture can be MEASURED against the
// design rather than eyeballed against it. Every value here is quoted in the
// handoff's §5 geometry block.
enum RideActivityMetrics {
    // Card — fixed, every state.
    static let cardWidth: CGFloat = 350
    static let cardHeight: CGFloat = 128
    static let cardRadius: CGFloat = 22
    static let cardPaddingTop: CGFloat = 12
    static let cardPaddingHorizontal: CGFloat = 15
    static let cardPaddingBottom: CGFloat = 13

    // The four fixed row heights. NOTHING a state does may change one of these —
    // that is the whole of "every state, same footprint".
    static let wordmarkRowHeight: CGFloat = 20
    static let headlineRowHeight: CGFloat = 24
    static let sublineRowHeight: CGFloat = 17
    static let railRowHeight: CGFloat = 18

    static let cardBrandRowGap: CGFloat = 8
    static let cardTileSize: CGFloat = 20
    static let wordmarkSize: CGFloat = 10
    static let wordmarkTracking: CGFloat = 0.9

    // Headline — 20/600, tracking −0.45. `in` / the unit / `dropoff` are 500 @62%.
    static let headlineSize: CGFloat = 20
    static let headlineGap: CGFloat = 5
    static let headlineTracking: CGFloat = -0.45

    // Subline — 13.5/400 @58%, tracking −0.1, one line, tail ellipsis.
    static let sublineSize: CGFloat = 13.5
    static let sublineTracking: CGFloat = -0.1

    // Rail — track 5 (r 2.5) · dest pin 11 (2px ring) · arrow 14 in a 22pt puck.
    static let railHeight: CGFloat = 5
    static let railPuck: CGFloat = 22
    static let railPuckRing: CGFloat = 2
    static let railArrow: CGFloat = 14
    static let railPin: CGFloat = 11
    static let railPinRing: CGFloat = 2
    /// The puck's opacity on the IDLE variant. Not "dimmed to signal a problem" —
    /// half-strength is what an UNTRAVELLED route looks like.
    static let railIdlePuckOpacity: Double = 0.5
    /// `transition: .5s cubic-bezier(.2,.8,.2,1)` — la-kit's own rail curve.
    static let railTravel: TimeInterval = 0.5

    // Compact Dynamic Island — a figure or nothing.
    static let compactArrow: CGFloat = 16
    static let compactFigureSize: CGFloat = 15
    static let compactWaveGlyph: CGFloat = 17
    static let compactCheckGlyph: CGFloat = 15
    static let minimalArrow: CGFloat = 17

    // Expanded island — 372 × 96 · r 38 · padding 12/18/14 · gap 9 · logo 28 ·
    // headline 19/600. The BOX is the system's (nothing may set an island's width or
    // its corner radius); the padding, the gap, the tile and the type are ours and
    // are the kit's.
    static let expandedGap: CGFloat = 9
    static let expandedHeaderGap: CGFloat = 11
    static let expandedTile: CGFloat = 28
    static let expandedHeadlineSize: CGFloat = 19
    static let expandedSublineSize: CGFloat = 12.5
    static let expandedPaddingTop: CGFloat = 12
    static let expandedPaddingHorizontal: CGFloat = 18
    static let expandedPaddingBottom: CGFloat = 14
}
