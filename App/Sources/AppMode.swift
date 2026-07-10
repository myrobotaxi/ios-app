import Foundation
import MyRoboTaxiKit

// MARK: - App mode (MYR-221 — the ONE launch-mode decision)
//
// Single source of truth for how the app is wired at launch: LIVE (production
// backend + real Sign in with Apple session auth) or SIMULATED (M1 fixtures,
// always-succeeds sign-in). Every composition point (Auth / Telemetry /
// RideRequest / PlaceSearch) reads this ONE resolved value instead of each
// re-reading `MRT_TELEMETRY` — so the sim-vs-live decision lives in exactly one
// place and cannot drift between the four.
//
// The decision is PLATFORM-DEPENDENT — that is the whole bug this issue fixes:
//
//   • REAL DEVICE (`!targetEnvironment(simulator)`) → `.live` by DEFAULT.
//     A Home Screen launch on the client's phone carries no simctl env, so
//     gating live (and therefore real auth) on `MRT_TELEMETRY=live` — which is
//     only ever set for the simulator — silently dropped device builds into
//     fixture mode, and SignInScreen ran its always-succeeds fixture sign-in
//     with no Apple sheet. On device the app now targets the production backend
//     and requires a real Apple sign-in. `MRT_BACKEND_URL` / `MRT_BACKEND_TOKEN`
//     remain honored as OPTIONAL dev overrides for our own on-device debugging;
//     the DEFAULT (no env) is production + real session auth.
//   • SIMULATOR → env-driven, EXACTLY as before: `.simulated` unless
//     `MRT_TELEMETRY=live` is set. Our offline demo, the DEBUG scene hooks, and
//     the drift-gate captures all depend on this branch being unchanged.
enum AppMode: Equatable {
    /// M1 fixtures — no network, always-succeeds simulated sign-in.
    case simulated
    /// Production/live backend. `staticToken` is the `MRT_BACKEND_TOKEN` dev
    /// override when present; `nil` means real Sign in with Apple drives auth.
    case live(LiveConfig)

    struct LiveConfig: Equatable {
        var environment: BackendEnvironment
        /// The static `MRT_BACKEND_TOKEN` override (dev / live-scene). When
        /// present it bypasses session auth and drives the fleet directly; when
        /// nil, the real `SessionTokenProvider` (Sign in with Apple) authenticates.
        var staticToken: String?
    }

    /// The live config when in a live mode, else nil. Convenience for the
    /// compositions so they never re-`switch` on the enum.
    var live: LiveConfig? {
        if case let .live(config) = self { return config }
        return nil
    }
}

extension AppMode {

    // MARK: - Resolution

    /// Resolve the launch mode.
    ///
    /// `isSimulator` is INJECTED (defaulting to the real compile-time value) so
    /// tests can exercise BOTH branches — `#if targetEnvironment(simulator)`
    /// cannot be toggled at runtime, so the platform check is wrapped in the one
    /// `isSimulatorBuild` seam and threaded through here as a parameter.
    static func resolve(
        isSimulator: Bool = isSimulatorBuild,
        env: (String) -> String? = AppMode.launchValue
    ) -> AppMode {
        if isSimulator {
            // Simulator: unchanged env-driven gating — live ONLY when explicitly
            // selected via `MRT_TELEMETRY=live` (the existing demo/drift posture).
            guard env("MRT_TELEMETRY")?.lowercased() == "live",
                  let environment = backendEnvironment(from: env("MRT_BACKEND_URL"))
            else { return .simulated }
            return .live(LiveConfig(environment: environment, staticToken: env("MRT_BACKEND_TOKEN")))
        } else {
            // Device DEFAULT: live against production. A dev `MRT_BACKEND_URL`
            // still redirects the host and `MRT_BACKEND_TOKEN` still overrides
            // auth (both optional), but with NO env the app is production + real
            // Apple sign-in — never fixture mode.
            let environment = backendEnvironment(from: env("MRT_BACKEND_URL")) ?? productionEnvironment
            return .live(LiveConfig(environment: environment, staticToken: env("MRT_BACKEND_TOKEN")))
        }
    }

    /// The compile-time platform, wrapped so `resolve` can be unit-tested for the
    /// OTHER branch. This property is the single `#if targetEnvironment` seam in
    /// the app's mode logic.
    static var isSimulatorBuild: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Launch environment reading
    //
    // Reads a launch var from the process env (the documented
    // `SIMCTL_CHILD_<NAME>=` path) or a `-<NAME> <value>` launch argument,
    // mirroring `DebugScenes`' resolution. Lives here (not `TelemetryComposition`)
    // so it compiles on a device RELEASE build — the whole point of the fix is
    // that the live path is no longer `#if DEBUG`-only.

    static func launchValue(_ name: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty { return env }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-\(name)"), i + 1 < args.count {
            let candidate = args[i + 1]
            return candidate.isEmpty ? nil : candidate
        }
        return nil
    }

    /// The production backend (`MRT_BACKEND_URL` unset). The Fly-managed API
    /// listener on :4443 — :443 serves Tesla vehicle mTLS and rejects plain API
    /// clients (split-TLS host).
    static var productionEnvironment: BackendEnvironment {
        // `backendEnvironment(from: nil)` resolves the production default and
        // never returns nil for the hardcoded URL.
        backendEnvironment(from: nil)!
    }

    /// Build a `BackendEnvironment` from a base URL string (default production
    /// `https://telemetry.myrobotaxi.app:4443`). REST mounts at `/api`; the
    /// WebSocket mounts at `/api/ws` with the scheme upgraded to `wss`/`ws`.
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
}
