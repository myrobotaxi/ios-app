import Foundation
import MyRoboTaxiKit

// MARK: - Place-search + location composition point (MYR-211; MYR-221)
//
// The ONE place the app decides between the simulated place-search / location
// seams (M1 default, offline demo — fixtures) and the live ones
// (`MKLocalSearchCompleter`/`CLLocationManager`, region-biased). Driven by the
// single resolved `AppMode` (MYR-221) — the same decision as
// `TelemetryComposition` / `RideRequestComposition` — so live search + live
// location light up together with live telemetry, live ride-requests, and real
// auth. No longer `#if DEBUG`: a device RELEASE build composes the live seams.
// `SharedViewerState` receives the bundle and owns the lifecycle.
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
        /// MYR-385: the schedule picker's conflict read (§7.22).
        ///
        /// **`nil` IN SIM, AND THAT IS THE WHOLE LIVE-PATH GATE.** A simulated
        /// picker does not decline to fetch, it has nothing to fetch WITH — the
        /// store refuses to construct a read without a provider — so every
        /// simulated and DEBUG capture is byte-identical without a single
        /// `isLive` branch inside the picker. Inventing fixture windows here
        /// would be a MYR-228 leak about a calendar nobody has.
        var bookedWindows: (any RideBookedWindowsProviding)?

        /// Fresh simulated seams each access (computed, not shared) so previews
        /// / tests / multiple `SharedViewerState`s never cross-talk through a
        /// single shared search state.
        @MainActor
        static var simulated: Seams {
            var userLocation: any UserLocationProviding = SimulatedUserLocation()
            #if DEBUG
            // MYR-248: a repro scene may seed a fixed simulated device fix so the
            // route-preview path (which needs a resolvable pickup) is reachable
            // headless in the simulator, without live mode's auth gate. `nil` for
            // every other scene — sim stays pixel-identical.
            if let fix = DebugScene.current?.simulatedUserFix {
                userLocation = SimulatedUserLocation(debugFix: fix)
            }
            #endif
            return Seams(
                placeSearch: SimulatedPlaceSearch(),
                userLocation: userLocation,
                liveVehicleLocator: nil,
                pinLabeler: SimulatedPinLabeler(),
                isLive: false,
                bookedWindows: nil // MYR-385 — SIM has no bookings and no endpoint
            )
        }
    }

    @MainActor
    static func make(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> Seams {
        if let config = TelemetryComposition.liveFleetConfig(mode: mode, sessionTokenProvider: sessionTokenProvider) {
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
                isLive: true,
                // MYR-385 — §7.22 through the same `RestClient` construction every
                // other live seam in this app makes. The store owns the caching and
                // the fail-open policy; this is only "where the bytes come from".
                bookedWindows: LiveRideBookedWindows(
                    endpoint: RestClient(
                        environment: config.environment,
                        tokenProvider: config.tokenProvider,
                        http: config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
                    )
                )
            )
        }
        return .simulated
    }
}
