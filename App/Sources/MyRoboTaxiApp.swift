import SwiftUI
import DesignSystem

@main
struct MyRoboTaxiApp: App {
    @AppStorage(MRTSurfaceLook.storageKey) private var lookRaw = MRTSurfaceLook.flat.rawValue

    private var look: MRTSurfaceLook {
        MRTSurfaceLook(rawValue: lookRaw) ?? .flat
    }

    var body: some Scene {
        WindowGroup {
            TokenShowcase()
                .mrtSurfaceLook(look)
                .preferredColorScheme(.dark)
        }
    }
}
