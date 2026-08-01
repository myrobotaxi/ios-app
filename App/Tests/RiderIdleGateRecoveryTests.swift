import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-402 — "A ride is N min away" comes back when the ride does
//
// THE CLIENT'S REPORT (2026-07-31 evening, build 202607311641): his active ride was
// cancelled SERVER-SIDE and the rider idle sheet's rotating placeholder never came
// back. His rule, verbatim: *"if you had a ride in progress and then no longer in
// progress the app should not have to be forced closed for the ride is x min away
// to show up."*
//
// THE MECHANISM, and it is not the gate the issue's title guessed at. MYR-341's
// four honesty gates were all correct; TWO of their INPUTS could only be corrected
// by a cold launch, which is why a force-quit fixed it and nothing else did.
//
//  1. `RiderIdleGate.carAvailability` — THE ONE THAT FIRES ON THE HAPPY PATH.
//     Its input is `VehicleSummary.hasActiveRide` off `GET /api/vehicles`, and
//     `RiderLiveVehicleLocator` fetched that list exactly ONCE per rider-map mount.
//     Nothing re-read it on a ride ending, on a foreground, or on a push tap.
//     Worse, the staleness was MASKED for the whole ride and unmasked exactly when
//     the ride ended: MYR-233's own-ride exception suppresses `.busy` for the rider
//     holding the ride, so the moment the ride was erased the exception lifted and
//     the pre-ride row — `hasActiveRide: true` — became load-bearing. **The gate
//     CLOSED on the transition that should have opened it.** Everything else about
//     the frame was correct, which is why the client reported only the placeholder.
//
//  2. `RiderIdleGate.requestInFlight` — the one that fires when the frame is
//     missed. `refreshActiveRide()` was `adoptOpenRiderRide()`, whose first line is
//     `guard activeRequest == nil`: adopt-only, so the rider's slot was releasable
//     by the WS `ride_status_changed` frame and by NOTHING else. A socket that was
//     down, backgrounded or terminally `auth_failed` (MYR-387's own finding) left a
//     cancelled ride in the slot for the rest of the session.
//
// Both are driven here through the REAL composition — the production
// `RiderLiveVehicleLocator` over a routed HTTP stub whose `/vehicles` body CHANGES,
// and the production `LiveRideRequestService` over a scripted API + a controllable
// event stream. Seeding a `FleetMember` or an `activeRequest` by hand would pass
// over exactly the two reads this issue is about.
@MainActor
final class RiderIdleGateRecoveryTests: XCTestCase {

    // MARK: Wire fixtures

    /// The rider's own car. `hasActiveRide` is the whole subject: `true` is the row
    /// the server serves WHILE the ride runs, `false` the moment it ends.
    private nonisolated static func ownedRow(hasActiveRide: Bool) -> VehicleSummary {
        VehicleSummary(
            vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "3795", status: .parked,
            chargeLevel: 71, estimatedRange: 244,
            lastUpdated: "2026-07-31T22:40:00.000Z", role: .owner,
            hasActiveRide: hasActiveRide
        )
    }

