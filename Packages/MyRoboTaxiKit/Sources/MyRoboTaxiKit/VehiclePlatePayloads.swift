import Foundation

// MARK: - Owner license-plate entry wire shapes (rest-api.md §7.14, MYR-286)
//
// Same EXCEPTION as `VehicleTeardownPayloads.swift` / `TeslaLinkPayloads.swift` /
// `AuthPayloads.swift`: contracts codegen covers READ models + the WS envelope
// only, so contracts v0.15.0 ships the `licensePlate` READ field on
// `VehicleState`/`VehicleSummary` but NO request/response type for the §7.14
// WRITE. These two tiny DTOs are authored here, verbatim from rest-api.md §7.14,
// and MUST be replaced by generated types the moment `contracts` grows them.
// Codable/Equatable/Sendable to match the generated-type conventions so the swap
// is drop-in.
//
// WHY THIS ENDPOINT EXISTS AT ALL: the plate is NOT a Tesla value. The Fleet API
// exposes no license plate on any endpoint, in any telemetry field, or in any
// proto — there is nothing to sync or decode. `Vehicle.licensePlate` is populated
// ONLY by the owner typing it here, which is why §7.14 is a plain owner-scoped DB
// write with no Tesla call anywhere in it (and therefore NOT a §7.9 vehicle
// command — see `VehicleCommandEndpoint.swift`).

/// Request body of `PUT /api/tesla/vehicles/{vehicleId}/plate` (§7.14).
///
/// The wire key is **`plate`**, NOT `licensePlate` — the server strict-decodes
/// this body and rejects an unknown key with `400 invalid_request`, so the
/// asymmetry with the response's `licensePlate` is load-bearing, not a typo.
///
/// The value is sent AS THE OWNER TYPED IT. The server normalizes (trim, then
/// uppercase) and only then validates (≤ 10 chars, charset `^[A-Z0-9 -]*$`), so
/// `"  abc 1234  "` is accepted and stored as `"ABC 1234"`. Clients therefore do
/// NOT pre-normalize: doing so would silently diverge from the server's rule and
/// make the echoed value look like a client-side transformation. An **empty
/// string CLEARS** the stored plate (an ordinary write, not a separate verb).
public struct VehiclePlateUpdateRequest: Codable, Equatable, Sendable {
    /// The plate as typed. Empty string clears.
    public var plate: String

    public init(plate: String) {
        self.plate = plate
    }
}

/// `200 OK` body of `PUT /api/tesla/vehicles/{vehicleId}/plate` (§7.14).
///
/// The response ECHOES the normalized stored value specifically so a client can
/// adopt it without a re-read — there is no WebSocket delta for this field in v1
/// (a `vehicle_update` frame NEVER carries `licensePlate`), so this echo and the
/// next §7.0/§7.1 read are the only two ways the new value ever reaches a client.
/// Callers MUST adopt `licensePlate`, never the string they submitted.
public struct VehiclePlateResponse: Codable, Equatable, Sendable {
    /// Echo of the path parameter (the Prisma cuid, NOT a VIN).
    public var vehicleId: String
    /// The **normalized** value now stored — already trimmed/uppercased by the
    /// server. Empty string when the plate was cleared. Never re-normalize it.
    public var licensePlate: String

    public init(vehicleId: String, licensePlate: String) {
        self.vehicleId = vehicleId
        self.licensePlate = licensePlate
    }
}

// MARK: - Sending seam

/// The owner license-plate write surface (§7.14), factored into its own protocol
/// so callers depend only on "store this plate" and can be tested with a stub —
/// the same narrowing pattern as ``VehicleTeardownEndpoint`` /
/// ``VehicleCommandSending``. `RestClient` is the production conformer.
///
/// Deliberately NOT folded into ``VehicleCommandSending``: a §7.9 command is a
/// signed Tesla actuation that can be asleep, unpaired, or rejected by the car,
/// while this is a local owner-scoped DB write that touches no Tesla surface at
/// all. Sharing the seam would invite the §7.9 wake-retry / `key_not_paired`
/// vocabulary onto an endpoint that can never produce it.
public protocol VehiclePlateEndpoint: Sendable {
    /// `PUT /api/tesla/vehicles/{vehicleId}/plate` (§7.14) — store the owner's
    /// plate for one owned vehicle and return the server-normalized value.
    /// Owner-authenticated; idempotent; an empty `plate` clears.
    ///
    /// Throws a typed `RestError.http` on any non-2xx: `400 invalid_request`
    /// (charset / 10-char cap violated AFTER normalization — the rejected value
    /// is never echoed back), `401 auth_failed`, `403 vehicle_not_owned`,
    /// `404 not_found` (unknown OR ownership-filtered — deliberately
    /// indistinguishable, matching §7.12).
    func setLicensePlate(_ plate: String, vehicleID: String) async throws -> VehiclePlateResponse
}
