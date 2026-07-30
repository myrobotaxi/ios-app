import XCTest
import CoreLocation
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-357 — "Someone else", audited end to end
//
// The audit question was whether the name the rider types into the passenger field
// ever reaches anyone. It does — every hop exists — but NOT ONE TEST PINNED IT,
// which is the same shape of exposure MYR-362 was: `passengerName` and
// `passengerPhone` are OPTIONAL on `RideRequestCreateRequest`, so dropping either
// from the body throws nothing, fails no decode, logs nothing, and answers `201`.
// The server would simply store `NULL` and the owner's card would quietly say a
// rider booked for themselves.
//
// The upstream half is verified and needs no client work: the handler decodes both
// keys, `go_ride_requests` has `passenger_name` / `passenger_phone` columns
// (migration `0002_ride_requests.up.sql`), the owner list/accept/decline responses
// all serialize through ONE `rideRequestWire` with both fields, and both are on
// `$defs.RideRequest` in the contract schema, not only on the create request. So
// the client's job is to keep sending them and keep reading them back — which is
// what this file makes a test failure rather than a screenshot.

@MainActor
final class PassengerWireTests: XCTestCase {

    private static func place(_ label: String) -> MyRoboTaxi.RidePlace {
        MyRoboTaxi.RidePlace(
            id: label, label: label, subtitle: "\(label) St", miles: 1, minutes: 5, icon: "mappin",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.41)
        )
    }

    private static func input(passenger: RidePassenger?) -> RideRequestInput {
        RideRequestInput(
            pickup: place("Pickup"), destination: place("Drop"),
            fleetMemberID: "veh-1", passenger: passenger
        )
    }

    // MARK: OUT — the create body

    func testTheCreateBodyCarriesBothPassengerFields() {
        let body = LiveRideRequestService.createBody(
            from: Self.input(passenger: RidePassenger(name: "Maya Chen", phone: "(415) 555-0142")),
            vehicleId: "veh-1"
        )
        XCTAssertEqual(body.passengerName, "Maya Chen")
        XCTAssertEqual(body.passengerPhone, "(415) 555-0142")
    }

    /// A name with no number is a legal request — §7.8 requires neither — and the
    /// name must still travel. Sending `""` for the phone would be worse than
    /// omitting it: the server rejects an empty `passengerName` with a 400, and an
    /// empty phone is a value that says nothing.
    func testANameWithNoNumberSendsTheNameAndOmitsTheNumber() {
        let body = LiveRideRequestService.createBody(
            from: Self.input(passenger: RidePassenger(name: "Dad", phone: "")),
            vehicleId: "veh-1"
        )
        XCTAssertEqual(body.passengerName, "Dad")
        XCTAssertNil(body.passengerPhone)
    }

    func testARideForTheRiderThemselvesSendsNeitherKey() {
        let body = LiveRideRequestService.createBody(from: Self.input(passenger: nil), vehicleId: "veh-1")
        XCTAssertNil(body.passengerName)
        XCTAssertNil(body.passengerPhone)
    }

    /// The body must survive ENCODING with both keys present — the MYR-362 lesson
    /// applied forwards: a field that is only ever asserted on the Swift value can
    /// still be missing from the bytes.
    func testBothKeysAreOnTheEncodedBody() throws {
        let body = LiveRideRequestService.createBody(
            from: Self.input(passenger: RidePassenger(name: "Maya Chen", phone: "(415) 555-0142")),
            vehicleId: "veh-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any]
        )
        XCTAssertEqual(object["passengerName"] as? String, "Maya Chen")
        XCTAssertEqual(object["passengerPhone"] as? String, "(415) 555-0142")
    }

    // MARK: BACK — what the owner reads

    func testTheOwnerSideMapsBothFieldsBackOffTheWire() {
        let passenger = RideRequestContractMapping.passenger(
            Self.wireRide(passengerName: "Maya Chen", passengerPhone: "(415) 555-0142")
        )
        XCTAssertEqual(passenger?.name, "Maya Chen")
        XCTAssertEqual(passenger?.phone, "(415) 555-0142")
    }

    /// `omitempty` on the Go side means an absent passenger is a MISSING key, never
    /// `null` — and a rider booking for themselves must not produce an empty
    /// passenger chip on the owner's card.
    func testAnAbsentPassengerMapsToNoPassengerAtAll() {
        XCTAssertNil(RideRequestContractMapping.passenger(Self.wireRide(passengerName: nil, passengerPhone: nil)))
        XCTAssertNil(RideRequestContractMapping.passenger(Self.wireRide(passengerName: "", passengerPhone: nil)))
    }

    /// The half of the pair the schema allows and the UI has to survive: a name with
    /// no number. Review renders "Add a mobile number to send the tracking link" and
    /// the owner's chip shows the name alone.
    func testANameWithNoNumberMapsToANamedPassengerWithABlankPhone() {
        let passenger = RideRequestContractMapping.passenger(
            Self.wireRide(passengerName: "Dad", passengerPhone: nil)
        )
        XCTAssertEqual(passenger?.name, "Dad")
        XCTAssertEqual(passenger?.phone, "")
    }

    private static func wireRide(passengerName: String?, passengerPhone: String?) -> MyRobotaxiContracts.RideRequest {
        MyRobotaxiContracts.RideRequest(
            id: "srv-1",
            riderId: "rider-1",
            ownerId: "owner-1",
            vehicleId: "veh-1",
            pickup: MyRobotaxiContracts.RidePlace(lat: 37.77, lng: -122.41, label: "Pickup", address: "Pickup St"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: 37.78, lng: -122.42, label: "Drop", address: "Drop St"),
            status: .requested,
            passengerName: passengerName,
            passengerPhone: passengerPhone,
            createdAt: "2026-07-30T18:00:00.000Z",
            updatedAt: "2026-07-30T18:00:00.000Z"
        )
    }
}
