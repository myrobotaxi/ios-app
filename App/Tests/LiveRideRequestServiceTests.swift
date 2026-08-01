import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-209 — LiveRideRequestService against a stubbed Kit layer (no network)
//
// Drives the live ride-request service through the `RideRequestAPI` +
// `RideEventStreaming` seams with in-memory stubs. Verifies the seam the rider's
// SharedViewerScreen + the owner's IncomingRequestSheet consume:
//  • submit → optimistic pending + POST create (targets the resolved vehicle),
//  • pending → accepted / declined via the owner methods + the matching POST,
//  • cancel → clears the request + POST cancel on the server id,
//  • a `ride_status_changed` WS frame refetches the detail and reconciles state.
@MainActor
final class LiveRideRequestServiceTests: XCTestCase {

    /// MYR-396 — the service's DEFAULT owner-dispatch pointer is the real
    /// `UserDefaults` one, because production must not be able to forget it. In a
    /// test host that is the RUNNER's defaults, so a test that accepts a ride
    /// leaves an id behind and the next test to `start()` would cold-adopt it —
    /// a phantom `ownerRequest` from a neighbouring test, appearing or not
    /// depending on execution order. Cleared before each test, the same rule
    /// `RootView.recentDestinationsStore()` applies to recents: a persistent store
    /// must never leak between runs.
    override func setUp() {
        super.setUp()
        UserDefaultsOwnerDispatchPointer().clear()
    }

    // MARK: pending → accepted

    /// MYR-325 — `accept()` is an OWNER action, so it is driven from the OWNER
    /// pipeline (the incoming feed), not from a rider `submit()`. Before the split
    /// this test reached the same state through the shared slot; the assertions
    /// (optimistic accepted, POST on the SERVER id) are unchanged.
    func testAcceptTransitionsPendingToAcceptedAndPosts() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([Self.wireRide(id: "srv-1", status: .requested)])
        await api.setDetail(Self.wireRide(id: "srv-1", status: .accepted, accepted: true))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()
        XCTAssertEqual(service.incomingRequest?.status, .pending)

