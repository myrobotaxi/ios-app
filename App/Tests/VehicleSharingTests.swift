import XCTest
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-184 vehicle sharing — app-level seam tests
//
// Covers the four places the app can get sharing wrong in ways the Kit's REST
// tests cannot see:
//
//   1. TIER MAPPING — design tier ↔ wire value, both directions. A mapping that
//      is right one way and wrong the other is how an owner grants "Can request
//      rides" and the recipient gets "Live location".
//   2. ROW GROUPING — one invite is N server rows sharing one code (§7.5.1), so
//      the owner's screen must show ONE row per invite and a revoke must delete
//      every id behind it.
//   3. REDEEM FLOWS — the §7.5.5 catalog folded onto the rider's four answers,
//      and which of them clear the entry field.
//   4. THE LIVE-PATH GATES — viewer-row filtering, the never-fail-open absent
//      tier, and the cumulative capability predicates the UI offers on.
//
// Scripted endpoints per the existing convention (`ScriptedShareEndpoint` below,
// same shape as the Kit's `RecordingHTTP`): no network, deterministic bodies.

// MARK: - Scripted endpoint

/// A `VehicleSharingEndpoint` that replays queued answers and records calls, so
/// a test can assert exactly which server rows a mutation touched.
final class ScriptedShareEndpoint: VehicleSharingEndpoint, @unchecked Sendable {
    enum Call: Equatable {
        case list(vehicleID: String)
        case create(vehicleID: String, label: String, permission: String, vehicleIDs: [String]?)
        case revoke(inviteID: String)
        case resend(inviteID: String)
        case redeem(code: String)
        /// MYR-369 — records the BODY's two optionals separately, so a test can
        /// assert that a partial update carried exactly ONE key. Recording a
        /// merged struct would make "sent allowRides only" and "sent both, one of
        /// them nil-equivalent" indistinguishable, which is the whole distinction
        /// the contract's partial-update rule turns on.
        case patch(inviteID: String, allowRides: Bool?, suspended: Bool?)
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []

    /// Per-vehicle list answers, consulted on every `shareInvites` call so a
    /// re-read after a mutation can return a DIFFERENT list.
    var listByVehicle: [String: [ShareInvite]] = [:]
    /// Per-vehicle list FAILURES, so a partial fan-out failure is expressible.
    var listError: [String: Error] = [:]
    var createResult: Result<ShareInvite, Error>?
    var resendResult: Result<ShareInvite, Error>?
    var revokeError: [String: Error] = [:]
    var redeemResult: Result<RedeemShareInviteResponse, Error>?

    private func record(_ call: Call) {
        lock.lock(); calls.append(call); lock.unlock()
    }

    func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
        record(.create(
            vehicleID: vehicleID,
            label: body.label,
            permission: body.permission.rawValue,
            vehicleIDs: body.vehicleIds
        ))
        switch createResult {
        case .success(let invite): return invite
        case .failure(let error): throw error
        case nil: throw ShareServiceError.missingCode
        }
    }

    func shareInvites(vehicleID: String) async throws -> [ShareInvite] {
        record(.list(vehicleID: vehicleID))
        if let error = listError[vehicleID] { throw error }
        return listByVehicle[vehicleID] ?? []
    }

    func revokeShareInvite(inviteID: String) async throws {
        record(.revoke(inviteID: inviteID))
        if let error = revokeError[inviteID] { throw error }
    }

    func resendShareInvite(inviteID: String) async throws -> ShareInvite {
        record(.resend(inviteID: inviteID))
        switch resendResult {
        case .success(let invite): return invite
        case .failure(let error): throw error
        case nil: throw ShareServiceError.inviteGone
        }
    }

    func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse {
        record(.redeem(code: code))
        switch redeemResult {
        case .success(let response): return response
        case .failure(let error): throw error
        case nil: throw RestError.http(status: 404, code: nil, message: nil, subCode: nil)
        }
    }

    /// MYR-369 — per-invite PATCH failures, so a rollback is expressible.
    var patchError: [String: Error] = [:]
    /// The row a successful PATCH answers with. Defaulted to `nil`, in which case
    /// the stub synthesizes an accepted row from the body — enough for the
    /// service, which re-reads the LIST rather than adopting this echo.
    var patchResult: ShareInvite?

    func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite {
        record(.patch(inviteID: inviteID, allowRides: body.allowRides, suspended: body.suspended))
        if let error = patchError[inviteID] { throw error }
        if let patchResult { return patchResult }
        return ShareInvite(
            inviteId: inviteID,
            vehicleId: "v1",
            label: "patched",
            // DERIVED, exactly as the server derives it — never a stored tier.
            permission: SharePermission(rawValue: (body.allowRides ?? false) ? "rides" : "live"),
            allowRides: body.allowRides ?? false,
            suspended: body.suspended ?? false,
            status: .accepted,
            createdAt: "2026-07-27T15:04:05Z",
            acceptedAt: "2026-07-28T15:04:05Z"
        )
    }
}

/// A `VehicleRideShareEndpoint` for the relocated §7.18 switch (MYR-369): echoes
/// the submission, or fails on demand to drive the rollback.
final class ShareTabRideShareEndpoint: VehicleRideShareEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var writes: [(vehicleID: String, enabled: Bool)] = []
    var failure: Error?
    /// When set, the echo DISAGREES with the submission — the case that proves
    /// the client adopts the server's answer rather than the bool it sent.
    var echoOverride: Bool?

    func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
        lock.lock(); writes.append((vehicleID, enabled)); lock.unlock()
        if let failure { throw failure }
        return VehicleRideShareResponse(vehicleId: vehicleID, enabled: echoOverride ?? enabled)
    }
}

// MARK: - Builders

private func invite(
    id: String,
    vehicle: String,
    label: String,
    permission: String,
    status: ShareInvite.Status,
    code: String? = nil,
    shareUrl: String? = nil,
    createdAt: String = "2026-07-27T15:04:05Z",
    expiresAt: String? = nil,
    acceptedAt: String? = nil,
    // MYR-369 — BOTH default to ABSENT, which is the pre-0.23.0 server AND the
    // shape of every pending row. Existing tests therefore keep exercising the
    // two compat FALLBACKS (`allowRides` falls back to the permission,
    // `suspended` reads as false), and the flag tests opt in explicitly.
    allowRides: Bool? = nil,
    suspended: Bool? = nil
) -> ShareInvite {
    ShareInvite(
        inviteId: id,
        vehicleId: vehicle,
        label: label,
        permission: SharePermission(rawValue: permission),
        allowRides: allowRides,
        suspended: suspended,
        status: status,
        code: code,
        // MYR-368 — defaulted to ABSENT, which is a pre-0.22.0 server. Every
        // existing test therefore keeps exercising the client-composed fallback,
        // and the signed-link tests opt in explicitly.
        shareUrl: shareUrl,
        createdAt: createdAt,
        expiresAt: expiresAt,
        acceptedAt: acceptedAt
    )
}

// MARK: - MYR-368 signed-link vectors

/// A COMPLETE server-minted link in the contract's exact shape — the vector this
/// issue was specified against.
///
/// Kept as one literal because that is the unit the client handles: the Ed25519
/// signature in `k` covers `join:{code}:{exp}:{from}:{to}`, so the URL has no
/// separable parts as far as this app is concerned.
let signedShareURL =
    "https://myrobotaxi.app/join/RBO246?k=1.1785942245.fPkcqmLr2p_HezqZtbP6J1NC-jQA0nAOp7hiFqTKZHo9L2YGVkNDx162VsdromPEMSZaMvMhxRCBS_xfaRw0BQ&from=Alex&to=Mira"

/// The same shape after a §7.5.4 resend: a new code, a new expiry, a new
/// signature — a whole new link.
let resignedShareURL =
    "https://myrobotaxi.app/join/ZKQ913?k=1.1786006800.nTwfey5ahMYPsdJzkOSlGIxz8GIauU3lNwyPHqayXUPPgHFKLWuV6DH6DH0kuOVgk68cLXDkuKUfbDnQLotHoQ&from=Alex&to=Mira"

private func summary(
    id: String,
    name: String,
    role: VehicleSummary.Role,
    permission: String?
) -> VehicleSummary {
    VehicleSummary(
        vehicleId: id,
        name: name,
        model: "Model 3",
        year: 2024,
        color: "Pearl White",
        vinLast4: "0001",
        status: .parked,
        chargeLevel: 72,
        estimatedRange: 210,
        lastUpdated: "2026-07-29T15:04:05Z",
        role: role,
        hasActiveRide: false,
        licensePlate: "8ABC123",
        serviceEstimatedEndAt: nil,
        sharePermission: permission.map { SharePermission(rawValue: $0) }
    )
}

// MARK: - Tier mapping

final class ShareTierMappingTests: XCTestCase {

    /// Both directions round-trip for every design tier. The contract's own doc
    /// comment names the pairing (`live` → "Live location", `live_history` →
    /// "Live + history", `rides` → "Can request rides").
    func testEveryDesignTierRoundTripsThroughTheWireValue() {
        for tier in ShareAccessLevel.allCases {
            let wire = ShareTierMapping.wireValue(for: tier)
            XCTAssertEqual(ShareTierMapping.tier(forWire: wire), tier, "round trip for \(tier)")
        }
    }

    func testWireValuesMatchTheContractEnumExactly() {
        XCTAssertEqual(ShareTierMapping.wireValue(for: .live), "live")
        XCTAssertEqual(ShareTierMapping.wireValue(for: .rides), "rides")
    }

    /// MYR-369 — `live_history` IS RETIRED and no preset may produce it. The
    /// wire side keeps DECODING it (below); what must be unreachable is SENDING
    /// it, since the server neither emits nor honours the tier any more.
    func testNoPresetCanSendTheRetiredHistoryTier() {
        let sendable = ShareAccessLevel.allCases.map(ShareTierMapping.wireValue(for:))
        XCTAssertFalse(sendable.contains("live_history"))
        XCTAssertEqual(sendable, ["live", "rides"])
    }

    /// The DECODE-COMPAT half, and the one MYR-369 is most likely to lose by
    /// accident. `live_history` is never emitted, but the enum member survives
    /// for wire compatibility and a row somehow carrying it must still render
    /// honestly — folded to `.live`, which is what the contract says such a
    /// legacy grant now derives, rather than to `nil`/"Shared access".
    func testTheRetiredHistoryTierStillDecodesAndFoldsToLive() {
        XCTAssertEqual(ShareTierMapping.tier(forWire: "live_history"), .live)
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "live_history"), "Location")
    }

    /// The rendered label is the DESIGN's own string for each preset, so an owner
    /// who picked "Location + rides" in the sheet sees it on the row.
    func testPermLabelsAreTheDesignsOwnTierLabels() {
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "live"), "Location")
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "rides"), "Location + rides")
    }

    /// A tier this build has never heard of gets a NEUTRAL label and a nil tier —
    /// never a guessed one. Guessing `live` would mislabel the row downward;
    /// guessing `rides` would offer affordances we cannot reason about.
    func testAnUnknownWireTierIsNeitherGuessedUpNorDown() {
        XCTAssertNil(ShareTierMapping.tier(forWire: "full_control"))
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "full_control"), "Shared access")
    }

    /// The fixture rows carry only the rendered string; recovering the tier from
    /// it keeps a simulated row reporting a tier without changing any pixel.
    func testFixturePermLabelsRecoverTheirTier() {
        XCTAssertEqual(ShareAccessLevel.fromPermLabel("Location"), .live)
        XCTAssertEqual(ShareAccessLevel.fromPermLabel("Location + rides"), .rides)
        XCTAssertNil(ShareAccessLevel.fromPermLabel("Shared access"))
        // The retired label is no longer any preset's.
        XCTAssertNil(ShareAccessLevel.fromPermLabel("Live + history"))
    }

    /// MYR-369 — the preset→capability mapping, which is the ONLY thing a preset
    /// still does: it decides `allowRides` at redemption and is inert afterwards.
    func testPresetsMapToTheRideCapabilityTheServerWillGrant() {
        XCTAssertFalse(ShareAccessLevel.live.allowsRides)
        XCTAssertTrue(ShareAccessLevel.rides.allowsRides)
    }

    /// The composer's summary card is checked PER CAPABILITY now, not as a
    /// cumulative prefix. Both presets grant location; only `rides` grants rides.
    func testTheSummaryCardChecksEachCapabilityIndependently() {
        let caps = ShareFixtures.capabilities
        XCTAssertEqual(caps.map(\.key), ["live", "rides"], "the history row is retired")
        XCTAssertEqual(caps.map { ShareAccessLevel.live.grants($0) }, [true, false])
        XCTAssertEqual(caps.map { ShareAccessLevel.rides.grants($0) }, [true, true])
    }
}

