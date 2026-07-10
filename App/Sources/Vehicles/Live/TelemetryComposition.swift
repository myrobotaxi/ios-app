import Foundation
import MyRoboTaxiKit

// MARK: - Telemetry composition point (MYR-201 deliverable 2; MYR-221)
//
// The ONE place the app builds `OwnerHomeState`: the simulated fleet (M1 default,
// works offline) or the live Kit-backed fleet. It no longer re-reads the launch
// env itself — it consults the single resolved `AppMode` (MYR-221), which decides
// sim-vs-live once (env-driven in the simulator, live-by-default on device). No
// other site branches on sim-vs-live.
//
// The live path is NO LONGER `#if DEBUG`-only: a device RELEASE build must reach
// it, since a Home Screen launch on the client's phone is exactly where the app
// must default to live. On the simulator, `AppMode.resolve()` stays `.simulated`
// unless `MRT_TELEMETRY=live` — so the offline demo compiles identically to before.
enum TelemetryComposition {

    /// Build the owner-home state for the resolved mode. `sessionTokenProvider`
    /// (MYR-164) is the real Sign in with Apple session from `AuthComposition`;
    /// used in live mode when no static token overrides it.
    @MainActor
    static func makeOwnerHomeState(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> OwnerHomeState {
        if let config = liveFleetConfig(mode: mode, sessionTokenProvider: sessionTokenProvider) {
            return OwnerHomeState(fleet: LiveVehicleFleet(config: config))
        }
        return OwnerHomeState() // simulated fleet — the default
    }

    /// The live-fleet config for a live `AppMode`, else nil (simulated). Shared by
    /// `RideRequestComposition` and `PlaceSearchComposition` so all three light up
    /// together on one decision.
    ///
    /// Token precedence (MYR-164): the static `MRT_BACKEND_TOKEN` OVERRIDES when
    /// present (dev / live-scene launches — the existing path, kept working);
    /// otherwise the real Sign in with Apple `sessionTokenProvider` authenticates
    /// the fleet; with neither, an empty static token → REST 401 → the graceful
    /// "Sign-in required" state (unchanged).
    static func liveFleetConfig(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> LiveVehicleFleet.Config? {
        guard let live = mode.live else { return nil }
        let tokenProvider: any TokenProvider
        if let token = live.staticToken {
            tokenProvider = StaticTokenProvider(token)
        } else if let sessionTokenProvider {
            tokenProvider = sessionTokenProvider
        } else {
            tokenProvider = StaticTokenProvider("")
        }
        return LiveVehicleFleet.Config(
            environment: live.environment,
            tokenProvider: tokenProvider
        )
    }
}
