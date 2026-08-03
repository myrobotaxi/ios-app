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

    /// **MYR-425 — THE WHOLE FIX, THROUGH THE REAL COORDINATOR.** This test used to
    /// assert the defect: `endedWith?.dismissal == .completedLinger`, `endpoint.ends
    /// == ["ride-1"]`, `phase == .idle`, all within half a second of the drop-off.
    /// Every one of those is now the thing that must NOT happen.
    func testACompletedRideUPDATESTheCardAndKEEPSItsRegistration() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        XCTAssertNil(
            presenter.endedWith,
            """
            Ending here is the production defect: an `.ended` Activity leaves the \
            Dynamic Island ~1.4s later whatever its dismissal date says.
            """
        )
        XCTAssertEqual(presenter.updates.last?.status, .completed, "the final frame IS written")
        XCTAssertTrue(presenter.isPresenting)
        XCTAssertEqual(coordinator.phase.rideID, "ride-1")
        XCTAssertTrue(
            endpoint.ends.isEmpty,
            """
            THE HALF THAT PRODUCED THE EMPTY alerted_phase 6. The §7.21 DELETE \
            tombstones the (ride, rider) row, so the server's completed announcement \
            found zero recipients and its held end had nothing to hold.
            """
        )
        XCTAssertEqual(endpoint.registrations.count, 1, "and the registration is untouched, not re-placed")
    }

    func testTheCompletedUpdateCarriesNOStaleDate() async throws {
        // `RideActivityStaleness.window` is three minutes and the server's held end
        // is five away, so a completed frame written with the default stale date
        // would grey itself out while it waits. `SystemRideActivityPresenter.end`
        // has always passed nil here; the UPDATE path had no terminal status until now.
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .enroute))
        await settle()
        XCTAssertNotNil(presenter.updateStaleDates.last ?? nil, "a RUNNING ride can still move on without us")

        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        XCTAssertEqual(presenter.updates.last?.status, .completed)
        XCTAssertNil(presenter.updateStaleDates.last ?? Date(), "a finished ride cannot move on")
    }

    /// **THE SERVER'S HELD END, HONOURED — and no fight over it.** MYR-421's end
    /// arrives over APNs and reaches this app only as an `.ended` lifecycle. The
    /// coordinator stands down: no second end, and no DELETE, because the end that
    /// removed the card is the same event that closed the server's row.
    func testAServerDeliveredENDArrivingLaterIsHonouredWithoutAFight() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()
        XCTAssertEqual(coordinator.phase.rideID, "ride-1")

        presenter.deliverServerEnd()
        await settle()

        XCTAssertEqual(coordinator.phase, .idle, "this process stops driving a card that is gone")
        XCTAssertNil(presenter.endedWith, "the client does not end a card the server already ended")
        XCTAssertTrue(endpoint.ends.isEmpty, "and does not delete a row the server's end already closed")

        // And nothing brings it back: a later tick over the same completed record
        // neither restarts a card nor ends one.
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()
        XCTAssertEqual(presenter.startCount, 1)
        XCTAssertNil(presenter.endedWith)
        XCTAssertTrue(endpoint.ends.isEmpty)
    }

    /// The backstop, driven the way it is driven in production: the MYR-405
    /// launch/foreground reconcile pass, which finishes by re-asking `action`.
    func testTheBACKSTOPEndsTheCardFiveMinutesOnWithNoServerEnd() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        var completed = makeRecord(status: .completed)
        completed.completedAt = Date().addingTimeInterval(-RideActivityCompletedEnd.backstop - 1)

        await coordinator.handleLaunchOrForeground(account(completed))
        await settle()

        XCTAssertEqual(presenter.endedWith?.state.status, .completed, "the same final frame, not a blank one")
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(endpoint.ends, ["ride-1"], "and only NOW is the registration released")
    }

    func testTheBackstopDoesNotFireWhileTheServersEndIsStillDue() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()

        var completed = makeRecord(status: .completed)
        completed.completedAt = Date().addingTimeInterval(-60)

        await coordinator.handleRideChange(completed)
        await coordinator.handleLaunchOrForeground(account(completed))
        await settle()

        XCTAssertNil(presenter.endedWith, "one minute in, the server's held end is still four minutes away")
        XCTAssertEqual(coordinator.phase.rideID, "ride-1")
        XCTAssertTrue(endpoint.ends.isEmpty)
    }

    func testTheBackstopDoesNOTFireAfterAServerEnd() async throws {
        // The double-fire guard. The card is already gone, the row is already closed,
        // and a backstop that ran anyway would issue a DELETE against a ride the
        // server has finished with — and, on a fresh card for a NEW ride, would be
        // the MYR-405 starvation reached by a new door.
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        // The ride completes, the card stays live, and the SERVER'S end lands well
        // inside the five minutes — the ordinary, healthy sequence.
        var justCompleted = makeRecord(status: .completed)
        justCompleted.completedAt = Date().addingTimeInterval(-60)
        await coordinator.handleRideChange(justCompleted)
        await settle()
        presenter.deliverServerEnd()
        await settle()
        XCTAssertEqual(coordinator.phase, .idle)

        // Now the backstop's deadline passes and every driver is re-run over the same
        // ride. Nothing may fire: the card is gone and the row is already closed.
        var longSinceCompleted = makeRecord(status: .completed)
        longSinceCompleted.completedAt = Date().addingTimeInterval(-RideActivityCompletedEnd.backstop - 1)
        await coordinator.handleRideChange(longSinceCompleted)
        await coordinator.handleLaunchOrForeground(account(longSinceCompleted))
        await settle()

        XCTAssertNil(presenter.endedWith, "the client must not end a card twice")
        XCTAssertTrue(endpoint.ends.isEmpty, "nor delete a row the server's own end already closed")
        XCTAssertEqual(presenter.startCount, 1, "and must not resurrect one either")
    }

    func testANEWRideStillEndsTheLingeringCompletedCard() async throws {
        // MYR-405 semantic 4, preserved — and now REACHED through the `.restart`
        // arm, since the completed card is `.active` rather than an `.ended` row the
        // reaper deliberately skips. The client's own rule: "clear banners after 5min
        // OR if new ride begins".
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        await coordinator.handleRideChange(makeRecord(id: "ride-2", status: .accepted))
        await settle()

        // `presenter.endedWith` is cleared by the new `start`, so the observable
        // proof that the old card came down is the §7.21 release plus the phase move.
        // What the ending FRAME says is asserted in the pure suite
        // (`testANEWRideEndsACompletedCardWITHOUTRelabellingItCancelled`).
        XCTAssertEqual(endpoint.ends, ["ride-1"], "the finished ride's registration is released here")
        XCTAssertEqual(coordinator.phase.rideID, "ride-2")
        XCTAssertEqual(presenter.startCount, 2)
        XCTAssertFalse(
            presenter.restored.contains { $0.rideID == "ride-1" && $0.lifecycle.isOnScreenAndOurs },
            "the client's own rule: clear banners after 5min OR if a new ride begins"
        )
    }

    func testTheRIDERSSwipeStillEndsACompletedCardsRegistration() async throws {
        // Semantic 5 is unchanged by MYR-425 and points the other way from the
        // server's end: a swipe is the RIDER's decision and the server must be told
        // to stop pushing to a card nobody can see.
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        presenter.emit(lifecycle: .dismissed)
        await settle()

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
    }

    func testADECLINEDRideStillEndsImmediatelyAndReleasesTheRegistration() async throws {
        // Byte-identical to before MYR-425: `declined` is outside the design's six
        // phases, no announcement is coming for it, and the prompt end is the point.
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        await coordinator.handleRideChange(makeRecord(status: .declined))
        await settle()

        XCTAssertEqual(presenter.endedWith?.state.status, .declined)
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
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

    /// MYR-405's five minutes SURVIVE MYR-425 — they simply belong to the server's
    /// held end now, and the card stays LIVE across them instead of `.ended`. What
    /// this asserts is the client's half: nothing comes down at the drop-off.
    func testTheFiveMinutesAreNowSpentLIVERatherThanEnded() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .completed))
        await settle()

        XCTAssertNil(presenter.endedWith)
        XCTAssertTrue(presenter.isPresenting)
        XCTAssertEqual(RideActivityCompletedEnd.backstop, 5 * 60)
    }

    // MARK: - MYR-415: the registration must name the SERVER's ride id

    /// **THE DEFECT, AS ONE ASSERTION.** `go_live_activities` was EMPTY across nine
    /// production rides in three days while `go_push_devices` stayed healthy, and
    /// this is the entire reason: the §7.21 POST named `RideRequestRecord.id`, which
    /// for a ride this device SUBMITTED is the client `UUID` that
    /// `LiveRideRequestService.submit` minted optimistically (MYR-218). `fold` copies
    /// that record forward verbatim, so the local id never becomes the server's —
    /// the server's lives only in `riderServerRideID` / `activeServerRideID`, which
    /// is what accept, decline and cancel have always posted on.
    ///
    /// So the app posted to `/api/ride-requests/{client-uuid}/activity-token` for
    /// every ride, got a 404 for a ride the server has never heard of, and swallowed
    /// it. `go_push_devices` was unaffected because MYR-186's registration is
    /// ACCOUNT-scoped and carries no ride id at all.
    func testTheTokenIsRegisteredUnderTheServerRideIDNotTheLocalDraftUUID() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(
            serverRideID: { "clride0000000000000001" }
        )

        // The record carries the optimistic client UUID, exactly as a submitted
        // ride's does for its whole life.
        await coordinator.handleRideChange(makeRecord(id: "1E572C40-LOCAL-DRAFT", status: .accepted))
        await settle()
        presenter.emit(token: Data([0x8a, 0x1f]))
        await settle()

        XCTAssertEqual(
            endpoint.registrations.map(\.rideID),
            ["clride0000000000000001"],
            "the POST must name the SERVER's ride id — the local draft UUID is a 404"
        )
        XCTAssertFalse(
            endpoint.attempts.contains { $0.rideID == "1E572C40-LOCAL-DRAFT" },
            "the local draft UUID must never reach the wire at all"
        )
    }

    /// **AND THE TOKEN OUTLIVES THE WAIT.** MYR-398 v3 starts the Activity at
    /// REQUEST, which is before the create POST has even fired, so ActivityKit's
    /// token routinely arrives while there is no server id yet. Dropping it there
    /// would be the same zero-row outcome by a kinder-looking route:
    /// `pushTokenUpdates` yields once per Activity in the ordinary case, so a token
    /// let go is a token that never comes back.
    func testATokenArrivingBeforeTheServerIDIsHeldAndRegisteredWhenItLands() async throws {
        var serverID: String?
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { serverID })

        await coordinator.handleRideChange(makeRecord(id: "LOCAL", status: .pending))
        await settle()
        presenter.emit(token: Data([0xab, 0xcd]))
        await settle()

        XCTAssertTrue(endpoint.attempts.isEmpty, "nothing may be posted under an id the server has never issued")

        // The create is acknowledged: `riderServerRideID` lands, and RootView's
        // observer pokes the coordinator.
        serverID = "clride-server-9"
        await coordinator.handleServerRideIDChange()
        await settle()

        XCTAssertEqual(endpoint.registrations.map(\.rideID), ["clride-server-9"])
        XCTAssertEqual(endpoint.registrations.first?.token, "abcd")
    }

    /// **A FAILED POST IS RETRIED, NOT DROPPED** — MYR-186's policy, which is the
    /// other half of why `go_push_devices` recovers from a bad minute and this table
    /// did not. The old `catch { return }` reasoned that "the next rotation tries
    /// again", but ActivityKit does not rotate on a schedule, so for most rides
    /// there is no next rotation and one failure cost the whole ride.
    func testAFailedRegistrationIsRetriedOnTheNextTickRatherThanDropped() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "srv-1" })
        endpoint.registrationResult = .failure(RestError.http(status: 500, code: nil, message: nil, subCode: nil))

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        presenter.emit(token: Data([0x01]))
        await settle()

        XCTAssertEqual(endpoint.attempts.count, 1)
        XCTAssertTrue(endpoint.registrations.isEmpty, "the 500 did not register anything")

        // The next tick — a status change, a launch, or a foreground — retries the
        // SAME held token without needing ActivityKit to reissue it.
        endpoint.registrationResult = .success(LiveActivityRegistrationResponse(registered: true, sandbox: true))
        await coordinator.handleRideChange(makeRecord(status: .enroute))
        await settle()

        XCTAssertEqual(endpoint.registrations.map(\.rideID), ["srv-1"], "the held token is placed on the retry")
    }

    /// A confirmed registration is not re-posted on every tick — the retry must not
    /// become a poll.
    func testASuccessfulRegistrationIsNotRepostedOnEveryTick() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "srv-1" })

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        await settle()
        presenter.emit(token: Data([0x01]))
        await settle()
        await coordinator.handleRideChange(makeRecord(status: .enroute))
        await coordinator.handleServerRideIDChange()
        await settle()

        XCTAssertEqual(endpoint.attempts.count, 1, "one placed registration, one POST")
    }

    /// **ADOPTION RE-REGISTERS, AND IT DOES SO UNDER THE SERVER ID.** MYR-405 clears
    /// `registered` on adopt precisely so the adopted card's own token reaches the
    /// server — the issue asked for this path to be verified rather than assumed,
    /// because a re-register that never fires leaves the server pushing to whichever
    /// card this account registered last.
    func testAdoptingARestoredActivityReRegistersItsOwnTokenUnderTheServerID() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "srv-adopted" })
        presenter.restored = [snapshot("ride-1")]

        await coordinator.handleLaunchOrForeground {
            RideActivityAccountRide(record: self.makeRecord(status: .enroute), isResolved: true)
        }
        await settle()
        XCTAssertEqual(presenter.adopted, ["ride-1"], "precondition: the restored card was adopted")

        presenter.emit(token: Data([0xfe, 0xed]))
        await settle()

        XCTAssertEqual(
            endpoint.registrations.map(\.rideID),
            ["srv-adopted"],
            "the ADOPTED Activity's token must reach the server, under the server's id"
        )
        XCTAssertEqual(endpoint.registrations.first?.token, "feed")
    }

    /// The §7.21 DELETE has to name the id the POST named, or it releases nothing.
    ///
    /// Driven off `declined` since MYR-425 — a completed ride no longer produces a
    /// client-side end at all, which is that issue's whole point. The BACKSTOP's
    /// release is asserted separately, and names the same id by the same code path.
    func testEndingReleasesTheRegistrationUnderTheServerRideID() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "srv-7" })

        await coordinator.handleRideChange(makeRecord(id: "LOCAL", status: .accepted))
        await settle()
        presenter.emit(token: Data([0x01]))
        await settle()
        await coordinator.handleRideChange(makeRecord(id: "LOCAL", status: .declined))
        await settle()

        XCTAssertEqual(endpoint.ends, ["srv-7"], "the release names what the registration named")
    }

    func testTheBackstopsReleaseAlsoNamesTheServerRideID() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "srv-7" })

        await coordinator.handleRideChange(makeRecord(id: "LOCAL", status: .accepted))
        await settle()
        presenter.emit(token: Data([0x01]))
        await settle()

        var completed = makeRecord(id: "LOCAL", status: .completed)
        completed.completedAt = Date().addingTimeInterval(-RideActivityCompletedEnd.backstop - 1)
        await coordinator.handleRideChange(completed)
        await settle()

        XCTAssertEqual(endpoint.ends, ["srv-7"])
    }

    /// **THE SUMMARY'S DONE BUTTON MUST NOT EAT THE ARRIVAL CARD** (MYR-425).
    ///
    /// Dismissing the post-ride summary releases the rider's slot, so the account
    /// resolves to `.none` and MYR-405's reaper sees the completed card as an orphan.
    /// It is not one — it is this process's own card, mid-linger, with the server's
    /// announcement still to come. Reaping it would take it down `.immediate` AND
    /// issue the §7.21 DELETE: this issue's defect, from inside its own fix.
    func testReleasingTheRiderSlotDoesNotREAPTheLingeringCompletedCard() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        var completed = makeRecord(status: .completed)
        completed.completedAt = Date().addingTimeInterval(-30)
        await coordinator.handleRideChange(completed)
        await settle()

        // The rider taps Done: `activeRequest` goes nil, and the app foregrounds.
        await coordinator.handleRideChange(nil)
        await coordinator.handleLaunchOrForeground(account(nil))
        await settle()

        XCTAssertNil(presenter.endedWith, "no local end while the server's held end is still due")
        XCTAssertTrue(presenter.endedActivities.isEmpty, "and the reaper leaves it alone")
        XCTAssertTrue(endpoint.ends.isEmpty)
        XCTAssertEqual(coordinator.phase.rideID, "ride-1")
    }

    func testOnceTheBackstopHasPassedTheOrphanedCompletedCardDoesComeDown() async throws {
        // The other side of the same guard: the exemption is bounded by the deadline,
        // so a completed card whose server end never arrived does not become
        // permanently un-reapable.
        let (coordinator, presenter, endpoint) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0xaa]))
        await settle()

        var completed = makeRecord(status: .completed)
        completed.completedAt = Date().addingTimeInterval(-RideActivityCompletedEnd.backstop - 1)
        await coordinator.handleRideChange(completed)
        await settle()

        XCTAssertEqual(presenter.endedWith?.state.status, .completed)
        XCTAssertEqual(presenter.endedWith?.dismissal, .immediate)
        XCTAssertEqual(endpoint.ends, ["ride-1"])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// Reaping somebody else's leftover card must not delete the row belonging to
    /// the ride this process is driving — the `isDuplicateOfAdopted` starvation
    /// reached through a different door.
    func testReapingAnOrphanDoesNotReleaseTheHeldRidesRegistration() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "srv-live" })
        presenter.restored = [snapshot("ride-1"), snapshot("some-other-ride")]

        await coordinator.handleLaunchOrForeground {
            RideActivityAccountRide(record: self.makeRecord(status: .enroute), isResolved: true)
        }
        await settle()
        presenter.emit(token: Data([0x01]))
        await settle()

        XCTAssertEqual(
            presenter.endedActivities.map(\.rideID),
            ["some-other-ride"],
            "precondition: the orphan was reaped"
        )
        XCTAssertFalse(
            endpoint.ends.contains("srv-live"),
            "reaping an orphan must never release the live ride's own registration"
        )
        XCTAssertEqual(endpoint.registrations.map(\.rideID), ["srv-live"])
    }

    // MARK: - MYR-416: adopt-on-relaunch across the two-id split

    /// **THE DEFECT, END TO END.** A ride this device SUBMITTED puts the LOCAL draft
    /// UUID into the Activity's immutable attributes (MYR-398 v3 requests the card at
    /// REQUEST, before the create POST has fired, so there is no server id to stamp).
    /// A relaunch rebuilds the record from the wire, so the account's live ride is
    /// named by the SERVER's id — and MYR-405's adoption compared the two with `==`.
    ///
    /// Pre-fix, this test's card is REAPED and a second one started in its place:
    /// MYR-405's own duplicate-banner symptom, produced by MYR-405's own fix.
    func testARELAUNCHIntoARiderSubmittedRideADOPTSTheCardItAlreadyHas() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, presenter, endpoint) = makeCoordinator(
            serverRideID: { "clride-server-1" },
            identities: ledger
        )
        // What the PREVIOUS process left on the lock screen.
        presenter.restored = [snapshot("1E572C40-LOCAL")]

        await coordinator.handleLaunchOrForeground(
            account(makeRecord(id: "clride-server-1", status: .enroute))
        )
        await settle()

        XCTAssertEqual(presenter.adopted, ["1E572C40-LOCAL"], "the card keeps the id it was STAMPED with")
        XCTAssertEqual(presenter.startCount, 0, "a second card is the whole defect")
        XCTAssertTrue(presenter.endedActivities.isEmpty, "and the rider's own banner is not reaped on the way")
        XCTAssertTrue(endpoint.ends.isEmpty, "nor is its §7.21 registration released")
        XCTAssertEqual(coordinator.phase.rideID, "1E572C40-LOCAL")

        // ADOPTION RE-REGISTERS — under the SERVER's id, which is MYR-415's rule and
        // is what makes the kept banner live again.
        presenter.emit(token: Data([0xfe, 0xed]))
        await settle()
        XCTAssertEqual(endpoint.registrations.map(\.rideID), ["clride-server-1"])
    }

    /// **THE OTHER DOOR TO THE SAME DUPLICATE.** Adoption is only half of a relaunch:
    /// `handleLaunchOrForeground` finishes by re-asking the state machine, and that
    /// tick used to read "a different ride is open" and `.restart` the card it had
    /// just adopted.
    func testTheADOPTEDCardSurvivesTheTickThatFollowsTheAdoption() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, presenter, _) = makeCoordinator(
            serverRideID: { "clride-server-1" },
            identities: ledger
        )
        presenter.restored = [snapshot("1E572C40-LOCAL")]

        await coordinator.handleLaunchOrForeground(
            account(makeRecord(id: "clride-server-1", status: .enroute))
        )
        await settle()
        // A status change arriving over the socket, on the SERVER's id.
        await coordinator.handleRideChange(makeRecord(id: "clride-server-1", status: .enroute))
        await settle()

        XCTAssertNil(presenter.endedWith)
        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertEqual(coordinator.phase.rideID, "1E572C40-LOCAL")
    }

    /// The START path reconciles too, and reaches the same question by a different
    /// road: on a relaunch `RootView`'s record observer can fire before the launch
    /// reconcile does, so `performStart` must adopt across the split as well or it
    /// requests the second card itself.
    func testTheSTARTPathAlsoAdoptsAcrossTheSplit() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, presenter, _) = makeCoordinator(
            serverRideID: { "clride-server-1" },
            identities: ledger
        )
        presenter.restored = [snapshot("1E572C40-LOCAL")]

        await coordinator.handleRideChange(makeRecord(id: "clride-server-1", status: .enroute))
        await settle()

        XCTAssertEqual(presenter.adopted, ["1E572C40-LOCAL"])
        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertTrue(presenter.endedActivities.isEmpty)
    }

    /// **THE WRITE HALF, WITHOUT WHICH THE TESTS ABOVE ARE A TAUTOLOGY.** The mapping
    /// is only knowable in the process that SUBMITTED the ride, and only once the
    /// create is acknowledged — which does not touch `activeRequest`, so
    /// `handleServerRideIDChange` is the one entry point that sees it.
    func testTheSUBMITTINGProcessIsWhatRecordsTheMapping() async throws {
        let ledger = InMemoryRideActivityRideIDs()
        var serverID: String?
        let (coordinator, _, _) = makeCoordinator(serverRideID: { serverID }, identities: ledger)

        await coordinator.handleRideChange(makeRecord(id: "1E572C40-LOCAL", status: .pending))
        await settle()
        XCTAssertEqual(
            ledger.identity(),
            .unmapped,
            "nothing to map yet — the create has not been acknowledged"
        )

        serverID = "clride-server-1"
        await coordinator.handleServerRideIDChange()
        await settle()

        XCTAssertTrue(
            ledger.identity().namesTheSameRide(
                activityRideID: "1E572C40-LOCAL",
                as: "clride-server-1"
            ),
            "the pair the NEXT process needs to recognise this card"
        )
    }

    /// A ride adopted from the wire has ONE id, so it maps nothing at all — the
    /// ledger stays empty for an account that only ever relaunches into rides the
    /// server told it about.
    func testARideWhoseIDsCoincideWritesNoMappingAtAll() async throws {
        let ledger = InMemoryRideActivityRideIDs()
        let (coordinator, presenter, _) = makeCoordinator(
            serverRideID: { "ride-1" },
            identities: ledger
        )

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.emit(token: Data([0x01]))
        await settle()

        XCTAssertEqual(ledger.identity(), .unmapped)
    }

    /// **ORPHAN REAPING IS UNCHANGED**, with a mapping held and a live ride on
    /// screen. This is the property a looser comparison would have quietly cost.
    func testAGenuinelyFOREIGNCardIsStillReapedOnARelaunch() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, presenter, endpoint) = makeCoordinator(
            serverRideID: { "clride-server-1" },
            identities: ledger
        )
        presenter.restored = [snapshot("1E572C40-LOCAL"), snapshot("somebody-elses-ride")]

        await coordinator.handleLaunchOrForeground(
            account(makeRecord(id: "clride-server-1", status: .enroute))
        )
        await settle()

        XCTAssertEqual(presenter.adopted, ["1E572C40-LOCAL"])
        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["somebody-elses-ride"])
        XCTAssertEqual(
            endpoint.ends,
            ["somebody-elses-ride"],
            """
            the orphan keeps its best-effort release under the ACTIVITY's own id \
            (MYR-415), and the held ride's registration is untouched
            """
        )
    }

    /// An account with NO live ride still has every card reaped, mapping or not.
    func testAMappedCardIsStillAnORPHANOnceTheAccountHoldsNoRide() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, presenter, _) = makeCoordinator(identities: ledger)
        presenter.restored = [snapshot("1E572C40-LOCAL")]

        await coordinator.handleLaunchOrForeground(account(nil))
        await settle()

        XCTAssertEqual(presenter.endedActivities.map(\.rideID), ["1E572C40-LOCAL"])
        XCTAssertTrue(presenter.adopted.isEmpty)
    }

    /// **AN OWNER-ACCEPTED (wire-adopted) RIDE RELAUNCHES EXACTLY AS IT DID.** Both
    /// ids are the server's, no mapping exists, and every assertion here is the
    /// pre-MYR-416 behaviour.
    func testARelaunchIntoAWireAdoptedRideIsUnchanged() async throws {
        let (coordinator, presenter, endpoint) = makeCoordinator(serverRideID: { "ride-1" })
        presenter.restored = [snapshot("ride-1")]

        await coordinator.handleLaunchOrForeground(account(makeRecord(status: .enroute)))
        await settle()

        XCTAssertEqual(presenter.adopted, ["ride-1"])
        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertTrue(presenter.endedActivities.isEmpty)
        XCTAssertTrue(endpoint.ends.isEmpty)
    }

    /// **THE RIDER'S SWIPE OUTLIVES THE PROCESS**, which before MYR-416 it could not:
    /// the dismissal is reported under the CARD's id and the relaunched record
    /// carries the server's, so the app handed back a card the rider had removed.
    func testADismissedRiderSubmittedCardIsNotRestartedAfterARelaunch() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, presenter, _) = makeCoordinator(
            serverRideID: { "clride-server-1" },
            identities: ledger
        )
        presenter.restored = [snapshot("1E572C40-LOCAL", .dismissed)]

        await coordinator.handleLaunchOrForeground(
            account(makeRecord(id: "clride-server-1", status: .enroute))
        )
        await settle()

        XCTAssertEqual(presenter.startCount, 0, "the rider swiped this ride away")
        XCTAssertTrue(presenter.adopted.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// The mapping is a statement about THIS ACCOUNT's rides, so it goes out with the
    /// session — alongside the profile, the view mode and the owner's dispatch
    /// pointer.
    func testSigningOutFORGETSTheMapping() async throws {
        let ledger = InMemoryRideActivityRideIDs(["1E572C40-LOCAL": "clride-server-1"])
        let (coordinator, _, _) = makeCoordinator(
            serverRideID: { "clride-server-1" },
            identities: ledger
        )

        await coordinator.handleSignOut()
        await settle()

        XCTAssertEqual(ledger.identity(), .unmapped)
    }

    // MARK: - Harness

    /// MYR-415 — the default answers `"ride-1"`, i.e. the same id `makeRecord`
    /// mints, so every pre-existing test keeps asserting exactly what it did. That
    /// is not a fudge: a ride ADOPTED from the wire on cold launch genuinely has one
    /// id, because its record was built by `RideRequestContractMapping.record(from:)`
    /// off the server's own row. The case where the two DIVERGE is a ride this
    /// device SUBMITTED, and it gets its own tests below.
    ///
    /// MYR-416 — the `local ↔ server` ledger is IN MEMORY here, always. A store on
    /// `UserDefaults.standard` would carry one test's mapping into the next, and a
    /// mapping is exactly the input that decides whether a card is adopted or reaped.
    private func makeCoordinator(
        sandbox: Bool = true,
        vehicle: @escaping @MainActor () -> RideActivityVehicle? = { nil },
        serverRideID: @escaping @MainActor () -> String? = { "ride-1" },
        identities: RideActivityRideIDStoring = InMemoryRideActivityRideIDs()
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
            serverRideID: serverRideID,
            identities: identities,
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

    // MARK: - MYR-423: the content state ActivityKit actually holds

    /// What the CARD says, per ride — the stub's stand-in for
    /// `Activity.content.state`.
    ///
    /// It is written by `start` and `update` exactly as the system writes it, and by
    /// `deliver(push:)` for the half of the truth this process never sees. **That
    /// second writer is what makes these tests proof rather than tautology**: a stub
    /// that only echoed our own updates back could never distinguish "the coordinator
    /// held the server's value" from "the coordinator re-wrote its own", because on
    /// such a stub those two are the same bytes.
    private(set) var deliveredStates: [String: RideActivityAttributes.ContentState] = [:]

    func deliveredContentState(rideID: String) -> RideActivityAttributes.ContentState? {
        deliveredStates[rideID]
    }

    /// Stand in for APNs replacing the Activity's content state — the one event that
    /// happens entirely outside this process.
    func deliver(push state: RideActivityAttributes.ContentState, rideID: String) {
        deliveredStates[rideID] = state
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
        if !keepOne { deliveredStates[rideID] = nil }
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
        deliveredStates[attributes.rideID] = state
        restored.append(RideActivitySnapshot(rideID: attributes.rideID, lifecycle: .active))
        return true
    }

    /// MYR-425 — the stale date each update carried. A completed frame must carry
    /// NONE, and nothing else in the stub could tell the difference.
    private(set) var updateStaleDates: [Date?] = []

    func update(state: RideActivityAttributes.ContentState, staleDate: Date?) async {
        updates.append(state)
        updateStaleDates.append(staleDate)
        if let heldRideID { deliveredStates[heldRideID] = state }
    }

    /// **Stand in for the SERVER'S HELD END** (MYR-421 / MYR-425) — the one exit this
    /// process does not perform. APNs ends the Activity outright, so the card leaves
    /// the screen and the system reports `.ended`; the app learns about it from the
    /// lifecycle stream and from the restore list, and from nowhere else.
    func deliverServerEnd() {
        guard let heldRideID else { return }
        restored = restored.map {
            $0.rideID == heldRideID
                ? RideActivitySnapshot(rideID: $0.rideID, lifecycle: .ended)
                : $0
        }
        isPresenting = false
        lifecycleContinuation?.yield(.ended)
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
            if let heldRideID { deliveredStates[heldRideID] = nil }
        case .linger:
            if let heldRideID { deliveredStates[heldRideID] = state }
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
