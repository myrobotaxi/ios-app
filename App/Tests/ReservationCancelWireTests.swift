import XCTest
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - What the two cancels actually PUT ON THE WIRE (MYR-381)
//
// TestFlight r14, build 202607310508. The client cancelled ONE reservation from
// BOTH roles and neither worked: the rider's ScheduledRideSheet answered
// "Couldn't cancel that ride" and the owner's Drives → Upcoming X answered
// "Couldn't cancel that reservation". The ride (`ce528c30…`) was plain
// `accepted` and pre-due — legal for a rider cancel AND for a scheduled owner
// decline — and production's `updated_at` never moved, so no mutation ever
// reached the server at all.
//
// MYR-376/377's tests all stubbed the `RiderScheduledRideSource` /
// `UpcomingReservationSource` SEAM, so every one of them passed while the two
// live implementations below the seam sent something the server does not answer.
// These tests run the REAL `LiveRiderScheduledRides` / `LiveUpcomingReservations`
// over a REAL `RestClient` against a recording transport, and assert the request
// BYTES — method, path, and the id inside it — because the bytes are the only
// thing production ever saw.
final class ReservationCancelWireTests: XCTestCase {

    /// The client's own ride id shape: a UUID, not the contract's example cuid.
    private static let rideID = "ce528c30-2f19-4b2a-9d0a-6ec2b0d55f41"
    private static let vehicleID = "veh-live-1"

    // MARK: - Rider: ScheduledRideSheet ⇢ "Cancel ride"

    @MainActor
    func testTheRiderCancelPostsTheSERVERRideIDToTheCancelPath() async throws {
        let http = RoutedHTTP([
            .init("/cancel", body: Self.rideBody(status: "cancelled")),
            .init("/ride-requests", body: Self.listBody())
        ])
        let store = RiderScheduledRidesStore(source: LiveRiderScheduledRides(
            api: Self.restClient(http: http),
            vehicleNames: { _ in nil }
        ))

        await store.load()
        let row = try XCTUnwrap(store.rides.first)
        XCTAssertEqual(row.id, Self.rideID, "the row's id IS the server's ride id")

        await store.cancel(id: row.id)

        let requests = await http.capturedRequests()
        let post = try XCTUnwrap(requests.first { $0.httpMethod == "POST" }, "no cancel ever reached the transport")
        XCTAssertEqual(post.url?.path, "/api/ride-requests/\(Self.rideID)/cancel")
        XCTAssertNil(store.failureNotice, "a 200 is not a refusal")
    }

    // MARK: - Owner: Drives → Upcoming ⇢ X

    @MainActor
    func testTheOwnerDeclinePostsTheSERVERRideIDToTheDeclinePath() async throws {
        let http = RoutedHTTP([
            .init("/decline", body: Self.rideBody(status: "declined")),
            .init("/ride-requests/incoming", body: Self.listBody())
        ])
        let state = OwnerDrivesState(
            live: true,
            reservations: LiveUpcomingReservations(api: Self.restClient(http: http))
        )

        await state.loadUpcoming(vehicleID: Self.vehicleID)
        let row = try XCTUnwrap(state.upcoming.first)
        XCTAssertEqual(row.id, Self.rideID)

        await state.cancelReservation(id: row.id, vehicleID: Self.vehicleID)

        let requests = await http.capturedRequests()
        let post = try XCTUnwrap(requests.first { $0.httpMethod == "POST" }, "no decline ever reached the transport")
        XCTAssertEqual(post.url?.path, "/api/ride-requests/\(Self.rideID)/decline")
        XCTAssertNil(state.cancelFailureNotice, "a 200 is not a refusal")
    }

    // MARK: - Wire bodies

    private static func restClient(http: any HTTPPerforming) -> RestClient {
        RestClient(environment: .test, tokenProvider: StaticTokenProvider("t"), http: http)
    }

    /// Tomorrow at noon UTC — accepted, undispatched, so both roles' predicates
    /// (`RideReservation.isDormant` / `.isUpcomingReservation`) put it on screen.
    private static var scheduledFor: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date().addingTimeInterval(24 * 3600))
    }

    private static func rideBody(status: String) -> Data {
        Data("""
        {
          "id": "\(rideID)",
          "riderId": "u-rider", "ownerId": "u-owner", "vehicleId": "\(vehicleID)",
          "pickup": { "lat": 33.0198, "lng": -96.6989, "label": "Home" },
          "dropoff": { "lat": 32.9346, "lng": -96.8206, "label": "Galleria Dallas" },
          "status": "\(status)",
          "scheduledFor": "\(scheduledFor)",
          "createdAt": "2026-07-31T05:00:00.000Z",
          "updatedAt": "2026-07-31T05:04:00.000Z",
          "acceptedAt": "2026-07-31T05:04:00.000Z",
          "requesterName": "Thomas"
        }
        """.utf8)
    }

    private static func listBody() -> Data {
        Data("""
        { "items": [\(String(decoding: rideBody(status: "accepted"), as: UTF8.self))], "nextCursor": null, "hasMore": false }
        """.utf8)
    }
}
