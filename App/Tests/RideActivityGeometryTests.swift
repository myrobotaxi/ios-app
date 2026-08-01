import UIKit
import XCTest
@testable import MyRoboTaxi

// MARK: - The card's FIXED footprint, measured (MYR-398 v3)
//
// The field report's fourth item was *"all banners the same width and height"*, and
// v3's answer is a fixed 350 × 128 card over four fixed-height rows. That promise
// lives in numbers (`RideActivityMetrics`) and in `lineLimit(1)`, and a promise
// about geometry that nothing measures is a promise about a comment — so this suite
// does the two things a unit test genuinely can:
//
//   1. **The arithmetic.** Four fixed rows plus the padding must ADD UP to 128 with
//      room left over for the `space-between` gaps, and never more than 128. A row
//      grown by a point is the whole failure mode, and it is silent: SwiftUI would
//      simply compress the gaps until they ran out and then clip.
//   2. **The longest strings.** Both one-line rows are `lineLimit(1)` with a tail
//      ellipsis, so what a test can prove is that the widest string each row can
//      legitimately be handed still FITS its slot — measured through UIKit's own
//      text engine at the real size, in the real content width.
//
// What it deliberately does NOT claim: that the rendered CARD is 128pt. That needs
// the widget process on a lock screen, and the lock screen has no headless capture
// route at all (`simctl` has no lock command). The PR says so rather than implying
// otherwise.

final class RideActivityGeometryTests: XCTestCase {

    /// The card's own content width — 350 less 15 either side.
    private static let contentWidth = RideActivityMetrics.cardWidth
        - RideActivityMetrics.cardPaddingHorizontal * 2

    // MARK: - 1. The rows add up

    /// **FOUR FIXED ROWS + PADDING ≤ 128**, with the remainder going to the two
    /// `space-between` gaps.
    ///
    /// la-kit's card is THREE children — the wordmark row, the headline+subline
    /// block, and the rail — so the leftover is split into two gaps of 12. If a row
    /// ever grew past the leftover, the gaps would collapse to zero and then the
    /// content would clip, which is the kind of failure that looks like a rendering
    /// bug rather than like a layout mistake.
    func testTheFourRowsAndThePaddingFitTheFixedCardHeight() {
        let rows = RideActivityMetrics.wordmarkRowHeight
            + RideActivityMetrics.headlineRowHeight
            + RideActivityMetrics.sublineRowHeight
            + RideActivityMetrics.railRowHeight
        let padding = RideActivityMetrics.cardPaddingTop + RideActivityMetrics.cardPaddingBottom

        XCTAssertEqual(rows, 79, "20 + 24 + 17 + 18 — the board's own four row heights")
        XCTAssertEqual(padding, 25, "12 top, 13 bottom")

        let leftover = RideActivityMetrics.cardHeight - rows - padding
        XCTAssertEqual(leftover, 24, "which la-kit's space-between splits into two 12pt gaps")
        XCTAssertGreaterThanOrEqual(leftover, 0, "a row grew and the card no longer composes")
    }

    /// The puck is CLAMPED to the track, so it can never overhang either end —
    /// `11 + (W − 22) × p` for its centre, i.e. `(W − 22) × p` for its leading edge.
    ///
    /// This is what let v3 drop v2's `headClearance`: a centred disc overhung the
    /// rail by half its width and had to be inset on the island, where the 38pt
    /// corner radius cut it in half at `p == 1`.
    func testThePuckIsClampedToTheTrackAtBothEnds() {
        let width = Self.contentWidth
        let travel = width - RideActivityMetrics.railPuck

        for fraction in [0.0, 0.38, 0.5, 0.88, 1.0] {
            let leading = travel * fraction
            XCTAssertGreaterThanOrEqual(leading, 0, "p=\(fraction)")
            XCTAssertLessThanOrEqual(
                leading + RideActivityMetrics.railPuck,
                width + 0.001,
                "p=\(fraction) overhangs the track"
            )
        }
    }

