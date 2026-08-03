import CoreLocation
import MyRobotaxiContracts
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-379 — the rider can TYPE a pickup, then fine-tune it on the map
//
// The client, r18: *"No option to type in pick up location and then fine set up
// exact spot to pick up on map. It locks to current location."*
//
// Two claims are made by the fix and both are pinned here. The first is the
// FEATURE: a typed pickup chains into the existing pin-drop seeded at the place
// the rider named, and the pin they confirm there is the pickup the car is
// dispatched to. The second is the GUARANTEE that makes it safe to ship: a rider
// who never touches the pickup row gets byte-identical behaviour, because
// "Current location" is still exactly what `draftPickup == nil` means.
//
// The state machine is deliberately tested through `SharedViewerState` rather
// than through a mirror of it — `RiderDraftLifetimeTests`' precedent. The one
// thing extracted as pure is the ENTRY LADDER (`RiderPickupEntry`), because its
// whole matrix is three optionals and reaching it through a map, a camera
// controller and a location manager would test MapKit rather than the rule.

/// A device fix, so the "locks to current location" rung has something to be.
private final class PickupSelectionUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    private(set) var refreshCount = 0
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { true }
    func start() {}
    func stop() {}
    func refresh() { refreshCount += 1 }
}

@MainActor
final class RiderPickupSelectionTests: XCTestCase {

    /// The rider's own feet — the coordinate the client's report says the pin
    /// "locks to".
    private static let deviceFix = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    /// A pickup three blocks away that the rider TYPED.
    private static let searched = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    /// Where they dragged the pin once they got there — the kerb, not the pin's
    /// entry point. This is the coordinate that has to reach the wire.
    private static let nudged = CLLocationCoordinate2D(latitude: 37.7961, longitude: -122.3944)

    private static func place(
        id: String, label: String, at coordinate: CLLocationCoordinate2D
    ) -> MyRoboTaxi.RidePlace {
        MyRoboTaxi.RidePlace(
            id: id, label: label, subtitle: "\(label) St", miles: 0, minutes: 0,
            icon: "mappin", coordinate: coordinate
        )
    }

    private static var searchedPickup: MyRoboTaxi.RidePlace {
        place(id: "ferry", label: "Ferry Building", at: searched)
    }

