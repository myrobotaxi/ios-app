import SwiftUI
import DesignSystem

@main
struct MyRoboTaxiApp: App {
    // MYR-186 — APNs and notification presentation are UIKit-delegate-only APIs,
    // so push needs an app delegate. It owns no policy (see `PushAppDelegate`):
    // it registers as the notification-centre delegate and forwards to the
    // coordinator `RootView` composes. Installing it changes nothing on the
    // simulated path — the coordinator there is inert.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                // Product decision (Thomas, 2026-07-06): Flat only — Liquid
                // Glass is out of scope. The look stays pinned here; the
                // MRTSurfaceLook API remains for the showcase/tests only.
                .mrtSurfaceLook(.flat)
                .preferredColorScheme(.dark)
        }
    }
}
