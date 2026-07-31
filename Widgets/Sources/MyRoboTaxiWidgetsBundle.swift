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
            RideActivityLockScreenView(state: context.state, isStale: context.isStale)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    RideActivityIslandExpanded(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                RideActivityIslandLeading(state: context.state)
            } compactTrailing: {
                RideActivityIslandTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                // phone-frame.jsx:29-33 — the minimal state is a single gold dot
                // with a glow, and nothing else. It is what the rider sees when
                // another app owns the island, so it says only "your ride is
                // running".
                Circle()
                    .fill(context.isStale ? Color.mrtTextMuted : Color.mrtGold)
                    .frame(width: 8, height: 8)
                    .shadow(color: context.isStale ? .clear : Color.mrtGoldGlow, radius: 4)
            }
            // Tapping any region opens the app, which routes to the rider's own
            // tracking sheet. No deep-link URL is set: the app already reconciles
            // its surface from the ride's status on foreground
            // (`SharedViewerScreen.reconcileMountedPhase`), so a URL would be a
            // second, divergent route to the same screen.
            .keylineTint(Color.mrtGold)
        }
    }
}
