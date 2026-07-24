import Foundation

// MARK: - Owner car-offboarding wire shapes (rest-api.md §7.12, MYR-258)
//
// Same EXCEPTION as `TeslaLinkPayloads.swift` / `AuthPayloads.swift`: the §7.12
// owner-teardown surface (`DELETE /api/tesla/vehicles/{vehicleId}`) landed on the
// backend AFTER the last `MyRobotaxiContracts` codegen and has no JSON Schema in
// the telemetry repo yet, so there is no generated `VehicleTeardown*` type to
// import. These small DTOs are authored here, verbatim from rest-api.md §7.12,
// and MUST be replaced by the generated types the moment `contracts` regenerates
// the teardown schema (codegen follow-up — see the PR body). Codable/Equatable/
// Sendable to match the generated-type conventions so the swap is drop-in.

/// The owner-manual virtual-key removal instructions returned by §7.12. Tesla's
/// security model gives a partner NO API and NO deep link to remove its own
/// enrolled key (car-offboarding.md §1.3) — so `automatable` is ALWAYS `false`,
/// and `steps` is rendered verbatim to the owner. All fields P0 (public copy).
public struct VirtualKeyRemoval: Codable, Equatable, Sendable {
    /// Whether a MyRoboTaxi virtual key is (was) enrolled and needs removal.
    public var required: Bool
    /// Always `false` — there is no Fleet API and no deep link to do this for the
    /// owner; it is instructions only.
    public var automatable: Bool
    /// Ordered, human-readable steps the owner follows in the Tesla app / car.
    public var steps: [String]

    public init(required: Bool, automatable: Bool, steps: [String]) {
        self.required = required
        self.automatable = automatable
        self.steps = steps
    }
}

/// Response of `DELETE /api/tesla/vehicles/{vehicleId}` (§7.12) — the honest
/// post-teardown state plus the two owner-only follow-up actions Tesla's model
/// leaves to the owner (consent revoke + virtual-key removal).
///
/// The teardown is authoritative and idempotent: `removed` is `true` on both a
/// fresh removal and an already-gone no-op. `wasLastVehicle` mirrors
/// `teslaTokensCleared` (our stored Tesla tokens were deleted + `Settings` reset)
/// when this was the owner's last linked car. `streamConfigDeleted` reports the
/// best-effort Tesla `fleet_telemetry_config` delete (non-fatal on skip/failure).
/// `revokeUrl` is the owner-confirmed Tesla consent-revoke deep link (public, no
/// secret; omitted when no Tesla `client_id` is configured) — deleting OUR tokens
/// removes OUR access but does NOT revoke the grant, which only the owner can do.
public struct VehicleTeardownResponse: Codable, Equatable, Sendable {
    /// Authoritative: the car is gone from the app (true on a fresh removal AND an
    /// already-gone no-op).
    public var removed: Bool
    /// True when this was the owner's last linked vehicle (Account tokens cleared
    /// + `Settings` reset).
    public var wasLastVehicle: Bool
    /// Mirrors `wasLastVehicle`: our stored Tesla tokens were deleted. Removes OUR
    /// access, not the Tesla grant itself.
    public var teslaTokensCleared: Bool
    /// Whether the best-effort Tesla `fleet_telemetry_config` delete succeeded.
    /// `false` on skip/failure — non-fatal.
    public var streamConfigDeleted: Bool
    /// Owner-confirmed consent-revoke deep link (public URL, no secret). Omitted
    /// (`nil`) when no Tesla `client_id` is configured.
    public var revokeUrl: String?
    /// Owner-manual key-removal instructions (always `automatable == false`).
    public var virtualKeyRemoval: VirtualKeyRemoval

    public init(
        removed: Bool,
        wasLastVehicle: Bool,
        teslaTokensCleared: Bool,
        streamConfigDeleted: Bool,
        revokeUrl: String?,
        virtualKeyRemoval: VirtualKeyRemoval
    ) {
        self.removed = removed
        self.wasLastVehicle = wasLastVehicle
        self.teslaTokensCleared = teslaTokensCleared
        self.streamConfigDeleted = streamConfigDeleted
        self.revokeUrl = revokeUrl
        self.virtualKeyRemoval = virtualKeyRemoval
    }
}

/// The owner car-offboarding surface (rest-api.md §7.12, MYR-258), factored into
/// its own protocol so callers depend only on "remove this car" and can be tested
/// with a stub — the same narrowing pattern as ``TeslaLinkEndpoint`` /
/// ``AuthenticationEndpoint``. `RestClient` is the production conformer.
///
/// Owner-authenticated: it runs the standard Bearer + single 401-refresh pipeline
/// (the caller must already be a signed-in owner). The full teardown is a local DB
/// transaction, so the route is always mounted regardless of proxy config.
public protocol VehicleTeardownEndpoint: Sendable {
    /// `DELETE /api/tesla/vehicles/{vehicleId}` (§7.12) — full owner teardown of
    /// one owned vehicle. Authoritative + idempotent. Owner-authenticated; no
    /// request body. `{vehicleId}` is the Prisma cuid (NOT a VIN).
    func removeVehicle(vehicleID: String) async throws -> VehicleTeardownResponse
}
