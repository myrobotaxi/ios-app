import SwiftUI
import DesignSystem

@main
struct MyRoboTaxiApp: App {
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
