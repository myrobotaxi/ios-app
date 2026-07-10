import CoreLocation
import MapKit
import Observation

// MARK: - Autocomplete engine seam (MYR-211 region-bias fix)
//
// A thin abstraction over `MKLocalSearchCompleter` so the region-bias +
// distance pipeline in `LivePlaceSearch` is unit-testable with faked completer
// results (the completer itself needs MapKit's network backend and its
// `MKLocalSearchCompletion` objects can't be constructed in tests).

/// One autocomplete row, engine-agnostic. `completion` carries the real
/// completer object for coordinate resolution on the live path; tests leave it
/// `nil` and inject their own item resolver.
struct AutocompleteSuggestion {
    var title: String
    var subtitle: String
    var completion: MKLocalSearchCompletion?
}

@MainActor
protocol AutocompleteEngine: AnyObject {
    var onSuggestions: (@MainActor ([AutocompleteSuggestion]) -> Void)? { get set }
    var onFailure: (@MainActor () -> Void)? { get set }
    /// Set the active fragment + bias region. Called after the debounce window.
    func update(fragment: String, region: MKCoordinateRegion)
}

/// The production engine: wraps `MKLocalSearchCompleter` (POI + address).
@MainActor
final class LocalSearchCompleterEngine: NSObject, AutocompleteEngine, MKLocalSearchCompleterDelegate {
    var onSuggestions: (@MainActor ([AutocompleteSuggestion]) -> Void)?
    var onFailure: (@MainActor () -> Void)?

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        // Include `.query` (MYR-211 defect A1): many landmark/business searches
        // ("Northpark Center, Dallas") surface ONLY as query-type completions —
        // excluding them made whole POI queries return nothing. Query
        // completions resolve to a coordinate through `MKLocalSearch` exactly
        // like POI/address ones, so the rest of the pipeline is unchanged.
        completer.resultTypes = [.pointOfInterest, .address, .query]
        completer.delegate = self
    }

    func update(fragment: String, region: MKCoordinateRegion) {
        // Region FIRST, then the fragment — MapKit re-queries the current
        // fragment when either changes, so a repeated fragment with a new
        // region (the fix-arrived re-bias) still reaches the backend.
        completer.region = region
        completer.queryFragment = fragment
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let suggestions = completer.results.map {
            AutocompleteSuggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
        Task { @MainActor [weak self] in
            self?.onSuggestions?(suggestions)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.onFailure?()
        }
    }
}

// MARK: - LivePlaceSearch (MYR-211 deliverable 1; region-bias fix)
//
// The live conformer of `PlaceSearching`: autocomplete-as-you-type via the
// engine above, region-biased to the rider's LIVE coordinate, each suggestion
// resolved to a real coordinate (`MKLocalSearch`) so the design row can show
// straight-line miles. Saved places that match the query rank FIRST
// (deliverable 2), then the live suggestions.
//
// Debounced per Apple guidance (a keystroke doesn't fire a search); stale
// per-suggestion resolution is cancelled when a newer batch arrives.
//
// REGION-BIAS FIX (live-audit defect): the first search commonly fires BEFORE
// the first CoreLocation fix (the permission prompt is still up on first
// launch; the `searchFiltered` scene seeds its query on appear), capturing the
// fixture-fallback center — which produced globally-unbiased results with
// SF-relative distances. Two guarantees now hold:
//  1. `update(query:regionCenter:)` re-issued with the SAME query but a NEW
//     center (the view layer re-runs the active search when
//     `SharedViewerState.mapRegionCenterKey` changes) re-biases the engine
//     region AND deterministically re-resolves the cached suggestion batch
//     with the new center — distances recompute even if MapKit coalesces the
//     delegate callback for an unchanged fragment.
//  2. Distances are always computed from the CURRENT center at resolve time,
//     never a center captured when the batch was originally requested.
@Observable
@MainActor
final class LivePlaceSearch: PlaceSearching {
    /// Resolves one suggestion to a map item (real coordinate + POI category).
    /// Injectable so tests can fake resolution without MapKit's network.
    typealias ItemResolver = @MainActor (AutocompleteSuggestion) async -> MKMapItem?

    private(set) var results: [RidePlace]?

    /// Kept out of `@Observable` tracking — internal plumbing, not view state.
    @ObservationIgnored private let engine: any AutocompleteEngine
    @ObservationIgnored private let resolveItem: ItemResolver
    /// The saved places ranked ahead of live suggestions. EMPTY on the live
    /// composition path (MYR-214) so fixture SF places never poison a live
    /// destination search; real saved places populate this with accounts
    /// (MYR-193). Tests inject a list to exercise the saved-first ranking.
    @ObservationIgnored private let savedPlaces: [RidePlace]
    @ObservationIgnored private var regionCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// The last suggestion batch + the fragment it answered — re-resolved with
    /// the new center on a same-query re-bias (guarantee 1 above).
    @ObservationIgnored private var lastSuggestions: [AutocompleteSuggestion] = []
    @ObservationIgnored private var lastFragment: String?

