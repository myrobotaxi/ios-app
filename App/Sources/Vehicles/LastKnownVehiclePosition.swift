import CoreLocation
import Foundation

// MARK: - LastKnownVehiclePosition (MYR-387) — where the car WAS, on device
//
// `OwnerMapCamera`'s third rung. Before a snapshot arrives — and for a car whose
// snapshot genuinely carries no fix — the owner map has no coordinate at all, and
// the alternative to Null Island is either "nothing" or "the last real place we
// saw this car". Both are honest; the second is better, and it costs one
// `UserDefaults` key.
//
// Follows `RecentDestinations` / `AccountStorage` (MYR-224, MYR-356) exactly: a
// `Codable` DTO, a reverse-DNS key, `init(defaults:)` so tests and DEBUG scenes
// get their own store, and nothing clever.
//
// **Not a MYR-228 concern.** Nothing here is a fixture — a cached position is a
// place this device genuinely observed this car at, on whichever path observed
// it. A cold install has none, so a live boot with no cache behaves exactly as it
// would without this file, and no simulated capture is touched (the simulated
// fleet never records: `LiveVehicleFleet` is the only writer).
//
// **A cached position may never be presented as a live one.** The store is read
// ONLY by `OwnerMapCamera`, which widens the span and withholds the vehicle
// marker for exactly this case — see `drawsVehicleMarker`.

/// One cached vehicle position, in its persisted shape.
public struct LastKnownVehiclePosition: Codable, Sendable, Equatable {
    public let vehicleID: String
    public let latitude: Double
    public let longitude: Double
    public let recordedAt: Date

    public init(vehicleID: String, latitude: Double, longitude: Double, recordedAt: Date) {
        self.vehicleID = vehicleID
        self.latitude = latitude
        self.longitude = longitude
        self.recordedAt = recordedAt
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// `Sendable` and NOT actor-isolated, following `AccountStorage`: the whole store
/// is one immutable `UserDefaults` reference, which is itself thread-safe, and
/// the composition point that builds it (`TelemetryComposition.liveFleetConfig`)
/// is nonisolated.
public final class LastKnownVehiclePositionStore: Sendable {

    /// Reverse-DNS, same convention as `AccountStorage` / `RecentDestinations`.
    public static let defaultsKey = "app.myrobotaxi.ios.lastKnownVehiclePositions"

    /// A fleet is small; this is generous. Oldest entries fall off first so a
    /// long-lived install cannot grow the key without bound.
    public static let maxEntries = 12

    /// How stale a cached position may be and still frame a map.
    ///
    /// 30 days. A parking spot from last month is still a far better answer to
    /// "roughly where is my car" than the Gulf of Guinea, and the render is
    /// already hedged (wider span, no marker). Past that the honest answer is
    /// "we don't know", and `OwnerMapCamera` returns `.unpositioned`.
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The cached position for a vehicle, or `nil` when there is none, it has
    /// expired, or — defensively — a stored value is itself the no-fix sentinel.
    public func position(forVehicleID id: String, now: Date = Date()) -> CLLocationCoordinate2D? {
        guard let record = stored().first(where: { $0.vehicleID == id }) else { return nil }
        guard now.timeIntervalSince(record.recordedAt) <= Self.maxAge else { return nil }
        guard OwnerMapCamera.hasFix(record.coordinate) else { return nil }
        return record.coordinate
    }

    /// Record a REAL observed position.
    ///
    /// A no-fix coordinate is dropped rather than stored: writing `(0, 0)` here
    /// would poison the very fallback this exists to provide, and would do it
    /// silently — the exact "a fixture DEFAULT is a leak with no grep signature"
    /// shape CLAUDE.md warns about, wearing a cache.
    @discardableResult
    public func record(
        vehicleID: String,
        coordinate: CLLocationCoordinate2D,
        now: Date = Date()
    ) -> Bool {
        guard OwnerMapCamera.hasFix(coordinate) else { return false }
        var records = stored().filter { $0.vehicleID != vehicleID }
        records.append(LastKnownVehiclePosition(
            vehicleID: vehicleID,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            recordedAt: now
        ))
        records.sort { $0.recordedAt > $1.recordedAt }
        write(Array(records.prefix(Self.maxEntries)))
        return true
    }

    /// Everything currently held, newest first. Exposed for tests and for the cap
    /// assertion; the app only ever asks `position(forVehicleID:)`.
    public func allPositions() -> [LastKnownVehiclePosition] { stored() }

    private func stored() -> [LastKnownVehiclePosition] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([LastKnownVehiclePosition].self, from: data)
        else { return [] }
        return decoded
    }

    private func write(_ records: [LastKnownVehiclePosition]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
