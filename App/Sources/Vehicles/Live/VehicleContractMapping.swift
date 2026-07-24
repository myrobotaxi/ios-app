import CoreLocation
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Contracts → view-model mapping (MYR-201 deliverable 1)
//
// The single, PURE translation layer between the Kit's generated
// `MyRobotaxiContracts` types (`VehicleSummary`, `VehicleState`) and the app's
// existing view-facing models (`Vehicle`, `VehicleActivity`,
// `VehicleTelemetrySnapshot`, `MRTVehicleStatus`). Every function here is a
// static pure map with no I/O — that is what makes the adapter unit-testable
// with contracts fixtures and no network (MYR-201 deliverable 5).
//
// Design rules honored:
// - **Neutral fallbacks for open enums** — the generated `Status`/`GearPosition`/
//   `ChargeState` enums carry an `.unrecognized(String)` arm for forward-compat
//   wire values (MYR-195). Every switch here handles it with a calm, known
//   fallback rather than crashing or inventing a look.
// - **`offline` maps to the design's Offline badge** — `MRTVehicleStatus`
//   (DesignSystem `StatusIndicators`) is exactly the design's four badge states
//   (driving/parked/charging/offline); wire `status` folds onto it.
// - **No hand-written wire shapes** — this file only READS generated properties.
enum VehicleContractMapping {

    // MARK: Status → design badge

    /// Fold the full-snapshot `VehicleState.Status` onto the design's badge set.
    /// `inService` has no shipped badge, so it takes the calm stationary
    /// `parked` fallback; `unrecognized` (a newer-contracts wire value) takes the
    /// neutral `offline` fallback rather than guessing a live state.
    static func badgeStatus(from wire: VehicleState.Status) -> MRTVehicleStatus {
        switch wire {
        case .driving: return .driving
        case .parked: return .parked
        case .charging: return .charging
        case .offline: return .offline
        case .inService: return .parked          // no in-service badge — neutral stationary
        case .unrecognized: return .offline       // forward-compat wire value — neutral
        }
    }

    /// Same fold for the lean list-row `VehicleSummary.Status` (identical arms).
    static func badgeStatus(from wire: VehicleSummary.Status) -> MRTVehicleStatus {
        switch wire {
        case .driving: return .driving
        case .parked: return .parked
        case .charging: return .charging
        case .offline: return .offline
        case .inService: return .parked
        case .unrecognized: return .offline
        }
    }

    /// Whether the snapshot's hero should render the *driving* layout. Only the
    /// literal `driving` wire status drives motion; charging/parked/offline/
    /// in_service/unrecognized are all the stationary (parked) hero.
    static func isDriving(_ wire: VehicleState.Status) -> Bool {
        if case .driving = wire { return true }
        return false
    }

    // MARK: VehicleState → telemetry snapshot (the M1/M2 seam value)

    /// Map a full `VehicleState` onto the hero's per-tick `VehicleTelemetrySnapshot`.
    /// `status` collapses to the seam's binary driving/parked (the richer badge
    /// state travels separately via ``badgeStatus(from:)``); `progress` is derived
    /// from how far along the nav route the trip has travelled.
    static func snapshot(from state: VehicleState) -> VehicleTelemetrySnapshot {
        let driving = isDriving(state.status)
        return VehicleTelemetrySnapshot(
            status: driving ? .driving : .parked,
            progress: driving ? tripProgress(from: state) : 0,
            speedMPH: max(0, state.speed),
            batteryPercent: Double(min(100, max(0, state.chargeLevel))),
            etaMinutes: driving ? max(0, state.etaMinutes ?? 0) : 0,
            // Real cabin/ambient temps — the ONLY controls-surface fields the
            // `VehicleState` contract carries today (MYR-251). Everything else on
            // the controls surface renders as unknown on the live path.
            interiorTempF: state.interiorTemp,
            exteriorTempF: state.exteriorTemp
        )
    }