// MARK: - Row grouping

final class ShareRowGroupingTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-07-29T15:04:05Z")!

    /// §7.5.1 — a multi-vehicle invite is N rows sharing ONE code. The owner
    /// created ONE invite and must see ONE row; rendering three "Mira Chen"s
    /// would misrepresent what they did.
    func testOnePendingCodeAcrossThreeVehiclesCollapsesToOneRow() {
        let rows = (1...3).map {
            invite(
                id: "inv\($0)", vehicle: "veh\($0)", label: "Mira Chen",
                permission: "live_history", status: .pending, code: "RBO246",
                expiresAt: "2026-08-05T15:04:05Z"
            )
        }
        let result = ShareRowGrouping.group(rows, now: now)

        XCTAssertEqual(result.pending.count, 1)
        let row = try! XCTUnwrap(result.pending.first)
        XCTAssertEqual(row.name, "Mira Chen")
        XCTAssertEqual(row.code, "RBO246")
        XCTAssertEqual(row.tier, .live, "live_history folds to live (MYR-369)")
        // All three server ids are behind the one row, so a cancel removes the
        // whole grant rather than leaving two vehicles shared.
        XCTAssertEqual(result.inviteIDs[row.id]?.sorted(), ["inv1", "inv2", "inv3"])
    }

    /// Accepted rows have NO code (§7.5.2 drops it), so the sibling set is keyed
    /// by the natural key of one redemption: label + tier + the accept instant.
    func testAcceptedSiblingsGroupOnLabelTierAndAcceptInstant() {
        let rows = (1...2).map {
            invite(
                id: "acc\($0)", vehicle: "veh\($0)", label: "Roommate",
                permission: "live", status: .accepted,
                acceptedAt: "2026-07-01T11:23:00Z"
            )
        }
        let result = ShareRowGrouping.group(rows, now: now)

        XCTAssertEqual(result.viewers.count, 1)
        let viewer = try! XCTUnwrap(result.viewers.first)
        XCTAssertEqual(viewer.perm, "Location")
        XCTAssertEqual(viewer.tier, .live)
        XCTAssertEqual(result.inviteIDs[viewer.id]?.sorted(), ["acc1", "acc2"])
    }

    /// Two DIFFERENT people who happen to be on the same tier must not merge.
    func testDistinctLabelsStayDistinctRows() {
        let rows = [
            invite(id: "a", vehicle: "v", label: "Mira", permission: "live", status: .accepted, acceptedAt: "2026-07-01T11:23:00Z"),
            invite(id: "b", vehicle: "v", label: "Jonas", permission: "live", status: .accepted, acceptedAt: "2026-07-01T11:23:00Z"),
        ]
        XCTAssertEqual(ShareRowGrouping.group(rows, now: now).viewers.count, 2)
    }

    /// v1 has NO presence signal — the wire carries no `isOnline`. The dot stays
    /// OFF rather than claiming someone is watching.
    func testLiveViewerRowsNeverClaimPresenceAndNeverCarryAnEmail() {
        let rows = [invite(id: "a", vehicle: "v", label: "Mira", permission: "rides", status: .accepted, acceptedAt: "2026-07-01T11:23:00Z")]
        let viewer = try! XCTUnwrap(ShareRowGrouping.group(rows, now: now).viewers.first)
        XCTAssertFalse(viewer.online)
        XCTAssertNil(viewer.email, "codes, not emails — the wire carries no address")
    }

    /// §7.5.2 — "Expiry is not a status." An expired invite stays `pending` with
    /// `expiresAt` in the past and simply stops redeeming; a client that does not
    /// derive the affordance leaves the owner staring at a live-looking code that
    /// grants nothing.
    func testAPastExpiryReadsAsExpiredRatherThanSent() {
        let rows = [invite(
            id: "a", vehicle: "v", label: "Diego", permission: "live", status: .pending,
            code: "OLD123", createdAt: "2026-07-01T15:04:05Z", expiresAt: "2026-07-08T15:04:05Z"
        )]
        XCTAssertEqual(ShareRowGrouping.group(rows, now: now).pending.first?.sent, "expired")
    }

    /// An unexpired row keeps the prototype's "sent {ago}" vocabulary, off
    /// `createdAt` — which a resend deliberately does NOT reset.
    func testAnUnexpiredRowReadsSentAgoFromCreatedAt() {
        let rows = [invite(
            id: "a", vehicle: "v", label: "Diego", permission: "live", status: .pending,
            code: "NEW123", createdAt: "2026-07-27T15:04:05Z", expiresAt: "2026-08-05T15:04:05Z"
        )]
        XCTAssertEqual(ShareRowGrouping.group(rows, now: now).pending.first?.sent, "sent 2d ago")
    }

    /// The pending caption names the CODE — the only handle either party has on a
    /// code-based invite — where a fixture row names its email.
    func testCaptionLeadNamesTheCodeOnLiveAndTheEmailInSim() {
        let live = PendingInvite(id: "x", name: "Mira", email: nil, code: "RBO246", sent: "sent 2d ago")
        XCTAssertEqual(live.captionLead, "Code RBO246")
        let sim = PendingInvite(name: "Diego Vega", email: "d.vega@studio.io", sent: "2d ago")
        XCTAssertEqual(sim.captionLead, "d.vega@studio.io")
    }

    /// A status appended by a newer contracts version is SKIPPED, not guessed
    /// into a section: putting an unknown status under "Viewers" would tell the
    /// owner someone has access when they might not.
    func testAnUnrecognizedStatusIsNotFiledUnderEitherSection() {
        let rows = [invite(id: "a", vehicle: "v", label: "Mira", permission: "live", status: .unrecognized("suspended"))]
        let result = ShareRowGrouping.group(rows, now: now)
        XCTAssertTrue(result.viewers.isEmpty)
        XCTAssertTrue(result.pending.isEmpty)
    }
}

// MARK: - LiveShareService

@MainActor
final class LiveShareServiceTests: XCTestCase {

