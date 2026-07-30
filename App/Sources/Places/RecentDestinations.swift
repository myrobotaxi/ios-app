import Foundation
import CoreLocation

// MARK: - MYR-356 — recent destinations, on device
//
// The search sheet's pre-typing region has always been a promise the app could
// not keep. In SIM it lists the prototype's `SAVED`/`RECENT`/`NEARBY` fixtures;
// on the LIVE path MYR-214 emptied all three (a Frisco rider tapping the fixture
// "Home · 221 Folsom St" got a cross-country route), leaving one muted line —
// "Type a destination to search" — and `RideRequestSearchContent`'s own comment
// admitting why: *"no real saved places until accounts (MYR-193) and no
// session-recents store yet, so there's nothing local to list."*
//
// Recents are the half of that gap which needs NO backend at all: the rider's own
// choices, on their own device. This is that store.
//
// FOUR rules:
//
//  • **The list is DEVICE-LOCAL and therefore honest on both paths.** Nothing here
//    is a fixture, so MYR-228 does not apply — a live rider's recents are places a
//    live rider actually chose. That is also why the same code runs in SIM: a
//    recents row in the simulator is a real choice made in the simulator.
//  • **It renders only when it is NON-EMPTY**, which is what keeps the drift gate
//    intact. A cold install has no recents, so live keeps its muted line and SIM
//    keeps the fixture Saved/Recent/Nearby list byte-for-byte. `RootView` also
//    boots every DEBUG scene against an in-memory store (`DebugScene
//    .seededRecentDestinations`), so no capture can ever pick up recents left
//    behind by hand-driving the flow on the same simulator.
//  • **A recorded row carries NO distance and NO duration.** The rows the rider
//    tapped came from MapKit autocomplete, which carries neither (MYR-211: live
//    rows show straight-line miles and 0 minutes), and a distance measured at
//    choose-time is stale by the next session anyway. `destRow` already hides both
//    lines at 0, so a recent reads as label + address — the prototype's own Recent
//    grammar, whose rows likewise carry no icon of their own.
//  • **The stored id is preserved verbatim**, including the `live-unresolved|`
//    prefix MYR-237 puts on a suggestion whose coordinate has not been resolved
//    yet. Selecting such a row later runs `RidePlaceMapper.isUnresolved` →
//    `resolveDraftDestinationIfNeeded()` exactly as a fresh autocomplete row does,
//    so a recent behaves *identically* to choosing that destination from search —
//    which is the deliverable, stated as a structural property rather than a
//    second code path.

/// One recently-chosen destination, in its persisted shape.
///
/// A DTO rather than `RidePlace` because `RidePlace` is not `Codable` (it holds a
/// `CLLocationCoordinate2D`, which is why it also hand-writes its `==`). Keeping
/// the wire-to-disk shape separate is the `AccountStorage` precedent.
public struct RecentDestination: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let subtitle: String?
    public let latitude: Double
    public let longitude: Double
    public let chosenAt: Date

    public init(id: String, label: String, subtitle: String?, latitude: Double, longitude: Double, chosenAt: Date) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.chosenAt = chosenAt
    }

    public init(place: RidePlace, chosenAt: Date) {
        self.init(
            id: place.id,
            label: place.label,
            subtitle: place.subtitle,
            latitude: place.coordinate.latitude,
            longitude: place.coordinate.longitude,
            chosenAt: chosenAt
        )
    }

    /// Back to the type every row in the search sheet speaks. Miles/minutes are
    /// deliberately 0 — see this file's header — and `destRow` hides both at 0.
    public var place: RidePlace {
        RidePlace(
            id: id,
            label: label,
            subtitle: subtitle,
            miles: 0,
            minutes: 0,
            icon: RecentDestinationList.icon,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }
}

/// The list rule, as a pure function — so dedupe, ordering and the cap are
/// testable without a store, a view or a simulator.
public enum RecentDestinationList {
    /// The client's number. Also the read cap, applied defensively on load so a
    /// list written by a build with a different limit cannot over-render.
    public static let limit = 5

