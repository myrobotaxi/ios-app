import Foundation
import MyRoboTaxiKit

// MARK: - Auth composition point (MYR-164)
//
// The ONE place the app decides which `AuthSession` backs sign-in AND which
// `TokenProvider` (if any) the live fleet / ride-request services should use, so
// the two stay in lockstep — the fleet's REST/WS calls carry the exact session
// the sign-in screen just established.
//
// Precedence (matches `TelemetryComposition` gating — live is DEBUG-only, so
// RELEASE always resolves to the simulated session, shipped demo unchanged):
//
//   1. Not live (default / RELEASE)          → SimulatedAuthSession, no provider.
//   2. Live + MRT_BACKEND_TOKEN present      → SimulatedAuthSession (the static
//      token is injected out-of-band for dev / live-scene launches; sign-in is
//      pure navigation), and the static token drives the fleet — the existing
//      override, KEPT WORKING unchanged.
//   3. Live + NO static token                → LiveAuthSession backed by a real
//      Kit `SessionTokenProvider` (Keychain-backed); that same provider is
//      handed to the fleet so one session authenticates everything.
enum AuthComposition {

    struct Result {
        let session: any AuthSession
        /// Non-nil only in case 3 above. Threaded into the telemetry + ride
        /// compositions so the live fleet reuses this session's Bearer token.
        let sessionTokenProvider: SessionTokenProvider?
    }

    @MainActor
    static func make() -> Result {
        #if DEBUG
        if let environment = TelemetryComposition.liveBackendEnvironment() {
            // Case 2 — static token override wins; keep the simulated session.
            if TelemetryComposition.staticBackendToken() != nil {
                return Result(session: SimulatedAuthSession(), sessionTokenProvider: nil)
            }
            // Case 3 — real Sign in with Apple drives a backend session. The auth
            // RestClient is pre-auth (never sends a Bearer), so its own
            // TokenProvider is a throwaway static "" that is never consulted.
            let authClient = RestClient(environment: environment, tokenProvider: StaticTokenProvider(""))
            let provider = SessionTokenProvider(auth: authClient, store: KeychainRefreshTokenStore())
            return Result(
                session: LiveAuthSession(sessionProvider: provider),
                sessionTokenProvider: provider
            )
        }
        #endif
        // Case 1 — the default.
        return Result(session: SimulatedAuthSession(), sessionTokenProvider: nil)
    }
}
