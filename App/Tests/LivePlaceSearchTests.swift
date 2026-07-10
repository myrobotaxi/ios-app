import CoreLocation
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-211 region-bias fix — LivePlaceSearch pipeline (faked engine)
//
// Live-audit defect: from a Frisco, TX fix, "fer" returned globally-unbiased
// results ("Ferrara, Italy") with SF-relative distances ("Fern St, San
// Francisco · 1.3 mi"). These tests drive `LivePlaceSearch` through the
// `AutocompleteEngine` seam with faked completer suggestions and an injected
// item resolver (no MapKit network): the engine's bias region must be the LIVE
// center, distances must be computed from that same center, and a fix arriving
// AFTER the query (same fragment, new center) must re-bias + re-distance.
@MainActor
final class LivePlaceSearchTests: XCTestCase {

    private let frisco = CLLocationCoordinate2D(latitude: 33.086, longitude: -96.852)
    private let sfFixture = DriveFixtures.home // the pre-fix fallback center
    private let dallasDowntown = CLLocationCoordinate2D(latitude: 32.7876, longitude: -96.7994) // ~Klyde Warren Park
    private let sfFernSt = CLLocationCoordinate2D(latitude: 37.7885, longitude: -122.4174) // Fern St, SF

    @MainActor
    private final class FakeEngine: AutocompleteEngine {
        var onSuggestions: (@MainActor ([AutocompleteSuggestion]) -> Void)?
        var onFailure: (@MainActor () -> Void)?
        private(set) var updates: [(fragment: String, region: MKCoordinateRegion)] = []
        func update(fragment: String, region: MKCoordinateRegion) {
            updates.append((fragment, region))
        }
        func emit(_ suggestions: [AutocompleteSuggestion]) {
            onSuggestions?(suggestions)
        }
    }

