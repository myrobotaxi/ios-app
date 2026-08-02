import DesignSystem
@testable import MyRoboTaxi
import SwiftUI
import XCTest

// MARK: - MYR-419 (client defect) — the dispatch chrome and the sheet, at every height
//
// r18, build `202608020103`: with a live dispatch and the owner sheet pulled up,
// the status pill and the gold "Dropped off" CTA sit ON TOP of the sheet's own
// hero row. Measured on iPhone 17 Pro before the fix (`ownerDispatchedEnroute`,
// `MRT_OWNER_DETENT=tall`): the sheet's top edge lands at 140 from the physical
// edge and the CTA's ink ends at ~202 — 62pt of the card standing over the
// sheet's "Driving · Cybercab / 185 mi" row.
//
// THE RULE THIS PINS is MYR-345's, applied at the sheet's TOP edge rather than
// its peek band: **a live-only element brings exactly its own room.** The sheet's
// stop is derived from the chrome that is actually on screen, so:
//
//   • no dispatch → the grammar's own 140, unchanged, and every owner capture
//     without a live ride is byte-identical;
//   • a dispatch WITH a CTA (`accepted`, `enroute`) → room for pill + CTA;
//   • a dispatch WITHOUT one (`arrived`, `completed`) → room for the pill alone,
//     because reserving a CTA's 38pt for a state that has none is MYR-345's
//     flat-24 over-reserve pointed the other way.
//
// The card is MEASURED here, through a `UIHostingController` at the real screen
// width — the `OwnerPeekBandTests` precedent — rather than re-derived on paper,
// which is exactly what let MYR-315's flat 24 stand unchallenged for an issue.
@MainActor
final class OwnerDispatchSheetClearanceTests: XCTestCase {

    /// The device the drift-gate captures are taken on, and the narrowest
    /// supported one (a pill that wrapped on a small screen would show up here as
    /// a taller card rather than in a client screenshot — the MYR-335 lesson).
    private static let screens: [(name: String, width: CGFloat, height: CGFloat, topInset: CGFloat)] = [
        ("iPhone 17 Pro", 402, 874, 62),
        ("iPhone SE/mini class", 375, 812, 47),
        ("iPhone 17 Pro Max", 440, 956, 62)
    ]

    // MARK: Measuring the real card

    /// The card as `HomeScreen` renders it for a status: the shipping status line
    /// and the shipping CTA gate, so a copy change or a state losing its button
    /// moves this measurement rather than sliding past it.
    private func card(for status: RideRequestStatus) -> OwnerDispatchCard {
        OwnerDispatchCard(
            line: OwnerRideStatusLine.text(
                status: status, riderName: "Thomas", dropoffLabel: "Galleria Dallas"
            ) ?? "",
            isComplete: status == .completed,
            action: OwnerRideStatusLine.actionTitle(for: status)
                .map { OwnerDispatchAction(title: $0, handler: {}) }
        )
    }

    private func measuredHeight(_ card: OwnerDispatchCard, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: card.frame(width: width))
        host.view.backgroundColor = .clear
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// Every status that puts a card on screen. `pending` and `declined` render
    /// none (`OwnerRideStatusLine.text` is nil), so they are not dispatch states.
    private static let dispatchStatuses: [RideRequestStatus] = [.accepted, .arrived, .enroute, .completed]

    // MARK: THE DELIVERABLE — no overlap at ANY detent, on any supported screen

