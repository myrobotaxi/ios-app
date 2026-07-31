import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// REST-surface tests for the schedule-picker conflict read (MYR-385, §7.22):
/// path + query assembly, the UTC-`Z` instant encoding, the envelope decode, the
/// empty-list case, the error catalog, and the `time_conflict` sub-code the
/// create-side refusal carries.
///
/// **THE RAW-KEY CROSS-PIN IS THE POINT OF THIS FILE** (the MYR-362 lesson,
/// pointed forwards). `BookedWindow` is generated, so this client cannot get a key
/// wrong the way MYR-362's hand-authored `VehicleServiceWindowResponse` did — but
/// a FIXTURE still can, and a fixture is only evidence to the extent it is the
/// wire. `start`/`end`/`pending`/`own` are all REQUIRED here, so a mis-keyed
/// fixture would at least throw; the two BOOLEANS are the ones that matter most,
/// because reading them wrongly is silent in exactly the MYR-362 way — a window
/// mis-read as `pending: false` says the untrue "booked" about a merely contested
/// slot, and one mis-read as `own: false` tells a rider "that car is booked" about
/// their own noon reservation, which is precisely the r15 report. So the fixture's
/// RAW JSON keys are asserted against what the GENERATED type produces, and the
/// contract's own printed example is decoded to the expected VALUES.
///
/// No network — the deterministic `RecordingHTTP` replays canonical fixtures.
final class VehicleBookedWindowsEndpointTests: XCTestCase {
    private let devEnvironment = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    private func client(_ stubs: [RecordingHTTP.Stub]) -> (RestClient, RecordingHTTP) {
        let http = RecordingHTTP(stubs)
        return (RestClient(environment: devEnvironment, tokenProvider: StaticTokenProvider("tkn"), http: http), http)
    }

