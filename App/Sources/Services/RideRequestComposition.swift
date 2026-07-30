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

    /// MYR-360 — the reservation seam behind the owner's ride-share pause warning,
    /// or `nil` off the live path (where the toggle does not render at all).
    ///
    /// It is composed from a `RestClient` of its own rather than lifted off the live
    /// ride-request service, and deliberately so: `RestClient` is a `Sendable`
    /// struct holding a URL, a token provider and a session — building a second one
    /// opens no connection and costs nothing, while reaching into the service would
    /// couple an owner availability control to the rider/owner RIDE pipelines
    /// (MYR-325) it has nothing to do with. It also means this feature composes
    /// with no socket at all, which is what lets a DEBUG scene drive the REAL fetch.
    @MainActor
    static func makeUpcomingReservations(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> LiveUpcomingReservations? {
        guard let config = TelemetryComposition.liveFleetConfig(mode: mode, sessionTokenProvider: sessionTokenProvider) else { return nil }
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        return LiveUpcomingReservations(
            api: RestClient(environment: config.environment, tokenProvider: config.tokenProvider, http: http)
        )
    }
}
