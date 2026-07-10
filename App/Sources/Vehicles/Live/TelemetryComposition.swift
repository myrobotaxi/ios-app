import Foundation
import MyRoboTaxiKit

// MARK: - Telemetry composition point (MYR-201 deliverable 2)
//
// The ONE place the app decides between the simulated fleet (M1 default, works
// offline) and the live Kit-backed fleet. `RootView` builds `OwnerHomeState`
// through here — there are no scattered `if live` conditionals anywhere else.
//
// Live mode is a DEBUG-only facility gated on launch env/args, so RELEASE builds
// always compile to the simulated fleet (identical to the shipped M1 demo):
//
//   MRT_TELEMETRY = live | sim         (default: sim)
//   MRT_BACKEND_URL = https://telemetry.myrobotaxi.app:4443   (default)
// NOTE: port 4443 is the Fly-managed API listener; :443 serves Tesla vehicle
// mTLS with a pinned cert and rejects plain API clients (split-TLS host).
//   MRT_BACKEND_TOKEN = <bearer JWT>   (supplied by the orchestrator/human;
//                                        NEVER hardcoded or committed)
//
// Auth: the production backend requires a real HS256 JWT (sub = live user CUID,
// iss=myrobotaxi, aud=telemetry, signed with the server's AUTH_SECRET). There is
// no repo-discoverable dev/static token, so the token is injected at launch via
// `MRT_BACKEND_TOKEN` and threaded through the Kit's `TokenProvider`. With no /
// an invalid token the fleet surfaces the graceful "Sign-in required" state on
// the REST 401 (deliverable 3) rather than crashing.
enum TelemetryComposition {

    /// Build the owner-home state with the fleet the launch environment selects.
    /// `sessionTokenProvider` (MYR-164) is the real Sign in with Apple session
    /// from `AuthComposition`; used in live mode when no static token overrides it.
    @MainActor
    static func makeOwnerHomeState(sessionTokenProvider: SessionTokenProvider? = nil) -> OwnerHomeState {
        #if DEBUG
        if let config = liveConfigFromEnvironment(sessionTokenProvider: sessionTokenProvider) {
            return OwnerHomeState(fleet: LiveVehicleFleet(config: config))
        }
        #endif
        return OwnerHomeState() // simulated fleet — the default
    }

    #if DEBUG
    /// The static dev/live-scene token (`MRT_BACKEND_TOKEN`), or nil when unset.
    /// When present it OVERRIDES session auth (MYR-164 env-override precedence).
    static func staticBackendToken() -> String? { value(for: "MRT_BACKEND_TOKEN") }

    /// The live `BackendEnvironment` when `MRT_TELEMETRY=live` is set, else nil.
    /// Shared by `AuthComposition` so the auth RestClient targets the same host.
    static func liveBackendEnvironment() -> BackendEnvironment? {
        guard value(for: "MRT_TELEMETRY")?.lowercased() == "live" else { return nil }
        return backendEnvironment(from: value(for: "MRT_BACKEND_URL"))
    }

    /// Returns a live-fleet config only when `MRT_TELEMETRY=live` is set (env or
    /// `-MRT_TELEMETRY live` launch arg); otherwise `nil` (simulated default).
    ///
    /// Token precedence (MYR-164): the static `MRT_BACKEND_TOKEN` OVERRIDES when
    /// present (dev / live-scene launches — the existing path, kept working);
    /// otherwise the real Sign in with Apple `sessionTokenProvider` authenticates
    /// the fleet; with neither, an empty static token → REST 401 → the graceful
    /// "Sign-in required" state (unchanged).
    static func liveConfigFromEnvironment(sessionTokenProvider: SessionTokenProvider? = nil) -> LiveVehicleFleet.Config? {
        guard let environment = liveBackendEnvironment() else { return nil }
        let tokenProvider: any TokenProvider
        if let token = staticBackendToken() {
            tokenProvider = StaticTokenProvider(token)
        } else if let sessionTokenProvider {
            tokenProvider = sessionTokenProvider
        } else {
            tokenProvider = StaticTokenProvider("")
        }
        return LiveVehicleFleet.Config(
            environment: environment,
            tokenProvider: tokenProvider
        )
    }

    /// Reads a launch var from the process env (the documented
    /// `SIMCTL_CHILD_<NAME>=` path) or a `-<NAME> <value>` launch argument,
    /// mirroring `DebugScenes`' resolution.
    static func value(for name: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty { return env }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-\(name)"), i + 1 < args.count {
            let candidate = args[i + 1]
            return candidate.isEmpty ? nil : candidate
        }
        return nil
    }

    /// Build a `BackendEnvironment` from a base URL string (default production
    /// `https://telemetry.myrobotaxi.app`). REST mounts at `/api`; the WebSocket
    /// mounts at `/api/ws` with the scheme upgraded to `wss`/`ws`.
    static func backendEnvironment(from urlString: String?) -> BackendEnvironment? {
        let base = urlString?.trimmingCharacters(in: .whitespaces)
        let resolved = (base?.isEmpty == false ? base! : "https://telemetry.myrobotaxi.app:4443")
        guard var components = URLComponents(string: resolved), let scheme = components.scheme?.lowercased() else {
            return nil
        }

        var rest = components
        rest.path = "/api"
        guard let restBaseURL = rest.url else { return nil }

        components.scheme = (scheme == "http") ? "ws" : "wss"
        components.path = "/api/ws"
        guard let webSocketURL = components.url else { return nil }

        let host = rest.host?.lowercased()
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return BackendEnvironment(
            restBaseURL: restBaseURL,
            webSocketURL: webSocketURL,
            allowsInsecureLoopback: loopback
        )
    }
    #endif
}
