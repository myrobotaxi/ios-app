import Foundation

// MARK: - A ride wears TWO ids, and the lock screen carries the one nothing else
// compares against (MYR-416)
//
// MYR-415 established the split and fixed the REGISTRATION half of it: for a ride
// this device SUBMITTED, `RideRequestRecord.id` is the optimistic client `UUID`
// `LiveRideRequestService.submit` minted (MYR-218) — `fold` copies the record
// forward verbatim and `id` is a `let` — while the server's id lives beside it in
// `riderServerRideID` / `activeServerRideID`. Every §7.8 write already knew that.
//
// **THE ACTIVITY DID NOT, AND IT COULD NOT.** `RideActivityAttributes.rideID` is a
// STATIC attribute, stamped at `Activity.request` and immutable for the life of the
// card — and MYR-398 v3 requests the card at REQUEST, before the create POST has
// even fired, so at the only moment the attributes can be written there is
// legitimately no server id to write. The lock screen therefore carries the LOCAL
// draft UUID for every rider-submitted ride.
//
// That is invisible for as long as the process lives, because the record carries
// the same local id. It becomes the whole defect on a RELAUNCH: `adoptOpenRiderRide`
// rebuilds the record from the wire, so `RideActivityAccountRide.resolve()` answers
// `.live(rideID: <SERVER id>)` while the restored snapshot still says `<local draft
// UUID>`. MYR-405's adoption compares the two with `==`, finds no match, and takes
// the branch it wrote for a stranger's card: **reap the rider's own live banner and
// start a second one beside it** — the exact duplicate-card class MYR-405 closed for
// its own path, re-entered through the id it never had to think about.
//
// ─────────────────────────────────────────────────────────────────────────────
// **THE FIX IS A MATCHING LAYER, NOT AN ATTRIBUTES CHANGE.** ActivityKit attributes
// are immutable after `request`, so stamping the server id onto a card that already
// exists is not a thing that can be done. What CAN be done is to stop asking "are
// these two strings equal" and start asking "do these two ids name the same ride
// this account holds" — which is one function, in one place, over a mapping this
// device is the only thing that can know.
// ─────────────────────────────────────────────────────────────────────────────
//
// **THE MAPPING HAS TO OUTLIVE THE PROCESS, because the process boundary IS the
// bug.** An in-memory `local ↔ server` map (the shape MYR-415's `pendingToken` /
// `serverRideID` plumbing half-built) is correct and useless on its own: the only
// process that ever holds both ids at once is the one that submitted the ride, and
// it is dead by the time adoption matters. So the pair is persisted, following
// `OwnerDispatchPointer` (MYR-396) exactly — and for exactly its reason: *"the id is
// a fact this device already knew and threw away when the process died."*
//
// **A MAPPING IS NOT A RIDE**, the same way a pointer is not one. Nothing is
// rendered from it and nothing is adopted on its say-so; it only ever answers
// whether two ids the app already holds are the same ride, and every other rule —
// dormancy, `.ended`/`.dismissed`, the unresolved third arm, adopt-before-reap —
// runs unchanged on top of the answer. A card whose ride this account does NOT hold
// has no entry, so it matches nothing and is reaped exactly as before.

/// The ids one ride wears, as this feature's comparison layer sees them (MYR-416).
///
/// A pure value with no I/O: the persisted half is `RideActivityRideIDStoring`, so
/// the state machine keeps taking a plain input it can be swept over.
struct RideActivityRideIdentity: Equatable, Sendable {

    /// ACTIVITY id (what `RideActivityAttributes.rideID` carries, i.e. what is on the
    /// lock screen) → the SERVER id the same ride answers to everywhere else.
    ///
    /// Keyed that way round because the Activity's id is the one that is fixed
    /// forever: it is stamped once into immutable attributes, while the record's id
    /// changes shape across a relaunch.
    private let serverIDsByActivityID: [String: String]

    init(serverIDsByActivityID: [String: String] = [:]) {
        self.serverIDsByActivityID = serverIDsByActivityID
    }

    /// No mapping at all. Every comparison then falls back to plain equality, which
    /// is precisely what this feature did before MYR-416 — so it is the DEFAULT for
    /// every pure entry point and every pre-existing test is unchanged by
    /// construction.
    static let unmapped = RideActivityRideIdentity()

    /// Every id this account has used for one ride, including the id it was asked
    /// about.
    ///
    /// Both directions are answered, deliberately: the caller does not always know
    /// which of the two ids it is holding — the coordinator's `phase` names the
    /// ACTIVITY's, the record names the SERVER's in a relaunched process and the
    /// LOCAL one in the process that submitted it. A predicate that only worked one
    /// way round would be right at three call sites and wrong at the fourth, and the
    /// fourth is how this class of bug got here.
    func identities(of rideID: String) -> Set<String> {
        var ids: Set<String> = [rideID]
        if let server = serverIDsByActivityID[rideID] { ids.insert(server) }
        for (activityID, serverID) in serverIDsByActivityID where serverID == rideID {
            ids.insert(activityID)
        }
        return ids
    }

    /// Is the card on the lock screen this ride's card?
    ///
    /// The ONE question MYR-416 replaces `==` with. It is deliberately not called
    /// `matches`: what it asserts is that two ids name the same ride, which is a
    /// statement about a ride and not about two strings.
    func namesTheSameRide(activityRideID: String, as rideID: String) -> Bool {
        identities(of: rideID).contains(activityRideID)
    }

