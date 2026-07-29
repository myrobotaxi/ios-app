import Foundation

// MARK: - APNs device-token registration wire shapes (MYR-186)
//
// Same EXCEPTION as `VehiclePlatePayloads.swift` / `VehicleServiceWindowPayloads.swift`
// / `VehicleTeardownPayloads.swift` / `AuthPayloads.swift`: contracts codegen covers
// READ models + the WS envelope only, so there is no generated request type for this
// WRITE. The one DTO below is authored here, verbatim from the locked MYR-186 backend
// contract, and MUST be replaced by a generated type the moment `contracts` grows one.
// Codable/Equatable/Sendable to match the generated-type conventions so the swap is
// drop-in.
//
// WHY THIS ENDPOINT EXISTS AT ALL: APNs addresses a specific INSTALL of the app on a
// specific device, not a user. The server therefore cannot derive a push destination
// from the session — the device must hand its opaque APNs token up, and hand it back
// on sign-out so a shared phone stops receiving the previous account's ride alerts.
// The token is not stable: iOS re-issues it on restore-from-backup, reinstall, and
// occasionally on OS upgrade, so REGISTER is an idempotent upsert that the client
// re-sends whenever the token it holds differs from the one it last confirmed.
//
// WHY `sandbox` IS A CLIENT DECISION: a device token is only valid against the APNs
// environment that minted it, and nothing in the token itself says which one that was.
// The value is the BUILD's APNs environment, resolved from the `aps-environment`
// entitlement the build was signed with — DEBUG builds are signed `development`
// (sandbox), while TestFlight and App Store builds are signed `production` and are
// therefore NOT sandbox. Getting it wrong is silent: APNs simply never delivers.

/// Body of `PUT /api/push/devices` and `DELETE /api/push/devices` (MYR-186).
///
/// BOTH verbs carry the SAME body — the token is the resource identifier, and it is
/// deliberately not a path component (an APNs token is 64 hex characters; a path that
/// long is awkward to log, proxy, and rotate). `DELETE` therefore has a request body,
/// which is unusual but is what the locked contract specifies.
///
/// `deviceToken` is the LOWERCASE HEX encoding of the raw APNs token bytes handed to
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. The app never
/// sends `Data.description` — on modern OS releases that is `{length = 32, bytes = 0x…}`,
/// which is not a token at all.
public struct PushDeviceRegistration: Codable, Equatable, Sendable {
    /// Lowercase hex APNs device token (no `<`/`>`, no spaces).
    public var deviceToken: String
    /// Whether the token was minted by the APNs SANDBOX environment — i.e. whether the
    /// build carries the `development` `aps-environment` entitlement. `false` for
    /// TestFlight and App Store builds.
    public var sandbox: Bool

    public init(deviceToken: String, sandbox: Bool) {
        self.deviceToken = deviceToken
        self.sandbox = sandbox
    }
}

// MARK: - Sending seam

/// The APNs device-token registration surface (MYR-186), factored into its own
/// protocol so callers depend only on "remember / forget this device" and can be
/// tested with a stub — the same narrowing pattern as ``VehiclePlateEndpoint`` /
/// ``VehicleTeardownEndpoint``. `RestClient` is the production conformer.
///
/// Deliberately NOT folded into ``VehicleCommandSending``: a §7.9 command is a signed
/// Tesla actuation against a car that can be asleep or unpaired, while these are
/// account-scoped DB writes that touch no Tesla surface at all, so the route is always
/// mounted and the §7.9 error vocabulary (`vehicle_asleep`, `not_owned`, …) does not
/// apply.
///
/// Both calls return `Void`: the contract's success is `200` with an empty-ish body
/// that carries nothing the client needs. They run the authenticated pipeline's
/// body-DISCARDING path so a zero-byte `200` and a `{}` `200` are both plain success —
/// a client that insisted on decoding either shape would fail on the other.
public protocol PushDeviceEndpoint: Sendable {
    /// `PUT /api/push/devices` (MYR-186) — register (upsert) this install's APNs token
    /// against the signed-in account. Authenticated (Bearer + single 401 refresh-retry).
    /// Idempotent: re-sending an unchanged token is a no-op server-side, which is what
    /// makes the "re-send on every cold start / rotation" client policy safe.
    ///
    /// Throws a typed `RestError` on any non-2xx — `400 invalid_request` (malformed
    /// token), `401 auth_failed` (surfaced only after the one refresh-retry). Callers
    /// MUST treat a failure as "try again next foreground" and never block UI on it:
    /// push is an enhancement, and a device that fails to register still receives every
    /// update over the existing telemetry socket.
    func registerPushDevice(token: String, sandbox: Bool) async throws

    /// `DELETE /api/push/devices` (MYR-186) — forget this install's APNs token. Called
    /// on SIGN-OUT so the next account on this phone does not inherit the previous
    /// one's ride alerts. Same body as the register call (see ``PushDeviceRegistration``).
    ///
    /// Idempotent and best-effort: deleting a token the server never knew is a clean
    /// no-op, and a failure here must not block or delay the sign-out itself.
    func unregisterPushDevice(token: String, sandbox: Bool) async throws
}