    /// The prototype's Recent rows carry no icon of their own and fall to
    /// `DestRow`'s generic `mappin` branch (ride-request.jsx:283). Ours is the same
    /// symbol `RideRequestContractMapping.place` gives every wire place.
    public static let icon = "mappin"

    /// The dedupe key.
    ///
    /// NOT the id. MYR-237 resolves a picked suggestion asynchronously and swaps a
    /// `live-unresolved|…` shell for a resolved place with a DIFFERENT id, so a
    /// rider who chose the same café twice — once before the resolve landed, once
    /// after — would have two ids for one place. The label + address pair is what
    /// the rider actually reads, so it is what "the same destination" means here.
    static func key(label: String, subtitle: String?) -> String {
        "\(label.lowercased())|\((subtitle ?? "").lowercased())"
    }

    static func key(_ destination: RecentDestination) -> String {
        key(label: destination.label, subtitle: destination.subtitle)
    }

    /// The list after the rider chose `place`, most-recent-first and capped.
    ///
    /// Returns `nil` — record NOTHING — for a "Search Nearby" category row, which
    /// MYR-278 established is not a place at all (no single coordinate), and for a
    /// blank label, which would render an empty row.
    public static func recording(
        _ place: RidePlace,
        in existing: [RecentDestination],
        now: Date = Date()
    ) -> [RecentDestination]? {
        guard !RidePlaceMapper.isCategorySearch(place) else { return nil }
        guard !place.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let entry = RecentDestination(place: place, chosenAt: now)
        let entryKey = key(entry)
        // The new choice goes to the head; the old copy of the same place drops out
        // rather than being left further down, so "most recent" is true of every row.
        let rest = existing.filter { key($0) != entryKey }
        return Array(([entry] + rest).prefix(limit))
    }

    /// The read cap. Applied on load so a longer list already on disk (or seeded by
    /// a DEBUG scene) still renders exactly `limit` rows.
    public static func capped(_ destinations: [RecentDestination]) -> [RecentDestination] {
        Array(destinations.prefix(limit))
    }
}

// MARK: - Storage

/// The persistence seam. `@MainActor` because every caller is — `SharedViewerState`
/// owns the list and is `@MainActor` itself — which keeps the in-memory variant a
/// plain class with no `@unchecked Sendable`.
@MainActor
public protocol RecentDestinationsStoring: Sendable {
    func load() -> [RecentDestination]
    func save(_ destinations: [RecentDestination])
}

/// `UserDefaults`, following `AccountStorage.swift` (MYR-224) exactly: a reverse-DNS
/// key, a JSON-encoded `Codable` payload, `init(defaults:)` for test injection, and a
/// `try?` decode that answers an empty list rather than throwing at a rider.
///
/// UserDefaults and not the Keychain, per that file's own rule — the Keychain is
/// reserved for the refresh token, and a destination the rider typed is display
/// state, not a secret.
@MainActor
public struct UserDefaultsRecentDestinationsStore: RecentDestinationsStoring {
    static let key = "app.myrobotaxi.rider.recentDestinations"

    private let defaults: UserDefaults

    /// `nonisolated` so it can be a DEFAULT ARGUMENT on `SharedViewerState.init`.
    /// Default arguments are evaluated in a nonisolated context, and storing a
    /// `UserDefaults` reference touches no actor state — only `load`/`save` do.
    public nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [RecentDestination] {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([RecentDestination].self, from: data)
        else { return [] }
        return RecentDestinationList.capped(decoded)
    }

    public func save(_ destinations: [RecentDestination]) {
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The non-persisting variant: DEBUG scenes (which must boot from a KNOWN list, not
/// from whatever the last hand-driven session left on the simulator) and unit tests.
@MainActor
public final class InMemoryRecentDestinationsStore: RecentDestinationsStoring {
    private var destinations: [RecentDestination]

    public init(_ destinations: [RecentDestination] = []) {
        self.destinations = destinations
    }

    public func load() -> [RecentDestination] { RecentDestinationList.capped(destinations) }
    public func save(_ destinations: [RecentDestination]) { self.destinations = destinations }
}
