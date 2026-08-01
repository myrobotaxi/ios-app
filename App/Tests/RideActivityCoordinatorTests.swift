import CoreLocation
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - Token registration, rotation and the 409 (MYR-172)
//
// The ActivityKit half is stubbed (`StubRideActivityPresenter`) exactly as MYR-186
// stubs `PushAuthorizing`; what is asserted here is everything AROUND the
// framework — hex encoding, the sandbox flag, re-registration on rotation, and the
// 409-means-end-locally rule.

@MainActor
final class RideActivityCoordinatorTests: XCTestCase {

    // MARK: - Registration

    func testStartingAnActivityRegistersItsTokenAsLowercaseHex() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0x8a, 0x1f, 0x4c, 0x2e, 0x00, 0xff]))
        await settle()

        let calls = endpoint.registrations
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.rideID, "ride-1")
        XCTAssertEqual(
            calls.first?.token,
            "8a1f4c2e00ff",
            """
            The server validates HEX. `Data.description` — the shape a naive \
            interpolation produces — is "<8a1f4c2e 00ff>", which is not it. Note \
            the zero byte: it must pad to "00", not collapse to "0".
            """
        )
        XCTAssertTrue(presenter.isPresenting)
    }

    func testTheHexEncodingIsMYR186sAndNotASecondCopy() {
        // The same encoder the device token uses. Two encoders is two places to get
        // padding or case wrong.
        XCTAssertEqual(PushDeviceToken.hex(from: Data([0x00, 0x0f, 0xff])), "000fff")
    }

    func testTheSandboxFlagMirrorsTheBuildsAPNsEnvironment() async throws {
        let (sandboxCoordinator, sandboxPresenter, sandboxEndpoint) = makeCoordinator(sandbox: true)
        await sandboxCoordinator.handleRideChange(makeRecord(status: .accepted))
        sandboxPresenter.emit(token: Data([0x01]))
        await settle()
        XCTAssertEqual(sandboxEndpoint.registrations.first?.sandbox, true)

        let (prodCoordinator, prodPresenter, prodEndpoint) = makeCoordinator(sandbox: false)
        await prodCoordinator.handleRideChange(makeRecord(status: .accepted))
        prodPresenter.emit(token: Data([0x01]))
        await settle()
        XCTAssertEqual(
            prodEndpoint.registrations.first?.sandbox,
            false,
            """
            Sent explicitly rather than omitted on the production arm: the schema \
            defaults a missing key to production, so omitting it would make \
            "production" and "the client did not say" the same bytes.
            """
        )
    }

    func testTheDefaultSandboxFlagIsTheSameOneMYR186Uses() {
        // Not re-derived from an entitlement read or a profile parse — one source
        // of truth for the whole app.
        #if DEBUG
        XCTAssertTrue(PushEnvironment.isSandbox)
        #else
        XCTAssertFalse(PushEnvironment.isSandbox)
        #endif
    }

    // MARK: - Rotation

    func testAROTATEDTokenIsREREGISTERED() async throws {
        // ActivityKit reissues the token during the life of ONE Activity and
        // expects the server to switch. Missing a rotation fails silently: the old
        // token simply stops delivering and the lock screen stops updating.
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()
        presenter.emit(token: Data([0xbb]))
        await settle()

        XCTAssertEqual(endpoint.registrations.map(\.token), ["aa", "bb"])
        XCTAssertEqual(
            Set(endpoint.registrations.map(\.rideID)),
            ["ride-1"],
            "a rotation is an ordinary re-registration against the SAME ride — the endpoint upserts"
        )
    }

    func testTheSAMETokenTwiceForTheSameRideIsNotReRegistered() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertEqual(endpoint.registrations.count, 1, "a wasted round trip on every foreground")
    }

    // MARK: - The 409

    func testA409OnRegistrationENDSTheActivityLocally() async throws {
        // §7.21: posting against a ride that has already reached a terminal state is
        // 409, "and the 409 is the signal to end it locally". This is the ONLY thing
        // that rescues a rider whose ride ended while the app was not running.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        endpoint.registrationResult = .failure(
            RestError.http(status: 409, code: nil, message: nil, subCode: nil)
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertFalse(presenter.isPresenting, "the card must come off the lock screen")
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(endpoint.ends, ["ride-1"], "and the server is told the Activity is gone")
    }

    func testTheTerminalConflictIsRecognisedByStatusAlone() {
        XCTAssertTrue(
            RestError.http(status: 409, code: nil, message: nil, subCode: nil)
                .isTerminalRideActivityConflict
        )
        XCTAssertFalse(
            RestError.http(status: 500, code: nil, message: nil, subCode: nil)
                .isTerminalRideActivityConflict
        )
        XCTAssertFalse(RestError.transport(underlying: URLError(.timedOut)).isTerminalRideActivityConflict)
    }

    func testATRANSIENTFailureLeavesTheActivityUpAndRetriesOnTheNextRotation() async throws {
        // Pushes are the primary channel but the app is the backstop, and the
        // backstop is still standing. Tearing the card down on a 500 would punish
        // the rider for the server's bad minute.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        endpoint.registrationResult = .failure(
            RestError.http(status: 503, code: nil, message: nil, subCode: nil)
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertTrue(presenter.isPresenting)
        XCTAssertNil(presenter.endedWith)

        endpoint.registrationResult = .success(LiveActivityRegistrationResponse(registered: true, sandbox: true))
        presenter.emit(token: Data([0xaa]))
        await settle()

        XCTAssertEqual(
            endpoint.attempts.count,
            2,
            """
            The failed attempt recorded nothing in `registered`, so the SAME token is \
            tried again rather than deduped away as already-registered. A dedup that \
            counted failures would strand the Activity: the server would never learn \
            the token, and the lock screen would sit there never updating.
            """
        )
        XCTAssertEqual(endpoint.registrations.count, 1, "and exactly one of the two succeeded")
    }

    // MARK: - Lifecycle end to end

    func testACompletedRideEndsWithTheLingerAndTellsTheServer() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleRideChange(makeRecord(status: .completed))

        XCTAssertEqual(presenter.endedWith?.state.status, .completed)
        XCTAssertEqual(presenter.endedWith?.dismissal, .completedLinger)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAnErasedRideEndsTheActivityAsCancelled() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleRideChange(nil)

        XCTAssertEqual(presenter.endedWith?.state.status, .cancelled)
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
    }

    func testSigningOutTakesTheCardDownAtOnce() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleSignOut()

        XCTAssertFalse(
            presenter.isPresenting,
            """
            the card names the rider's DESTINATION, which is P1 and scoped to that \
            one rider — it must not still be there when the next account signs in
            """
        )
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
    }

    // MARK: - Simulated mode

    func testSIMULATEDModeNeverTouchesActivityKitOrTheNetwork() async throws {
        // A fixture ride putting a real card on a real lock screen would be visible
        // to a human, not just to a test. This is the same inert-by-construction
        // rule `PushComposition` follows.
        let presenter = StubRideActivityPresenter()
        let endpoint = SpyRideActivityEndpoint()
        let coordinator = RideActivityCoordinator(
            presenter: presenter,
            endpoint: endpoint,
            isLive: false,
            sandbox: true,
            vehicleName: { "Blue Whale" }
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        XCTAssertFalse(presenter.isPresenting)
        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertTrue(endpoint.registrations.isEmpty)
        XCTAssertTrue(endpoint.ends.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testASYSTEMREFUSALIsOrdinaryAndRegistersNothing() async throws {
        // The rider may simply have Live Activities switched off in Settings. That
        // is not an error and must not leave the coordinator believing it holds a
        // card.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.allowsStart = false

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(endpoint.registrations.isEmpty)
        XCTAssertTrue(endpoint.ends.isEmpty)
    }

    // MARK: - MYR-405: the restore race, and the duplicate it produced

    func testTheStartPathWAITSForTheRestoreAndADOPTSInsteadOfStartingASecondCard() async throws {
        // THE CLIENT'S SCREENSHOT, AS A TEST. `Activity.activities` is restored
        // ASYNCHRONOUSLY: the first reads of a process answer EMPTY even though a
        // card for this very ride is on the lock screen. The old start path read
        // once, saw nothing to adopt, and called `Activity.request` — two banners
        // for one ride, and because the server keeps one token per (ride, rider) the
        // older one starved on "IN RIDE · Not updating" for ever.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restoreScript = [[], [], [snapshot("ride-1")], [snapshot("ride-1")]]

        await coordinator.handleRideChange(makeRecord(status: .enroute))
        await settle()

        XCTAssertEqual(
            presenter.startCount,
            0,
            "a second `Activity.request` for a ride that already has a card IS the defect"
        )
        XCTAssertEqual(presenter.adopted, ["ride-1"])
        XCTAssertEqual(coordinator.phase.rideID, "ride-1")
        XCTAssertGreaterThan(
            presenter.restoreReads,
            2,
            "an empty list is not evidence until the budget has been spent on it"
        )
    }

    func testAnADOPTEDActivityHasITSOwnTokenReRegistered() async throws {
        // The other half of the fix, and the half that makes the kept banner LIVE
        // again. The server rotates on (ride, rider), so until it hears the adopted
        // Activity's own token every push still addresses whatever this account
        // registered last — which, in the client's case, was the duplicate.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("ride-1")]

        await coordinator.handleRideChange(makeRecord(status: .enroute))
        presenter.emit(token: Data([0xc0, 0xde]))
        await settle()

        XCTAssertEqual(presenter.adopted, ["ride-1"])
        XCTAssertEqual(endpoint.registrations.map(\.token), ["c0de"])
        XCTAssertEqual(endpoint.registrations.map(\.rideID), ["ride-1"])
    }

    func testADUPLICATEOfTheSameRideIsReapedWITHOUTDeletingThatRidesRegistration() async throws {
        // Healing an install that is ALREADY in the broken state: two on-screen
        // cards for one ride. One is kept and the other ended — and the §7.21 delete
        // must NOT fire, because it is keyed on the RIDE and would delete the
        // registration belonging to the banner just adopted.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("ride-1"), snapshot("ride-1")]

        await coordinator.handleLaunchOrForeground(account(makeRecord(status: .enroute)))
        await settle()

        XCTAssertEqual(presenter.adopted, ["ride-1"])
        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["ride-1"], "the second card comes down")
        XCTAssertEqual(presenter.endedActivities.map(\.dismissal), [.immediate])
        XCTAssertTrue(
            endpoint.ends.isEmpty,
            "deleting the (ride, rider) registration here would starve the card we kept"
        )
        XCTAssertEqual(presenter.startCount, 0)
    }

    // MARK: - MYR-405: orphan reaping

    func testAnORPHANIsReapedOnLaunchWhenTheAccountHoldsNoRide() async throws {
        // The generalization of §7.21's 409-means-end-now. The ride ended while the
        // app was not running, the terminal push was missed, and nothing in the app
        // could reach the card: `handleRideChange` reasons from `phase`, which is
        // this process's memory and is empty at launch.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("ride-gone")]

        await coordinator.handleLaunchOrForeground(account(nil))
        await settle()

        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["ride-gone"])
        XCTAssertEqual(presenter.endedActivities.map(\.dismissal), [.immediate])
        XCTAssertEqual(endpoint.ends, ["ride-gone"], "and the server stops pushing to it")
    }

    func testAnActivityForARideThatIsNOTTheAccountsActiveOneIsReaped() async throws {
        let (coordinator, presenter, _) = makeCoordinator()
        presenter.restored = [snapshot("someone-elses-ride"), snapshot("ride-1")]

        await coordinator.handleLaunchOrForeground(account(makeRecord(status: .enroute)))
        await settle()

        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["someone-elses-ride"])
        XCTAssertEqual(presenter.adopted, ["ride-1"], "and the live one is kept, not restarted")
    }

    func testTheREAPERWaitsForTheRidePipelineAndEndsNOTHINGUntilItAnswers() async throws {
        // THE GUARD THAT KEEPS THE FIX FROM BEING WORSE THAN THE BUG. On a cold
        // launch `activeRequest` is nil because §7.8 has not answered — not because
        // the rider has no ride. Reaping on that reading would take a live ride's
        // card off the lock screen every time the phone launched with no signal.
        // MYR-326's "loading ≠ unavailable", with a lock-screen card as the casualty.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("ride-1")]

        await coordinator.handleLaunchOrForeground(account(nil, resolved: false))
        await settle()

        XCTAssertTrue(presenter.endedActivities.isEmpty, "a read that has not answered is not evidence")
        XCTAssertTrue(endpoint.ends.isEmpty)
        XCTAssertTrue(presenter.adopted.isEmpty, "and nothing is adopted on that reading either")
    }

    func testTheRideListAnsweringMIDPOLLIsWhatTheReaperActsOn() async throws {
        // The launch sequence for real: the Activity list and the §7.8 read settle
        // at roughly the same time, and ONE budget covers both. The reaper must act
        // on the answered reading, not on the first one.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restoreScript = [[], [snapshot("ride-gone")], [snapshot("ride-gone")]]
        var resolved = false

        await coordinator.handleLaunchOrForeground {
            defer { resolved = true }
            return RideActivityAccountRide(record: nil, isResolved: resolved)
        }
        await settle()

        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["ride-gone"])
        XCTAssertEqual(endpoint.ends, ["ride-gone"])
    }

    func testAnALREADYENDEDActivityIsLEFTALONESoTheCompletedLingerSurvives() async throws {
        // `.ended` means the card is living out its dismissal policy — which for a
        // completed ride is MYR-405's own five minutes. Reaping it would take the
        // arrival card away seconds after it appeared: this issue's fix cancelling
        // this issue's fix.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("ride-done", .ended)]

        await coordinator.handleLaunchOrForeground(account(nil))
        await settle()

        XCTAssertTrue(presenter.endedActivities.isEmpty)
        XCTAssertTrue(endpoint.ends.isEmpty)
    }

    // MARK: - MYR-405: a new ride ends every prior card

    func testStartingANEWRidesActivityEndsALLPriorOnes() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("old-ride-a"), snapshot("old-ride-b")]

        await coordinator.handleRideChange(makeRecord(id: "ride-new", status: .accepted))
        await settle()

        XCTAssertEqual(
            Set(presenter.endedActivities.map(\.rideID)),
            ["old-ride-a", "old-ride-b"]
        )
        XCTAssertEqual(Set(endpoint.ends), ["old-ride-a", "old-ride-b"])
        XCTAssertEqual(presenter.startCount, 1, "and exactly one card is on the lock screen after it")
        XCTAssertEqual(coordinator.phase.rideID, "ride-new")
    }

    // MARK: - MYR-405: the rider's swipe is final

    func testARIDERSDISMISSALIsNeverResurrectedForTheSameRide() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        XCTAssertEqual(presenter.startCount, 1)

        presenter.emit(lifecycle: .dismissed)
        await settle()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(
            endpoint.ends,
            ["ride-1"],
            "the server is told to stop pushing to a card nobody can see"
        )

        // Every route back in: a status change, a foreground, a relaunch.
        await coordinator.handleRideChange(makeRecord(status: .enroute))
        await coordinator.handleLaunchOrForeground(account(makeRecord(status: .enroute)))
        await settle()

        XCTAssertEqual(
            presenter.startCount,
            1,
            """
            Starting a second card here would overrule the rider repeatedly and make \
            the swipe look broken. The in-app tracking sheet still carries the ride, \
            exactly as it does for a rider who never enabled Live Activities.
            """
        )
    }

    func testANEWRideAfterADismissalStartsNormally() async throws {
        // The client's own "or if new ride begins". A dismissal is a decision about
        // ONE ride, not a standing opt-out.
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        presenter.emit(lifecycle: .dismissed)
        await settle()

        await coordinator.handleRideChange(makeRecord(id: "ride-2", status: .accepted))
        await settle()

        XCTAssertEqual(presenter.startCount, 2)
        XCTAssertEqual(coordinator.phase.rideID, "ride-2")
    }

    func testADISMISSEDCardFoundInTheRestoreListIsNotRestarted() async throws {
        // A dismissal has to survive the process it happened in: the rider swiped,
        // force-quit, and relaunched into the same live ride.
        let (coordinator, presenter, _) = makeCoordinator()
        presenter.restored = [snapshot("ride-1", .dismissed)]

        await coordinator.handleLaunchOrForeground(account(makeRecord(status: .enroute)))
        await settle()

        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertTrue(presenter.adopted.isEmpty, "a dismissed card is not on screen to adopt")
        XCTAssertTrue(presenter.endedActivities.isEmpty, "and nothing is on screen to reap")
    }

    func testSigningOutTakesDownORPHANSToo() async throws {
        // The card names the rider's DESTINATION, which is P1. An orphan left by a
        // previous process names it just as loudly as the one this process holds,
        // and until MYR-405 sign-out could not see it at all.
        let (coordinator, presenter, endpoint) = makeCoordinator()
        presenter.restored = [snapshot("ride-from-a-previous-process")]

        // Nothing is held: this process never started that card, which is exactly
        // the situation `phase`-based cleanup could not see.
        await coordinator.handleSignOut()
        await settle()

        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["ride-from-a-previous-process"])
        XCTAssertEqual(endpoint.ends, ["ride-from-a-previous-process"])
    }

    // MARK: - MYR-405: five minutes

    func testACompletedRideEndsWithTheFIVEMinuteLinger() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .completed))

        XCTAssertEqual(presenter.endedWith?.dismissal, .linger(5 * 60))
    }

    // MARK: - Harness

    private func makeCoordinator(
        sandbox: Bool = true,
        vehicle: @escaping @MainActor () -> RideActivityVehicle? = { nil }
    ) -> (RideActivityCoordinator, StubRideActivityPresenter, SpyRideActivityEndpoint) {
        let presenter = StubRideActivityPresenter()
        let endpoint = SpyRideActivityEndpoint()
        let coordinator = RideActivityCoordinator(
            presenter: presenter,
            endpoint: endpoint,
            isLive: true,
            sandbox: sandbox,
            vehicleName: { "Blue Whale" },
            vehicle: vehicle,
            // MYR-405 — the restore budget is real seconds in production and zero
            // here. The POLL still runs, read for read; only the waiting is skipped,
            // so `restoreReads` remains a true count of how hard the coordinator
            // looked before it believed an empty list.
            sleep: { _ in }
        )
        return (coordinator, presenter, endpoint)
    }

    // MARK: - MYR-398 v3: the new start point and the static vehicle

    /// **THE ACTIVITY STARTS AT REQUEST**, through the whole coordinator rather than
    /// only through the pure decision — because the start path is where MYR-405 put
    /// the restore budget, the adoption and the reap, and every one of those now runs
    /// one status earlier than it used to.
    func testAnInstantRequestStartsAnActivityThroughTheRealStartPath() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .pending))
        await settle()

        XCTAssertEqual(presenter.startCount, 1)
        XCTAssertEqual(coordinator.phase.rideID, "ride-1")
        XCTAssertEqual(coordinator.phase.state?.status, .requested)
    }

    /// **AND MYR-405's SEMANTICS ARE UNCHANGED AT THE NEW START POINT.** The reap of
    /// a prior orphan, the adoption of a card for this same ride, and the refusal to
    /// resurrect a dismissal all have to hold one status earlier — that is the whole
    /// risk of moving a start point into a state machine somebody else's issue owns.
    func testTheNewStartPointStillADOPTSTheSameRidesRestoredCard() async throws {
        let (coordinator, presenter, _) = makeCoordinator()
        presenter.restored = [snapshot("ride-1")]

        await coordinator.handleRideChange(makeRecord(status: .pending))
        await settle()

        XCTAssertEqual(presenter.adopted, ["ride-1"])
        XCTAssertEqual(presenter.startCount, 0, "adopt, never duplicate — at requested too")
    }

    func testTheNewStartPointStillREAPSAPriorOrphan() async throws {
        let (coordinator, presenter, _) = makeCoordinator()
        presenter.restored = [snapshot("ride-0")]

        await coordinator.handleRideChange(makeRecord(status: .pending))
        await settle()

        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["ride-0"])
        XCTAssertEqual(presenter.startCount, 1)
    }

    func testTheNewStartPointStillHonoursADismissal() async throws {
        let (coordinator, presenter, _) = makeCoordinator()
        presenter.restored = [snapshot("ride-1", .dismissed)]

        await coordinator.handleRideChange(makeRecord(status: .pending))
        await settle()

        XCTAssertEqual(presenter.startCount, 0, "the rider swiped this ride away")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// **THE CAR TRAVELS AS A STATIC ATTRIBUTE**, read once at `Activity.request`.
    ///
    /// This is what keeps the feature off the wire entirely: no content-state field,
    /// no schema bump, no server work. A test that only checked the card's subline
    /// would pass with the attribute never plumbed.
    func testTheStaticVehicleReachesActivityRequest() async throws {
        let vehicle = RideActivityVehicle(
            plate: "7SRJ294", color: "Silver", model: "Model Y", year: 2026
        )
        let (coordinator, presenter, _) = makeCoordinator(vehicle: { vehicle })

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()

        XCTAssertEqual(presenter.startedAttributes.first?.vehicle, vehicle)
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(presenter.startedAttributes.first?.vehicle),
            "7SRJ294 · Silver 2026 Model Y"
        )
    }

    /// A ride whose vehicle the app has not resolved yet starts anyway, with no
    /// attribute — and the card says "Your Tesla" rather than nothing.
    func testAnUnresolvedVehicleStillStartsTheActivity() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()

        XCTAssertEqual(presenter.startCount, 1)
        XCTAssertNil(presenter.startedAttributes.first?.vehicle)
    }

    /// The account as the app can state it, for the launch/foreground entry point.
    private func account(
        _ record: RideRequestRecord?,
        resolved: Bool = true
    ) -> @MainActor () -> RideActivityAccountRide {
        { RideActivityAccountRide(record: record, isResolved: resolved) }
    }

    private func snapshot(
        _ rideID: String,
        _ lifecycle: RideActivitySnapshot.Lifecycle = .active
    ) -> RideActivitySnapshot {
        RideActivitySnapshot(rideID: rideID, lifecycle: lifecycle)
    }

    /// Let the token-consuming `Task` run. The stream is fed from the test, so a
    /// couple of yields is enough — there is no real clock anywhere in this path.
    /// Let the coordinator's unstructured registration `Task` run to completion.
    ///
    /// MYR-377 — this was six bare `Task.yield()`s, and it is a PRE-EXISTING FLAKE
    /// rather than anything this issue changed: `RideActivityCoordinatorTests` fails
    /// its 409 and transient-retry cases on `origin/main` when run in ISOLATION (14
    /// tests, 6 failures, reproducible), and passes inside the full suite, because
    /// how many yields it takes for a detached task to reach an `await` is a
    /// function of what else the cooperative pool is doing. Adding tests anywhere in
    /// the target is enough to flip it — which is exactly what a suite must not do.
    ///
    /// Yielding AND sleeping gives the pool a real chance to schedule rather than a
    /// hopeful one. Deliberately not asserting on coordinator internals to know when
    /// to stop: these tests are about observable effects, and a settle helper that
    /// reached into the thing under test would be assertion by another name.
    private func settle() async {
        for _ in 0..<12 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeRecord(id: String = "ride-1", status: MyRoboTaxi.RideRequestStatus) -> RideRequestRecord {
        let place = RidePlace(
            id: "dest", label: "Home", subtitle: nil, miles: 4.2, minutes: 12,
            icon: "house.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
        )
        var record = RideRequestRecord(
            id: id,
            input: RideRequestInput(pickup: place, destination: place, fleetMemberID: "vehicle-1"),
            status: status
        )
        record.status = status
        return record
    }
}

