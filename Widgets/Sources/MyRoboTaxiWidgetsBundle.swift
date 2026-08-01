import ActivityKit
import DesignSystem
import SwiftUI
import WidgetKit

// MARK: - The widget extension (MYR-172)
//
// V1 SHIPS EXACTLY ONE THING: the rider's ride Live Activity. Home-screen,
// lock-screen and StandBy WIDGETS are explicitly out of v1 scope (MYR-172:
// "Widgets/StandBy/owner variant: explicitly OUT of v1 — follow-ups"), even though
// the design's `surfaces.jsx` draws them, and even though this target is where
// they will go. The bundle is the extension point; adding a `Widget` beside the
// Activity later needs no target work.

@main
struct MyRoboTaxiWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivityWidget()
    }
}

struct RideLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            // The lock-screen / banner presentation.
            RideActivityLockScreenView(card: card(context))

        } dynamicIsland: { context in
            let card = card(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    RideActivityIslandExpanded(card: card)
                }
            } compactLeading: {
                RideActivityIslandLeading(card: card)
            } compactTrailing: {
                RideActivityIslandTrailing(card: card)
            } minimal: {
                // MYR-398 v2 — THE MINIMAL STATE IS THE EAST-BANKED ARROW.
                //
                // MYR-172 put a bare gold dot here (phone-frame.jsx:29-33); v1 made
                // it the mark at its own -22° bank; v2 banks it due east like every
                // other instance of it on these four surfaces. One glyph, one
                // orientation, four surfaces — an arrow that pointed north here and
                // east on the rail would read as two different marks.
                RideActivityIslandMinimal(card: card)
            }
            // Tapping any region opens the app, which routes to the rider's own
            // tracking sheet. No deep-link URL is set: the app already reconciles
            // its surface from the ride's status on foreground
            // (`SharedViewerScreen.reconcileMountedPhase`), so a URL would be a
            // second, divergent route to the same screen.
            .keylineTint(Color.mrtGold)
        }
    }

    /// The ONE place a context becomes a card.
    ///
    /// Every presentation below takes the resolved `RideActivityCard` rather than
    /// the raw context, so the lock screen, the compact island and the expanded
    /// island cannot each answer "which leg is this?" differently — and so the
    /// whole decision is a pure function the app's test bundle can drive
    /// (`RideActivityCardTests`), which is the only way any of it is assertable at
    /// all: an `ActivityViewContext` cannot be constructed in a test.
    ///
    /// The PICKUP LABEL comes off the static attributes, never off `context.state`.
    /// §7.21.3 deliberately does not push it — a pickup cannot change for the life
    /// of a ride and the app already holds it — so a widget that looked for it on
    /// the wire would render no meet-at line, forever, against a correct server.
    private func card(_ context: ActivityViewContext<RideActivityAttributes>) -> RideActivityCard {
        RideActivityCard.resolve(
            state: context.state,
            pickupLabel: context.attributes.pickupLabel,
            isStale: context.isStale
        )
    }
}
