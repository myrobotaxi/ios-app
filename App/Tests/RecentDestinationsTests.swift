import XCTest
import CoreLocation
@testable import MyRoboTaxi

// MARK: - MYR-356 — the recents list rule + its store
//
// The list rule is a pure function, so ordering, dedupe and the cap are pinned here
// without a store, a view or a simulator. The store tests follow
// `AccountIdentityTests`' precedent exactly: a scratch `UserDefaults(suiteName:)`
// torn down with `removePersistentDomain(forName:)`.

@MainActor
final class RecentDestinationsTests: XCTestCase {

    private func place(
        id: String,
        label: String,
        subtitle: String? = nil,
        lat: Double = 37.77,
        lon: Double = -122.41
    ) -> RidePlace {
        RidePlace(
            id: id, label: label, subtitle: subtitle,
            miles: 3.1, minutes: 14, icon: "fork.knife",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
        )
    }

    private static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: The list rule

    func testChoosingAPlaceRecordsItAtTheHead() {
        let list = RecentDestinationList.recording(
            place(id: "a", label: "Tartine Bakery", subtitle: "600 Guerrero St"),
            in: [],
            now: Self.epoch
        )
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?.label, "Tartine Bakery")
        XCTAssertEqual(list?.first?.subtitle, "600 Guerrero St")
        XCTAssertEqual(list?.first?.chosenAt, Self.epoch)
    }

    func testTheNewestChoiceLeadsAndTheRestKeepTheirOrder() {
        var list: [RecentDestination] = []
        for (index, label) in ["One", "Two", "Three"].enumerated() {
            list = RecentDestinationList.recording(
                place(id: "p\(index)", label: label), in: list,
                now: Self.epoch.addingTimeInterval(Double(index))
            ) ?? list
        }
        XCTAssertEqual(list.map(\.label), ["Three", "Two", "One"])
    }

    func testChoosingTheSamePlaceAgainMovesItUpRatherThanDuplicatingIt() {
        var list = RecentDestinationList.recording(
            place(id: "a", label: "Ferry Building", subtitle: "1 Ferry Building"), in: [], now: Self.epoch
        ) ?? []
        list = RecentDestinationList.recording(
            place(id: "b", label: "SFO", subtitle: "Terminal 2"), in: list, now: Self.epoch.addingTimeInterval(1)
        ) ?? list
        // Same label + address, DIFFERENT id — exactly what MYR-237's async resolve
        // produces when it swaps a `live-unresolved|…` shell for the resolved place.
        list = RecentDestinationList.recording(
            place(id: "live-unresolved|zzz", label: "Ferry Building", subtitle: "1 Ferry Building"),
            in: list, now: Self.epoch.addingTimeInterval(2)
        ) ?? list

        XCTAssertEqual(list.map(\.label), ["Ferry Building", "SFO"], "the repeat must move up, not duplicate")
    }

    func testTheDedupeIsCaseInsensitiveOnBothLabelAndAddress() {
        var list = RecentDestinationList.recording(
            place(id: "a", label: "Pier 39", subtitle: "Beach St"), in: [], now: Self.epoch
        ) ?? []
        list = RecentDestinationList.recording(
            place(id: "b", label: "PIER 39", subtitle: "BEACH ST"), in: list, now: Self.epoch.addingTimeInterval(1)
        ) ?? list
        XCTAssertEqual(list.count, 1)
    }

    func testTwoPlacesSharingALabelButNotAnAddressAreDifferentPlaces() {
        var list = RecentDestinationList.recording(
            place(id: "a", label: "Blue Bottle", subtitle: "66 Mint St"), in: [], now: Self.epoch
        ) ?? []
        list = RecentDestinationList.recording(
            place(id: "b", label: "Blue Bottle", subtitle: "315 Linden St"), in: list, now: Self.epoch.addingTimeInterval(1)
        ) ?? list
        XCTAssertEqual(list.count, 2)
    }

    func testTheListIsCappedAtFiveMostRecentFirst() {
        var list: [RecentDestination] = []
        for index in 0..<8 {
            list = RecentDestinationList.recording(
                place(id: "p\(index)", label: "Place \(index)"), in: list,
                now: Self.epoch.addingTimeInterval(Double(index))
            ) ?? list
        }
        XCTAssertEqual(RecentDestinationList.limit, 5)
        XCTAssertEqual(list.map(\.label), ["Place 7", "Place 6", "Place 5", "Place 4", "Place 3"])
    }

    /// MYR-278 — a "Search Nearby" category row is not a place (no single
    /// coordinate). It must never become a destination, and so must never become a
    /// recent one either.
    func testACategorySearchRowIsNeverRecorded() {
        let category = RidePlaceMapper.categorySearchPlace(
            title: "Coffee", regionCenter: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.41)
        )
        XCTAssertNil(RecentDestinationList.recording(category, in: [], now: Self.epoch))
    }

    func testABlankLabelIsNeverRecorded() {
        XCTAssertNil(RecentDestinationList.recording(place(id: "a", label: "   "), in: [], now: Self.epoch))
    }

    // MARK: Round-trip to a `RidePlace`

    /// The deliverable stated structurally: selecting a recent must behave exactly
    /// like choosing that destination from search. The id — including MYR-237's
    /// `live-unresolved|` prefix — survives the round trip, which is the ONLY reason
    /// `resolveDraftDestinationIfNeeded()` still fires for it.
    func testTheStoredIdSurvivesSoAnUnresolvedRecentStillReResolves() {
        let unresolved = place(id: "live-unresolved|tartine", label: "Tartine Bakery")
        let stored = RecentDestination(place: unresolved, chosenAt: Self.epoch)
        XCTAssertTrue(RidePlaceMapper.isUnresolved(stored.place))
    }

    /// A recorded row carries no measured distance. `destRow` hides both readouts at
    /// 0, so the row reads label + address — the prototype's own Recent grammar.
    func testARecordedRowClaimsNoDistanceOrDuration() {
        let stored = RecentDestination(
            place: place(id: "a", label: "Tartine Bakery", subtitle: "600 Guerrero St"), chosenAt: Self.epoch
        )
        XCTAssertEqual(stored.place.miles, 0)
        XCTAssertEqual(stored.place.minutes, 0)
        XCTAssertEqual(stored.place.icon, RecentDestinationList.icon)
        XCTAssertEqual(stored.place.coordinate.latitude, 37.77, accuracy: 0.0001)
        XCTAssertEqual(stored.place.coordinate.longitude, -122.41, accuracy: 0.0001)
    }

    // MARK: The UserDefaults store (AccountIdentityTests' precedent)

    private func scratchDefaults(_ name: String) -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    func testTheStoreRoundTripsThroughUserDefaults() {
        let suite = "mrt.tests.recents.roundtrip"
        let defaults = scratchDefaults(suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = UserDefaultsRecentDestinationsStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty, "a cold install has no recents")

        let list = RecentDestinationList.recording(
            place(id: "a", label: "Tartine Bakery", subtitle: "600 Guerrero St"), in: [], now: Self.epoch
        ) ?? []
        store.save(list)

        let reread = UserDefaultsRecentDestinationsStore(defaults: defaults).load()
        XCTAssertEqual(reread.map(\.label), ["Tartine Bakery"])
        XCTAssertEqual(reread.first?.subtitle, "600 Guerrero St")
        XCTAssertEqual(reread.first?.id, "a")
    }

    func testGarbageOnDiskReadsAsNoRecentsRatherThanThrowing() {
        let suite = "mrt.tests.recents.garbage"
        let defaults = scratchDefaults(suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(Data("not json".utf8), forKey: UserDefaultsRecentDestinationsStore.key)
        XCTAssertTrue(UserDefaultsRecentDestinationsStore(defaults: defaults).load().isEmpty)
    }

    /// A longer list already on disk (written by a build with a different limit, or
    /// seeded by a DEBUG scene) still renders exactly `limit` rows.
    func testTheReadCapsDefensively() {
        let long = (0..<9).map {
            RecentDestination(
                id: "p\($0)", label: "Place \($0)", subtitle: nil,
                latitude: 37.77, longitude: -122.41, chosenAt: Self.epoch
            )
        }
        XCTAssertEqual(InMemoryRecentDestinationsStore(long).load().count, RecentDestinationList.limit)
    }

    // MARK: The one seam the flow records through

    /// Recording hangs off `selectDestination` — the single funnel every advance
    /// goes through (`proceedFromSearch` delegates to it, and the idle sheet's
    /// Home/Work chips call it directly). Merely TAPPING a result row
    /// (`chooseDestination`) fills the field and does not advance, so it records
    /// nothing: a destination the rider backed out of with "Change trip" is not one
    /// they chose.
    func testAdvancingRecordsTheDestinationAndMerelyTappingOneDoesNot() {
        let store = InMemoryRecentDestinationsStore()
        let state = SharedViewerState(seams: .simulated, recentDestinationsStore: store)

        state.chooseDestination(place(id: "a", label: "Tartine Bakery", subtitle: "600 Guerrero St"))
        XCTAssertTrue(state.recentDestinations.isEmpty, "a tap that does not advance is not a choice")

        state.proceedFromSearch()
        XCTAssertEqual(state.recentDestinations.map(\.label), ["Tartine Bakery"])
        XCTAssertEqual(store.load().map(\.label), ["Tartine Bakery"], "and it is persisted, not just held")
    }

    func testTheStateExposesRecentsAsPlacesTheSearchSheetCanRender() {
        let store = InMemoryRecentDestinationsStore([
            RecentDestination(id: "a", label: "Pier 39", subtitle: "Beach St", latitude: 37.8, longitude: -122.4, chosenAt: Self.epoch)
        ])
        let state = SharedViewerState(seams: .simulated, recentDestinationsStore: store)
        XCTAssertEqual(state.recentDestinationPlaces.map(\.label), ["Pier 39"])
        XCTAssertEqual(state.recentDestinationPlaces.first?.icon, RecentDestinationList.icon)
    }

    /// The drift-gate guarantee, asserted rather than assumed: with nothing stored,
    /// the sheet has no recents to render at all — so every simulated scene keeps
    /// the fixture list and every live scene keeps its muted line.
    func testAColdStateHasNoRecentsToRender() {
        let state = SharedViewerState(seams: .simulated, recentDestinationsStore: InMemoryRecentDestinationsStore())
        XCTAssertTrue(state.recentDestinationPlaces.isEmpty)
    }
}