// MARK: - Fakes

@MainActor
final class StubRideActivityPresenter: RideActivityPresenting {
    var areActivitiesEnabled = true
    var allowsStart = true

    private(set) var startCount = 0
    /// MYR-398 v3 — the STATIC attributes each start was given, so a test can assert
    /// the vehicle reached `Activity.request` rather than only that a card appeared.
    private(set) var startedAttributes: [RideActivityAttributes] = []
    private(set) var updates: [RideActivityAttributes.ContentState] = []
    private(set) var endedWith: (state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal)?
    private(set) var isPresenting = false

    private var continuation: AsyncStream<Data>.Continuation?

    // MARK: - MYR-405: the restore list

    /// What `Activity.activities` answers RIGHT NOW.
    var restored: [RideActivitySnapshot] = []

    /// A SCRIPT of successive answers, which is how the async restore is
    /// reproduced: the real list is empty for the first reads of a process and
    /// fills in afterwards, and a coordinator that believes the first read is the
    /// one that starts a second banner.
    var restoreScript: [[RideActivitySnapshot]] = []

    private(set) var restoreReads = 0
    private(set) var adopted: [String] = []
    private(set) var endedActivities: [(rideID: String, dismissal: RideActivityDismissal)] = []

    private var lifecycleContinuation: AsyncStream<RideActivitySnapshot.Lifecycle>.Continuation?

