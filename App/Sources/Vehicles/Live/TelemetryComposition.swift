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
//   MRT_BACKEND_URL = https://telemetry.myrobotaxi.app   (default)
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
    @MainActor
    static func makeOwnerHomeState() -> OwnerHomeState {
        #if DEBUG
        if let config = liveConfigFromEnvironment() {
            return OwnerHomeState(fleet: LiveVehicleFleet(config: config))
        }
        #endif
        return OwnerHomeState() // simulated fleet — the default
    }

    #if DEBUG
    /// Returns a live-fleet config only when `MRT_TELEMETRY=live` is set (env or
    /// `-MRT_TELEMETRY live` launch arg); otherwise `nil` (simulated default).
    static func liveConfigFromEnvironment() -> LiveVehicleFleet.Config? {
        guard value(for: "MRT_TELEMETRY")?.lowercased() == "live" else { return nil }
        guard let environment = backendEnvironment(from: value(for: "MRT_BACKEND_URL")) else { return nil }
        let token = value(for: "MRT_BACKEND_TOKEN") ?? ""
        return LiveVehicleFleet.Config(
            environment: environment,
            tokenProvider: StaticTokenProvider(token)
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
        let resolved = (base?.isEmpty == false ? base! : "https://telemetry.myrobotaxi.app")
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
