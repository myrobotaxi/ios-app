import Foundation
import MyRoboTaxiKit

// MARK: - Sharing composition point (MYR-184)
//
// The ONE place the app decides between the fixture sharing screens and the real
// §7.5 endpoints, driven by the single resolved `AppMode` — exactly the shape
// `RideRequestComposition` / `TelemetryComposition` already have. No other site
// branches on sim-vs-live for sharing.
//
// Both halves are composed here from ONE `RestClient` so the owner's mint/revoke
// and the rider's redeem authenticate through the same session. Unlike
// `RideRequestComposition` this opens no socket: §7.5 is pure REST, and the
// viewer's live stream arrives through the existing telemetry path once the
// vehicle is in their catalog.
enum ShareComposition {

    /// The owner's sharing service. `ownedVehicles` is read live (a closure, not
    /// a snapshot) so the send-invite sheet's picker follows the fleet as it
    /// loads — see `LiveShareService.shareableVehicles`.
    @MainActor
    static func makeShareService(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil,
        ownedVehicles: @escaping @MainActor () -> [Vehicle]
    ) -> any ShareService {
        guard let rest = makeRestClient(mode: mode, sessionTokenProvider: sessionTokenProvider) else {
            return SimulatedShareService()
        }
        return LiveShareService(api: rest, ownedVehicles: ownedVehicles)
    }

    /// The rider's shared-vehicle catalog + redeem call.
    @MainActor
    static func makeSharedVehicleCatalog(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> any SharedVehicleCatalog {
        guard let rest = makeRestClient(mode: mode, sessionTokenProvider: sessionTokenProvider) else {
            return SimulatedSharedVehicleCatalog()
        }
        return LiveSharedVehicleCatalog(rest: rest)
    }

    /// The shared REST client, or `nil` when the resolved mode is simulated.
    /// Reuses `TelemetryComposition.liveFleetConfig` so sharing inherits the very
    /// same environment, token provider and (in tests) injected transport that
    /// the fleet and ride-request services do.
    @MainActor
    private static func makeRestClient(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider?
    ) -> RestClient? {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else { return nil }
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        return RestClient(environment: config.environment, tokenProvider: config.tokenProvider, http: http)
    }
}