    var presentedActivities: [RideActivitySnapshot] {
        restoreReads += 1
        if !restoreScript.isEmpty { restored = restoreScript.removeFirst() }
        return restored
    }

    func adopt(rideID: String) -> Bool {
        guard restored.contains(where: { $0.rideID == rideID && $0.lifecycle.isOnScreenAndOurs })
        else { return false }
        adopted.append(rideID)
        isPresenting = true
        heldRideID = rideID
        return true
    }

    func endActivity(rideID: String, dismissal: RideActivityDismissal) async {
        endedActivities.append((rideID, dismissal))
        // Mirrors `SystemRideActivityPresenter`: the HELD Activity is never ended by
        // id, which is the only reason "keep one of two identically-named cards" can
        // be expressed at all.
        var keepOne = heldRideID == rideID
        restored = restored.filter {
            guard $0.rideID == rideID else { return true }
            defer { keepOne = false }
            return keepOne
        }
    }

    func activityStates() -> AsyncStream<RideActivitySnapshot.Lifecycle> {
        AsyncStream { continuation in
            self.lifecycleContinuation = continuation
        }
    }

    /// Stand in for the SYSTEM reporting a state change — a rider's swipe, above all.
    func emit(lifecycle: RideActivitySnapshot.Lifecycle) {
        lifecycleContinuation?.yield(lifecycle)
    }

