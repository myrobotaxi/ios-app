import Foundation

// MARK: - Owner ride-share pause wire shapes (MYR-342, rest-api.md §7.18)
//
// Same EXCEPTION as `VehicleServiceWindowPayloads.swift` / `VehiclePlatePayloads
// .swift` / `VehicleTeardownPayloads.swift`: contracts codegen covers READ models
// + the WS envelope only, so contracts v0.20.0 ships the `rideShareEnabled` READ
// field on `VehicleState`/`VehicleSummary` but NO request/response type for the
// WRITE. These two tiny DTOs are authored here, verbatim from §7.18, and MUST be
// replaced by generated types the moment `contracts` grows them.
// Codable/Equatable/Sendable to match the generated-type conventions so the swap
// is drop-in.
//
// WHAT THIS SWITCH IS. Not a fact about the car — an OWNER INTENTION about it.
// §7.18 states the gap it closes in as many words: before it an owner had two
// ways to stop riders booking their car and neither was a switch. They could mark
// it `in_service` (a lie about where the car is — and one MYR-313 lets SCHEDULED
// rides through anyway, so it does not even work), or decline every incoming
// request by hand forever (a chore, not a state). Nothing could express "the car
// is fine; I am simply not lending it out at the moment".
//
// THREE PROPERTIES THAT SHAPE EVERY CONSUMER BELOW:
//
//  1. NO TESLA CALL, EVER. Like §7.14 (plate) and §7.16 (service window) this is a
//     local owner-scoped DB write. The car is never asked, never woken, and is
//     never the thing that refuses — so none of the §7.9 command vocabulary
//     (asleep / key-not-paired / rejected) may appear on this path.
//  2. NO CLEAR, AND NO THIRD STATE. This is the ONE place §7.18 deliberately
//     diverges from its §7.16 template: `enabled` is REQUIRED. The service-window
//     body treats an absent key, an explicit null, an empty string and an empty
//     body as four spellings of the same *clear*; here BOTH VALUES ARE DECISIONS,
//     so all four of those spellings are `400 invalid_request`. Guessing would
//     either un-pause a car its owner paused or withdraw one its owner never
//     touched.
//  3. IDEMPOTENT IN BOTH DIRECTIONS. PUTting `false` twice yields the same `200`
//     and the same stored value; so does `true`. The toggle is not a one-way door.

/// Request body of `PUT /api/tesla/vehicles/{vehicleId}/ride-share` (§7.18).
///
/// One REQUIRED boolean. `true` resumes ride requests for this vehicle; `false`
/// PAUSES them. There is no clear and no "unset" — see property 2 above.
///
/// The server strict-decodes this body (`additionalProperties: false`), so an
/// extra key is a `400`; the struct carries exactly the one field for that reason.
public struct VehicleRideShareUpdateRequest: Codable, Equatable, Sendable {
    /// `true` resumes, `false` pauses. Never optional — silence is not an answer
    /// on this endpoint.
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// `200 OK` body of `PUT /api/tesla/vehicles/{vehicleId}/ride-share` (§7.18).
///
/// The wire key is **`enabled`** — the same word the REQUEST uses, and NOT the
/// read shapes' `rideShareEnabled`. The asymmetry is load-bearing rather than a
/// typo, exactly as it is for §7.16's `expectedEndAt` → `serviceEstimatedEndAt`
/// and §7.14's `plate` → `licensePlate`: the write names the owner's INPUT, the
/// read names the stored field.
///
/// ADOPT THIS VALUE, never the bool you sent. §7.18 is explicit that this server
/// writes exactly what was asked, so today the echo always equals the request —
/// and it is echoed anyway "because the contract's rule is that the client adopts
/// the server's answer, which keeps a future server free to refuse or coerce
/// without breaking clients". A client that adopted its own submission would be
/// correct by luck and would break silently the day that changes.
///
/// Note what is NOT here: there is no precedence to worry about (unlike §7.16,
/// where Tesla's `service_etc` outranks the owner's entry). Nothing outranks the
/// owner on this field — no telemetry frame can reach it, by construction: the
/// column is deliberately absent from the shared telemetry-fed control-state
/// upsert so a routine frame from the car cannot silently re-enable a car its
/// owner paused.
public struct VehicleRideShareResponse: Codable, Equatable, Sendable {
    /// Echo of the path parameter (the Prisma cuid, NOT a VIN).
    public var vehicleId: String
    /// The RESOLVED stored value. Never re-derive this from the request.
    public var enabled: Bool

    public init(vehicleId: String, enabled: Bool) {
        self.vehicleId = vehicleId
        self.enabled = enabled
    }
}

// MARK: - Sending seam

/// The owner ride-share write surface (MYR-342), factored into its own protocol
/// so callers depend only on "pause / resume rides for this car" and can be tested
/// with a stub — the same narrowing pattern as ``VehicleServiceWindowEndpoint`` /
/// ``VehiclePlateEndpoint`` / ``VehicleTeardownEndpoint`` / ``VehicleCommandSending``.
/// `RestClient` is the production conformer.
///
/// Deliberately NOT folded into ``VehicleCommandSending``, for exactly the reason
/// ``VehicleServiceWindowEndpoint`` is not: a §7.9 command is a signed Tesla
/// actuation that can be asleep, unpaired, or refused by the car, while this is an
/// owner-scoped DB write that touches no Tesla surface. Sharing the seam would
/// invite the wake-retry / `key_not_paired` vocabulary onto an endpoint that can
/// never produce it.
///
/// Deliberately NOT folded into ``VehicleServiceWindowEndpoint`` either, even
/// though both are §7.1x owner-scoped writes with the same error catalog: the two
/// can be in flight independently, and their failures say different things to an
/// owner ("that time has passed" vs. "the switch didn't move").
public protocol VehicleRideShareEndpoint: Sendable {
    /// `PUT /api/tesla/vehicles/{vehicleId}/ride-share` (§7.18) — pause or resume
    /// ride requests for one OWNED vehicle and return the server's RESOLVED value.
    /// Owner-authenticated; idempotent in both directions.
    ///
    /// Throws a typed `RestError.http` on any non-2xx: `400 invalid_request`
    /// (missing vehicle id, malformed body, unknown keys, or a non-boolean
    /// `enabled`), `401 auth_failed`, `403 vehicle_not_owned` (**including a viewer
    /// at ANY share tier** — no tier grants this toggle, at any level: the pause is
    /// the owner's switch and a rider able to flip it would invert the feature),
    /// `404 not_found` (unknown OR ownership-filtered — deliberately
    /// indistinguishable, matching §7.12/§7.14/§7.16), `500 internal_error`
    /// (atomic: nothing written, retryable — and never reported as success, since a
    /// `200` over a failed write would leave an owner believing their car is paused
    /// while it is still taking requests).
    func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse
}
