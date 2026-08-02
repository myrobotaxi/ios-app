import DesignSystem
@testable import MyRoboTaxi
import SwiftUI
import XCTest

// MARK: - MYR-422 — the stat row has THREE slots, and that is a measurement
//
// The client's decision brings the FSD MILES and AUTONOMOUS tiles back as "—"
// placeholders: *"should just have some place holder instead of being omitted"*,
// keeping the prototype's three-tile layout stable. MYR-414 had put the measured
// road distance in a tile of its own, so the obvious composition was FOUR:
//
//     14 min · Trip | 12.8 mi · Distance | — mi · FSD miles | — % · Autonomous
//
// **IT DOES NOT FIT, AND NOTHING IN THE ROW WOULD HAVE SAID SO.** No tile takes
// `maxWidth: .infinity`, the `HStack` has no `Spacer` and the labels have no
// ellipsis grammar — the prototype's own design, and the reason MYR-414 could drop
// a tile with no tuning. The same property makes GROWING silent: the row simply
// runs out past the page gutter. Measured here through a `UIHostingController`
// (the `OwnerPeekBandTests` / `VehicleControlTileCaptionTests` precedent):
//
//     four tiles          363.3pt
//     content band         331.0pt @375   349.0pt @393   386.0pt @430
//
// — over the gutter on the client's own device, and 32pt over on the narrowest
// supported one. Compressing the dividers cannot save it either: the worst legal
// row ("1 hr 37", a three-digit distance) is 306.3pt of TILES before a single
// divider. So the strip is the prototype's three slots and the measured distance
// rides the hero caption instead (`RideSummaryPresentation.heroDistanceMiles`).
//
// These are the measurements that decided that, kept as assertions so the next
// tile has to answer the same question.
@MainActor
final class RideSummaryStripLayoutTests: XCTestCase {

    /// Every width the app ships on, narrowest first. 375 is the floor
    /// (`VehicleControlTileCaptionTests`' own device), 393 the prototype's canvas,
    /// 430 the largest.
    private static let deviceWidths: [CGFloat] = [375, 393, 430]

    /// The band the summary's column actually has: the page less its two 22pt
    /// gutters (`RideRequestSummaryContent`'s `.padding(.horizontal, 22)`).
    private func contentWidth(_ device: CGFloat) -> CGFloat {
        device - 2 * RideSummaryStatsStrip.pageHorizontalPadding
    }

    /// The row's intrinsic width — what it WANTS, not what it was given, so an
    /// overflow reads as a number bigger than the band rather than as clipped ink
    /// nobody measured.
    private func stripWidth(_ tiles: [RideSummaryPresentation.Tile]) -> CGFloat {
        let host = UIHostingController(rootView: RideSummaryStatsStrip(tiles: tiles))
        host.view.backgroundColor = .clear
        let unbounded = CGFloat.greatestFiniteMagnitude
        return host.sizeThatFits(in: CGSize(width: unbounded, height: unbounded)).width
    }

    /// The live row, and the worst-case live row: MYR-395's hours grammar in the
    /// trip slot, both placeholders beside it.
    private static let liveRow: [RideSummaryPresentation.Tile] =
        [.trip(minutes: 14), .fsdMiles(nil), .autonomous(percent: nil)]
    private static let widestLiveRow: [RideSummaryPresentation.Tile] =
        [.trip(minutes: 97), .fsdMiles(nil), .autonomous(percent: nil)]

    /// **THE LIVE ROW FITS EVERY SUPPORTED WIDTH**, in its ordinary and its widest
    /// form. Measured: 265.0pt and 306.0pt against a 331pt floor.
    func testTheLiveThreeTileRowFitsEveryWidth() {
        for row in [Self.liveRow, Self.widestLiveRow] {
            let width = stripWidth(row)
            for device in Self.deviceWidths {
                XCTAssertLessThan(
                    width,
                    contentWidth(device),
                    "the live row overflows at \(device)pt (row \(width), band \(contentWidth(device)))"
                )
            }
        }
    }

    /// **THE FOURTH TILE IS THE MEASUREMENT THAT MOVED THE DISTANCE OFF THE STRIP.**
    /// Asserted in the POSITIVE — that it does NOT fit — so the day someone adds a
    /// tile back this file explains why the last one left, rather than silently
    /// passing because the row happens to be short that week.
    func testAFourthTileWouldNotFitThePage() {
        let four = stripWidth([
            .trip(minutes: 14),
            // The tile MYR-414 had here; the case is gone from the enum, so this
            // stands in for any fourth tile of comparable width.
            .fsdMiles(12.8),
            .fsdMiles(nil),
            .autonomous(percent: nil)
        ])
        XCTAssertGreaterThan(
            four,
            contentWidth(393),
            "a four-tile row (\(four)pt) does not fit the client's own 393pt device (band \(contentWidth(393))pt)"
        )
        XCTAssertGreaterThan(four, contentWidth(375))
    }

    /// **THE PLACEHOLDERS ARE NO WIDER THAN THE NUMBERS THEY STAND IN FOR**, so
    /// bringing the two tiles back cannot make the prototype's own row overflow.
    /// Stated as a comparison rather than as literals so it stays true when the type
    /// scale moves.
    func testAPlaceholderTileIsNoWiderThanTheSameTileWithANumber() {
        XCTAssertLessThanOrEqual(stripWidth([.fsdMiles(nil)]), stripWidth([.fsdMiles(14.2)]))
        XCTAssertLessThanOrEqual(
            stripWidth([.autonomous(percent: nil)]),
            stripWidth([.autonomous(percent: 100)])
        )
    }

    /// The SIM row is the prototype's, unchanged by this issue — measured against the
    /// same band, so a regression there is caught here rather than in the drift gate.
    func testThePrototypesThreeTileRowIsUnchangedAndFits() {
        let sim: [RideSummaryPresentation.Tile] = [
            .trip(minutes: 32),
            .fsdMiles(14.2),
            .autonomous(percent: 100)
        ]
        let width = stripWidth(sim)
        for device in Self.deviceWidths {
            XCTAssertLessThan(width, contentWidth(device))
        }
    }

    /// A row with nothing in it must occupy nothing — MYR-347's empty-section rule,
    /// which the caller enforces by not rendering the strip at all, asserted here on
    /// the view itself so the two cannot disagree.
    func testAnEmptyRowIsEmpty() {
        XCTAssertEqual(stripWidth([]), 0, accuracy: 0.5)
    }
}
