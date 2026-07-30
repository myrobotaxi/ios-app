import XCTest
@testable import MyRoboTaxiKit

/// REST-surface tests for the account's per-category push preferences (MYR-349,
/// rest-api.md §7.19): authenticated path assembly for both verbs, the PARTIAL
/// request body, the TOTAL five-key response, the echo the client must adopt, and
/// the error catalog folded through the typed `RestError`.
///
/// THE TESTS THAT MATTER MOST HERE ARE THE TWO ABOUT KEYS, and they exist because
/// of MYR-362. `VehicleServiceWindowResponse` shipped declaring a key §7.16 has
/// never emitted; every property on it was optional, so the body DECODED, cleanly,
/// to `nil` — no throw, no 4xx, no log. The stub and the fixture had been
/// hand-authored from the same misreading, so the suite stayed green about a body
/// the server never sends. The two guards that would have caught it are asserting
/// on the RAW fixture keys and decoding the spec's OWN printed example, so both
/// are written here before the fact rather than after it.
///
/// No network — the deterministic `RecordingHTTP` replays canonical fixtures.
final class PushPrefsEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    /// The five §7.19 keys, spelled out as STRING LITERALS on purpose. Deriving
    /// them from `PushPrefCategory.allCases` would make this assertion agree with
    /// the client's own naming by construction — which is precisely the failure
    /// mode MYR-362 was: every artefact agreeing with each other and none of them
    /// with the wire.
    private let wireKeys: Set<String> = [
        "rideLifecycle", "driveStarted", "driveCompleted", "chargingComplete", "viewerJoined",
    ]

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    // MARK: - The decode, against §7.19's own printed example

    // The spec prints exactly this object. It is decoded here as a LITERAL rather
    // than through the fixture, so the test still holds if the fixture is ever
    // edited — the two guards are deliberately independent of each other.
    func testTheSpecsPrintedExampleDecodes() throws {
        let json = #"{"rideLifecycle":true,"driveStarted":true,"driveCompleted":true,"chargingComplete":true,"viewerJoined":true}"#
        let prefs = try JSONDecoder().decode(PushPrefsResponse.self, from: Data(json.utf8))
        XCTAssertTrue(prefs.rideLifecycle)
        XCTAssertTrue(prefs.driveStarted)
        XCTAssertTrue(prefs.driveCompleted)
        XCTAssertTrue(prefs.chargingComplete)
        XCTAssertTrue(prefs.viewerJoined)
    }

    // A MISSING key must FAIL, loudly. This is the whole reason the five
    // properties are non-optional: on an optional, a renamed or dropped key
    // decodes to `nil` and the app renders a plausible default with every signal
    // it has saying the call worked (MYR-362, verbatim).
    func testAMissingKeyFailsTheDecodeRatherThanDefaulting() {
        let json = #"{"rideLifecycle":true,"driveStarted":true,"driveCompleted":true,"viewerJoined":true}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(PushPrefsResponse.self, from: Data(json.utf8)),
            "a body missing chargingComplete is not §7.19 and must not decode to a default"
        )
    }

    // The same rule from the other side: a MISSPELLED key is a missing key. A
    // client whose property was `chargingCompleted` would have decoded this to
    // nil-then-false and reported a successful save of a value nobody stored.
    func testAMisspelledKeyFailsTheDecode() {
        let json = #"{"rideLifecycle":true,"driveStarted":true,"driveCompleted":true,"chargingCompleted":true,"viewerJoined":true}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PushPrefsResponse.self, from: Data(json.utf8)))
    }

    // The RAW fixture keys are exactly the five camelCase strings §7.19 names.
    // A hand-authored fixture is evidence only to the extent it is the wire.
    func testTheFixturesCarryExactlyTheFiveWireKeys() throws {
        for name in ["rest/push_prefs.json", "rest/push_prefs_charging_off.json"] {
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Fixture.data(name)) as? [String: Any]
            )
            let keys = Set(json.keys).subtracting(["_meta"])
            XCTAssertEqual(keys, wireKeys, "\(name): §7.19 emits exactly these five keys")
            for key in wireKeys {
                XCTAssertNotNil(json[key] as? Bool, "\(name): \(key) is a JSON boolean, never a string or a number")
            }
        }
    }

    // MARK: - GET

    func testGetReadsTheAccountsFiveValues() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/push_prefs.json"))])

        let prefs = try await client.pushPrefs()
        XCTAssertEqual(
            prefs,
            PushPrefsResponse(
                rideLifecycle: true,
                driveStarted: true,
                driveCompleted: true,
                chargingComplete: true,
                viewerJoined: true
            ),
            "an account with nothing stored answers all-true — absence is never 'off'"
        )

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/users/me/push-prefs")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
        XCTAssertNil(requests[0].httpBody)
    }

    // MARK: - PUT

    // The body is PARTIAL — one changed toggle sends ONE key. The server strict-
    // decodes, so a struct that always emitted all five would 400 nothing today
    // and would still be lying about what the client changed.
    func testPutSendsOnlyTheChangedKeyAndReturnsTheTotalEcho() async throws {
        let (client, http) = client([
            .init(status: 200, body: try Fixture.data("rest/push_prefs_charging_off.json"))
        ])

        let echo = try await client.setPushPrefs(PushPrefsUpdateRequest(.chargingComplete, false))
        XCTAssertEqual(echo.chargingComplete, false)
        XCTAssertTrue(echo.rideLifecycle, "the PUT answers with ALL FIVE, re-read after the write")
        XCTAssertTrue(echo.driveStarted)
        XCTAssertTrue(echo.driveCompleted)
        XCTAssertTrue(echo.viewerJoined)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].url?.path, "/api/users/me/push-prefs")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["chargingComplete"], "a partial body carries only what changed")
        XCTAssertEqual(json["chargingComplete"] as? Bool, false)
    }

    // `false` is a VALUE, not an absence: it must travel as an explicit JSON
    // `false` on the one key being written, never be omitted into a `{}` that
    // §7.19 would read as "change nothing".
    func testTurningACategoryOffSendsAnExplicitFalse() async throws {
        let (client, http) = client([
            .init(status: 200, body: try Fixture.data("rest/push_prefs_charging_off.json"))
        ])
        _ = try await client.setPushPrefs(PushPrefsUpdateRequest(.chargingComplete, false))

        let requests = await http.capturedRequests()
        let raw = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertEqual(raw, #"{"chargingComplete":false}"#, "got \(raw)")
    }

    // Every category maps to its own key, both directions. A row bound to one
    // category writing another's key is a silent, plausible-looking bug that no
    // decode can catch — so the whole matrix is asserted.
    func testEveryCategoryWritesItsOwnKey() async throws {
        for category in PushPrefCategory.allCases {
            let (client, http) = client([
                .init(status: 200, body: try Fixture.data("rest/push_prefs.json"))
            ])
            _ = try await client.setPushPrefs(PushPrefsUpdateRequest(category, true))
            let requests = await http.capturedRequests()
            let body = try XCTUnwrap(requests[0].httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Array(json.keys), [category.rawValue])
            XCTAssertEqual(json[category.rawValue] as? Bool, true)
        }
    }

    // §7.19 accepts an EMPTY object as a plain read-after-write. The synthesized
    // encoder's nil-omission is what produces it, so this pins that behaviour
    // rather than assuming it.
    func testAnAllNilUpdateEncodesToAnEmptyObject() throws {
        let raw = String(decoding: try JSONEncoder().encode(PushPrefsUpdateRequest()), as: UTF8.self)
        XCTAssertEqual(raw, "{}")
    }

    // MARK: - Errors

    func testErrorCatalogFoldsOntoTypedOutcomes() async {
        let cases: [(status: Int, code: String, expected: RestError.CommandFailureKind)] = [
            (400, "invalid_request", .invalidRequest),
            (401, "auth_failed", .auth),
            (500, "internal_error", .other),
        ]
        for c in cases {
            let body = Data(#"{"error":{"code":"\#(c.code)","message":"nope"}}"#.utf8)
            // 401 retries once after the refresh hook, so stub it twice.
            let stubs = Array(repeating: RecordingHTTP.Stub(status: c.status, body: body), count: 2)
            let (client, _) = client(stubs)
            do {
                _ = try await client.setPushPrefs(PushPrefsUpdateRequest(.driveStarted, false))
                XCTFail("expected an error on \(c.status)")
            } catch let error as RestError {
                XCTAssertEqual(error.commandFailureKind, c.expected, "for \(c.code)")
            } catch {
                XCTFail("expected RestError for \(c.code), got \(error)")
            }
        }
    }

    // A failed write must NEVER resolve to a value a caller would trust. The
    // caller's rollback depends on this throwing: a `500` swallowed into a
    // plausible object would leave a toggle sitting in the position the user chose
    // over a server that holds the other one.
    func testAFailedWriteThrowsRatherThanAnsweringWithAPlausibleObject() async {
        let body = Data(#"{"error":{"code":"internal_error","message":"store failure"}}"#.utf8)
        let (client, _) = client([.init(status: 500, body: body)])
        do {
            _ = try await client.setPushPrefs(PushPrefsUpdateRequest(.chargingComplete, false))
            XCTFail("a failed write must not resolve to a value the caller would adopt")
        } catch let error as RestError {
            XCTAssertEqual(error.commandFailureKind, .other)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }

    // A failed GET is an honest state for the caller to render, not a default to
    // fall back on — the same rule, on the read side.
    func testAFailedReadThrows() async {
        let body = Data(#"{"error":{"code":"auth_failed","message":"nope"}}"#.utf8)
        let (client, _) = client([
            .init(status: 401, body: body),
            .init(status: 401, body: body),
        ])
        do {
            _ = try await client.pushPrefs()
            XCTFail("a failed read must not resolve to all-true")
        } catch let error as RestError {
            XCTAssertEqual(error.commandFailureKind, .auth)
        } catch {
            XCTFail("expected RestError, got \(error)")
        }
    }
}
