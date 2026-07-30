import Foundation

// MARK: - Per-category push preference wire shapes (MYR-349, rest-api.md §7.19)
//
// Same EXCEPTION as `PushDevicePayloads.swift` / `VehicleServiceWindowPayloads
// .swift` / `VehicleRideSharePayloads.swift` / `VehiclePlatePayloads.swift`:
// contracts codegen covers READ models + the WS envelope only, so there is no
// generated type for this account-scoped read/write pair. The DTOs below are
// authored here, verbatim from §7.19, and MUST be replaced by generated types the
// moment `contracts` grows them. Codable/Equatable/Sendable to match the
// generated-type conventions so the swap is drop-in.
//
// WHY THIS ENDPOINT EXISTS. MYR-186 registered the DEVICE; nothing ever asked the
// account WHICH pushes it wanted. The Settings notification toggles were
// `@State private var toggles = NotificationToggles()` on both Settings screens —
// local structs that persisted nowhere, gated nothing, and reset on every launch.
// An owner who switched "Charging complete" off watched it come back on the next
// cold start, and got the notification either way. §7.19 is where that answer now
// lives.
//
// THREE PROPERTIES THAT SHAPE EVERY CONSUMER BELOW:
//
//  1. THE READ IS TOTAL, THE WRITE IS PARTIAL. The server always emits ALL FIVE
//     keys (an absent row server-side resolves to all-`true` before it answers),
//     so ``PushPrefsResponse`` declares five NON-OPTIONAL `Bool`s. The REQUEST is
//     any SUBSET — a client changing one toggle sends one key — so
//     ``PushPrefsUpdateRequest`` is five optionals that encode only what is set.
//  2. THE RESPONSE IS AN ECHO READ *AFTER* THE WRITE. `PUT` answers with the same
//     total five-key object `GET` does, re-read from storage once the write
//     landed. Adopt it WHOLESALE; never re-derive the stored state from the bool
//     you sent (see ``PushPrefsResponse``).
//  3. AN EMPTY BODY IS LEGAL. `{}` is a plain read-after-write, not an error.
//     UNKNOWN keys are `400 invalid_request`, which is why the request type
//     carries exactly the five and nothing else.
//
// MYR-362 IS THE REASON THE RESPONSE PROPERTIES ARE NON-OPTIONAL, and it is the
// single most important line in this file. A wrong or missing key on an OPTIONAL
// Swift property decodes cleanly to `nil`: no throw, no 4xx, no log — every
// signal the app has says the call worked. §7.16's `VehicleServiceWindowResponse`
// shipped with an invented key on optionals and every save silently adopted a nil
// that was never on the wire. Non-optional here means a wrong key FAILS THE
// DECODE, loudly, in the one place a test can see it.

/// The five push categories §7.19 knows about — the wire's own key set, spelled
/// once so a screen, a service and a request body cannot disagree about it.
///
/// `rideLifecycle` covers the whole rider-facing ride status class (requested /
/// accepted / declined / en route / arrived / completed / expired); the other four
/// are owner-facing. There is deliberately no `promos`/tips category: MYR-349
/// deleted that toggle rather than give it a column (see `SharedSettingsScreen`).
public enum PushPrefCategory: String, CaseIterable, Codable, Sendable {
    /// Rider: the whole requested → accepted/declined → arrived → completed class.
    case rideLifecycle
    /// Owner: a drive began.
    case driveStarted
    /// Owner: a drive ended.
    case driveCompleted
    /// Owner: the car finished charging.
    case chargingComplete
    /// Owner: someone the owner shared with started watching.
    case viewerJoined
}

/// `200 OK` body of BOTH `GET` and `PUT /api/users/me/push-prefs` (§7.19).
///
/// ```json
/// {"rideLifecycle":true,"driveStarted":true,"driveCompleted":true,"chargingComplete":true,"viewerJoined":true}
/// ```
///
/// **ALL FIVE PROPERTIES ARE NON-OPTIONAL, DELIBERATELY.** The server always emits
/// all five — an account with no row stored resolves to all-`true` before
/// answering — so any absent key means the client is talking to something other
/// than §7.19 and must find out immediately rather than render a `nil` folded to a
/// plausible default. This is the MYR-362 rule applied in advance: an optional
/// would make a renamed or mistyped key indistinguishable from a legitimate
/// answer, and there would be nothing anywhere to say so.
///
/// **ADOPT THIS OBJECT WHOLESALE.** On a `PUT` it is not a confirmation of the key
/// you sent; it is the state of all five AFTER the write, read back from storage.
/// A client that adopted its own submission would be correct by luck and would
/// break silently the day the server coerces, refuses, or changes a sibling key.
public struct PushPrefsResponse: Codable, Equatable, Sendable {
    /// Rider ride-status pushes.
    public var rideLifecycle: Bool
    /// Owner "drive started" pushes.
    public var driveStarted: Bool
    /// Owner "drive completed" pushes.
    public var driveCompleted: Bool
    /// Owner "charging complete" pushes.
    public var chargingComplete: Bool
    /// Owner "viewer joined" pushes.
    public var viewerJoined: Bool