    private static func instant(_ value: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)!
    }

    // MARK: - The happy path

    // §7.22's own printed example, decoded through the GENERATED envelope. Both
    // items are asserted field by field, because every one of the four is a fact a
    // picker renders or words itself with.
    func testBookedWindowsDecodesTheContractsPrintedExample() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_booked_windows.json"))])

        let response = try await client.bookedWindows(
            vehicleID: "clxyz1234567890abcdef",
            from: Self.instant("2026-08-01T00:00:00Z"),
            to: Self.instant("2026-08-08T00:00:00Z")
        )

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(
            response.items[0],
            BookedWindow(start: "2026-08-01T11:15:00Z", end: "2026-08-01T12:45:00Z", pending: true, own: false)
        )
        XCTAssertEqual(
            response.items[1],
            BookedWindow(start: "2026-08-01T18:15:00Z", end: "2026-08-01T19:45:00Z", pending: false, own: true)
        )

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/vehicles/clxyz1234567890abcdef/booked-windows")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
    }

    // The bounds travel as UTC `Z`, and that is a correctness property rather than
    // a style choice: §7.22 warns that a literal `+` in an RFC 3339 numeric offset
    // decodes to a SPACE server-side and the value then arrives unparseable
    // (`400`), and `URLComponents` does NOT percent-encode `+` in a query value.
    // Taking `Date`s and formatting them here is what makes that unreachable.
    func testTheRangeTravelsAsUTCZuluAndNeverAsANumericOffset() async throws {
        let (client, http) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_booked_windows_empty.json"))])

        // An instant that a device in, say, Berlin would naturally render as
        // "2026-08-01T02:00:00+02:00" — the exact shape that breaks on the wire.
        _ = try await client.bookedWindows(
            vehicleID: "veh_1",
            from: Self.instant("2026-08-01T00:00:00Z"),
            to: Self.instant("2026-08-08T00:00:00Z")
        )

        let requests = await http.capturedRequests()
        let query = URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let from = try XCTUnwrap(query.first { $0.name == "from" }?.value)
        let to = try XCTUnwrap(query.first { $0.name == "to" }?.value)
        XCTAssertEqual(from, "2026-08-01T00:00:00Z")
        XCTAssertEqual(to, "2026-08-08T00:00:00Z")
        XCTAssertFalse(from.contains("+"), "a literal + decodes to a space server-side and is a 400")
        XCTAssertFalse(to.contains("+"))

        // And the raw query string carries no unescaped `+` either — the check the
        // URLQueryItem assertion above cannot make on its own.
        let raw = try XCTUnwrap(requests[0].url?.query)
        XCTAssertFalse(raw.contains("+"))
    }

    // §7.22: an EMPTY array (never null) is the common case and MUST render as an
    // unrestricted picker — never as an error and never as a loading state. It is
    // also NOT "the car is wide open": the endpoint deliberately does not consult
    // the §7.18 pause or the §7.16 service window, so those gates stay separate.
    func testAnEmptyItemsArrayDecodesAsAnEmptyListRatherThanAFailure() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_booked_windows_empty.json"))])

        let response = try await client.bookedWindows(
            vehicleID: "veh_1",
            from: Self.instant("2026-08-01T00:00:00Z"),
            to: Self.instant("2026-08-08T00:00:00Z")
        )

        XCTAssertTrue(response.items.isEmpty)
    }

    // MARK: - The MYR-362 cross-pin

    // The FIXTURE's raw keys, asserted against the keys the GENERATED type
    // actually produces. MYR-362's suite was green about a body the server never
    // sends precisely because its hand-authored type and its hand-authored fixture
    // were written from the same misreading and agreed with each other; comparing
    // the fixture to the generated ENCODER is the check that has no such blind
    // spot.
    func testTheFixtureKeysAreExactlyTheKeysTheGeneratedTypeProduces() throws {
        let generated = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(
                VehicleBookedWindowsResponse(items: [
                    BookedWindow(start: "2026-08-01T11:15:00Z", end: "2026-08-01T12:45:00Z", pending: true, own: false)
                ])
            )
        ) as? [String: Any]
        let envelopeKeys = Set(try XCTUnwrap(generated).keys)
        let windowKeys = Set(
            try XCTUnwrap((try XCTUnwrap(generated)["items"] as? [[String: Any]])?.first).keys
        )

        XCTAssertEqual(envelopeKeys, ["items"], "the envelope IS the contract — no cursor, no hasMore")
        XCTAssertEqual(windowKeys, ["start", "end", "pending", "own"])

        for name in ["rest/vehicle_booked_windows.json", "rest/vehicle_booked_windows_empty.json"] {
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Fixture.data(name)) as? [String: Any]
            )
            XCTAssertEqual(Set(json.keys), envelopeKeys, "\(name): envelope keys drifted from the generated type")
            for item in try XCTUnwrap(json["items"] as? [[String: Any]]) {
                XCTAssertEqual(Set(item.keys), windowKeys, "\(name): window keys drifted from the generated type")
            }
        }
    }

    // The other half of the cross-pin: the fixture's raw VALUES, read straight out
    // of the JSON rather than through the decoder, must be the values the decode
    // produced above. `pending` and `own` are the two that matter — both are plain
    // booleans a picker words itself with, and getting either backwards is silent.
    func testTheFixtureRawValuesAreWhatTheDecodeProduced() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Fixture.data("rest/vehicle_booked_windows.json")) as? [String: Any]
        )
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)

        XCTAssertEqual(items[0]["start"] as? String, "2026-08-01T11:15:00Z")
        XCTAssertEqual(items[0]["end"] as? String, "2026-08-01T12:45:00Z")
        XCTAssertEqual(items[0]["pending"] as? Bool, true, "a still-undecided claim says 'requested', not 'booked'")
        XCTAssertEqual(items[0]["own"] as? Bool, false)

        XCTAssertEqual(items[1]["start"] as? String, "2026-08-01T18:15:00Z")
        XCTAssertEqual(items[1]["end"] as? String, "2026-08-01T19:45:00Z")
        XCTAssertEqual(items[1]["pending"] as? Bool, false)
        XCTAssertEqual(items[1]["own"] as? Bool, true, "the r15 report was a rider colliding with their OWN ride")
    }

    // Every window spans exactly twice the server's half-width, identical across
    // the response — the property that says the server RESOLVED the constant for
    // us. Asserted as a relationship rather than as 90 minutes: the half-width is a
    // product guess the server may move, and a client that pinned the number would
    // be the client §7.22 exists to make impossible.
    func testEveryWindowInOneResponseHasTheSameWidth() async throws {
        let (client, _) = client([.init(status: 200, body: try Fixture.data("rest/vehicle_booked_windows.json"))])
        let response = try await client.bookedWindows(
            vehicleID: "veh_1",
            from: Self.instant("2026-08-01T00:00:00Z"),
            to: Self.instant("2026-08-08T00:00:00Z")
        )

        let widths = Set(response.items.map { Self.instant($0.end).timeIntervalSince(Self.instant($0.start)) })
        XCTAssertEqual(widths.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(widths.first), 0, "`end` is always strictly after `start`")
    }

    // MARK: - Errors

    // §7.22 validates rather than clamping: a span past the 14-day cap, `from ==
    // to` and `from > to` are all `400 invalid_request`. Surfaced as the typed
    // error so a caller degrades rather than rendering a partial answer as whole.
    func testAnOverlongRangeSurfacesTheTypedInvalidRequest() async throws {
        let (client, _) = client([.init(status: 400, body: try Fixture.data("rest/error.invalid_request.json"))])

        do {
            _ = try await client.bookedWindows(
                vehicleID: "veh_1",
                from: Self.instant("2026-08-01T00:00:00Z"),
                to: Self.instant("2026-09-01T00:00:00Z")
            )
            XCTFail("expected a 400")
        } catch let error as RestError {
            XCTAssertEqual(error.httpStatus, 400)
            guard case .http(_, let code, _, _) = error else { return XCTFail("expected .http") }
            XCTAssertEqual(code?.rawValue, "invalid_request")
        }
    }

    // Authorization is the ride-create gate byte for byte, so a caller a create
    // would refuse is refused here too — the endpoint is never an oracle.
    func testANonRidesViewerIsRefusedExactlyAsACreateWouldRefuseThem() async throws {
        let (client, _) = client([.init(status: 403, body: Data(#"{"error":{"code":"vehicle_not_owned","message":"no"}}"#.utf8))])

        do {
            _ = try await client.bookedWindows(
                vehicleID: "veh_1",
                from: Self.instant("2026-08-01T00:00:00Z"),
                to: Self.instant("2026-08-08T00:00:00Z")
            )
            XCTFail("expected a 403")
        } catch let error as RestError {
            XCTAssertEqual(error.httpStatus, 403)
        }
    }

    // MARK: - The create-side refusal this read exists to pre-empt

    // MYR-383's `409 vehicle_unavailable` + `subCode: time_conflict`, folded to the
    // typed predicates. `isTimeConflict` is a STRICT NARROWING of
    // `isVehicleUnavailable`, so MYR-233's existing routing keeps firing unchanged
    // and only the copy gets to be more specific.
    func testTheTimeConflictRefusalIsBothVehicleUnavailableAndTimeConflict() async throws {
        let (client, _) = client([.init(status: 409, body: try Fixture.data("rest/error.time_conflict.json"))])

        do {
            _ = try await client.createRideRequest(
                RideRequestCreateRequest(
                    vehicleId: "veh_1",
                    pickup: RidePlace(lat: 0, lng: 0, label: "A"),
                    dropoff: RidePlace(lat: 1, lng: 1, label: "B")
                )
            )
            XCTFail("expected a 409")
        } catch let error as RestError {
            XCTAssertTrue(error.isVehicleUnavailable, "every time conflict is also a vehicle-unavailable refusal")
            XCTAssertTrue(error.isTimeConflict)
        }
    }

    // The BROADER refusal (a car in service / offline / already on a ride) carries
    // no sub-code, and must NOT be mistaken for a time conflict — it is a different
    // sentence and a different next step for the rider.
    func testAPlainVehicleUnavailableRefusalIsNotATimeConflict() async throws {
        let body = Data(#"{"error":{"code":"vehicle_unavailable","message":"vehicle is in service"}}"#.utf8)
        let (client, _) = client([.init(status: 409, body: body)])

        do {
            _ = try await client.createRideRequest(
                RideRequestCreateRequest(
                    vehicleId: "veh_1",
                    pickup: RidePlace(lat: 0, lng: 0, label: "A"),
                    dropoff: RidePlace(lat: 1, lng: 1, label: "B")
                )
            )
            XCTFail("expected a 409")
        } catch let error as RestError {
            XCTAssertTrue(error.isVehicleUnavailable)
            XCTAssertFalse(error.isTimeConflict)
        }
    }
}
