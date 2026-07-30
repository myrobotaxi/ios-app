import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for the owner on-demand refresh endpoint (rest-api.md
/// §7.15 — MYR-315): authenticated POST path assembly, BOTH 200 statuses decoded
/// off the canonical fixtures, tolerant status decoding, RFC3339 parsing in both
/// emitted shapes, and the §7.15 error catalog folded through the typed
/// `RestError`. No network — the deterministic `RecordingHTTP` replays fixtures.
final class VehicleRefreshEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // §7.15 — the authenticated POST lands on
    // /api/tesla/vehicles/{id}/refresh with NO body, and the `fresh` (no-op)
    // outcome decodes as a SUCCESS carrying the existing read time.
    func testFreshStatusDecodesAsSuccessWithExistingReadTime() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_refresh_fresh.json"))])

        let response = try await client.refreshVehicle(id: "clxyz1234567890abcdef")

        XCTAssertEqual(response.status, .fresh)
        XCTAssertFalse(response.status.didWake, "`fresh` is a deliberate no-op — never claim a wake happened")
        XCTAssertEqual(
            response.lastUpdated,
            ISO8601DateFormatter().date(from: "2026-07-27T16:04:12Z")
        )

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/tesla/vehicles/clxyz1234567890abcdef/refresh")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertNil(requests[0].httpBody, "§7.15 takes no request body")
    }

    // §7.15 — the `refreshed` outcome, whose fixture carries FRACTIONAL seconds.
    // `ISO8601DateFormatter` refuses a fractional timestamp unless the option is
    // set, so a single-format parser would drop the timestamp on precisely the
    // path that produced a new read.
    func testRefreshedStatusDecodesAndParsesFractionalTimestamp() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_refresh_refreshed.json"))])

        let response = try await client.refreshVehicle(id: "veh")

        XCTAssertEqual(response.status, .refreshed)
        XCTAssertTrue(response.status.didWake)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(response.lastUpdated, fractional.date(from: "2026-07-27T16:09:48.512Z"))
    }

    // Forward compatibility: a status this build doesn't know must NOT fail the
    // decode — the call still returned 200 with an authoritative read time, and a
    // shipped client that threw here would turn a server-side addition into a
    // client-side outage. It is preserved verbatim and reported as "no wake".
    func testUnrecognizedStatusIsToleratedRatherThanThrown() async throws {
        let body = Data(#"{"status":"queued","lastUpdated":"2026-07-27T16:04:12Z"}"#.utf8)
        let (client, _) = client([.init(status: 200, body: body)])

        let response = try await client.refreshVehicle(id: "veh")

        XCTAssertEqual(response.status, .unrecognized("queued"))
        XCTAssertEqual(response.status.rawValue, "queued", "the raw value survives round-trip")
        XCTAssertFalse(response.status.didWake, "only `refreshed` proves a wake")
    }

    // A malformed timestamp is a genuine contract violation and MUST throw — the
    // alternative (defaulting to `Date()`) would fabricate a freshness claim,
    // which is exactly the dishonesty this stamp exists to prevent.
    func testMalformedTimestampThrowsRatherThanFabricatingFreshness() async {
        let body = Data(#"{"status":"refreshed","lastUpdated":"whenever"}"#.utf8)
        let (client, _) = client([.init(status: 200, body: body)])
        do {
            _ = try await client.refreshVehicle(id: "veh")
            XCTFail("expected a decoding failure on a non-RFC3339 timestamp")
        } catch let error as RestError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // §7.15 — 503 `vehicle_asleep` is the wake-budget-exhausted case: the car did
    // NOT come up. It folds onto the SAME typed outcome the §7.9 command catalog
    // already defines, so the app reuses the MYR-301 asleep copy instead of
    // inventing a second vocabulary for the same physical situation.
    func testVehicleAsleepFoldsOntoTypedAsleepOutcome() async {
        let body = Data(#"{"error":{"code":"vehicle_asleep","message":"vehicle did not wake"}}"#.utf8)
        let (client, _) = client([.init(status: 503, body: body)])
        do {
            _ = try await client.refreshVehicle(id: "veh")
            XCTFail("expected an error on 503")
        } catch let error as RestError {
            XCTAssertEqual(error.commandFailureKind, .vehicleAsleep)
            XCTAssertEqual(error.httpStatus, 503)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // §7.15 — 429 `rate_limited` is the per-vehicle ~60s cooldown. Distinct from
    // asleep: the car may be perfectly awake; we simply asked too soon. Never
    // auto-retried (a retry inside the window just 429s again).
    func testRateLimitedFoldsOntoTypedCooldownOutcome() async {
        let body = Data(#"{"error":{"code":"rate_limited","message":"try again shortly"}}"#.utf8)
        let (client, _) = client([.init(status: 429, body: body)])
        do {
            _ = try await client.refreshVehicle(id: "veh")
            XCTFail("expected an error on 429")
        } catch let error as RestError {
            XCTAssertEqual(error.commandFailureKind, .rateLimited)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // The standard auth/ownership catalog. 404 is deliberately indistinguishable
    // from ownership-filtered (matches §7.12/§7.14) — it must not read as
    // "not owned".
    func testStandardErrorCatalogFoldsOntoTypedOutcomes() async {
        let cases: [(status: Int, code: String, expected: RestError.CommandFailureKind)] = [
            (401, "auth_failed", .auth),
            (403, "vehicle_not_owned", .notOwned),
            (404, "not_found", .notFound),
            (500, "internal_error", .other),
        ]
        for c in cases {
            let body = Data(#"{"error":{"code":"\#(c.code)","message":"nope"}}"#.utf8)
            // 401 retries once after the refresh hook, so stub it twice.
            let stubs = Array(repeating: RecordingHTTP.Stub(status: c.status, body: body), count: 2)
            let (client, _) = client(stubs)
            do {
                _ = try await client.refreshVehicle(id: "veh")
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.commandFailureKind, c.expected, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // MYR-315 — the STATE is not in the §7.15 body, so the refreshed read only
    // reaches the UI if it is re-fetched down the normal snapshot path. The socket
    // exposes exactly that, and it must emit on the SUBSCRIBED vehicle's stream
    // (the same event a reconnect produces) rather than a parallel channel.
    func testRefreshSnapshotEmitsOnTheSubscribedVehiclesStream() async throws {
        let source = StubSnapshotSource(state: try Fixture.state("rest/snapshot.json"))
        let socket = makeSocket(source: source)
        let events = await socket.subscribe(to: "clxyz1234567890abcdef")

        await socket.refreshSnapshot(vehicleId: "clxyz1234567890abcdef")

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        guard case .snapshot(let state, _)? = event else {
            return XCTFail("expected a .snapshot event, got \(String(describing: event))")
        }
        XCTAssertEqual(state.vehicleId, "clxyz1234567890abcdef")
        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 1)

        await socket.disconnect()
    }

    // A vehicle nobody is watching has no stream to emit on, so the refresh must
    // not spend a request to update nothing.
    func testRefreshSnapshotIsANoOpForAnUnsubscribedVehicle() async throws {
        let source = StubSnapshotSource(state: try Fixture.state("rest/snapshot.json"))
        let socket = makeSocket(source: source)

        await socket.refreshSnapshot(vehicleId: "never-subscribed")

        let callCount = await source.callCount()
        XCTAssertEqual(callCount, 0, "an unwatched vehicle must not cost a request")
        await socket.disconnect()
    }

    /// A socket that never dials: the refresh path under test is REST + event
    /// emission, so the channel is only here to satisfy the dependency.
    private func makeSocket(source: StubSnapshotSource) -> TelemetrySocket {
        TelemetrySocket(
            webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
            tokenProvider: StaticTokenProvider("tkn"),
            snapshotSource: source,
            channelFactory: MockChannelFactory([MockWebSocketChannel(label: 0)])
        )
    }
}

private extension Fixture {
    /// The canonical §7.1 snapshot fixture, decoded into the contracts type.
    static func state(_ relativePath: String) throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try data(relativePath))
    }
}
