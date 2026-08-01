import XCTest

// MARK: - MYR-396 — the owner's ride survives a relaunch, on the real screen
//
// `OwnerDispatchColdLaunchTests` proves the RULE: given a pointer and a live wire
// record, `LiveRideRequestService` adopts it into `ownerDispatch`. This file
// proves the rule is what the SCREEN consults — that a launch actually reaches
// the adoption and that `HomeScreen` renders the restored ride.
//
// That distinction is not academic here. `ownerDispatch` is read through
// `HomeScreen.dispatchedRide`, which layers `OwnerRideStatusLine
// .dispatchCardVisible` and the `OwnerHomeState` acknowledgement on top of it, so
// a perfectly-adopted record can still render nothing — which is exactly the
// MYR-387 shape (`ColdSnapshotLoad` was right, four ways, and unreachable) and
// MYR-369's (`VehicleRideShare.display` passed every test with no call sites).
final class OwnerDispatchColdLaunchUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MRT_SCENE"] = scene
        app.launch()
        return app
    }

    /// THE CLIENT'S FRAME, RESTORED. A launch with an open accepted ride on the
    /// wire — and on NO list this owner can read, which is the defect — puts the
    /// in-progress card back: the status line naming the rider, and the phase
    /// control that moves the ride on.
    func testAColdLaunchRestoresTheInProgressCardAndItsControl() {
        let app = launch(scene: "ownerDispatchColdAdopted")

        let status = app.staticTexts["En route to pickup \u{00B7} Mira"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 20),
            "owner Home rendered no trace of the ride in progress after a relaunch")

        let pickedUp = app.buttons["Picked up"]
        XCTAssertTrue(pickedUp.waitForExistence(timeout: 5), "the phase control came back with the card")
        XCTAssertTrue(pickedUp.isHittable)
        XCTAssertGreaterThanOrEqual(pickedUp.frame.height, 44 - 0.5, "min tap target is 44pt")
    }

    /// THE NAME IS THE SERVER'S. The restored record travels the same
    /// `RideRequestContractMapping.record(from:)` fold a WS frame does, so the card
    /// says who the rider actually is — not the simulated persona the pixel-paired
    /// `ownerDispatched` scene renders.
    func testTheRestoredCardNamesTheRiderTheWireNamed() {
        let app = launch(scene: "ownerDispatchColdAdopted")
        XCTAssertTrue(app.staticTexts["En route to pickup \u{00B7} Mira"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.staticTexts["En route to pickup \u{00B7} Sam"].exists,
            "a wire record must not be narrated with the fixture persona")
    }

    /// A RESTORED DISPATCH IS A DISPATCH, NOT AN INCOMING REQUEST. The two owner
    /// surfaces are fed by two projections of one pipeline (MYR-325), and an
    /// adoption that put an answered ride in the `pending` slot would re-present a
    /// ride the owner already accepted — whose Accept would `409`.
    func testTheRestoredRideDoesNotComeBackAsAnIncomingRequest() {
        let app = launch(scene: "ownerDispatchColdAdopted")
        XCTAssertTrue(app.staticTexts["En route to pickup \u{00B7} Mira"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Accept"].exists, "an accepted ride must not be offered for acceptance")
        XCTAssertFalse(app.buttons["Decline"].exists)
    }

    /// The PAIR's other half, unchanged: the same card reached by a live accept in
    /// this process. It is the pixel reference for the scene above, and the guard
    /// that this issue did not move the simulated owner surface.
    func testTheSimulatedDispatchSceneIsUnchanged() {
        let app = launch(scene: "ownerDispatched")
        XCTAssertTrue(app.staticTexts["En route to pickup \u{00B7} Sam"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Picked up"].waitForExistence(timeout: 5))
    }
}
