import Foundation
import MyRoboTaxiKit

// MARK: - Notification-preference composition point (MYR-349)
//
// The ONE place the app decides between the prototype's local toggles and the
// real §7.19 endpoint, driven by the single resolved `AppMode` — exactly the
// shape `ShareComposition` / `PushComposition` / `RideRequestComposition` already
// have. No other site branches on sim-vs-live for notification preferences.
enum PushPrefsComposition {

    /// The account's notification preferences. `SimulatedPushPrefsService` (the
    /// prototype's own positions, zero network, every DEBUG capture scene) unless
    /// the resolved mode is live, in which case `LivePushPrefsService` against
    /// rest-api.md §7.19.
    ///
    /// A service is ALWAYS returned rather than an optional, unlike `linkedVehicles`
    /// / `teardown`: the toggles must render on both paths (they always have), so
    /// there is no "absent" arm for a screen to reason about. What changes is
    /// whether the value behind them is anybody's but the view's.
    @MainActor
    static func makeService(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> any PushPrefsService {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else {
            return SimulatedPushPrefsService()
        }
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        let client = RestClient(
            environment: config.environment,
            tokenProvider: config.tokenProvider,
            http: http
        )
        return LivePushPrefsService(endpoint: client)
    }
}
