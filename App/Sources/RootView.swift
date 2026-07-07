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
    /// Temporary M1 post-tutorial destination — a later issue replaces it
    /// with the home map (owner) / shared map (rider).
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
                // Skip) → Live Map (placeholder until that issue lands).
                OwnerTutorial(onDone: { screen = .signedInPlaceholder })
            case .riderTutorial:
                // tutorials.jsx:374 — onDone → Shared Live Map (placeholder
                // until that issue lands).
                RiderTutorial(onDone: { screen = .signedInPlaceholder })
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
