import Foundation
import MyRobotaxiContracts

// MARK: - Vehicle sharing (rest-api.md §7.5, MYR-184)
//
// SIX endpoints, TWO audiences. Five are OWNER-facing and speak `ShareInvite`;
// one is RIDER-facing and speaks `RedeemShareInviteResponse`. `ShareInvite` is
// NEVER delivered to an invited party — it carries the owner-typed `label`, the
// owner-only capability flags, and, while pending, the live `code`.
//
// Unlike `VehiclePlatePayloads` / `VehicleTeardownPayloads`, this family needs NO
// locally-authored DTOs: contracts generates every request AND response shape
// here, including the write bodies (v0.19.0 for the original five, v0.23.0 for
// MYR-369's `PatchShareInviteRequest`). The Kit owns zero wire shapes for it —
// which is the whole reason MYR-362's wrong-key class cannot recur on this
// family, and why the fixtures are pinned against the GENERATED types below.
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

    /// `PATCH /api/invites/{inviteId}` (MYR-369) — the owner editing ONE accepted
    /// grant's capabilities IN PLACE. This is what replaces the pre-MYR-369 rule
    /// that a grant's access was fixed for its life and changing it meant
    /// revoke-plus-reinvite.
    ///
    /// ACCEPTED GRANTS ONLY: a still-`pending` invite answers `409 conflict`,
    /// because a pending row has no grant to edit — its access is decided at
    /// redemption from the invite's `permission` preset. Owner-only; an invite
    /// that does not exist, belongs to another owner, or is a revoked tombstone
    /// all answer `404` INDISTINGUISHABLY (``RestError/isShareInviteGone``), the
    /// same non-oracle rule DELETE follows.
    ///
    /// PARTIAL BY DESIGN — only the properties PRESENT are written, and an absent
    /// property is NOT the same as sending `false`. At least one is required
    /// (`minProperties: 1`); an empty body is a `400`, deliberately, so a client
    /// bug cannot look like a successful edit.
    ///
    /// APPLIES TO ONE ROW: a multi-vehicle invite is N rows and patching one
    /// changes that vehicle's grant only, so an owner may hold different
    /// capabilities per vehicle for the same person. Callers standing for a
    /// grouped screen row must therefore patch every id in the group.
    ///
    /// The 200 body is the updated row — an accepted row, so it carries
    /// `allowRides`, `suspended` and the DERIVED `permission`, and carries
    /// neither `code` nor `shareUrl`.
    func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite
}

// MARK: - Per-grant capability reads (MYR-369)
//
// The tier comparison that used to live here is GONE. `SharePermission.rank` and
// `grants(_:)` implemented the contract's pre-MYR-369 TOTAL ORDER
// (live < live_history < rides) with a cumulative `>=`, which the 0.23.0 contract
// now states in as many words is WRONG on an accepted row: the underlying model
// is a set of independent editable flags, not an order. They are DELETED rather
// than deprecated on purpose — a comparator that still compiles is a foot-gun,
// and every call site had to be visited anyway.

extension SharePermission {
    /// Whether this DERIVED projection says the viewer may request rides.
    ///
    /// EQUALITY, not `>=`. On an accepted row the server derives this value on
    /// every read — `allowRides` true → `rides`, otherwise `live` — so `rides` is
    /// the only value that means "may ride", and there is no longer a tier above
    /// it that implies it.
    ///
    /// `live_history` answers `false`: it IS RETIRED AND NEVER EMITTED, and a
    /// legacy grant created at that preset derives `live`. The member survives in
    /// the enum for wire compat only, so an installed decoder keeps decoding.
    ///
    /// Fails CLOSED on `.unrecognized` — a value this build has never heard of is
    /// not evidence of permission. UI-affordance hint only: the server enforces
    /// the gate on every ride create, owner accept and reservation dispatch, so a
    /// client that gets this wrong can only mis-OFFER, never escalate.
    public var allowsRides: Bool { self == .rides }
}

extension ShareInvite {
    /// Whether this grant may request rides — the truth, preferred over the
    /// derived ``permission`` projection wherever the owner-only flag is present.
    ///
    /// THE ABSENCE RULE IS A FALLBACK, NOT A DEFAULT. `allowRides` is omitted on
    /// a `pending` row (there is no grant yet) and by any server predating
    /// MYR-369. The contract's instruction for both is to fall back to
    /// `permission` — `rides` → true — and NEVER to assume either value outright.
    ///
    /// NOT INDEPENDENT OF SUSPENSION: this describes what the grant WOULD allow
    /// once active. A suspended grant with `allowRides: true` grants NOTHING, so
    /// an owner-facing control renders the switch in its stored position while
    /// suspended, and no viewer-facing surface may present the person as able to
    /// ride without checking ``isSuspended`` too.
    public var allowsRides: Bool { allowRides ?? permission.allowsRides }

    /// Whether the owner has PAUSED this grant.
    ///
    /// ABSENCE IS NEVER SUSPENSION — an absent key means a `pending` row or a
    /// server predating MYR-369, and the contract is explicit that it "MUST be
    /// read as NOT suspended". Note this points the OPPOSITE way from
    /// ``allowsRides``'s fallback, which is exactly why both are written out here
    /// rather than left to a call site to remember.
    ///
    /// SUSPENSION GATES EVERYTHING and is server-enforced by removing the grant
    /// from the viewer's access set, so this flag is only ever read on the
    /// OWNER's own listing — a suspended grant produces no row at all on any
    /// viewer surface.
    public var isSuspended: Bool { suspended ?? false }
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