        service.accept()
        XCTAssertEqual(service.ownerDispatch?.status, .accepted)
        XCTAssertNil(service.incomingRequest, "the answered card clears synchronously")
        await eventually { await api.acceptCount == 1 }
        let acceptID = await api.lastAcceptID
        XCTAssertEqual(acceptID, "srv-1", "accept targets the server-assigned id")
    }

    /// The rider's create still resolves its target vehicle from `vehicles()` — the
    /// half of the old accept test that was really about `submit`.
    func testSubmitResolvesTheCreateTargetVehicle() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-1v", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        service.confirmSend() // MYR-218: the deferred create POST fires on send
        await eventually { await api.createCount == 1 }
        await eventually { await api.lastCreateVehicleID == "veh-live" } // resolved from vehicles()
    }

    // MARK: pending → declined

    /// MYR-325 — `decline()` is likewise an OWNER action on the OWNER pipeline.
    func testDeclineTransitionsPendingToDeclinedAndPosts() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([Self.wireRide(id: "srv-2", status: .requested)])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()

        service.decline()
        XCTAssertEqual(service.ownerRequest?.status, .declined)
        XCTAssertNil(service.incomingRequest, "a declined request is on no owner surface")
        await eventually { await api.declineCount == 1 }
        let declineID = await api.lastDeclineID
        XCTAssertEqual(declineID, "srv-2")
    }

    // MARK: cancel

    func testCancelClearsActiveRequestAndPostsCancelOnServerID() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-3", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 } // serverRideID now set

        service.cancel()
        XCTAssertNil(service.activeRequest, "cancel drops the active request")
        await eventually { await api.cancelCount == 1 }
        let cancelID = await api.lastCancelID
        XCTAssertEqual(cancelID, "srv-3")
    }

    // MARK: MYR-218 defect 1 — the countdown is a REAL send grace window

    /// The create POST must NOT fire at booking entry: while the rider's
    /// "Sending request 10s" fill is running, no server ride exists yet, so the
    /// owner's simulator cannot have received the request (the client's
    /// side-by-side complaint). `submit` shows the optimistic pending but makes
    /// zero API calls until the send is confirmed.
    func testSubmitDefersCreatePOSTUntilSendConfirmed() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-defer", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        // Give any stray background work a beat — no create must have fired.
        try? await Task.sleep(nanoseconds: 40_000_000)
        let createdBeforeSend = await api.createCount
        XCTAssertEqual(createdBeforeSend, 0, "no create POST fires during the countdown window")

        service.confirmSend() // "Tap to send now"
        await eventually { await api.createCount == 1 }
    }

    /// The countdown-zero auto-send and a "Tap to send now" tap share ONE
    /// idempotent trigger — a double-fire (tap racing the timer, or two taps)
    /// still produces exactly one create POST.
    func testConfirmSendFiresExactlyOnePOST() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-once", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        service.confirmSend()
        service.confirmSend() // racing second signal — must be a no-op
        await eventually { await api.createCount == 1 }
        try? await Task.sleep(nanoseconds: 40_000_000)
        let count = await api.createCount
        XCTAssertEqual(count, 1, "the send trigger is idempotent — never a double POST")
    }

    /// Cancelling DURING the window discards locally with ZERO server calls (no
    /// serverRideID exists yet) and clears the record — and the armed
    /// countdown-zero timer must not fire a create after the cancel.
    func testCancelDuringWindowMakesZeroAPICallsAndClearsRecord() async {
        // A short window so we can prove the timer never fires a POST post-cancel.
        let api = StubRideAPI(created: Self.wireRide(id: "srv-win", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false,
                                             sendWindow: .milliseconds(20))

        service.submit(Self.sampleInput())
        service.cancel()
        XCTAssertNil(service.activeRequest, "cancel-during-window clears the optimistic record")

        // Wait past the original window: the disarmed timer must not send.
        try? await Task.sleep(nanoseconds: 80_000_000)
        let createCount = await api.createCount
        let cancelCount = await api.cancelCount
        XCTAssertEqual(createCount, 0, "no create POST — the ride never reached the server")
        XCTAssertEqual(cancelCount, 0, "no remote cancel — there is no serverRideID to cancel")
    }

    /// Reaching countdown zero (no tap) fires the deferred POST on its own and
    /// keeps the request pending — the owner now receives it, at the END of the
    /// grace window rather than the start.
    func testCountdownZeroFiresSendAndKeepsPending() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-zero", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false,
                                             sendWindow: .milliseconds(20))

        service.submit(Self.sampleInput())
        let createdAtSubmit = await api.createCount
        XCTAssertEqual(createdAtSubmit, 0, "nothing sent at submit time")

        // No tap — the window elapses and the auto-send fires.
        await eventually { await api.createCount == 1 }
        XCTAssertEqual(service.activeRequest?.status, .pending, "the request stays pending after the auto-send")
    }

    // MARK: MYR-212 defect 3 (round 2) — classify create failures

    /// DEFINITIVE (typed HTTP 4xx): the server refused the create, so no ride
    /// exists — the optimistic pending must NOT linger as a stuck "Waiting…"
    /// card. It transitions to `.declined`, which is exactly what drives the
    /// SharedViewerScreen's existing declined affordance (owner-decline reuse).
    func testDefinitiveCreateFailureDropsOptimisticPendingIntoDeclined() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-x", status: .requested),
            createError: RestError.http(status: 403, code: .permissionDenied, message: "forbidden", subCode: nil)
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        service.confirmSend()
        await eventually { await api.createCount == 1 } // the refused POST fired

        // Declined affordance state set; the stuck pending is gone; no re-POST /
        // reconcile GET was attempted (a 4xx is not indeterminate).
        await eventually { service.activeRequest?.status == .declined }
        let listCount = await api.rideListCount
        XCTAssertEqual(listCount, 0, "a definitive 4xx never reconciles via GET")
    }

    /// INDETERMINATE (transport blip): the create MAY have landed on the server.
    /// The optimistic pending survives (round-1 fix, carrying the real draft
    /// labels) and a background reconcile GET discovers the real ride and adopts
    /// its server id — proven by a subsequent mutation targeting that id.
    func testIndeterminateCreateFailureSurvivesAndReconcileAdoptsFoundRide() async {
        let input = Self.liveInput()
        // The server DID create it (visible in the rider's own ride list) even
        // though the POST's response never reached the client.
        let landed = Self.wireRide(
            id: "srv-found", status: .requested,
            pickup: MyRobotaxiContracts.RidePlace(lat: input.pickup.coordinate.latitude, lng: input.pickup.coordinate.longitude, label: "1200 Grandscape Blvd"),
            dropoff: MyRobotaxiContracts.RidePlace(lat: input.destination.coordinate.latitude, lng: input.destination.coordinate.longitude, label: "Bell Southstone Yards")
        )
        let api = StubRideAPI(created: landed, createError: URLError(.timedOut))
        await api.setRideList([landed])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false, reconcilePolicy: Self.fastReconcile)

        service.submit(input)
        service.confirmSend()
        await eventually { await api.createCount == 1 } // the failing POST fired
        await eventually { await api.rideListCount >= 1 } // reconcile polled the rider's list

        // Record survives with the REAL draft labels (not placeholders).
        XCTAssertEqual(service.activeRequest?.status, .pending, "an indeterminate failure keeps the optimistic pending")
        XCTAssertEqual(service.activeRequest?.input.destination.label, "Bell Southstone Yards")
        XCTAssertEqual(service.activeRequest?.input.pickup.label, "1200 Grandscape Blvd")

        // Adoption: RIDER mutations now target the DISCOVERED server id, not the
        // local UUID. (MYR-325: `cancel()` rather than `accept()` — accept belongs
        // to the owner pipeline, which this rider-side reconcile never touches.)
        service.cancel()
        await eventually { await api.cancelCount == 1 }
        let cancelID = await api.lastCancelID
        XCTAssertEqual(cancelID, "srv-found", "reconcile adopted the found ride's server id")
    }

    /// INDETERMINATE but the reconcile GET finds NOTHING within the window: the
    /// create truly never landed → fall through to the definitive path (declined).
    func testIndeterminateCreateFailureWithNoMatchFallsThroughToDefinitive() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-x", status: .requested), createError: URLError(.timedOut))
        // rideList stays empty — the server never created the ride.
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false, reconcilePolicy: Self.fastReconcile)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await api.rideListCount >= 1 } // reconcile tried

        // Nothing matched across the window → definitive → declined affordance.
        await eventually { service.activeRequest?.status == .declined }
    }

    // MARK: MYR-220 — session/connection failures are NOT owner declines

    /// A bare HTTP 401 on the create POST means the SESSION died mid-send (token
    /// expired), not that the owner refused. The optimistic pending must NOT
    /// become `.declined` (that renders "… can't take this ride right now" for a
    /// dead session); it clears, `sessionFailure` is flagged for the rider's calm
    /// retry, and no reconcile GET runs (a 401 is not indeterminate).
    func testAuthFailure401OnCreateFlagsSessionErrorNotDeclined() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-401", status: .requested),
            createError: RestError.http(status: 401, code: .authFailed, message: "token expired", subCode: nil)
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        service.confirmSend()
        await eventually { await api.createCount == 1 } // the 401'd POST fired

        await eventually { service.sessionFailure != nil }
        XCTAssertNil(service.activeRequest, "a session failure clears the stuck pending — no frozen Waiting… card")
        XCTAssertNotEqual(service.activeRequest?.status, .declined, "auth failure never renders as an owner decline")
        let listCount = await api.rideListCount
        XCTAssertEqual(listCount, 0, "a 401 is definitive-not-indeterminate — no reconcile GET")
    }

    /// An auth-shaped 403 (carrying the typed `auth_failed` code — the backend's
    /// re-auth-required shape) is likewise a session failure, not a decline. We
    /// branch on the TYPED code, so this 403 does NOT take the definitive path a
    /// generic `permission_denied` 403 does.
    func testAuthShaped403OnCreateFlagsSessionErrorNotDeclined() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-403a", status: .requested),
            createError: RestError.http(status: 403, code: .authFailed, message: "reauth required", subCode: .reauthRequired)
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        await eventually { service.sessionFailure != nil }
        XCTAssertNil(service.activeRequest, "auth-shaped 403 clears the pending, not declines it")
    }

    /// A genuine semantic refusal — 409 conflict (lifecycle collision) — keeps the
    /// DEFINITIVE path unchanged: the request goes `.declined` and no session
    /// failure is raised. Proves the split only diverts AUTH-shaped 4xx.
    func testConflict409KeepsDefinitiveDeclinedPath() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-409", status: .requested),
            createError: RestError.http(status: 409, code: .conflict, message: "already exists", subCode: nil)
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        await eventually { service.activeRequest?.status == .declined }
        XCTAssertNil(service.sessionFailure, "a 409 is a real refusal — not a session failure")
        XCTAssertNil(service.vehicleUnavailableFailure, "a generic conflict is not a vehicle-unavailable refusal")
    }

    // MARK: MYR-233 — 409 vehicle_unavailable is not a decline

    /// The typed `409 vehicle_unavailable` on the create POST means the CAR can't
    /// take this ride (it already carries an open instant ride, or it went
    /// in_service/offline between the list fetch and the send). No ride was
    /// created and NOBODY refused the rider, so this must not render as an owner
    /// decline: the stuck pending clears, `vehicleUnavailableFailure` is raised
    /// for the honest notice + scheduling route, and no reconcile GET runs.
    ///
    /// The code is not (yet) a member of the contracts `ErrorPayload.Code` enum,
    /// so it arrives as `.unrecognized("vehicle_unavailable")` — exactly what the
    /// forward-compat arm exists for. We branch on that typed value, never on the
    /// human message (FR-7.1).
    func testVehicleUnavailable409ClearsPendingAndFlagsFailureNotDeclined() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-veh", status: .requested),
            createError: RestError.http(
                status: 409,
                code: .unrecognized("vehicle_unavailable"),
                message: "vehicle is busy",
                subCode: nil
            )
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        XCTAssertEqual(service.activeRequest?.status, .pending)
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        await eventually { service.vehicleUnavailableFailure != nil }
        XCTAssertNil(service.activeRequest, "clears the stuck pending — no frozen Waiting… card")
        XCTAssertNotEqual(service.activeRequest?.status, .declined, "the car being busy is not an owner decline")
        XCTAssertNil(service.sessionFailure, "the session is fine — only the vehicle is unavailable")
        let listCount = await api.rideListCount
        XCTAssertEqual(listCount, 0, "definitive, not indeterminate — no reconcile GET")
    }

    /// No retry loop (acceptance criterion 3): the refusal fires exactly ONE
    /// create POST and never re-POSTs — an identical request would 409 again.
    func testVehicleUnavailable409NeverRetriesTheCreate() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "srv-veh2", status: .requested),
            createError: RestError.http(
                status: 409, code: .unrecognized("vehicle_unavailable"), message: "busy", subCode: nil
            )
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { service.vehicleUnavailableFailure != nil }
        // Give any (unwanted) retry a chance to fire before asserting.
        try? await Task.sleep(for: .milliseconds(200))
        let createCount = await api.createCount
        XCTAssertEqual(createCount, 1, "exactly one POST — no retry loop")
    }

    /// A repeat refusal must raise a FRESH failure value, so the observing
    /// `.onChange` fires again instead of coalescing and dropping the notice.
    func testRepeatVehicleUnavailableRaisesAFreshFailure() async {
        let error = RestError.http(
            status: 409, code: .unrecognized("vehicle_unavailable"), message: "busy", subCode: nil
        )
        let api = StubRideAPI(created: Self.wireRide(id: "srv-veh3", status: .requested), createError: error)
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { service.vehicleUnavailableFailure != nil }
        let first = service.vehicleUnavailableFailure

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { service.vehicleUnavailableFailure != first }
        XCTAssertNotEqual(service.vehicleUnavailableFailure, first, "a repeat refusal must not coalesce")
    }

    /// The ACCEPT path (MYR-277 C's reconcile) raises the same typed failure, so
    /// the single-account demo's rider-who-also-accepts gets the honest copy
    /// rather than a silent snap-back. The existing reconcile still runs.
    func testVehicleUnavailable409OnAcceptFlagsFailureAndStillReconciles() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([Self.wireRide(id: "srv-acc", status: .requested)])
        await api.setDetail(Self.wireRide(id: "srv-acc", status: .requested))
        await api.setAcceptError(RestError.http(
            status: 409, code: .unrecognized("vehicle_unavailable"), message: "busy", subCode: nil
        ))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()

        service.accept()
        await eventually { service.vehicleUnavailableFailure != nil }
        await eventually { service.incomingRequest?.status == .pending }
        XCTAssertEqual(service.incomingRequest?.status, .pending, "the refused accept folds back to the incoming card")
    }

    // MARK: MYR-270 — owner-driven dispatch v2 (picked-up / start / dropped-off)

    /// Drive a fresh service into the state the CLIENT's own device is in mid-ride:
    /// the RIDER holds their own accepted ride AND the OWNER holds it as a dispatch.
    ///
    /// MYR-325 — the advance tests below legitimately span BOTH pipelines, because
    /// the CTAs do: `pickedUp()`/`droppedOff()` are the OWNER's, `startRide()` is the
    /// RIDER's. Before the split one `submit()` produced a record both roles shared;
    /// now the setup states the duality outright — a self-created ride that surfaces
    /// on the owner's incoming feed too (the documented decision on `integrate`).
    /// This is a strictly more faithful fixture than the shared slot it replaces.
    private func acceptedService(id: String) async -> (LiveRideRequestService, StubRideAPI) {
        let api = StubRideAPI(created: Self.wireRide(id: id, status: .requested))
        await api.setIncoming([Self.wireRide(id: id, status: .requested)])
        await api.setDetail(Self.wireRide(id: id, status: .accepted, accepted: true))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        service.submit(Self.sampleInput())            // RIDER half
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await service.refreshIncoming()               // OWNER half — same ride
        XCTAssertEqual(service.incomingRequest?.id, id, "the self-created ride reaches the owner card")

        service.accept()                              // OWNER answers
        await eventually { await api.acceptCount == 1 }
        XCTAssertEqual(service.ownerDispatch?.status, .accepted)
        // The accept's own 200 is an authoritative record, so `integrate` folds it
        // onto the rider half too — no WS frame needed for the same-device case.
        await eventually { service.activeRequest?.status == .accepted }
        return (service, api)
    }

    /// Advance to `.arrived` via `pickedUp()` (the OWNER path), waiting for the
    /// reconcile so a following `startRide()` sees the settled `.arrived` on the
    /// RIDER half — which it reaches through the advance's own `integrate`.
    private func advanceToArrived(_ service: LiveRideRequestService, _ api: StubRideAPI, id: String) async {
        await api.setAdvance(Self.wireRide(id: id, status: .arrived, accepted: true))
        await api.setDetail(Self.wireRide(id: id, status: .arrived, accepted: true))
        service.pickedUp()
        await eventually { service.ownerDispatch?.status == .arrived }
        await eventually { service.activeRequest?.status == .arrived }
    }

    /// OWNER `pickedUp()` optimistically flips accepted → arrived synchronously and
    /// POSTs `/picked-up` on the SERVER id; the returned arrived record reconciles.
    func testPickedUpAdvancesAcceptedToArrivedAndPostsOnServerID() async {
        let (service, api) = await acceptedService(id: "srv-pu")
        await api.setAdvance(Self.wireRide(id: "srv-pu", status: .arrived, accepted: true))

        service.pickedUp()
        XCTAssertEqual(service.ownerDispatch?.status, .arrived, "picked-up flips to arrived synchronously")

        await eventually { await api.pickedUpCount == 1 }
        let puID = await api.lastAdvanceID
        XCTAssertEqual(puID, "srv-pu", "picked-up targets the server-assigned id")
        await eventually { service.ownerDispatch?.status == .arrived }
    }

    /// MYR-411 — **THE RELABEL IS COPY ONLY, AND THIS IS THE TEST THAT SAYS SO.**
    /// The accepted-state button reads "Arrived at pickup" instead of "Picked up",
    /// and the two facts a copy pass could quietly take with it are asserted HERE,
    /// in one test, against the LABEL the owner taps:
    ///
    ///  • the same executor method (`pickedUp()`) and the same §7.8 write — exactly
    ///    ONE `/picked-up` POST on the server id, and NOTHING on `/start` or
    ///    `/dropped-off`, so the relabel cannot have quietly become a different or
    ///    an extra call;
    ///  • the same status write (`accepted → arrived`, on BOTH pipelines).
    ///
    /// And the state it lands on still offers the owner NO button, which is what
    /// keeps the rider's circular "Start ride" the one and only `arrived → enroute`
    /// trigger. `RideDispatchStatusTests` pins the strings; this pins that the
    /// string names this transition and no other.
    func testTheRelabelledAcceptedCTAStillDrivesTheIdenticalTransition() async {
        XCTAssertEqual(OwnerRideStatusLine.actionTitle(for: .accepted), "Arrived at pickup",
                       "the button under test is the relabelled one")

        let (service, api) = await acceptedService(id: "srv-411")
        await api.setAdvance(Self.wireRide(id: "srv-411", status: .arrived, accepted: true))
        await api.setDetail(Self.wireRide(id: "srv-411", status: .arrived, accepted: true))

        // What `HomeScreen.dispatchAction` invokes for `.accepted` — unchanged.
        service.pickedUp()

        XCTAssertEqual(service.ownerDispatch?.status, .arrived, "same optimistic status write")
        await eventually { await api.pickedUpCount == 1 }
        await eventually { service.activeRequest?.status == .arrived }

        let pickedUpCount = await api.pickedUpCount
        let startCount = await api.startCount
        let droppedOffCount = await api.droppedOffCount
        let advanceID = await api.lastAdvanceID
        XCTAssertEqual(pickedUpCount, 1, "exactly one /picked-up — no second call, no retry")
        XCTAssertEqual(startCount, 0, "the owner's button never starts the ride (MYR-411)")
        XCTAssertEqual(droppedOffCount, 0, "and never completes it")
        XCTAssertEqual(advanceID, "srv-411", "still the server-assigned id")

        XCTAssertNil(OwnerRideStatusLine.actionTitle(for: .arrived),
                     "no second owner button: arrived → enroute is the rider's Start alone")
    }

    /// RIDER `start()` optimistically flips arrived → enroute, seeds the leg-2
    /// tracking anchor (past `pickupCut`), and POSTs `/start` on the server id.
    func testStartAdvancesArrivedToEnrouteSeedsLeg2AndPostsOnServerID() async {
        let (service, api) = await acceptedService(id: "srv-st")
        await advanceToArrived(service, api, id: "srv-st")

        await api.setAdvance(Self.wireRide(id: "srv-st", status: .enroute, accepted: true))
        service.startRide()

        XCTAssertEqual(service.activeRequest?.status, .enroute, "start flips to enroute synchronously")
        let seeded = service.activeRequest?.trackProgress ?? 0
        let cut = service.activeRequest?.pickupCut ?? 1
        XCTAssertGreaterThan(seeded, cut, "leg-2 anchor sits past pickupCut (in-ride leg)")

        await eventually { await api.startCount == 1 }
        let stID = await api.lastAdvanceID
        XCTAssertEqual(stID, "srv-st", "start targets the server-assigned id")
        await eventually { service.activeRequest?.status == .enroute }
    }

    /// A `409` on `/start` (the ride already advanced past `arrived`) reconciles to
    /// the TRUE server status via a refetch, never an auto-retry.
    func testStart409ReconcilesToServerStatusViaRefetch() async {
        let (service, api) = await acceptedService(id: "srv-s4")
        await advanceToArrived(service, api, id: "srv-s4")

        await api.setAdvanceError(RestError.http(status: 409, code: .conflict, message: "already advanced", subCode: nil))
        await api.setDetail(Self.wireRide(id: "srv-s4", status: .completed, accepted: true))
        service.startRide()
        await eventually { await api.startCount == 1 }
        await eventually { service.activeRequest?.status == .completed }
    }

    /// A transient `/start` failure where the server NEVER advanced (the refetch
    /// still reads `arrived`) reverts the optimistic enroute back to `arrived` and
    /// rewinds the anchor to the leg-1 seed, so the Start CTA re-appears.
    func testStartTransientFailureRevertsToArrived() async {
        let (service, api) = await acceptedService(id: "srv-s5")
        await advanceToArrived(service, api, id: "srv-s5")

        await api.setAdvanceError(URLError(.timedOut)) // refetch still reads arrived
        service.startRide()
        XCTAssertEqual(service.activeRequest?.status, .enroute, "optimistic flip first")
        await eventually { service.activeRequest?.status == .arrived }
        let cut = service.activeRequest?.pickupCut ?? 0
        let progress = service.activeRequest?.trackProgress ?? 1
        XCTAssertLessThan(progress, cut, "anchor rewound to leg 1 (pre-pickup) so Start reappears")
    }

    /// Double failure: the `/start` POST AND the reconciling refetch both fail. The
    /// server never advanced, so no WS frame will correct the optimistic enroute —
    /// the service UNDOES the optimistic flip back to `.arrived` (MYR-265 review).
    func testStartDoubleFailureRevertsOptimisticEnroute() async {
        let (service, api) = await acceptedService(id: "srv-s6")
        await advanceToArrived(service, api, id: "srv-s6")

        await api.setAdvanceError(URLError(.timedOut))
        await api.setDetailError(URLError(.notConnectedToInternet))
        service.startRide()
        XCTAssertEqual(service.activeRequest?.status, .enroute, "optimistic flip first")
        await eventually { service.activeRequest?.status == .arrived }
    }

    /// OWNER `droppedOff()` optimistically flips enroute → completed synchronously
    /// and POSTs `/dropped-off` on the server id (no drive-end auto-completion).
    func testDroppedOffAdvancesEnrouteToCompletedAndPostsOnServerID() async {
        let (service, api) = await acceptedService(id: "srv-do")
        await advanceToArrived(service, api, id: "srv-do")
        await api.setAdvance(Self.wireRide(id: "srv-do", status: .enroute, accepted: true))
        service.startRide()
        // The RIDER's optimistic flip is synchronous; the OWNER half arrives when the
        // /start 200 is integrated, and "Dropped off" is gated on THAT (MYR-325).
        await eventually { service.ownerDispatch?.status == .enroute }
        await eventually { service.activeRequest?.status == .enroute }

        await api.setAdvance(Self.wireRide(id: "srv-do", status: .completed, accepted: true))
        service.droppedOff()
        XCTAssertEqual(service.ownerDispatch?.status, .completed, "dropped-off completes synchronously")

        await eventually { await api.droppedOffCount == 1 }
        let doID = await api.lastAdvanceID
        XCTAssertEqual(doID, "srv-do", "dropped-off targets the server-assigned id")
        await eventually { service.ownerDispatch?.status == .completed }
        await eventually { service.activeRequest?.status == .completed }
    }

    /// `start()` before pickup is confirmed is a no-op locally: from `.accepted`
    /// (owner has not tapped "Arrived at pickup"), the CTA is not even shown, and the guard
    /// makes `start()` post nothing — the rider cannot skip the pickup confirmation.
    func testStartFromAcceptedIsGuardedNoOp() async {
        let (service, api) = await acceptedService(id: "srv-guard")
        service.startRide()
        XCTAssertEqual(service.activeRequest?.status, .accepted, "start is a no-op from accepted")
        // Give any (erroneous) POST a chance to fire, then assert none did.
        await eventually { await api.acceptCount == 1 }
        let startCount = await api.startCount
        XCTAssertEqual(startCount, 0, "no /start POST from accepted")
    }

    // MARK: WS ride_status_changed round-trips into the UI state

    func testStatusChangedFrameRefetchesAndReconcilesToAccepted() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-4", status: .requested))
        // The detail refetch on the frame returns the accepted record.
        await api.setDetail(Self.wireRide(id: "srv-4", status: .accepted, accepted: true))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        // Seed a pending request (server id srv-4), then deliver the owner-accept frame.
        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening } // event pump attached

        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-4", vehicleId: "veh-live", status: .accepted, timestamp: "2026-07-09T18:05:22.114Z"
        )))

        await eventually { service.activeRequest?.status == .accepted }
        XCTAssertNotNil(service.activeRequest?.trackProgress)
    }

    // MARK: MYR-277 A1 — same-device demo: integrate() refreshes the real rider name

    /// The single-account repro: the rider's optimistic `activeRequest` carries NO
    /// requesterName (the rider never stamps their own display name). The
    /// `ride_request_created` frame refetches the full server record — which DOES
    /// carry the name — and `integrate()` must FOLD it onto the tracked request so
    /// the owner card shows "Thomas Nandola wants a ride", not "Shared viewer".
    func testCreatedFrameRefreshesRealRequesterNameOntoOptimisticDraft() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-a1", status: .requested, requesterName: nil))
        // The on-demand detail refetch resolves the real display name.
        await api.setDetail(Self.wireRide(id: "srv-a1", status: .requested, requesterName: "Thomas Nandola"))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput()) // optimistic draft — requesterName nil
        service.confirmSend()
        await eventually { await api.createCount == 1 } // serverRideID == srv-a1
        XCTAssertNil(service.activeRequest?.input.requesterName, "the optimistic rider draft has no name")
        await eventually { await socket.isListening }

        // The account-wide ride_request_created frame → detail refetch → integrate.
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "srv-a1", vehicleId: "veh-live", riderId: "u-rider",
            status: .requested, requesterName: "Thomas Nandola", timestamp: "2026-07-09T18:00:01.000Z"
        )))

        await eventually { service.activeRequest?.input.requesterName == "Thomas Nandola" }
        // Still pending (the owner hasn't decided) — the incoming card just shows the real name now.
        XCTAssertEqual(service.activeRequest?.status, .pending)
    }

    /// A later frame whose refetch carries NO name must not erase an already-known
    /// name: the refresh is `refetched ?? current`, never a blind overwrite.
    func testFrameWithoutNameKeepsExistingRequesterName() async {
        // No `setDetail`, so the first refetch falls back to `createReturn` (named).
        let api = StubRideAPI(created: Self.wireRide(id: "srv-a1b", status: .requested, requesterName: "Thomas Nandola"))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }

        // First frame: the refetch carries the name → folded onto the draft.
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "srv-a1b", vehicleId: "veh-live", riderId: "u-rider",
            status: .requested, requesterName: "Thomas Nandola", timestamp: "2026-07-09T18:00:01.000Z"
        )))
        await eventually { service.activeRequest?.input.requesterName == "Thomas Nandola" }

        // Owner accepts: the status-change refetch now carries NO name — the known
        // name must survive (the fold is `ride.requesterName ?? current`).
        await api.setDetail(Self.wireRide(id: "srv-a1b", status: .accepted, accepted: true, requesterName: nil))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-a1b", vehicleId: "veh-live", status: .accepted, timestamp: "2026-07-09T18:05:22.114Z"
        )))
        await eventually { service.activeRequest?.status == .accepted }
        XCTAssertEqual(service.activeRequest?.input.requesterName, "Thomas Nandola", "a nameless refetch never erases the known name")
    }

    // MARK: MYR-277 C — accept 409 (vehicle in_service/offline) reconciles, not stuck

    /// The backend 409s an accept for an in_service/offline vehicle. The optimistic
    /// `.accepted` must NOT be swallowed: a refetch reads the ride still `requested`,
    /// so the service folds it back to `.pending` and the incoming sheet re-appears.
    func testAccept409ReconcilesBackToPending() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([Self.wireRide(id: "srv-409a", status: .requested)])
        // The accept POST is refused; the authoritative refetch still reads requested.
        await api.setAcceptError(RestError.http(status: 409, code: .conflict, message: "vehicle unavailable", subCode: nil))
        await api.setDetail(Self.wireRide(id: "srv-409a", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()

        service.accept()
        XCTAssertEqual(service.ownerDispatch?.status, .accepted, "optimistic accepted first")
        await eventually { await api.acceptCount == 1 }
        // 409 → refetch reads requested → folded back to pending (sheet re-shows).
        await eventually { service.incomingRequest?.status == .pending }
        XCTAssertNil(service.incomingRequest?.acceptedAt, "the reverted request carries no acceptedAt")
    }

    /// A 409 whose reconciling refetch ALSO fails: the optimistic accept still can't
    /// stand (the server never accepted), so it reverts to pending locally.
    func testAccept409WithFailedRefetchRevertsToPending() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([Self.wireRide(id: "srv-409b", status: .requested)])
        await api.setAcceptError(RestError.http(status: 409, code: .conflict, message: "vehicle unavailable", subCode: nil))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()
        await api.setDetailError(URLError(.notConnectedToInternet))

        service.accept()
        await eventually { service.incomingRequest?.status == .pending }
    }

    // MARK: MYR-230 deliverable 2 — cold-launch adoption of the rider's open ride

    /// A rider who force-quit mid-ride relaunches: `start()` GETs the rider's own
    /// list and adopts the newest OPEN INSTANT ride, so the shell lands in the
    /// correct tracking state (not the idle greeting) with mutations targeting the
    /// server id.
    func testColdLaunchAdoptsNewestOpenInstantRiderRide() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setRideList([Self.wireRide(id: "srv-open", status: .accepted, accepted: true)])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.start() // runs the cold-launch adoption
        await eventually { service.activeRequest?.status == .accepted }
        XCTAssertNotNil(service.activeRequest?.trackProgress, "an adopted accepted ride seeds the tracking progress")

        service.cancel() // targets the adopted server id
        await eventually { await api.cancelCount == 1 }
        let cancelID = await api.lastCancelID
        XCTAssertEqual(cancelID, "srv-open", "cold-launch adoption wired the server id for mutations")
    }

    /// Scheduled reservations (a `scheduledFor` set) and terminal rides
    /// (completed/declined/cancelled) are NOT adoptable open instant rides — a
    /// cold launch over only those adopts nothing (stays on the idle greeting).
    func testColdLaunchIgnoresScheduledAndTerminalRides() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setRideList([
            Self.wireRide(id: "srv-sched", status: .requested, scheduledFor: "2026-07-11T06:30:00.000Z"),
            Self.wireRide(id: "srv-done", status: .completed),
        ])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.start()
        // Give the adoption + incoming seed a beat to run.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(service.activeRequest, "no open instant ride to adopt → idle greeting")
    }

    // MARK: MYR-230 deliverable 3 — 409 ride_active adopts the existing open ride

    /// A create refused `409 ride_active` (the rider already holds an open instant
    /// ride) ADOPTS the ride carried in the body instead of surfacing a decline:
    /// the optimistic draft is replaced by the real open ride, never `.declined`,
    /// and no reconcile GET runs (the server already handed us the ride).
    func testRideActive409AdoptsReturnedRideNotDeclined() async {
        let existing = Self.wireRide(id: "srv-existing", status: .accepted, accepted: true)
        let api = StubRideAPI(
            created: Self.wireRide(id: "unused", status: .requested),
            createError: RestError.rideActive(active: existing)
        )
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 } // the refused create fired

        await eventually { service.activeRequest?.id == "srv-existing" }
        XCTAssertEqual(service.activeRequest?.status, .accepted, "adopts the returned open ride")
        XCTAssertNotEqual(service.activeRequest?.status, .declined, "ride_active is never an owner decline")
        XCTAssertNil(service.sessionFailure, "ride_active is not a session failure")
        let listCount = await api.rideListCount
        XCTAssertEqual(listCount, 0, "the body carried the ride — no reconcile GET needed")

        service.cancel() // mutations now target the adopted server id
        await eventually { await api.cancelCount == 1 }
        let cancelID = await api.lastCancelID
        XCTAssertEqual(cancelID, "srv-existing", "adoption wired the returned ride's server id for mutations")
    }

    /// The rare terminal-race body: `409 ride_active` with NO sibling. The service
    /// re-syncs from the rider's own open list and adopts the newest open ride.
    func testRideActive409MissingSiblingRefetchesOpenList() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "unused", status: .requested),
            createError: RestError.rideActive(active: nil)
        )
        await api.setRideList([Self.wireRide(id: "srv-refetch", status: .accepted, accepted: true)])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await api.rideListCount >= 1 } // refetched the open list

        await eventually { service.activeRequest?.id == "srv-refetch" }
        XCTAssertEqual(service.activeRequest?.status, .accepted)
    }

    /// `409 ride_active` with no sibling AND nothing open on refetch (the blocking
    /// ride reached a terminal state): drop the stuck optimistic pending rather
    /// than strand the rider on a "Waiting…" card. Never `.declined`.
    func testRideActive409MissingSiblingNoOpenClearsPending() async {
        let api = StubRideAPI(
            created: Self.wireRide(id: "unused", status: .requested),
            createError: RestError.rideActive(active: nil)
        )
        // rideList stays empty.
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await api.rideListCount >= 1 }

        await eventually { service.activeRequest == nil }
        XCTAssertNil(service.sessionFailure, "not a session failure")
    }

    // MARK: MYR-292 — a held COMPLETED ride must never block the owner's next dispatch

    /// Drive the service into the state the TestFlight defect leaves behind: the
    /// OWNER holds a `.completed` ride it adopted from the incoming path, and nothing
    /// will ever clear it (`completeAndReset()` is the RIDER summary's affordance).
    private func ownerHoldingCompletedRide(id: String, socket: StubRideSocket, api: StubRideAPI) async -> LiveRideRequestService {
        await api.setIncoming([Self.wireRide(id: id, status: .requested)])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { service.incomingRequest?.id == id } // owner incoming seed
        // MYR-325: the seed lands in the OWNER pipeline and nowhere else — a
        // stronger statement than the `activeRequestOrigin == .ownerIncoming` tag
        // this replaces, which could only say who had written the shared slot.
        XCTAssertNil(service.activeRequest, "the rider pipeline is untouched by the owner feed")
        await eventually { await socket.isListening }

        // …owner accepts, ride runs, owner taps "Dropped off" → completed.
        await api.setDetail(Self.wireRide(id: id, status: .completed, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: id, vehicleId: "veh-live", status: .completed, timestamp: "2026-07-26T18:30:00.000Z"
        )))
        await eventually { service.ownerDispatch?.status == .completed }
        return service
    }

    /// (a) The defect: with a stale `.completed` ride held, a brand-new incoming
    /// `ride_created` frame used to be silently dropped by the `activeRequest == nil`
    /// adoption guard — so after ONE drop-off the owner could not receive another
    /// request until relaunch. The new `pending` ride must DISPLACE the dead one and
    /// become the tracked request (mutations retarget its server id).
    func testNewPendingRideDisplacesHeldCompletedOwnerRide() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        let service = await ownerHoldingCompletedRide(id: "srv-done", socket: socket, api: api)

        // A SECOND rider requests the same car.
        await api.setDetail(Self.wireRide(id: "srv-next", status: .requested, requesterName: "Maya"))
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "srv-next", vehicleId: "veh-live", riderId: "u-rider2",
            status: .requested, requesterName: "Maya", timestamp: "2026-07-26T18:40:00.000Z"
        )))

        await eventually { service.incomingRequest?.id == "srv-next" }
        XCTAssertEqual(service.incomingRequest?.status, .pending, "the owner's incoming sheet can show again")
        XCTAssertNil(service.activeRequest, "still nothing in the rider pipeline")

        // The completed ride is released — mutations now target the NEW server id.
        service.decline()
        await eventually { await api.declineCount == 1 }
        let declineID = await api.lastDeclineID
        XCTAssertEqual(declineID, "srv-next", "the displaced completed ride no longer owns the mutation target")
    }

    /// (b) The widening is scoped to a NEW `pending` ride. Frames for other rides in
    /// any non-pending status must not displace the held record — only an incoming
    /// REQUEST takes the slot.
    func testHeldCompletedRideIsNotDisplacedByNonPendingFrames() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        let service = await ownerHoldingCompletedRide(id: "srv-done2", socket: socket, api: api)

        let nonPending: [(MyRobotaxiContracts.RideRequestStatus, RideStatusChangedPayload.Status)] = [
            (.accepted, .accepted), (.arrived, .arrived), (.enroute, .enroute), (.completed, .completed), (.declined, .declined),
        ]
        for (detail, frame) in nonPending {
            await api.setDetail(Self.wireRide(id: "srv-other", status: detail, accepted: true))
            await socket.push(.statusChanged(RideStatusChangedPayload(
                rideRequestId: "srv-other", vehicleId: "veh-live", status: frame, timestamp: "2026-07-26T18:45:00.000Z"
            )))
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(service.ownerDispatch?.id, "srv-done2", "only a pending incoming request may take the slot")
        XCTAssertEqual(service.ownerDispatch?.status, .completed)
    }

    /// (c) The safety guard. The RIDER legitimately holds a `.completed` ride for as
    /// long as the Ride Summary is on screen — "See you soon" (`completeAndReset()`)
    /// is what clears it. A new incoming request must NOT clobber that record, or the
    /// summary would swap its itinerary out from under the rider and "See you soon"
    /// would file a stranger's ride into history. The guard therefore tests the
    /// ORIGIN of the held ride, not just its status.
    func testRiderSummaryCompletedRideIsNeverClobberedByIncomingRequest() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-ride", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        // The RIDER's own ride, submitted on this device, runs to completion — the
        // rider is now sitting on the Ride Summary.
        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-ride", status: .completed, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-ride", vehicleId: "veh-live", status: .completed, timestamp: "2026-07-26T19:00:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .completed }
        let summaryRideID = service.activeRequest?.id

        // Someone else requests the car while the summary is up.
        await api.setDetail(Self.wireRide(id: "srv-intruder", status: .requested, requesterName: "Maya"))
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "srv-intruder", vehicleId: "veh-live", riderId: "u-rider2",
            status: .requested, requesterName: "Maya", timestamp: "2026-07-26T19:01:00.000Z"
        )))
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(service.activeRequest?.id, summaryRideID, "the rider's summary record survives untouched")
        XCTAssertEqual(service.activeRequest?.status, .completed)
        // MYR-325 — and the intruder is no longer PUNISHED for the rider's summary.
        // This assertion is new: before the split, protecting the summary meant the
        // owner got nothing at all, which is the starvation this issue fixes.
        XCTAssertEqual(service.incomingRequest?.id, "srv-intruder", "the owner's card presents alongside it")

        // …and once the rider taps "See you soon" the rider slot frees up normally,
        // with the owner card entirely unaffected.
        _ = service.completeAndReset()
        XCTAssertNil(service.activeRequest)
        XCTAssertEqual(service.incomingRequest?.id, "srv-intruder")
    }

    /// (d) `refreshIncoming()` carries the SAME widened guard, symmetrically: it is
    /// the other half of the owner's incoming adoption, so a dead completed ride must
    /// not block it either (and, by the same origin test, a rider's live summary
    /// still does).
    func testRefreshIncomingAdoptsWaitingRequestOverHeldCompletedRide() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        let service = await ownerHoldingCompletedRide(id: "srv-done3", socket: socket, api: api)

        await api.setIncoming([Self.wireRide(id: "srv-waiting", status: .requested)])
        await service.refreshIncoming()
        XCTAssertEqual(service.incomingRequest?.id, "srv-waiting", "a waiting request is adopted over the dead completed ride")
        XCTAssertEqual(service.incomingRequest?.status, .pending)
    }

    /// …and the rider-safety half on the `refreshIncoming()` path. MYR-325 changes
    /// what "safety" costs: the rider's summary is still never displaced, but the
    /// owner's card now presents anyway, because it is not the same piece of state.
    func testRefreshIncomingLeavesRiderCompletedRideAndStillPresentsTheCard() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-rider-sum", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-rider-sum", status: .completed, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-rider-sum", vehicleId: "veh-live", status: .completed, timestamp: "2026-07-26T19:10:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .completed }
        // The rider's own record keeps its CLIENT id (the optimistic draft is folded
        // in place; only `serverRideID` carries the server's cuid).
        let summaryRideID = service.activeRequest?.id

        await api.setIncoming([Self.wireRide(id: "srv-waiting2", status: .requested)])
        await service.refreshIncoming()
        XCTAssertEqual(service.activeRequest?.id, summaryRideID, "the rider's summary is never displaced by the incoming seed")
        XCTAssertEqual(service.activeRequest?.status, .completed)
        XCTAssertEqual(service.incomingRequest?.id, "srv-waiting2", "…and the owner is no longer starved by it")
    }

    // MARK: - MYR-317 — the owner's incoming QUEUE (badge + auto-advance)
    //
    // Before this issue the owner held ONE slot and `refreshIncoming` adopted
    // `page.items.first`, discarding the rest of the page: extra pending requests
    // (several riders, or several future reservations against the same car) were
    // invisible, and the next one surfaced only if a fresh WS frame happened to
    // arrive after the current card resolved. These tests pin the queue's rules and,
    // just as importantly, that it never becomes a back door around the MYR-292
    // rider-safety invariants.

    /// An owner with three open requests: the head takes the card, the other two
    /// are HELD and counted — the badge's number is exactly what the old
    /// `page.items.first` threw away.
    func testIncomingPageBeyondTheFirstBecomesTheWaitingQueue() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([
            Self.wireRide(id: "q-1", status: .requested),
            Self.wireRide(id: "q-2", status: .requested),
            Self.wireRide(id: "q-3", status: .requested),
        ])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        await service.refreshIncoming()
        XCTAssertEqual(service.incomingRequest?.id, "q-1", "the feed head still takes the card (order unchanged)")
        XCTAssertEqual(service.waitingIncomingCount, 2, "the rest of the page is held, not discarded")
        XCTAssertNil(service.activeRequest, "the rider pipeline is not involved")
    }

    /// DECLINE → the next queued request surfaces on the same card path, with the
    /// badge counting down. This is the MYR-317 headline behaviour, and it only
    /// works because MYR-306 widened `canAdoptIncoming` to an owner `.declined`.
    func testDeclineAutoAdvancesToTheNextQueuedRequest() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([
            Self.wireRide(id: "adv-1", status: .requested),
            Self.wireRide(id: "adv-2", status: .requested),
            Self.wireRide(id: "adv-3", status: .requested),
        ])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()
        XCTAssertEqual(service.incomingRequest?.id, "adv-1")

        service.decline()
        XCTAssertEqual(service.incomingRequest?.id, "adv-2", "the next request surfaces immediately, no relaunch")
        XCTAssertEqual(service.incomingRequest?.status, .pending, "…as a fresh, answerable card")
        await eventually { await api.declineCount == 1 }
        let declineID = await api.lastDeclineID
        XCTAssertEqual(declineID, "adv-1", "the decline still targeted the resolved ride")
        // The re-fetch that follows adoption must not resurrect the declined ride
        // from a page that predates the POST.
        await eventually { service.waitingIncomingCount == 1 }
        XCTAssertEqual(service.incomingRequest?.id, "adv-2")
    }

    /// ACCEPT must NOT advance: the accepted ride is a live dispatch that owns the
    /// slot (the owner is now driving it to the pickup). The queue keeps holding the
    /// others — the badge is the only thing that changes.
    func testAcceptKeepsTheDispatchAndNeverAdoptsAQueuedRequest() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([
            Self.wireRide(id: "acc-1", status: .requested),
            Self.wireRide(id: "acc-2", status: .requested),
        ])
        await api.setDetail(Self.wireRide(id: "acc-1", status: .accepted, accepted: true))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()

        service.accept()
        await eventually { await api.acceptCount == 1 }
        try? await Task.sleep(nanoseconds: 80_000_000) // let the queue re-fetch settle
        XCTAssertEqual(service.ownerDispatch?.id, "acc-1", "the dispatched ride keeps the slot")
        XCTAssertEqual(service.ownerDispatch?.status, .accepted)
        XCTAssertEqual(service.waitingIncomingCount, 1, "the other request is still waiting behind it")
    }

    /// COMPLETION-RELEASE: the owner's own ride reaches `completed` (the drop-off),
    /// which is the one status that is terminal FOR THE OWNER — the queued request
    /// then surfaces on its own instead of waiting for a new frame that will never
    /// come (the exact "one ride and the owner goes deaf" defect).
    func testCompletedRideAutoAdvancesToTheQueuedRequest() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        await api.setIncoming([
            Self.wireRide(id: "done-1", status: .requested),
            Self.wireRide(id: "next-2", status: .requested),
        ])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { service.incomingRequest?.id == "done-1" }
        await eventually { service.waitingIncomingCount == 1 }
        await eventually { await socket.isListening }

        // The ride runs and the owner taps "Dropped off".
        await api.setDetail(Self.wireRide(id: "done-1", status: .completed, accepted: true))
        await api.setIncoming([Self.wireRide(id: "next-2", status: .requested)]) // server drops the finished row
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "done-1", vehicleId: "veh-live", status: .completed, timestamp: "2026-07-27T20:00:00.000Z"
        )))

        await eventually { service.incomingRequest?.id == "next-2" }
        XCTAssertEqual(service.incomingRequest?.status, .pending)
        XCTAssertEqual(service.waitingIncomingCount, 0)
    }

    /// A `ride_created` frame that arrives while a card is UP is queued rather than
    /// dropped (it used to be silently discarded by the adoption guard), and a
    /// re-delivered frame for the same ride must not count the same rider twice.
    func testCreatedFrameQueuesBehindTheCurrentCardAndIsDeduped() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        await api.setIncoming([Self.wireRide(id: "held-1", status: .requested)])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { service.incomingRequest?.id == "held-1" }
        await eventually { await socket.isListening }

        await api.setDetail(Self.wireRide(id: "arrival-2", status: .requested, requesterName: "Maya"))
        for _ in 0..<2 {
            await socket.push(.created(RideRequestCreatedPayload(
                rideRequestId: "arrival-2", vehicleId: "veh-live", riderId: "u-rider2",
                status: .requested, requesterName: "Maya", timestamp: "2026-07-27T20:10:00.000Z"
            )))
        }

        await eventually { service.waitingIncomingCount == 1 }
        try? await Task.sleep(nanoseconds: 80_000_000) // let the second frame land
        XCTAssertEqual(service.waitingIncomingCount, 1, "the same ride is queued once, not twice")
        XCTAssertEqual(service.incomingRequest?.id, "held-1", "the card in front of the owner never moved")
    }

    /// A QUEUED request that resolves somewhere else (another device accepted it,
    /// the rider cancelled it) leaves the queue — the owner must never be advanced
    /// onto a card nobody is waiting on.
    func testQueuedRequestResolvedRemotelyIsDroppedFromTheQueue() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        await api.setIncoming([
            Self.wireRide(id: "cur-1", status: .requested),
            Self.wireRide(id: "gone-2", status: .requested),
        ])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { service.incomingRequest?.id == "cur-1" }
        await eventually { service.waitingIncomingCount == 1 }
        await eventually { await socket.isListening }

        // The queued ride is accepted elsewhere (or cancelled) — the feed drops it too.
        await api.setDetail(Self.wireRide(id: "gone-2", status: .accepted, accepted: true))
        await api.setIncoming([Self.wireRide(id: "cur-1", status: .requested)])
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "gone-2", vehicleId: "veh-live", status: .accepted, timestamp: "2026-07-27T20:20:00.000Z"
        )))
        await eventually { service.waitingIncomingCount == 0 }

        // …and resolving the current card now surfaces NOTHING, rather than
        // advancing the owner onto a ride that is already somebody else's.
        service.decline()
        XCTAssertEqual(service.ownerRequest?.id, "cur-1", "no dead ride was adopted")
        XCTAssertEqual(service.ownerRequest?.status, .declined, "the declined record stands until a real request arrives")
        XCTAssertNil(service.incomingRequest, "…and it shows on no owner surface")
        XCTAssertEqual(service.waitingIncomingCount, 0)
    }

    /// A stale feed page (built before the decline POST landed) still lists the ride
    /// the owner just answered. It must not be re-queued — or the owner would be
    /// asked to decide on it a second time, and Accept would 409.
    func testStaleFeedPageNeverReQueuesAnAlreadyResolvedRequest() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let stale = [
            Self.wireRide(id: "stale-1", status: .requested),
            Self.wireRide(id: "stale-2", status: .requested),
        ]
        await api.setIncoming(stale)
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        await service.refreshIncoming()
        XCTAssertEqual(service.incomingRequest?.id, "stale-1")

        service.decline() // the feed stub keeps returning BOTH rows as `requested`
        await eventually { await api.declineCount == 1 }
        await service.refreshIncoming()
        XCTAssertEqual(service.incomingRequest?.id, "stale-2", "the queue advanced once")
        XCTAssertEqual(service.waitingIncomingCount, 0, "the answered request is not waiting again")
    }

    // MARK: MYR-306 — an owner-declined ride must not jam adoption

    /// The MYR-306 defect, mirroring the MYR-292 set: `decline()` leaves the record
    /// on `.declined` and nothing on the owner path clears it, so every later
    /// incoming frame was dropped until relaunch. An owner-originated declined ride
    /// is now displaced by the next pending request.
    func testOwnerDeclinedRideIsDisplacedByNextPendingRequest() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        let socket = StubRideSocket()
        await api.setIncoming([Self.wireRide(id: "dec-1", status: .requested)])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)
        await eventually { service.incomingRequest?.id == "dec-1" }
        await eventually { await socket.isListening }

        await api.setIncoming([]) // nothing queued locally — the frame is the only route in
        service.decline()
        await eventually { service.ownerRequest?.status == .declined }

        // A SECOND rider requests the same car after the decline.
        await api.setDetail(Self.wireRide(id: "dec-next", status: .requested, requesterName: "Maya"))
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "dec-next", vehicleId: "veh-live", riderId: "u-rider2",
            status: .requested, requesterName: "Maya", timestamp: "2026-07-27T21:00:00.000Z"
        )))

        await eventually { service.incomingRequest?.id == "dec-next" }
        XCTAssertEqual(service.incomingRequest?.status, .pending, "the owner can answer again without relaunching")
    }

    /// The MYR-306 safety half — the reason MYR-292 deliberately left `.declined`
    /// alone: the RIDER's `DeclinedNotice` renders their own declined record.
    ///
    /// MYR-325 — this is TONIGHT'S EXACT STATE, and the assertion at the end is the
    /// one that inverts. The rider's notice is still untouchable (now because the
    /// owner arm cannot write that storage at all), but the incoming requests no
    /// longer WAIT behind it: they present. Waiting was the defect — on the client's
    /// device that queue never drained, because nothing clears a rider's declined
    /// notice except the rider dismissing it, and he had two requests to answer.
    func testRiderDeclinedNoticeIsNotClobberedButNoLongerStarvesTheOwner() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-rdec", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        // The rider's own request, declined by the owner → the notice is on screen.
        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-rdec", status: .declined))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-rdec", vehicleId: "veh-live", status: .declined, timestamp: "2026-07-27T21:10:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .declined }
        let noticeRideID = service.activeRequest?.id

        // Someone else requests the car while the notice is up — by frame AND by feed.
        await api.setDetail(Self.wireRide(id: "rdec-intruder", status: .requested, requesterName: "Maya"))
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "rdec-intruder", vehicleId: "veh-live", riderId: "u-rider2",
            status: .requested, requesterName: "Maya", timestamp: "2026-07-27T21:11:00.000Z"
        )))
        await api.setIncoming([Self.wireRide(id: "rdec-intruder", status: .requested)])
        await service.refreshIncoming()
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(service.activeRequest?.id, noticeRideID, "the rider's declined record survives untouched")
        XCTAssertEqual(service.activeRequest?.status, .declined)
        XCTAssertEqual(service.incomingRequest?.id, "rdec-intruder", "the owner's request PRESENTS — it no longer waits")
        XCTAssertEqual(service.waitingIncomingCount, 0, "nothing is left stranded in the queue")
    }

    /// The queue must not become a back door around the MYR-292 rider-summary
    /// invariant either: with the rider sitting on their completed ride, a whole
    /// PAGE of incoming requests is held and counted, and not one of them is adopted.
    func testQueuedRequestsNeverDisplaceTheRiderSummary() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-qsum", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-qsum", status: .completed, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-qsum", vehicleId: "veh-live", status: .completed, timestamp: "2026-07-27T21:20:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .completed }
        let summaryRideID = service.activeRequest?.id

        await api.setIncoming([
            Self.wireRide(id: "qsum-1", status: .requested),
            Self.wireRide(id: "qsum-2", status: .requested),
        ])
        await service.refreshIncoming()

        XCTAssertEqual(service.activeRequest?.id, summaryRideID, "the rider's summary is never displaced")
        XCTAssertEqual(service.activeRequest?.status, .completed)
        // MYR-325 — the page is no longer held hostage by the rider's summary: the
        // head presents and only the genuine remainder waits.
        XCTAssertEqual(service.incomingRequest?.id, "qsum-1")
        XCTAssertEqual(service.waitingIncomingCount, 1, "one request waits behind the card, honestly")

        // …and "See you soon" clears the RIDER's slot without disturbing the owner.
        _ = service.completeAndReset()
        XCTAssertNil(service.activeRequest)
        XCTAssertEqual(service.incomingRequest?.id, "qsum-1")
        XCTAssertEqual(service.waitingIncomingCount, 1)
    }

    // MARK: - MYR-325 — the owner's incoming pipeline is not the rider's ride slot
    //
    // Live client repro (his device, 2026-07-27). He is OWNER and RIDER on one
    // account. His RIDER-side scheduled request was owner-declined; the
    // rider-origin `.declined` record stays held (the `DeclinedNotice` renders it,
    // and MYR-292/306 deliberately protect it). Two FRESH incoming requests then
    // arrived — server `requested`, pushes delivered, the deep link fired
    // `refreshIncoming()` — and no incoming card ever surfaced, because the single
    // `activeRequest` slot served both roles and `canAdoptIncoming` (correctly)
    // refuses to displace a rider-origin terminal record. Correct rider guard,
    // starved owner: the slot itself was the defect.

    /// THE REPRO. A rider-origin `.declined` record is held; two `requested`
    /// incoming requests are waiting; `refreshIncoming()` runs. The owner's
    /// incoming card MUST present — and the rider's declined notice must survive
    /// untouched, because they are no longer the same piece of state.
    func testIncomingCardPresentsWhileRiderHoldsTheirOwnDeclinedNotice() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-tonight", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        // The rider's own request, declined by the owner → `DeclinedNotice` is up.
        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-tonight", status: .declined))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-tonight", vehicleId: "veh-live", status: .declined,
            timestamp: "2026-07-27T22:00:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .declined }
        let noticeRideID = service.activeRequest?.id

        // TWO fresh incoming requests land while that notice is still on screen;
        // the push deep-link fires the owner's feed refresh.
        await api.setIncoming([
            Self.wireRide(id: "tonight-1", status: .requested, requesterName: "Maya"),
            Self.wireRide(id: "tonight-2", status: .requested, requesterName: "Ravi"),
        ])
        await service.refreshIncoming()

        XCTAssertEqual(service.incomingRequest?.id, "tonight-1", "the owner's incoming card presents")
        XCTAssertEqual(service.incomingRequest?.status, .pending, "…as a fresh, answerable card")
        XCTAssertEqual(service.waitingIncomingCount, 1, "the second request is counted behind it")

        // …and the rider half is completely untouched — different slot.
        XCTAssertEqual(service.activeRequest?.id, noticeRideID, "the rider's declined notice survives")
        XCTAssertEqual(service.activeRequest?.status, .declined)
    }

    /// The same starvation reached by the OTHER route: a live `ride_request_created`
    /// frame (no feed fetch at all) while the rider's declined notice is held.
    func testCreatedFrameSurfacesIncomingCardWhileRiderHoldsDeclinedNotice() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-tn2", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-tn2", status: .declined))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-tn2", vehicleId: "veh-live", status: .declined,
            timestamp: "2026-07-27T22:05:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .declined }

        await api.setDetail(Self.wireRide(id: "tn2-incoming", status: .requested, requesterName: "Maya"))
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "tn2-incoming", vehicleId: "veh-live", riderId: "u-rider2",
            status: .requested, requesterName: "Maya", timestamp: "2026-07-27T22:06:00.000Z"
        )))

        await eventually { service.incomingRequest?.id == "tn2-incoming" }
        XCTAssertEqual(service.activeRequest?.status, .declined, "the rider's notice is not displaced")
    }

    /// The rider is MID-RIDE (a live `enroute` dispatch of their own) and a new
    /// request arrives for their car. On main the non-terminal rider record blocked
    /// adoption outright; the owner card must now present alongside the tracking
    /// sheet, and the rider's ride must not so much as flicker.
    func testIncomingCardPresentsWhileRiderIsMidRide() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-mid", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await api.setDetail(Self.wireRide(id: "srv-mid", status: .enroute, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-mid", vehicleId: "veh-live", status: .enroute,
            timestamp: "2026-07-27T22:10:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .enroute }
        let riderProgress = service.activeRequest?.trackProgress

        await api.setIncoming([Self.wireRide(id: "mid-incoming", status: .requested)])
        await service.refreshIncoming()

        XCTAssertEqual(service.incomingRequest?.id, "mid-incoming", "the owner card presents during the rider's ride")
        XCTAssertEqual(service.activeRequest?.status, .enroute, "the rider's live ride is untouched")
        XCTAssertEqual(service.activeRequest?.trackProgress, riderProgress, "…including its tracking anchor")
    }

    // MARK: MYR-325 — same-account duality: a self-created ride surfaces on BOTH

    /// The DECISION (documented on `integrate`): a ride this device's rider created
    /// ALSO surfaces on this device's owner pipeline. The client self-tests exactly
    /// this way — request as rider, answer as owner — and the rider's booking card
    /// and the owner's incoming card are different SURFACES, not one shared record.
    /// Both pipelines legitimately hold the same ride id.
    func testSelfCreatedRideSurfacesOnBothPipelines() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-self", status: .requested))
        let socket = StubRideSocket()
        await api.setDetail(Self.wireRide(id: "srv-self", status: .requested, requesterName: "Thomas Nandola"))
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }

        // The account-wide created frame — the owner half of the same account.
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "srv-self", vehicleId: "veh-live", riderId: "u-rider",
            status: .requested, requesterName: "Thomas Nandola", timestamp: "2026-07-27T22:20:00.000Z"
        )))

        await eventually { service.incomingRequest?.id == "srv-self" }
        XCTAssertEqual(service.activeRequest?.status, .pending, "the rider still sees their own booking card")
        XCTAssertEqual(service.incomingRequest?.input.requesterName, "Thomas Nandola")
    }

    /// ACCEPT from the owner card: the owner's slot becomes a DISPATCH, and the
    /// rider side learns through the existing WS `integrate` — the accept is not
    /// written into the rider's record directly (the two pipelines only ever meet
    /// through an authoritative server record).
    func testAcceptFromOwnerCardDispatchesAndRiderSeesAcceptedViaIntegrate() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-dual", status: .requested))
        let socket = StubRideSocket()
        await api.setDetail(Self.wireRide(id: "srv-dual", status: .requested))
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { await socket.isListening }
        await socket.push(.created(RideRequestCreatedPayload(
            rideRequestId: "srv-dual", vehicleId: "veh-live", riderId: "u-rider",
            status: .requested, requesterName: nil, timestamp: "2026-07-27T22:30:00.000Z"
        )))
        await eventually { service.incomingRequest?.id == "srv-dual" }

        service.accept()
        XCTAssertNil(service.incomingRequest, "the card clears the instant the owner answers")
        XCTAssertEqual(service.ownerDispatch?.status, .accepted, "…and becomes the owner's dispatch")
        await eventually { await api.acceptCount == 1 }
        let acceptID = await api.lastAcceptID
        XCTAssertEqual(acceptID, "srv-dual", "the accept targets the OWNER pipeline's server id")

        // The rider learns via the server's frame, not via a shared slot.
        await api.setDetail(Self.wireRide(id: "srv-dual", status: .accepted, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-dual", vehicleId: "veh-live", status: .accepted,
            timestamp: "2026-07-27T22:31:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .accepted }
        XCTAssertNotNil(service.activeRequest?.trackProgress, "the rider's tracking anchor is seeded")
        XCTAssertEqual(service.ownerDispatch?.status, .accepted, "the dispatch card holds the same ride")
    }

    /// DECLINE from the owner card on a SELF-created ride: the owner pipeline
    /// advances to the next waiting request immediately, and the rider's own
    /// `DeclinedNotice` arrives through the frame. This is tonight's whole loop,
    /// end to end — and the state it used to deadlock in.
    func testDeclineFromOwnerCardAdvancesQueueAndRiderGetsDeclinedNotice() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-dd", status: .requested))
        let socket = StubRideSocket()
        await api.setDetail(Self.wireRide(id: "srv-dd", status: .requested))
        await api.setIncoming([
            Self.wireRide(id: "srv-dd", status: .requested),
            Self.wireRide(id: "dd-next", status: .requested),
        ])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { service.incomingRequest?.id == "srv-dd" }
        await eventually { await socket.isListening }

        await api.setIncoming([Self.wireRide(id: "dd-next", status: .requested)])
        service.decline()
        XCTAssertEqual(service.incomingRequest?.id, "dd-next", "the next request surfaces immediately")

        // The rider half arrives on the server's frame.
        await api.setDetail(Self.wireRide(id: "srv-dd", status: .declined))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: "srv-dd", vehicleId: "veh-live", status: .declined,
            timestamp: "2026-07-27T22:40:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .declined }
        XCTAssertEqual(service.incomingRequest?.id, "dd-next", "the rider's notice does not disturb the owner card")
    }

    /// The rider CANCELLING their own request must retire the owner-side card for
    /// it too — otherwise the split would leave a phantom incoming request on this
    /// device's own owner Home, whose Accept would 409.
    func testRiderCancelRetiresTheSelfRequestFromTheOwnerPipeline() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-cx", status: .requested))
        let socket = StubRideSocket()
        await api.setIncoming([Self.wireRide(id: "srv-cx", status: .requested)])
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: true)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        await eventually { service.incomingRequest?.id == "srv-cx" }

        await api.setIncoming([]) // the server drops the cancelled row
        service.cancel()
        XCTAssertNil(service.activeRequest, "the rider's card is gone")
        XCTAssertNil(service.incomingRequest, "…and so is the owner's card for the same ride")
        await eventually { await api.cancelCount == 1 }
    }

    /// The owner's DISPATCH projection is the accepted→completed lifecycle only:
    /// a pending request belongs to the incoming card, and a declined one to
    /// neither surface (`OwnerRideStatusLine` renders no line for it).
    func testOwnerDispatchProjectionExcludesPendingAndDeclined() async {
        let api = StubRideAPI(created: Self.wireRide(id: "unused", status: .requested))
        await api.setIncoming([Self.wireRide(id: "proj-1", status: .requested)])
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        await service.refreshIncoming()
        XCTAssertNotNil(service.incomingRequest, "pending → the incoming card")
        XCTAssertNil(service.ownerDispatch, "pending is never a dispatch")

        await api.setIncoming([])
        service.decline()
        XCTAssertNil(service.incomingRequest, "declined → the card animates out")
        XCTAssertNil(service.ownerDispatch, "…and it is not a dispatch either")
    }

    // MARK: - Builders

    private static func sampleInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[1],
            fleetMemberID: RideRequestFixtures.fleet[0].id
        )
    }

    /// A draft carrying real street labels + concrete coordinates — the
    /// reconcile matches wire rides by these pickup/dropoff coordinates.
    private static func liveInput() -> RideRequestInput {
        RideRequestInput(
            pickup: RidePlace(id: "pin", label: "1200 Grandscape Blvd", subtitle: nil, miles: 0, minutes: 0, icon: "mappin",
                              coordinate: CLLocationCoordinate2D(latitude: 33.09, longitude: -96.85)),
            destination: RidePlace(id: "live|bell", label: "Bell Southstone Yards", subtitle: nil, miles: 5.4, minutes: 16, icon: "mappin",
                                   coordinate: CLLocationCoordinate2D(latitude: 33.15, longitude: -96.82)),
            fleetMemberID: "veh-live"
        )
    }

    /// Drives the reconcile window in ~milliseconds so the "finds nothing"
    /// fall-through resolves inside a unit test.
    private static let fastReconcile = LiveRideRequestService.ReconcilePolicy(attempts: 3, delay: .milliseconds(10))

    private static func wireRide(
        id: String,
        status: MyRobotaxiContracts.RideRequestStatus,
        accepted: Bool = false,
        scheduledFor: String? = nil,
        requesterName: String? = nil,
        pickup: MyRobotaxiContracts.RidePlace = MyRobotaxiContracts.RidePlace(lat: 37.7793, lng: -122.3937, label: "Current location"),
        dropoff: MyRobotaxiContracts.RidePlace = MyRobotaxiContracts.RidePlace(lat: 37.6156, lng: -122.3900, label: "SFO · Terminal 2")
    ) -> RideRequest {
        RideRequest(
            id: id,
            riderId: "u-rider",
            ownerId: "u-rider",
            vehicleId: "veh-live",
            pickup: pickup,
            dropoff: dropoff,
            status: status,
            scheduledFor: scheduledFor,
            createdAt: Self.isoNow(),
            updatedAt: Self.isoNow(),
            acceptedAt: accepted ? "2026-07-09T18:05:22.114Z" : nil,
            requesterName: requesterName
        )
    }

    /// `createdAt` for a reconcile-discoverable ride must be no earlier than the
    /// optimistic `requestedAt` (≈ now) — use the current time so the match's
    /// recency guard passes regardless of when the suite runs.
    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true")
    }
}

