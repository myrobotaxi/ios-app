import SwiftUI
import DesignSystem

@main
struct MyRoboTaxiApp: App {
    @AppStorage(SurfaceLook.storageKey) private var lookRaw = SurfaceLook.flat.rawValue

    private var look: SurfaceLook {
        SurfaceLook(rawValue: lookRaw) ?? .flat
    }

    var body: some Scene {
        WindowGroup {
            TokenShowcase()
                .mrtSurfaceLook(look)
                .preferredColorScheme(.dark)
        }
    }
}