    /// Fraction 0…1 of the active navigation route already travelled, derived
    /// from `tripDistanceRemaining` against the full route's planar length. The
    /// wire carries the vehicle's real GPS, but the app's `VehicleMapView` places
    /// the marker as `position(along: route, progress:)`; deriving `progress`
    /// from distance-remaining keeps that marker on the route near the real
    /// position without a projection. Returns 0 when navigation isn't active or
    /// the route/distance is unknown.
    static func tripProgress(from state: VehicleState) -> Double {
        guard let remaining = state.tripDistanceRemaining else { return 0 }
        let route = routeCoordinates(from: state.navRouteCoordinates)
        let total = VehicleRoute.totalDistanceMiles(along: route)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    // MARK: VehicleState → activity (hero + map geometry)

    /// Derive the hero/map `VehicleActivity` from a live snapshot. Driving builds
    /// a `DrivingTrip` from the navigation atomic group + geocoded origin; every
    /// other status builds a `ParkedLocation` at the vehicle's current position.
    static func activity(from state: VehicleState) -> VehicleActivity {
        if isDriving(state.status) {
            return .driving(drivingTrip(from: state))
        }
        return .parked(parkedLocation(from: state))
    }

    static func drivingTrip(from state: VehicleState) -> DrivingTrip {
        let route = routeCoordinates(from: state.navRouteCoordinates)
        let currentPosition = position(from: state)
        // Prefer the wire nav route; fall back to a straight origin→destination
        // pair when Tesla hasn't decoded a RouteLine yet, and finally to a
        // single current-position point so the marker still has geometry.
        let resolvedRoute: [CLLocationCoordinate2D]
        if route.count > 1 {
            resolvedRoute = route
        } else if let dest = destinationCoordinate(from: state) {
            resolvedRoute = [currentPosition, dest]
        } else {
            resolvedRoute = [currentPosition]
        }
        return DrivingTrip(
            destinationName: nonEmpty(state.destinationName) ?? "Navigating",
            destinationCity: cityComponent(from: state.destinationAddress) ?? "",
            originLabel: nonEmpty(state.locationName) ?? "Start",
            originAddress: state.locationAddress,
            destinationAddress: state.destinationAddress ?? "",
            route: resolvedRoute
        )
    }

    static func parkedLocation(from state: VehicleState) -> ParkedLocation {
        ParkedLocation(
            label: nonEmpty(state.locationName)
                ?? nonEmpty(state.locationAddress)
                ?? "Location unavailable",
            coordinate: position(from: state),
            parkedSince: parseTimestamp(state.lastUpdated) ?? Date()
        )
    }

    // MARK: Summary + state → fleet row (`Vehicle`)

    /// Build a `Vehicle` fleet row from a list-endpoint `VehicleSummary`, folding
    /// in the live full `VehicleState` when one has arrived (its GPS/nav upgrade
    /// the placeholder activity). `plate` has no Tesla wire field, so the last-4
    /// of the VIN stands in for human disambiguation in the switcher; seat
    /// heat/vent aren't in the read contract, so they take neutral `false`
    /// (VehicleControls degrade gracefully).
    static func vehicle(summary: VehicleSummary, state: VehicleState? = nil) -> Vehicle {
        let activity: VehicleActivity = state.map(activity(from:))
            ?? placeholderActivity(for: summary)
        return Vehicle(
            id: summary.vehicleId,
            name: nonEmpty(summary.name) ?? summary.model,
            model: modelLabel(year: summary.year, model: summary.model),
            colorName: summary.color,
            plate: plateDisplay(vinLast4: summary.vinLast4),
            seatHeat: false,
            seatVent: false,
            activity: activity
        )
    }

    /// Before the socket delivers a full snapshot, the row still needs an
    /// activity for the hero. `driving` summaries get a minimal driving trip
    /// (empty route → marker sits still); everything else parks at an unknown
    /// location. Replaced the moment the real `VehicleState` arrives.
    static func placeholderActivity(for summary: VehicleSummary) -> VehicleActivity {
        switch summary.status {
        case .driving:
            return .driving(DrivingTrip(
                destinationName: "Navigating",
                destinationCity: "",
                originLabel: "Start",
                originAddress: "",
                destinationAddress: "",
                route: []
            ))
        default:
            return .parked(ParkedLocation(
                label: "Locating…",
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                parkedSince: Date()
            ))
        }
    }

    /// The badge status for a fleet row: the live snapshot's status when present,
    /// else the summary's last-known status.
    static func badgeStatus(forSummary summary: VehicleSummary, state: VehicleState?) -> MRTVehicleStatus {
        if let state { return badgeStatus(from: state.status) }
        return badgeStatus(from: summary.status)
    }

    // MARK: - Helpers

    /// `"2024 Model 3 LR"`-style label from the year + model wire fields, matching
    /// the fixture `Vehicle.model` shape.
    static func modelLabel(year: Int, model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard year > 0 else { return trimmed }
        return "\(year) \(trimmed)"
    }

    /// Tesla telemetry has no license-plate field; the VIN last-4 stands in for
    /// human disambiguation in the switcher. Empty when the VIN is unknown.
    static func plateDisplay(vinLast4: String) -> String {
        let trimmed = vinLast4.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : "VIN ····\(trimmed)"
    }

    /// `[[lon, lat]]` (GeoJSON/Mapbox order, contracts `navRouteCoordinates`) →
    /// `CLLocationCoordinate2D`. Drops malformed pairs.
    static func routeCoordinates(from wire: [[Double]]?) -> [CLLocationCoordinate2D] {
        guard let wire else { return [] }
        return wire.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    /// The vehicle's current coordinate, honoring the contract's "0,0 = no fix"
    /// convention (§2.3) by leaving it at the origin — callers treat it as
    /// last-known geometry, never a valid Gulf-of-Guinea location.
    static func position(from state: VehicleState) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude)
    }

    static func destinationCoordinate(from state: VehicleState) -> CLLocationCoordinate2D? {
        guard let lat = state.destinationLatitude, let lon = state.destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Best-effort "city" line for the route timeline — the last-but-one
    /// comma-separated component of the destination address
    /// (e.g. "202 Stage Rd, Pescadero, CA" → "Pescadero").
    static func cityComponent(from address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 2 ? parts[parts.count - 2] : parts.last
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseTimestamp(_ value: String) -> Date? {
        iso8601.date(from: value) ?? iso8601WithFractional.date(from: value)
    }
}
