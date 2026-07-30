import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-264 — no fixture personas/vehicles on the live incoming-request path
//
// Two things proven here:
//  1. `RideRequestContractMapping.record(from:)` PRESERVES the real wire identity
//     (`vehicleId`, `requesterName`) instead of substituting `RideRequestFixtures
//     .fleet[0]` / a hardcoded "Sam".
//  2. `IncomingRequestDisplay.resolve` — the single gated resolver the owner sheet
//     + accept toast both consume — renders the real rider name + real fleet-join
//     vehicle on live (neutral / hidden when absent), and the fixture persona +
//     fixture vehicle in sim (pixel-identical to M1).
final class IncomingRequestLiveIdentityTests: XCTestCase {

    private let pickup = CLLocationCoordinate2D(latitude: 32.7767, longitude: -96.7970)
    private let dropoff = CLLocationCoordinate2D(latitude: 33.1507, longitude: -96.8236)

    private func wireRide(
        vehicleId: String = "veh-live",
        requesterName: String? = "Jamie Rivera",
        status: MyRobotaxiContracts.RideRequestStatus = .requested
    ) -> RideRequest {
        RideRequest(
            id: "srv-live-1",
            riderId: "u-rider",
            ownerId: "u-owner",
            vehicleId: vehicleId,
            pickup: MyRobotaxiContracts.RidePlace(lat: pickup.latitude, lng: pickup.longitude, label: "1200 Grandscape Blvd"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: dropoff.latitude, lng: dropoff.longitude, label: "Bell Southstone Yards"),
            status: status,
            createdAt: "2026-07-09T18:00:00.000Z",
            updatedAt: "2026-07-09T18:00:00.000Z",
            acceptedAt: nil,
            requesterName: requesterName
        )
    }

    private func liveVehicle(id: String = "veh-live", name: String = "Lunar") -> Vehicle {
        Vehicle(
            id: id,
            name: name,
            model: "Model Y",
            colorName: "Quicksilver",
            plate: "",
            seatHeat: false,
            seatVent: false,
            activity: .parked(ParkedLocation(
                label: "Home",
                coordinate: pickup,
                parkedSince: Date()
            ))
        )
    }

    // MARK: - Mapping preserves real identity

