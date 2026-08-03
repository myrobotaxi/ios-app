import DesignSystem
import SwiftUI
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-379 — the pickup row is a FIELD now, and it must not grow
//
// "Current location stays the default and nothing changes for a rider who never
// touches it" is the guarantee this whole feature rests on, and it is a claim
// about PIXELS as much as about behaviour. Turning the pickup's `Text` into a
// `TextField` broke it quietly: measured full-frame on `riderRecentDestinations`,
// the route card grew and the entire list below it shifted **13 device px
// (4.24pt) down**. Nothing clipped and nothing overflowed, which is exactly why
// it would have shipped — it reads as a rounding difference in a screenshot and
// as nothing at all in a diff summarised as one percentage.
//
// A `TextField` is simply taller than a `Text` of the same font: it reserves
// room for an editing caret and the text container's own insets. So the pickup
// field is pinned to the height the `Text` occupied
// (`MRTMetrics.rideRoutePickupFieldHeight`), and this file is where that number
// comes from — measured through a `UIHostingController` against the REAL views,
// the `OwnerPeekBandTests` precedent, rather than typed from a screenshot.
@MainActor
final class RiderPickupRowMetricsTests: XCTestCase {

    /// The route card's text column at its shipping width: the card spans the
    /// sheet less the 16pt page gutters, less the 22pt rail inset, less the
    /// trailing capsule's room.
    private static let columnWidth: CGFloat = 240

    private func measure<V: View>(_ view: V) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: Self.columnWidth))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: Self.columnWidth, height: .greatestFiniteMagnitude)).height
    }

    /// The pre-MYR-379 pickup line, verbatim.
    private var legacyText: some View {
        Text(SharedViewerState.pickupFallbackLabel)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundStyle(Color.mrtText)
            .lineLimit(1)
    }

    /// THE NUMBER. If this ever fails, the pin below is measuring the wrong
    /// thing and the route card has started to drift again.
    func testThePinnedHeightIsTheHeightTheTextOccupied() {
        let text = measure(legacyText)
        XCTAssertEqual(
            MRTMetrics.rideRoutePickupFieldHeight, text, accuracy: 0.5,
            "the pickup field is pinned to the line it replaced — measured \(text)pt"
        )
    }

    /// The reason the pin is needed at all, asserted in the POSITIVE so it cannot
    /// quietly stop being true: an UNPINNED field is genuinely taller, which is
    /// the 4.24pt the captures found.
    func testAnUnpinnedFieldWouldBeTallerThanTheLineItReplaces() {
        let text = measure(legacyText)
        let field = measure(
            TextField("", text: .constant(""))
                .font(.system(size: 14.5, weight: .medium))
        )
        XCTAssertGreaterThan(
            field, text + 1,
            "if a TextField ever stops being taller than a Text, the pin is dead weight and should go"
        )
    }
}