    /// The sheet's top edge clears the dispatch card's last ink at every stop the
    /// ladder offers, for every dispatch state, on every supported screen.
    ///
    /// Asserted over the WHOLE ladder rather than over `tall` alone: the sheet
    /// passes through every height between its detents on the way up, so a rule
    /// stated only about the top stop is a rule a future `halfHeightFraction`
    /// could walk straight past.
    func testNoDetentRisesIntoTheDispatchCardInAnyState() {
        for screen in Self.screens {
            for status in Self.dispatchStatuses {
                let height = measuredHeight(card(for: status), width: screen.width)
                let clearance = OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: height)
                let cardBottom = OwnerMapTopChrome.dispatchCardTop + height
                let detents = MRTMetrics.sheetDetentHeights(
                    peekHeight: MRTMetrics.homePeekHeightParked,
                    halfHeight: (screen.height - screen.topInset) * MRTMetrics.homeHalfHeightFraction,
                    screenHeight: screen.height,
                    allowsTallDetent: true,
                    topClearance: clearance
                )
                for (index, detent) in detents.enumerated() {
                    let sheetTop = screen.height - detent
                    XCTAssertGreaterThanOrEqual(
                        sheetTop, cardBottom,
                        "\(screen.name) \(status) detent \(index): sheet top \(sheetTop) is inside the card (bottom \(cardBottom))"
                    )
                }
            }
        }
    }

    /// …leaving the SAME clear band below the dispatch card that the grammar's
    /// own stop leaves below the `MapHeader` chip (140 − 100 = 40), so a
    /// reserved stop reads like an unreserved one.
    func testTheSheetLeavesTheGrammarsOwnClearBandBelowTheCard() {
        XCTAssertEqual(
            OwnerMapTopChrome.dispatchCardSheetGap,
            MRTMetrics.sheetTallTopClearance - OwnerMapTopChrome.mapHeaderBottom,
            "the gap is derived from the stop it mirrors, not chosen"
        )
        for screen in Self.screens {
            for status in Self.dispatchStatuses {
                let height = measuredHeight(card(for: status), width: screen.width)
                let clearance = OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: height)
                XCTAssertEqual(
                    clearance - (OwnerMapTopChrome.dispatchCardTop + height),
                    OwnerMapTopChrome.dispatchCardSheetGap, accuracy: 0.001,
                    "\(screen.name) \(status)"
                )
            }
        }
    }

    /// **THE RUBBER BAND IS A HEIGHT TOO, AND IT IS THE ONE A SETTLED FRAME
    /// CANNOT SEE.** A finger can pull the sheet above its tallest detent;
    /// `SheetPhysics.rubberBand`'s resistance saturates at its `dimension` (30),
    /// so the highest top edge ever reachable is the stop less 30. The reserve
    /// has to absorb the whole band or the client can still photograph a gold CTA
    /// with a sheet through it — at a height no detent assertion visits.
    func testAMaximalOvershootStillCannotReachTheCard() {
        let saturation: CGFloat = 30 // SheetPhysics.rubberBand's default `dimension`
        for screen in Self.screens {
            for status in Self.dispatchStatuses {
                let height = measuredHeight(card(for: status), width: screen.width)
                let clearance = OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: height)
                let highestReachableTop = clearance - saturation
                XCTAssertGreaterThanOrEqual(
                    highestReachableTop, OwnerMapTopChrome.dispatchCardTop + height,
                    "\(screen.name) \(status): a saturated overshoot reaches \(highestReachableTop), card ends at \(OwnerMapTopChrome.dispatchCardTop + height)"
                )
            }
        }
    }

    /// The two states with a CTA reserve MORE than the two without one — the
    /// per-element half of MYR-345's rule. A flat reserve would pass every
    /// overlap assertion above and still bank ~38pt of hole under `arrived`.
    func testTheReserveIsPerCardAndNotAFlatBand() {
        let width = Self.screens[0].width
        let withCTA = Self.dispatchStatuses.filter { OwnerRideStatusLine.actionTitle(for: $0) != nil }
        let withoutCTA = Self.dispatchStatuses.filter { OwnerRideStatusLine.actionTitle(for: $0) == nil }
        XCTAssertEqual(withCTA, [.accepted, .enroute], "precondition: MYR-411's CTA gate")
        XCTAssertEqual(withoutCTA, [.arrived, .completed])

        let tallest = withoutCTA.map { measuredHeight(card(for: $0), width: width) }.max() ?? 0
        let shortest = withCTA.map { measuredHeight(card(for: $0), width: width) }.min() ?? 0
        XCTAssertGreaterThan(
            shortest, tallest + 30,
            "a card carrying the 38pt CTA must reserve visibly more than one that carries only the pill"
        )
    }

    // MARK: The no-ride path is untouched

    /// NO dispatch card ⇒ exactly the grammar's own clearance. This is what keeps
    /// `ownerHome` and every other owner capture byte-identical, and it is stated
    /// as an equality rather than a bound so a stray reserve cannot creep in.
    func testWithNoDispatchTheClearanceIsTheGrammarsOwnNumberExactly() {
        XCTAssertEqual(OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: nil), MRTMetrics.sheetTallTopClearance)
        XCTAssertEqual(OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: 0), MRTMetrics.sheetTallTopClearance)
        // A measurement that has not landed yet, and MYR-227's non-finite guard,
        // both read as "no card" rather than as a reserve of nonsense.
        XCTAssertEqual(OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: -12), MRTMetrics.sheetTallTopClearance)
        XCTAssertEqual(OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: .nan), MRTMetrics.sheetTallTopClearance)
        XCTAssertEqual(OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: .infinity), MRTMetrics.sheetTallTopClearance)
    }

    /// A dispatch card may RAISE the sheet's stop and may never lower it —
    /// swept, because the floor is the kind of guard that is right by arithmetic
    /// until somebody moves one of the two numbers under it.
    ///
    /// At the shipped geometry the floor never BINDS (`dispatchCardTop` 112 +
    /// `dispatchCardSheetGap` 40 already exceeds 140 before any card is measured),
    /// and that is asserted too rather than left as a comfortable assumption: a
    /// card carrying a live ride must never let the sheet climb higher than a
    /// screen with no ride on it.
    func testACardCanOnlyEverRaiseTheClearanceNeverLowerIt() {
        for height in stride(from: CGFloat(1), through: 400, by: 7) {
            XCTAssertGreaterThanOrEqual(
                OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: height),
                MRTMetrics.sheetTallTopClearance,
                "a \(height)pt card"
            )
        }
        XCTAssertGreaterThan(
            OwnerMapTopChrome.dispatchCardTop + OwnerMapTopChrome.dispatchCardSheetGap,
            MRTMetrics.sheetTallTopClearance,
            "the card's own placement already clears the grammar's stop, so the floor is a statement of intent rather than a live branch"
        )
    }

    /// PEEK and HALF are where every existing dispatch capture rests, and the
    /// reserve must not have moved either of them. Stated against the ladder the
    /// screen actually builds, on the capture device.
    func testPeekAndHalfAreUnmovedByTheReserve() {
        let screen = Self.screens[0]
        let height = measuredHeight(card(for: .enroute), width: screen.width)
        let container = screen.height - screen.topInset
        let half = container * MRTMetrics.homeHalfHeightFraction

        let reserved = MRTMetrics.sheetDetentHeights(
            peekHeight: MRTMetrics.homePeekHeightDriving,
            halfHeight: half,
            screenHeight: screen.height,
            allowsTallDetent: true,
            topClearance: OwnerMapTopChrome.sheetTopClearance(dispatchCardHeight: height)
        )
        let unreserved = MRTMetrics.sheetDetentHeights(
            peekHeight: MRTMetrics.homePeekHeightDriving,
            halfHeight: half,
            screenHeight: screen.height,
            allowsTallDetent: true
        )
        XCTAssertEqual(reserved[0], unreserved[0], accuracy: 0.001, "peek is the prototype's band, reserve or no reserve")
        XCTAssertEqual(reserved[1], unreserved[1], accuracy: 0.001, "half is the 0.58 fraction, reserve or no reserve")
        XCTAssertLessThan(reserved[2], unreserved[2], "…and TALL is the one stop the reserve moves")
        XCTAssertEqual(reserved.count, 3, "the tall detent survives — the owner does not silently lose it mid-ride")
    }

    /// The card's placement and the room reserved for it are ONE constant. If
    /// `HomeScreen` ever pads the overlay from something else, this fails rather
    /// than the client finding the overlap again.
    func testTheCardTopIsTheSwitcherChipsBottomPlusItsGap() {
        XCTAssertEqual(OwnerMapTopChrome.mapHeaderBottom, 100, "screens.jsx:302 top 60 + :306 height 40")
        XCTAssertEqual(
            OwnerMapTopChrome.dispatchCardTop, OwnerMapTopChrome.mapHeaderBottom + 12,
            "MYR-265 pins the card 12pt under the switcher chip"
        )
    }
}
