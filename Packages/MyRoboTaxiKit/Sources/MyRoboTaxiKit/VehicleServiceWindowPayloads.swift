import Foundation

// MARK: - Owner "expected back" service-window wire shapes (MYR-316)
//
// Same EXCEPTION as `VehiclePlatePayloads.swift` / `VehicleTeardownPayloads.swift`
// / `TeslaLinkPayloads.swift`: contracts codegen covers READ models + the WS
// envelope only, so contracts v0.17.0 ships the `serviceEstimatedEndAt` READ
// field on `VehicleState`/`VehicleSummary` but NO request/response type for the
// WRITE. These two tiny DTOs are authored here, verbatim from the locked
// endpoint contract, and MUST be replaced by generated types the moment
// `contracts` grows them. Codable/Equatable/Sendable to match the generated-type
// conventions so the swap is drop-in.
//
// WHY THE WRITE EXISTS AT ALL, given the field is SERVER-COMPUTED: the server's
// precedence for `serviceEstimatedEndAt` is (1) Tesla's own `service_etc` from
// the Fleet API's `service_data`, (2) failing that, the value the owner enters
// HERE, (3) null. Tesla returns an all-null `service_data` body for any visit
// with no appointment record — which is the COMMON case — so without this
// endpoint the field would simply be null for most real service visits and the
// rider scheduling floor would never engage. The owner is the fallback source of
// truth, not an override: a client CANNOT tell from the wire which source
// produced the value it reads back (there is no source discriminator on the read
// shape), and it does not need to — it renders whatever the server resolved.

/// Request body of `PUT /api/tesla/vehicles/{vehicleId}/service-window` (MYR-316).
///
/// The wire key is **`expectedEndAt`**, NOT `serviceEstimatedEndAt` — the write
/// names the OWNER'S input, while the read field names the server's RESOLVED
/// value (which may be Tesla's instead). The server strict-decodes this body, so
/// the asymmetry is load-bearing, not a typo — the same shape as §7.14's
/// `plate` → `licensePlate`.
///
/// `nil` (encoded as JSON `null`) **CLEARS** the owner's entry, exactly like an
/// empty string does; both are an ordinary write, not a separate verb. Clearing
/// does NOT necessarily null the read field: if Tesla holds an estimate it keeps
/// winning under precedence (1).
///
/// The value must be RFC 3339 and **in the future** — the server answers `400
/// invalid_request` otherwise. Clients validate client-side too (so the owner
/// gets an immediate, local answer instead of a round trip), but the server's
/// check is the authority; the two deliberately state the same rule.
public struct VehicleServiceWindowUpdateRequest: Codable, Equatable, Sendable {
    /// RFC 3339 instant the owner expects the car back, or `nil` to clear.
    ///
    /// Declared as a double optional in `encode(to:)` terms: the key is ALWAYS
    /// emitted, carrying an explicit `null` when clearing, because an omitted key
    /// and an explicit null are not the same request to a strict decoder.
    public var expectedEndAt: String?

    public init(expectedEndAt: String?) {
        self.expectedEndAt = expectedEndAt
    }

    /// Always emit `expectedEndAt`, even when nil. Swift's synthesized encoder
    /// OMITS a nil optional, which would send `{}` for a clear — a body that says
    /// "change nothing", not "clear it". The clear is the whole point of the nil
    /// case, so it is encoded explicitly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedEndAt, forKey: .expectedEndAt)
    }
}

/// `200 OK` body of `PUT /api/tesla/vehicles/{vehicleId}/service-window` (MYR-316).
///
/// The response ECHOES the server's RESOLVED `serviceEstimatedEndAt` — which is
/// NOT necessarily the value just submitted: Tesla's `service_etc` outranks the
/// owner's entry, so an owner who types 4 PM against a Tesla estimate of 2 PM
/// gets 2 PM back. Callers MUST adopt this field, never the string they sent, or
/// the sheet will claim a completion time the server does not hold.
///
/// `serviceEstimatedEndAt` is nullable here for two distinct real reasons — the
/// owner cleared their entry and Tesla has none, or the car has already left
/// `in_service` (the server clears the field automatically on that transition).
/// Both mean the same thing to a consumer: no window is known.
public struct VehicleServiceWindowResponse: Codable, Equatable, Sendable {
    /// Echo of the path parameter (the Prisma cuid, NOT a VIN).
    public var vehicleId: String
    /// The server's RESOLVED estimate now stored, or `nil` when none is known.
    /// Never re-derive this from the request.
    public var serviceEstimatedEndAt: String?

    public init(vehicleId: String, serviceEstimatedEndAt: String?) {
        self.vehicleId = vehicleId
        self.serviceEstimatedEndAt = serviceEstimatedEndAt
    }
}

// MARK: - Sending seam

/// The owner service-window write surface (MYR-316), factored into its own
/// protocol so callers depend only on "store this expected-back time" and can be
/// tested with a stub — the same narrowing pattern as ``VehiclePlateEndpoint`` /
/// ``VehicleTeardownEndpoint`` / ``VehicleCommandSending``. `RestClient` is the
/// production conformer.
///
/// Deliberately NOT folded into ``VehicleCommandSending``, for exactly the reason
/// ``VehiclePlateEndpoint`` is not: a §7.9 command is a signed Tesla actuation
/// that can be asleep, unpaired, or refused by the car, while this is an
/// owner-scoped DB write that touches no Tesla surface. Sharing the seam would
/// invite the wake-retry / `key_not_paired` vocabulary onto an endpoint that can
/// never produce it.
public protocol VehicleServiceWindowEndpoint: Sendable {
    /// `PUT /api/tesla/vehicles/{vehicleId}/service-window` (MYR-316) — store the
    /// owner's expected-back time for one owned vehicle and return the server's
    /// RESOLVED estimate. Owner-authenticated; idempotent; `nil` clears.
    ///
    /// Throws a typed `RestError.http` on any non-2xx: `400 invalid_request` (the
    /// instant is not in the future, or is not RFC 3339), `401 auth_failed`,
    /// `403 vehicle_not_owned`, `404 not_found` (unknown OR ownership-filtered —
    /// deliberately indistinguishable, matching §7.12/§7.14).
    func setServiceWindow(expectedEndAt: String?, vehicleID: String) async throws -> VehicleServiceWindowResponse
}