    private func makeService(
        _ endpoint: ScriptedShareEndpoint,
        vehicles: [Vehicle] = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]],
        rideShare: ShareTabRideShareEndpoint = ShareTabRideShareEndpoint()
    ) -> LiveShareService {
        LiveShareService(
            api: endpoint,
            rideShareAPI: rideShare,
            ownedVehicles: { vehicles },
            now: { ISO8601DateFormatter().date(from: "2026-07-29T15:04:05Z")! }
        )
    }

    /// §7.5.2 answers for ONE vehicle; the Share tab is the owner's whole
    /// picture. The service fans out and merges.
    func testLoadFansOutOneListPerOwnedVehicle() async {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        endpoint.listByVehicle[vehicles[0].id] = [
            invite(id: "a", vehicle: vehicles[0].id, label: "Mira", permission: "rides", status: .accepted, acceptedAt: "2026-07-01T11:23:00Z")
        ]
        endpoint.listByVehicle[vehicles[1].id] = [
            invite(id: "b", vehicle: vehicles[1].id, label: "Diego", permission: "live", status: .pending, code: "ABC123", expiresAt: "2026-08-05T15:04:05Z")
        ]

        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()

        XCTAssertEqual(service.viewers.map(\.name), ["Mira"])
        XCTAssertEqual(service.pending.map(\.name), ["Diego"])
        XCTAssertEqual(
            endpoint.calls.filter { if case .list = $0 { return true } else { return false } }.count,
            2
        )
    }

    /// An account with no linked car has nothing shared. That is the screen's
    /// existing honest empty state, NOT a failure and NOT a loading spinner.
    func testAnEmptyFleetLoadsToEmptyListsWithNoStatusLineAndNoRequests() async {
        let endpoint = ScriptedShareEndpoint()
        let service = makeService(endpoint, vehicles: [])
        await service.load()

        XCTAssertTrue(service.viewers.isEmpty)
        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(endpoint.calls.isEmpty, "nothing to ask about")
    }

    /// One unreadable vehicle must not blank the screen — the other cars' grants
    /// are still true, so the rows that DID load stay and no status line appears.
    /// The quiet line is reserved for the case where EVERY vehicle failed.
    func testOneFailedVehicleKeepsTheOtherRowsAndStaysSilent() async {
        struct Boom: Error {}
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        endpoint.listByVehicle[vehicles[0].id] = [
            invite(id: "a", vehicle: vehicles[0].id, label: "Mira", permission: "rides", status: .accepted, acceptedAt: "2026-07-01T11:23:00Z")
        ]
        endpoint.listError[vehicles[1].id] = Boom()

        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()

        XCTAssertEqual(service.viewers.count, 1)
        XCTAssertNil(service.statusMessage, "a partial failure must not put a status line under a list that is fine")
    }

    /// EVERY vehicle failing is the only case that earns the quiet status line —
    /// and it must not blank the screen into a false "no one has access yet".
    func testAllVehiclesFailingSurfacesTheQuietStatusLine() async {
        struct Boom: Error {}
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0]]
        endpoint.listError[vehicles[0].id] = Boom()

        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()

        XCTAssertNotNil(service.statusMessage)
        XCTAssertFalse(service.isLoading)
    }

    /// §7.5.1 — the PATH vehicle authorizes the call and MUST be in the set. The
    /// service picks it deterministically in FLEET order rather than letting
    /// `Set` iteration order decide, and omits the array for a single vehicle.
    func testCreateChoosesThePathVehicleInFleetOrderAndOmitsTheDegenerateArray() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        endpoint.createResult = .success(invite(
            id: "new", vehicle: vehicles[0].id, label: "Mira", permission: "rides",
            status: .pending, code: "RBO246", expiresAt: "2026-08-05T15:04:05Z"
        ))

        let service = makeService(endpoint, vehicles: vehicles)
        let handout = try await service.createInvite(
            label: "Mira", tier: .rides, vehicleIDs: [vehicles[0].id]
        )

        XCTAssertEqual(handout?.code, "RBO246")
        guard case .create(let path, let label, let permission, let ids)? = endpoint.calls.first else {
            return XCTFail("expected a create")
        }
        XCTAssertEqual(path, vehicles[0].id)
        XCTAssertEqual(label, "Mira")
        XCTAssertEqual(permission, "rides")
        XCTAssertNil(ids, "single-vehicle create omits vehicleIds")
    }

    func testMultiVehicleCreateSendsEverySelectedIdInFleetOrder() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        endpoint.createResult = .success(invite(
            id: "new", vehicle: vehicles[0].id, label: "Mira", permission: "live",
            status: .pending, code: "RBO246", expiresAt: "2026-08-05T15:04:05Z"
        ))

        let service = makeService(endpoint, vehicles: vehicles)
        // Deliberately reversed input — the service must still send fleet order
        // and pick the fleet-first member as the path vehicle.
        _ = try await service.createInvite(
            label: "Mira", tier: .live, vehicleIDs: [vehicles[1].id, vehicles[0].id]
        )

        guard case .create(let path, _, _, let ids)? = endpoint.calls.first else {
            return XCTFail("expected a create")
        }
        XCTAssertEqual(path, vehicles[0].id)
        XCTAssertEqual(ids, [vehicles[0].id, vehicles[1].id])
        XCTAssertTrue(ids?.contains(path) == true, "§7.5.1: the set MUST include the path vehicle")
    }

    /// The share sheet is the whole point of a create — a 201 without a code
    /// contradicts §7.5.1 and must surface rather than present an empty sheet.
    func testACreateWithNoCodeIsAnError() async {
        let endpoint = ScriptedShareEndpoint()
        endpoint.createResult = .success(invite(
            id: "new", vehicle: VehicleFixtures.vehicles[0].id, label: "Mira",
            permission: "live", status: .pending, code: nil
        ))
        let service = makeService(endpoint)
        do {
            _ = try await service.createInvite(label: "Mira", tier: .live, vehicleIDs: [VehicleFixtures.vehicles[0].id])
            XCTFail("expected an error")
        } catch let error as ShareServiceError {
            XCTAssertEqual(error, .missingCode)
        } catch {
            XCTFail("expected ShareServiceError, got \(error)")
        }
    }

    /// Revoking a MULTI-VEHICLE grant must DELETE every server row behind the
    /// screen row — otherwise the person keeps access to the other cars.
    func testRevokingAGroupedRowDeletesEveryInviteIdBehindIt() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        for (index, vehicle) in vehicles.enumerated() {
            endpoint.listByVehicle[vehicle.id] = [invite(
                id: "acc\(index)", vehicle: vehicle.id, label: "Mira",
                permission: "rides", status: .accepted, acceptedAt: "2026-07-01T11:23:00Z"
            )]
        }
        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()
        let viewer = try XCTUnwrap(service.viewers.first)

        try await service.revoke(viewer)

        let revoked = endpoint.calls.compactMap { call -> String? in
            if case .revoke(let id) = call { return id }
            return nil
        }
        XCTAssertEqual(revoked.sorted(), ["acc0", "acc1"])
    }

    /// §7.5.3 is idempotent for the caller's own rows and answers 404 for a row
    /// that is already gone. Both mean "this grant no longer exists", which is
    /// exactly what the owner asked for — so a 404 is SUCCESS, not a failure.
    func testARevoke404IsTreatedAsSuccess() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicle = VehicleFixtures.vehicles[0]
        endpoint.listByVehicle[vehicle.id] = [invite(
            id: "acc0", vehicle: vehicle.id, label: "Mira", permission: "rides",
            status: .accepted, acceptedAt: "2026-07-01T11:23:00Z"
        )]
        endpoint.revokeError["acc0"] = RestError.http(status: 404, code: nil, message: nil, subCode: nil)

        let service = makeService(endpoint, vehicles: [vehicle])
        await service.load()
        let viewer = try XCTUnwrap(service.viewers.first)

        // Must NOT throw.
        try await service.revoke(viewer)
    }

    /// §7.5.4 re-mints EVERY sibling atomically server-side, so exactly ONE call
    /// is correct. Looping the siblings would mint N codes and keep only the last
    /// — splitting the invite instead of refreshing it.
    func testResendCallsTheServerOnceForTheWholeGroupAndReturnsTheNewCode() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        for (index, vehicle) in vehicles.enumerated() {
            endpoint.listByVehicle[vehicle.id] = [invite(
                id: "pen\(index)", vehicle: vehicle.id, label: "Diego", permission: "live",
                status: .pending, code: "OLD123", expiresAt: "2026-08-05T15:04:05Z"
            )]
        }
        endpoint.resendResult = .success(invite(
            id: "pen0", vehicle: vehicles[0].id, label: "Diego", permission: "live",
            status: .pending, code: "ZKQ913", expiresAt: "2026-08-06T09:00:00Z"
        ))

        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()
        let pending = try XCTUnwrap(service.pending.first)
        XCTAssertEqual(service.pending.count, 1, "two rows, one code, one screen row")

        let handout = try await service.resend(pending)

        XCTAssertEqual(handout?.code, "ZKQ913")
        let resends = endpoint.calls.filter { if case .resend = $0 { return true } else { return false } }
        XCTAssertEqual(resends.count, 1, "§7.5.4 re-mints the siblings server-side")
    }

    /// MYR-340/MYR-359 — the handout delegates to the ONE builder, so a create
    /// and a resend cannot hand out differently-shaped payloads.
    func testHandoutShareURLIsTheComposedInviteLink() {
        let handout = ShareHandout(code: "RBO246", label: "Mira", vehicleNames: ["Lunar"])
        XCTAssertEqual(
            handout.shareURL(ownerFirstName: "Thomas"),
            ShareInviteMessage.shareURL(code: "RBO246", ownerFirstName: "Thomas")
        )
        XCTAssertEqual(
            handout.shareURL(ownerFirstName: nil),
            ShareInviteMessage.shareURL(code: "RBO246", ownerFirstName: nil)
        )
    }

    // MARK: MYR-368 — the server's signed link reaches the handout

    /// §7.5.1's `shareUrl` travels from the create response to the share sheet
    /// UNCHANGED. The service does not validate it, rewrite it or re-order its
    /// query, because every one of those edits would break the signature it is
    /// carrying.
    func testCreateCarriesTheServersSignedLinkOntoTheHandout() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0]]
        endpoint.createResult = .success(invite(
            id: "pen0", vehicle: vehicles[0].id, label: "Mira Chen", permission: "live_history",
            status: .pending, code: "RBO246", shareUrl: signedShareURL,
            expiresAt: "2026-08-05T15:04:05Z"
        ))

        let service = makeService(endpoint, vehicles: vehicles)
        let handout = try await service.createInvite(
            label: "Mira Chen", tier: .rides, vehicleIDs: [vehicles[0].id]
        )

        XCTAssertEqual(handout?.shareUrl, signedShareURL)
        XCTAssertEqual(
            handout?.shareURL(ownerFirstName: "Thomas").absoluteString, signedShareURL,
            "the owner's own name does not get to overrule a name that is inside a signature"
        )
    }

    /// A resend RE-SIGNS, so the handout takes the link off THAT response — not
    /// off the pending row it resent, which is now dead in both its code and its
    /// link.
    func testResendCarriesTheReSignedLinkAndNotThePreviousOne() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0]]
        endpoint.listByVehicle[vehicles[0].id] = [invite(
            id: "pen0", vehicle: vehicles[0].id, label: "Mira Chen", permission: "live_history",
            status: .pending, code: "RBO246", shareUrl: signedShareURL,
            expiresAt: "2026-08-05T15:04:05Z"
        )]
        endpoint.resendResult = .success(invite(
            id: "pen0", vehicle: vehicles[0].id, label: "Mira Chen", permission: "live_history",
            status: .pending, code: "ZKQ913", shareUrl: resignedShareURL,
            expiresAt: "2026-08-06T09:00:00Z"
        ))

        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()
        let pending = try XCTUnwrap(service.pending.first)
        let handout = try await service.resend(pending)

        XCTAssertEqual(handout?.code, "ZKQ913")
        XCTAssertEqual(handout?.shareURL(ownerFirstName: "Thomas").absoluteString, resignedShareURL)
        XCTAssertNotEqual(handout?.shareUrl, signedShareURL, "the previous link stops redeeming")
    }

    /// THE GRACEFUL TRANSITION. A server that predates 0.22.0 sends `code` with no
    /// `shareUrl` — the state every deployment was in the day before this issue —
    /// and the handout falls back to MYR-359's client-composed link, byte for
    /// byte. Nothing about the owner's experience changes on that server.
    func testAServerWithoutTheFieldFallsBackToTheClientComposedLink() async throws {
        let endpoint = ScriptedShareEndpoint()
        let vehicles = [VehicleFixtures.vehicles[0]]
        endpoint.createResult = .success(invite(
            id: "pen0", vehicle: vehicles[0].id, label: "Mira Chen", permission: "live_history",
            status: .pending, code: "RBO246", expiresAt: "2026-08-05T15:04:05Z"
        ))

        let service = makeService(endpoint, vehicles: vehicles)
        let handout = try await service.createInvite(
            label: "Mira Chen", tier: .rides, vehicleIDs: [vehicles[0].id]
        )

        XCTAssertNil(handout?.shareUrl)
        XCTAssertEqual(
            handout?.shareURL(ownerFirstName: "Thomas").absoluteString,
            "https://myrobotaxi.app/join/RBO246?from=Thomas"
        )
        XCTAssertEqual(
            handout?.shareURL(ownerFirstName: nil).absoluteString,
            "https://myrobotaxi.app/join/RBO246"
        )
    }
}

// MARK: - Share payload (MYR-340 → MYR-346 → MYR-359)

/// TestFlight, Jul 30 (client): the branded invite card never shows in the
/// thread.
///
/// MYR-340 turned the handout into a mini-onboarding and MYR-346 put the invite
/// link at the head of it, on the reading that platforms preview the FIRST link
/// in a body. iMessage's actual rule is narrower — a message becomes a rich link
/// only when it is NOTHING BUT a link — so the steps, the bare code line and the
/// expiry sentence were what suppressed the card the link was added to produce.
///
/// These pin the new contract, which is small enough to state in one sentence:
/// **the payload is the URL and nothing else**, carrying the sender's name only
/// when there is a real one to carry.
final class ShareInviteMessageTests: XCTestCase {

    private let code = "RBO246"

    // MARK: The payload is a link, not a message

    /// The whole thing. Written out as a literal rather than composed from the
    /// same helpers the implementation uses — a test that rebuilds the value it
    /// is checking cannot fail when the value changes.
    func testThePayloadIsExactlyTheJoinURLAndNothingElse() {
        XCTAssertEqual(
            ShareInviteMessage.shareURL(code: code, ownerFirstName: "Thomas").absoluteString,
            "https://myrobotaxi.app/join/RBO246?from=Thomas"
        )
        XCTAssertEqual(
            ShareInviteMessage.shareURL(code: code, ownerFirstName: nil).absoluteString,
            "https://myrobotaxi.app/join/RBO246"
        )
    }

    /// No PROSE survives anywhere in the payload. This is the actual defect: any
    /// one of these strings reappearing in the item turns the message back into
    /// text with a link in it, and the card silently stops rendering — a
    /// regression with no crash, no failing request and no visible symptom
    /// except a client screenshot a day later.
    func testNoProseSurvivesInThePayload() {
        for name: String? in ["Thomas", nil] {
            let payload = ShareInviteMessage.shareURL(code: code, ownerFirstName: name).absoluteString
            for prose in [
                "shared their Tesla", "shared my Tesla", "MyRoboTaxi",
                "Open the link", "No app yet", "Sign in with Apple",
                "Enter this invite code", "expires in",
            ] {
                XCTAssertFalse(
                    payload.contains(prose),
                    "the payload must be a bare link — found \(prose.debugDescription)"
                )
            }
            XCTAssertFalse(payload.contains(" "), "one token, no spaces")
            XCTAssertFalse(payload.contains("\n"), "one line, no newlines")
        }
    }

    /// The TestFlight link is DEMOTED, not deleted: it is the landing page's
    /// button now (the page a recipient without the app lands on anyway), and it
    /// still lives in exactly one constant on this side. Quoting it in the
    /// payload is what made the payload more than a link.
    func testTheTestFlightLinkIsNoLongerInThePayloadButStillHasOneHome() {
        let payload = ShareInviteMessage.shareURL(code: code, ownerFirstName: "Thomas").absoluteString
        XCTAssertFalse(payload.contains("testflight.apple.com"))
        XCTAssertEqual(
            AppDistribution.testFlightPublicJoinURL,
            "https://testflight.apple.com/join/uarZRUbg",
            "the live public link (Friends & Family external group, 2026-07-29)"
        )
    }

