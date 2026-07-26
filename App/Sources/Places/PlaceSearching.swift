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

    /// MYR-278 — run an actual nearby POI search for a category term (e.g.
    /// "Coffee", "Restaurants") around `regionCenter`, replacing `results` with
    /// the matching places. Invoked when the rider taps a "Search Nearby"
    /// category row (a MapKit query-type completion, which has NO single
    /// coordinate) instead of selecting it as a destination. `[]` → honest "No
    /// results"; each returned place is a real, selectable destination.
    func runNearbySearch(category: String, regionCenter: CLLocationCoordinate2D)
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

    /// MYR-278 — sim never produces "Search Nearby" category rows (the fixture
    /// filter only returns concrete places), so this is defensive: reuse the
    /// same fixture filter so a simulated category tap degrades to a normal
    /// (fixture) result set rather than doing nothing. Keeps sim behavior
    /// self-consistent and pixel-identical (no category rows ever appear).
    func runNearbySearch(category: String, regionCenter: CLLocationCoordinate2D) {
        update(query: category, regionCenter: regionCenter)
    }
}

// MARK: - RidePlace mapping (pure — MYR-211 deliverable 5)
//
// The pure translation from MapKit results to the app's `RidePlace`, factored
// out of `LivePlaceSearch` so the category→icon table, subtitle choice, and
// straight-line distance are unit-testable with hand-built values and no
// network / no completer.
enum RidePlaceMapper {

    // MARK: MYR-278 — "Search Nearby" category rows
    //
    // `MKLocalSearchCompleter` returns QUERY-type completions for category-ish
    // fragments ("coffee", "food", "gas") — MapKit labels these with the literal
    // subtitle "Search Nearby". A query completion has NO single coordinate; it
    // stands for a whole CATEGORY. The pre-278 pipeline resolved each one through
    // `MKLocalSearch` to its FIRST map item and let the rider "select" it as a
    // destination — so tapping "Coffee" silently picked one arbitrary coffee shop
    // (or, when resolution lost to Apple's throttle, an `unresolvedPlace` whose
    // coordinate is the rider's OWN location → a 0.0mi pickup→pickup break). The
    // client's report: "Search Nearby doesn't work — it just selects it as a
    // destination and breaks."
    //
    // Fix: recognize these completions, render them as a distinct category-search
    // row, and — on tap — run a real nearby `MKLocalSearch` for the category
    // whose POIs the rider then selects (see `LivePlaceSearch.runNearbySearch`).

    /// MapKit's literal subtitle on a category / multi-result query completion.
    static let nearbySearchSubtitle = "Search Nearby"

    /// True when an autocomplete suggestion is a category query completion (no
    /// single coordinate) rather than a concrete place — detected by MapKit's
    /// "Search Nearby" subtitle marker.
    ///
    /// KNOWN LIMITATION (locale) — `MKLocalSearchCompletion` exposes no public
    /// `isQuery`/result-type flag, so the only available signal is the subtitle
    /// string, and MapKit LOCALIZES it to the device region. This match is the
    /// English "Search Nearby"; on a non-English device a category completion's
    /// subtitle is translated, so detection returns false and the completion
    /// falls through to coordinate resolution (an arbitrary single place — the
    /// milder, non-crashing form of the original bug; `selectDestination` /
    /// `chooseDestination` still block the 0.0mi break). Needs a follow-up
    /// (locale-robust query-completion detection, e.g. a curated per-locale
    /// marker table or a structural signal if Apple ever exposes one).
    static func isCategoryCompletion(title: String, subtitle: String?) -> Bool {
        guard !title.isEmpty, let subtitle else { return false }
        return subtitle.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(nearbySearchSubtitle) == .orderedSame
    }

    /// A category-search row — tapping it runs a real nearby POI search instead
    /// of selecting it as a destination. Its "coordinate" is the region center
    /// as an inert placeholder (it is NEVER geocoded / routed — the UI branches
    /// on `isCategorySearch` before any select path). Distance hidden (miles 0).
    static func categorySearchPlace(title: String, regionCenter: CLLocationCoordinate2D) -> RidePlace {
        RidePlace(
            id: "live-category|\(title)",
            label: title,
            subtitle: nearbySearchSubtitle,
            miles: 0,
            minutes: 0,
            icon: "magnifyingglass",
            coordinate: regionCenter
        )
    }

    /// Whether a place is a "Search Nearby" category row (see `categorySearchPlace`).
    /// The search UI runs a nearby POI search on tap rather than a destination select.
    static func isCategorySearch(_ place: RidePlace) -> Bool {
        place.id.hasPrefix("live-category|")
    }

    /// A concise subtitle for a POI returned by a nearby `MKLocalSearch` (which
    /// resolves items directly, so there's no completer subtitle to carry) —
    /// street · locality, or nil when the placemark has neither.
    static func nearbyAddressSubtitle(_ placemark: MKPlacemark) -> String? {
        let parts = [placemark.thoroughfare, placemark.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Map a POI from a nearby `MKLocalSearch` (MYR-278) to a `RidePlace` — a
    /// real, selectable destination (real coordinate + category icon), titled by
    /// the item's own name (falling back to the category term).
    static func nearbyRidePlace(
        from item: MKMapItem,
        fallbackTitle: String,
        regionCenter: CLLocationCoordinate2D
    ) -> RidePlace {
        ridePlace(
            from: item,
            title: item.name ?? fallbackTitle,
            subtitle: nearbyAddressSubtitle(item.placemark),
            regionCenter: regionCenter
        )
    }

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

    /// Map a suggestion whose coordinate is already KNOWN (the selection-time
    /// cache, MYR-237) to a `RidePlace` — same shape as `ridePlace(from:)`
    /// minus the POI category (not cached; the generic pin icon is used).
    static func ridePlace(
        at coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String?,
        regionCenter: CLLocationCoordinate2D
    ) -> RidePlace {
        RidePlace(
            id: "live|\(title)|\(subtitle ?? "")",
            label: title,
            subtitle: (subtitle?.isEmpty == false) ? subtitle : nil,
            miles: straightLineMiles(from: regionCenter, to: coordinate),
            minutes: 0,
            icon: "mappin",
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

    /// Whether a place is a live suggestion whose coordinate was NEVER resolved
    /// (the `unresolvedPlace` placeholder — its "coordinate" is the region
    /// center, i.e. the rider's own location, NOT the place). Selection MUST
    /// re-resolve these before any distance/route math trusts the coordinate
    /// (MYR-237 device QA: an unresolved pick produced a 0.0mi trip and a
    /// pickup→pickup route request).
    static func isUnresolved(_ place: RidePlace) -> Bool {
        place.id.hasPrefix("live-unresolved|")
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
