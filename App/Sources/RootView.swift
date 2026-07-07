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
    /// Temporary M1 post-flow destination — MYR-166 replaces it with the
    /// Owner/Rider tutorials, then the home map (owner) / shared map (rider).
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
                // app.jsx:94 — onComplete → OwnerTutorial (MYR-166; placeholder
                // until it lands), onCancel → back to the choice screen.
                AddTeslaFlow(
                    onComplete: {
                        role = .owner
                        screen = .signedInPlaceholder
                    },
                    onCancel: { screen = .emptyState }
                )
            case .inviteCode:
                // app.jsx:98-101 — onComplete → RiderTutorial (MYR-166;
                // placeholder until it lands). The `returning` variant (from
                // rider Settings) arrives with the Settings screen's issue.
                InviteCodeFlow(
                    onComplete: {
                        role = .shared
                        screen = .signedInPlaceholder
                    },
                    onCancel: { screen = .emptyState }
                )
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