    /// The bare CODE line is gone with the rest of the prose — but the code
    /// itself is still in the link, which is what the landing page prints and
    /// what the app autofills. Nothing about manual entry regressed; the code
    /// simply travels in the URL now.
    func testTheCodeTravelsInThePathRatherThanOnItsOwnLine() {
        let url = ShareInviteMessage.shareURL(code: code, ownerFirstName: "Thomas")
        XCTAssertEqual(url.pathComponents, ["/", "join", "RBO246"])
    }

    /// It is composed from the SAME type that PARSES an incoming link, and it
    /// round-trips through it. A literal in the composer would be a second
    /// definition of the URL shape, free to drift from the one the AASA hands
    /// back to us.
    func testTheLinkIsQuotedFromTheOneDefinitionAndParsesBack() {
        for name: String? in ["Thomas", nil, "!!!"] {
            let url = ShareInviteMessage.shareURL(code: code, ownerFirstName: name)
            XCTAssertEqual(url.absoluteString, AppDistribution.inviteJoinURL(code: code, from: name))
            XCTAssertEqual(
                InviteLink.code(from: url), code,
                "every link we hand out must survive the parser that receives it"
            )
        }
    }

    // MARK: The `from` parameter

    /// With a name, the parameter is present — this is what makes the recipient's
    /// card say "Thomas invited you to ride their Tesla" instead of the generic
    /// line. The name is trimmed on the way in.
    func testANameTravelsAsTheFromParameter() {
        XCTAssertEqual(fromValue(ownerFirstName: "Thomas"), "Thomas")
        XCTAssertEqual(fromValue(ownerFirstName: "  Thomas "), "Thomas")
        XCTAssertEqual(fromValue(ownerFirstName: "thomas"), "thomas", "case is the page's business")
    }

    /// With no usable name the parameter is OMITTED ENTIRELY — never `?from=`,
    /// never a placeholder. `nil` is a real state, not a defensive branch: Apple
    /// returns a human name only on the FIRST authorization, and a row created
    /// before native sign-in carries none (`UserProfile`). The page then renders
    /// its generic heading, which is the same two-grammar rule the old paragraph
    /// implemented in Swift — moved to where the recipient reads it.
    func testNoNameOmitsTheParameterEntirely() {
        for absent: String? in [nil, "", "   ", "\n"] {
            let payload = ShareInviteMessage.shareURL(code: code, ownerFirstName: absent).absoluteString
            XCTAssertEqual(payload, "https://myrobotaxi.app/join/RBO246")
            XCTAssertFalse(payload.contains("from"), "no empty parameter, no placeholder")
        }
    }

    /// JUNK. The name reaches a scraped, cached, forwarded page title, so the
    /// client filters before sending and the page filters again on arrival —
    /// neither side trusting the other. Separators and punctuation are dropped;
    /// anything with no letters left is omitted.
    func testJunkNamesAreFilteredOrOmitted() {
        XCTAssertEqual(fromValue(ownerFirstName: "Mary-Jane"), "MaryJane")
        XCTAssertEqual(fromValue(ownerFirstName: "Mary Jane"), "MaryJane")
        XCTAssertEqual(fromValue(ownerFirstName: "O'Neill"), "ONeill")
        XCTAssertNil(fromValue(ownerFirstName: "Thomas3"),
                     "a digit means this is not a name — never guess which part of it was")

        for junk in ["<script>alert(1)</script>", "\"><img src=x onerror=1>", "%00", "…",
                     "123", "!!!", "https://evil.example", "&from=x"] {
            XCTAssertNil(
                fromValue(ownerFirstName: junk),
                "\(junk.debugDescription) must not reach a page title"
            )
        }
    }

    /// A name we cannot SPELL in `[A-Za-z]` is omitted whole rather than reduced
    /// to the ASCII it happens to contain. "Jos invited you to ride their Tesla"
    /// misspells a person to a stranger; the generic heading merely declines to
    /// name them, which is the kinder failure — and the only reason this is not
    /// a plain "keep the letters" filter.
    func testANameThatCannotBeSpelledInASCIIIsOmittedRatherThanStripped() {
        for name in ["José", "Ольга", "美咲", "Zoë"] {
            XCTAssertNil(fromValue(ownerFirstName: name), "\(name) must not be abbreviated")
        }
    }

    /// The cap exists so a pathological profile value cannot make the link
    /// unshareable. It truncates rather than rejecting: a 30-letter first name is
    /// a real name, and the page has room for the first twenty of it.
    func testALongNameIsCappedRatherThanDropped() {
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(fromValue(ownerFirstName: long), String(repeating: "a", count: 20))
        XCTAssertEqual(InviteLink.inviterNameMaxLength, 20)
    }

    /// Whatever survives is URL-safe by construction, and the link still parses
    /// back to the code with the parameter attached — the property that matters
    /// on the receiving end, where `InviteLinkRouting` must ignore the query
    /// completely.
    func testTheComposedLinkIsAlwaysAWellFormedURL() {
        for name in ["Thomas", "Mary-Jane", "José", "", "<script>", String(repeating: "z", count: 99)] {
            let url = ShareInviteMessage.shareURL(code: code, ownerFirstName: name)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host(), "myrobotaxi.app")
            XCTAssertEqual(InviteLink.code(from: url), code)
        }
    }

    // MARK: Both share paths

    /// A fresh create and a §7.5.4 resend (which mints a NEW code and kills the
    /// old one) hand over the same shape. The resend handout deliberately carries
    /// no vehicle names (`LiveShareService.resend`), which must not change the
    /// payload — the payload never quoted them.
    func testCreateAndResendHandoutsShareTheSameLink() {
        let created = ShareHandout(code: code, label: "Mira", vehicleNames: ["Lunar", "Cybercab"])
        let resent = ShareHandout(code: code, label: "Mira", vehicleNames: [])
        XCTAssertEqual(
            created.shareURL(ownerFirstName: "Thomas"),
            resent.shareURL(ownerFirstName: "Thomas"),
            "the recipient of a resend gets the same card as a first-time invite"
        )
    }

    // MARK: MYR-368 — the server's link is the payload

    /// THE PRIMARY PATH. When the server minted a link, that link IS the payload,
    /// byte for byte — same character sequence in, same character sequence out.
    ///
    /// Asserted on `absoluteString` rather than on `URL` equality because the
    /// failure this guards against is a REWRITE, not a mismatch: percent-encoding
    /// a character Foundation would have escaped, normalising the path, or
    /// reordering the query all produce a `URL` that still points "at the same
    /// place" and still fails an Ed25519 verification at the join shell.
    func testAServerMintedLinkIsTheWholePayloadUnchanged() {
        let resolved = ShareInviteMessage.shareURL(
            serverURL: signedShareURL, code: code, ownerFirstName: "Thomas"
        )
        XCTAssertEqual(resolved.absoluteString, signedShareURL)
    }

    /// The client's own name is IGNORED when the server signed one in. `from` and
    /// `to` are both inside the signature, so composing our own `?from=` over the
    /// top would be forging a value somebody else vouched for — and would strip
    /// `k` in the process.
    func testTheOwnersLocalNameCannotOverruleASignedOne() {
        for name: String? in ["Thomas", nil, "", "Mary-Jane", "José", "<script>"] {
            XCTAssertEqual(
                ShareInviteMessage.shareURL(
                    serverURL: signedShareURL, code: code, ownerFirstName: name
                ).absoluteString,
                signedShareURL,
                "for \(String(describing: name))"
            )
        }
    }

    /// Every part of the contract's shape survives the round trip — the signature
    /// parameter, its three dot-separated fields, and BOTH display names. Stated
    /// as separate assertions from the byte-equality above so a failure says WHICH
    /// part went missing.
    func testTheSignedLinkKeepsItsSignatureAndBothNames() throws {
        let url = ShareInviteMessage.shareURL(
            serverURL: signedShareURL, code: code, ownerFirstName: nil
        )
        let items = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(items.map(\.name), ["k", "from", "to"], "the contract's parameter ORDER")
        let k = try XCTUnwrap(items.first { $0.name == "k" }?.value)
        let parts = k.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "keyId.expUnix.sigBase64url")
        XCTAssertEqual(String(parts[0]), "1", "the key id shipping today")
        XCTAssertEqual(Int(parts[1]), 1_785_942_245, "the expiry as UNIX seconds")
        XCTAssertEqual(parts[2].count, 86, "unpadded base64url of 64 signature bytes")
        XCTAssertEqual(items.first { $0.name == "from" }?.value, "Alex")
        XCTAssertEqual(items.first { $0.name == "to" }?.value, "Mira")
    }

    /// THE FALLBACK. Absence is the contract's own documented case — "a consumer
    /// that finds `code` without `shareUrl` MUST fall back" — and what this client
    /// falls back to is MYR-359's link, unchanged.
    func testAnAbsentServerLinkFallsBackToTheComposedOne() {
        XCTAssertEqual(
            ShareInviteMessage.shareURL(serverURL: nil, code: code, ownerFirstName: "Thomas")
                .absoluteString,
            "https://myrobotaxi.app/join/RBO246?from=Thomas"
        )
        XCTAssertEqual(
            ShareInviteMessage.shareURL(serverURL: nil, code: code, ownerFirstName: nil)
                .absoluteString,
            "https://myrobotaxi.app/join/RBO246"
        )
    }

    /// **`URL(string:)` SUCCEEDING IS NOT EVIDENCE THAT A STRING IS A LINK**, and
    /// this test exists because the first implementation believed it was.
    ///
    /// Foundation parses RFC 3986 RELATIVE references, so `URL(string:)` answers
    /// non-nil for almost anything: `"not a url at all"` becomes a URL whose
    /// `absoluteString` is `not%20a%20url%20at%20all`, with no scheme and no host.
    /// Handing THAT to `UIActivityViewController` puts a percent-escaped fragment
    /// of text where the invite should be — the MYR-359 defect wearing a `URL`
    /// type. The guard is absoluteness (a scheme AND a host), and every value that
    /// fails it takes the composed link instead.
    func testAValueThatParsesButIsNotAnAbsoluteLinkFallsBackToo() {
        for junk in ["", "   ", "not a url at all", "RBO246", "/join/RBO246", "myrobotaxi.app/join/RBO246"] {
            XCTAssertEqual(
                ShareInviteMessage.shareURL(
                    serverURL: junk, code: code, ownerFirstName: "Thomas"
                ).absoluteString,
                "https://myrobotaxi.app/join/RBO246?from=Thomas",
                "for \(junk.debugDescription)"
            )
        }
    }

    /// The guard stops at absoluteness on purpose: it does NOT pin the host, the
    /// path or the presence of `k`. The link's address is the server's to move
    /// (with the AASA and the entitlement — MYR-346), and a client that silently
    /// downgraded a valid new shape to its own unsigned link would turn a
    /// coordinated rollout into a regression nobody can see.
    func testAnAbsoluteLinkIsForwardedEvenWhenItIsNotTheShapeThisBuildExpects() {
        for future in [
            "https://myrobotaxi.app/j/RBO246?k=1.1785942245.sig",
            "https://eu.myrobotaxi.app/join/RBO246?k=1.1785942245.sig&from=Alex&to=Mira",
        ] {
            XCTAssertEqual(
                ShareInviteMessage.shareURL(
                    serverURL: future, code: code, ownerFirstName: "Thomas"
                ).absoluteString,
                future
            )
        }
    }

    /// MYR-359's rules stand on the new payload: it is still ONE token, still one
    /// line, still no prose, and still carries no TestFlight link. The URL got
    /// longer, not chattier — a message that is nothing but a link is what makes
    /// the card render, and that is a property of the WHOLE payload, not of the
    /// half this issue changed.
    func testTheSignedPayloadIsStillNothingButALink() {
        let payload = ShareInviteMessage.shareURL(
            serverURL: signedShareURL, code: code, ownerFirstName: "Thomas"
        ).absoluteString
        XCTAssertFalse(payload.contains(" "), "one token, no spaces")
        XCTAssertFalse(payload.contains("\n"), "one line, no newlines")
        XCTAssertFalse(payload.contains("testflight.apple.com"))
        for prose in ["shared their Tesla", "MyRoboTaxi", "Open the link", "expires in"] {
            XCTAssertFalse(payload.contains(prose), "found \(prose.debugDescription)")
        }
    }

    // MARK: -

    /// The `from` value actually carried by the composed link, or `nil` when the
    /// parameter was omitted. Read off the URL rather than from
    /// `InviteLink.inviterName` so these assertions describe what SHIPS.
    private func fromValue(ownerFirstName: String?) -> String? {
        let url = ShareInviteMessage.shareURL(code: code, ownerFirstName: ownerFirstName)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "from" }?.value
    }
}

