import CoreLocation
import Foundation
import MyRoboTaxiKit
import Observation

// MARK: - RiderLiveVehicleLocator (MYR-211 deliverable 3 — region fallback)
//
// The rider's live-vehicle region *fallback*: when the device location isn't
// available (permission not yet granted / denied), the rider map and search
// still bias to the live vehicle's region (the client's "map is in SF, vehicle
// is in Dallas" bug) instead of the SF fixture. It fetches the account's first
// vehicle's cold snapshot over REST — one `GET`, NO socket (the owner fleet's
// socket and the live ride service already hold connections; this stays a
// cheap one-shot, refreshable on foreground), honoring the contract's
// "0,0 = no fix" convention by reporting `nil` rather than the Gulf of Guinea.
//
// This is the region-biasing hook only; wiring the rider's shared vehicle to a
// full live telemetry stream (marker/route) is future work (the shared-viewer
// live join, noted in `LiveRideRequestService`).
//
// MYR-212 deliverable 4: the same first-vehicle fetch also publishes a live
// `FleetMember` (nickname / real battery / availability / VIN-plate) so the
// rider's Review + Booking cards show the REAL vehicle instead of the fixture
// fleet (`LiveFleetMemberMapping`). Single-vehicle join only — the multi-vehicle
// picker is MYR-91 scope.
@Observable
@MainActor
final class RiderLiveVehicleLocator {
    private(set) var coordinate: CLLocationCoordinate2D?
    /// The account's first owned vehicle as a `FleetMember` (identity + live
    /// battery/availability), or `nil` until the vehicle list has loaded.
    private(set) var fleetMember: FleetMember?

    @ObservationIgnored private let rest: RestClient
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(config: LiveVehicleFleet.Config) {
        let http = config.http ?? URLSession(configuration: RestClient.defaultConfiguration())
        rest = RestClient(environment: config.environment, tokenProvider: config.tokenProvider, http: http)
    }

    /// Fetch the first vehicle's identity + last-known coordinate. Idempotent
    /// while a load is in flight; safe to call again on foreground to refresh.
    func start() {
        guard loadTask == nil else { return }
        let rest = self.rest
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard let vehicles = try? await rest.vehicles(), let first = vehicles.first else { return }
            guard !Task.isCancelled else { return }
            // Publish the live fleet identity from the list row (has nickname,
            // color, charge, VIN, status) even before the full snapshot lands.
            self?.fleetMember = LiveFleetMemberMapping.fleetMember(from: first)
            guard let state = try? await rest.snapshot(vehicleId: first.vehicleId) else { return }
            guard !Task.isCancelled else { return }
            // Contract §2.3: (0,0) is "no fix", not a valid location.
            guard !(state.latitude == 0 && state.longitude == 0) else { return }
            self?.coordinate = CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude)
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
    }
}