    func start(
        attributes: RideActivityAttributes,
        state: RideActivityAttributes.ContentState,
        staleDate: Date?
    ) async -> Bool {
        guard allowsStart, areActivitiesEnabled else { return false }
        // DELIBERATELY PERMISSIVE ABOUT A SECOND CARD. `Activity.request` will
        // happily give you one — that is the whole defect — so the stub grants it
        // and records it, letting a test catch the duplicate instead of having the
        // fake quietly prevent what production does not.
        startCount += 1
        startedAttributes.append(attributes)
        isPresenting = true
        endedWith = nil
        heldRideID = attributes.rideID
        restored.append(RideActivitySnapshot(rideID: attributes.rideID, lifecycle: .active))
        return true
    }

    func update(state: RideActivityAttributes.ContentState, staleDate: Date?) async {
        updates.append(state)
    }

    func end(state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal) async {
        endedWith = (state, dismissal)
        isPresenting = false
        continuation?.finish()
        continuation = nil
        lifecycleContinuation?.finish()
        lifecycleContinuation = nil
        // A `.linger` end leaves the Activity ON SCREEN in state `.ended` for the
        // whole dismissal window, which is exactly the row a later reap must not
        // touch. `.immediate` takes it off the list.
        switch dismissal {
        case .immediate:
            restored.removeAll { $0.rideID == heldRideID }
        case .linger:
            restored = restored.map {
                $0.rideID == heldRideID
                    ? RideActivitySnapshot(rideID: $0.rideID, lifecycle: .ended)
                    : $0
            }
        }
    }

