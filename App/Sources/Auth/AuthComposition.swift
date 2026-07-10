import Foundation
import MyRoboTaxiKit

// MARK: - Auth composition point (MYR-164; MYR-221)
//
// The ONE place the app decides which `AuthSession` backs sign-in AND which
// `SessionTokenProvider` (if any) the live fleet / ride-request / place-search
// services should use, so they stay in lockstep — the fleet's REST/WS calls
// carry the exact session the sign-in screen just established.
//
// Driven by the single resolved `AppMode` (MYR-221) rather than re-reading the
// launch env. Precedence:
//
//   1. `.simulated`                          → SimulatedAuthSession, no provider
//      (M1 offline demo / simulator default; also the always-succeeds sign-in).
//   2. `.live` + static `MRT_BACKEND_TOKEN`  → SimulatedAuthSession (the static
//      token is injected out-of-band for dev / live-scene launches; sign-in is
//      pure navigation), and the static token drives the fleet — the existing
//      override, KEPT WORKING unchanged.
//   3. `.live` + NO static token             → LiveAuthSession backed by a real
//      Kit `SessionTokenProvider` (Keychain-backed); that same provider is handed
//      to the fleet so one session authenticates everything. This is the DEFAULT
//      on a real device — the app is signed-out until a real Apple sign-in.
//
// No longer `#if DEBUG`: a device RELEASE build resolves case 3 and must compile
// the live session path.
enum AuthComposition {

    struct Result {
        let session: any AuthSession
        /// Non-nil only in case 3. Threaded into the telemetry / ride / place
        /// compositions so the live services reuse this session's Bearer token.
        let sessionTokenProvider: SessionTokenProvider?
        /// True when a refresh token is already stored (case 3, returning user):
        /// the app attempts a SILENT resume at launch and routes straight into the
        /// app instead of showing SignInScreen (MYR-221). False in cases 1/2.
        let hasStoredSession: Bool
    }

    @MainActor
    static func make(
        mode: AppMode = AppMode.resolve(),
        store: any RefreshTokenStore = KeychainRefreshTokenStore()
    ) -> Result {
        guard let live = mode.live else {
            // Case 1 — the default.
            return Result(session: SimulatedAuthSession(), sessionTokenProvider: nil, hasStoredSession: false)
        }
        // Case 2 — static token override wins; keep the simulated session.
        if live.staticToken != nil {
            return Result(session: SimulatedAuthSession(), sessionTokenProvider: nil, hasStoredSession: false)
        }
        // Case 3 — real Sign in with Apple drives a backend session. The auth
        // RestClient is pre-auth (never sends a Bearer), so its own TokenProvider
        // is a throwaway static "" that is never consulted.
        let authClient = RestClient(environment: live.environment, tokenProvider: StaticTokenProvider(""))
        let provider = SessionTokenProvider(auth: authClient, store: store)
        let hasStored = ((try? store.read()) ?? nil) != nil
        return Result(
            session: LiveAuthSession(sessionProvider: provider),
            sessionTokenProvider: provider,
            hasStoredSession: hasStored
        )
    }
}