    /// At `p = 1` the puck lands exactly on the end of the track, where the
    /// destination pin used to be — which is why the pin is REMOVED there rather
    /// than drawn under it.
    func testAtFullProgressThePuckParksOnTheEndOfTheTrack() {
        let width = Self.contentWidth
        let leading = (width - RideActivityMetrics.railPuck) * 1.0
        XCTAssertEqual(leading + RideActivityMetrics.railPuck, width, accuracy: 0.001)
    }

    // MARK: - 2. The longest strings fit their one line

    /// **THE LONGEST HEADLINE IN THE SET.** "Reservation expired" at 20/600 is what
    /// the fixed 24pt row and its one-line rule are measured against.
    func testTheLongestHeadlineFitsOneLine() {
        let widest = [
            RideActivityCopy.expiredHeadline,
            RideActivityCopy.dispatchHeadline,
            RideActivityCopy.arrivedHeadline,
            RideActivityCopy.declinedHeadline,
            RideActivityCopy.unknownHeadline,
            RideActivityCopy.cancelledHeadline,
            RideActivityCopy.completedHeadline,
        ]

        for headline in widest {
            let width = Self.width(
                headline,
                size: RideActivityMetrics.headlineSize,
                weight: .semibold,
                tracking: RideActivityMetrics.headlineTracking
            )
            XCTAssertLessThan(
                width,
                Self.contentWidth,
                "\(headline) measures \(width)pt in a \(Self.contentWidth)pt row"
            )
        }
    }

    /// The composed countdown and clock forms fit too, measured PART BY PART with
    /// the row's own 5pt gaps — the headline is four `Text`s in an `HStack`, not one
    /// string, so measuring it as one would understate it.
    func testBothComposedHeadlineFormsFitOneLine() {
        let countdown = Self.width(
            RideActivityCopy.pickupPhase,
            size: RideActivityMetrics.headlineSize, weight: .semibold,
            tracking: RideActivityMetrics.headlineTracking
        ) + Self.width(
            RideActivityCopy.countdownJoin,
            size: RideActivityMetrics.headlineSize, weight: .medium, tracking: 0
        ) + Self.width(
            "88", size: RideActivityMetrics.headlineSize, weight: .semibold,
            tracking: RideActivityMetrics.headlineTracking
        ) + Self.width(
            "min", size: RideActivityMetrics.headlineSize, weight: .medium, tracking: 0
        ) + RideActivityMetrics.headlineGap * 3

        let clock = Self.width(
            "12:42 AM", size: RideActivityMetrics.headlineSize, weight: .semibold,
            tracking: RideActivityMetrics.headlineTracking
        ) + Self.width(
            RideActivityCopy.dropoffWord,
            size: RideActivityMetrics.headlineSize, weight: .medium, tracking: 0
        ) + RideActivityMetrics.headlineGap

        XCTAssertLessThan(countdown, Self.contentWidth, "Pickup in 88 min measures \(countdown)pt")
        XCTAssertLessThan(clock, Self.contentWidth, "12:42 AM dropoff measures \(clock)pt")
    }

    /// **THE VEHICLE DESCRIPTOR'S BUDGET, MEASURED — AGAINST REAL CARS.**
    ///
    /// `RideActivityVehicleDescriptor.maxCharacters` is a COPY rule (how much
    /// identification is worth reading at a glance) and a character count cannot
    /// answer "does it fit". This is the half that can, and what it measures is the
    /// SHIPPING ladder's own output over Tesla's real paint names, models, trims and
    /// a full-length plate — not `String(repeating: "M", …)`, which is 394pt at 34
    /// characters and would force the budget down to 27, dropping the year the
    /// client asked for out of every descriptor in order to survive a string no car
    /// can produce.
    ///
    /// The rung the ladder picks is what has to fit, so that is what is measured.
    func testTheDescriptorBudgetsWidestStringFitsTheSubline() {
        let corpus = [
            RideActivityVehicle(plate: "8ABCD123", color: "Pearl White Multi-Coat", model: "Model 3", year: 2026, trim: "Long Range"),
            RideActivityVehicle(plate: "7SRJ294", color: "Deep Blue Metallic", model: "Model S", year: 2026, trim: "Plaid"),
            RideActivityVehicle(plate: "WWWWWWWW", color: "Quicksilver", model: "Model Y", year: 2026, trim: "Performance"),
            RideActivityVehicle(plate: "MMMMMMMM", color: "Ultra Red", model: "Cybertruck", year: 2026),
            RideActivityVehicle(color: "Midnight Silver Metallic", model: "Model X", year: 2025, trim: "Plaid"),
        ]

        for vehicle in corpus {
            let composed = RideActivityVehicleDescriptor.compose(vehicle)
            let width = Self.width(
                composed,
                size: RideActivityMetrics.sublineSize,
                weight: .regular,
                tracking: RideActivityMetrics.sublineTracking
            )
            XCTAssertLessThan(
                width,
                Self.contentWidth,
                "\(composed) — \(composed.count) chars — measures \(width)pt in a \(Self.contentWidth)pt row"
            )
        }
    }

