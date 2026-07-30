import Foundation
import Observation
import MyRoboTaxiKit

// MARK: - Notification-preference seam (MYR-349)
//
// Before this issue there was NO seam here at all, and no state either: BOTH
// Settings screens declared `@State private var toggles = NotificationToggles()`
// — a private struct of plain `Bool`s, local to the view, persisted nowhere and
// read by nothing. The rows moved when you touched them and that was the entire
// behaviour. A toggle switched off came back on at the next cold start, and the
// notification arrived regardless, because no send site anywhere consulted them.
// The client's report is exact: "the Settings notification toggles are local-only
// lies".
//
// rest-api.md §7.19 shipped, so this becomes the same shape every other M1↔M2
// boundary in this app already has: ONE protocol, a fixture conformer, a
// Kit-backed conformer, composed at exactly one point (`PushPrefsComposition`,
// wired from `RootView` off the ONE resolved `AppMode`) — the `ShareService` /
// `SharedVehicleCatalog` precedent verbatim.
//
// TWO THINGS THIS SEAM DELIBERATELY IS NOT:
//
//  • It is not per-device. §7.19 is account-scoped: the choices outlive every
//    install and follow the user to their next phone. `PushDeviceEndpoint`
//    (MYR-186) is the per-install half and stays separate — a sign-out that drops
//    a device token must never be able to reach the user's stored preferences.
//  • It is not per-vehicle. An owner with two cars has one set of preferences;
//    nothing in §7.19 is keyed by vehicle.

/// The five §7.19 categories as the app holds them — one value type so a screen
/// never juggles five loose `Bool`s and the ECHO can be adopted WHOLESALE in one
/// assignment.
///
/// Defaults are all `true`, matching the server's answer for an account with
/// nothing stored. `SimulatedPushPrefsService` overrides them with the
/// PROTOTYPE's positions instead — see there.
struct PushPrefs: Equatable, Sendable {
    var rideLifecycle = true
    var driveStarted = true
    var driveCompleted = true
    var chargingComplete = true
    var viewerJoined = true

    init(
        rideLifecycle: Bool = true,
        driveStarted: Bool = true,
        driveCompleted: Bool = true,
        chargingComplete: Bool = true,
        viewerJoined: Bool = true
    ) {
        self.rideLifecycle = rideLifecycle
        self.driveStarted = driveStarted
        self.driveCompleted = driveCompleted
        self.chargingComplete = chargingComplete
        self.viewerJoined = viewerJoined
    }

    /// Adopt a §7.19 body wholesale. The ONE conversion point from the wire, so a
    /// caller can never adopt four of five keys and keep a stale fifth.
    init(_ response: PushPrefsResponse) {
        self.init(
            rideLifecycle: response.rideLifecycle,
            driveStarted: response.driveStarted,
            driveCompleted: response.driveCompleted,
            chargingComplete: response.chargingComplete,
            viewerJoined: response.viewerJoined
        )
    }

    subscript(category: PushPrefCategory) -> Bool {
        get {
            switch category {
            case .rideLifecycle: return rideLifecycle
            case .driveStarted: return driveStarted
            case .driveCompleted: return driveCompleted
            case .chargingComplete: return chargingComplete
            case .viewerJoined: return viewerJoined
            }
        }
        set {
            switch category {
            case .rideLifecycle: rideLifecycle = newValue
            case .driveStarted: driveStarted = newValue
            case .driveCompleted: driveCompleted = newValue
            case .chargingComplete: chargingComplete = newValue
            case .viewerJoined: viewerJoined = newValue
            }
        }
    }
}

/// The rows each Settings screen renders, and the §7.19 category each one is
/// bound to.
///
/// It lives HERE, outside the two views, for one reason: the row → category
/// mapping is the thing most likely to be wrong in a way nothing catches. A row
/// wired to the neighbouring category still moves, still saves, still comes back
/// with the position the user chose — it just silences the wrong notification.
/// No decode, no error and no screenshot can see that. The tables are what the
/// screens actually render (`ForEach` over these arrays, not literal call
/// sequences), so the matrix test asserts the shipping mapping rather than a
/// second copy of it.
enum SettingsNotificationRows {
    struct Row: Equatable, Identifiable {
        var label: String
        var category: PushPrefCategory
        var id: String { label }
    }

