import Foundation
import MyRobotaxiContracts

// MARK: - Vehicle sharing (rest-api.md §7.5, MYR-184)
//
// Five endpoints, TWO audiences. Four are OWNER-facing and speak `ShareInvite`;
// one is RIDER-facing and speaks `RedeemShareInviteResponse`. `ShareInvite` is
// NEVER delivered to an invited party — it carries the owner-typed `label` and,
// while pending, the live `code`.
//
// Unlike `VehiclePlatePayloads` / `VehicleTeardownPayloads`, this family needs NO
// locally-authored DTOs: contracts v0.19.0 generates every request AND response
// shape here, including the write bodies. The Kit owns zero wire shapes for it.
//
// CODES, NOT EMAILS. The platform has no email infrastructure; the owner mints a
// 6-character code and hands it out through the iOS system share sheet. Nothing
// in this family accepts, stores, or resolves an email address.

/// The vehicle-sharing surface (§7.5), factored into its own protocol so callers
/// depend only on "mint / list / revoke / re-mint / redeem" and can be tested with
/// a stub — the same narrowing pattern as ``VehiclePlateEndpoint`` /
/// ``VehicleTeardownEndpoint`` / ``VehicleCommandSending``. `RestClient` is the
/// production conformer.
///
/// Deliberately ONE protocol spanning both audiences even though the redeem call
/// is rider-facing: the five endpoints are one server-side feature with one error
/// vocabulary, and splitting them would make the app compose two seams to
/// implement one screen pair. The *app-level* seam (`ShareService`) is what draws
/// the owner/rider line.
public protocol VehicleSharingEndpoint: Sendable {
    /// `POST /api/vehicles/{vehicleId}/invites` (§7.5.1) — mint ONE code and
    /// create one grant row per vehicle in the requested set. Owner-only.
    ///
    /// The 201 body is the row for the **path vehicle**; sibling rows are not
    /// returned, and the `code` on the returned row is the one to hand out for all
    /// of them. `vehicleIds`, when present, MUST include the path vehicle (400
    /// otherwise — the path vehicle is what authorizes the call).
    ///
    /// ALL-OR-NOTHING: a set containing one car the caller does not own mints
    /// nothing at all. Not idempotent — a retry mints a second code.
    func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite

    /// `GET /api/vehicles/{vehicleId}/invites` (§7.5.2) — the owner's pending
    /// invites + accepted viewer grants for ONE vehicle, newest first. Owner-only.
    ///
    /// Returns the unwrapped rows; the `ShareInviteListResponse` envelope (key
    /// `invites`, NOT `items` — this surface is unpaginated by contract) is handled
    /// here. Revoked rows are never serialized, so callers never filter for them.
    func shareInvites(vehicleID: String) async throws -> [ShareInvite]

    /// `DELETE /api/invites/{inviteId}` (§7.5.3) — cancel a pending invite OR
    /// revoke an accepted grant; the row is tombstoned, never hard-deleted.
    /// Owner-only, `204 No Content`, and IDEMPOTENT for the caller's own rows
    /// (re-revoking answers 204, not a spurious 404).
    func revokeShareInvite(inviteID: String) async throws

    /// `POST /api/invites/{inviteId}/resend` (§7.5.4) — mint a NEW code and reset
    /// `expiresAt` to a full 7 days, invalidating the previous code. Owner-only and
    /// PENDING-only (`409 conflict` on an accepted grant).
    ///
    /// The re-mint covers EVERY row of the invite atomically, not only the path
    /// row: a multi-vehicle invite is one code backing N rows, so re-minting one
    /// row would leave the leaked code live on the siblings. The 200 body is still
    /// the PATH row, with `inviteId` and `createdAt` unchanged.
    func resendShareInvite(inviteID: String) async throws -> ShareInvite

    /// `POST /api/invites/redeem` (§7.5.5) — the RIDER-side join. Accepts every
    /// pending, unexpired row backing the code, atomically, for the authenticated
    /// caller. The redeeming account is the JWT subject and is never client-supplied.
    ///
    /// `vehicles` is never empty and every row carries `role: viewer` plus a
    /// `sharePermission`, viewer-masked exactly as §7.0 will show them a second
    /// later — so the caller can seed its catalog straight from this response.
    ///
    /// Fold the failure through ``ShareRedemptionFailure`` rather than branching on
    /// raw status codes: 404 deliberately conflates unknown / expired / already-
    /// consumed, and the client must not pretend to distinguish them.
    func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse
}

// MARK: - Cumulative tier comparison

