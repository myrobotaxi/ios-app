import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for the vehicle-sharing family (rest-api.md §7.5 — MYR-184):
/// path assembly for all five endpoints, the `invites` (not `items`) envelope, the
/// pending-only `code`, the 204 DELETE that must not decode, the §7.5.5 error
/// catalog folded through the typed `RestError`, and the CUMULATIVE tier
/// comparison every gate depends on. No network — `RecordingHTTP` replays fixture
/// responses transcribed from the spec.
final class VehicleSharingEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // MARK: - §7.5.1 create

    func testCreateInvitePostsLabelPermissionAndOmitsVehicleIdsForSingleVehicle() async throws {
        let (client, http) = client([.init(status: 201, body: try Fixture.data("rest/share_invite_created.json"))])

        let invite = try await client.createShareInvite(
            CreateShareInviteRequest(label: "Mira Chen", permission: .liveHistory),
            vehicleID: "clxyz1234567890abcdef"
        )

        XCTAssertEqual(invite.inviteId, "csh0123456789abcdef0123456789abcd")
        XCTAssertEqual(invite.status, .pending)
        XCTAssertEqual(invite.code, "RBO246", "a pending row carries the redeemable code")
        XCTAssertEqual(invite.expiresAt, "2026-08-05T15:04:05Z")
        XCTAssertNil(invite.acceptedAt, "acceptedAt is omitted while pending")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/vehicles/clxyz1234567890abcdef/invites")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["label"] as? String, "Mira Chen")
        XCTAssertEqual(json["permission"] as? String, "live_history")
        // §7.5.1: omitting `vehicleIds` is EXACTLY equivalent to `[<path vehicleId>]`.
        // Sending the degenerate one-element array would be noise on the wire.
        XCTAssertNil(json["vehicleIds"], "single-vehicle create omits the array entirely")
        // There is NO email anywhere in this contract.
        XCTAssertNil(json["email"])
    }

    func testMultiVehicleCreateSendsTheWholeSetIncludingThePathVehicle() async throws {
        let (client, http) = client([.init(status: 201, body: try Fixture.data("rest/share_invite_created.json"))])

        _ = try await client.createShareInvite(
            CreateShareInviteRequest(
                label: "Mira Chen",
                permission: .rides,
                vehicleIds: ["clxyz1234567890abcdef", "clxyz1234567890abcdeg"]
            ),
            vehicleID: "clxyz1234567890abcdef"
        )

        let requests = await http.capturedRequests()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any]
        )
        let ids = try XCTUnwrap(json["vehicleIds"] as? [String])
        // §7.5.1: a set that omits the vehicle in the URL is rejected 400 — the
        // path vehicle is what AUTHORIZES the call.
        XCTAssertTrue(ids.contains("clxyz1234567890abcdef"))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: - §7.5.2 list

    func testListUnwrapsTheInvitesEnvelopeAndKeepsCodeOnPendingRowsOnly() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/share_invites_list.json"))])

        let invites = try await client.shareInvites(vehicleID: "clxyz1234567890abcdef")

        XCTAssertEqual(invites.count, 2)
        let pending = try XCTUnwrap(invites.first { $0.status == .pending })
        let accepted = try XCTUnwrap(invites.first { $0.status == .accepted })
        XCTAssertEqual(pending.code, "RBO246")
        XCTAssertNotNil(pending.expiresAt)
        // §7.5.2 rule 3: the key is OMITTED on every accepted row. A client must
        // never expect to re-read the code of a grant that has been redeemed.
        XCTAssertNil(accepted.code)
        XCTAssertNil(accepted.expiresAt)
        XCTAssertEqual(accepted.acceptedAt, "2026-07-01T11:23:00Z")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/vehicles/clxyz1234567890abcdef/invites")
        // Unpaginated by contract — no cursor, no limit.
        XCTAssertNil(requests[0].url?.query)
    }

    /// §7.5.2 rule 1: the envelope is `invites`, deliberately NOT the `items`
    /// key of the cursor-paginated lists. A body using `items` must fail to
    /// decode rather than silently yield an empty list.
    func testItemsEnvelopeIsNotAcceptedForTheInviteList() async {
        let body = Data(#"{"items":[]}"#.utf8)
        let (client, _) = client([.init(status: 200, body: body)])
        do {
            _ = try await client.shareInvites(vehicleID: "veh")
            XCTFail("expected a decoding failure on the wrong envelope key")
        } catch let error as RestError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // MARK: - §7.5.3 delete

    /// The success is `204 No Content`. Routing it through the decoding pipeline
    /// would fail a zero-byte body with `RestError.decoding`, so this endpoint
    /// must discard the body — the same reason `registerPushDevice` does.
    func testRevokeSendsDeleteAndAcceptsAnEmpty204() async throws {
        let (client, http) = client([.init(status: 204, body: Data())])

        try await client.revokeShareInvite(inviteID: "csh0123456789abcdef0123456789abcd")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[0].url?.path, "/api/invites/csh0123456789abcdef0123456789abcd")
        XCTAssertNil(requests[0].httpBody)
    }

    /// §7.5.3: a 404 means the invite does not exist OR belongs to another owner
    /// — indistinguishably, so this endpoint is not an oracle for other people's
    /// invite ids. The caller folds it as a benign terminal state.
    func testRevoke404FoldsOntoTheGoneFlag() async {
        let (client, _) = client([.init(status: 404, body: try! Fixture.data("rest/error.not_found.json"))])
        do {
            try await client.revokeShareInvite(inviteID: "nope")
            XCTFail("expected an error on 404")
        } catch let error as RestError {
            XCTAssertTrue(error.isShareInviteGone)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // MARK: - §7.5.4 resend

    func testResendReturnsANewCodeOnTheSameInviteIdAndUnchangedCreatedAt() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/share_invite_resent.json"))])

        let updated = try await client.resendShareInvite(inviteID: "csh0123456789abcdef0123456789abcd")

        XCTAssertEqual(updated.code, "ZKQ913", "a resend MINTS A NEW CODE; the previous one is dead")
        XCTAssertEqual(updated.inviteId, "csh0123456789abcdef0123456789abcd", "the id is stable across a resend")
        XCTAssertEqual(
            updated.createdAt, "2026-07-29T15:04:05Z",
            "createdAt is NOT reset — the owner's 'sent {ago}' line still refers to the original send"
        )

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/invites/csh0123456789abcdef0123456789abcd/resend")
    }

    /// §7.5.4: pending-only. Re-opening an ACCEPTED grant for redemption by a
    /// different person would be a quiet transfer of access, so the server 409s.
    func testResendOnAnAcceptedInviteIsAConflict() async {
        let (client, _) = client([.init(status: 409, body: try! Fixture.data("rest/error.conflict.json"))])
        do {
            _ = try await client.resendShareInvite(inviteID: "csh")
            XCTFail("expected an error on 409")
        } catch let error as RestError {
            XCTAssertTrue(error.isShareInviteAlreadyAccepted)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // MARK: - §7.5.5 redeem

    func testRedeemPostsTheNormalizedCodeAndReturnsViewerMaskedVehicles() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/share_redeem.json"))])

        // Deliberately messy input — §7.5.5 says a code pasted with a stray space
        // or hyphen still works because BOTH sides normalize identically.
        let response = try await client.redeemShareInvite(code: " rbo-246 ")

        XCTAssertEqual(response.ownerFirstName, "Alex")
        XCTAssertEqual(response.vehicles.count, 1)
        let row = try XCTUnwrap(response.vehicles.first)
        XCTAssertEqual(row.role, .viewer)
        XCTAssertEqual(row.sharePermission, .rides)
        // MYR-184 fixed the viewer mask stripping `name`, which is `required` in
        // vehicle-summary.schema.json. The rider UI needs it to title the car.
        XCTAssertEqual(row.name, "Alex's Model 3")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/invites/redeem")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["code"] as? String, "RBO246", "upper-cased, non-[A-Z0-9] stripped")
    }

    /// The §7.5.5 catalog, folded onto the four answers the rider screen can act
    /// on. 400 and 404 stay DISTINCT ("you sent nonsense" vs "that code grants
    /// you nothing"); 404 stays ONE case covering unknown / expired / consumed,
    /// because the server answers all three identically on purpose.
    func testRedeemErrorCatalogFoldsOntoTheFourRiderAnswers() async throws {
        let cases: [(Int, ShareRedemptionFailure)] = [
            (400, .malformed),
            (404, .invalidOrExpired),
            (409, .alreadyHasAccess),
            (429, .tooManyAttempts),
            (500, .unavailable),
            (401, .unavailable),
        ]
        for (status, expected) in cases {
            let (client, _) = client([.init(status: status, body: Data(#"{"error":{"code":"x","message":"y"}}"#.utf8))])
            do {
                _ = try await client.redeemShareInvite(code: "RBO246")
                XCTFail("expected an error on \(status)")
            } catch let error as RestError {
                XCTAssertEqual(error.shareRedemptionFailure, expected, "status \(status)")
            } catch {
                XCTFail("expected RestError, got \(error)")
            }
        }
    }

    // MARK: - §7.5.0 cumulative tiers

    /// The tiers form a TOTAL ORDER and every gate compares with `>=`, never
    /// equality. `rides` grants history; `live` grants neither of the others.
    func testTierComparisonIsCumulativeNotEqual() {
        XCTAssertTrue(SharePermission.rides.grants(.live))
        XCTAssertTrue(SharePermission.rides.grants(.liveHistory))
        XCTAssertTrue(SharePermission.rides.grants(.rides))
        XCTAssertTrue(SharePermission.liveHistory.grants(.live))
        XCTAssertFalse(SharePermission.liveHistory.grants(.rides))
        XCTAssertTrue(SharePermission.live.grants(.live))
        XCTAssertFalse(SharePermission.live.grants(.liveHistory))
    }

    /// An UNRECOGNIZED tier (appended by a newer contracts version) fails CLOSED
    /// on both sides. It is by the contract's rule strictly higher than `rides`,
    /// but offering affordances on a tier this build cannot reason about is the
    /// guess that produces a 403 wall.
    func testUnrecognizedTierFailsClosed() {
        let future = SharePermission.unrecognized("full_control")
        XCTAssertFalse(future.grants(.live))
        XCTAssertFalse(SharePermission.rides.grants(future))
    }

    /// §7.0: an ABSENT `sharePermission` on a VIEWER row means the LOWEST tier —
    /// never full access, never fail open. On an OWNER row it means nothing at
    /// all (an owner is not on a tier), so the resolver reports nil.
    func testAbsentSharePermissionOnAViewerRowResolvesToTheLowestTier() throws {
        let response: VehicleListResponse = try JSONDecoder()
            .decode(VehicleListResponse.self, from: try Fixture.data("rest/vehicles_list_viewer.json"))
        var viewer = try XCTUnwrap(response.items.first)
        XCTAssertEqual(viewer.role, .viewer)
        XCTAssertEqual(viewer.effectiveSharePermission, .liveHistory, "the fixture's declared tier")

        viewer.sharePermission = nil
        XCTAssertEqual(viewer.effectiveSharePermission, .live, "absent means the LOWEST tier")
        XCTAssertFalse(
            (viewer.effectiveSharePermission ?? .live).grants(.rides),
            "absence must never be read as full access"
        )

        viewer.role = .owner
        XCTAssertNil(viewer.effectiveSharePermission, "an owner is not on a tier")
    }
}
