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
        /// MYR-212: reverse-geocoder for the authoritative pin's street label
        /// (sim conformer returns nil → the pin keeps its fixture string).
        var pinLabeler: any RidePinLabeling
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
                pinLabeler: SimulatedPinLabeler(),
                isLive: false
            )
        }
    }

    @MainActor
    static func make() -> Seams {
        #if DEBUG
        if let config = TelemetryComposition.liveConfigFromEnvironment() {
            return Seams(
                // MYR-214 — EMPTY saved places in live: the SF fixture places
                // ("Home · 221 Folsom St") must never rank into a live ride's
                // destination search. Real saved places arrive with MYR-193.
                placeSearch: LivePlaceSearch(savedPlaces: []),
                userLocation: LiveUserLocation(),
                liveVehicleLocator: RiderLiveVehicleLocator(config: config),
                // MYR-217: industry-style pickup-point labeling — nearby named
                // POIs + the guarded reverse geocode, best label wins (see
                // `PickupPointLabeler.swift`'s research record). The plain
                // `LivePinLabeler` remains the geocode component inside it.
                pinLabeler: LivePickupPointLabeler(),
                isLive: true
            )
        }
        #endif
        return .simulated
    }
}
