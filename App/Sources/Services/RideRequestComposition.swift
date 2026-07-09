import Foundation
import MyRoboTaxiKit

// MARK: - Ride-request composition point (MYR-209)
//
// The ONE place the app decides between the simulated ride-request service (M1
// default, offline demo) and the live Kit-backed one — mirrors
// `TelemetryComposition.makeOwnerHomeState()` and reuses its exact launch-env
// gating so live telemetry and live ride-requests light up together:
//
//   MRT_TELEMETRY = live | sim   (default: sim)
//   MRT_BACKEND_URL / MRT_BACKEND_TOKEN — as documented in `TelemetryComposition`.
//
// Live mode is DEBUG-only (RELEASE always compiles to the simulated service, so
// the shipped demo is unchanged). No other site branches on sim-vs-live.
//
// NOTE (v1): the live service opens its OWN `TelemetrySocket` (its own WS
// connection), independent of the owner fleet's socket. Two authenticated
// connections under one user is acceptable for the demo — the server unicasts
// ride frames to every authed connection of the ride's parties. Sharing a single
// socket across the fleet + ride service is a future consolidation.
enum RideRequestComposition {

    @MainActor
    static func makeService() -> any RideRequestService {
        #if DEBUG
        if let live = makeLiveService() { return live }
        #endif
        return SimulatedRideRequestService() // the default
    }

    #if DEBUG
    @MainActor
    static func makeLiveService() -> LiveRideRequestService? {
        guard let config = TelemetryComposition.liveConfigFromEnvironment() else { return nil }
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
    #endif
}
