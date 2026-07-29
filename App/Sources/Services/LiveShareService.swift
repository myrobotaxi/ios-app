import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - LiveShareService (MYR-184, rest-api.md §7.5)
//
// The owner's sharing screen against the real endpoints. Three things about the
// contract shape this class exists to absorb, none of which the screen should
// know about:
//
//  1. THE LIST IS PER-VEHICLE, THE SCREEN IS PER-OWNER. §7.5.2 answers for ONE
//     vehicle; the Share tab is the owner's whole sharing picture. So this fans
//     out one GET per owned vehicle and merges.
//
//  2. ONE INVITE IS N ROWS. A multi-vehicle invite mints one row per vehicle
//     sharing ONE code (§7.5.1), so a naive render shows the same person three
//     times. Rows are REGROUPED back into the invite the owner actually created —
//     pending rows by their shared `code` (the contract's own words: "the sibling
//     set *is* the invite"), accepted rows by the natural key of one redemption
//     (label + tier + the instant it was accepted).
//
//  3. THE ROW ID IS NOT THE INVITE ID. Because of (2), one screen row can stand
//     for several server rows, so revoking or cancelling has to DELETE every id
//     in the group. Resend does NOT — §7.5.4 re-mints every sibling atomically
//     server-side, so re-sending one member is the whole invite, and re-sending
//     each member in turn would mint N codes and keep only the last.
//
// Failures are surfaced as a quiet `statusMessage`, never a dialog, and the list
// is re-read after every mutation rather than optimistically patched: the server
// is authoritative about who has access, and a stale local array on THIS screen
// is how an owner comes to believe they revoked someone they did not.
@Observable
@MainActor
final class LiveShareService: ShareService {
    private(set) var viewers: [Viewer] = []
    private(set) var pending: [PendingInvite] = []
    private(set) var isLoading = false
    private(set) var statusMessage: String?

    /// The owner's fleet, read live from the SAME started fleet the Home map uses
    /// (`OwnerHomeState`), so the send-invite sheet's picker offers the account's
    /// real cars — MYR-228 fix (a). A closure rather than a stored array because
    /// the fleet loads asynchronously and can change under the screen (a car
    /// linked or torn down mid-session).
    var shareableVehicles: [Vehicle] { ownedVehicles() }

    /// §7.5 is code-based end to end — see ``ShareService/sharesByCode``.
    var sharesByCode: Bool { true }

    @ObservationIgnored private let api: any VehicleSharingEndpoint
    @ObservationIgnored private let ownedVehicles: @MainActor () -> [Vehicle]
    @ObservationIgnored private let now: () -> Date

    /// Screen-row id → the server invite ids it stands for. Rebuilt on every load;
    /// a mutation reads it, so a mutation on a row that predates the newest load
    /// simply finds nothing and re-loads rather than deleting the wrong grant.
    @ObservationIgnored private var inviteIDs: [String: [String]] = [:]

