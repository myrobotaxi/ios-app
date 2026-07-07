import Foundation
import Observation

// MARK: - Auth session (M1 — simulated, MYR-164)
//
// Minimal seam between the sign-in UI and the auth backend. M1 ships only
// `SimulatedAuthSession` (no network — backend auth is MYR-193, NOT ready).
// MYR-193 replaces the implementation, not the surface: a real session will
// run ASAuthorizationController + the backend token exchange inside
// `signIn()`, which is why it is `async throws` today even though the
// simulated path cannot fail — user-cancel and network errors slot in
// without touching any call site.

@MainActor
protocol AuthSession: AnyObject {
    /// True once a session is established (simulated in M1).
    var isSignedIn: Bool { get }

    /// Establishes a session. MYR-193: Sign in with Apple + backend exchange;
    /// throws on cancel/failure. M1: resolves immediately, no network.
    func signIn() async throws

    /// Tears the session down (Settings "Sign out" flows return here).
    func signOut()
}

/// M1 stand-in — flips a local flag, touches nothing else.
@MainActor
@Observable
final class SimulatedAuthSession: AuthSession {
    private(set) var isSignedIn = false

    func signIn() async throws {
        isSignedIn = true
    }

    func signOut() {
        isSignedIn = false
    }
}
