import Foundation
import MyRoboTaxiKit

// MARK: - Composition point (MYR-186)

/// Builds the push coordinator from the ONE resolved `AppMode` — mirrors
/// `TeslaLinkComposition` / `VehicleTeardownComposition`, and reuses the live
/// fleet's resolved environment + session token provider so the device
/// registration carries the exact signed-in user's Bearer.
///
/// A coordinator is ALWAYS returned, even in simulated mode: it is then inert
/// (`isLive: false`, no endpoint), which keeps `RootView`'s wiring free of
/// optionality and keeps the "no prompt, no network, no drift" guarantee in one
/// place — the coordinator — rather than spread across every call site.
enum PushComposition {

    @MainActor
    static func makeCoordinator(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> PushRegistrationCoordinator {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else {
            return PushRegistrationCoordinator(endpoint: nil, isLive: false)
        }
        let client = RestClient(environment: config.environment, tokenProvider: config.tokenProvider)
        return PushRegistrationCoordinator(endpoint: client, isLive: true)
    }
}