    /// Embarcadero Center — the car. ~1.4 mi from the rider below, so the estimate
    /// is a real, non-zero minute count out of the production `RiderPickupETA`.
    private static let carFix = CLLocationCoordinate2D(latitude: 37.7949, longitude: -122.3995)
    /// The Ferry Building — the rider.
    private static let riderFix = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)

    private nonisolated static func snapshot(at coordinate: CLLocationCoordinate2D) -> VehicleState {
        VehicleState(
            vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2026,
            color: "Quicksilver", vin: "7SAYGDET7TA613795",
            softwareVersion: "2026.20.6.6", trim: nil,
            status: .parked, speed: 0, heading: 180,
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            locationName: "Embarcadero Center \u{00B7} Lot B",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 71, chargeState: nil, estimatedRange: 244, timeToFull: nil,
            interiorTemp: 68, exteriorTemp: 61,
            odometerMiles: 6349, fsdMilesSinceReset: 812.5,
            lastUpdated: "2026-07-31T22:41:00.000Z"
        )
    }

    private nonisolated static func body(_ state: VehicleState) -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(state)
    }

    private nonisolated static func wireRide(
        id: String,
        status: MyRobotaxiContracts.RideRequestStatus
    ) -> MyRobotaxiContracts.RideRequest {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = stamp.string(from: Date())
        return MyRobotaxiContracts.RideRequest(
            id: id, riderId: "u-rider", ownerId: "u-rider", vehicleId: "veh-live",
            pickup: MyRobotaxiContracts.RidePlace(lat: riderFix.latitude, lng: riderFix.longitude, label: "Current location"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO \u{00B7} Terminal 2"),
            status: status, scheduledFor: nil,
            createdAt: now, updatedAt: now,
            acceptedAt: status == .requested ? nil : "2026-07-31T22:30:00.000Z"
        )
    }

    // MARK: Composition

    /// The rider's live surface, assembled the way `RootView` assembles it: the
    /// production locator over a routed wire, the production viewer state over the
    /// locator, and the production ride service over a scripted API + event stream.
    private struct Rig {
        let http: RoutedHTTP
        let api: ScriptedRideAPI
        let socket: ControllableRideSocket
        let locator: RiderLiveVehicleLocator
        let state: SharedViewerState
        let service: LiveRideRequestService
    }

    private func makeRig(hasActiveRide: Bool) -> Rig {
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.body(Self.snapshot(at: Self.carFix))),
            .init("/vehicles", body: Contracts.listResponse([Self.ownedRow(hasActiveRide: hasActiveRide)])),
        ])
        let locator = RiderLiveVehicleLocator(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: AuthenticatingChannelFactory()
        ))
        let state = SharedViewerState(vehicle: nil, seams: .init(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: FixedRiderLocation(coordinate: Self.riderFix),
            liveVehicleLocator: locator,
            pinLabeler: SimulatedPinLabeler(),
            isLive: true
        ))
        let api = ScriptedRideAPI()
        let socket = ControllableRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: false)
        return Rig(http: http, api: api, socket: socket, locator: locator, state: state, service: service)
    }

    /// The screen's own one line (`SharedViewerScreen.syncRiderOwnsActiveRide`),
    /// which is all of it: `riderOwnsActiveRide` is `private(set)` and this setter
    /// is its only door, so a screen cannot lift the exception without the re-read.
    private func syncOwnRide(_ rig: Rig) {
        rig.state.setRiderOwnsActiveRide(
            RiderOwnRideException.holdsOpenRide(status: rig.service.activeRequest?.status)
        )
    }

    /// The placeholder, resolved exactly as `SharedViewerScreen.searchPlaceholders`
    /// resolves it — through the shipping gates, off the shipping state.
    private func gate(_ rig: Rig) -> RiderIdleGate? {
        RiderIdlePlaceholder.suppressingGate(
            pickupETAMinutes: rig.state.pickupETAMinutes,
            unavailability: rig.state.liveFleetMember?.unavailability,
            hasActiveRequest: rig.service.activeRequest != nil
        )
    }

    private func placeholders(_ rig: Rig) -> [String] {
        RiderIdlePlaceholder.items(
            resolvesLiveETA: rig.state.resolvesPickupETA,
            pickupETAMinutes: rig.state.pickupETAMinutes,
            unavailability: rig.state.liveFleetMember?.unavailability,
            hasActiveRequest: rig.service.activeRequest != nil
        )
    }

    /// Bring the rig up to the client's starting condition: the map is on screen,
    /// the car is streaming, the list says the car is busy, and the rider holds the
    /// ride that made it busy. The placeholder is suppressed — correctly — by the
    /// request-in-flight gate.
    private func startMidRide(_ rig: Rig) async {
        rig.state.startTelemetry()
        // The ride reaches the slot by the SHIPPING cold-launch adoption
        // (`start()` → `adoptOpenRiderRide`), so `riderServerRideID` is set the way
        // production sets it — which is what the re-read below is narrowed on.
        await rig.api.setRides([Self.wireRide(id: "srv-402", status: .enroute)])
        await rig.api.setDetail(Self.wireRide(id: "srv-402", status: .enroute))
        rig.service.start()
        await eventually { rig.service.activeRequest?.status == .enroute }
        // The RAW endpoints, then the seat — `SharedViewerScreen` does this from
        // `.onChange(of: pickupETAFixKey, initial: true)`; there is no view here.
        await eventually { rig.state.liveFleetMember != nil && rig.locator.coordinate != nil }
        rig.state.refreshPickupETAAnchors()
        XCTAssertNotNil(rig.state.pickupETAMinutes, "both endpoints are known — the estimate gate is open")
        syncOwnRide(rig)
        XCTAssertEqual(gate(rig), .requestInFlight,
                       "with a ride running the placeholder is suppressed by the ride, not by the car")
        // …and NOT by the car: the own-ride exception is masking a row that already
        // says `hasActiveRide: true`. That mask is the whole trap.
        XCTAssertNil(rig.state.liveFleetMember?.unavailability)
    }

    /// Deliver the server's `ride_status_changed` for the held ride.
    private func pushStatusFrame(_ rig: Rig, status: RideStatusChangedPayload.Status) async {
        await eventually { await rig.socket.isListening }
        await rig.socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-402", vehicleId: "veh-live", status: status,
            timestamp: "2026-07-31T22:45:00.000Z"
        )))
    }

    /// Wait for the list to have been read `count` times, then let the load task
    /// unwind — `refreshFleet` coalesces onto an in-flight load, so a second trigger
    /// fired before the first settles is legitimately a no-op and would make the
    /// next assertion a race rather than a fact.
    private func awaitListReads(_ rig: Rig, _ count: Int) async {
        await eventually { await rig.http.callCount(suffix: "/vehicles") == count }
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - The recovery matrix

    /// ARM 1 — THE WS FRAME. The server cancels; `ride_status_changed` lands while
    /// the app is foregrounded; the placeholder must come back with no relaunch.
    ///
    /// This is the arm that fails on the pre-fix build even though every part of the
    /// erasure works: `integrate` empties the slot, `requestInFlight` opens, and the
    /// gate immediately re-closes on `carAvailability` because the list row still
    /// says `hasActiveRide: true`. The rider is told their own finished ride means
    /// the car is busy.
    func testTheFrameThatEndsTheRideBringsThePlaceholderBack() async {
        let rig = makeRig(hasActiveRide: true)
        await startMidRide(rig)

        // The server cancelled it, and the list row it serves says so from now on.
        await rig.api.setCancelled(Self.wireRide(id: "srv-402", status: .cancelled))
        await rig.http.setBody(suffix: "/vehicles",
                               body: Contracts.listResponse([Self.ownedRow(hasActiveRide: false)]))
        await pushStatusFrame(rig, status: .cancelled)

        await eventually { rig.service.activeRequest == nil }
        syncOwnRide(rig) // the screen's `.onChange(of: activeRequest?.status)`

        await eventually { self.gate(rig) == nil }
        XCTAssertEqual(placeholders(rig).count, 2, "the rotation is back — two items, not one")
        XCTAssertTrue(placeholders(rig)[1].hasPrefix("A ride is "), placeholders(rig)[1])
    }

    /// ARM 2 — THE FOREGROUND REFETCH, WITH THE SOCKET DOWN. No frame ever arrives:
    /// the ride was cancelled while the app was suspended. The resume must reach the
    /// same state the frame would have.
    ///
    /// This arm fails TWICE on the pre-fix build — the slot is never released
    /// (`refreshActiveRide` was adopt-only) and the list is never re-read — so it is
    /// the one that proves both latches rather than one.
    func testTheForegroundRefetchRecoversWithNoFrameAtAll() async {
        let rig = makeRig(hasActiveRide: true)
        await startMidRide(rig)

        // Cancelled while away. The socket delivers nothing, ever.
        await rig.api.setCancelled(Self.wireRide(id: "srv-402", status: .cancelled))
        await rig.http.setBody(suffix: "/vehicles",
                               body: Contracts.listResponse([Self.ownedRow(hasActiveRide: false)]))

        // `RootView`'s `scenePhase == .active` arm, in its own order.
        rig.state.handleForeground()
        await rig.service.refreshActiveRide()
        syncOwnRide(rig)

        XCTAssertNil(rig.service.activeRequest,
                     "a refetch must be able to EMPTY the rider's slot, not only fill it")
        await eventually { self.gate(rig) == nil }
        XCTAssertEqual(placeholders(rig).count, 2)
    }

    /// The clean statement of latch 1 ON ITS OWN, with the slot behaving perfectly.
    /// Nothing here touches the ride service after the erasure — the only question
    /// is whether the availability gate can be re-opened without a relaunch.
    func testTheAvailabilityGateReopensWithoutARelaunch() async {
        let rig = makeRig(hasActiveRide: true)
        await startMidRide(rig)

        // Erase the slot exactly as `integrate` does for a `cancelled` wire status.
        await rig.api.setCancelled(Self.wireRide(id: "srv-402", status: .cancelled))
        await pushStatusFrame(rig, status: .cancelled)
        await eventually { rig.service.activeRequest == nil }

        // The car is free now. The list says so; nothing has asked it.
        await rig.http.setBody(suffix: "/vehicles",
                               body: Contracts.listResponse([Self.ownedRow(hasActiveRide: false)]))
        XCTAssertEqual(rig.state.liveFleetMember?.unavailability, nil,
                       "while the exception is still up the stale row is masked")

        syncOwnRide(rig) // the exception lifts — and takes the mask with it
        await eventually { rig.state.liveFleetMember?.unavailability == nil }
        XCTAssertEqual(gate(rig), nil,
                       "the lifted exception must land on a RE-READ row, not the pre-ride one")
    }

    /// THE STALE ROW IS WHAT MAKES THE ABOVE A REAL TEST. Run the identical sequence
    /// with the server still reporting the car busy and the gate must STAY closed —
    /// otherwise the recovery tests would pass just as well against a client that
    /// ignored `hasActiveRide` altogether.
    func testACarThatIsGenuinelyStillBusyStaysGated() async {
        let rig = makeRig(hasActiveRide: true)
        await startMidRide(rig)

        await rig.api.setCancelled(Self.wireRide(id: "srv-402", status: .cancelled))
        await pushStatusFrame(rig, status: .cancelled)
        await eventually { rig.service.activeRequest == nil }
        // The list keeps saying busy — somebody ELSE's ride is on this car.
        syncOwnRide(rig)
        await eventually { await rig.http.callCount(suffix: "/vehicles") >= 2 }

        XCTAssertEqual(gate(rig), .carAvailability)
        XCTAssertEqual(placeholders(rig), [RiderIdlePlaceholder.destinationPrompt])
    }

    // MARK: - The sweep: no gate input may be refreshable only by a cold launch

    /// EVERY GATE, ONE SWEEP. For each `RiderIdleGate`, close it, remove the reason,
    /// fire the recovery funnel and require it to open — in ONE process.
    ///
    /// Written over `allCases` rather than as three named tests so a gate added
    /// later cannot be added without an answer to "what re-opens it?". That is the
    /// invariant this issue exists to install: the placeholder's inputs are observed
    /// state that updates from the events that end a ride, and **no gate may latch**.
    func testEveryGateCanBeReopenedInOneProcess() async {
        for gateUnderTest in RiderIdleGate.allCases {
            let rig = makeRig(hasActiveRide: gateUnderTest == .carAvailability)
            rig.state.startTelemetry()
            await eventually { rig.state.liveFleetMember != nil }

            switch gateUnderTest {
            case .requestInFlight:
                await rig.api.setRides([Self.wireRide(id: "srv-402", status: .enroute)])
                await rig.api.setDetail(Self.wireRide(id: "srv-402", status: .enroute))
                rig.service.start()
                await eventually { rig.service.activeRequest != nil }
                syncOwnRide(rig)
                rig.state.refreshPickupETAAnchors()
                XCTAssertEqual(gate(rig), .requestInFlight)
                // Remove the reason: the server says it is over, and only a REFETCH
                // is allowed to find that out — no frame is pushed here.
                await rig.api.setCancelled(Self.wireRide(id: "srv-402", status: .cancelled))
                await rig.service.refreshActiveRide()

            case .carAvailability:
                await eventually { rig.locator.coordinate != nil }
                rig.state.refreshPickupETAAnchors()
                XCTAssertEqual(gate(rig), .carAvailability)
                await rig.http.setBody(suffix: "/vehicles",
                                       body: Contracts.listResponse([Self.ownedRow(hasActiveRide: false)]))
                rig.state.refreshRideEndGateInputs()

            case .pickupEstimate:
                // Honesty gate 1 with no device fix at all. The car's coordinate is
                // already streaming, so the ONLY missing endpoint is the rider's —
                // which is what makes this the estimate gate and not the vehicle one.
                let phone = MovableRiderLocation()
                let noFix = SharedViewerState(vehicle: nil, seams: .init(
                    placeSearch: SimulatedPlaceSearch(),
                    userLocation: phone,
                    liveVehicleLocator: rig.locator,
                    pinLabeler: SimulatedPinLabeler(),
                    isLive: true
                ))
                await eventually { rig.locator.coordinate != nil }
                noFix.refreshPickupETAAnchors()
                XCTAssertEqual(
                    RiderIdlePlaceholder.suppressingGate(
                        pickupETAMinutes: noFix.pickupETAMinutes,
                        unavailability: noFix.liveFleetMember?.unavailability,
                        hasActiveRequest: false
                    ),
                    .pickupEstimate
                )
                // The fix lands. The funnel re-seats the anchors over it — no
                // relaunch, and no waiting for the next `pickupETAFixKey` change.
                phone.coordinate = Self.riderFix
                noFix.refreshRideEndGateInputs()
                XCTAssertNil(
                    RiderIdlePlaceholder.suppressingGate(
                        pickupETAMinutes: noFix.pickupETAMinutes,
                        unavailability: noFix.liveFleetMember?.unavailability,
                        hasActiveRequest: false
                    ),
                    "the estimate gate re-opens on a re-seat, in-process"
                )
                rig.state.stopTelemetry()
                continue
            }

            syncOwnRide(rig)
            await eventually { self.gate(rig) == nil }
            XCTAssertNil(gate(rig), "\(gateUnderTest) latched — only a relaunch would clear it")
            rig.state.stopTelemetry()
        }
    }

    /// THE FLEET LIST IS RE-READ ON ALL THREE EVENTS the invariant names. Asserted on
    /// the REQUEST COUNT, because "the gate opened" can be satisfied by a lucky
    /// cached value and "the client asked again" cannot.
    func testTheListIsReReadOnEveryRideEndingEvent() async {
        let rig = makeRig(hasActiveRide: true)
        rig.state.startTelemetry()
        await awaitListReads(rig, 1)

        // 1 — the WS frame arm, i.e. the own-ride exception lifting.
        rig.state.setRiderOwnsActiveRide(true)
        rig.state.setRiderOwnsActiveRide(false)
        await awaitListReads(rig, 2)

        // 2 — the foreground refetch.
        rig.state.handleForeground()
        await awaitListReads(rig, 3)

        // 3 — the push tap (`RootView.applyPushTapRoute(.riderActiveFlow)`).
        rig.state.refreshRideEndGateInputs()
        await awaitListReads(rig, 4)

        rig.state.stopTelemetry()
    }

    /// RAISING the exception must NOT refetch, and neither may a re-sync that changes
    /// nothing. `syncRiderOwnsActiveRide` runs on every appearance and every status
    /// fold; a refetch on each would be a poll wearing an observer's clothes.
    func testOnlyTheLiftingEdgeRefetches() async {
        let rig = makeRig(hasActiveRide: false)
        rig.state.startTelemetry()
        await eventually { await rig.http.callCount(suffix: "/vehicles") == 1 }

        rig.state.setRiderOwnsActiveRide(false) // false → false
        rig.state.setRiderOwnsActiveRide(true)  // false → true (the mask going ON)
        rig.state.setRiderOwnsActiveRide(true)  // true → true
        try? await Task.sleep(for: .milliseconds(120))
        let count = await rig.http.callCount(suffix: "/vehicles")
        XCTAssertEqual(count, 1, "nothing but the LIFT is a reason to re-read")

        rig.state.stopTelemetry()
    }

    /// A refetch with the map off screen makes no request at all — `refreshFleet` is
    /// gated on `started` for the same reason `handleForeground` is: a rider in
    /// Settings holds no socket and should hold no polling either.
    func testNoRequestIsMadeWhileTheMapIsOffScreen() async {
        let rig = makeRig(hasActiveRide: true)
        rig.state.refreshRideEndGateInputs()
        try? await Task.sleep(for: .milliseconds(120))
        let count = await rig.http.callCount(suffix: "/vehicles")
        XCTAssertEqual(count, 0)
    }

    // MARK: - The narrowing on the slot re-read

    /// A read that FAILS is not evidence that a ride ended (MYR-326's rule, pointed
    /// at the rider's slot). The held record must survive a 500.
    func testAFailedReReadLeavesTheHeldRideAlone() async {
        let rig = makeRig(hasActiveRide: true)
        await startMidRide(rig)

        await rig.api.setDetailError(RestError.http(status: 500, code: nil, message: nil, subCode: nil))
        await rig.service.refreshActiveRide()

        XCTAssertEqual(rig.service.activeRequest?.status, .enroute,
                       "a request that did not answer says nothing about the ride")
    }

    /// An OPTIMISTIC record — a create still inside MYR-218's grace window — has no
    /// server ride to ask about, so the re-read must not touch it. Asking would 404
    /// and folding a 404 would discard a ride the rider is part-way through booking.
    func testAnOptimisticRecordIsNeverReReadAway() async {
        let rig = makeRig(hasActiveRide: false)
        rig.state.startTelemetry()
        rig.service.submit(Self.sampleInput())
        XCTAssertEqual(rig.service.activeRequest?.status, .pending)

        await rig.service.refreshActiveRide()

        XCTAssertEqual(rig.service.activeRequest?.status, .pending,
                       "no server id means nothing to reconcile against")
        let detailCount = await rig.api.detailCount
        XCTAssertEqual(detailCount, 0, "and nothing was asked")
        rig.state.stopTelemetry()
    }

    /// MYR-397's awaited cancel documented that "the caller's `refreshActiveRide()`
    /// re-reads and `integrate` maps the wire's `cancelled` to the record
    /// disappearing" — and it did not re-read anything. `stillStands` was reporting
    /// the LOCAL optimistic record back to itself; it happened to be right only
    /// because a frame usually followed. Now the verdict is the server's.
    func testTheAwaitedCancelsReReadNowActuallyReReads() async {
        let rig = makeRig(hasActiveRide: true)
        await startMidRide(rig)
        let before = await rig.api.detailCount

        try? await rig.service.cancelActiveRide(id: "srv-402")
        await rig.api.setCancelled(Self.wireRide(id: "srv-402", status: .cancelled))
        await rig.service.refreshActiveRide()

        let after = await rig.api.detailCount
        XCTAssertGreaterThan(after, before, "the re-read has to actually hit the wire")
        XCTAssertFalse(
            RiderActiveRideCancel.stillStands(status: rig.service.activeRequest?.status),
            "the cancel is settled by the server's record, not by the local optimism"
        )
    }

    // MARK: - The derived items array cannot drift from the gate

    func testItemsIsDerivedFromTheGate() {
        let matrix: [(Int?, FleetUnavailability?, Bool)] = [
            (9, nil, false), (9, nil, true), (9, .busy, false), (9, .inService, false),
            (nil, nil, false), (0, nil, false), (nil, .paused, true),
        ]
        for (minutes, unavailability, active) in matrix {
            let gate = RiderIdlePlaceholder.suppressingGate(
                pickupETAMinutes: minutes, unavailability: unavailability, hasActiveRequest: active
            )
            let items = RiderIdlePlaceholder.items(
                pickupETAMinutes: minutes, unavailability: unavailability, hasActiveRequest: active
            )
            XCTAssertEqual(items.count, gate == nil ? 2 : 1,
                           "gate \(String(describing: gate)) vs items \(items)")
        }
    }

    func testTheGateNamesTheMostSpecificReason() {
        XCTAssertEqual(
            RiderIdlePlaceholder.suppressingGate(pickupETAMinutes: nil, unavailability: .busy, hasActiveRequest: true),
            .requestInFlight,
            "with a ride in flight nothing else is worth naming"
        )
        XCTAssertEqual(
            RiderIdlePlaceholder.suppressingGate(pickupETAMinutes: nil, unavailability: .busy, hasActiveRequest: false),
            .carAvailability
        )
    }

    // MARK: - The pure own-ride rule

    func testTheOwnRideExceptionClassifiesEveryStatusAndTheAbsence() {
        XCTAssertTrue(RiderOwnRideException.holdsOpenRide(status: .pending))
        XCTAssertTrue(RiderOwnRideException.holdsOpenRide(status: .accepted))
        XCTAssertTrue(RiderOwnRideException.holdsOpenRide(status: .arrived))
        XCTAssertTrue(RiderOwnRideException.holdsOpenRide(status: .enroute))
        XCTAssertFalse(RiderOwnRideException.holdsOpenRide(status: .completed))
        XCTAssertFalse(RiderOwnRideException.holdsOpenRide(status: .declined))
        XCTAssertFalse(RiderOwnRideException.holdsOpenRide(status: nil),
                       "a cancelled ride reaches this rule as an ABSENCE (MYR-172's erasure)")
    }

    // MARK: - Helpers

    private static func sampleInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(id: "p", label: "Current location", subtitle: nil, miles: 0, minutes: 0,
                              icon: "mappin", coordinate: riderFix),
            destination: RidePlace(id: "d", label: "SFO \u{00B7} Terminal 2", subtitle: nil, miles: 18.4, minutes: 24,
                                   icon: "mappin",
                                   coordinate: CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)),
            fleetMemberID: "veh-live"
        )
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