    func testMappingPreservesRealVehicleId() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide()))
        // The real vehicle id is preserved (was overwritten with the fixture fleet[0].id).
        XCTAssertEqual(record.input.fleetMemberID, "veh-live")
        XCTAssertNotEqual(record.input.fleetMemberID, RideRequestFixtures.fleet[0].id)
    }

    func testMappingPreservesRealRequesterName() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Jamie Rivera")))
        XCTAssertEqual(record.input.requesterName, "Jamie Rivera")
    }

    func testMappingLeavesRequesterNameNilWhenAbsent() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: nil)))
        XCTAssertNil(record.input.requesterName)
    }

    // MARK: - Live display: real name + real vehicle, never fixtures

    func testLiveDisplayUsesRealRiderNameAndVehicleJoin() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Jamie Rivera")))
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

        XCTAssertEqual(display.riderName, "Jamie Rivera")
        XCTAssertEqual(display.avatarInitial, "J")
        XCTAssertEqual(display.title(hasPassenger: false), "Jamie Rivera wants a ride")
        // Real fleet-join vehicle name — never the fixture "Model Y".
        XCTAssertEqual(display.vehicleName, "Lunar")
        XCTAssertNotEqual(display.vehicleName, RideRequestFixtures.fleet[0].name)
        // The wire carries no per-request battery/status → hidden, not asserted.
        XCTAssertNil(display.batteryAfter)
        XCTAssertFalse(display.showsReadyStatus)
    }

    /// MYR-355 — an absent live `requesterName` means the account was DELETED (the
    /// server resolves a rider who exists but is nameless to the literal "Rider"),
    /// so the stand-in names that rather than asserting a role the person no longer
    /// holds.
    func testLiveDisplayNamesADeletedAccountFormerRiderWhenNameAbsent() throws {
        for absent in [nil, "", "   "] as [String?] {
            let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: absent)))
            let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

            XCTAssertNil(display.riderName, "requesterName \(String(describing: absent)) should be treated as absent")
            XCTAssertNil(display.avatarInitial) // neutral person glyph, no fabricated initial
            XCTAssertEqual(display.title(hasPassenger: false), "Former rider wants a ride")
            XCTAssertEqual(display.title(hasPassenger: true), "Former rider requested a ride")
            XCTAssertEqual(display.riderLabel, "Former rider")
            XCTAssertFalse(
                display.title(hasPassenger: false).contains(IncomingRequestDisplay.neutralRole),
                "the present-tense role must not stand in for a person who is gone"
            )
        }
    }

    func testLiveDisplayHidesVehicleWhenNotInFleet() throws {
        // A live request whose vehicle isn't in the owner's loaded fleet: no name to
        // show and nothing to fake.
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(vehicleId: "veh-unknown")))
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: nil)
        XCTAssertNil(display.vehicleName)
    }

    // MARK: - Sim display: fixture persona + fixture vehicle (pixel-identical M1)

    func testSimDisplayKeepsFixturePersonaAndVehicle() {
        let member = RideRequestFixtures.fleet[0] // Alex · Model Y · 68%
        let dest = RideRequestFixtures.recentPlaces[1] // SFO · 18.4 mi
        let input = RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: dest,
            fleetMemberID: member.id
        )
        let record = RideRequestRecord(input: input, status: .pending)
        let display = IncomingRequestDisplay.resolve(request: record, isLive: false, liveVehicle: nil)

        XCTAssertEqual(display.riderName, "Sam")
        XCTAssertEqual(display.avatarInitial, "S")
        XCTAssertEqual(display.title(hasPassenger: false), "Sam wants a ride")
        XCTAssertEqual(display.vehicleName, member.name) // "Model Y"
        XCTAssertTrue(display.showsReadyStatus)
        // The fixture battery-after formula: max(10, battery - round(miles*0.7)).
        XCTAssertEqual(display.batteryAfter, max(10, member.battery - Int((dest.miles * 0.7).rounded())))
    }

    // MARK: - MYR-312: the SCHEDULED card names the requester from frame 0

    /// A locally-submitted draft (the single-account demo: this device's rider) is
    /// stamped with the signed-in identity, so the owner card names them before the
    /// deferred create POST + WS refetch can. A SCHEDULED request drops the rider
    /// straight back to idle, so that window is exactly when the owner looks — the
    /// client's "Shared viewer wants a ride · Scheduled · Sat 5:30 PM".
    func testScheduledDraftFromSignedInRiderShowsTheRealName() {
        let profile = UserProfile(id: "u-me", name: "Thomas Nandola", email: "thomas@myrobotaxi.app")
        let record = localDraft(schedule: RideSchedule(day: "Sat", time: "5:30 PM"), profile: profile)
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

        // The FIRST name — identical to the server's MYR-229 `firstNameToken`
        // resolution for the same account, so the later authoritative fold is a
        // no-op rather than a visible re-render.
        XCTAssertEqual(display.riderName, "Thomas")
        XCTAssertEqual(display.avatarInitial, "T")
        XCTAssertEqual(display.title(hasPassenger: false), "Thomas wants a ride")
        XCTAssertNotEqual(display.title(hasPassenger: false), "Former rider wants a ride")
    }

    /// The honest fallback is unchanged: an account with no usable name still
    /// renders the neutral role, never a fabricated persona or an empty subject.
    func testScheduledDraftWithoutAccountNameKeepsTheNeutralFallback() {
        for nameless in [nil, "", "   "] as [String?] {
            let profile = UserProfile(id: "u-me", name: nameless, email: "thomas@myrobotaxi.app")
            let record = localDraft(schedule: RideSchedule(day: "Sat", time: "5:30 PM"), profile: profile)
            let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

            XCTAssertNil(display.riderName, "name \(String(describing: nameless)) must be treated as absent")
            XCTAssertEqual(display.title(hasPassenger: false), "Former rider wants a ride")
        }
    }

    /// SIM has no signed-in profile, so the draft carries no name and the fixture
    /// persona still renders — the `ownerScheduled` drift-gate scene is untouched.
    func testSimScheduledDraftKeepsFixturePersona() {
        let record = localDraft(schedule: RideSchedule(day: "Sat", time: "5:30 PM"), profile: nil)
        XCTAssertNil(record.input.requesterName)

        let display = IncomingRequestDisplay.resolve(request: record, isLive: false, liveVehicle: nil)
        XCTAssertEqual(display.title(hasPassenger: false), "Sam wants a ride")
    }

    /// The stamp is identity, not schedule-specific: an instant draft gets the same
    /// real name (it was only invisible there because the rider sits on the Booking
    /// card for the whole 10s grace window).
    func testInstantDraftGetsTheSameRealName() {
        let profile = UserProfile(id: "u-me", name: "Thomas Nandola", email: nil)
        let record = localDraft(schedule: nil, profile: profile)
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())
        XCTAssertEqual(display.title(hasPassenger: false), "Thomas wants a ride")
    }

    /// The draft the rider's Review CTA submits (`RideRequestReviewContent.confirm`),
    /// built through the SAME resolver so the test can't drift from the shipping call.
    // MARK: - MYR-355: nil requesterName means DELETED, and only on the live path

    /// The backend fact the copy rests on: `requesterName` is omitted **iff** the
    /// rider has no identity row in any of the three sources. A rider who exists
    /// but is nameless resolves to the literal "Rider", so a nil is never a
    /// still-present person — which is what makes "Former rider" a statement of
    /// fact rather than a guess. A server-sent "Rider" must therefore render
    /// VERBATIM and never be reinterpreted.
    func testAServerResolvedNamelessRiderRendersRiderAndNotFormerRider() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Rider")))
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

        XCTAssertEqual(display.riderName, "Rider")
        XCTAssertEqual(display.riderLabel, "Rider")
        XCTAssertEqual(display.title(hasPassenger: false), "Rider wants a ride")
        XCTAssertNotEqual(display.riderLabel, IncomingRequestDisplay.formerRider)
    }

    /// A PRESENT name is untouched by this change — the stand-in only ever fills
    /// an absence.
    func testAPresentNameIsUnchangedByTheDeletedAccountStandIn() throws {
        let record = try XCTUnwrap(RideRequestContractMapping.record(from: wireRide(requesterName: "Jamie Rivera")))
        let display = IncomingRequestDisplay.resolve(request: record, isLive: true, liveVehicle: liveVehicle())

        XCTAssertEqual(display.riderName, "Jamie Rivera")
        XCTAssertEqual(display.riderLabel, "Jamie Rivera")
        XCTAssertEqual(display.title(hasPassenger: false), "Jamie Rivera wants a ride")
    }

    /// The SIM path cannot reach the stand-in by construction: `resolve`'s
    /// simulated arm always returns the fixture persona, so `riderName` is never
    /// nil there. This is what keeps every simulated capture byte-identical.
    func testTheSimulatedPathCanNeverRenderTheDeletedAccountStandIn() {
        let input = RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[1],
            fleetMemberID: RideRequestFixtures.fleet[0].id,
            requesterName: nil
        )
        let display = IncomingRequestDisplay.resolve(
            request: RideRequestRecord(input: input, status: .pending),
            isLive: false,
            liveVehicle: nil
        )

        XCTAssertEqual(display.riderName, IncomingRequestDisplay.simRiderName)
        XCTAssertEqual(display.riderLabel, "Sam")
        XCTAssertNotEqual(display.riderLabel, IncomingRequestDisplay.formerRider)
        XCTAssertFalse(display.title(hasPassenger: false).contains(IncomingRequestDisplay.formerRider))
    }

    /// `neutralRole` survives, unchanged, for the ONE surface that renders it
    /// unconditionally as a ROLE subtitle even when a name IS present
    /// (`IncomingRequestSheet.headerSubtitle`, ride-request.jsx:1313). Repurposing
    /// it would have put "Former rider · 3 min ago" under a named requester.
    func testTheRoleSubtitleTermIsUnchangedAndDistinctFromTheStandIn() {
        XCTAssertEqual(IncomingRequestDisplay.neutralRole, "Shared viewer")
        XCTAssertEqual(IncomingRequestDisplay.formerRider, "Former rider")
        XCTAssertNotEqual(IncomingRequestDisplay.neutralRole, IncomingRequestDisplay.formerRider)
    }

    private func localDraft(schedule: RideSchedule?, profile: UserProfile?) -> RideRequestRecord {
        let input = RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[1],
            fleetMemberID: "veh-live",
            passenger: nil,
            schedule: schedule,
            requesterName: IncomingRequestDisplay.localRequesterName(profile: profile)
        )
        return RideRequestRecord(input: input, status: .pending)
    }
}
