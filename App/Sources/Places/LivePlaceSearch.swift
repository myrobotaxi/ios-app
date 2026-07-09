import CoreLocation
import MapKit
import Observation

// MARK: - LivePlaceSearch (MYR-211 deliverable 1)
//
// The live conformer of `PlaceSearching`: autocomplete-as-you-type via
// `MKLocalSearchCompleter` (POI + address), region-biased to the rider's
// coordinate, each suggestion resolved to a real coordinate with `MKLocalSearch`
// so the design row can show straight-line miles. Saved places that match the
// query rank FIRST (deliverable 2), then the live suggestions.
//
// Debounced per Apple guidance (a keystroke doesn't fire a search): the query
// fragment is only handed to the completer after a short quiet window, and the
// per-suggestion coordinate resolution is cancelled the moment a newer
// suggestion set arrives. `MKLocalSearchCompleter`/`MKLocalSearch` must be used
// from the main thread — this whole class is `@MainActor`.
@Observable
@MainActor
final class LivePlaceSearch: NSObject, PlaceSearching, MKLocalSearchCompleterDelegate {
    private(set) var results: [RidePlace]?

    /// Kept out of `@Observable` tracking — internal plumbing, not view state.
    @ObservationIgnored private let completer: MKLocalSearchCompleter
    @ObservationIgnored private var regionCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?

    /// Debounce window before a fragment reaches the completer, and the cap on
    /// how many suggestions get coordinate-resolved per update.
    private let debounce: Duration
    private let maxResults: Int

    init(debounce: Duration = .milliseconds(250), maxResults: Int = 8) {
        self.completer = MKLocalSearchCompleter()
        self.debounce = debounce
        self.maxResults = maxResults
        super.init()
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
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
            self.completer.region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            )
            self.completer.queryFragment = fragment
        }
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let completions = completer.results
        Task { @MainActor [weak self] in
            self?.resolve(completions)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Fall back to the saved-place matches alone rather than a hard
            // failure — the design's "No results" reads calmly either way.
            self.results = RidePlaceMapper.matchingSavedPlaces(query: self.query)
        }
    }

    // MARK: Coordinate resolution

    /// Resolve the top-K completions to `MKMapItem`s (real coordinates + POI
    /// category) concurrently, preserving the completer's ranking, then publish
    /// `savedMatches + liveResults`. Stale batches are cancelled when a newer
    /// completion set (or a new query) supersedes them.
    private func resolve(_ completions: [MKLocalSearchCompletion]) {
        resolveTask?.cancel()
        let center = regionCenter
        let queryAtDispatch = query
        let savedMatches = RidePlaceMapper.matchingSavedPlaces(query: queryAtDispatch)
        let top = Array(completions.prefix(maxResults))

        // No live suggestions: the saved matches (possibly empty → "No results").
        guard !top.isEmpty else {
            results = savedMatches
            return
        }

        resolveTask = Task { [weak self] in
            var resolved: [(Int, RidePlace)] = []
            await withTaskGroup(of: (Int, RidePlace)?.self) { group in
                for (index, completion) in top.enumerated() {
                    group.addTask {
                        guard let item = await Self.resolveItem(for: completion) else { return nil }
                        return (index, RidePlaceMapper.ridePlace(
                            from: item,
                            title: completion.title,
                            subtitle: completion.subtitle,
                            regionCenter: center
                        ))
                    }
                }
                for await pair in group {
                    if let pair { resolved.append(pair) }
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

    /// One `MKLocalSearch` for a single completion → its first map item.
    private static func resolveItem(for completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        return await withCheckedContinuation { continuation in
            search.start { response, _ in
                continuation.resume(returning: response?.mapItems.first)
            }
        }
    }
}
