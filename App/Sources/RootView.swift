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
    /// First-run choice screen (app.jsx 'empty') — Add your Tesla vs Join
    /// with an invite code.
    case emptyState
    /// Owner pairing flow (app.jsx 'addTesla').
    case addTesla
    /// Rider join flow (app.jsx 'inviteCode').
    case inviteCode
    /// Post-pairing walkthrough (tutorials.jsx OwnerTutorial), 5 cards.
    case ownerTutorial
    /// Post-join walkthrough (tutorials.jsx RiderTutorial), 5 cards.
    case riderTutorial
    /// Owner Live Map + tab shell (MYR-167 — screens.jsx `HomeScreen` plus
    /// the Drives/Share/Settings tab placeholders those issues build next).
    case ownerHome
    /// Temporary M1 post-tutorial destination for the rider path — a later
    /// issue replaces it with the shared map.
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
    // Lifted above `.ownerHome`'s tab switch (app.jsx's `vehicleIdx`/`sheet`
    // are App-level state, not HomeScreen-local — screens.jsx:369) so the
    // selected vehicle, sheet detent, and each vehicle's ticking telemetry
    // survive switching to Drives/Share/Settings and back.
    @State private var ownerHomeState = OwnerHomeState()
    @State private var ownerTab = "home"

    var body: some View {
        ZStack {
            switch screen {
            case .signIn:
                SignInScreen(session: session) {
                    // First run lands on the choice screen (app.jsx 'empty');
                    // returning-user routing straight to home is a later issue.
                    screen = .emptyState
                }
            case .emptyState:
                // app.jsx:92 — the two self-describing paths.
                EmptyScreen(
                    onAdd: { screen = .addTesla },
                    onInvite: { screen = .inviteCode }
                )
            case .addTesla:
                // app.jsx:94 — onComplete → OwnerTutorial, onCancel → back to
                // the choice screen.
                AddTeslaFlow(
                    onComplete: {
                        role = .owner
                        screen = .ownerTutorial
                    },
                    onCancel: { screen = .emptyState }
                )
            case .inviteCode:
                // app.jsx:98-101 — onComplete → RiderTutorial. The `returning`
                // variant (from rider Settings) arrives with the Settings
                // screen's issue and skips the tutorial entirely.
                InviteCodeFlow(
                    onComplete: {
                        role = .shared
                        screen = .riderTutorial
                    },
                    onCancel: { screen = .emptyState }
                )
            case .ownerTutorial:
                // tutorials.jsx:363 — onDone (Continue on the last card, or
                // Skip) → Live Map (MYR-167).
                OwnerTutorial(onDone: { screen = .ownerHome })
            case .riderTutorial:
                // tutorials.jsx:374 — onDone → Shared Live Map (placeholder
                // until that issue lands).
                RiderTutorial(onDone: { screen = .signedInPlaceholder })
            case .ownerHome:
                // app.jsx:110-115 — HomeScreen owns the "home" tab; the
                // other owner tabs are simple placeholders until their
                // issues land (Drives, Share, Settings).
                switch ownerTab {
                case "drives":
                    PlaceholderScreen(icon: "clock", title: "Drives", ownerTab: $ownerTab)
                case "invites":
                    PlaceholderScreen(icon: "person.2", title: "Share", ownerTab: $ownerTab)
                case "settings":
                    PlaceholderScreen(icon: "gearshape", title: "Settings", ownerTab: $ownerTab)
                default:
                    HomeScreen(homeState: ownerHomeState, ownerTab: $ownerTab)
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
