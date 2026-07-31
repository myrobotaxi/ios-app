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
    /// MYR-386 — `.idle` until something asks. See ``ShareRosterLoadPhase``: the
    /// `isLoading` / `statusMessage` pair this replaces could not express it, and
    /// the screen read neither anyway.
    private(set) var rosterPhase: ShareRosterLoadPhase = .idle

    /// The owner's fleet, read live from the SAME started fleet the Home map uses
    /// (`OwnerHomeState`), so the send-invite sheet's picker offers the account's
    /// real cars — MYR-228 fix (a). A closure rather than a stored array because
    /// the fleet loads asynchronously and can change under the screen (a car
    /// linked or torn down mid-session).
    var shareableVehicles: [Vehicle] { ownedVehicles() }

    /// §7.5 is code-based end to end — see ``ShareService/sharesByCode``.
    var sharesByCode: Bool { true }

    @ObservationIgnored private let api: any VehicleSharingEndpoint
    /// §7.18's `PUT /api/tesla/vehicles/{id}/ride-share`. A SECOND seam rather
    /// than a widened `VehicleSharingEndpoint`, because the vehicle-level pause
    /// is not part of the §7.5 sharing family at all — MYR-369 only moved WHERE
    /// its switch is drawn. `RestClient` conforms to both, so the live path still
    /// composes exactly one client.
    @ObservationIgnored private let rideShareAPI: any VehicleRideShareEndpoint
    @ObservationIgnored private let ownedVehicles: @MainActor () -> [Vehicle]
    /// MYR-386 — what the fleet behind `ownedVehicles` is DOING, so an empty
    /// vehicle list can be told apart from a vehicle list that has not answered.
    /// See ``ShareFleetState``. A CLOSURE for the same reason `ownedVehicles` is
    /// one: this service does not own the fleet and cannot refresh it, and the
    /// answer changes underneath the screen as the list loads.
    @ObservationIgnored private let fleetState: @MainActor () -> ShareFleetState
    @ObservationIgnored private let now: () -> Date

    /// Screen-row id → the server invite ids it stands for. Rebuilt on every load;
    /// a mutation reads it, so a mutation on a row that predates the newest load
    /// simply finds nothing and re-loads rather than deleting the wrong grant.
    @ObservationIgnored private var inviteIDs: [String: [String]] = [:]

    /// Guards against overlapping loads (tab switches, a mutation's re-read, and
    /// `.task` can all land at once).
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// MYR-369 — the ride-share position the owner has flipped on THIS screen,
    /// keyed by vehicle id, holding the server's ECHO once the write lands.
    ///
    /// It exists because `ownedVehicles` is a CLOSURE into the fleet, which this
    /// service does not own and cannot refresh: §7.18 carries no WebSocket delta,
    /// so nothing would push the new position back into that list before the next
    /// cold read. Without the override the switch would spring back under the
    /// owner's thumb. The override is authoritative over the fleet row for
    /// exactly the same reason `VehicleRideShare.resolvedEnabled` prefers the
    /// committed value over the snapshot (the MYR-316 stale-read defect).
    /// DELIBERATELY OBSERVED (no `@ObservationIgnored`): `vehicleRideShare` is
    /// computed from it, so the OPTIMISTIC flip only reaches the switch if
    /// writing here publishes. It happened to work through the sibling
    /// `rideShareInFlight` changing in the same breath, which is the kind of
    /// accidental dependency that survives until someone removes the spinner.
    private var rideShareOverrides: [String: Bool] = [:]

    /// Vehicle ids whose §7.18 write is in flight, so a second tap cannot race
    /// the first and land the two echoes out of order.
    private var rideShareInFlight: Set<String> = []

    init(
        api: any VehicleSharingEndpoint,
        rideShareAPI: any VehicleRideShareEndpoint,
        ownedVehicles: @escaping @MainActor () -> [Vehicle],
        // MYR-386 — defaulted to `.resolved` so every existing construction site
        // (tests, DEBUG scenes) is unchanged and keeps its old meaning: their
        // vehicle lists are literals, in hand before the service exists, so there
        // is genuinely nothing resolving behind them.
        fleetState: @escaping @MainActor () -> ShareFleetState = { .resolved },
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.rideShareAPI = rideShareAPI
        self.ownedVehicles = ownedVehicles
        self.fleetState = fleetState
        self.now = now
    }

    // MARK: - Vehicle-level ride sharing (§7.18, relocated by MYR-369)

    var vehicleRideShare: [VehicleRideShareRow] {
        ownedVehicles().map { vehicle in
            VehicleRideShareRow(
                id: vehicle.id,
                name: vehicle.name,
                // ABSENT MEANS ENABLED — resolved in the one place that spells
                // the explicit-`false` test, never as `!= true`.
                //
                // This is the owner's STORED preference and nothing else. The
                // in-service derivation sits ON TOP of it inside
                // `VehicleRideShareRow.display` and never replaces it (MYR-358):
                // if it substituted its own value here, the owner's flip would be
                // invisible for the whole service visit and would then reappear,
                // which is the very shape of the bug that rule shipped alongside.
                storedEnabled: VehicleRideShare.isEnabled(
                    rideShareOverrides[vehicle.id] ?? vehicle.rideShareEnabled
                ),
                isInService: vehicle.isInService,
                isBusy: rideShareInFlight.contains(vehicle.id)
            )
        }
    }

    func setVehicleRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws {
        guard !rideShareInFlight.contains(vehicleID) else { return }
        // The value to restore if the write fails — the RESOLVED STORED
        // preference, not a guess at what it might have been.
        //
        // `storedEnabled` and NOT `isEnabled` (MYR-358): the latter is the derived
        // switch POSITION, which reads `false` for the whole of a service visit
        // whatever the owner stored. Rolling back to it would silently persist a
        // pause the owner never asked for the moment a write failed on a car that
        // happened to be in a service bay — writing the derived state back into
        // the preference is precisely what deriving it exists to avoid.
        let previous = vehicleRideShare.first { $0.id == vehicleID }?.storedEnabled
        rideShareOverrides[vehicleID] = enabled           // optimistic
        rideShareInFlight.insert(vehicleID)
        defer { rideShareInFlight.remove(vehicleID) }
        do {
            let response = try await rideShareAPI.setRideShareEnabled(enabled, vehicleID: vehicleID)
            // Adopt the ECHO, not the bool we sent — §7.18 answers with the
            // stored position, and believing our own request is how a client
            // comes to disagree with the server about an availability switch.
            rideShareOverrides[vehicleID] = response.enabled
        } catch {
            // Roll the switch back. Leaving the optimistic position up would
            // manufacture the exact belief §7.18 refuses to allow — an owner
            // walking away certain their car is paused while it still takes
            // requests. Restoring `nil` (rather than `!enabled`) when there was
            // no prior override keeps "absent means enabled" intact.
            // `previous` is already optional and assigning nil REMOVES the key,
            // which is the correct restore when there was no override to begin
            // with — the row falls back to the fleet's value and "absent means
            // enabled" survives intact.
            rideShareOverrides[vehicleID] = previous
            throw error
        }
    }

    // MARK: - Per-viewer capability edits (MYR-369, PATCH /api/invites/{id})

    func setViewerAllowRides(_ allowRides: Bool, viewer: Viewer) async throws {
        try await patchViewer(viewer, optimistic: { $0.with(allowRides: allowRides) }) {
            PatchShareInviteRequest(allowRides: allowRides)
        }
    }

    func setViewerSuspended(_ suspended: Bool, viewer: Viewer) async throws {
        try await patchViewer(viewer, optimistic: { $0.with(suspended: suspended) }) {
            PatchShareInviteRequest(suspended: suspended)
        }
    }

    /// The shared body of both per-viewer edits: move the row NOW, patch every
    /// server row behind it, and restore the exact previous row if anything
    /// refused.
    ///
    /// **ONE SCREEN ROW IS N SERVER ROWS.** A multi-vehicle invite is N grants and
    /// the PATCH applies to ONE of them, so a grouped row has to patch its whole
    /// group — the same fan-out `deleteGroup` does, and for the same reason.
    ///
    /// **THE BODY IS BUILT PER CALL, CARRYING EXACTLY ONE KEY.** The contract's
    /// update is PARTIAL: only properties PRESENT are written and an absent one is
    /// NOT `false`. Sending both flags because we happen to know both would
    /// overwrite a capability the owner did not touch — with whatever this
    /// client last read, which on a stale row is a silent unintended edit.
    private func patchViewer(
        _ viewer: Viewer,
        optimistic: (Viewer) -> Viewer,
        body: () -> PatchShareInviteRequest
    ) async throws {
        let ids = inviteIDs[viewer.id] ?? []
        guard !ids.isEmpty else {
            // The row predates the newest load. Re-read rather than patch a grant
            // we can no longer name.
            await performLoad()
            return
        }
        guard let index = viewers.firstIndex(where: { $0.id == viewer.id }) else { return }
        let previous = viewers[index]
        viewers[index] = optimistic(previous)             // optimistic

        var firstFailure: Error?
        for id in ids {
            do {
                _ = try await api.patchShareInvite(body(), inviteID: id)
            } catch let error as RestError where error.isShareInviteGone {
                // 404 is the same non-oracle answer DELETE gives: gone, another
                // owner's, or a tombstone. The grant this row stood for is not
                // ours to edit, and the re-read below shows the owner the truth.
                continue
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure {
            // ROLL BACK to the exact row we replaced, then re-read. The rollback
            // is what the owner sees immediately; the re-read is what makes it
            // true, since a partial failure across a multi-vehicle group can
            // leave the server holding a mix neither position describes.
            if let current = viewers.firstIndex(where: { $0.id == viewer.id }) {
                viewers[current] = previous
            }
            await performLoad()
            throw firstFailure
        }
        // Re-read rather than adopt the echo: the 200 body is ONE row of a group
        // that may be N, and this screen's standing rule is that the server is
        // authoritative about who has access.
        await performLoad()
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
            // Nothing to ask about — §7.5.2 is per-vehicle and there is no
            // vehicle. But an empty fleet is TWO situations (MYR-386), and this
            // branch used to answer both of them with "nothing is shared":
            //
            //  • the list has not answered yet — the Share tab opened during a
            //    cold boot, which is the client's flash. A fetch IS genuinely
            //    running (the fleet's), and the roster is blocked on it, so the
            //    skeleton is honest and `InvitesScreen` re-asks when it lands.
            //  • the list answered and the account owns no cars — then the empty
            //    hero is the honest render, exactly as before.
            //
            // A fleet that FAILED is neither: "no one has access yet" is a claim
            // about the account, and a list that did not answer cannot support it.
            viewers = []
            pending = []
            inviteIDs = [:]
            switch fleetState() {
            case .resolving: rosterPhase = .loading
            case .resolved: rosterPhase = .loaded
            case .unreachable: rosterPhase = .failed(Self.unreadableMessage)
            }
            return
        }

        rosterPhase = .loading

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
            // MYR-386 — a settled FAILURE, not a lingering "loading". The
            // published lists are deliberately left as they were: rows already in
            // hand outrank this phase in `ShareRosterState.resolve`, so a
            // transient failure on a re-read never blanks a roster the owner is
            // reading. It is only when there is nothing in hand that this reaches
            // the screen, and then it says so instead of claiming an empty list.
            rosterPhase = .failed(Self.unreadableMessage)
            return
        }
        apply(rows: rows, vehicles: vehicles)
        // Set AFTER `apply`, so the one frame in which the phase says "loaded"
        // is never a frame in which the lists are still the previous answer.
        rosterPhase = .loaded
    }

    /// The quiet one-line sentence a failed read shows. `static` so the screen's
    /// failure state and this service's phase are provably the same string.
    static let unreadableMessage = "Can\u{2019}t load sharing right now"

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
            vehicleNames: vehicles.filter { ids.contains($0.id) }.map(\.name),
            // MYR-368 — the server's own signed link, forwarded exactly as it
            // arrived. Optional by contract: a server predating 0.22.0 sends the
            // code alone and the handout falls back to the client-composed link.
            // Deliberately NOT validated here — the shape, the parameter order
            // and the signature are the server's, and anything this client
            // "corrected" would fail verification at the join shell.
            shareUrl: invite.shareUrl
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
        // §7.5.4 RE-SIGNS: a resend mints a new code and a new expiry, so the
        // whole URL changes and the previous link stops redeeming. Taking the
        // link off THIS response rather than off the pending row we resent is
        // what makes that true on this side too.
        return ShareHandout(
            code: code, label: updated.label, vehicleNames: [], shareUrl: updated.shareUrl
        )
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
                // MYR-369 — the FLAGS ARE PART OF THE KEY NOW. A grouped row
                // renders one pair of switches and patches every id behind it, so
                // two grants that disagree about `allowRides` or `suspended` must
                // NOT collapse into one row: the switches would show one grant's
                // state while writing to both, and un-suspending "Mira" would
                // silently restore a car the owner had paused separately.
                //
                // `permission` is derived from `allowRides` and so is already
                // implied by it; both are in the key anyway, because a key that
                // depends on a derivation staying true is a key that breaks
                // silently when the derivation changes.
                let key = "acc:\(row.label)|\(row.permission.rawValue)"
                    + "|\(row.allowsRides)|\(row.isSuspended)|\(row.acceptedAt ?? "")"
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
                    tier: ShareTierMapping.tier(forWire: first.permission.rawValue),
                    // MYR-369 — read through the Kit's two accessors so the pair
                    // of DIFFERENT absence rules is applied in exactly one place:
                    // an absent `allowRides` falls back to the derived permission,
                    // an absent `suspended` is NOT suspension.
                    allowRides: first.allowsRides,
                    suspended: first.isSuspended
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
