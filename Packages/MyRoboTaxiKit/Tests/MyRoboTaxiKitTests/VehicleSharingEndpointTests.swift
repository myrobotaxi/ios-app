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

    // MARK: - MYR-368 — `shareUrl`, the server-minted SIGNED join link

    /// The create response's link, decoded and compared BYTE FOR BYTE against the
    /// fixture's own string.
    ///
    /// It is asserted as one literal rather than by its parts because that is how
    /// it is used: `k` is an Ed25519 signature over `join:{code}:{exp}:{from}:{to}`
    /// and BOTH names are inside it, so a client that reassembled this URL from
    /// components — reordering the query, re-encoding it, dropping a parameter it
    /// had no use for — would produce a link the web join shell bounces. The only
    /// correct handling is to carry the whole string, so the only meaningful
    /// assertion is on the whole string.
    func testCreateSurfacesTheSignedShareUrlVerbatim() async throws {
        let (client, _) = client([.init(status: 201, body: try Fixture.data("rest/share_invite_created.json"))])

        let invite = try await client.createShareInvite(
            CreateShareInviteRequest(label: "Mira Chen", permission: .liveHistory),
            vehicleID: "clxyz1234567890abcdef"
        )

        XCTAssertEqual(
            invite.shareUrl,
            "https://myrobotaxi.app/join/RBO246?k=1.1785942245.mHRTPwZlrUFqzQ9k1p8O_5xkzXQ9dHTh5rHhNaeJ0OQz3n0XmL4vJ8ptKQC1cO8bZ5MPKB6h0nlFmVLbUqEQAg&from=Alex&to=Mira"
        )
        // The link CONTAINS the code, which is why it inherits the code's P1
        // classification whole rather than being treated as an ordinary URL.
        XCTAssertEqual(invite.code, "RBO246")
        XCTAssertTrue(try XCTUnwrap(invite.shareUrl).contains("RBO246"))
    }

    /// The contract's rule is that `shareUrl` is present EXACTLY WHERE `code` IS —
    /// so it is on the pending row and absent from the accepted one, for the same
    /// reason the code is: there is nothing left to redeem.
    func testTheListCarriesTheShareUrlOnPendingRowsOnly() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/share_invites_list.json"))])

        let invites = try await client.shareInvites(vehicleID: "clxyz1234567890abcdef")
        let pending = try XCTUnwrap(invites.first { $0.status == .pending })
        let accepted = try XCTUnwrap(invites.first { $0.status == .accepted })

        XCTAssertNotNil(pending.shareUrl)
        XCTAssertEqual(pending.shareUrl?.contains("/join/RBO246"), true)
        XCTAssertNil(accepted.shareUrl, "no code, no link — the two travel together")
        XCTAssertNil(accepted.code)
    }

    /// A resend RE-SIGNS. The new code and the new expiry produce a whole new URL,
    /// which is what makes "the previous link stops redeeming" true of the LINK
    /// and not just of the six characters inside it.
    func testAResendMintsAWholeNewSignedLink() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/share_invite_resent.json"))])

        let updated = try await client.resendShareInvite(inviteID: "csh0123456789abcdef0123456789abcd")
        let url = try XCTUnwrap(updated.shareUrl)

        XCTAssertTrue(url.contains("/join/ZKQ913"), "the new code is in the new link")
        XCTAssertFalse(url.contains("RBO246"), "the dead code is not")
        // The `k` expiry is `expiresAt` in a different encoding — the contract
        // requires the two to agree, and a client finding them disagreeing must
        // trust `expiresAt`.
        XCTAssertEqual(updated.expiresAt, "2026-08-06T09:00:00Z")
        XCTAssertTrue(url.contains("k=1.1786006800."), "1786006800 == 2026-08-06T09:00:00Z")
    }

    /// THE FALLBACK CASE, and the reason it needs a fixture of its own.
    ///
    /// `shareUrl` is optional, so a server that predates 0.22.0 — every deployed
    /// server the day before this issue — answers with the key simply not there,
    /// and it decodes to `nil` without a throw, a 4xx or a log. That is not a
    /// defect to guard against; the contract instructs the consumer to fall back.
    /// What this pins is that the ABSENCE is what reaches the client, so the
    /// decision is made on a real `nil` rather than on a value nobody looked at.
    func testAServerThatPredatesTheFieldDecodesToNilRatherThanFailing() async throws {
        let (client, _) = client([.init(status: 201, body: try Fixture.data("rest/share_invite_created_legacy.json"))])

        let invite = try await client.createShareInvite(
            CreateShareInviteRequest(label: "Mira Chen", permission: .liveHistory),
            vehicleID: "clxyz1234567890abcdef"
        )

        XCTAssertNil(invite.shareUrl, "absent means absent — the client composes its own link")
        XCTAssertEqual(invite.code, "RBO246", "everything else about the row is unchanged")
        XCTAssertEqual(invite.status, .pending)
    }

    /// The fixtures are evidence only to the extent they ARE the wire, so the raw
    /// bytes are checked for the key itself — the MYR-362 lesson, where a
    /// hand-authored fixture agreed with an invented key on an optional property
    /// and kept a whole suite green about a body the server never sends.
    func testTheFixturesCarryTheContractsOwnKeyName() throws {
        let signed = try JSONSerialization.jsonObject(
            with: try Fixture.data("rest/share_invite_created.json")
        ) as? [String: Any]
        XCTAssertNotNil(signed?["shareUrl"], "the key is `shareUrl`, not `share_url` or `url`")

        let legacy = try JSONSerialization.jsonObject(
            with: try Fixture.data("rest/share_invite_created_legacy.json")
        ) as? [String: Any]
        XCTAssertNil(legacy?["shareUrl"], "the pre-0.22.0 fixture must genuinely omit the key")
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

    // MARK: - §7.5.0 capability reads (rewritten by MYR-369)

    /// **THE CUMULATIVE COMPARISON IS GONE, AND ITS REPLACEMENT IS EQUALITY.**
    ///
    /// This class previously asserted `SharePermission.rides.grants(.liveHistory)`
    /// and the rest of a total order — correct for the contract it was written
    /// against, and wrong for 0.23.0, which states that on an accepted row the
    /// value is DERIVED from per-grant flags and that the `>=` comparison "is
    /// WRONG on an accepted row and MUST be replaced by a direct read of the
    /// flags". `rank`/`grants(_:)` are deleted rather than deprecated, so this is
    /// the test that would stop them coming back.
    func testTheRideCapabilityIsAnEqualityReadNotACumulativeOne() {
        XCTAssertTrue(SharePermission.rides.allowsRides)
        XCTAssertFalse(SharePermission.live.allowsRides)
    }

    /// `live_history` is RETIRED AND NEVER EMITTED, but the member survives for
    /// wire compat. It must still DECODE, and it must not be read as granting
    /// rides — under the old order it did not either, but it got there by ranking
    /// below `rides` rather than by being a value nothing emits.
    func testTheRetiredHistoryTierStillDecodesAndGrantsNoRides() throws {
        let decoded = try JSONDecoder().decode(
            SharePermission.self, from: Data("\"live_history\"".utf8)
        )
        XCTAssertEqual(decoded, .liveHistory, "the enum member is kept for decode compat")
        XCTAssertEqual(decoded.rawValue, "live_history")
        XCTAssertFalse(decoded.allowsRides)
    }

    /// An UNRECOGNIZED value (appended by a newer contracts version) fails CLOSED.
    /// Offering affordances on a capability this build cannot reason about is the
    /// guess that produces a 403 wall.
    func testUnrecognizedTierFailsClosed() {
        XCTAssertFalse(SharePermission.unrecognized("full_control").allowsRides)
    }

    // MARK: - Per-grant flags and their TWO different absence rules (MYR-369)

    /// The rule most likely to be swapped by a tidy refactor: the two optional
    /// flags fall back in OPPOSITE directions. An absent `allowRides` defers to
    /// the derived `permission`; an absent `suspended` is NOT suspension.
    func testTheTwoFlagsFallBackInOppositeDirections() throws {
        let response = try JSONDecoder().decode(
            ShareInviteListResponse.self,
            from: try Fixture.data("rest/share_invites_list.json")
        )
        // This fixture is now the PRE-0.23.0 server: neither key is on any row.
        let accepted = try XCTUnwrap(response.invites.first { $0.status == .accepted })
        XCTAssertNil(accepted.allowRides, "the legacy fixture carries no flag")
        XCTAssertNil(accepted.suspended)
        XCTAssertFalse(accepted.allowsRides, "falls back to permission `live` → no rides")
        XCTAssertFalse(accepted.isSuspended, "ABSENCE IS NEVER SUSPENSION")

        // And the fallback follows the permission rather than defaulting to false.
        var promoted = accepted
        promoted.permission = .rides
        XCTAssertTrue(promoted.allowsRides, "absent allowRides falls back to `rides` → true")
    }

    /// A 0.23.0 row: the flags are present and are the truth, and `permission`
    /// agrees with them because the server derives it on every read.
    func testAcceptedRowsCarryBothFlagsAndTheDerivedPermissionAgrees() throws {
        let response = try JSONDecoder().decode(
            ShareInviteListResponse.self,
            from: try Fixture.data("rest/share_invites_list_flags.json")
        )
        let accepted = response.invites.filter { $0.status == .accepted }
        XCTAssertEqual(accepted.count, 3)
        for row in accepted {
            XCTAssertNotNil(row.allowRides, "\(row.label): accepted rows carry the flag")
            XCTAssertNotNil(row.suspended, "\(row.label)")
            XCTAssertEqual(
                row.permission.allowsRides, row.allowsRides,
                "\(row.label): `permission` is DERIVED from allowRides, so it cannot disagree"
            )
        }

        // The state the contract is most specific about: suspended WITH the ride
        // flag still set. The flag survives, and it grants nothing while paused.
        let paused = try XCTUnwrap(accepted.first { $0.isSuspended })
        XCTAssertEqual(paused.label, "Aanya Iyer")
        XCTAssertTrue(paused.allowsRides, "the stored flag survives suspension")
    }

    // MARK: - Raw-key assertions (the MYR-362 decode trap, pointed at MYR-369)
    //
    // `allowRides` and `suspended` are OPTIONAL BOOLS. A wrong key on an optional
    // decodes SILENTLY to nil — no throw, no 4xx, no log — which is exactly how
    // MYR-362 shipped an empty service-window row over a `200`. Worse here: nil
    // on `suspended` reads as NOT SUSPENDED, so a mis-keyed fixture would show a
    // paused viewer as having full access and every decode test would pass. The
    // only guard that works is asserting on the RAW keys.

    /// The keys are exactly where the schema says, and — the half a decode can
    /// never check — ABSENT where it says they must be. Both flags are
    /// ACCEPTED-ROWS-ONLY: a pending invite has no grant yet, so a pending row
    /// carrying either would be describing access that does not exist.
    func testTheFlagsAreOnAcceptedRowsAndAbsentFromPendingOnes() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try Fixture.data("rest/share_invites_list_flags.json")
            ) as? [String: Any]
        )
        let invites = try XCTUnwrap(json["invites"] as? [[String: Any]])

        for row in invites {
            let status = row["status"] as? String
            let label = (row["label"] as? String) ?? "?"
            if status == "accepted" {
                XCTAssertNotNil(row["allowRides"], "\(label): §7.5.2 emits allowRides on accepted rows")
                XCTAssertNotNil(row["suspended"], "\(label): and suspended alongside it")
                XCTAssertNil(row["code"], "\(label): the code is spent on redemption")
                XCTAssertNil(row["shareUrl"], "\(label): the link goes with the code")
            } else {
                XCTAssertNil(row["allowRides"], "\(label): a PENDING row has no grant to describe")
                XCTAssertNil(row["suspended"], "\(label): ditto — absence here is the contract, not an oversight")
            }
        }

        // `live_history` is retired and NEVER emitted. A fixture that carried one
        // would be modelling a server that no longer exists.
        let permissions = invites.compactMap { $0["permission"] as? String }
        XCTAssertFalse(permissions.contains("live_history"), "the tier is retired")
        XCTAssertTrue(Set(permissions).isSubset(of: ["live", "rides"]))
    }

    /// The PATCH response fixture, against the contract's own sentence about it:
    /// an accepted row carrying both flags and the derived permission, and
    /// carrying NEITHER `code` NOR `shareUrl`.
    func testThePatchResponseFixtureIsAnAcceptedRowWithNoLiveCredential() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try Fixture.data("rest/share_invite_patched.json")
            ) as? [String: Any]
        )
        XCTAssertEqual(json["status"] as? String, "accepted")
        XCTAssertNotNil(json["allowRides"])
        XCTAssertNotNil(json["suspended"])
        XCTAssertNil(json["code"], "a redeemed grant has no live code to hand back")
        XCTAssertNil(json["shareUrl"], "and no link, which contains one")

        let decoded = try JSONDecoder().decode(
            ShareInvite.self, from: try Fixture.data("rest/share_invite_patched.json")
        )
        XCTAssertTrue(decoded.isSuspended)
        XCTAssertTrue(decoded.allowsRides, "a partial update did not clear what it did not touch")
    }

    /// **THE FIXTURES ARE PINNED AGAINST THE GENERATED TYPES, NOT AGAINST MY
    /// READING OF THE SPEC.** Every key a fixture uses is round-tripped through
    /// the contracts type it stands for, so a fixture key that codegen does not
    /// produce fails here rather than decoding quietly to nil. This is the guard
    /// MYR-362 did not have: its hand-authored response type and its fixture were
    /// written from the same misreading, so they agreed with each other and the
    /// suite was green about a body the server never sends.
    func testEveryFixtureKeyIsAKeyTheGeneratedTypeProduces() throws {
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(
            ShareInviteListResponse.self,
            from: try Fixture.data("rest/share_invites_list_flags.json")
        )
        for row in decoded.invites {
            let reEncoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try encoder.encode(row)) as? [String: Any]
            )
            let fixtureKeys: Set<String> = Set(
                (try fixtureRow(labelled: row.label) ?? [:]).keys
            )
            XCTAssertTrue(
                fixtureKeys.isSubset(of: Set(reEncoded.keys)),
                "\(row.label): fixture keys \(fixtureKeys.subtracting(Set(reEncoded.keys))) "
                    + "are not produced by the generated ShareInvite"
            )
        }
    }

    private func fixtureRow(labelled label: String) throws -> [String: Any]? {
        let json = try JSONSerialization.jsonObject(
            with: try Fixture.data("rest/share_invites_list_flags.json")
        ) as? [String: Any]
        let invites = json?["invites"] as? [[String: Any]]
        return invites?.first { ($0["label"] as? String) == label }
    }

    // MARK: - The PATCH body (MYR-369)

    /// **PARTIAL BY DESIGN.** `JSONEncoder` omits `nil`, and that omission IS the
    /// contract's update semantics — an absent property leaves the capability
    /// unchanged and is NOT the same as sending `false`. So a body built to edit
    /// ONE flag must encode exactly ONE key. A client that filled in both would
    /// overwrite a capability the owner never touched, with whatever it last
    /// read — a silent unintended edit that answers `200`.
    func testAPartialPatchBodyEncodesExactlyTheKeysItSets() throws {
        func keys(_ body: PatchShareInviteRequest) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(body))
            return Set(((object as? [String: Any]) ?? [:]).keys)
        }
        XCTAssertEqual(try keys(PatchShareInviteRequest(allowRides: true)), ["allowRides"])
        XCTAssertEqual(try keys(PatchShareInviteRequest(suspended: true)), ["suspended"])
        // `false` is a VALUE and must travel; only nil is omitted.
        XCTAssertEqual(try keys(PatchShareInviteRequest(allowRides: false)), ["allowRides"])
        XCTAssertEqual(
            try keys(PatchShareInviteRequest(allowRides: true, suspended: false)),
            ["allowRides", "suspended"]
        )
        // `minProperties: 1` — an empty body is a 400 by contract, so a client
        // that builds one has a bug. Nothing stops it compiling; this names it.
        XCTAssertTrue(try keys(PatchShareInviteRequest()).isEmpty)
    }

    /// The RAW key spellings on the wire, asserted against the literal strings
    /// the schema prints. Both properties are optional bools, so a typo here is
    /// invisible to every decode test in this file.
    func testThePatchBodyUsesTheSchemasOwnKeySpellings() throws {
        let data = try JSONEncoder().encode(
            PatchShareInviteRequest(allowRides: true, suspended: false)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["allowRides"] as? Bool, true)
        XCTAssertEqual(json["suspended"] as? Bool, false)
        // The names this client must NOT invent — the MYR-362 shape, where a
        // plausible-looking synonym decodes to nil and nothing anywhere says so.
        for wrong in ["allow_rides", "allowRide", "ridesAllowed", "isSuspended", "suspend"] {
            XCTAssertNil(json[wrong], "\(wrong) is not a key §7.5 emits or accepts")
        }
    }

    /// §7.0: an ABSENT `sharePermission` on a VIEWER row means the LOWEST tier —
    /// never full access, never fail open. On an OWNER row it means nothing at
    /// all (an owner is not on a tier), so the resolver reports nil.
    func testAbsentSharePermissionOnAViewerRowResolvesToTheLowestTier() throws {
        let response: VehicleListResponse = try JSONDecoder()
            .decode(VehicleListResponse.self, from: try Fixture.data("rest/vehicles_list_viewer.json"))
        var viewer = try XCTUnwrap(response.items.first)
        XCTAssertEqual(viewer.role, .viewer)

        viewer.sharePermission = nil
        XCTAssertEqual(viewer.effectiveSharePermission, .live, "absent means the LOWEST tier")
        XCTAssertFalse(
            (viewer.effectiveSharePermission ?? .live).allowsRides,
            "absence must never be read as full access"
        )

        viewer.role = .owner
        XCTAssertNil(viewer.effectiveSharePermission, "an owner is not on a tier")
    }
}