    /// Debounce window before a fragment reaches the engine, and the cap on
    /// how many suggestions get coordinate-resolved per update.
    private let debounce: Duration
    private let maxResults: Int

    init(
        engine: (any AutocompleteEngine)? = nil,
        resolveItem: ItemResolver? = nil,
        savedPlaces: [RidePlace] = [],
        debounce: Duration = .milliseconds(250),
        maxResults: Int = 8
    ) {
        self.engine = engine ?? LocalSearchCompleterEngine()
        self.resolveItem = resolveItem ?? Self.localSearchItem
        self.savedPlaces = savedPlaces
        self.debounce = debounce
        self.maxResults = maxResults
        self.engine.onSuggestions = { [weak self] suggestions in
            guard let self else { return }
            self.lastSuggestions = suggestions
            self.lastFragment = self.query
            self.resolve(suggestions)
        }
        self.engine.onFailure = { [weak self] in
            guard let self else { return }
            // Fall back to the saved-place matches alone rather than a hard
            // failure — the design's "No results" reads calmly either way.
            self.results = RidePlaceMapper.matchingSavedPlaces(query: self.query, in: self.savedPlaces)
        }
    }

    func update(query: String, regionCenter: CLLocationCoordinate2D) {
        self.regionCenter = regionCenter
        self.query = query
        debounceTask?.cancel()

        guard !query.isEmpty else {
            // Empty query: back to the default sections immediately, no search.
            resolveTask?.cancel()
            results = nil
            return
        }

        let fragment = query
        let center = regionCenter
        let debounce = self.debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.engine.update(fragment: fragment, region: MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
            // Same query re-issued with a new center (the fix-arrived
            // re-bias): re-resolve the cached batch with the new center NOW,
            // deterministically — a fresh (better-biased) engine callback
            // supersedes it when/if MapKit re-fires.
            if fragment == self.lastFragment, !self.lastSuggestions.isEmpty {
                self.resolve(self.lastSuggestions)
            }
        }
    }

    // MARK: Coordinate resolution

    /// Resolve the top-K suggestions to map items (real coordinates + POI
    /// category) concurrently, preserving the engine's ranking, then publish
    /// `savedMatches + liveResults`. Distances come from the CURRENT
    /// `regionCenter` (guarantee 2 — never a stale captured center). Stale
    /// batches are cancelled when a newer one (or a new query) supersedes them.
    private func resolve(_ suggestions: [AutocompleteSuggestion]) {
        resolveTask?.cancel()
        let center = regionCenter
        let queryAtDispatch = query
        let savedMatches = RidePlaceMapper.matchingSavedPlaces(query: queryAtDispatch, in: savedPlaces)
        let top = Array(suggestions.prefix(maxResults))

        // No live suggestions: the saved matches (possibly empty → "No results").
        guard !top.isEmpty else {
            results = savedMatches
            return
        }

        let resolveItem = self.resolveItem
        resolveTask = Task { [weak self] in
            var resolved: [(Int, RidePlace)] = []
            await withTaskGroup(of: (Int, RidePlace).self) { group in
                for (index, suggestion) in top.enumerated() {
                    group.addTask {
                        if let item = await resolveItem(suggestion) {
                            return (index, RidePlaceMapper.ridePlace(
                                from: item,
                                title: suggestion.title,
                                subtitle: suggestion.subtitle,
                                regionCenter: center
                            ))
                        }
                        // Degrade, never drop (MYR-211 defect A3): a failed/slow
                        // `MKLocalSearch` resolution must NOT delete the row — a
                        // batch that resolved to zero rows renders the empty "No
                        // results" state even though the completer had matches.
                        // Keep the completer's title/subtitle (distance hidden,
                        // coordinate resolved on selection).
                        return (index, RidePlaceMapper.unresolvedPlace(
                            title: suggestion.title,
                            subtitle: suggestion.subtitle,
                            regionCenter: center
                        ))
                    }
                }
                for await pair in group {
                    resolved.append(pair)
                }
            }
            guard !Task.isCancelled else { return }
            let live = resolved.sorted { $0.0 < $1.0 }.map(\.1)
            await MainActor.run { [weak self] in
                guard let self, self.query == queryAtDispatch else { return }
                self.results = savedMatches + live
            }
        }
    }

    /// The live resolver: one `MKLocalSearch` per suggestion → first map item.
    private static let localSearchItem: ItemResolver = { suggestion in
        guard let completion = suggestion.completion else { return nil }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        return await withCheckedContinuation { continuation in
            search.start { response, _ in
                continuation.resume(returning: response?.mapItems.first)
            }
        }
    }
}