    /// Guards against overlapping loads (tab switches, a mutation's re-read, and
    /// `.task` can all land at once).
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        api: any VehicleSharingEndpoint,
        ownedVehicles: @escaping @MainActor () -> [Vehicle],
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.ownedVehicles = ownedVehicles
        self.now = now
    }

    // MARK: - Load

    func load() async {
        loadTask?.cancel()
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        let vehicles = ownedVehicles()
        guard !vehicles.isEmpty else {
            // Nothing to ask about. Not an error and not "loading" — an account
            // with no linked car simply has nothing shared, and the screen's
            // existing "No one has access yet." is the honest render.
            viewers = []
            pending = []
            inviteIDs = [:]
            statusMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        var rows: [ShareInvite] = []
        var failures = 0
        for vehicle in vehicles {
            if Task.isCancelled { return }
            do {
                rows.append(contentsOf: try await api.shareInvites(vehicleID: vehicle.id))
            } catch {
                // One unreadable vehicle must not blank the whole screen — the
                // other cars' grants are still true. Counted, and reported only
                // if EVERY vehicle failed (below), so a single transient 500
                // does not put a status line under a list that is fine.
                failures += 1
            }
        }
        if Task.isCancelled { return }

        if failures == vehicles.count {
            statusMessage = "Can\u{2019}t load sharing right now"
            return
        }
        statusMessage = nil
        apply(rows: rows, vehicles: vehicles)
    }

    /// Regroup the merged wire rows into screen rows. Pure given its inputs —
    /// `ShareRowGrouping` holds the actual rule so it is unit-testable without a
    /// service, a clock, or a network.
    private func apply(rows: [ShareInvite], vehicles: [Vehicle]) {
        let grouped = ShareRowGrouping.group(rows, now: now())
        viewers = grouped.viewers
        pending = grouped.pending
        inviteIDs = grouped.inviteIDs
    }

    // MARK: - Create (§7.5.1)

    @discardableResult
    func createInvite(label: String, tier: ShareAccessLevel, vehicleIDs: [String]) async throws -> ShareHandout? {
        let vehicles = ownedVehicles()
        // The PATH vehicle authorizes the call and MUST be a member of the set
        // (§7.5.1 — a set omitting it is a 400). Pick the first selected id that
        // the fleet actually knows, in FLEET order, so the path vehicle is
        // deterministic rather than dependent on Set iteration order.
        guard let pathVehicle = vehicles.first(where: { vehicleIDs.contains($0.id) }) else {
            throw ShareServiceError.noVehicleSelected
        }
        let ids = vehicles.map(\.id).filter { vehicleIDs.contains($0) }
        let request = CreateShareInviteRequest(
            label: label,
            permission: SharePermission(rawValue: ShareTierMapping.wireValue(for: tier)),
            // Omit the array entirely for the ordinary single-vehicle case —
            // §7.5.1 says that is exactly equivalent to `[<path vehicleId>]`, and
            // sending the degenerate one-element array would be noise on the wire.
            vehicleIds: ids.count > 1 ? ids : nil
        )
        let invite = try await api.createShareInvite(request, vehicleID: pathVehicle.id)
        await performLoad()
        guard let code = invite.code else {
            // A 201 with no code contradicts §7.5.1 (the row is `pending`, and
            // pending rows carry one). Nothing to hand out, so say so rather than
            // presenting an empty share sheet.
            throw ShareServiceError.missingCode
        }
        return ShareHandout(
            code: code,
            label: invite.label,
            vehicleNames: vehicles.filter { ids.contains($0.id) }.map(\.name)
        )
    }

    // MARK: - Revoke / cancel (§7.5.3)

    func revoke(_ viewer: Viewer) async throws {
        try await deleteGroup(rowID: viewer.id)
    }

    func cancelInvite(_ invite: PendingInvite) async throws {
        try await deleteGroup(rowID: invite.id)
    }

    /// DELETE every server row behind one screen row. A `404` is SUCCESS, not a
    /// failure: §7.5.3 answers 404 for "does not exist" and "belongs to another
    /// owner" alike, and from the owner's side both mean the grant this row stood
    /// for is gone — which is precisely the state they asked for.
    private func deleteGroup(rowID: String) async throws {
        let ids = inviteIDs[rowID] ?? []
        guard !ids.isEmpty else {
            // The row predates the newest load. Re-read rather than guess.
            await performLoad()
            return
        }
        var firstFailure: Error?
        for id in ids {
            do {
                try await api.revokeShareInvite(inviteID: id)
            } catch let error as RestError where error.isShareInviteGone {
                continue
            } catch {
                // Keep going: partially revoking is better than stopping at the
                // first failure and leaving the rest granted, and the re-read
                // below shows the owner exactly what is still shared.
                if firstFailure == nil { firstFailure = error }
            }
        }
        await performLoad()
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Resend (§7.5.4)

    @discardableResult
    func resend(_ invite: PendingInvite) async throws -> ShareHandout? {
        guard let id = inviteIDs[invite.id]?.first else {
            await performLoad()
            throw ShareServiceError.inviteGone
        }
        // ONE call for the whole invite: the server locks every pending row
        // sharing this code and writes the same new code to all of them in one
        // transaction. Looping the siblings here would mint N codes and leave
        // only the last one live.
        let updated = try await api.resendShareInvite(inviteID: id)
        await performLoad()
        guard let code = updated.code else { throw ShareServiceError.missingCode }
        return ShareHandout(code: code, label: updated.label, vehicleNames: [])
    }
}

// MARK: - Errors

/// The refusals the OWNER's share screen can act on. Deliberately tiny: every
/// other failure is a `RestError` the caller folds into the quiet status line.
enum ShareServiceError: Error, Equatable {
    /// The send sheet submitted with nothing selected that the fleet knows about.
    case noVehicleSelected
    /// A 2xx that contradicts §7.5 — a pending invite with no `code`.
    case missingCode
    /// The invite disappeared between the render and the tap (cancelled from
    /// another device, or redeemed).
    case inviteGone
}

// MARK: - Row grouping (pure)

/// Turns the merged §7.5.2 wire rows into the two screen lists. Extracted from
/// the service so the rule — which is the subtle part — is testable as a pure
/// function of (rows, clock).
enum ShareRowGrouping {
    struct Result {
        var viewers: [Viewer] = []
        var pending: [PendingInvite] = []
        var inviteIDs: [String: [String]] = [:]
    }

    static func group(_ rows: [ShareInvite], now: Date) -> Result {
        var result = Result()

        // Pending: keyed by the shared CODE. §7.5.1/§7.5.4 make the code the
        // identity of an invite across its sibling rows, and a resend rewrites it
        // on all of them at once, so two rows with one code are one invite.
        // A pending row with no code contradicts §7.5.2; it falls back to its own
        // id so it still renders (as one row) rather than vanishing.
        var pendingOrder: [String] = []
        var pendingByKey: [String: [ShareInvite]] = [:]
        // Accepted: keyed by the natural key of ONE redemption. The code is gone
        // by then (§7.5.2 drops it on accepted rows), so there is no server-side
        // handle tying the siblings together — label + tier + the accept instant
        // is what one person redeeming one code produces, atomically, and is the
        // closest true key the wire offers.
        var acceptedOrder: [String] = []
        var acceptedByKey: [String: [ShareInvite]] = [:]

        for row in rows {
            switch row.status {
            case .pending:
                let key = "code:" + (row.code ?? row.inviteId)
                if pendingByKey[key] == nil { pendingOrder.append(key) }
                pendingByKey[key, default: []].append(row)
            case .accepted:
                let key = "acc:\(row.label)|\(row.permission.rawValue)|\(row.acceptedAt ?? "")"
                if acceptedByKey[key] == nil { acceptedOrder.append(key) }
                acceptedByKey[key, default: []].append(row)
            case .unrecognized:
                // A status appended by a newer contracts version. Skipping is the
                // only safe render: the two sections mean specific things
                // ("has access" / "hasn't joined yet") and guessing which one an
                // unknown status belongs to could tell the owner someone has
                // access when they do not.
                continue
            }
        }

        for key in acceptedOrder {
            guard let group = acceptedByKey[key], let first = group.first else { continue }
            result.viewers.append(
                Viewer(
                    id: key,
                    name: first.label,
                    // Codes, not emails — the wire carries no address (§7.5).
                    email: nil,
                    // No presence signal exists in v1: the dot stays off rather
                    // than claiming someone is watching.
                    online: false,
                    perm: ShareTierMapping.permLabel(forWire: first.permission.rawValue),
                    tier: ShareTierMapping.tier(forWire: first.permission.rawValue)
                )
            )
            result.inviteIDs[key] = group.map(\.inviteId)
        }

        for key in pendingOrder {
            guard let group = pendingByKey[key], let first = group.first else { continue }
            result.pending.append(
                PendingInvite(
                    id: key,
                    name: first.label,
                    email: nil,
                    code: first.code,
                    sent: sentLabel(for: first, now: now),
                    tier: ShareTierMapping.tier(forWire: first.permission.rawValue)
                )
            )
            result.inviteIDs[key] = group.map(\.inviteId)
        }

        return result
    }

    /// The pending row's relative caption. Two jobs, in priority order:
    ///
    ///  1. EXPIRY WINS. §7.5.2: "Expiry is not a status" — an expired invite stays
    ///     `pending` with an `expiresAt` in the past and simply stops redeeming.
    ///     A client that wants an expired affordance derives it, and one that does
    ///     not leaves the owner staring at a live-looking code that grants nothing.
    ///  2. Otherwise the prototype's "sent {ago}" shape, off `createdAt` — which a
    ///     resend deliberately does NOT reset, so the line keeps referring to the
    ///     original send.
    static func sentLabel(for invite: ShareInvite, now: Date) -> String {
        if let raw = invite.expiresAt,
           let expiry = parse(raw),
           expiry <= now {
            return "expired"
        }
        guard let created = parse(invite.createdAt) else { return "sent" }
        return "sent " + relative(from: created, to: now)
    }

    /// "just now" / "5m ago" / "3h ago" / "2d ago" — the prototype's own
    /// vocabulary (`ShareFixtures.pending` ships "2d ago"), so a live row and a
    /// fixture row read identically.
    static func relative(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// Reuses the fleet's ISO-8601 parser so timestamps decode identically
    /// everywhere in the app (fractional seconds tolerated).
    private static func parse(_ value: String) -> Date? {
        VehicleContractMapping.parseTimestamp(value)
    }
}
