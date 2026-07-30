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
/// ```json
/// { "vehicleId": "clxyz1234567890abcdef", "expectedEndAt": "2026-07-29T18:00:00Z" }
/// ```
///
/// **THE KEY IS `expectedEndAt`, AND IT IS THE OWNER COLUMN — NOT the resolved
/// `serviceEstimatedEndAt`** (MYR-362). This shape was hand-authored from a
/// misreading of §7.16 and named a key the server has never emitted; because
/// every property here is optional, decoding SUCCEEDED and simply produced `nil`,
/// so **every SET adopted a nil echo** and the owner's saved completion date
/// vanished from a sheet whose write had just returned `200`. An absent key on an
/// optional is the quietest possible wire defect: there is no throw, no notice,
/// and no log — only a field that is always empty.
///
/// §7.16 states the choice and the reason in as many words: *"the response echoes
/// the OWNER column rather than the resolved field — echoing the resolved value
/// would make a client believe its write had been overruled when it has merely
/// been outranked by Tesla on the next read, and would leave it with no way to
/// display the value the owner just typed."*
///
/// So the resolved window (`COALESCE(service_etc, service_expected_end_at)`) is
/// **not knowable from this response at all**, and §7.16 says what to do instead:
/// *"A client that needs the new value immediately either adopts this response
/// optimistically or re-reads §7.0 / §7.1."* `LiveVehicleCommandExecutor
/// .setServiceWindow` does both — it adopts this echo, and MYR-351's
/// deliberately non-latching read guard lets the first `/snapshot` issued after
/// the commit replace it with the resolved value when Tesla outranks it.
///
/// `expectedEndAt` is nullable for exactly one reason: the owner cleared their
/// entry (any of §7.16's four clearing spellings). It is the OWNER's column, so
/// it is unaffected by Tesla's estimate and by the car leaving service — both of
/// those move the RESOLVED field on the next read, not this one.
public struct VehicleServiceWindowResponse: Codable, Equatable, Sendable {
    /// Echo of the path parameter (the Prisma cuid, NOT a VIN).
    public var vehicleId: String
    /// The owner's expected-back instant now stored in `service_expected_end_at`,
    /// RFC 3339 UTC, or `nil` when cleared. Server-validated (future-only) and
    /// server-normalized, so it is the owner's submission rather than a second
    /// opinion — but it is NOT necessarily what §7.0 / §7.1 will emit next.
    public var expectedEndAt: String?

    public init(vehicleId: String, expectedEndAt: String?) {
        self.vehicleId = vehicleId
        self.expectedEndAt = expectedEndAt
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
