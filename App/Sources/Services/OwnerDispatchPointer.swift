import Foundation

// MARK: - The owner's live dispatch outlives the process (MYR-396)
//
// THE PROBLEM THIS SOLVES IS A GAP IN THE CONTRACT, not a missing fetch. There is
// exactly one owner-scoped ride feed — `GET /api/ride-requests/incoming` — and
// rest-api.md §7.8 defines it as status `requested` ONLY: *"decided rows leave the
// feed by construction"*. `GET /api/ride-requests` is the RIDER's own list
// (`ListByRiderPage`, `rider_id = :sub`), and `?upcomingForVehicle=` is
// `accepted` AND strictly FUTURE, i.e. precisely the reservations that are NOT
// live. So on the wire this app speaks, **an owner cannot ask "which ride am I
// driving right now?"** — the moment they tap Accept, the ride is on no list they
// can read.
//
// What they CAN read is `GET /api/ride-requests/{id}`, which is party-only and so
// answers for the owner as readily as for the rider. All it needs is the id — and
// the id is a fact this device already knew and threw away when the process died.
// That is the whole of this file: one string, persisted, so a cold launch has
// something to ask about.
//
// Following `AccountStorage` (MYR-224) / `RecentDestinations` (MYR-356) /
// `LastKnownVehiclePosition` (MYR-387) exactly — a `Codable` DTO, a reverse-DNS
// key, `init(defaults:)` so tests and DEBUG scenes get their own store, and
// nothing clever.
//
// **Not a MYR-228 concern.** Nothing here is a fixture. A pointer is a ride this
// device's OWNER genuinely accepted, and it is written by the owner pipeline
// itself — so a cold install has none, the simulated service never writes one
// (it has no server ride to point at), and no capture is touched.
//
// **A pointer is not a ride.** It is only ever used to ASK the server, and the
// answer is what decides everything: a terminal ride is not adopted, a DORMANT
// reservation is not adopted (MYR-376), and a read that fails adopts nothing and
// forgets nothing. Nothing about the card is ever rendered from what is stored
// here — see `LiveRideRequestService.refreshOwnerDispatch`.

/// One remembered owner dispatch, in its persisted shape.
struct OwnerDispatchPointerRecord: Codable, Sendable, Equatable {
    let rideID: String
    let recordedAt: Date
}

/// Where the owner's live-dispatch id is kept between processes.
protocol OwnerDispatchPointerStoring: Sendable {
    /// The remembered ride id, or `nil` when there is none or it has expired.
    func read(now: Date) -> String?
    func write(rideID: String, now: Date)
    func clear()
}

extension OwnerDispatchPointerStoring {
    func read() -> String? { read(now: Date()) }
    func write(rideID: String) { write(rideID: rideID, now: Date()) }
}

/// `Sendable` and NOT actor-isolated, following `AccountStorage`: the whole store
/// is one immutable `UserDefaults` reference, which is itself thread-safe.
final class UserDefaultsOwnerDispatchPointer: OwnerDispatchPointerStoring {

    /// Reverse-DNS, same convention as `AccountStorage` / `RecentDestinations`.
    static let defaultsKey = "app.myrobotaxi.ios.ownerDispatchPointer"

    /// How long a pointer may go unresolved before it stops being asked about.
    ///
    /// 30 days, the `LastKnownVehiclePositionStore` number, and generous on
    /// purpose: the longest-lived thing this can point at is a reservation the
    /// owner accepted well ahead of time, which stays worth restoring for as long
    /// as it is in the future. Past that the honest reading is that something went
    /// wrong once and nobody is waiting on this ride — and an id nothing will ever
    /// resolve is one `GET` per launch, forever.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func read(now: Date = Date()) -> String? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let record = try? JSONDecoder().decode(OwnerDispatchPointerRecord.self, from: data),
              now.timeIntervalSince(record.recordedAt) <= Self.maxAge
        else { return nil }
        return record.rideID
    }

    func write(rideID: String, now: Date = Date()) {
        let record = OwnerDispatchPointerRecord(rideID: rideID, recordedAt: now)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func clear() { defaults.removeObject(forKey: Self.defaultsKey) }
}

/// The store for tests and DEBUG scenes — the same reason
/// `InMemoryRecentDestinationsStore` exists: a pointer left behind by
/// hand-driving a live flow on a simulator must never seed a later capture.
final class InMemoryOwnerDispatchPointer: OwnerDispatchPointerStoring {
    private let lock = NSLock()
    nonisolated(unsafe) private var record: OwnerDispatchPointerRecord?

    init(rideID: String? = nil, recordedAt: Date = Date()) {
        record = rideID.map { OwnerDispatchPointerRecord(rideID: $0, recordedAt: recordedAt) }
    }

    func read(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        return record?.rideID
    }

    func write(rideID: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        record = OwnerDispatchPointerRecord(rideID: rideID, recordedAt: now)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        record = nil
    }
}
