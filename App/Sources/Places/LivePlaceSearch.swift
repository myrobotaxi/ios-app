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
    /// MYR-278 — true when this is a category / multi-result query completion
    /// (MapKit's "Search Nearby" rows), which has no single coordinate. Such a
    /// suggestion becomes a category-search row, NOT a resolvable destination.
    var isQueryCategory: Bool = false
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
            AutocompleteSuggestion(
                title: $0.title,
                subtitle: $0.subtitle,
                completion: $0,
                // MYR-278 — flag MapKit's category / "Search Nearby" query rows
                // so the pipeline renders them as a nearby-search trigger rather
                // than resolving them to one arbitrary place.
                isQueryCategory: RidePlaceMapper.isCategoryCompletion(title: $0.title, subtitle: $0.subtitle)
            )
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

    /// MYR-278 — runs a nearby category `MKLocalSearch` (natural-language query +
    /// region), returning the matching POIs. Injectable so the nearby-search
    /// behavior is unit-testable without MapKit's network.
    typealias NearbyResolver = @MainActor (_ category: String, _ regionCenter: CLLocationCoordinate2D) async -> [MKMapItem]

    private(set) var results: [RidePlace]?

    /// Kept out of `@Observable` tracking — internal plumbing, not view state.
    @ObservationIgnored private let engine: any AutocompleteEngine
    @ObservationIgnored private let resolveItem: ItemResolver
    @ObservationIgnored private let resolveNearby: NearbyResolver
    @ObservationIgnored private var nearbyTask: Task<Void, Never>?
    /// MYR-278 (live-regression fix) — the category term of the ACTIVE nearby
    /// search, or nil in normal autocomplete mode. On the live path the device
    /// streams ~1Hz fixes; each fix re-runs the active query with a new center
    /// (`SharedViewerState.mapRegionCenterKey` onChange). Without this, that
    /// re-run went through `update` → re-resolved the last autocomplete batch →
    /// republished the "Search Nearby" category ROW over the tapped POIs (the
    /// results survived ~250ms then flipped back on any moving device). While a
    /// category is active, a same-category `update` (a re-bias) is a no-op that
    /// keeps the POIs; a DIFFERENT query (the rider typed) exits nearby mode.
    @ObservationIgnored private var activeNearbyCategory: String?
    /// The saved places ranked ahead of live suggestions. EMPTY on the live
    /// composition path (MYR-214) so fixture SF places never poison a live
    /// destination search; real saved places populate this with accounts
    /// (MYR-193). Tests inject a list to exercise the saved-first ranking.
    @ObservationIgnored private let savedPlaces: [RidePlace]
    @ObservationIgnored private var regionCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Resolved coordinates by suggestion identity (MYR-237): each keystroke
    /// batch re-ranked the SAME suggestions and re-resolved every one — one
    /// `MKLocalSearch` per row per batch (typing a word cost ~30 requests),
    /// which is what tripped Apple's throttle and produced unresolved rows.
    /// A resolved coordinate is stable for a session; cache it.
    @ObservationIgnored private var coordinateCache: [String: CLLocationCoordinate2D] = [:]

    nonisolated private static func cacheKey(_ s: AutocompleteSuggestion) -> String { "\(s.title)|\(s.subtitle ?? "")" }
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// The last suggestion batch + the fragment it answered — re-resolved with
    /// the new center on a same-query re-bias (guarantee 1 above).
    @ObservationIgnored private var lastSuggestions: [AutocompleteSuggestion] = []
    @ObservationIgnored private var lastFragment: String?

    // MARK: MYR-371 — the supersede token
    //
    // Every publish path was guarded by `self.query == <value captured at
    // dispatch>`, which is a correct test for "did the rider type something
    // else" and a BROKEN one for "did the rider CLEAR the field": clearing sets
    // `query` to `""`, and `"" == ""` passes. So a completer batch still in
    // flight when the field was emptied resolved against an empty query, found
    // no saved matches, and published `[] + live` — a populated RESULTS list
    // under a "Where to?" placeholder, which is exactly the client's screenshot.
    // The `onFailure` arm had the same hole pointing at `[]`, i.e. `No results
    // for ""`.
    //
    // A monotonic token fixes the whole class rather than that one case, and
    // follows `TelemetrySocket.generation` / `LiveVehicleCommandExecutor
    // .noticeGeneration` — the two places this app already does this.
    // `generation` is bumped by EVERY state change the rider can cause (a
    // keystroke, a clear, a nearby-category tap); `engineGeneration` records the
    // one that was current when the fragment was handed to MapKit. A callback is
    // answering a superseded fragment exactly when the two disagree, and a clear
    // hands MapKit nothing, so it can never agree again.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var engineGeneration = -1

    /// Debounce window before a fragment reaches the engine, and the cap on
    /// how many suggestions get coordinate-resolved per update.
    private let debounce: Duration
    private let maxResults: Int

    init(
        engine: (any AutocompleteEngine)? = nil,
        resolveItem: ItemResolver? = nil,
        resolveNearby: NearbyResolver? = nil,
        savedPlaces: [RidePlace] = [],
        debounce: Duration = .milliseconds(250),
        maxResults: Int = 8
    ) {
        self.engine = engine ?? LocalSearchCompleterEngine()
        self.resolveItem = resolveItem ?? Self.localSearchItem
        self.resolveNearby = resolveNearby ?? Self.localNearbySearch
        self.savedPlaces = savedPlaces
        self.debounce = debounce
        self.maxResults = maxResults
        self.engine.onSuggestions = { [weak self] suggestions in
            guard let self else { return }
            // MYR-371 — drop a batch answering a fragment the rider has moved
            // on from. Without this the cached-batch bookkeeping below ALSO
            // outlives the clear, so a later same-fragment re-bias could
            // resurrect the stale list a second time.
            guard self.isCurrentEngineBatch else { return }
            self.lastSuggestions = suggestions
            self.lastFragment = self.query
            self.resolve(suggestions, generation: self.generation)
        }
        self.engine.onFailure = { [weak self] in
            guard let self else { return }
            // MYR-371 — a failure for a superseded/cleared fragment publishes
            // NOTHING. It used to publish `matchingSavedPlaces(query: "")`,
            // i.e. `[]`, and `[]` is the "No results" state — so a completer
            // that errored just after the field was emptied rendered
            // `No results for ""` over the recents the rider should have seen.
            guard self.isCurrentEngineBatch else { return }
            // Fall back to the saved-place matches alone rather than a hard
            // failure — the design's "No results" reads calmly either way.
            self.results = RidePlaceMapper.matchingSavedPlaces(query: self.query, in: self.savedPlaces)
        }
    }

    /// Whether an engine callback is answering the fragment currently in play.
    /// False after a clear (which hands the engine nothing, so `engineGeneration`
    /// can never catch up) and after any newer keystroke or nearby tap.
    private var isCurrentEngineBatch: Bool {
        engineGeneration == generation && !query.isEmpty
    }

    func update(query: String, regionCenter: CLLocationCoordinate2D) {
        self.regionCenter = regionCenter
        // MYR-278 (live-regression fix) — a location re-bias (SAME category, new
        // GPS fix) while a nearby-category search is active must KEEP the
        // published POIs, never fall back to the autocomplete category-row list,
        // and must not re-issue an `MKLocalSearch` on every 1Hz fix (throttle).
        // The center is updated above for the next EXPLICIT search. A different
        // query means the rider typed → fall through and exit nearby mode.
        if let category = activeNearbyCategory, query == category {
            return
        }
        activeNearbyCategory = nil
        self.query = query
        // MYR-371 — every rider-caused change supersedes what is in flight.
        generation &+= 1
        debounceTask?.cancel()
        // MYR-278 — a keystroke supersedes any in-flight nearby-category search.
        nearbyTask?.cancel()

        guard !query.isEmpty else {
            // Empty query: back to the default sections IMMEDIATELY, no search.
            //
            // MYR-371 — `results = nil` was already here and was already right;
            // what was missing is everything around it. The cancels below only
            // stop work this object owns, and the batch that produced the
            // client's screenshot was inside MapKit, which has no idea the field
            // was emptied. The generation bump above is what makes that batch
            // undeliverable when it lands. Clearing the cached batch as well
            // means a later re-bias on the same fragment cannot replay it.
            resolveTask?.cancel()
            lastSuggestions = []
            lastFragment = nil
            results = nil
            return
        }

        let fragment = query
        let center = regionCenter
        let debounce = self.debounce
        let dispatched = generation
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self, self.generation == dispatched else { return }
            // Record WHICH generation MapKit is now working on, so its callback
            // can be matched against the rider's latest intent when it lands.
            self.engineGeneration = dispatched
            self.engine.update(fragment: fragment, region: MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
            // Same query re-issued with a new center (the fix-arrived
            // re-bias): re-resolve the cached batch with the new center NOW,
            // deterministically — a fresh (better-biased) engine callback
            // supersedes it when/if MapKit re-fires.
            if fragment == self.lastFragment, !self.lastSuggestions.isEmpty {
                self.resolve(self.lastSuggestions, generation: dispatched)
            }
        }
    }

    // MARK: Nearby category search (MYR-278)

    /// Run a real nearby POI search for a category term and publish the matching
    /// places as `results`. Invoked when the rider taps a "Search Nearby"
    /// category row instead of a concrete place. Cancels any in-flight
    /// autocomplete/resolution so a stale batch can't clobber these results;
    /// `[]` → the honest "No results" empty state.
    func runNearbySearch(category: String, regionCenter: CLLocationCoordinate2D) {
        self.regionCenter = regionCenter
        // The category term becomes the active query so a later keystroke's
        // supersede/clear logic (and the empty-query reset) behaves normally.
        self.query = category
        // MYR-278 (live-regression fix) — enter nearby-category mode so a
        // subsequent same-category re-bias (a fresh GPS fix) keeps these POIs
        // instead of resurrecting the autocomplete category-row list.
        self.activeNearbyCategory = category
        // MYR-371 — a category tap supersedes every in-flight autocomplete batch,
        // including one MapKit has not delivered yet.
        generation &+= 1
        debounceTask?.cancel()
        resolveTask?.cancel()
        nearbyTask?.cancel()

        let center = regionCenter
        let resolveNearby = self.resolveNearby
        let cap = maxResults
        let dispatched = generation
        nearbyTask = Task { [weak self] in
            let items = await resolveNearby(category, center)
            guard !Task.isCancelled, let self else { return }
            // Only publish if this is still the active category search — by
            // TOKEN as well as by term (MYR-371), so a clear followed by the
            // same category being typed again cannot adopt this older batch.
            guard self.generation == dispatched, self.query == category else { return }
            self.results = items.prefix(cap).map {
                RidePlaceMapper.nearbyRidePlace(from: $0, fallbackTitle: category, regionCenter: center)
            }
        }
    }

    // MARK: Coordinate resolution

    /// Resolve the top-K suggestions to map items (real coordinates + POI
    /// category) concurrently, preserving the engine's ranking, then publish
    /// `savedMatches + liveResults`. Distances come from the CURRENT
    /// `regionCenter` (guarantee 2 — never a stale captured center). Stale
    /// batches are cancelled when a newer one (or a new query) supersedes them.
    private func resolve(_ suggestions: [AutocompleteSuggestion], generation dispatched: Int) {
        resolveTask?.cancel()
        let center = regionCenter
        let queryAtDispatch = query
        let savedMatches = RidePlaceMapper.matchingSavedPlaces(query: queryAtDispatch, in: savedPlaces)
        let top = Array(suggestions.prefix(maxResults))

        // No live suggestions: the saved matches (possibly empty → "No results").
        // MYR-371 — this publish is SYNCHRONOUS but its caller need not be (the
        // re-bias path re-resolves a cached batch from inside the debounce task),
        // so it is stamped like every other.
        guard !top.isEmpty else {
            if generation == dispatched { results = savedMatches }
            return
        }

        let resolveItem = self.resolveItem
        // Cache hits build their rows with NO network (MYR-237 throttle fix);
        // only genuinely new suggestions go to `MKLocalSearch`.
        let cache = coordinateCache
        var prefilled: [(Int, RidePlace)] = []
        var pending: [(Int, AutocompleteSuggestion)] = []
        for (index, suggestion) in top.enumerated() {
            if suggestion.isQueryCategory {
                // MYR-278 — a "Search Nearby" category completion has NO single
                // coordinate; never send it to `MKLocalSearch` (that resolved it
                // to one arbitrary place, the break). Emit a category-search row
                // with no network — tapping it runs `runNearbySearch`.
                prefilled.append((index, RidePlaceMapper.categorySearchPlace(
                    title: suggestion.title,
                    regionCenter: center
                )))
            } else if let cached = cache[Self.cacheKey(suggestion)] {
                prefilled.append((index, RidePlaceMapper.ridePlace(
                    at: cached,
                    title: suggestion.title,
                    subtitle: suggestion.subtitle,
                    regionCenter: center
                )))
            } else {
                pending.append((index, suggestion))
            }
        }
        let seed = prefilled
        resolveTask = Task { [weak self] in
            var resolved: [(Int, RidePlace)] = seed
            var learned: [(String, CLLocationCoordinate2D)] = []
            await withTaskGroup(of: (Int, RidePlace, String?).self) { group in
                for (index, suggestion) in pending {
                    group.addTask {
                        if let item = await resolveItem(suggestion) {
                            let place = RidePlaceMapper.ridePlace(
                                from: item,
                                title: suggestion.title,
                                subtitle: suggestion.subtitle,
                                regionCenter: center
                            )
                            return (index, place, Self.cacheKey(suggestion))
                        }
                        // Degrade, never drop (MYR-211 defect A3): a failed/slow
                        // `MKLocalSearch` resolution must NOT delete the row — a
                        // batch that resolved to zero rows renders the empty "No
                        // results" state even though the completer had matches.
                        // Keep the completer's title/subtitle (distance hidden,
                        // coordinate resolved on SELECTION — SelectionPlaceResolver).
                        return (index, RidePlaceMapper.unresolvedPlace(
                            title: suggestion.title,
                            subtitle: suggestion.subtitle,
                            regionCenter: center
                        ), nil)
                    }
                }
                for await (index, place, key) in group {
                    resolved.append((index, place))
                    if let key { learned.append((key, place.coordinate)) }
                }
            }
            guard !Task.isCancelled else { return }
            let live = resolved.sorted { $0.0 < $1.0 }.map(\.1)
            let learnedPairs = learned
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (key, coordinate) in learnedPairs {
                    self.coordinateCache[key] = coordinate
                }
                // MYR-371 — the generation is the load-bearing half of this
                // guard. `query == queryAtDispatch` passes trivially when both
                // are "" (the rider cleared the field while this batch was in
                // flight), which is precisely how a stale list came back up
                // under the "Where to?" placeholder. The token cannot collide.
                guard self.generation == dispatched, self.query == queryAtDispatch else { return }
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

    /// The live nearby resolver (MYR-278): a category natural-language
    /// `MKLocalSearch` biased to a compact region around the rider, returning
    /// every matching POI.
    private static let localNearbySearch: NearbyResolver = { category, center in
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category
        request.region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        )
        // NOTE: a throttled/failed `MKLocalSearch` surfaces here as `[]` — the UI
        // then shows the honest "No results" empty state, which under Apple's
        // throttle is indistinguishable from a genuine no-match. The
        // `activeNearbyCategory` re-bias no-op (see `update`) deliberately does
        // NOT re-issue this search on every 1Hz fix, precisely to stay clear of
        // that throttle; the rider can re-run by editing the query.
        let response = try? await MKLocalSearch(request: request).start()
        return response?.mapItems ?? []
    }
}

