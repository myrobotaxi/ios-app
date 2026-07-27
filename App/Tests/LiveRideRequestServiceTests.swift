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

    // MARK: pending → accepted

    func testSubmitThenAcceptTransitionsPendingToAcceptedAndPosts() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-1", status: .requested))
        let socket = StubRideSocket()
        let service = LiveRideRequestService(api: api, socket: socket, autoStart: false)

        service.submit(Self.sampleInput())
        XCTAssertEqual(service.activeRequest?.status, .pending, "optimistic pending is visible synchronously")
        service.confirmSend() // MYR-218: the deferred create POST fires on send
        await eventually { await api.createCount == 1 }
        await eventually { await api.lastCreateVehicleID == "veh-live" } // resolved from vehicles()

        service.accept()
        XCTAssertEqual(service.activeRequest?.status, .accepted)
        XCTAssertNotNil(service.activeRequest?.trackProgress, "an accepted now-ride seeds the static tracking progress")
        await eventually { await api.acceptCount == 1 }
        let acceptID = await api.lastAcceptID
        XCTAssertEqual(acceptID, "srv-1", "accept targets the server-assigned id, not the local UUID")
    }

    // MARK: pending → declined

    func testSubmitThenDeclineTransitionsPendingToDeclinedAndPosts() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-2", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        service.decline()
        XCTAssertEqual(service.activeRequest?.status, .declined)
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

        // Adoption: mutations now target the DISCOVERED server id, not the local UUID.
        service.accept()
        await eventually { await api.acceptCount == 1 }
        let acceptID = await api.lastAcceptID
        XCTAssertEqual(acceptID, "srv-found", "reconcile adopted the found ride's server id")
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
        let api = StubRideAPI(created: Self.wireRide(id: "srv-acc", status: .requested))
        await api.setDetail(Self.wireRide(id: "srv-acc", status: .requested))
        await api.setAcceptError(RestError.http(
            status: 409, code: .unrecognized("vehicle_unavailable"), message: "busy", subCode: nil
        ))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        service.submit(Self.liveInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        service.accept()
        await eventually { service.vehicleUnavailableFailure != nil }
        await eventually { service.activeRequest?.status == .pending }
        XCTAssertEqual(service.activeRequest?.status, .pending, "the refused accept folds back to the incoming card")
    }

    // MARK: MYR-270 — owner-driven dispatch v2 (picked-up / start / dropped-off)

    /// Drive a fresh service to the `.accepted` state (create → confirm → accept),
    /// with `serverRideID == id`. The shared setup for the advance tests below.
    private func acceptedService(id: String) async -> (LiveRideRequestService, StubRideAPI) {
        let api = StubRideAPI(created: Self.wireRide(id: id, status: .requested))
        await api.setDetail(Self.wireRide(id: id, status: .accepted, accepted: true))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)
        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }
        service.accept()
        await eventually { await api.acceptCount == 1 }
        XCTAssertEqual(service.activeRequest?.status, .accepted)
        return (service, api)
    }

    /// Advance the service to `.arrived` via `pickedUp()` (the owner path), waiting
    /// for the reconcile so a following `start()` sees the settled `.arrived`.
    private func advanceToArrived(_ service: LiveRideRequestService, _ api: StubRideAPI, id: String) async {
        await api.setAdvance(Self.wireRide(id: id, status: .arrived, accepted: true))
        await api.setDetail(Self.wireRide(id: id, status: .arrived, accepted: true))
        service.pickedUp()
        await eventually { service.activeRequest?.status == .arrived }
    }

    /// OWNER `pickedUp()` optimistically flips accepted → arrived synchronously and
    /// POSTs `/picked-up` on the SERVER id; the returned arrived record reconciles.
    func testPickedUpAdvancesAcceptedToArrivedAndPostsOnServerID() async {
        let (service, api) = await acceptedService(id: "srv-pu")
        await api.setAdvance(Self.wireRide(id: "srv-pu", status: .arrived, accepted: true))

        service.pickedUp()
        XCTAssertEqual(service.activeRequest?.status, .arrived, "picked-up flips to arrived synchronously")

        await eventually { await api.pickedUpCount == 1 }
        let puID = await api.lastAdvanceID
        XCTAssertEqual(puID, "srv-pu", "picked-up targets the server-assigned id")
        await eventually { service.activeRequest?.status == .arrived }
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
        await eventually { service.activeRequest?.status == .enroute }

        await api.setAdvance(Self.wireRide(id: "srv-do", status: .completed, accepted: true))
        service.droppedOff()
        XCTAssertEqual(service.activeRequest?.status, .completed, "dropped-off completes synchronously")

        await eventually { await api.droppedOffCount == 1 }
        let doID = await api.lastAdvanceID
        XCTAssertEqual(doID, "srv-do", "dropped-off targets the server-assigned id")
        await eventually { service.activeRequest?.status == .completed }
    }

    /// `start()` before pickup is confirmed is a no-op locally: from `.accepted`
    /// (owner has not tapped Picked up), the CTA is not even shown, and the guard
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
        let api = StubRideAPI(created: Self.wireRide(id: "srv-409a", status: .requested))
        // The accept POST is refused; the authoritative refetch still reads requested.
        await api.setAcceptError(RestError.http(status: 409, code: .conflict, message: "vehicle unavailable", subCode: nil))
        await api.setDetail(Self.wireRide(id: "srv-409a", status: .requested))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        service.accept()
        XCTAssertEqual(service.activeRequest?.status, .accepted, "optimistic accepted first")
        await eventually { await api.acceptCount == 1 }
        // 409 → refetch reads requested → folded back to pending (sheet re-shows).
        await eventually { service.activeRequest?.status == .pending }
        XCTAssertNil(service.activeRequest?.acceptedAt, "the reverted request carries no acceptedAt")
    }

    /// A 409 whose reconciling refetch ALSO fails: the optimistic accept still can't
    /// stand (the server never accepted), so it reverts to pending locally.
    func testAccept409WithFailedRefetchRevertsToPending() async {
        let api = StubRideAPI(created: Self.wireRide(id: "srv-409b", status: .requested))
        await api.setAcceptError(RestError.http(status: 409, code: .conflict, message: "vehicle unavailable", subCode: nil))
        await api.setDetailError(URLError(.notConnectedToInternet))
        let service = LiveRideRequestService(api: api, socket: StubRideSocket(), autoStart: false)

        service.submit(Self.sampleInput())
        service.confirmSend()
        await eventually { await api.createCount == 1 }

        service.accept()
        await eventually { service.activeRequest?.status == .pending }
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
        await eventually { service.activeRequest?.id == id } // owner incoming seed
        XCTAssertEqual(service.activeRequestOrigin, .ownerIncoming)
        await eventually { await socket.isListening }

        // …owner accepts, ride runs, owner taps "Dropped off" → completed.
        await api.setDetail(Self.wireRide(id: id, status: .completed, accepted: true))
        await socket.push(.statusChanged(RideStatusChangedPayload(
            rideRequestId: id, vehicleId: "veh-live", status: .completed, timestamp: "2026-07-26T18:30:00.000Z"
        )))
        await eventually { service.activeRequest?.status == .completed }
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

        await eventually { service.activeRequest?.id == "srv-next" }
        XCTAssertEqual(service.activeRequest?.status, .pending, "the owner's incoming sheet can show again")
        XCTAssertEqual(service.activeRequestOrigin, .ownerIncoming)

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
        XCTAssertEqual(service.activeRequest?.id, "srv-done2", "only a pending incoming request may take the slot")
        XCTAssertEqual(service.activeRequest?.status, .completed)
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
        XCTAssertEqual(service.activeRequestOrigin, .rider)
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
        XCTAssertEqual(service.activeRequestOrigin, .rider)

        // …and once the rider taps "See you soon" the slot frees up normally.
        _ = service.completeAndReset()
        XCTAssertNil(service.activeRequest)
        XCTAssertNil(service.activeRequestOrigin)
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
        XCTAssertEqual(service.activeRequest?.id, "srv-waiting", "a waiting request is adopted over the dead completed ride")
        XCTAssertEqual(service.activeRequest?.status, .pending)
    }

    /// …and the rider-safety half of the same guard on the `refreshIncoming()` path.
    func testRefreshIncomingDoesNotAdoptOverRiderCompletedRide() async {
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
        XCTAssertEqual(service.activeRequestOrigin, .rider)
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