// MARK: - Simulated service (drift-gate guard)

@MainActor
final class SimulatedShareServiceTests: XCTestCase {

    /// The whole simulated experience must stay pixel-identical: the fixture
    /// seeds, the fixture picker, and NO loading branch a capture could reach.
    func testSimulatedServiceKeepsTheFixtureSeedsAndCannotReachALoadingBranch() async {
        let service = SimulatedShareService()
        XCTAssertEqual(service.viewers, ShareFixtures.viewers)
        XCTAssertEqual(service.pending, ShareFixtures.pending)
        XCTAssertEqual(service.shareableVehicles, VehicleFixtures.vehicles)
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.sharesByCode)
        await service.load()
        XCTAssertFalse(service.isLoading, "load is a no-op in sim")
    }

    /// MYR-184 data fix: the prototype's `doSend` DISCARDED the chosen tier
    /// (`accessLevel` never reached the pending row). It is carried now — a data
    /// change only; the row's rendered text is unchanged because a fixture row
    /// carries an email and the tier line renders only on code-based rows.
    func testSimulatedSendCarriesTheChosenTierOntoThePendingRow() async throws {
        let service = SimulatedShareService()
        _ = try await service.createInvite(
            label: "friend@example.com", tier: .rides, vehicleIDs: [VehicleFixtures.vehicles[0].id]
        )
        let added = try XCTUnwrap(service.pending.first)
        XCTAssertEqual(added.tier, .rides)
        XCTAssertEqual(added.name, "Friend", "emailToName, screens.jsx:1237-1240")
        XCTAssertNil(added.code, "sim has no server to mint one — and must not fabricate one")
    }

    /// No code means no share sheet in sim: the prototype's "Invite sent"
    /// celebration stays the closing beat.
    func testSimulatedSendMintsNoHandout() async throws {
        let service = SimulatedShareService()
        let handout = try await service.createInvite(
            label: "a@b.co", tier: .live, vehicleIDs: [VehicleFixtures.vehicles[0].id]
        )
        XCTAssertNil(handout)
    }
}

// MARK: - Rider catalog + redeem

@MainActor
final class SharedVehicleCatalogTests: XCTestCase {

    private func catalog(
        _ endpoint: ScriptedShareEndpoint,
        list: [VehicleSummary] = []
    ) -> LiveSharedVehicleCatalog {
        LiveSharedVehicleCatalog(api: endpoint, listVehicles: { list })
    }

    /// A rider who also OWNS a car sees both in `GET /api/vehicles`. Owner rows
    /// are theirs outright, belong on the owner shell, and carry no
    /// `sharePermission` at all — so treating them as grants would produce a
    /// tier-less row every gate then fails closed on.
    func testOnlyViewerRowsBecomeGrants() {
        let rows = [
            summary(id: "own", name: "My Car", role: .owner, permission: nil),
            summary(id: "shared", name: "Alex's Model 3", role: .viewer, permission: "rides"),
        ]
        let grants = LiveSharedVehicleCatalog.grants(from: rows)
        XCTAssertEqual(grants.map(\.id), ["shared"])
        XCTAssertEqual(grants.first?.vehicleName, "Alex's Model 3")
        XCTAssertEqual(grants.first?.tier, .rides)
    }

    /// §7.0 — an ABSENT `sharePermission` on a viewer row is the LOWEST tier.
    /// Never full access, never fail open.
    func testAnAbsentTierOnAViewerRowIsTreatedAsLiveNotAsFullAccess() {
        let grants = LiveSharedVehicleCatalog.grants(
            from: [summary(id: "s", name: "Shared", role: .viewer, permission: nil)]
        )
        let grant = try! XCTUnwrap(grants.first)
        XCTAssertEqual(grant.tier, .live)
        XCTAssertFalse(grant.grantsRides)
        XCTAssertFalse(grant.grantsHistory)
    }

    /// The FLAGGED decision: a live row has no owner name (only §7.5.5 carries
    /// one, and only at join time), so the row titles on the vehicle nickname
    /// alone rather than rendering "'s {Vehicle}" with a hole in it.
    func testALiveGrantTitlesOnTheVehicleNicknameAlone() {
        let grant = try! XCTUnwrap(
            LiveSharedVehicleCatalog.grants(
                from: [summary(id: "s", name: "Alex's Model 3", role: .viewer, permission: "live_history")]
            ).first
        )
        XCTAssertNil(grant.ownerName)
        XCTAssertEqual(grant.title, "Alex's Model 3")
        // MYR-369 — `live_history` is retired and folds to the `live` preset,
        // so a legacy row carrying it captions as plain "Location".
        XCTAssertEqual(grant.caption, "Location")
    }

    /// The bug the first drift-gate capture of the joined screen showed verbatim:
    /// "Alex's Alex's Model 3". `VehicleSummary.name` is the owner's OWN nickname
    /// and owners name cars after themselves — the canonical server fixture is
    /// literally "Alex's Model 3" — so prefixing `ownerFirstName` onto it doubles
    /// the name. It is prefixed only when the nickname is not already about them.
    func testTheOwnerNameIsNeverDoubledOntoANicknameThatAlreadyCarriesIt() {
        XCTAssertEqual(SharedVehicleTitle.compose(owner: "Alex", vehicle: "Alex's Model 3"), "Alex's Model 3")
        XCTAssertEqual(SharedVehicleTitle.compose(owner: "Alex", vehicle: "Alex’s Model 3"), "Alex’s Model 3")
        XCTAssertEqual(SharedVehicleTitle.compose(owner: "alex", vehicle: "Alex's Model 3"), "Alex's Model 3")
        // A nickname that is NOT about the owner still gets the possessive.
        XCTAssertEqual(SharedVehicleTitle.compose(owner: "Alex", vehicle: "Lunar"), "Alex’s Lunar")
        // No owner (the §7.0 catalog rows) → the vehicle alone, never a hole.
        XCTAssertEqual(SharedVehicleTitle.compose(owner: nil, vehicle: "Lunar"), "Lunar")
        XCTAssertEqual(SharedVehicleTitle.compose(owner: "", vehicle: "Lunar"), "Lunar")
        // No nickname → a calm generic rather than a dangling possessive.
        XCTAssertEqual(SharedVehicleTitle.compose(owner: "Alex", vehicle: ""), "Alex’s Tesla")
    }

    /// MYR-369 — THE GATES ARE EQUALITY NOW, and history is owner-only.
    ///
    /// This test previously asserted the opposite (`rides GRANTS history —
    /// cumulative, not equal`) and was correct for the contract it was written
    /// against. 0.23.0 retires the total order: `sharePermission` is a derived
    /// projection emitting only `rides` or `live`, and the contract states in as
    /// many words that "the history/drives surfaces are OWNER-ONLY as of MYR-369
    /// and no value of this field opens them."
    func testTheRideGateIsEqualityAndHistoryIsOwnerOnly() {
        func grant(_ tier: ShareAccessLevel?) -> SharedVehicleGrant {
            SharedVehicleGrant(
                id: "g", ownerName: nil, relationship: nil, vehicleName: "Car",
                accessLabel: "", tier: tier, vehicle: nil
            )
        }
        XCTAssertTrue(grant(.rides).grantsRides)
        XCTAssertFalse(grant(.live).grantsRides)
        // An unknown tier fails CLOSED — nothing offered.
        XCTAssertFalse(grant(nil).grantsRides)

        // NO viewer grant opens the drives surfaces any more — including the top
        // one, which used to reach them through the cumulative order.
        for tier: ShareAccessLevel? in [.rides, .live, nil] {
            XCTAssertFalse(
                grant(tier).grantsHistory,
                "history is owner-only as of MYR-369 (tier: \(String(describing: tier)))"
            )
        }
    }

    /// §7.5.5 — the response rows ARE the catalog rows the next `GET /api/vehicles`
    /// returns, so the rider's map has a car before the list round-trips.
    func testASuccessfulRedeemSeedsTheCatalogFromTheResponse() async throws {
        let endpoint = ScriptedShareEndpoint()
        endpoint.redeemResult = .success(RedeemShareInviteResponse(
            ownerFirstName: "Alex",
            vehicles: [summary(id: "shared", name: "Alex's Model 3", role: .viewer, permission: "rides")]
        ))
        let catalog = catalog(endpoint)

        let redeemed = try await catalog.redeem(code: "RBO246")

        XCTAssertEqual(redeemed.ownerFirstName, "Alex")
        XCTAssertEqual(redeemed.grants.map(\.id), ["shared"])
        XCTAssertEqual(catalog.grants.map(\.id), ["shared"], "seeded without a second round trip")
        XCTAssertTrue(catalog.hasLoaded)
    }

    /// The §7.5.5 catalog folded onto the rider's four answers.
    func testRedeemFailuresFoldOntoTheRidersFourAnswers() async {
        let cases: [(Int, ShareRedemptionFailure)] = [
            (400, .malformed),
            (404, .invalidOrExpired),
            (409, .alreadyHasAccess),
            (429, .tooManyAttempts),
            (503, .unavailable),
        ]
        for (status, expected) in cases {
            let endpoint = ScriptedShareEndpoint()
            endpoint.redeemResult = .failure(RestError.http(status: status, code: nil, message: nil, subCode: nil))
            do {
                _ = try await catalog(endpoint).redeem(code: "RBO246")
                XCTFail("expected a failure on \(status)")
            } catch let failure as ShareRedemptionFailure {
                XCTAssertEqual(failure, expected, "status \(status)")
            } catch {
                XCTFail("expected ShareRedemptionFailure, got \(error)")
            }
        }
    }

    /// A bad code CLEARS the field and shakes — the rider is going to retype it.
    /// The rate limit and "you already have access" do NOT: nothing is wrong with
    /// what they typed, and retyping the same code just burns another attempt.
    func testOnlyACodeVerdictClearsTheEntryField() {
        XCTAssertTrue(ShareRedemptionFailure.malformed.clearsEntry)
        XCTAssertTrue(ShareRedemptionFailure.invalidOrExpired.clearsEntry)
        XCTAssertFalse(ShareRedemptionFailure.tooManyAttempts.clearsEntry)
        XCTAssertFalse(ShareRedemptionFailure.alreadyHasAccess.clearsEntry)
        XCTAssertFalse(ShareRedemptionFailure.unavailable.clearsEntry)
    }

