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
// The three surfaces the UI needs:
//   • `coordinate`               — bias the search + center the map (nil ⇒ fall
//                                  back to the live vehicle / fixture region).
//   • `currentPickupCoordinate`  — a usable "Current location" pickup, or nil
//                                  when denied/restricted/no-fix (⇒ Set-on-map).
//   • `showsUserLocationDot`     — whether the map draws the standard blue dot.
@MainActor
protocol UserLocationProviding: AnyObject, Observable {
    /// Latest known device coordinate, or `nil` when there's no fix yet /
    /// authorization was refused. Simulated backend always reports `nil`.
    var coordinate: CLLocationCoordinate2D? { get }

    /// The coordinate to use for a "Current location" pickup, or `nil` when it
    /// can't be offered (denied/restricted/no fix) — the caller then routes the
    /// rider through Set-on-map instead (MYR-211 addendum #5).
    var currentPickupCoordinate: CLLocationCoordinate2D? { get }

    /// Display label for the current-location pickup — "Current location" until
    /// a reverse geocode upgrades it to a street/POI.
    var currentLocationLabel: String { get }

    /// Whether the map should draw the standard user-location dot (live +
    /// authorized only; always false for the simulated backend so sim
    /// screenshots stay pixel-identical).
    var showsUserLocationDot: Bool { get }

    /// Request when-in-use authorization + begin updates. Idempotent.
    func start()
    /// Stop updates. Idempotent.
    func stop()
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
    var coordinate: CLLocationCoordinate2D? { nil }
    var currentPickupCoordinate: CLLocationCoordinate2D? { nil }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { false }
    func start() {}
    func stop() {}
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

    /// A pickup is offerable only while authorized with an actual fix.
    var currentPickupCoordinate: CLLocationCoordinate2D? {
        isAuthorized ? coordinate : nil
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

    /// Best-effort reverse geocode to upgrade "Current location" to a street/POI,
    /// mirroring `PlaceLabeler`'s ladder (POI → neighborhood → street). Failure
    /// leaves the calm "Current location" fallback untouched.
    private func reverseGeocode(_ location: CLLocation) {
        geocodeTask?.cancel()
        geocodeTask = Task { [weak self] in
            let geocoder = CLGeocoder()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
            guard !Task.isCancelled else { return }
            let poi = placemark.areasOfInterest?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let label = poi
                ?? placemark.thoroughfare
                ?? placemark.subLocality
                ?? placemark.locality
            if let label, !label.isEmpty {
                self?.currentLocationLabel = label
            }
        }
    }
}
