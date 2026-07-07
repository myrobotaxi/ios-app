import SwiftUI
import DesignSystem

// MARK: - Routing shell (MYR-164)
//
// Deliberately tiny. Adding a screen = add an `AppScreen` case + a `switch`
// arm in `RootView`. Screens never see the router — they get callbacks —
// so later issues (home map, drives, settings, …) extend this without
// rewiring existing screens.

/// Top-level screens. Mirrors the prototype's `screen` state
/// (design/app/app.jsx `aS('…')`), one case per ported screen.
enum AppScreen: Hashable {
    case signIn
    /// Temporary M1 post-auth destination — replaced by the real home map
    /// (owner) / shared map (rider) as those screens land.
    case signedInPlaceholder
}

/// Persona — the prototype's Owner / Shared flow switch
/// (design/app/app.jsx `role`). Sign-in is shared; everything after it
/// branches on this.
enum UserRole: String {
    case owner
    case shared
}

struct RootView: View {
    @State private var session = SimulatedAuthSession()
    @State private var screen: AppScreen = .signIn
    @State private var role: UserRole = .owner

    var body: some View {
        ZStack {
            switch screen {
            case .signIn:
                SignInScreen(session: session) {
                    // app.jsx: onSignIn → role === 'shared' ? 'shared' : 'home'.
                    // Both land on the placeholder until those screens exist.
                    screen = .signedInPlaceholder
                }
            case .signedInPlaceholder:
                TokenShowcase()
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
    }
}

#Preview {
    RootView()
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
