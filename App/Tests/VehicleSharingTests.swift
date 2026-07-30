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
}

// MARK: - Builders

private func invite(
    id: String,
    vehicle: String,
    label: String,
    permission: String,
    status: ShareInvite.Status,
    code: String? = nil,
    createdAt: String = "2026-07-27T15:04:05Z",
    expiresAt: String? = nil,
    acceptedAt: String? = nil
) -> ShareInvite {
    ShareInvite(
        inviteId: id,
        vehicleId: vehicle,
        label: label,
        permission: SharePermission(rawValue: permission),
        status: status,
        code: code,
        createdAt: createdAt,
        expiresAt: expiresAt,
        acceptedAt: acceptedAt
    )
}

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
        XCTAssertEqual(ShareTierMapping.wireValue(for: .history), "live_history")
        XCTAssertEqual(ShareTierMapping.wireValue(for: .rides), "rides")
    }

    /// The rendered label is the DESIGN's own string for each tier, so an owner
    /// who picked "Live + history" in the sheet sees "Live + history" on the row.
    func testPermLabelsAreTheDesignsOwnTierLabels() {
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "live"), "Live location")
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "live_history"), "Live + history")
        XCTAssertEqual(ShareTierMapping.permLabel(forWire: "rides"), "Can request rides")
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
        XCTAssertEqual(ShareAccessLevel.fromPermLabel("Live location"), .live)
        XCTAssertEqual(ShareAccessLevel.fromPermLabel("Live + history"), .history)
        XCTAssertEqual(ShareAccessLevel.fromPermLabel("Can request rides"), .rides)
        XCTAssertNil(ShareAccessLevel.fromPermLabel("Shared access"))
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
        XCTAssertEqual(row.tier, .history)
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
        XCTAssertEqual(viewer.perm, "Live location")
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
        vehicles: [Vehicle] = [VehicleFixtures.vehicles[0], VehicleFixtures.vehicles[1]]
    ) -> LiveShareService {
        LiveShareService(
            api: endpoint,
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
        XCTAssertEqual(grant.caption, "Live + history")
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

    /// §7.5.0 — the gates are CUMULATIVE (`>=`), never equality.
    func testCapabilityGatesAreCumulative() {
        func grant(_ tier: ShareAccessLevel?) -> SharedVehicleGrant {
            SharedVehicleGrant(
                id: "g", ownerName: nil, relationship: nil, vehicleName: "Car",
                accessLabel: "", tier: tier, vehicle: nil
            )
        }
        XCTAssertTrue(grant(.rides).grantsRides)
        XCTAssertTrue(grant(.rides).grantsHistory, "rides GRANTS history — cumulative, not equal")
        XCTAssertFalse(grant(.history).grantsRides)
        XCTAssertTrue(grant(.history).grantsHistory)
        XCTAssertFalse(grant(.live).grantsHistory)
        XCTAssertFalse(grant(.live).grantsRides)
        // An unrankable tier fails CLOSED — nothing offered.
        XCTAssertFalse(grant(nil).grantsHistory)
        XCTAssertFalse(grant(nil).grantsRides)
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
