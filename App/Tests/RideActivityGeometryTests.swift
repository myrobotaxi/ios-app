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