extension SharePermission {
    /// Rank over the contract's TOTAL ORDER `live` < `live_history` < `rides`.
    ///
    /// `nil` for `.unrecognized` — a tier this build has never heard of. A newer
    /// contracts version appends only in INCREASING-privilege order, so an
    /// unrecognized value is strictly *above* `rides`; but ranking it that way
    /// would grant affordances on a tier we cannot reason about, so it is
    /// deliberately unrankable and `grants(_:)` fails CLOSED on it.
    var rank: Int? {
        switch self {
        case .live: return 0
        case .liveHistory: return 1
        case .rides: return 2
        case .unrecognized: return nil
        }
    }

    /// Cumulative `>=` over the tier order — the ONLY correct way to test a tier
    /// (§7.5.0: "every server gate compares with a `>=` over that order, never
    /// equality"). `rides` grants `live_history` grants `live`.
    ///
    /// Fails CLOSED on an unrecognized tier on either side: a client that cannot
    /// rank a value must not offer the affordance. This is a UI-affordance hint
    /// only — the server independently enforces every gate, so a client that gets
    /// this wrong cannot escalate, it can only mis-offer.
    public func grants(_ required: SharePermission) -> Bool {
        guard let mine = rank, let needed = required.rank else { return false }
        return mine >= needed
    }
}

extension VehicleSummary {
    /// The caller's effective tier over this row, resolved per the contract's
    /// absent-value rule: on a `viewer` row an ABSENT `sharePermission` means the
    /// LOWEST tier (`live`) — "never fail open" — because absence means either a
    /// server predating MYR-184 or a field the projection dropped, and neither is
    /// evidence of full access.
    ///
    /// `nil` on an OWNER row: an owner is not on a tier, they hold everything, so
    /// callers branch on `role` first rather than reading a synthesized tier.
    public var effectiveSharePermission: SharePermission? {
        guard role == .viewer else { return nil }
        return sharePermission ?? .live
    }
}

// MARK: - Typed redemption failures

/// The §7.5.5 error catalog, folded into the four answers a rider's invite-code
/// screen can actually act on. Built from the typed `RestError` — never from the
/// human `message` (FR-7.1).
///
/// The 404 case is deliberately ONE case covering unknown / expired / already-
/// consumed-by-another-account: the server answers all three with an identical
/// body specifically so an enumerating caller cannot tell them apart, and a client
/// that invented three different messages would be guessing out loud.
public enum ShareRedemptionFailure: Equatable, Sendable {
    /// `400 invalid_request` — malformed after normalization (wrong length or
    /// illegal characters). Distinct from `.invalidOrExpired` on purpose: "you sent
    /// nonsense" and "that code grants you nothing" are different answers.
    case malformed
    /// `404 not_found` — unknown, expired, or already consumed by a different
    /// account. Indistinguishable by design.
    case invalidOrExpired
    /// `409 conflict` — the caller OWNS one of the target vehicles, or already
    /// holds a grant on one of them through a different invite. Nothing was written.
    case alreadyHasAccess
    /// `429 rate_limited` — the per-user redemption cap (10 attempts/minute, every
    /// attempt counted including successes). The honest response is to wait, never
    /// an auto-retry.
    case tooManyAttempts
    /// `401` and any other transport/server failure — not a verdict on the code.
    case unavailable
}

extension RestError {
    /// Fold this error onto the §7.5.5 redemption catalog. Returns `nil` when the
    /// error is not one of the catalog's statuses AND not a transport failure —
    /// i.e. the caller should keep throwing rather than render a code verdict.
    public var shareRedemptionFailure: ShareRedemptionFailure {
        switch self {
        case .http(let status, _, _, _):
            switch status {
            case 400: return .malformed
            case 404: return .invalidOrExpired
            case 409: return .alreadyHasAccess
            case 429: return .tooManyAttempts
            default: return .unavailable
            }
        default:
            return .unavailable
        }
    }

    /// `409 conflict` on `POST /api/invites/{id}/resend` (§7.5.4) — the invite has
    /// already been ACCEPTED, so there is nothing to re-mint. Changing who holds an
    /// accepted grant is a revoke plus a fresh invite; silently re-opening it for
    /// redemption by a different person would be a quiet transfer of access.
    public var isShareInviteAlreadyAccepted: Bool {
        httpStatus == 409
    }

    /// `404 not_found` on a single-invite endpoint (§7.5.3 / §7.5.4) — the invite
    /// does not exist, belongs to another owner, or is a revoked tombstone. All
    /// three answer identically: this endpoint is not an oracle for other people's
    /// invite ids.
    ///
    /// For a DELETE this is a benign terminal state (the grant is gone either way),
    /// which is why callers treat it as success rather than surfacing it.
    public var isShareInviteGone: Bool {
        httpStatus == 404
    }
}
