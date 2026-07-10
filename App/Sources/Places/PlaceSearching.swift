import CoreLocation
import MapKit
import Observation

// MARK: - Place-search seam (MYR-211)
//
// The M1↔live seam for the rider's destination search — mirrors the reasoning
// of `VehicleTelemetrySource`/`RideRequestService`: M1 ships
// `SimulatedPlaceSearch` (filters the SF fixture places, byte-identical to the
// pre-MYR-211 inline filter), live mode swaps in `LivePlaceSearch`
// (`MKLocalSearchCompleter` + `MKLocalSearch`, region-biased to the rider's
// location). The rider's `RideRequestSearchContent` reads `results` and calls
// `update(query:regionCenter:)`; it never knows which backend answered.
//
// `results` is a three-state value the search UI switches on, matching the
// pre-existing design behavior exactly:
//   • `nil`   → no active query: show the Saved / Recent / Nearby sections.
//   • `[]`    → a query with no matches: show "No results for …".
//   • `[…]`   → matches: show the "Results" list.
//
// Observation note (same as the other seams): reads of `results` through the
// `any PlaceSearching` existential are tracked because the concrete type is an
// `@Observable` class, so a SwiftUI body that reads it re-renders on updates.
@MainActor
protocol PlaceSearching: AnyObject, Observable {
    /// Current results for the active query — see the tri-state contract above.
    var results: [RidePlace]? { get }

    /// Set the active query and the coordinate to bias results toward (the
    /// rider's location, live-vehicle fallback, or the fixture region — resolved
    /// by `SharedViewerState.mapRegionCenter`). The simulated backend resolves
    /// synchronously; the live backend debounces + queries asynchronously.
    func update(query: String, regionCenter: CLLocationCoordinate2D)
}

// MARK: - Simulated backend (byte-identical to the pre-MYR-211 inline filter)

/// M1 default: filters `RideRequestFixtures.recentPlaces` by label/subtitle —
/// the exact predicate `RideRequestSearchContent.filteredResults` ran inline
/// before this seam existed, so every simulated scene (search / searchFiltered)
/// renders pixel-identical. `regionCenter` is ignored (fixtures are fixed SF).
@Observable
@MainActor
final class SimulatedPlaceSearch: PlaceSearching {
    private(set) var results: [RidePlace]?

    func update(query: String, regionCenter: CLLocationCoordinate2D) {
        guard !query.isEmpty else { results = nil; return }
        let q = query.lowercased()
        results = RideRequestFixtures.recentPlaces.filter {
            $0.label.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }
}

// MARK: - RidePlace mapping (pure — MYR-211 deliverable 5)
//
// The pure translation from MapKit results to the app's `RidePlace`, factored
// out of `LivePlaceSearch` so the category→icon table, subtitle choice, and
// straight-line distance are unit-testable with hand-built values and no
// network / no completer.
enum RidePlaceMapper {

    /// Straight-line distance in miles between two coordinates (v1 accepts this
    /// in place of a per-result `MKDirections` route — see MYR-211 brief).
    static func straightLineMiles(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let from = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let to = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return from.distance(from: to) * 0.000621371 // meters → miles
    }

    /// SF Symbol for a POI category. The design draws every destination row's
    /// icon in gold inside a faint gold tile (`RideRequestSearchContent.destRow`);
    /// these are the sensible category glyphs, with a generic `mappin` fallback
    /// (matching the fixture recent-places, which all use `mappin`).
    static func icon(for category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "mappin" }
        switch category {
        case .airport: return "airplane"
        case .restaurant, .foodMarket, .bakery: return "fork.knife"
        case .cafe: return "cup.and.saucer.fill"
        case .hotel: return "bed.double.fill"
        case .gasStation: return "fuelpump.fill"
        case .evCharger: return "bolt.car.fill"
        case .parking: return "parkingsign"
        case .hospital, .pharmacy: return "cross.fill"
        case .store, .laundry: return "bag.fill"
        case .bank, .atm: return "banknote.fill"
        case .park, .campground, .nationalPark: return "leaf.fill"
        case .beach, .marina: return "beach.umbrella.fill"
        case .museum, .library: return "building.columns.fill"
        case .school, .university: return "graduationcap.fill"
        case .stadium: return "sportscourt.fill"
        case .theater, .movieTheater: return "theatermasks.fill"
        case .fitnessCenter: return "figure.run"
        case .publicTransport: return "tram.fill"
        default: return "mappin"
        }
    }

    /// Map a resolved `MKMapItem` (has a real coordinate + category) to a
    /// `RidePlace`. `regionCenter` seeds the straight-line miles; `minutes` is 0
    /// (the design row hides it when 0 — see `RideRequestSearchContent.destRow`),
    /// keeping v1 off per-result routing.
    static func ridePlace(
        from item: MKMapItem,
        title: String,
        subtitle: String?,
        regionCenter: CLLocationCoordinate2D
    ) -> RidePlace {
        let coordinate = item.placemark.coordinate
        return RidePlace(
            id: "live|\(title)|\(subtitle ?? "")",
            label: title,
            subtitle: (subtitle?.isEmpty == false) ? subtitle : nil,
            miles: straightLineMiles(from: regionCenter, to: coordinate),
            minutes: 0,
            icon: icon(for: item.pointOfInterestCategory),
            coordinate: coordinate
        )
    }

    /// A suggestion whose coordinate couldn't be resolved (failed/slow
    /// `MKLocalSearch`) — kept as a row from the completer's title/subtitle so a
    /// batch never collapses to the empty state (MYR-211 defect A3). Distance is
    /// hidden (`miles == 0`, matching `destRow`'s `miles > 0` guard); the
    /// coordinate is the region center as a placeholder until the real
    /// coordinate is resolved on selection.
    static func unresolvedPlace(
        title: String,
        subtitle: String?,
        regionCenter: CLLocationCoordinate2D
    ) -> RidePlace {
        RidePlace(
            id: "live-unresolved|\(title)|\(subtitle ?? "")",
            label: title,
            subtitle: (subtitle?.isEmpty == false) ? subtitle : nil,
            miles: 0,
            minutes: 0,
            icon: "mappin",
            coordinate: regionCenter
        )
    }

    /// Saved places whose label/subtitle contain the query — ranked FIRST in the
    /// live results (MYR-211 deliverable 2, "saved places rank first, always").
    ///
    /// MYR-214: the saved-place list is now a PARAMETER (was a hardwired read of
    /// `RideRequestFixtures.savedPlaces`). The live search passes an EMPTY list
    /// so the SF fixture places ("Home · 221 Folsom St") can never surface in a
    /// live ride's destination search — a rider in Frisco tapping the fixture
    /// "Home" produced a cross-country route (client QA, MYR-214). Real saved
    /// places arrive with accounts (MYR-193); until then live = MapKit-only. The
    /// default stays the fixtures so the pure `matchingSavedPlaces` helper (and
    /// its unit tests) keep exercising the ranking predicate unchanged.
    static func matchingSavedPlaces(query: String, in savedPlaces: [RidePlace] = RideRequestFixtures.savedPlaces) -> [RidePlace] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return savedPlaces.filter {
            $0.label.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }
}