// MARK: - Stubs

/// In-memory `RideRequestAPI` — records calls + arguments, returns canned records.
private actor StubRideAPI: RideRequestAPI {
    private let createReturn: RideRequest
    private let createError: Error?
    private var detailReturn: RideRequest?
    private var rideList: [RideRequest] = []
    /// MYR-292 — the OWNER incoming feed (`GET /api/ride-requests/incoming`). Empty
    /// by default so every pre-existing test's owner seed stays a no-op.
    private var incoming: [RideRequest] = []
    /// MYR-360 — the vehicle-scoped upcoming-reservation slice. Empty by default so
    /// no existing test's behaviour changes.
    private var upcoming: [RideRequest] = []
    private(set) var upcomingVehicleIDs: [String] = []

    private var advanceReturn: RideRequest?
    private var advanceError: Error?
    private var detailError: Error?
    private var acceptError: Error?

    private(set) var createCount = 0
    private(set) var acceptCount = 0
    private(set) var declineCount = 0
    private(set) var cancelCount = 0
    private(set) var pickedUpCount = 0
    private(set) var startCount = 0
    private(set) var droppedOffCount = 0
    private(set) var lastAdvanceID: String?
    private(set) var rideListCount = 0
    private(set) var lastCreateVehicleID: String?
    private(set) var lastAcceptID: String?
    private(set) var lastDeclineID: String?
    private(set) var lastCancelID: String?

    init(created: RideRequest, createError: Error? = nil) {
        self.createReturn = created
        self.createError = createError
    }

    func setDetail(_ ride: RideRequest) { detailReturn = ride }
    func setRideList(_ rides: [RideRequest]) { rideList = rides }
    func setIncoming(_ rides: [RideRequest]) { incoming = rides }
    func setUpcoming(_ rides: [RideRequest]) { upcoming = rides }
    func setAdvance(_ ride: RideRequest?) { advanceReturn = ride }
    func setAdvanceError(_ error: Error?) { advanceError = error }
    func setDetailError(_ error: Error?) { detailError = error }
    func setAcceptError(_ error: Error?) { acceptError = error }

    func vehicles() async throws -> [VehicleSummary] {
        [VehicleSummary(vehicleId: "veh-live", name: "Lunar", model: "Model Y", year: 2025, color: "Quicksilver",
                        vinLast4: "2046", status: .parked, chargeLevel: 68, estimatedRange: 210,
                        lastUpdated: "2026-07-09T18:00:00Z", role: .owner)]
    }

    func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        createCount += 1
        lastCreateVehicleID = body.vehicleId
        if let createError { throw createError }
        return createReturn
    }

    func rideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        rideListCount += 1
        return RideRequestsListResponse(items: rideList, hasMore: false)
    }
    func rideRequest(id: String) async throws -> RideRequest {
        if let detailError { throw detailError }
        return detailReturn ?? createReturn
    }
    func cancelRideRequest(id: String) async throws -> RideRequest { cancelCount += 1; lastCancelID = id; return createReturn }
    func acceptRideRequest(id: String) async throws -> RideRequest {
        acceptCount += 1; lastAcceptID = id
        if let acceptError { throw acceptError }
        return detailReturn ?? createReturn
    }
    func declineRideRequest(id: String) async throws -> RideRequest { declineCount += 1; lastDeclineID = id; return createReturn }
    private func advance(_ id: String) throws -> RideRequest {
        lastAdvanceID = id
        if let advanceError { throw advanceError }
        return advanceReturn ?? detailReturn ?? createReturn
    }
    func pickedUp(rideID: String) async throws -> RideRequest { pickedUpCount += 1; return try advance(rideID) }
    func start(rideID: String) async throws -> RideRequest { startCount += 1; return try advance(rideID) }
    func droppedOff(rideID: String) async throws -> RideRequest { droppedOffCount += 1; return try advance(rideID) }
    func incomingRideRequests(cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        RideRequestsListResponse(items: incoming, hasMore: false)
    }
    /// MYR-360 — the owner's upcoming reservations for ONE vehicle. Empty by
    /// default and unused by every test in this file: this service does not read
    /// them (the ride-share pause flow does, through its own narrow seam), so the
    /// conformance exists to keep the protocol total. `RideSharePauseWarningTests`
    /// scripts the same call properly.
    func upcomingReservations(vehicleID: String, cursor: String?, limit: Int) async throws -> RideRequestsListResponse {
        upcomingVehicleIDs.append(vehicleID)
        return RideRequestsListResponse(items: upcoming, hasMore: false)
    }
}

/// In-memory `RideEventStreaming` — a controllable ride-event source.
private actor StubRideSocket: RideEventStreaming {
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
