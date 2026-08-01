import SwiftUI
import DesignSystem

// MARK: - RiderTrackingPeekContent (MYR-397 item 1 — the clean peek)
//
// *"Why can I drag this bottom sheet down… Leverage Opus 5 and our design system
// to achieve a clean peak state."*
//
// **WHAT HE DRAGGED DOWN TO WAS THE FULL CARD WITH ITS BOTTOM CUT OFF.** MYR-271
// put the tracking card on the `PanSheet` engine with a single hosted layer, so
// the peek detent is the SAME view translated down until only its first 150pt
// show — the itinerary sliced through a row, a plate chip half in frame, the "Look
// for" card ending in a horizontal line that goes nowhere. That is MYR-296's
// guillotine, on the surface MYR-296 was about, reintroduced by the change that
// made the sheet draggable.
//
// The fix is the one MYR-296 already settled for this sheet: **a peek LAYER of its
// own**, crossfaded against the full one by the engine's drag progress, holding
// only what a brief summary is — the status line and the ETA. Nothing is cropped
// because nothing is hidden: the peek layer is a complete composition at its own
// height, and `SHEET_HEIGHTS`' rule for every phase past search is "size to
// content" (ride-request.jsx:47), so that height is MEASURED rather than the
// guessed 150 the old single-layer peek was pinned to.
//
// **THE ETA IS THE LADDER'S, NOT THE TICKER'S.** This layer takes
// `RiderTrackingLadderState` and renders the hero pair only when it says a pickup
// countdown is honest — so MYR-393's waiting state reaches the peek as "Waiting
// for Lunar to start" with no number beside it, rather than as the peek quietly
// keeping the sentence the full card had just stopped saying.
struct RiderTrackingPeekContent: View {
    let ladder: RiderTrackingLadderState
    /// The hero pair, already formatted by the full card's own rules. `nil`
    /// whenever `ladder.showsPickupCountdown` is false OR the stage is past
    /// pickup — the peek then reads as a status line alone.
    let minutesText: String?
    let milesText: String?
    /// The one-line context under the status ("Picking you up at …" /
    /// "Dropping you off at …").
    let contextPrefix: String
    let contextPlace: String
    /// MYR-393 — the muted position-freshness qualifier, or `nil`.
    let freshnessNote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(Color.mrtGold).frame(width: 6, height: 6).shadow(color: .mrtGoldGlow, radius: 4)
                    RideEyebrowText(text: ladder.line.text, color: .mrtGold, size: 11)
                }
                (Text(contextPrefix)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mrtTextSec)
                 + Text(contextPlace)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // MYR-393 — the qualifier brings exactly its own room and nothing
                // reserves room for it (MYR-345's per-line rule): with a current
                // position there is no line and the peek measures shorter.
                if let freshnessNote {
                    Text(freshnessNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextMuted)
                        .lineLimit(1)
                        .accessibilityIdentifier("mrt.tracking.freshnessNote")
                }
            }
            Spacer(minLength: 8)
            if let minutesText, let milesText {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(minutesText)
                            .font(.system(size: 34, weight: .bold))
                            .monospacedDigit()
                            .tracking(-1)
                            .foregroundStyle(Color.mrtText)
                        Text("min")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.mrtGold.opacity(0.8))
                    }
                    Text(milesText)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtGold.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        // The peek's own bottom room. Deliberately smaller than the full card's 30
        // — a summary that ends on its last line of ink and a scrollable card that
        // ends above a home indicator are different problems, and MYR-345's rule
        // is that a band is tuned to the ink it actually holds.
        .padding(.bottom, MRTMetrics.trackingPeekBottomPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