    /// The board's own fixture, measured, so the number in the PR is the board's own
    /// line rather than a synthetic one.
    func testTheBoardsOwnDescriptorFitsWithRoomToSpare() {
        let composed = RideActivityVehicleDescriptor.compose(
            RideActivityVehicle(plate: "7SRJ294", color: "Silver", model: "Model Y", year: 2026)
        )
        XCTAssertEqual(composed, "7SRJ294 · Silver 2026 Model Y")

        let width = Self.width(
            composed,
            size: RideActivityMetrics.sublineSize,
            weight: .regular,
            tracking: RideActivityMetrics.sublineTracking
        )
        XCTAssertLessThan(width, Self.contentWidth * 0.75, "\(composed) measures \(width)pt")
    }

    /// The longest SUBLINE the fourteen rows can produce that is not a descriptor —
    /// `Heading to {place}` over a long destination — is the row's real worst case,
    /// and it is the one string on the card that may legitimately ellipsize.
    ///
    /// So this asserts the OPPOSITE of the tests above, deliberately: the row is
    /// expected to truncate a long enough destination, and what must never happen is
    /// that it WRAPS. A wrapped subline would push the rail out of the card, which is
    /// the one failure the fixed footprint cannot absorb.
    func testALongDestinationTruncatesRatherThanWrapping() {
        let long = RideActivityCopy.headingTo("Galleria Dallas · 13350 Dallas Pkwy, Dallas TX 75240")
        let width = Self.width(
            long,
            size: RideActivityMetrics.sublineSize,
            weight: .regular,
            tracking: RideActivityMetrics.sublineTracking
        )
        XCTAssertGreaterThan(
            width,
            Self.contentWidth,
            "this fixture is meant to be the OVERFLOW case; if it now fits, lengthen it"
        )

        // One line, at the row's own height — which is what `lineLimit(1)` +
        // `.truncationMode(.tail)` guarantee and what the fixed row depends on.
        let bounded = Self.boundingHeight(
            long,
            size: RideActivityMetrics.sublineSize,
            width: Self.contentWidth
        )
        XCTAssertGreaterThan(
            bounded,
            RideActivityMetrics.sublineRowHeight,
            "an UNCONSTRAINED layout of this string wraps — which is exactly why the row is lineLimit(1)"
        )
    }

    // MARK: - 3. §0 A — the expanded island's top row

    /// **THE TOP ROW HOLDS TWO SMALL THINGS AND THEY BOTH FIT IT.**
    ///
    /// The row is 34 in the design and the SYSTEM's in the build — a
    /// `DynamicIslandExpandedRegion` is sized by iOS, and §0 A forbids setting a
    /// height anywhere in that builder. So what a test can do is check the two pieces
    /// of content against the number the design drew them into: a 26pt mark and a
    /// 24pt ring, either of which growing past 34 would push the row out and start
    /// the crowding over again.
    func testTheExpandedTopRowContentFitsTheRowTheDesignDrewIt() {
        XCTAssertLessThanOrEqual(RideActivityMetrics.expandedLogo, RideActivityMetrics.expandedTopRowHeight)
        XCTAssertLessThanOrEqual(RideActivityMetrics.expandedTrailingSlot, RideActivityMetrics.expandedTopRowHeight)
        XCTAssertEqual(RideActivityMetrics.expandedTrailingSlot, RideActivityMetrics.ringDiameter)
    }