// MARK: - Selection-time coordinate resolution (MYR-237)
//
// The results list may carry `unresolvedPlace` rows (failed/slow per-batch
// `MKLocalSearch`, common under Apple's throttle). Their placeholder
// coordinate is the RIDER'S OWN location — selecting one and trusting that
// coordinate produced a 0.0mi trip and a pickup→pickup route on device. This
// resolver turns the row's title+subtitle back into a real coordinate at
// selection time, with bounded retries spaced for the throttle.
enum SelectionPlaceResolver {
    static let attempts = 3
    static let retrySpacing: Duration = .seconds(4)

    /// The place with a REAL coordinate, or nil if every attempt failed.
    static func resolve(_ place: RidePlace, near center: CLLocationCoordinate2D?) async -> RidePlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [place.label, place.subtitle].compactMap { $0 }.joined(separator: " ")
        if let center {
            request.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
            )
        }
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: retrySpacing) }
            guard !Task.isCancelled else { return nil }
            // Later attempts fall back to the TITLE alone: query-type rows carry
            // marker subtitles ("Search Nearby") that can poison the query (the
            // Applebee's device trace — resolution failed twice on the combined
            // string).
            if attempt == 1 {
                request.naturalLanguageQuery = place.label
            }
            if let item = (try? await MKLocalSearch(request: request).start())?.mapItems.first {
                return RidePlaceMapper.ridePlace(
                    from: item,
                    title: place.label,
                    subtitle: place.subtitle,
                    regionCenter: center ?? item.placemark.coordinate
                )
            }
        }
        return nil
    }
}