    private func makeState(
        fix: CLLocationCoordinate2D? = RiderPickupSelectionTests.deviceFix,
        isLive: Bool = false
    ) -> (SharedViewerState, PickupSelectionUserLocation) {
        let location = PickupSelectionUserLocation(coordinate: fix)
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: location,
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: isLive
        )
        return (SharedViewerState(seams: seams), location)
    }

    /// The rider's DRAG, expressed the way the app expresses it: the map reporting
    /// a settled centre. `pinDropCameraSettled` is ignored on the simulated path by
    /// design (so captures hold still), which is why every fine-tune assertion here
    /// runs against a live-flagged state — a sim-only test of a drag would be a
    /// test of nothing.
    private func drag(_ state: SharedViewerState, to coordinate: CLLocationCoordinate2D) {
        state.pinDropCameraSettled(at: coordinate)
    }

    private func assertSame(
        _ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D,
        _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let coordinate = lhs else {
            return XCTFail("\(what): expected a coordinate, got nil", file: file, line: line)
        }
        XCTAssertEqual(coordinate.latitude, rhs.latitude, accuracy: 1e-9, "\(what): lat", file: file, line: line)
        XCTAssertEqual(coordinate.longitude, rhs.longitude, accuracy: 1e-9, "\(what): lng", file: file, line: line)
    }

    // MARK: The entry ladder (pure)

    /// Rung 3, and the whole reason this feature is additive: a rider who has
    /// touched neither affordance gets the device fix — which is exactly the bare
    /// `userLocation.coordinate` the map call site read before MYR-379.
    func testWithNoPickupOfAnyKindTheEntryIsStillTheDeviceFix() {
        assertSame(
            RiderPickupEntry.coordinate(seed: nil, confirmedPickup: nil, deviceFix: Self.deviceFix),
            Self.deviceFix, "the untouched default"
        )
    }

    /// Rung 1 — the client's ask. A searched pickup awaiting fine-tuning outranks
    /// the device fix, which is the literal undoing of "it locks to current
    /// location".
    func testASearchedPickupOutranksTheDeviceFix() {
        assertSame(
            RiderPickupEntry.coordinate(seed: Self.searched, confirmedPickup: nil, deviceFix: Self.deviceFix),
            Self.searched, "the seed"
        )
    }

    /// Rung 2 — the named behaviour change. Re-entering the pin-drop with a pickup
    /// already confirmed resumes THERE rather than throwing it away and returning
    /// to the rider's feet, which is what shipped before.
    func testAConfirmedPickupOutranksTheDeviceFix() {
        assertSame(
            RiderPickupEntry.coordinate(seed: nil, confirmedPickup: Self.nudged, deviceFix: Self.deviceFix),
            Self.nudged, "the confirmed pickup"
        )
    }

    /// The ORDER of the two upper rungs, which is the one that can be swapped
    /// without anything failing to compile. A live seed means a chain in progress
    /// and must win; the reverse would re-open a fine-tune on the pickup being
    /// replaced.
    func testASeedOutranksAConfirmedPickup() {
        assertSame(
            RiderPickupEntry.coordinate(seed: Self.searched, confirmedPickup: Self.nudged, deviceFix: Self.deviceFix),
            Self.searched, "seed over confirmed"
        )
    }

    /// No fix, no seed, no pickup is a real answer (the simulated path), not a
    /// failure — the map falls through to its own framing exactly as it always has.
    func testNothingKnownStaysNil() {
        XCTAssertNil(RiderPickupEntry.coordinate(seed: nil, confirmedPickup: nil, deviceFix: nil))
    }

    /// `isPlaceLed` is what suppresses the device-fix refresh, so it must be true
    /// for BOTH non-device rungs and false only for the untouched default.
    func testOnlyTheUntouchedDefaultIsAboutTheDevice() {
        XCTAssertFalse(RiderPickupEntry.isPlaceLed(seed: nil, confirmedPickup: nil))
        XCTAssertTrue(RiderPickupEntry.isPlaceLed(seed: Self.searched, confirmedPickup: nil))
        XCTAssertTrue(RiderPickupEntry.isPlaceLed(seed: nil, confirmedPickup: Self.nudged))
    }

    // MARK: searched → fine-tuned → submitted

    /// Selecting a searched pickup CHAINS into the pin-drop rather than committing
    /// a pickup outright — the client asked to type a place *and then* set the
    /// exact spot on the map, and the exact spot is the pin-drop's whole job.
    func testSelectingASearchedPickupChainsIntoTheSeededPinDrop() {
        let (state, _) = makeState()
        state.selectPickup(Self.searchedPickup)

        XCTAssertEqual(state.sheetPhase, .pinDrop(returnTo: .search), "it enters the pin-drop")
        XCTAssertEqual(state.pinReturn, .search, "and returns to the sheet it came from")
        assertSame(state.pinDropSeed, Self.searched, "the seed is the searched place")
        assertSame(state.pinDropEntryCoordinate, Self.searched, "and the camera opens there")
        XCTAssertNil(
            state.draftPickup,
            "nothing is committed yet — the rider has not confirmed a pin"
        )
    }

    /// MYR-237's anchor is pickup identity for the route cache, so naming a pickup
    /// that is not the device fix has to re-anchor it. Leaving the old anchor up
    /// would key the preview route off wherever the rider happened to be standing.
    func testSelectingASearchedPickupReAnchorsTheRoutePreview() {
        let (state, _) = makeState()
        state.chooseDestination(RideRequestFixtures.recentPlaces[1]) // anchors at the device fix
        assertSame(state.previewPickupAnchor, Self.deviceFix, "the anchor starts at the fix")

        state.selectPickup(Self.searchedPickup)
        assertSame(state.previewPickupAnchor, Self.searched, "and moves to the named pickup")
    }

    /// The FULL chain, and the assertion that matters most: the coordinate the
    /// rider DRAGGED to is what becomes the pickup — not the place they typed.
    /// A fine-tune that did not survive the confirm would make the whole second
    /// half of the client's sentence decorative.
    func testTheNudgedPinIsWhatBecomesThePickup() {
        let (state, _) = makeState(isLive: true)
        state.selectPickup(Self.searchedPickup)
        state.enterPinDrop()
        drag(state, to: Self.nudged)
        state.confirmPickup()

        assertSame(state.draftPickup?.coordinate, Self.nudged, "the confirmed pickup")
        XCTAssertEqual(state.draftPickup?.id, "pin", "and it is a PIN, not a searched place")
    }

    /// The seed is the pin's STARTING point and never a floor under it: a rider who
    /// searched a place and then dragged away from it must get where they dragged.
    /// Rung 1 outranking rung 2 in the ENTRY ladder must not leak into the
    /// coordinate a settled camera has already reported.
    func testADragAwayFromTheSearchedPlaceWins() {
        let (state, _) = makeState(isLive: true)
        state.selectPickup(Self.searchedPickup)
        state.enterPinDrop()
        drag(state, to: Self.nudged)

        assertSame(state.pinDropCoordinate, Self.nudged, "the settled centre outranks the seed")
    }

    /// ONE REPRESENTATION. A searched pickup that has been through the chain is
    /// indistinguishable downstream from one that was dropped on the map from the
    /// start — same `id`, same glyph, same shape — which is what lets every
    /// consumer stay untouched.
    func testASearchedPickupCommitsAsAnOrdinaryPinDroppedPickup() {
        let (searchLed, _) = makeState()
        searchLed.selectPickup(Self.searchedPickup)
        searchLed.confirmPickup()

        let (mapLed, _) = makeState()
        mapLed.sheetPhase = .pinDrop(returnTo: .search)
        mapLed.confirmPickup()

        XCTAssertEqual(searchLed.draftPickup?.id, mapLed.draftPickup?.id, "same identity")
        XCTAssertEqual(searchLed.draftPickup?.icon, mapLed.draftPickup?.icon, "same glyph")
        XCTAssertEqual(searchLed.draftPickup?.label, mapLed.draftPickup?.label, "same labeler output")
        XCTAssertEqual(searchLed.draftPickup?.miles, 0, "and no fabricated distance")
    }

    /// The seed is a ONE-SHOT. Left standing it would outrank rung 2 and re-open
    /// the next pin-drop on the pre-drag place, silently undoing the fine-tune.
    func testConfirmingSpendsTheSeedSoTheNextEntryResumesAtThePin() {
        let (state, _) = makeState()
        state.selectPickup(Self.searchedPickup)
        state.confirmPickup()

        XCTAssertNil(state.pinDropSeed, "the seed is spent")
        assertSame(
            state.pinDropEntryCoordinate, state.draftPickup!.coordinate,
            "so 'On map' resumes at the confirmed pin"
        )
    }

    /// Backing out commits nothing, so it must leave nothing — the sheet's pickup
    /// row is a mirror of `draftPickup` and has to be able to tell the truth about
    /// a chain the rider abandoned.
    func testBackingOutOfTheChainLeavesNoPickupAndNoSeed() {
        let (state, _) = makeState()
        state.selectPickup(Self.searchedPickup)
        state.returnFromPinDropToSearch()

        XCTAssertEqual(state.sheetPhase, .search)
        XCTAssertNil(state.draftPickup, "nothing was confirmed")
        XCTAssertNil(state.pinDropSeed, "and the abandoned seed does not linger")
        assertSame(state.pinDropEntryCoordinate, Self.deviceFix, "so the next entry is the default again")
    }

    /// MYR-278's category rows have no single coordinate and must never become an
    /// endpoint by ANY path — the pickup is a new path.
    func testACategoryRowCanNeverBecomeAPickup() {
        let (state, _) = makeState()
        let category = MyRoboTaxi.RidePlace(
            id: "live-category|coffee", label: "Coffee", subtitle: nil, miles: 0, minutes: 0,
            icon: "magnifyingglass", coordinate: Self.searched
        )
        XCTAssertTrue(RidePlaceMapper.isCategorySearch(category), "precondition")

        state.selectPickup(category)
        XCTAssertNil(state.pinDropSeed, "no seed")
        XCTAssertEqual(state.sheetPhase, .idle, "and the flow did not move")
    }

    // MARK: "Current location" is untouched

    /// The guarantee. A rider who never touches the pickup row still reaches the
    /// pin-drop through the destination funnel, still opens on the device fix, and
    /// still gets the refresh MYR-212 added for exactly that case.
    func testTheCurrentLocationDefaultIsUnchangedEndToEnd() {
        let (state, location) = makeState()
        state.selectDestination(RideRequestFixtures.recentPlaces[1])

        XCTAssertEqual(state.sheetPhase, .pinDrop(returnTo: .review), "the pre-MYR-379 route")
        XCTAssertNil(state.pinDropSeed, "with no seed")
        assertSame(state.pinDropEntryCoordinate, Self.deviceFix, "opening on the device fix")

        state.enterPinDrop()
        XCTAssertEqual(location.refreshCount, 1, "and the device-fix refresh still runs")
    }

    /// The refresh's other arm, which is a fix rather than a preservation: a fresh
    /// fix landing under a PLACE-LED session moves `mapRegionCenter`, which
    /// `pinDropCoordinate` falls back to before the first camera settle. Asking for
    /// one is the reported defect coming back through the last open door.
    func testAPlaceLedPinDropDoesNotChaseTheDeviceFix() {
        let (state, location) = makeState()
        state.selectPickup(Self.searchedPickup)
        state.enterPinDrop()

        XCTAssertEqual(location.refreshCount, 0, "no refresh under a seeded session")
        assertSame(state.pinDropCoordinate, Self.searched, "and the coordinate is the named place")
    }

    /// The window the previous test protects, stated directly: confirming BEFORE
    /// the camera has reported a settle must still give the rider the place they
    /// typed, never the fallback underneath it.
    func testConfirmingBeforeTheFirstSettleStillGivesTheSearchedPlace() {
        let (state, _) = makeState()
        state.selectPickup(Self.searchedPickup)
        state.enterPinDrop() // clears any settled centre; nothing has reported yet
        state.confirmPickup()

        assertSame(state.draftPickup?.coordinate, Self.searched, "the pickup")
    }

    /// The explicit way back to the default — the pickup field's clear `xmark`,
    /// which is the destination field's own affordance at the other end of the
    /// route card.
    func testClearingThePickupReturnsToTheCurrentLocationDefault() {
        let (state, _) = makeState()
        state.selectPickup(Self.searchedPickup)
        state.confirmPickup()
        XCTAssertNotNil(state.draftPickup, "precondition")

        state.clearPickup()
        XCTAssertNil(state.draftPickup, "back to the implicit default")
        XCTAssertNil(state.pinDropSeed, "and no pending chain survives it")
        assertSame(state.pinDropEntryCoordinate, Self.deviceFix, "so the pin opens on the device again")
    }

    // MARK: The draft reset covers the pickup

    /// MYR-389's rule applied to the field this issue adds. A stale seed is the
    /// sharpest possible version of the leak it was written for — it would open a
    /// brand-new trip's pin-drop on the previous trip's pickup.
    func testTheEntryResetForgetsAnAbandonedPickupChain() {
        let (state, _) = makeState()
        state.selectPickup(Self.searchedPickup)
        state.sheetPhase = .idle // the flow was left; the draft was not

        state.enterSearchFromIdle()
        XCTAssertNil(state.pinDropSeed, "the seed is part of the draft")
        XCTAssertNil(state.draftPickup)
        assertSame(state.pinDropEntryCoordinate, Self.deviceFix, "a fresh trip starts from the default")
    }

    /// The same through the other door, and through `discardDraftTrip` itself —
    /// the ONE list of what a draft is, which is where a new field gets forgotten.
    func testEveryResetDoorForgetsTheSeed() {
        for (name, reset) in [
            ("discardDraftTrip", { (s: SharedViewerState) in s.discardDraftTrip() }),
            ("resetDraftToIdle", { (s: SharedViewerState) in s.resetDraftToIdle() }),
            ("enterSearchFromIdle", { (s: SharedViewerState) in s.enterSearchFromIdle() }),
        ] {
            let (state, _) = makeState()
            state.selectPickup(Self.searchedPickup)
            reset(state)
            XCTAssertNil(state.pinDropSeed, "\(name) must forget the seed")
            XCTAssertNil(state.draftPickup, "\(name) must forget the pickup")
        }
    }

    // MARK: The create body carries the ADJUSTED coordinate

    /// The end of the line. Everything above is only worth having if the kerb the
    /// rider nudged to is the coordinate the car is dispatched to — and `pickup` is
    /// non-optional on `RideRequestInput`, so a wrong coordinate here throws
    /// nothing, fails no decode and still answers `201` (MYR-362's shape).
    func testTheCreateBodyCarriesTheFineTunedPickupCoordinate() throws {
        let (state, _) = makeState(isLive: true)
        state.selectPickup(Self.searchedPickup)
        state.enterPinDrop()
        drag(state, to: Self.nudged)
        state.confirmPickup()

        let body = LiveRideRequestService.createBody(
            from: RideRequestInput(
                pickup: try XCTUnwrap(state.draftPickup),
                destination: RideRequestFixtures.recentPlaces[1],
                fleetMemberID: "veh-1",
                passenger: nil
            ),
            vehicleId: "veh-1"
        )

        XCTAssertEqual(body.pickup.lat, Self.nudged.latitude, accuracy: 1e-9, "the wire's pickup lat")
        XCTAssertEqual(body.pickup.lng, Self.nudged.longitude, accuracy: 1e-9, "the wire's pickup lng")
        XCTAssertNotEqual(
            body.pickup.lat, Self.deviceFix.latitude, accuracy: 1e-9,
            "and emphatically NOT the device fix — that is the reported defect"
        )
    }

    /// The same coordinate, through ENCODING. MYR-362's lesson pointed forwards: a
    /// field only ever asserted on the Swift value can still be wrong in the bytes.
    func testTheEncodedBodyCarriesTheFineTunedCoordinate() throws {
        let (state, _) = makeState(isLive: true)
        state.selectPickup(Self.searchedPickup)
        state.enterPinDrop()
        drag(state, to: Self.nudged)
        state.confirmPickup()

        let body = LiveRideRequestService.createBody(
            from: RideRequestInput(
                pickup: try XCTUnwrap(state.draftPickup),
                destination: RideRequestFixtures.recentPlaces[1],
                fleetMemberID: "veh-1",
                passenger: nil
            ),
            vehicleId: "veh-1"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any]
        )
        let wirePickup = try XCTUnwrap(object["pickup"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(wirePickup["lat"] as? Double), Self.nudged.latitude, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(wirePickup["lng"] as? Double), Self.nudged.longitude, accuracy: 1e-9)
    }
}