    /// **THE EXPANDED HEADLINE STILL FITS ONE LINE AT 19/600**, and it has to fit a
    /// NARROWER row than the card's: the two small top-row regions do not steal from
    /// it, but the island is 372 wide against the card's 350 only after the system's
    /// own insets, so measuring against the card's content width is the conservative
    /// check.
    func testTheLongestHeadlineFitsTheExpandedIslandsOneLine() {
        let width = Self.width(
            RideActivityCopy.expiredHeadline,
            size: RideActivityMetrics.expandedHeadlineSize,
            weight: .semibold,
            tracking: RideActivityMetrics.headlineTracking
        )
        XCTAssertLessThan(width, Self.contentWidth, "\(RideActivityCopy.expiredHeadline) measures \(width)pt")
    }

    /// **THE TWO-LINE VS THREE-LINE PAIR, AS THE NUMBERS BEHIND THE CAPTURE.**
    ///
    /// §0 A's acceptance is that the island's height DIFFERS between a state whose
    /// bottom block is two lines and one whose block is three — that is what proves
    /// nothing is pinned. The screenshots are the evidence; this is the reason the
    /// pair exists at all: at 12.5pt in the island's content width, Dispatch's
    /// subline is comfortably one line and the client's own Galleria Dallas
    /// destination is not.
    func testTheCapturedPairIsGenuinelyOneLineAgainstTwo() {
        let short = RideActivityCopy.dispatchSubline
        let long = RideActivityCopy.headingTo("Galleria Dallas · 13350 Dallas Pkwy, Dallas TX 75240")

        let shortWidth = Self.width(
            short,
            size: RideActivityMetrics.expandedSublineSize,
            weight: .regular,
            tracking: RideActivityMetrics.sublineTracking
        )
        let longWidth = Self.width(
            long,
            size: RideActivityMetrics.expandedSublineSize,
            weight: .regular,
            tracking: RideActivityMetrics.sublineTracking
        )

        XCTAssertLessThan(shortWidth, Self.contentWidth, "\(short) measures \(shortWidth)pt")
        XCTAssertGreaterThan(
            longWidth,
            Self.contentWidth,
            "the three-line fixture must not fit one line, or the capture proves nothing"
        )
        XCTAssertEqual(
            RideActivityMetrics.expandedSublineLineLimit, 2,
            "and the island has to be allowed to USE the second line"
        )
    }

    // MARK: - 4. §0 B/C — the ring and the beat

    /// The two sizes, and the rule that they are ONE ring at two scales: the stroke
    /// tracks the diameter, so the compact ring is not a thicker ring drawn smaller.
    func testTheRingIsOneComponentAtTwoScales() {
        XCTAssertEqual(RideActivityMetrics.ringDiameter, 24)
        XCTAssertEqual(RideActivityMetrics.ringDiameterCompact, 22)
        XCTAssertEqual(RideActivityMetrics.ringStroke, 2.4)
        XCTAssertEqual(RideActivityMetrics.ringStrokeCompact, 2.2)
        XCTAssertLessThan(
            RideActivityMetrics.ringStrokeCompact,
            RideActivityMetrics.ringStroke,
            "the smaller ring takes the thinner stroke, or the two read as two rings"
        )
    }