    /// screens.jsx:473-486 — the owner's four, in the prototype's order.
    static let owner: [Row] = [
        Row(label: "Drive started", category: .driveStarted),
        Row(label: "Drive completed", category: .driveCompleted),
        Row(label: "Charging complete", category: .chargingComplete),
        Row(label: "Viewer joined", category: .viewerJoined),
    ]

    /// shared-screens.jsx:501-505 — the rider's, LESS "Tips & product news"
    /// (MYR-349 deletes it; §7.19 has no column for it and no send site ever
    /// produced it).
    ///
    /// BOTH remaining rows carry `rideLifecycle`. See `SharedSettingsScreen
    /// .notificationsCard` for why that is the schema rather than a shortcut, and
    /// for the open design question it leaves.
    static let rider: [Row] = [
        Row(label: "Request accepted / declined", category: .rideLifecycle),
        Row(label: "Pick-up & arrival alerts", category: .rideLifecycle),
    ]
}

/// What both Settings screens read their notification rows from, and write them
/// through.
@MainActor
protocol PushPrefsService: AnyObject, Observable {
    /// The values the rows RENDER. On the live path this is the server's answer
    /// (optimistically flipped mid-write, rolled back if the write fails); in sim
    /// it is the local struct the prototype always had.
    var prefs: PushPrefs { get }

    /// True once a `GET` has answered. `false` in sim only in the sense that there
    /// is nothing to wait for — the simulated service reports `true` from its first
    /// frame, so no simulated capture can reach a pre-load branch.
    var hasLoaded: Bool { get }

    /// A quiet one-line status when a read or a write did not land — never a
    /// dialog (design minimalism, the same convention as `VehicleFleet
    /// .statusMessage` and `ShareService.statusMessage`). Always `nil` in sim.
    ///
    /// This line is not decoration. A failed write that rolled the row back
    /// without saying so would look identical to a row the user never touched;
    /// a failed read that silently rendered defaults would tell an owner their
    /// charging alerts are on when nobody knows what they are.
    var statusMessage: String? { get }

    /// Fetch (or re-fetch) the account's five values. Idempotent and safe to call
    /// on every appearance of a Settings screen. No-op in sim.
    func load() async

    /// Change ONE category. Owns the whole write pattern — optimistic flip, echo
    /// adoption, rollback + notice on failure — so neither Settings screen holds
    /// any of it and the two cannot drift apart.
    ///
    /// Non-throwing on purpose: there is nothing for a view to do with the error
    /// that the row and its notice are not already showing (the same reasoning
    /// `HomeScreen.setRideShareEnabled` fires-and-forgets on).
    func setEnabled(_ category: PushPrefCategory, _ on: Bool) async
}

// MARK: - SimulatedPushPrefsService (the M1 default)

/// The fixture-backed notification toggles — byte-for-byte the behaviour both
/// Settings screens shipped with, now behind the seam.
///
/// LOCAL PERSISTENCE, NO NETWORK, EVER. `load()` is a no-op, `setEnabled` mutates
/// the struct and returns, nothing can fail (`statusMessage` is always `nil`) and
/// nothing is ever in flight. That is what keeps every simulated + DEBUG capture
/// pixel-identical apart from the deleted Tips row.
///
/// THE SEED IS THE PROTOTYPE'S POSITIONS, NOT THE SERVER'S DEFAULTS. `screens.jsx`
/// boots the owner's "Charging complete" row OFF while §7.19 defaults it ON, so
/// `PushPrefs()`'s all-true default would silently redraw the `ownerSettings`
/// drift-gate scene. The live path takes the server's answer because the server is
/// authoritative there; the simulated path is a rendering of the prototype and
/// takes the prototype's.
@Observable
@MainActor
final class SimulatedPushPrefsService: PushPrefsService {
    private(set) var prefs: PushPrefs
    var hasLoaded: Bool { true }
    var statusMessage: String? { nil }

    init() {
        // screens.jsx:473-486 / shared-screens.jsx:501-505 — the prototype's own
        // initial positions. `chargingComplete` is the only one that is off.
        prefs = PushPrefs(
            rideLifecycle: true,
            driveStarted: true,
            driveCompleted: true,
            chargingComplete: false,
            viewerJoined: true
        )
    }