    /// Resolver mapping suggestion titles to fixed coordinates — no network.
    private func resolver(_ table: [String: CLLocationCoordinate2D]) -> LivePlaceSearch.ItemResolver {
        { suggestion in
            table[suggestion.title].map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) }
        }
    }

    /// A resolver whose `blocked` titles suspend until `release(_:)` — lets a
    /// test hold one batch mid-resolution while a newer query supersedes it.
    @MainActor
    private final class GatedResolver {
        var table: [String: CLLocationCoordinate2D]
        var blocked: Set<String> = []
        private var gates: [String: CheckedContinuation<Void, Never>] = [:]

        init(_ table: [String: CLLocationCoordinate2D]) { self.table = table }

        var resolver: LivePlaceSearch.ItemResolver {
            { [self] suggestion in
                if blocked.contains(suggestion.title) {
                    await withCheckedContinuation { gates[suggestion.title] = $0 }
                }
                return table[suggestion.title].map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) }
            }
        }

        func isBlocking(_ title: String) -> Bool { gates[title] != nil }
        func release(_ title: String) { gates.removeValue(forKey: title)?.resume() }
    }

    private func makeSearch(
        engine: FakeEngine,
        table: [String: CLLocationCoordinate2D],
        savedPlaces: [RidePlace] = []
    ) -> LivePlaceSearch {
        LivePlaceSearch(engine: engine, resolveItem: resolver(table), savedPlaces: savedPlaces, debounce: .milliseconds(1))
    }

    // MARK: Bias region reaches the engine

    func testEngineRegionIsBiasedToLiveCenter() async {
        let engine = FakeEngine()
        let search = makeSearch(engine: engine, table: [:])
        search.update(query: "fer", regionCenter: frisco)
        await eventually { !engine.updates.isEmpty }

        let update = engine.updates.last!
        XCTAssertEqual(update.fragment, "fer")
        XCTAssertEqual(update.region.center.latitude, frisco.latitude, accuracy: 0.0001)
        XCTAssertEqual(update.region.center.longitude, frisco.longitude, accuracy: 0.0001)
    }

    // MARK: Distances come from the live center, ranking preserved

    func testDistancesComputedFromLiveCenterNotFixture() async {
        let engine = FakeEngine()
        let search = makeSearch(engine: engine, table: [
            "Klyde Warren Park": dallasDowntown,
            "Fern St": sfFernSt,
        ])
        search.update(query: "fer", regionCenter: frisco)
        await eventually { !engine.updates.isEmpty }
        engine.emit([
            AutocompleteSuggestion(title: "Klyde Warren Park", subtitle: "Dallas, TX"),
            AutocompleteSuggestion(title: "Fern St", subtitle: "San Francisco, CA, United States"),
        ])
        await eventually { search.results?.count == 2 }

        let results = search.results!
        // Engine ranking preserved: the nearby (Dallas) suggestion stays first.
        XCTAssertEqual(results.map(\.label), ["Klyde Warren Park", "Fern St"])
        // Frisco → downtown Dallas ≈ 20 mi, NOT an SF-relative figure.
        XCTAssertEqual(results[0].miles, 20.7, accuracy: 3)
        // Frisco → SF ≈ 1460 mi — the audit saw "1.3 mi" (SF-relative). Must
        // read ~1400+, never ~1.
        XCTAssertGreaterThan(results[1].miles, 1000)
    }

    // MARK: Fix arriving AFTER the query re-biases + re-distances

    func testFixArrivingAfterQueryRebiasesResults() async {
        let engine = FakeEngine()
        let search = makeSearch(engine: engine, table: ["Fern St": sfFernSt])

        // 1. Query fires pre-fix: center is the SF fixture fallback.
        search.update(query: "fer", regionCenter: sfFixture)
        await eventually { engine.updates.count == 1 }
        engine.emit([AutocompleteSuggestion(title: "Fern St", subtitle: "San Francisco, CA, United States")])
        await eventually { search.results?.count == 1 }
        XCTAssertLessThan(search.results![0].miles, 5) // SF-relative pre-fix

        // 2. The Frisco fix lands: the view layer re-runs the SAME query with
        //    the new center (SharedViewerState.mapRegionCenterKey onChange).
        search.update(query: "fer", regionCenter: frisco)

        //    The engine must be re-biased to Frisco…
        await eventually { engine.updates.count == 2 }
        XCTAssertEqual(engine.updates[1].region.center.latitude, frisco.latitude, accuracy: 0.0001)
        //    …and the cached batch re-distances from Frisco WITHOUT waiting for
        //    MapKit to re-fire (deterministic re-resolve of the cached batch).
        await eventually { (search.results?.first?.miles ?? 0) > 1000 }
        XCTAssertEqual(search.results?.first?.label, "Fern St")
    }

    // MARK: MYR-214 — live search omits fixture saved places

    /// The live composition path (`PlaceSearchComposition.make`) builds
    /// `LivePlaceSearch(savedPlaces: [])`, so the SF fixture "Home · 221 Folsom
    /// St" can NEVER surface in a live ride's destination search — a live rider
    /// in Frisco tapping the fixture "Home" produced a cross-country route
    /// (client QA, MYR-214). Only the MapKit suggestion remains.
    func testLiveSearchOmitsFixtureSavedPlaces() async {
        let engine = FakeEngine()
        // `makeSearch` defaults to EMPTY saved places (the live intent).
        let search = makeSearch(engine: engine, table: [
            "Home Depot": CLLocationCoordinate2D(latitude: 33.10, longitude: -96.80),
        ])
        search.update(query: "home", regionCenter: frisco)
        await eventually { !engine.updates.isEmpty }
        engine.emit([AutocompleteSuggestion(title: "Home Depot", subtitle: "Frisco, TX")])
        await eventually { search.results?.count == 1 }

        let results = search.results!
        // ONLY the MapKit suggestion — no fixture "Home" row.
        XCTAssertEqual(results.map(\.label), ["Home Depot"])
        XCTAssertFalse(results.contains { $0.id == "home" }, "fixture saved 'Home' must never appear in live results")
    }

    /// The saved-first ranking mechanism itself is intact for when real saved
    /// places arrive (accounts, MYR-193): an INJECTED saved place still ranks
    /// ahead of the live suggestions.
    func testInjectedSavedPlacesRankAheadOfLiveResults() async {
        let engine = FakeEngine()
        let savedHome = RidePlace(id: "home", label: "Home", subtitle: "221 Folsom St, San Francisco",
                                  miles: 4.2, minutes: 18, icon: "house.fill", coordinate: DriveFixtures.home)
        let search = makeSearch(
            engine: engine,
            table: ["Home Depot": CLLocationCoordinate2D(latitude: 33.10, longitude: -96.80)],
            savedPlaces: [savedHome]
        )
        search.update(query: "home", regionCenter: frisco)
        await eventually { !engine.updates.isEmpty }
        engine.emit([AutocompleteSuggestion(title: "Home Depot", subtitle: "Frisco, TX")])
        await eventually { search.results?.count == 2 }

        let results = search.results!
        // Injected saved "Home" first, then the live suggestion.
        XCTAssertEqual(results[0].id, "home")
        XCTAssertEqual(results[0].miles, 4.2, accuracy: 0.0001) // untouched saved place
        XCTAssertEqual(results[1].label, "Home Depot")
    }

    // MARK: Failed resolution degrades the row, never drops it (defect A3)

    func testUnresolvedSuggestionDegradesInsteadOfVanishing() async {
        let engine = FakeEngine()
        // Empty table ⇒ the resolver returns nil for every suggestion.
        let search = makeSearch(engine: engine, table: [:])
        search.update(query: "northpark", regionCenter: frisco)
        await eventually { !engine.updates.isEmpty }
        engine.emit([
            AutocompleteSuggestion(title: "NorthPark Center", subtitle: "Dallas, TX"),
            AutocompleteSuggestion(title: "Northpark Mall", subtitle: "Ridgeland, MS"),
        ])
        await eventually { search.results?.count == 2 }

        let results = search.results!
        // The completer's rows survive resolution failure (title/subtitle kept),
        // rather than the batch collapsing to the empty "No results" state.
        XCTAssertEqual(results.map(\.label), ["NorthPark Center", "Northpark Mall"])
        XCTAssertEqual(results[0].subtitle, "Dallas, TX")
        XCTAssertEqual(results[0].miles, 0) // distance hidden until resolved on selection
    }

    // MARK: Debounce coalesces rapid keystrokes into one engine query

    func testDebounceCoalescesRapidKeystrokes() async {
        let engine = FakeEngine()
        let search = LivePlaceSearch(engine: engine, resolveItem: resolver([:]), debounce: .milliseconds(60))
        search.update(query: "f", regionCenter: frisco)
        search.update(query: "fe", regionCenter: frisco)
        search.update(query: "fer", regionCenter: frisco)
        // Nothing reaches the engine until the quiet window elapses.
        XCTAssertTrue(engine.updates.isEmpty)

        await eventually { engine.updates.count == 1 }
        try? await Task.sleep(nanoseconds: 90_000_000) // let any stragglers fire
        XCTAssertEqual(engine.updates.count, 1)
        XCTAssertEqual(engine.updates[0].fragment, "fer") // only the final fragment
    }

    // MARK: A stale batch cannot clobber a newer query's results

    func testStaleResolutionDoesNotOverwriteNewerQuery() async {
        let engine = FakeEngine()
        let gated = GatedResolver([
            "Slow Place": sfFernSt,
            "Fast Place": dallasDowntown,
        ])
        gated.blocked = ["Slow Place"]
        let search = LivePlaceSearch(engine: engine, resolveItem: gated.resolver, debounce: .milliseconds(1))

        // First query's resolution blocks mid-flight.
        search.update(query: "slo", regionCenter: frisco)
        await eventually { engine.updates.count == 1 }
        engine.emit([AutocompleteSuggestion(title: "Slow Place", subtitle: "")])
        await eventually { gated.isBlocking("Slow Place") }

        // A newer query supersedes it and resolves immediately.
        search.update(query: "fas", regionCenter: frisco)
        await eventually { engine.updates.count == 2 }
        engine.emit([AutocompleteSuggestion(title: "Fast Place", subtitle: "")])
        await eventually { search.results?.map(\.label) == ["Fast Place"] }

        // The stale batch finally completes — it must NOT clobber the newer one.
        gated.release("Slow Place")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(search.results?.map(\.label), ["Fast Place"])
    }

    // MARK: Center-key plumbing (what the view's onChange watches)

    func testMapRegionCenterKeyTracksTheResolvedCenter() {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: SimulatedUserLocation(),
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: false
        )
        let state = SharedViewerState(seams: seams)
        // Sim: constant fixture center — the re-run onChange can never fire.
        XCTAssertEqual(state.mapRegionCenterKey, "\(DriveFixtures.home.latitude),\(DriveFixtures.home.longitude)")
    }

    // MARK: -

    private func eventually(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}