// MARK: - Test doubles

/// A `UserLocationProviding` whose fix never moves — the anchors are the subject
/// here, not the stream.
private final class FixedRiderLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}

/// The same, with a fix that ARRIVES — a phone that had no permission (or no lock)
/// when the map mounted and got one afterwards, which is `pickupEstimate`'s own
/// recovery.
private final class MovableRiderLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}

/// A `RideRequestAPI` whose DETAIL answer can be replaced mid-test — the wire's
/// half of "the ride is over now".
private actor ScriptedRideAPI: RideRequestAPI {
    private var detail: MyRobotaxiContracts.RideRequest?
    private var detailError: Error?
    private var rides: [MyRobotaxiContracts.RideRequest] = []
    private(set) var detailCount = 0

    func setDetail(_ ride: MyRobotaxiContracts.RideRequest) { detail = ride; detailError = nil }
    func setDetailError(_ error: Error) { detailError = error }
    func setRides(_ items: [MyRobotaxiContracts.RideRequest]) { rides = items }

    /// The server cancelled the ride: BOTH the detail read and the rider's own list
    /// say so from now on. Setting only the detail would model a server that
    /// contradicts itself, and `adoptOpenRiderRide` running straight after the
    /// release would re-adopt the ride the release just let go.
    func setCancelled(_ ride: MyRobotaxiContracts.RideRequest) {
        detail = ride
        detailError = nil
        rides = [ride]
    }

    func vehicles() async throws -> [VehicleSummary] {
        [VehicleSummary(vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2026,
                        color: "Quicksilver", vinLast4: "3795", status: .parked,
                        chargeLevel: 71, estimatedRange: 244,
                        lastUpdated: "2026-07-31T22:40:00.000Z", role: .owner)]
    }

    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }

    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: rides, hasMore: false)
    }

    func rideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        detailCount += 1
        if let detailError { throw detailError }
        guard let detail else { throw RestError.http(status: 404, code: nil, message: nil, subCode: nil) }
        return detail
    }

    func cancelRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        guard let detail else { throw RestError.http(status: 404, code: nil, message: nil, subCode: nil) }
        return detail
    }
    func acceptRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func declineRideRequest(id: String) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func pickedUp(rideID: String) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func start(rideID: String) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func droppedOff(rideID: String) async throws -> MyRobotaxiContracts.RideRequest {
        throw RestError.http(status: 501, code: nil, message: nil, subCode: nil)
    }
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: [], hasMore: false)
    }
}

/// A ride-event source the test drives by hand — and, for the foreground arm,
/// deliberately never drives at all.
private actor ControllableRideSocket: RideEventStreaming {
    private var continuation: AsyncStream<RideRequestEvent>.Continuation?
    var isListening: Bool { continuation != nil }
    func rideEvents() async -> AsyncStream<RideRequestEvent> {
        let (stream, continuation) = AsyncStream<RideRequestEvent>.makeStream()
        self.continuation = continuation
        return stream
    }
    func connect() async {}
    func disconnect() async {}
    func push(_ event: RideRequestEvent) { continuation?.yield(event) }
}