    func load() async {}

    func setEnabled(_ category: PushPrefCategory, _ on: Bool) async {
        prefs[category] = on
    }
}

// MARK: - LivePushPrefsService (rest-api.md §7.19)

/// The real thing: `GET` on appear, `PUT` per toggle, against §7.19 through the
/// narrow `PushPrefsEndpoint` Kit seam.
///
/// THE WRITE PATTERN IS MYR-342's `setRideShareEnabled`, VERBATIM, for the same
/// reasons:
///
///  1. IT FLIPS OPTIMISTICALLY. A toggle that waits for a round trip before moving
///     reads as broken — the finger leaves the switch and nothing happens.
///  2. IT ADOPTS THE ECHO, not the bool it sent. §7.19 answers with all five keys
///     re-read AFTER the write, so the echo is the authority on what is now
///     stored; a client that adopted its own submission would be correct by luck
///     and would break silently the day the server coerces or changes a sibling.
///     Adopting it WHOLESALE also means a stale sibling key cannot survive a
///     write (MYR-351/MYR-362: adopt echoes correctly, and adopt all of them).
///  3. IT ROLLS BACK AND SAYS SO. The optimistic flip is a claim about the
///     SERVER's state; if the write did not land, that claim is false. Leaving it
///     up would manufacture exactly the belief this feature exists to prevent — an
///     owner walking away believing charging alerts are off while they are still
///     firing. So the row snaps back AND a quiet line says why. A silent rollback
///     is nearly as bad as none: it looks identical to a row nobody touched.
///
/// A failed `GET` is an HONEST STATE, not a silent default: `hasLoaded` stays
/// false and the notice renders. The rows keep showing `PushPrefs()`'s all-true
/// (which is the server's own default for an unset account, i.e. the least
/// misleading thing to show), and the line above them says the settings could not
/// be read — rather than presenting five confident switches nobody fetched.
@Observable
@MainActor
final class LivePushPrefsService: PushPrefsService {
    private let endpoint: any PushPrefsEndpoint

    private(set) var prefs = PushPrefs()
    private(set) var hasLoaded = false
    private(set) var statusMessage: String?

    /// Categories with a `PUT` in flight. A second tap on a row already writing is
    /// a no-op rather than a second write — the same guard every keyed control in
    /// `LiveVehicleCommandExecutor` carries.
    private var inFlight: Set<PushPrefCategory> = []
    private var isLoading = false

    /// The one failure line for a write. §7.19's `400` is a malformed-body bug
    /// rather than something the user did, and its `401`/`500` are both "try
    /// again", so there is nothing to tell them apart FOR — the same reasoning
    /// behind `VehicleCommandNotice.rideShareNotSaved`.
    static let writeFailedNotice = "Couldn\u{2019}t save that notification setting. Please try again."
    /// The one failure line for a read.
    static let readFailedNotice = "Couldn\u{2019}t load your notification settings."

    init(endpoint: any PushPrefsEndpoint) {
        self.endpoint = endpoint
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            prefs = PushPrefs(try await endpoint.pushPrefs())
            hasLoaded = true
            statusMessage = nil
        } catch {
            // An honest state. NOT a silent fall-through to defaults: a read that
            // did not answer is not the same as an account that wants everything.
            statusMessage = Self.readFailedNotice
        }
    }

    func setEnabled(_ category: PushPrefCategory, _ on: Bool) async {
        guard !inFlight.contains(category) else { return }
        let previous = prefs
        prefs[category] = on // optimistic flip — see (1)
        inFlight.insert(category)
        defer { inFlight.remove(category) }
        do {
            let echo = try await endpoint.setPushPrefs(PushPrefsUpdateRequest(category, on))
            prefs = PushPrefs(echo) // adopt the ECHO, wholesale — see (2)
            // A successful write is also proof the account's row is readable, so
            // it clears a stale read notice rather than leaving one over rows the
            // server just confirmed.
            hasLoaded = true
            statusMessage = nil
        } catch {
            prefs = previous // roll back — see (3)
            statusMessage = Self.writeFailedNotice
        }
    }
}