    /// 404 conflates unknown / expired / already-consumed BY DESIGN, so the copy
    /// must not guess between them, and the rate-limit copy must say to wait.
    func testRiderCopyDoesNotGuessBetweenTheConflated404Causes() {
        XCTAssertEqual(ShareRedemptionFailure.invalidOrExpired.riderMessage, "That code didn’t work")
        XCTAssertEqual(ShareRedemptionFailure.malformed.riderMessage, "That code didn’t work")
        XCTAssertEqual(ShareRedemptionFailure.tooManyAttempts.riderMessage, "Too many attempts — wait a minute")
        for failure: ShareRedemptionFailure in [.invalidOrExpired, .malformed] {
            XCTAssertFalse(failure.riderMessage.lowercased().contains("expired"), "never guesses which cause it was")
        }
    }

    /// A FAILED list is not "nothing is shared with you". The last-known grants
    /// stand and `hasLoaded` is untouched, so the Live Map does not swap a working
    /// map for an empty state because one fetch timed out.
    func testAFailedListDoesNotEmptyTheCatalog() async {
        struct Boom: Error {}
        let endpoint = ScriptedShareEndpoint()
        let failing = LiveSharedVehicleCatalog(api: endpoint, listVehicles: { throw Boom() })
        await failing.load()
        XCTAssertFalse(failing.hasLoaded, "an unanswered list is not a loaded-empty catalog")
        XCTAssertTrue(failing.grants.isEmpty)
    }

    /// The simulated catalog publishes the prototype's three personas verbatim —
    /// the drift-gate guard for `SharedSettingsScreen`.
    func testSimulatedCatalogPublishesThePrototypePersonasVerbatim() async {
        let catalog = SimulatedSharedVehicleCatalog()
        XCTAssertEqual(catalog.grants.map(\.title), ["Alex’s Cybercab", "Mom’s Model Y", "Jordan’s Model 3"])
        XCTAssertEqual(catalog.grants.map(\.caption), [
            "Roommate · Request rides",
            "Family · Request rides",
            "Friend · Request rides",
        ])
        XCTAssertTrue(catalog.hasLoaded)
    }

    /// onboarding.jsx:421 — "forgiving: any 6 chars joins". The simulated redeem
    /// cannot fail, and returns the fixture host, so the sim success screen is
    /// the same pixels it was before the redeem call existed.
    func testSimulatedRedeemAlwaysSucceedsWithTheFixtureHost() async throws {
        let redeemed = try await SimulatedSharedVehicleCatalog().redeem(code: "ZZZZZZ")
        XCTAssertEqual(redeemed.ownerFirstName, "Alex")
        XCTAssertEqual(redeemed.grants.first?.vehicleName, "Model Y")
        XCTAssertEqual(redeemed.grants.first?.relationship, "Roommate")
    }
}

// MARK: - Rider shell gating

@MainActor
final class SharedViewerSharingGateTests: XCTestCase {

    /// MYR-228 fix (c): the rider's watched vehicle used to DEFAULT to
    /// `VehicleFixtures.vehicles[0]` with no live gate, so a signed-in rider with
    /// nothing shared watched a map for a car on nobody's account.
    func testALiveViewerStateStartsWithNoVehicleAndNoFixtureLeak() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        XCTAssertNil(state.sharedVehicle)
        // The map's degrade carries NO fixture content — not the fixture's name,
        // not its plate, not its id.
        XCTAssertEqual(state.mapVehicle.name, "")
        XCTAssertEqual(state.mapVehicle.plate, "")
        XCTAssertNotEqual(state.mapVehicle.id, VehicleFixtures.vehicles[0].id)
    }

    /// The SIM default is unchanged — every simulated + DEBUG rider scene keeps
    /// the fixture vehicle it captured before.
    func testTheSimulatedDefaultStillSeedsTheFixtureVehicle() {
        let state = SharedViewerState()
        XCTAssertEqual(state.sharedVehicle, VehicleFixtures.vehicles[0])
        XCTAssertEqual(state.mapVehicle, VehicleFixtures.vehicles[0])
    }

    /// Adoption takes the vehicle AND the tier from the grant.
    func testAdoptingAGrantTakesBothTheVehicleAndTheTier() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        let grant = try! XCTUnwrap(
            LiveSharedVehicleCatalog.grants(
                from: [summary(id: "shared", name: "Alex's Model 3", role: .viewer, permission: "live")]
            ).first
        )
        state.adoptSharedVehicle(grant)

        XCTAssertEqual(state.sharedVehicle?.id, "shared")
        XCTAssertEqual(state.sharedVehicle?.name, "Alex's Model 3")
        XCTAssertEqual(state.sharedVehicleTier, .live)
    }

    /// §7.5.0 — only the TOP tier may be offered the ride-request CTA. The client
    /// must not offer what the server will 403.
    func testOnlyTheRidesTierIsOfferedTheRequestAffordance() {
        func stateOn(_ permission: String) -> SharedViewerState {
            let state = SharedViewerState(vehicle: nil, seams: .simulated)
            state.adoptSharedVehicle(
                LiveSharedVehicleCatalog.grants(
                    from: [summary(id: "s", name: "Shared", role: .viewer, permission: permission)]
                ).first
            )
            return state
        }
        XCTAssertTrue(stateOn("rides").canRequestRides)
        XCTAssertFalse(stateOn("live_history").canRequestRides)
        XCTAssertFalse(stateOn("live").canRequestRides)
    }

    /// No tier applies on the simulated path (the prototype's rider can always
    /// request), so every simulated capture keeps the "Where to?" CTA.
    func testTheSimulatedRiderAlwaysKeepsTheRequestAffordance() {
        XCTAssertTrue(SharedViewerState().canRequestRides)
    }

    /// Re-adopting the SAME vehicle is a no-op, so a catalog refresh on every
    /// foreground does not restart the ticker and jump the map.
    func testReadoptingTheSameVehicleDoesNotReplaceTheTelemetrySource() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        let grant = LiveSharedVehicleCatalog.grants(
            from: [summary(id: "s", name: "Shared", role: .viewer, permission: "rides")]
        ).first
        state.adoptSharedVehicle(grant)
        let first = state.telemetrySource
        state.adoptSharedVehicle(grant)
        XCTAssertTrue(first === state.telemetrySource as AnyObject as? AnyObject)
    }
}

// MARK: - The share-sheet capture scenes exercise the PRIMARY path (MYR-368)

/// `ownerShareMessage` / `ownerShareMessageNoName` are the only capture route to
/// the share sheet, and after this issue the thing worth capturing is the SERVER's
/// signed link. A stub that kept answering with `code` alone would leave both
/// scenes quietly photographing the MYR-359 fallback and calling it the new
/// payload — a capture that is wrong about the product while looking exactly
/// right, which is the failure this file's `DebugShareEndpoint` exists to avoid.
///
/// So the stub's link is asserted the way the app treats a real one: parse it,
/// and check the shape the contract specifies.
@MainActor
final class DebugSignedInviteLinkTests: XCTestCase {

    func testTheCaptureStubMintsALinkInTheContractsShape() throws {
        let expires = Date(timeIntervalSince1970: 1_785_942_245)
        let raw = DebugSignedInviteLink.url(
            code: "RBO246", expires: expires, from: "Thomas Nandola", to: "Mira Chen"
        )
        let url = try XCTUnwrap(URL(string: raw))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(items.map(\.name), ["k", "from", "to"])
        let parts = try XCTUnwrap(items.first { $0.name == "k" }?.value)
            .split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(String(parts[0]), DebugSignedInviteLink.keyID)
        XCTAssertEqual(Int(parts[1]), 1_785_942_245, "`k`'s expiry is `expiresAt` in UNIX seconds")
        XCTAssertEqual(parts[2].count, 86, "unpadded base64url of 64 signature bytes")
        // The contract's server-side name rule: FIRST token, ASCII letters, ≤ 20.
        XCTAssertEqual(items.first { $0.name == "from" }?.value, "Thomas")
        XCTAssertEqual(items.first { $0.name == "to" }?.value, "Mira")
    }

    /// Whatever the stub mints must survive the SHIPPING parser — the property
    /// that makes the capture evidence about the product rather than about this
    /// file, and the same round-trip `ShareInviteMessageTests` asks of the
    /// client-composed link.
    func testTheCaptureStubsLinkParsesBackToItsCode() throws {
        for code in ["RBO246", "ZKQ913", "ABCDEF"] {
            let raw = DebugSignedInviteLink.url(
                code: code, expires: Date(), from: "Thomas Nandola", to: "Mira Chen"
            )
            XCTAssertEqual(InviteLink.code(from: try XCTUnwrap(URL(string: raw))), code)
            XCTAssertEqual(InviteCodeEntry.extractCode(from: raw), code, "and a paste of it, too")
        }
    }

    /// `ownerShareMessageNoName` is now the arm where the SERVER omitted the
    /// parameter, so the omission has to be the stub's — never an empty `from=`,
    /// and never at the cost of `to`, which is what keeps the pair a
    /// one-parameter diff.
    func testAnUnnameableOwnerDropsOnlyTheFromParameter() throws {
        for absent: String? in [nil, "", "   ", "123", "!!!"] {
            let raw = DebugSignedInviteLink.url(
                code: "RBO246", expires: Date(), from: absent, to: "Mira Chen"
            )
            XCTAssertFalse(raw.contains("from="), "for \(String(describing: absent))")
            XCTAssertTrue(raw.contains("to=Mira"))
            XCTAssertTrue(raw.contains("k="))
        }
    }

    /// THE SERVER'S NAME RULE IS NOT THE CLIENT'S, and the stub models the
    /// server's on purpose.
    ///
    /// `InviteLink.inviterName` (MYR-359, the FALLBACK link this client composes)
    /// omits an accented name WHOLE — "Jos invited you to ride their Tesla"
    /// misspells someone to a stranger, and declining to name them is the kinder
    /// failure. The contract's server-side rule is the plainer one: strip to
    /// `[A-Za-z]` and keep what is left, so "José" travels as "Jos" and only an
    /// empty result drops the parameter. Making the stub agree with the app here
    /// would have made it a mirror of this client instead of a model of the
    /// server, and the difference would then be invisible in every capture.
    func testTheStubFollowsTheServersNameRuleAndNotTheClientsStricterOne() {
        let raw = DebugSignedInviteLink.url(
            code: "RBO246", expires: Date(), from: "José Ruiz", to: "Mira Chen"
        )
        XCTAssertTrue(raw.contains("from=Jos"), "the server strips; it does not omit")
        XCTAssertNil(InviteLink.inviterName("José"), "the client, composing its own link, omits")
        XCTAssertEqual(DebugSignedInviteLink.signedName("Mary-Jane Watson"), "MaryJane",
                       "FIRST token, ASCII letters only")
        XCTAssertEqual(
            DebugSignedInviteLink.signedName(String(repeating: "a", count: 40)),
            String(repeating: "a", count: 20),
            "capped at 20"
        )
    }