    /// Is any id this ride has worn in the given set?
    ///
    /// Used for `dismissedRideIDs`, which is recorded under the ACTIVITY's id (the
    /// restore list and the lifecycle stream are the only two things that can report
    /// a swipe, and both speak that id) and consulted against the RECORD's. Without
    /// this, a rider who swiped a submitted ride's card away and relaunched would be
    /// given a fresh one — the dismissal reading as though it never worked, which is
    /// the very thing MYR-405 semantic 5 exists to prevent.
    func anyIdentity(of rideID: String, isIn ids: Set<String>) -> Bool {
        !identities(of: rideID).isDisjoint(with: ids)
    }
}

// MARK: - Where the pair is kept between processes

/// One remembered `local ↔ server` pair, in its persisted shape.
struct RideActivityRideIDPair: Codable, Sendable, Equatable {
    let activityRideID: String
    let serverRideID: String
    let recordedAt: Date
}

protocol RideActivityRideIDStoring: Sendable {
    /// Every pair still worth believing, as the value the pure layer consumes.
    func identity(now: Date) -> RideActivityRideIdentity

    /// Remember that the card stamped `activityRideID` is the ride the server calls
    /// `serverRideID`. Idempotent.
    func note(activityRideID: String, serverRideID: String, now: Date)

    /// Forget everything. Sign-out only — see `RideActivityCoordinator.handleSignOut`.
    func clear()
}

extension RideActivityRideIDStoring {
    func identity() -> RideActivityRideIdentity { identity(now: Date()) }

    func note(activityRideID: String, serverRideID: String) {
        note(activityRideID: activityRideID, serverRideID: serverRideID, now: Date())
    }
}

/// `Sendable` and NOT actor-isolated, following `UserDefaultsOwnerDispatchPointer`:
/// the whole store is one immutable `UserDefaults` reference, which is itself
/// thread-safe.
final class UserDefaultsRideActivityRideIDs: RideActivityRideIDStoring {

    /// Reverse-DNS, same convention as `AccountStorage` / `RecentDestinations` /
    /// `OwnerDispatchPointer`.
    static let defaultsKey = "app.myrobotaxi.ios.liveActivityRideIDs"

    /// How long a pair stays believable.
    ///
    /// **24 hours, and deliberately shorter than `OwnerDispatchPointer`'s 30 days.**
    /// That pointer names a ride the owner may have accepted for next week; this
    /// names a card that is ON THE LOCK SCREEN RIGHT NOW, and a Live Activity does
    /// not survive a day — the longest thing it can outlive is a ride plus MYR-425's
    /// five-minute completed linger. A pair older than that describes a card nobody
    /// can still be looking at.
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// At most this many pairs, newest kept.
    ///
    /// A rider holds one instant ride at a time (§7.8's active-instant uniqueness
    /// index), so the realistic count is one; the cap exists so a device that somehow
    /// never expires an entry cannot grow this without bound. Small on purpose — a
    /// large ledger would be a place for a stale pair to hide.
    static let capacity = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func identity(now: Date = Date()) -> RideActivityRideIdentity {
        var map: [String: String] = [:]
        for pair in load(now: now) { map[pair.activityRideID] = pair.serverRideID }
        return RideActivityRideIdentity(serverIDsByActivityID: map)
    }

    func note(activityRideID: String, serverRideID: String, now: Date = Date()) {
        guard !activityRideID.isEmpty, !serverRideID.isEmpty else { return }
        var pairs = load(now: now).filter { $0.activityRideID != activityRideID }
        pairs.append(
            RideActivityRideIDPair(
                activityRideID: activityRideID,
                serverRideID: serverRideID,
                recordedAt: now
            )
        )
        let kept = pairs.suffix(Self.capacity)
        guard let data = try? JSONEncoder().encode(Array(kept)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func clear() { defaults.removeObject(forKey: Self.defaultsKey) }

    private func load(now: Date) -> [RideActivityRideIDPair] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let pairs = try? JSONDecoder().decode([RideActivityRideIDPair].self, from: data)
        else { return [] }
        return pairs.filter { now.timeIntervalSince($0.recordedAt) <= Self.maxAge }
    }
}

/// The store for tests and DEBUG scenes — the same reason
/// `InMemoryOwnerDispatchPointer` exists: a pair left behind by hand-driving a live
/// flow on a simulator must never decide what a later run adopts.
final class InMemoryRideActivityRideIDs: RideActivityRideIDStoring {
    private let lock = NSLock()
    nonisolated(unsafe) private var pairs: [RideActivityRideIDPair]

    init(_ seed: [String: String] = [:], recordedAt: Date = Date()) {
        pairs = seed.map {
            RideActivityRideIDPair(activityRideID: $0.key, serverRideID: $0.value, recordedAt: recordedAt)
        }
    }

    func identity(now: Date = Date()) -> RideActivityRideIdentity {
        lock.lock(); defer { lock.unlock() }
        var map: [String: String] = [:]
        for pair in pairs { map[pair.activityRideID] = pair.serverRideID }
        return RideActivityRideIdentity(serverIDsByActivityID: map)
    }

    func note(activityRideID: String, serverRideID: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        pairs.removeAll { $0.activityRideID == activityRideID }
        pairs.append(
            RideActivityRideIDPair(
                activityRideID: activityRideID,
                serverRideID: serverRideID,
                recordedAt: now
            )
        )
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pairs = []
    }
}