    private var heldRideID: String?

    func pushTokens() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Stand in for ActivityKit issuing (or reissuing) the Activity's push token.
    func emit(token: Data) {
        continuation?.yield(token)
    }
}

final class SpyRideActivityEndpoint: RideActivityTokenEndpoint, @unchecked Sendable {
    struct Registration: Equatable {
        let rideID: String
        let token: String
        let sandbox: Bool
    }

    /// Calls that SUCCEEDED.
    private(set) var registrations: [Registration] = []
    /// Every call the coordinator made, successful or not. Kept separately because
    /// the interesting property of a failed registration is that it was ATTEMPTED
    /// — a spy that records only successes cannot tell "retried and failed again"
    /// from "never retried at all".
    private(set) var attempts: [Registration] = []
    private(set) var ends: [String] = []

    var registrationResult: Result<LiveActivityRegistrationResponse, Error> =
        .success(LiveActivityRegistrationResponse(registered: true, sandbox: true))

    func registerRideActivityToken(
        rideID: String,
        token: String,
        sandbox: Bool
    ) async throws -> LiveActivityRegistrationResponse {
        let call = Registration(rideID: rideID, token: token, sandbox: sandbox)
        attempts.append(call)
        switch registrationResult {
        case .success(let response):
            registrations.append(call)
            return response
        case .failure(let error):
            throw error
        }
    }

    func endRideActivityToken(rideID: String) async throws -> EndLiveActivityResponse {
        ends.append(rideID)
        return EndLiveActivityResponse(ended: true)
    }
}