    /// Two SEPARATE mints of the same code produce the same signature bytes, so a
    /// scene captured twice differs only where a real mint would differ (the
    /// expiry). Different codes do not collide.
    func testTheStandInSignatureIsDeterministicPerCode() {
        let a = DebugSignedInviteLink.url(code: "RBO246", expires: Date(timeIntervalSince1970: 1), from: nil, to: nil)
        let b = DebugSignedInviteLink.url(code: "RBO246", expires: Date(timeIntervalSince1970: 1), from: nil, to: nil)
        let c = DebugSignedInviteLink.url(code: "ZKQ913", expires: Date(timeIntervalSince1970: 1), from: nil, to: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - The scene end to end (MYR-368)

/// The guard that the two share-sheet capture scenes exercise the PRIMARY path.
///
/// `DebugSignedInviteLinkTests` proves the stub mints a link and
/// `LiveShareServiceTests` proves the service carries one; neither proves that
/// the SCENE wires the two together. That gap is exactly where a capture goes
/// quietly wrong — the sheet still opens, the code is still real, and the URL in
/// the screenshot is the pre-0.22.0 fallback.
@MainActor
final class ShareMessageSceneWiringTests: XCTestCase {

    private func handout(for scene: DebugScene) async throws -> ShareHandout {
        let service = try XCTUnwrap(scene.shareServiceOverride)
        await service.load()
        let pending = try XCTUnwrap(service.pending.first)
        // The same call `InvitesScreen`'s `opensShareSheetForFirstPending` makes.
        let minted = try await service.resend(pending)
        return try XCTUnwrap(minted)
    }

    /// `ownerShareMessage`: the sheet's payload is the SERVER's signed link, with
    /// the owner's name in it — resolved by the shipping `ShareInviteMessage`, so
    /// the capture shows what a real owner's phone would show.
    func testTheNamedSceneSharesTheServersSignedLink() async throws {
        let handout = try await self.handout(for: .ownerShareMessage)
        let payload = handout.shareURL(ownerFirstName: "Thomas").absoluteString

        XCTAssertEqual(payload, handout.shareUrl, "the server's link, verbatim")
        XCTAssertTrue(payload.contains("/join/ZKQ913"), "the resend's freshly minted code")
        XCTAssertTrue(payload.contains("&from=Thomas"))
        XCTAssertTrue(payload.contains("&to=Mira"))
        XCTAssertTrue(payload.contains("?k=1."), "the signature the join shell verifies")
    }

    /// `ownerShareMessageNoName`: the SERVER omitted `from`, which is the only way
    /// that arm can exist now that the client no longer composes the link. `to`
    /// stays, so the pair is a one-parameter diff and nothing else.
    func testTheNoNameSceneOmitsOnlyTheFromParameter() async throws {
        let named = try await handout(for: .ownerShareMessage)
        let anonymous = try await handout(for: .ownerShareMessageNoName)
        let payload = anonymous.shareURL(ownerFirstName: nil).absoluteString

        XCTAssertEqual(payload, anonymous.shareUrl)
        XCTAssertFalse(payload.contains("from="), "never an empty parameter")
        XCTAssertTrue(payload.contains("&to=Mira"))
        XCTAssertTrue(payload.contains("/join/ZKQ913"))
        XCTAssertEqual(
            named.shareURL(ownerFirstName: "Thomas").absoluteString
                .replacingOccurrences(of: "&from=Thomas", with: ""),
            payload,
            "the two scenes differ by exactly that one parameter"
        )
    }

    /// The list rows behind the tab carry the link too — §7.5.2 puts `shareUrl`
    /// on every PENDING row, alongside the code it contains.
    func testTheSeededPendingRowsCarryASignedLinkBeforeAnyResend() async throws {
        let service = try XCTUnwrap(DebugScene.ownerShareLive.shareServiceOverride)
        await service.load()
        XCTAssertEqual(service.pending.count, 1, "two server rows, one code, one screen row")
        let minted = try await service.createInvite(
            label: "Mira Chen", tier: .rides, vehicleIDs: [VehicleFixtures.vehicles[0].id]
        )
        XCTAssertEqual(try XCTUnwrap(minted).shareUrl?.contains("/join/RBO246"), true)
    }
}

// MARK: - MYR-369: per-viewer share controls
//
// The owner can now EDIT a grant in place (`PATCH /api/invites/{id}`) instead of
// revoking and re-inviting, and the vehicle-level ride-share switch moved onto
// this screen. These tests cover the three things that are easy to get wrong and
// impossible to see: what the wire body carries, what happens to the row when the
// write fails, and what the two switches say when they are disabled.

@MainActor
final class ShareViewerControlTests: XCTestCase {

    private let clock = { ISO8601DateFormatter().date(from: "2026-07-29T15:04:05Z")! }

    private func makeService(
        _ endpoint: ScriptedShareEndpoint,
        vehicles: [Vehicle] = [VehicleFixtures.vehicles[0]],
        rideShare: ShareTabRideShareEndpoint = ShareTabRideShareEndpoint()
    ) -> LiveShareService {
        LiveShareService(
            api: endpoint, rideShareAPI: rideShare,
            ownedVehicles: { vehicles }, now: clock
        )
    }

    /// One accepted grant, active, rides off — the ordinary starting state.
    private func seeded(
        _ endpoint: ScriptedShareEndpoint,
        vehicle: Vehicle,
        allowRides: Bool = false,
        suspended: Bool = false
    ) {
        endpoint.listByVehicle[vehicle.id] = [
            invite(
                id: "acc-1", vehicle: vehicle.id, label: "Mira Chen",
                permission: allowRides ? "rides" : "live", status: .accepted,
                acceptedAt: "2026-07-01T11:23:00Z",
                allowRides: allowRides, suspended: suspended
            )
        ]
    }

    // MARK: The wire body

    /// **THE BODY CARRIES EXACTLY THE FLAG BEING EDITED.** The update is partial
    /// by contract: an absent property leaves that capability alone and is NOT
    /// the same as sending `false`. A client that sent both because it happened
    /// to know both would overwrite a capability the owner never touched — with
    /// whatever it last read, which on a stale row is a silent unintended edit
    /// that answers `200`.
    func testEachSwitchPatchesOnlyItsOwnFlag() async throws {
        let vehicle = VehicleFixtures.vehicles[0]
        let endpoint = ScriptedShareEndpoint()
        seeded(endpoint, vehicle: vehicle)
        let service = makeService(endpoint, vehicles: [vehicle])
        await service.load()
        let viewer = try XCTUnwrap(service.viewers.first)

        try await service.setViewerAllowRides(true, viewer: viewer)
        let firstPatches = endpoint.calls.compactMap { call -> ScriptedShareEndpoint.Call? in
            if case .patch = call { return call } else { return nil }
        }
        XCTAssertEqual(
            firstPatches,
            [.patch(inviteID: "acc-1", allowRides: true, suspended: nil)],
            "the rides switch must not also write `suspended`"
        )

        try await service.setViewerSuspended(true, viewer: try XCTUnwrap(service.viewers.first))
        let patches = endpoint.calls.compactMap { call -> ScriptedShareEndpoint.Call? in
            if case .patch = call { return call } else { return nil }
        }
        XCTAssertEqual(patches.last, .patch(inviteID: "acc-1", allowRides: nil, suspended: true))
    }

    /// The Location switch reads as the VIEWER'S ACCESS; the wire flag is
    /// `suspended`. Its sense is therefore INVERTED, which is exactly the kind of
    /// off-by-a-negation that ships silently — the switch would look right and
    /// suspend on the wrong tap.
    func testTurningLocationOffSuspendsAndTurningItOnRestores() async throws {
        let vehicle = VehicleFixtures.vehicles[0]
        let endpoint = ScriptedShareEndpoint()
        seeded(endpoint, vehicle: vehicle, suspended: true)
        let service = makeService(endpoint, vehicles: [vehicle])
        await service.load()

        let viewer = try XCTUnwrap(service.viewers.first)
        XCTAssertTrue(viewer.suspended, "the row starts paused")

        // Location ON → suspended: FALSE.
        try await service.setViewerSuspended(false, viewer: viewer)
        let patches = endpoint.calls.compactMap { call -> ScriptedShareEndpoint.Call? in
            if case .patch = call { return call } else { return nil }
        }
        XCTAssertEqual(patches, [.patch(inviteID: "acc-1", allowRides: nil, suspended: false)])
    }

    /// **ONE SCREEN ROW IS N SERVER ROWS.** A multi-vehicle invite is N grants and
    /// the PATCH applies to ONE of them, so a grouped row has to patch its whole
    /// group — the same fan-out revoke does. Patching only the first would leave
    /// the person still able to ride the owner's other car, from a switch that
    /// says otherwise.
    func testAGroupedRowPatchesEveryServerRowBehindIt() async throws {
        let vehicles = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
        let endpoint = ScriptedShareEndpoint()
        for (index, vehicle) in vehicles.enumerated() {
            endpoint.listByVehicle[vehicle.id] = [
                invite(
                    id: "acc-\(index)", vehicle: vehicle.id, label: "Mira Chen",
                    permission: "live", status: .accepted,
                    acceptedAt: "2026-07-01T11:23:00Z",
                    allowRides: false, suspended: false
                )
            ]
        }
        let service = makeService(endpoint, vehicles: vehicles)
        await service.load()
        XCTAssertEqual(service.viewers.count, 1, "two server rows, one person, one row")

        try await service.setViewerAllowRides(true, viewer: try XCTUnwrap(service.viewers.first))
        let patched = endpoint.calls.compactMap { call -> String? in
            if case .patch(let id, _, _) = call { return id } else { return nil }
        }
        XCTAssertEqual(patched.sorted(), ["acc-0", "acc-1"])
    }

    /// Two grants that DISAGREE about a flag must stay two rows. Collapsing them
    /// would render one pair of switches over two different states and write to
    /// both — so un-pausing "Mira" would silently restore a car the owner had
    /// paused separately.
    func testGrantsDifferingOnlyBySuspensionDoNotCollapseIntoOneRow() {
        let rows = [
            invite(
                id: "a", vehicle: "v1", label: "Mira Chen", permission: "live",
                status: .accepted, acceptedAt: "2026-07-01T11:23:00Z",
                allowRides: false, suspended: false
            ),
            invite(
                id: "b", vehicle: "v2", label: "Mira Chen", permission: "live",
                status: .accepted, acceptedAt: "2026-07-01T11:23:00Z",
                allowRides: false, suspended: true
            ),
        ]
        let result = ShareRowGrouping.group(rows, now: clock())
        XCTAssertEqual(result.viewers.count, 2, "same person, same instant, different access")
        XCTAssertEqual(result.viewers.map(\.suspended).sorted(by: { !$0 && $1 }), [false, true])
    }

    // MARK: Optimistic UI + rollback

    /// The switch moves NOW — a toggle that waits for a round trip reads as
    /// broken — and the row is the server's again the moment the write refuses.
    /// Leaving the optimistic position up is the failure mode that matters: an
    /// owner walks away believing they paused someone who still has full access.
    func testAFailedPatchRollsTheRowBackToItsPreviousPosition() async throws {
        let vehicle = VehicleFixtures.vehicles[0]
        let endpoint = ScriptedShareEndpoint()
        seeded(endpoint, vehicle: vehicle, allowRides: false)
        endpoint.patchError["acc-1"] = RestError.http(
            status: 500, code: nil, message: nil, subCode: nil
        )
        let service = makeService(endpoint, vehicles: [vehicle])
        await service.load()
        let viewer = try XCTUnwrap(service.viewers.first)
        XCTAssertFalse(viewer.allowRides)

        do {
            try await service.setViewerAllowRides(true, viewer: viewer)
            XCTFail("a 500 must reach the caller so the screen can say so")
        } catch {
            // expected — the screen turns this into its quiet failure toast.
        }
        XCTAssertFalse(
            try XCTUnwrap(service.viewers.first).allowRides,
            "the optimistic ON must not survive a refused write"
        )
    }

    /// A `404` is the same non-oracle answer DELETE gives — gone, another
    /// owner's, or a tombstone — so it is not a failure to report. The re-read
    /// that follows is what shows the owner the truth.
    func testAPatchOnAVanishedGrantIsNotSurfacedAsAFailure() async throws {
        let vehicle = VehicleFixtures.vehicles[0]
        let endpoint = ScriptedShareEndpoint()
        seeded(endpoint, vehicle: vehicle)
        endpoint.patchError["acc-1"] = RestError.http(
            status: 404, code: nil, message: nil, subCode: nil
        )
        let service = makeService(endpoint, vehicles: [vehicle])
        await service.load()
        let viewer = try XCTUnwrap(service.viewers.first)

        // Must not throw.
        try await service.setViewerAllowRides(true, viewer: viewer)
    }

    // MARK: The relocated vehicle switch (§7.18)

    /// The card at the top of the Share tab reads the SAME field the owner
    /// sheet's row read, through the same "absent means enabled" rule.
    func testTheVehicleRowReadsAbsentAsEnabledAndFalseAsPaused() async {
        let base = VehicleFixtures.vehicles[0]
        func row(_ flag: Bool?) async -> VehicleRideShareRow? {
            let vehicle = Vehicle(
                id: base.id, name: base.name, model: base.model, colorName: base.colorName,
                plate: base.plate, seatHeat: base.seatHeat, seatVent: base.seatVent,
                activity: base.activity, rideShareEnabled: flag
            )
            let service = makeService(ScriptedShareEndpoint(), vehicles: [vehicle])
            return service.vehicleRideShare.first
        }
        let absent = await row(nil)
        XCTAssertEqual(absent?.isEnabled, true, "ABSENT MEANS ENABLED — never paused")
        let paused = await row(false)
        XCTAssertEqual(paused?.isEnabled, false, "an explicit false is the owner's pause")
        let on = await row(true)
        XCTAssertEqual(on?.isEnabled, true)
    }

    /// The client adopts the server's ECHO, not the bool it sent — the rule that
    /// keeps a future coercing server from being silently contradicted.
    func testTheVehicleSwitchAdoptsTheServersEchoRatherThanTheSubmission() async throws {
        let vehicle = VehicleFixtures.vehicles[0]
        let rideShare = ShareTabRideShareEndpoint()
        rideShare.echoOverride = true                 // server refuses to pause
        let service = makeService(ScriptedShareEndpoint(), vehicles: [vehicle], rideShare: rideShare)

        try await service.setVehicleRideShareEnabled(false, vehicleID: vehicle.id)
        XCTAssertEqual(rideShare.writes.map(\.enabled), [false], "we asked for OFF")
        XCTAssertEqual(
            service.vehicleRideShare.first?.isEnabled, true,
            "and adopted the server's answer, which was ON"
        )
    }

    /// §7.18's own reasoning: a failed write reported as success "would leave an
    /// owner believing their car is paused while it is still taking requests".
    func testAFailedVehicleWriteRollsTheSwitchBack() async {
        let vehicle = VehicleFixtures.vehicles[0]
        let rideShare = ShareTabRideShareEndpoint()
        rideShare.failure = RestError.http(status: 500, code: nil, message: nil, subCode: nil)
        let service = makeService(ScriptedShareEndpoint(), vehicles: [vehicle], rideShare: rideShare)
        XCTAssertEqual(service.vehicleRideShare.first?.isEnabled, true)

        do {
            try await service.setVehicleRideShareEnabled(false, vehicleID: vehicle.id)
            XCTFail("the refusal must reach the caller")
        } catch {}
        XCTAssertEqual(
            service.vehicleRideShare.first?.isEnabled, true,
            "the optimistic PAUSE must not survive a refused write"
        )
    }

    // MARK: What the switches SAY

    private func viewer(
        name: String = "Aanya", allowRides: Bool, suspended: Bool
    ) -> Viewer {
        Viewer(
            id: "v", name: name, email: nil, online: false, perm: "Location",
            tier: allowRides ? .rides : .live, allowRides: allowRides, suspended: suspended
        )
    }

    /// The paused row must make the CONSEQUENCE plain and name the person. The
    /// wire's word for this is "suspended", which means nothing to an owner.
    func testASuspendedRowSaysThePersonCannotSeeTheCar() {
        let controls = ShareViewerControls.resolve(
            viewer: viewer(allowRides: true, suspended: true),
            vehicleRideShareEnabled: true, vehicleName: nil
        )
        XCTAssertFalse(controls.locationOn)
        XCTAssertEqual(controls.subtitle, "Paused \u{2014} Aanya can\u{2019}t see this car")
        XCTAssertFalse(controls.ridesInteractive, "suspension gates everything below it")
        XCTAssertTrue(
            controls.ridesOn,
            "the STORED flag still shows, so the owner can see what restoring returns"
        )
    }

    /// **PRECEDENCE.** A viewer who is suspended on a car whose ride sharing is
    /// ALSO off must be told the stronger, more specific fact. Naming the lesser
    /// reason would send the owner to the wrong switch.
    func testSuspensionOutranksTheVehicleLevelPauseInTheCopy() {
        let controls = ShareViewerControls.resolve(
            viewer: viewer(allowRides: true, suspended: true),
            vehicleRideShareEnabled: false, vehicleName: "Lunar"
        )
        XCTAssertTrue(controls.subtitle.contains("can\u{2019}t see this car"))
        XCTAssertEqual(controls.ridesCaption, "Turn location back on to change this")
    }

    /// A disabled Rides switch must carry the VEHICLE-LEVEL context, not just
    /// grey out. A control that stops working without saying why is the silent
    /// state this app has been burned by repeatedly.
    func testTheVehiclePauseDisablesRidesAndSaysWhy() {
        let named = ShareViewerControls.resolve(
            viewer: viewer(allowRides: true, suspended: false),
            vehicleRideShareEnabled: false, vehicleName: "Lunar"
        )
        XCTAssertTrue(named.locationOn, "the person can still SEE the car")
        XCTAssertFalse(named.ridesInteractive)
        XCTAssertEqual(named.ridesCaption, "Ride sharing is off for Lunar")

        // A single-car owner reads the unnamed sentence better.
        let unnamed = ShareViewerControls.resolve(
            viewer: viewer(allowRides: true, suspended: false),
            vehicleRideShareEnabled: false, vehicleName: nil
        )
        XCTAssertEqual(unnamed.ridesCaption, "Ride sharing is off for this car")
    }

    /// The ordinary active states: both switches live, and the subtitle says what
    /// the person can actually do.
    func testAnActiveRowStatesWhatTheGrantAllows() {
        let watching = ShareViewerControls.resolve(
            viewer: viewer(allowRides: false, suspended: false),
            vehicleRideShareEnabled: true, vehicleName: nil
        )
        XCTAssertTrue(watching.locationOn)
        XCTAssertFalse(watching.ridesOn)
        XCTAssertTrue(watching.ridesInteractive)
        XCTAssertNil(watching.ridesCaption, "a live control needs no explanation")
        XCTAssertEqual(watching.subtitle, "Can see this car\u{2019}s location")

        let riding = ShareViewerControls.resolve(
            viewer: viewer(allowRides: true, suspended: false),
            vehicleRideShareEnabled: true, vehicleName: nil
        )
        XCTAssertEqual(riding.subtitle, "Can see this car and request rides")
    }
}

// MARK: - MYR-369: the viewer's car simply vanishes

@MainActor
final class SuspendedVehicleDisappearanceTests: XCTestCase {

    /// **SUSPENSION IS NOT A MARKER, IT IS AN ABSENCE.** The server enforces it by
    /// removing the grant from the viewer's access set, so a suspended car does
    /// not arrive flagged — it stops being in `GET /api/vehicles`. A client
    /// looking for a "suspended" field on the viewer side would find nothing and
    /// conclude everything was fine.
    func testASuspendedGrantProducesNoViewerRowAtAll() {
        // The owner's OWN listing still serializes it — that is the whole point,
        // they have to be able to un-suspend it.
        let ownerRows = ShareRowGrouping.group(
            [invite(
                id: "acc-1", vehicle: "v1", label: "Aanya", permission: "live",
                status: .accepted, acceptedAt: "2026-07-01T11:23:00Z",
                allowRides: false, suspended: true
            )],
            now: ISO8601DateFormatter().date(from: "2026-07-29T15:04:05Z")!
        )
        XCTAssertEqual(ownerRows.viewers.count, 1, "the owner must still see it to restore it")
        XCTAssertTrue(ownerRows.viewers[0].suspended)

        // The VIEWER's side of the same suspension: the row is simply not there.
        XCTAssertTrue(LiveSharedVehicleCatalog.grants(from: []).isEmpty)
    }

    /// The list refresh that follows a suspension resolves to the honest EMPTY
    /// state rather than to "unavailable" — nothing failed, the account genuinely
    /// has no vehicles now.
    func testTheListRefreshAfterASuspensionResolvesToEmptyNotUnavailable() {
        let resolution = RiderVehicleSet.resolve(
            hasLoaded: true, loadFailed: false, grants: [], ownedVehicles: []
        )
        XCTAssertEqual(resolution, .empty)

        // A list that did NOT answer is a different question and must not be
        // mistaken for "your car was taken away".
        XCTAssertEqual(
            RiderVehicleSet.resolve(
                hasLoaded: false, loadFailed: true, grants: [], ownedVehicles: []
            ),
            .unavailable
        )
    }

    /// **THE STRAND.** Releasing the viewer state on `.empty` is MYR-369's viewer
    /// half. Before it, `.empty` left `sharedVehicle`, the tier and the live
    /// socket subscription all pointed at a car the account no longer has access
    /// to: the shell showed an honest empty screen while the state underneath it
    /// still held the revoked vehicle.
    func testAdoptingNilReleasesTheVehicleAndItsTier() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        let grant = try! XCTUnwrap(
            LiveSharedVehicleCatalog.grants(
                from: [summary(id: "shared", name: "Alex's Model 3", role: .viewer, permission: "rides")]
            ).first
        )
        state.adoptSharedVehicle(grant)
        XCTAssertEqual(state.sharedVehicle?.id, "shared")
        XCTAssertEqual(state.sharedVehicleTier, .rides)

        // The car is suspended; the next list read carries nothing.
        state.adopt(nil)
        XCTAssertNil(state.sharedVehicle, "the vanished car must not be held")
        XCTAssertNil(state.sharedVehicleTier, "nor its capabilities")
    }

    /// Releasing must not CRASH or strand a half-adopted state — the car can go
    /// away mid-session, and re-adopting a real one afterwards has to work.
    func testTheViewerSurvivesTheCarVanishingAndComingBack() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        let grant = try! XCTUnwrap(
            LiveSharedVehicleCatalog.grants(
                from: [summary(id: "shared", name: "Alex's Model 3", role: .viewer, permission: "live")]
            ).first
        )
        state.adoptSharedVehicle(grant)
        state.adopt(nil)
        XCTAssertNil(state.sharedVehicle)
        // Restored by the owner → the next refresh adopts it again cleanly.
        state.adoptSharedVehicle(grant)
        XCTAssertEqual(state.sharedVehicle?.id, "shared")
        XCTAssertEqual(state.sharedVehicleTier, .live)
    }

    /// A viewer whose grant has `allowRides` false gets NO ride affordance, and
    /// the gate reads off the derived `live` the server now emits. `live_history`
    /// no longer arrives at all, so the old middle rung cannot be what decides it.
    func testAViewerWithoutRidesIsOfferedNoRideAffordance() {
        func canRide(_ permission: String) -> Bool {
            let state = SharedViewerState(vehicle: nil, seams: .simulated)
            let grant = try! XCTUnwrap(
                LiveSharedVehicleCatalog.grants(
                    from: [summary(id: "s", name: "Car", role: .viewer, permission: permission)]
                ).first
            )
            state.adoptSharedVehicle(grant)
            return state.canRequestRides
        }
        XCTAssertTrue(canRide("rides"), "allowRides true derives `rides`")
        XCTAssertFalse(canRide("live"), "allowRides false derives `live` — watch only")
        // Decode-compat: retired, never emitted, and must not open the affordance.
        XCTAssertFalse(canRide("live_history"))
    }
}
