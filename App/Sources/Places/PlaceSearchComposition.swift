import Foundation

// MARK: - Place-search + location composition point (MYR-211)
//
// The ONE place the app decides between the simulated place-search / location
// seams (M1 default, offline demo — fixtures) and the live ones
// (`MKLocalSearchCompleter`/`CLLocationManager`, region-biased). Mirrors
// `RideRequestComposition` / `TelemetryComposition` and reuses their exact
// launch-env gating (`MRT_TELEMETRY=live`) so live search + live location light
// up together with live telemetry and live ride-requests.
//
// Live mode is DEBUG-only (RELEASE always composes the simulated seams, so the
// shipped demo is unchanged). `SharedViewerState` receives the bundle and owns
// the lifecycle.
enum PlaceSearchComposition {

    struct Seams {
        var placeSearch: any PlaceSearching
        var userLocation: any UserLocationProviding
        /// Live-vehicle region fallback (nil in sim — fixtures never need it).
        var liveVehicleLocator: RiderLiveVehicleLocator?
        /// True when the live seams were selected — gates the live-only pickup
        /// resolution + pin-drop coordinate in `SharedViewerState`.
        var isLive: Bool

        /// Fresh simulated seams each access (computed, not shared) so previews
        /// / tests / multiple `SharedViewerState`s never cross-talk through a
        /// single shared search state.
        @MainActor
        static var simulated: Seams {
            Seams(
                placeSearch: SimulatedPlaceSearch(),
                userLocation: SimulatedUserLocation(),
                liveVehicleLocator: nil,
                isLive: false
            )
        }
    }

    @MainActor
    static func make() -> Seams {
        #if DEBUG
        if let config = TelemetryComposition.liveConfigFromEnvironment() {
            return Seams(
                placeSearch: LivePlaceSearch(),
                userLocation: LiveUserLocation(),
                liveVehicleLocator: RiderLiveVehicleLocator(config: config),
                isLive: true
            )
        }
        #endif
        return .simulated
    }
}