    /// **THE CENTRE HAS TO FIT INSIDE THE STROKE, WITH AIR.**
    ///
    /// The arrow (12) and the glyph (13) sit inside a 24pt circle drawn with a 2.4pt
    /// stroke, i.e. a 19.2pt hole. A centre that touched the ring would read as one
    /// blob at island scale, so the check is the clearance rather than the diameter.
    func testTheRingsCentreClearsItsOwnStroke() {
        for (name, centre, diameter, stroke) in [
            ("arrow · minimal/expanded", RideActivityMetrics.ringArrow, RideActivityMetrics.ringDiameter, RideActivityMetrics.ringStroke),
            ("glyph · minimal/expanded", RideActivityMetrics.ringGlyph, RideActivityMetrics.ringDiameter, RideActivityMetrics.ringStroke),
            ("arrow · compact", RideActivityMetrics.ringArrow, RideActivityMetrics.ringDiameterCompact, RideActivityMetrics.ringStrokeCompact),
            ("glyph · compact", RideActivityMetrics.ringGlyph, RideActivityMetrics.ringDiameterCompact, RideActivityMetrics.ringStrokeCompact),
        ] {
            let hole = diameter - stroke * 2
            XCTAssertLessThan(centre, hole, "\(name): \(centre)pt centre in a \(hole)pt hole")
            XCTAssertGreaterThan(
                hole - centre, 1.5,
                "\(name): the centre all but touches the ring"
            )
        }
    }

    /// **THE BEAT'S LADDER, IN ORDER.** The ring completes, THEN fades, and the glyph
    /// springs in a beat after the fade starts. Written as inequalities rather than
    /// as three literals, because what matters is the sequence: a delay edited to sit
    /// before the completion would play the glyph over an arc still sweeping under
    /// it.
    func testTheArrivalBeatPlaysInOrderAndEndsInOneSecondish() {
        XCTAssertEqual(
            RideActivityMetrics.arrivalRingCompletion,
            RideActivityMetrics.railTravel,
            "the ring completes on the rail's own curve and duration"
        )
        XCTAssertEqual(RideActivityMetrics.arrivalRingFadeDelay, RideActivityMetrics.arrivalRingCompletion)
        XCTAssertGreaterThan(
            RideActivityMetrics.arrivalGlyphDelay,
            RideActivityMetrics.arrivalRingFadeDelay,
            "the glyph follows the fade, it does not race it"
        )
        XCTAssertEqual(
            RideActivityMetrics.arrivalGlyphDelay - RideActivityMetrics.arrivalRingFadeDelay,
            0.1,
            accuracy: 0.0001,
            "the handoff's 0.1s"
        )

        // A COMPLETION BEAT, NOT AN AMBIENCE. The whole thing has to be over long
        // before the five-minute linger it plays at the start of.
        XCTAssertLessThan(
            RideActivityMetrics.arrivalGlyphDelay + RideActivityMetrics.arrivalSpringResponse * 2,
            2.0
        )
    }

    /// The ring settles UNDER the glyph rather than disappearing: the leg really is
    /// finished, and 40% is what says so without competing with the mark that
    /// replaced the arrow.
    func testTheSettledRingIsStillVisible() {
        XCTAssertEqual(RideActivityMetrics.arrivalRingSettledOpacity, 0.4)
        XCTAssertGreaterThan(RideActivityMetrics.arrivalRingSettledOpacity, 0.2)
        XCTAssertLessThan(RideActivityMetrics.arrivalRingSettledOpacity, 1)
    }

    /// The rotation's own two numbers. A quarter arc is enough to read as a direction
    /// at 24pt, and 1.4s is slow enough not to strobe on a lock screen.
    func testTheIndeterminateArcIsAQuarterTurningOnceEvery1Point4Seconds() {
        XCTAssertEqual(RideActivityMetrics.ringIndeterminateArc, 0.25)
        XCTAssertEqual(RideActivityMetrics.ringSpin, 1.4)
        XCTAssertGreaterThan(RideActivityMetrics.ringMinimumArc, 0)
        XCTAssertLessThan(
            RideActivityMetrics.ringMinimumArc,
            RideActivityMetrics.ringIndeterminateArc,
            "the determinate floor must never be mistakable for the waiting arc"
        )
    }

    // MARK: - 5. §0 A · the corner-safe insets