    public init(
        rideLifecycle: Bool,
        driveStarted: Bool,
        driveCompleted: Bool,
        chargingComplete: Bool,
        viewerJoined: Bool
    ) {
        self.rideLifecycle = rideLifecycle
        self.driveStarted = driveStarted
        self.driveCompleted = driveCompleted
        self.chargingComplete = chargingComplete
        self.viewerJoined = viewerJoined
    }

    /// The value stored for one category.
    public subscript(category: PushPrefCategory) -> Bool {
        switch category {
        case .rideLifecycle: return rideLifecycle
        case .driveStarted: return driveStarted
        case .driveCompleted: return driveCompleted
        case .chargingComplete: return chargingComplete
        case .viewerJoined: return viewerJoined
        }
    }
}

/// Request body of `PUT /api/users/me/push-prefs` (§7.19) — a PARTIAL object.
///
/// Only the keys the client is changing travel. Swift's synthesized encoder omits
/// a nil optional, which is EXACTLY the semantics §7.19 wants here (contrast
/// ``VehicleServiceWindowUpdateRequest``, where an omitted key and an explicit
/// null are different requests and the encoder is therefore hand-written). An
/// all-nil instance encodes to `{}`, which the contract accepts as a plain
/// read-after-write rather than an error.
///
/// The server strict-decodes: an unknown key is `400 invalid_request`, so this
/// struct carries exactly the five §7.19 names and nothing else.
public struct PushPrefsUpdateRequest: Codable, Equatable, Sendable {
    public var rideLifecycle: Bool?
    public var driveStarted: Bool?
    public var driveCompleted: Bool?
    public var chargingComplete: Bool?
    public var viewerJoined: Bool?

    public init(
        rideLifecycle: Bool? = nil,
        driveStarted: Bool? = nil,
        driveCompleted: Bool? = nil,
        chargingComplete: Bool? = nil,
        viewerJoined: Bool? = nil
    ) {
        self.rideLifecycle = rideLifecycle
        self.driveStarted = driveStarted
        self.driveCompleted = driveCompleted
        self.chargingComplete = chargingComplete
        self.viewerJoined = viewerJoined
    }

    /// The one-key body a single toggle produces — the only shape the app sends.
    ///
    /// Built from the category rather than by naming a property, so a row bound to
    /// `chargingComplete` cannot write `driveCompleted` through a copy-paste slip.
    public init(_ category: PushPrefCategory, _ enabled: Bool) {
        self.init()
        switch category {
        case .rideLifecycle: rideLifecycle = enabled
        case .driveStarted: driveStarted = enabled
        case .driveCompleted: driveCompleted = enabled
        case .chargingComplete: chargingComplete = enabled
        case .viewerJoined: viewerJoined = enabled
        }
    }
}

// MARK: - Sending seam

/// The account push-preference surface (MYR-349), factored into its own protocol
/// so callers depend only on "what does this account want, and change one of them"
/// and can be tested with a stub — the same narrowing pattern as
/// ``PushDeviceEndpoint`` / ``VehicleRideShareEndpoint`` /
/// ``VehicleServiceWindowEndpoint``. `RestClient` is the production conformer.
///
/// Deliberately NOT folded into ``PushDeviceEndpoint``, even though both are
/// "push" and both are account-scoped: a device registration is about ONE INSTALL
/// (its APNs token, its environment, and it is dropped on sign-out), while these
/// preferences belong to the ACCOUNT and outlive every device it ever signs in on.
/// Sharing the seam would let a sign-out path that clears a token reach the user's
/// stored choices, which is the one thing it must never do.
public protocol PushPrefsEndpoint: Sendable {
    /// `GET /api/users/me/push-prefs` (§7.19) — the account's five current values.
    /// Authenticated (Bearer + single 401 refresh-retry). An account with nothing
    /// stored answers all-`true`; there is no "unset" on the wire.
    ///
    /// Throws a typed `RestError` on any non-2xx (`401 auth_failed`,
    /// `500 internal_error`) and `.decoding` on a body missing any of the five
    /// keys — see ``PushPrefsResponse`` for why that is a feature.
    func pushPrefs() async throws -> PushPrefsResponse

    /// `PUT /api/users/me/push-prefs` (§7.19) — change any SUBSET of the five and
    /// receive the whole five back, re-read after the write.
    ///
    /// Authenticated and idempotent: writing the same value twice is the same
    /// `200` and the same stored state. Throws `400 invalid_request` (unknown key
    /// or a non-boolean value), `401 auth_failed`, `500 internal_error` — and a
    /// `500` is never reported as success, because a toggle left in the position
    /// the user chose over a server holding the other one manufactures exactly the
    /// false belief this feature exists to prevent.
    func setPushPrefs(_ update: PushPrefsUpdateRequest) async throws -> PushPrefsResponse
}
