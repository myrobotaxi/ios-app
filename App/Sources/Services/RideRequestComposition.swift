import Foundation
import MyRoboTaxiKit

// MARK: - Ride-request composition point (MYR-209; MYR-221)
//
// The ONE place the app decides between the simulated ride-request service (M1
// default, offline demo) and the live Kit-backed one — driven by the single
// resolved `AppMode` (MYR-221) so live telemetry, live ride-requests, live search
// and real auth all light up together on one decision. No other site branches on
// sim-vs-live.
//
// No longer `#if DEBUG`: a device RELEASE build composes the live service.
//
// NOTE (v1): the live service opens its OWN `TelemetrySocket` (its own WS
// connection), independent of the owner fleet's socket. Two authenticated
// connections under one user is acceptable for the demo — the server unicasts
// ride frames to every authed connection of the ride's parties. Sharing a single
// socket across the fleet + ride service is a future consolidation.
enum RideRequestComposition {

    @MainActor
    static func makeService(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> any RideRequestService {
        if let live = makeLiveService(mode: mode, sessionTokenProvider: sessionTokenProvider) { return live }
        return SimulatedRideRequestService() // the default
    }

    @MainActor
    static func makeLiveService(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> LiveRideRequestService? {
        guard let config = TelemetryComposition.liveFleetConfig(mode: mode, sessionTokenProvider: sessionTokenProvider) else { return nil }
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        let rest = RestClient(environment: config.environment, tokenProvider: config.tokenProvider, http: http)
        let socket = TelemetrySocket(
            webSocketURL: config.environment.webSocketURL,
            tokenProvider: config.tokenProvider,
            snapshotSource: rest,
            channelFactory: config.channelFactory ?? URLSessionWebSocketChannelFactory()
        )
        return LiveRideRequestService(api: rest, socket: socket)
    }
}
