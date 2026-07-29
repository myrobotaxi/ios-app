import XCTest
@testable import MyRoboTaxi

/// Foreground banner suppression + tap routing (MYR-186).
///
/// Both are pure functions precisely so this matrix can be pinned without a
/// notification centre or a running app. The suppression rule is RIDE-SPECIFIC,
/// not surface-specific — the interesting cases below are the ones where the
/// right surface is up but for a DIFFERENT ride.
@MainActor
final class PushNotificationRoutingTests: XCTestCase {

    private let rideA = PushRideNotification(rideID: "ride_a")
    private let rideB = PushRideNotification(rideID: "ride_b")

    // MARK: Payload extraction

    func testRideIDIsReadFromUserInfo() {
        let payload = PushRideNotification.from(userInfo: ["rideId": "ride_a", "aps": ["alert": "x"]])
        XCTAssertEqual(payload?.rideID, "ride_a")
    }

    func testMissingOrEmptyRideIDYieldsNoPayload() {
        XCTAssertNil(PushRideNotification.from(userInfo: ["aps": ["alert": "x"]]))
        XCTAssertNil(PushRideNotification.from(userInfo: ["rideId": ""]))
        XCTAssertNil(PushRideNotification.from(userInfo: ["rideId": 42]), "a non-string id is not a ride id")
    }

    // MARK: Owner foreground suppression

    func testOwnerSuppressesWhenTheIncomingCardShowsThatRide() {
        let context = PushSurfaceContext(role: .owner, ownerIncomingRideID: "ride_a")
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideA, context: context),
            .suppress,
            "the banner would cover the card's own Accept/Decline buttons"
        )
    }

    /// The load-bearing case: an owner looking at request A must still be told
    /// about request B — B is exactly what they cannot see.
    func testOwnerStillSeesABannerForADifferentRide() {
        let context = PushSurfaceContext(role: .owner, ownerIncomingRideID: "ride_a")
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideB, context: context),
            .present,
            "a second rider must not be silently hidden behind the first one's card"
        )
    }

    func testOwnerSeesABannerWhenNoIncomingCardIsUp() {
        let context = PushSurfaceContext(role: .owner)
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideA, context: context),
            .present
        )
    }

    /// Owner on the Drives/Settings tab: the incoming card is not frontmost, so
    /// the context carries no id and the banner presents.
    func testOwnerOnAnotherTabSeesABanner() {
        let context = PushSurfaceContext(role: .owner, ownerIncomingRideID: nil, riderTrackingRideID: "ride_a")
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideA, context: context),
            .present,
            "the rider-side field must not suppress on the owner branch"
        )
    }

    // MARK: Rider foreground suppression

    func testRiderSuppressesWhileTrackingThatRide() {
        let context = PushSurfaceContext(role: .shared, riderTrackingRideID: "ride_a")
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideA, context: context),
            .suppress,
            "every state the notification announces is already on screen and updating"
        )
    }

    func testRiderStillSeesABannerForADifferentRide() {
        let context = PushSurfaceContext(role: .shared, riderTrackingRideID: "ride_a")
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideB, context: context),
            .present
        )
    }

    func testRiderNotOnTrackingSeesABanner() {
        let context = PushSurfaceContext(role: .shared)
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideA, context: context),
            .present
        )
    }

    /// The owner-side field must not suppress on the rider branch either — the
    /// two are read independently, per role.
    func testRiderIsNotSuppressedByTheOwnerField() {
        let context = PushSurfaceContext(role: .shared, ownerIncomingRideID: "ride_a")
        XCTAssertEqual(
            PushNotificationRouting.foregroundPresentation(notification: rideA, context: context),
            .present
        )
    }

    // MARK: No ride id

    func testANotificationWithoutARideIDIsAlwaysPresented() {
        for context in [
            PushSurfaceContext(role: .owner, ownerIncomingRideID: "ride_a"),
            PushSurfaceContext(role: .shared, riderTrackingRideID: "ride_a")
        ] {
            XCTAssertEqual(
                PushNotificationRouting.foregroundPresentation(notification: nil, context: context),
                .present,
                "with no ride id there is no basis to claim the user is already looking at it"
            )
        }
    }

    // MARK: Tap routing

    func testOwnerTapRoutesToOwnerHome() {
        XCTAssertEqual(PushNotificationRouting.tapRoute(notification: rideA, role: .owner), .ownerHome)
    }

    func testRiderTapRoutesToTheActiveFlow() {
        XCTAssertEqual(PushNotificationRouting.tapRoute(notification: rideA, role: .shared), .riderActiveFlow)
    }

    /// The ride id deliberately does NOT change the route: each role has exactly
    /// one surface where a ride is dealt with, and the id is what the refresh at
    /// the far end resolves.
    func testTheRouteDoesNotVaryWithTheRideID() {
        XCTAssertEqual(
            PushNotificationRouting.tapRoute(notification: rideA, role: .owner),
            PushNotificationRouting.tapRoute(notification: rideB, role: .owner)
        )
        XCTAssertEqual(
            PushNotificationRouting.tapRoute(notification: nil, role: .shared),
            .riderActiveFlow,
            "a payload-less tap still lands on the role's surface"
        )
    }
}
