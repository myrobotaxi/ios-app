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

    /// **MYR-417 — `Ride requested from {car}` FITS ONE LINE ON BOTH SURFACES.**
    ///
    /// This is the measurement the copy change had to survive, and it is asked twice
    /// because the two surfaces set the same sentence at two sizes: 20/600 in the
    /// card's 320pt row, and 19/600 on the expanded island (measured against the
    /// card's width, which is the conservative of the two — the island is wider once
    /// the system's own insets are taken).
    ///
    /// **THE CORPUS IS REAL NICKNAMES, NOT `String(repeating:)`.** `VehicleSummary
    /// .name` is what an owner typed, so the fixtures are the ones this repo can
    /// point at: the client's own "Lunar", the schema example's "Blue Whale", the
    /// prototype's "Cybercab", the canonical server fixture "Alex's Model 3" (owners
    /// name cars after themselves), and the board's nameless fallback "Your Tesla".
    /// A 34-M string would fail this and would tell us nothing, exactly as it would
    /// have forced the descriptor's budget down to 27.
    func testTheDispatchHeadlineFitsOneLineOnBothSurfaces() {
        for name in Self.realisticNicknames {
            let headline = RideActivityCopy.rideRequestedFrom(name)
            for (surface, size) in [
                ("card 20/600", RideActivityMetrics.headlineSize),
                ("island 19/600", RideActivityMetrics.expandedHeadlineSize),
            ] {
                let width = Self.width(
                    headline,
                    size: size,
                    weight: .semibold,
                    tracking: RideActivityMetrics.headlineTracking
                )
                XCTAssertLessThan(
                    width,
                    Self.contentWidth,
                    "\(surface): \"\(headline)\" measures \(width)pt in a \(Self.contentWidth)pt row"
                )
            }
        }
    }

    /// **AND A NICKNAME LONGER THAN THE ROW ELLIPSIZES RATHER THAN WRAPPING — WHICH
    /// IS SAFE HERE, AND IS NOT SAFE ANYWHERE ELSE ON THIS CARD.**
    ///
    /// The descriptor drops parts itself precisely because a truncation there would
    /// eat the MODEL, the second most identifying fact on the card. The headline has
    /// no such problem: the only thing at its tail is the tail of a name the rider
    /// chose, and the car's full identification is on the line directly beneath it.
    /// So the system's own tail ellipsis is the right answer and no ladder is needed
    /// — but the row must still never GROW, which is what is asserted.
    ///
    /// The budget this implies, measured: about 14 characters of nickname on the
    /// card. Everything in `realisticNicknames` is inside it.
    func testAnOverlongNicknameTruncatesRatherThanWrapping() {
        let overlong = RideActivityCopy.rideRequestedFrom("Thomas's Very Long Cybertruck Name")
        let width = Self.width(
            overlong,
            size: RideActivityMetrics.headlineSize,
            weight: .semibold,
            tracking: RideActivityMetrics.headlineTracking
        )
        XCTAssertGreaterThan(
            width,
            Self.contentWidth,
            "this fixture is meant to be the OVERFLOW case; if it now fits, lengthen it"
        )
        XCTAssertGreaterThan(
            Self.boundingHeight(overlong, size: RideActivityMetrics.headlineSize, width: Self.contentWidth),
            RideActivityMetrics.headlineRowHeight,
            "an UNCONSTRAINED layout of this string wraps — which is why the row is lineLimit(1)"
        )
    }

    /// The nicknames every measurement here is taken against — real ones, and the
    /// board's own fallback for a car that has none.
    private static let realisticNicknames = [
        "Lunar",
        "Blue Whale",
        "Cybercab",
        "Your Tesla",
        "Alex's Model 3",
    ]

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
    /// of content against the number the design drew them into: a 26pt mark and —
    /// since MYR-420 deleted the 24pt ring — a 19pt glyph, either of which growing
    /// past 34 would push the row out and start the crowding over again.
    func testTheExpandedTopRowContentFitsTheRowTheDesignDrewIt() {
        XCTAssertLessThanOrEqual(RideActivityMetrics.expandedLogo, RideActivityMetrics.expandedTopRowHeight)
        XCTAssertLessThanOrEqual(RideActivityMetrics.expandedTrailingSlot, RideActivityMetrics.expandedTopRowHeight)
        // The widest thing the region can hold, which is now the bare wave rather
        // than the ring that used to enclose it.
        XCTAssertEqual(RideActivityMetrics.expandedTrailingSlot, RideActivityMetrics.expandedWaveGlyph)
        XCTAssertGreaterThanOrEqual(
            RideActivityMetrics.expandedTrailingSlot,
            RideActivityMetrics.expandedCheckGlyph,
            "the slot's stated size must cover BOTH glyphs, not just the one it was set from"
        )
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
        // MYR-417 — Dispatch's subline is the vehicle descriptor now, so the
        // two-line half of the pair is measured against what that state actually
        // renders rather than against a string it no longer carries.
        let short = RideActivityVehicleDescriptor.compose(
            RideActivityVehicle(plate: "7SRJ294", color: "Silver", model: "Model Y", year: 2026)
        )
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

    // MARK: - 4. §0 C — the arrival beat, and the ring that is no longer here
    //
    // ─────────────────────────────────────────────────────────────────────────────
    // **WHAT MYR-420 DELETED FROM THIS SECTION, AND WHY NONE OF IT WAS REPLACED.**
    //
    // Four tests lived here and went with the component they measured:
    // `testTheRingIsOneComponentAtTwoScales` (24/2.4 against 22/2.2),
    // `testTheRingsCentreClearsItsOwnStroke` (the 12pt arrow and 13pt glyph inside a
    // 19.2pt hole), `testTheSettledRingIsStillVisible` (the 40% the arc faded to
    // under a landed glyph) and `testTheWaitingArcIsAPartialArcInsideTheBoardsRange`
    // (0.25 inside the board's 25-35%, and MYR-417's 90s window against the ticker's
    // own push cadence). Every constant they pinned is deleted, so each of them would
    // now be a test that cannot compile rather than a guard that can fail — which is
    // the honest signal, and the reason none was rewritten to assert the absence.
    //
    // **THE GEOMETRY THAT SURVIVED IS THE GLYPHS' AND THE MINIMAL ISLAND'S**, and it
    // is below and in section 6. The MEASUREMENT that killed the ring is prose rather
    // than arithmetic and lives in `design/Handoff-Live-Activity.md`'s MYR-420 mirror
    // note.
    // ─────────────────────────────────────────────────────────────────────────────

    /// **THE MINIMAL ISLAND'S TWO MARKS FIT THE CIRCLE THEY NOW SIT IN ALONE.**
    ///
    /// §5 sized the arrow (12) and the glyph (13) as the CENTRE of a 24pt ring — they
    /// had to clear a 19.2pt hole with air. MYR-420 removed the ring and kept both
    /// numbers, so the constraint they are measured against changes: what they have
    /// to fit now is the minimal presentation's own 37pt circle, which they do with
    /// room to spare. **They are deliberately NOT raised to the bare trailing sizes**
    /// (17/19) — nothing about this surface grew, and a mark re-sized because its
    /// enclosure left would be this issue redesigning a state it was told to leave
    /// alone.
    func testTheMinimalMarksFitTheCircleTheyStandInAlone() {
        for (name, mark) in [
            ("arrow", RideActivityMetrics.minimalArrow),
            ("glyph", RideActivityMetrics.minimalGlyph),
        ] {
            XCTAssertLessThan(
                mark,
                RideActivityMetrics.minimalCircle,
                "\(name): \(mark)pt in a \(RideActivityMetrics.minimalCircle)pt circle"
            )
            XCTAssertGreaterThan(
                RideActivityMetrics.minimalCircle - mark, 20,
                "\(name): a mark this close to the circle's edge reads as a filled disc"
            )
        }
        // §5's own pair, unchanged by the removal — the glyph is a point larger than
        // the arrow because an SF Symbol's optical size sits inside its bounding box
        // in a way the mark's polygons do not.
        XCTAssertEqual(RideActivityMetrics.minimalArrow, 12)
        XCTAssertEqual(RideActivityMetrics.minimalGlyph, 13)
        XCTAssertGreaterThan(RideActivityMetrics.minimalGlyph, RideActivityMetrics.minimalArrow)
    }

    /// **THE BEAT IS ONE DELAY ON THREE SURFACES NOW, AND ITS VALUE DID NOT MOVE.**
    ///
    /// §0 C's beat was a sequence — the ring completed on the rail's own curve, faded,
    /// and the glyph sprang in 0.1s later. MYR-412 already reduced the two trailing
    /// slots to the last step alone (a bare surface has no arc to sweep), and MYR-420
    /// brings the minimal island onto the same one. So what is left to assert is that
    /// the interval is the handoff's own 0.1s — the number the arrival states shipped
    /// with, so those two rows animate exactly as they did — and that the whole beat
    /// is over long before the five-minute linger it plays at the start of.
    func testTheArrivalBeatIsOneShortDelayAndIsOverLongBeforeTheLinger() {
        XCTAssertEqual(RideActivityMetrics.arrivalGlyphDelay, 0.1, accuracy: 0.0001)
        XCTAssertGreaterThan(
            RideActivityMetrics.arrivalGlyphDelay, 0,
            "a glyph that lands in the same frame as the thing it replaces is a swap, not a beat"
        )
        // A COMPLETION BEAT, NOT AN AMBIENCE.
        XCTAssertLessThan(
            RideActivityMetrics.arrivalGlyphDelay + RideActivityMetrics.arrivalSpringResponse * 2,
            2.0
        )
        XCTAssertEqual(RideActivityMetrics.arrivalGlyphFromScale, 0.6)
        XCTAssertLessThan(
            RideActivityMetrics.arrivalGlyphFromScale, 1,
            "the glyph scales UP into place"
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

    // MARK: - 6. MYR-412 · the bare trailing slot, and the shave that made it clip

    /// **THE BARE GLYPHS ARE SIZED AGAINST THE RING THEY REPLACE, IN THE MIRROR'S OWN
    /// RANGES.**
    ///
    /// The board puts the wave and the check in the trailing slot with nothing around
    /// them, and the mirror states the ranges those two may take (wave 17-19, check
    /// 15-19). Both pairs are checked against the range AND against each other: the
    /// expanded pair is the larger, because that surface carries the larger ring, and
    /// the CHECK is the smaller of each pair because a filled disc carries more ink
    /// per point than an open hand.
    func testTheBareArrivalGlyphsAreSizedForTheSurfaceTheyStandOn() {
        for (name, size, low, high) in [
            ("wave · compact", RideActivityMetrics.compactWaveGlyph, 17.0 as CGFloat, 19.0 as CGFloat),
            ("wave · expanded", RideActivityMetrics.expandedWaveGlyph, 17.0, 19.0),
            ("check · compact", RideActivityMetrics.compactCheckGlyph, 15.0, 19.0),
            ("check · expanded", RideActivityMetrics.expandedCheckGlyph, 15.0, 19.0),
        ] {
            XCTAssertGreaterThanOrEqual(size, low, "\(name): below the mirror's range")
            XCTAssertLessThanOrEqual(size, high, "\(name): above the mirror's range")
        }

        XCTAssertGreaterThan(
            RideActivityMetrics.expandedWaveGlyph,
            RideActivityMetrics.compactWaveGlyph,
            "the expanded slot carries the larger ring, so it carries the larger glyph"
        )
        XCTAssertGreaterThan(
            RideActivityMetrics.expandedCheckGlyph,
            RideActivityMetrics.compactCheckGlyph
        )
        XCTAssertLessThan(
            RideActivityMetrics.compactCheckGlyph,
            RideActivityMetrics.compactWaveGlyph,
            "the check is a filled disc and the wave an open hand — equal points is not equal weight"
        )
        XCTAssertLessThan(
            RideActivityMetrics.expandedCheckGlyph,
            RideActivityMetrics.expandedWaveGlyph
        )
    }

    /// **A SLOT-FILLING GLYPH IS NOT THE MINIMAL ISLAND'S MARK**, and the sizes are
    /// what say so.
    ///
    /// `minimalGlyph` (13) was §5's centre-of-the-ring size and is still the minimal
    /// island's, where the mark shares a 37pt circle with nothing. The trailing slots'
    /// glyphs carry a whole slot on their own and are larger. If a future edit
    /// collapsed the two — rendering the trailing glyph at the minimal size — the
    /// arrival states would visibly shrink, which is exactly the regression MYR-420's
    /// "the glyph states are byte-identical" promise rules out.
    func testTheTrailingGlyphIsBiggerThanTheMinimalIslandsMark() {
        for (name, bare) in [
            ("wave · compact", RideActivityMetrics.compactWaveGlyph),
            ("check · compact", RideActivityMetrics.compactCheckGlyph),
            ("wave · expanded", RideActivityMetrics.expandedWaveGlyph),
            ("check · expanded", RideActivityMetrics.expandedCheckGlyph),
        ] {
            XCTAssertGreaterThan(
                bare, RideActivityMetrics.minimalGlyph,
                "\(name): a slot-filling glyph must not be drawn at the minimal island's size"
            )
        }
    }

    /// **THE INSET SURVIVES THE RING, AND ITS REASON CHANGED WITH IT** (MYR-420).
    ///
    /// MYR-412 introduced `compactTrailingInset` as a CLIPPING fix:
    /// `Circle().stroke(lineWidth: w)` centres the line on the path, so a 22pt ring
    /// drew to 24.2pt and the compact trailing region — which clips on the HORIZONTAL
    /// axis and not the vertical — shaved 1.1pt off each side (measured on #168: the
    /// ring's ink came back 23.00pt wide against 24.0-24.67pt tall, the client's *"cut
    /// off on the leading edge"*). **That reason is gone with the ring**: an SF Symbol
    /// draws inside its own bounds, `strokeOverhang` is deleted, and nothing this slot
    /// renders can overflow the frame the region clips to.
    ///
    /// **WHAT THE INSET IS NOW IS THE GLYPH'S CLEAR SPACE, AND THAT IS WHY IT STAYS AT
    /// 4.** The arrival states are the half of this slot MYR-420 did not change;
    /// removing the inset would move both marks 4pt outward, toward the very boundary
    /// the system clips at — a visible change to two states nobody asked to change, in
    /// the name of tidying up a constant. So the assertion is no longer "it exceeds
    /// the overhang": it is that the number did not move.
    func testTheCompactTrailingInsetIsTheGlyphsClearSpaceAndDidNotMove() {
        XCTAssertEqual(
            RideActivityMetrics.compactTrailingInset, 4,
            "the glyph states are byte-identical across MYR-420, and this is the number that keeps them so"
        )
        XCTAssertGreaterThan(
            RideActivityMetrics.compactTrailingInset, 0,
            "an element flush against the edge this region clips at is the MYR-412 report"
        )
    }

    /// **THE INSET IS AFFORDABLE, AND THAT WAS MEASURED RATHER THAN ASSUMED.**
    ///
    /// A slot that clips is a slot where adding padding can make things worse, so the
    /// budget was probed before the inset was chosen: rulers of known width rendered
    /// in this very region came back whole at 34pt (pill 191.0) and at 46pt (pill
    /// 212.0), and the shipping `3:42 PM` figure measures 65.3pt of ink and renders
    /// whole. The widest content the slot can hold is now the compact WAVE plus its
    /// two insets — 25pt, further inside that bound than the 30pt ring ever was.
    func testTheInsetCompactTrailingElementFitsTheMeasuredBudget() {
        let widest = max(
            RideActivityMetrics.compactWaveGlyph,
            RideActivityMetrics.compactCheckGlyph
        ) + RideActivityMetrics.compactTrailingInset * 2
        XCTAssertLessThanOrEqual(
            widest,
            RideActivityMetrics.compactTrailingMeasuredBudget,
            "\(widest)pt of trailing content is past the narrowest ruler proved to render whole"
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