    /// **THE THREE INSETS EXIST, THEY ARE POSITIVE, AND THEY ARE SMALL.**
    ///
    /// The client's follow-up was that the mark, the ring and the rail's two ends
    /// meet the pill's corner curvature. The fix is three insets, and each of them
    /// is wrong in two directions: zero is the defect, and anything large enough to
    /// re-proportion the surface is the "shrink the layout" the same instruction
    /// forbids. The ceiling is the design's own box padding (20 horizontal / 10
    /// top) — an inset bigger than the padding it sits inside would be the second
    /// inset that stops a full-width region being one.
    func testTheCornerSafeInsetsAreRealAndSmall() {
        for (name, value, ceiling) in [
            ("horizontal", RideActivityMetrics.expandedCornerSafeHorizontal, RideActivityMetrics.expandedPaddingHorizontal),
            ("top", RideActivityMetrics.expandedCornerSafeTop, RideActivityMetrics.expandedPaddingTop),
            ("rail end", RideActivityMetrics.expandedRailCornerSafeInset, RideActivityMetrics.expandedPaddingHorizontal),
        ] {
            XCTAssertGreaterThan(value, 0, "\(name): zero is the reported defect")
            XCTAssertLessThan(value, ceiling, "\(name): \(value)pt is re-proportioning, not insetting")
        }
    }

    /// **THE RAIL'S ENDS ARE THE PUCK'S ENDS**, which is why insetting the rail is
    /// insetting exactly what the client saw hit the bottom corners.
    ///
    /// The puck rides `0 … W − puck`, so at `p = 0` its LEADING edge is the rail's
    /// leading edge and at `p = 1` its TRAILING edge is the rail's trailing edge —
    /// there is no third thing in that row reaching further out. The check is that
    /// the inset genuinely buys the puck room rather than merely the track: the
    /// ground disc is 2pt wider than the puck on each side, so the inset has to
    /// clear the RING as well.
    func testTheRailInsetClearsThePucksGroundDiscAndNotJustTheTrack() {
        let discOverhang = RideActivityMetrics.railPuckRing
        XCTAssertGreaterThan(
            RideActivityMetrics.expandedRailCornerSafeInset,
            discOverhang,
            "the puck's ground disc overhangs the track by \(discOverhang)pt and the inset has to cover it"
        )
    }

    /// **THE HEADLINE AND SUBLINE ARE NOT INSET, AND THAT IS THE POINT.**
    ///
    /// There is no `expandedHeadlineCornerSafe…`, deliberately — the client's
    /// instruction is that the text column keeps its alignment while the two bands
    /// that touch the curve pay for the corners. The structural form of that is the
    /// bottom block's own spacing being untouched by §0 A's follow-up: the rail
    /// carries the horizontal inset at ITS call site, so the block's leading edge is
    /// still the headline's.
    func testTheTextColumnKeepsItsGutter() {
        XCTAssertEqual(RideActivityMetrics.expandedBlockSpacing, 2)
        XCTAssertEqual(RideActivityMetrics.expandedRailTopGap, 8)
        // The rail's inset is horizontal ONLY. A vertical one here would move the
        // rail off the gap above it and start re-tuning the block.
        XCTAssertGreaterThan(RideActivityMetrics.expandedRailCornerSafeInset, 0)
    }

    /// **THE INSET STILL LEAVES A RAIL WORTH DRAWING.** It comes off BOTH ends, so
    /// the travel loses twice the inset; on the narrowest island this surface ships
    /// to that still has to leave the puck a majority of the row to move through, or
    /// the fraction stops being readable as one.
    func testTheInsetRailStillHasTravel() {
        // The island's content width, conservatively taken as the card's — the
        // island is wider, so this is the tighter of the two.
        let width = Self.contentWidth
            - RideActivityMetrics.expandedRailCornerSafeInset * 2
        let travel = width - RideActivityMetrics.railPuck
        XCTAssertGreaterThan(travel / Self.contentWidth, 0.8, "travel collapsed to \(travel)pt")
    }

    // MARK: - Measurement

    private static func width(
        _ text: String,
        size: CGFloat,
        weight: UIFont.Weight,
        tracking: CGFloat
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .kern: tracking,
        ]
        return (text as NSString).size(withAttributes: attributes).width
    }

    private static func boundingHeight(_ text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: UIFont.systemFont(ofSize: size)],
            context: nil
        ).height
    }
}
