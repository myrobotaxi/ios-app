import CoreLocation
import Observation

// MARK: - User-location seam (MYR-211 addendum — CoreLocation)
//
// Sits alongside `PlaceSearching`: M1 ships `SimulatedUserLocation` (a no-op
// that reports "no fix", so the rider map keeps the fixture region and the
// pickup keeps flowing through Set-on-map — byte-identical to the pre-MYR-211
// behavior), and live mode swaps in `LiveUserLocation` (a `CLLocationManager`,
// when-in-use authorization only). The rider's map, search bias, and pickup all
// read this seam; none of them know which backend answered.
//
// The surfaces the UI needs:
//   • `coordinate`               — bias the search + center the map/pin-drop
//                                  (nil ⇒ fall back to the live vehicle /
//                                  fixture region).
//   • `currentLocationLabel`     — the reverse-geocoded label for the pin-drop
//                                  pickup ("Current location" until upgraded).
//   • `showsUserLocationDot`     — whether the map draws the standard blue dot.
@MainActor
protocol UserLocationProviding: AnyObject, Observable {
    /// Latest known device coordinate, or `nil` when there's no fix yet /
    /// authorization was refused. Simulated backend always reports `nil`.
    var coordinate: CLLocationCoordinate2D? { get }

    /// Display label for the pin-drop pickup centered on the rider — "Current
    /// location" until a reverse geocode upgrades it to a street/POI.
    var currentLocationLabel: String { get }

    /// Whether the map should draw the standard user-location dot (live +
    /// authorized only; always false for the simulated backend so sim
    /// screenshots stay pixel-identical).
    var showsUserLocationDot: Bool { get }

    /// Request when-in-use authorization + begin updates. Idempotent.
    func start()
    /// Stop updates. Idempotent.
    func stop()
    /// MYR-212 defect 2: force a fresh one-shot fix — called when the pin-drop
    /// phase mounts so a stale/absent cached fix doesn't leave the pin opening
    /// on the vehicle-region fallback. No-op for the simulated backend.
    func refresh()
}

// MARK: - Simulated backend (no-op — byte-identical pre-MYR-211 behavior)

/// M1 default: reports no location at all. The rider map therefore keeps the
/// fixture region (`SharedViewerState.mapRegionCenter` falls through to
/// `DriveFixtures.home`), the pickup keeps flowing through Set-on-map (no
/// current-location shortcut), and no user dot is drawn — exactly the
/// pre-MYR-211 simulated flow, so every sim scene renders identically.
@Observable
@MainActor
final class SimulatedUserLocation: UserLocationProviding {
    /// Normally `nil` (no fix — pixel-identical pre-MYR-211 sim behavior). A
    /// DEBUG scene may seed a FIXED coordinate (`debugFix`) so a headless,
    /// auth-free repro can exercise the live-shaped `routePreviewActive` path in
    /// the simulator (MYR-248 — the route preview needs a resolvable pickup, and
    /// live mode gates on real auth). `nil` in every normal/Release path, so all
    /// other sim scenes stay byte-identical.
    private let debugFix: CLLocationCoordinate2D?
    init(debugFix: CLLocationCoordinate2D? = nil) { self.debugFix = debugFix }

    var coordinate: CLLocationCoordinate2D? { debugFix }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { false }
    func start() {}
    func stop() {}
    func refresh() {}
}

// MARK: - Live backend (CLLocationManager, when-in-use)

/// The live conformer: a `CLLocationManager` requesting *when-in-use*
/// authorization only (the `NSLocationWhenInUseUsageDescription` copy is in
/// `project.yml`). Denied/restricted degrades gracefully — no coordinate, no
/// pickup, no dot — so the rider is quietly routed through Set-on-map.
@Observable
@MainActor
final class LiveUserLocation: NSObject, UserLocationProviding, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var currentLocationLabel: String = "Current location"
    private(set) var authorization: CLAuthorizationStatus

    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private var started = false
    @ObservationIgnored private var geocodeTask: Task<Void, Never>?

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var showsUserLocationDot: Bool { isAuthorized }

    private var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func start() {
        guard !started else { return }
        started = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        started = false
        manager.stopUpdatingLocation()
        geocodeTask?.cancel()
    }

    /// MYR-212 defect 2: request a fresh one-shot fix (when authorized) so the
    /// pin-drop phase opens on the freshest device coordinate rather than a
    /// stale cached one. `requestLocation` delivers a single up-to-date fix
    /// through `didUpdateLocations`; harmless if a continuous stream is already
    /// running. No-op until authorized (auth is requested by `start()`).
    func refresh() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    // MARK: CLLocationManagerDelegate (delivered on the main thread — the
    // manager was created on the main actor)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            if isAuthorized, started {
                manager.startUpdatingLocation()
            } else if !isAuthorized {
                // Denied/restricted: drop any stale fix so the UI degrades.
                coordinate = nil
                manager.stopUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated {
            coordinate = latest.coordinate
            reverseGeocode(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures leave the last-known fix in place — no UI change.
    }

    /// Best-effort reverse geocode to upgrade "Current location" to a
    /// street-level label. MYR-212 defect 1: uses the shared street-first ladder
    /// (`LivePinLabeler.streetLabel`), which never falls through to a bare city
    /// — the client's pin resolved to "Frisco" under the old ladder. Failure /
    /// no-precise-match leaves the calm "Current location" fallback untouched.
    private func reverseGeocode(_ location: CLLocation) {
        geocodeTask?.cancel()
        geocodeTask = Task { [weak self] in
            let geocoder = CLGeocoder()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
            guard !Task.isCancelled else { return }
            if let label = LivePinLabeler.streetLabel(from: placemark) {
                self?.currentLocationLabel = label
            }
        }
    }
}
