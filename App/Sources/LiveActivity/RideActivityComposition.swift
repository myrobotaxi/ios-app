import Foundation
import MyRoboTaxiKit

// MARK: - Composition point (MYR-172)

/// Builds the Live Activity coordinator from the ONE resolved `AppMode`, exactly
/// as `PushComposition` builds the device-registration coordinator — same
/// `liveFleetConfig` gate, same `RestClient`, same signed-in Bearer.
///
/// A coordinator is ALWAYS returned. In simulated mode it is INERT (`isLive:
/// false`, no endpoint) rather than nil, so `RootView` has no optionality to
/// thread and the "no ActivityKit, no network, no drift" guarantee lives in one
/// place. That matters more here than it does for push: a fixture ride putting a
/// real card on a real lock screen would be visible to a human, not just to a
/// test.
enum RideActivityComposition {

    /// `serverRideID` is the rider pipeline's `activeServerRideID` — MYR-415. It is
    /// a CLOSURE for the same reason `vehicle` is: the id lands asynchronously (the
    /// create POST's acknowledgement), and the Activity is started before it, so a
    /// value captured here would be `nil` for the session.
    @MainActor
    static func makeCoordinator(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil,
        vehicleName: @escaping @MainActor () -> String = { "" },
        vehicle: @escaping @MainActor () -> RideActivityVehicle? = { nil },
        serverRideID: @escaping @MainActor () -> String? = { nil }
    ) -> RideActivityCoordinator {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else {
            return RideActivityCoordinator(
                presenter: SystemRideActivityPresenter(),
                endpoint: nil,
                isLive: false,
                vehicleName: vehicleName,
                vehicle: vehicle,
                serverRideID: serverRideID
            )
        }
        let client = RestClient(environment: config.environment, tokenProvider: config.tokenProvider)
        return RideActivityCoordinator(
            presenter: SystemRideActivityPresenter(),
            endpoint: client,
            isLive: true,
            vehicleName: vehicleName,
            vehicle: vehicle,
            serverRideID: serverRideID
        )
    }
}
