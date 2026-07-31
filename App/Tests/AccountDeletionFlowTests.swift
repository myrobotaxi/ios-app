import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import SwiftUI
import XCTest

// MARK: - MYR-355 / MYR-366 — deleting your account, and the visual offboarding
//
// Everything asserted here is about the WIRE and the ORDER: how many times the
// endpoint is called on each path, that a FAILED delete leaves the user signed in
// and able to try again, and — MYR-366's whole subject — that the STEPPER never
// tells a story the server has not backed.
//
// `DELETE /api/users/me` is re-runnable by contract, so the retry is the
// recovery; a client that signed someone out on failure would strand them outside
// the only surface that can finish the job.

/// A scripted `AccountDeletionEndpoint` that counts calls and can be told to fail
/// a given number of times before succeeding — which is how the mid-failure retry
/// case is expressed.
private actor CountingDeletionEndpoint: AccountDeletionEndpoint {
    private var remainingFailures: Int
    private var calls = 0

    init(failuresBeforeSuccess: Int = 0) {
        self.remainingFailures = failuresBeforeSuccess
    }

    func deleteAccount() async throws {
        calls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw RestError.http(
                status: 500,
                code: ErrorPayload.Code(rawValue: "internal_error"),
                message: "boom",
                subCode: nil
            )
        }
    }

    func callCount() -> Int { calls }
}

/// An endpoint that is CALLED and never answers — the shape of a slow or wedged
/// backend, and the only way to observe the narration finishing first.
private actor NeverAnsweringDeletionEndpoint: AccountDeletionEndpoint {
    private var calls = 0

    func deleteAccount() async throws {
        calls += 1
        // Cancellation (the test tearing the task down) throws, which is the same
        // thing a dismissed screen does in production.
        try await Task.sleep(for: .seconds(3600))
    }

    func callCount() -> Int { calls }
}

@MainActor
final class AccountDeletionFlowTests: XCTestCase {

    /// A flow plus its endpoint and a counter for the local sign-out + wipe.
    /// Narration is paced by an injected no-op sleep, so the tests run at wire
    /// speed rather than in 3.2s increments.
    private func makeFlow(
        failuresBeforeSuccess: Int = 0
    ) -> (AccountDeletionFlow, CountingDeletionEndpoint, () -> Int) {
        let endpoint = CountingDeletionEndpoint(failuresBeforeSuccess: failuresBeforeSuccess)
        let signOuts = Counter()
        let flow = AccountDeletionFlow(endpoint: endpoint, onDeleted: { signOuts.bump() })
        flow.narrationSleep = { _ in }
        return (flow, endpoint, { signOuts.value })
    }

    /// A tiny main-actor counter, so the sign-out callback is observable without a
    /// view.
    @MainActor private final class Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: The happy path

    func testTheDialogLeadsToTheOffboardingScreenAndOnlyThatScreenDeletes() async {
        let (flow, endpoint, signOuts) = makeFlow()

        flow.begin(role: .owner)
        XCTAssertEqual(flow.step, .firstConfirm)
        var calls = await endpoint.callCount()
        XCTAssertEqual(calls, 0, "raising the dialog must not touch the network")

        flow.confirmFirstStep()
        XCTAssertEqual(flow.step, .offboarding, "the confirm's product is the offboarding screen")
        calls = await endpoint.callCount()
        XCTAssertEqual(
            calls, 0,
            "confirming must not delete anything by itself — the SCREEN starts the call when it appears"
        )
        XCTAssertEqual(
            flow.stepper.stepCount, OffboardingSequence.ownerSteps.count,
            "the stepper is sized to the role's sequence as the screen is raised"
        )

        await flow.runOffboarding()
        calls = await endpoint.callCount()
        XCTAssertEqual(calls, 1, "the delete goes out exactly once")
        XCTAssertTrue(flow.stepper.isComplete)
        XCTAssertEqual(
            signOuts(), 0,
            "MYR-366: the 204 does NOT wipe the session — the ending screen's Done does"
        )

        flow.finish()
        XCTAssertEqual(signOuts(), 1, "Done runs the local sign-out + wipe exactly once")
        XCTAssertEqual(flow.step, .none)
        XCTAssertFalse(flow.isDeleting)
    }

    func testTheRoleIsCarriedFromBeginIntoBothTheCopyAndTheSequence() {
        let (owner, _, _) = makeFlow()
        owner.begin(role: .owner)
        XCTAssertEqual(owner.role, .owner)
        XCTAssertEqual(owner.firstConfirmConfig.message, AccountDeletionDialog.ownerMessage)
        XCTAssertEqual(owner.offboardingSteps, OffboardingSequence.ownerSteps)

        let (rider, _, _) = makeFlow()
        rider.begin(role: .shared)
        XCTAssertEqual(rider.role, .shared)
        XCTAssertEqual(rider.firstConfirmConfig.message, AccountDeletionDialog.riderMessage)
        XCTAssertEqual(rider.offboardingSteps, OffboardingSequence.riderSteps)
    }

    // MARK: Cancelling — nothing happens at all

    func testCancellingTheDialogDeletesNothing() async {
        let (flow, endpoint, signOuts) = makeFlow()

        flow.begin(role: .owner)
        flow.cancel()

        XCTAssertEqual(flow.step, .none)
        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(signOuts(), 0, "a cancelled delete must not sign anyone out")
    }

    /// The dialog card runs `config.action()` and THEN `dismiss()`, so the dialog's
    /// own presentation binding is set false AFTER the flow has already moved to
    /// `.offboarding`. An unguarded setter would close the surface it just opened —
    /// this pins the guard.
    func testDismissingTheDialogAfterItsConfirmDoesNotCloseTheOffboardingScreen() {
        let (flow, _, _) = makeFlow()

        flow.begin(role: .owner)
        flow.firstConfirmConfig.action()      // the confirm button's action
        flow.isPresentingFirstConfirm = false // the card's own dismiss(), which follows

        XCTAssertEqual(flow.step, .offboarding, "the offboarding screen must survive the dialog's dismissal")
        XCTAssertTrue(flow.isPresentingOffboarding)
        XCTAssertFalse(flow.isPresentingFirstConfirm)
    }

    // MARK: Failure — stay signed in, say so, and let them retry

    func testAFailedDeleteLeavesTheUserSignedInAndNeverAllChecked() async {
        let (flow, endpoint, signOuts) = makeFlow(failuresBeforeSuccess: 1)

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        await flow.runOffboarding()

        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(signOuts(), 0, "a failed delete must NOT sign the user out — the account may still exist")
        XCTAssertTrue(flow.stepper.hasFailed)
        XCTAssertFalse(flow.stepper.isComplete, "an all-checked stepper over a failed delete is the one forbidden render")
        XCTAssertLessThan(
            flow.stepper.checkedCount, flow.stepper.stepCount,
            "the final step is server-gated and the server refused"
        )
        XCTAssertFalse(flow.isDeleting, "the in-flight flag is released on the failure path too")
        XCTAssertEqual(flow.step, .offboarding, "the failure treatment lives ON this screen")
    }

    /// THE MID-FAILURE RETRY, now in place on the offboarding screen. The endpoint
    /// is re-runnable, so the second attempt is a real second call — and the steps
    /// already narrated are RESUMED rather than replayed, because re-running
    /// finishes the job from where it got to.
    func testRetryingOnTheOffboardingScreenCallsTheEndpointAgainAndCanSucceed() async {
        let (flow, endpoint, signOuts) = makeFlow(failuresBeforeSuccess: 1)

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        await flow.runOffboarding()
        XCTAssertTrue(flow.stepper.hasFailed)
        let checkedBeforeRetry = flow.stepper.checkedCount

        await flow.retryOffboarding()

        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 2, "the retry is a real second DELETE")
        XCTAssertTrue(flow.stepper.isComplete, "and it finishes the job")
        XCTAssertGreaterThanOrEqual(
            flow.stepper.checkedCount, checkedBeforeRetry,
            "a retry resumes; it never un-checks a step"
        )
        XCTAssertEqual(signOuts(), 0, "still nothing until Done")
    }

    func testNotNowAfterAFailureReturnsToSettingsStillSignedIn() async {
        let (flow, _, signOuts) = makeFlow(failuresBeforeSuccess: 1)

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        await flow.runOffboarding()
        flow.dismissAfterFailure()

        XCTAssertEqual(flow.step, .none)
        XCTAssertEqual(signOuts(), 0, "backing out of a failure must never sign anyone out")
    }

    /// "Not now" is reachable ONLY from a failure. A user cannot walk away from a
    /// delete that is still in flight or that succeeded.
    func testDismissAfterFailureDoesNothingWhileTheDeleteHasNotFailed() {
        let (flow, _, _) = makeFlow()
        flow.begin(role: .owner)
        flow.confirmFirstStep()
        flow.dismissAfterFailure()
        XCTAssertEqual(flow.step, .offboarding)
    }

    // MARK: Re-entry

    func testRunningTheOffboardingTwiceDoesNotSendASecondDelete() async {
        let (flow, endpoint, _) = makeFlow()

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        async let first: Void = flow.runOffboarding()
        async let second: Void = flow.runOffboarding()
        _ = await (first, second)

        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 1, "a re-entrant `.task` must not send two deletes")
    }

    // MARK: The honesty gate, end to end

    /// NARRATION FINISHES FIRST. Against an endpoint that never answers, the
    /// stepper must walk every narrated step and then STOP one short of the end,
    /// with the last step in flight — never complete.
    func testWithNoAnswerTheStepperNarratesToTheGateAndHoldsThere() async {
        let endpoint = NeverAnsweringDeletionEndpoint()
        let signOuts = Counter()
        let flow = AccountDeletionFlow(endpoint: endpoint, onDeleted: { signOuts.bump() })
        flow.narrationSleep = { _ in }

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        let running = Task { await flow.runOffboarding() }

        // Let the narration run to its limit; it cannot go further by construction.
        for _ in 0..<200 where flow.stepper.checkedCount < flow.stepper.narrationLimit {
            await Task.yield()
        }

        XCTAssertEqual(
            flow.stepper.checkedCount, flow.stepper.narrationLimit,
            "narration checks every step it owns"
        )
        XCTAssertFalse(flow.stepper.isComplete, "and NOT the last one, which the 204 owns")
        XCTAssertEqual(
            flow.stepper.activeIndex, flow.stepper.stepCount - 1,
            "the last step is the one in flight — the spinner the client will see"
        )
        XCTAssertEqual(signOuts.value, 0)

        running.cancel()
        _ = await running.result
    }

    // MARK: The simulated path

    /// No seam at all is NOT the same as a seam that failed (the
    /// `RideSharePauseFlow.setEnabled` distinction). On the simulated path there is
    /// no server account: the local session IS the whole account, so the confirmed
    /// delete resolves to the local wipe — a complete execution of what was asked,
    /// not a pretend one, and NOT a failure.
    func testWithNoEndpointTheOffboardingCompletesAndDoneWipesLocally() async {
        let signOuts = Counter()
        let flow = AccountDeletionFlow(endpoint: nil, onDeleted: { signOuts.bump() })
        flow.narrationSleep = { _ in }

        flow.begin(role: .shared)
        flow.confirmFirstStep()
        await flow.runOffboarding()

        XCTAssertTrue(flow.stepper.isComplete)
        XCTAssertFalse(flow.stepper.hasFailed)
        flow.finish()
        XCTAssertEqual(signOuts.value, 1)
    }
}

// MARK: - MYR-366 — the stepper state machine
//
// The four orderings that decide whether this screen is honest, each as one
// assertion over a value with no view and no clock. They are here rather than in a
// UI test on purpose: a timing-dependent UI test for "did the 204 land before the
// narration finished" would be slow, flaky, and would prove less.

final class OffboardingStepperStateTests: XCTestCase {

    private func narrate(_ state: inout OffboardingStepperState, times: Int) {
        for _ in 0..<times { state.narrateOneStep() }
    }

    // MARK: The gate itself

    func testNarrationAloneCanNeverCheckTheLastStep() {
        var state = OffboardingStepperState(stepCount: OffboardingSequence.ownerSteps.count)
        narrate(&state, times: 50) // far past the end

        XCTAssertEqual(state.narrated, state.narrationLimit, "narration is capped one short of the end")
        XCTAssertEqual(state.checkedCount, state.stepCount - 1)
        XCTAssertFalse(state.isComplete, "the last check belongs to the 204 and to nothing else")
        XCTAssertEqual(state.activeIndex, state.stepCount - 1, "the last step spins while the answer is awaited")
    }

    func testTheLastStepChecksOnlyWhenBothTheServerAndTheNarrationAreDone() {
        var state = OffboardingStepperState(stepCount: 4)
        narrate(&state, times: 3)
        XCTAssertFalse(state.isComplete)

        state.recordSuccess()
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.checkedCount, 4)
        XCTAssertNil(state.activeIndex, "nothing is in flight once it is done")
    }

    // MARK: 204 BEFORE the narration finishes

    func testA204ThatArrivesEarlyDoesNotJumpTheFinalCheckForward() {
        var state = OffboardingStepperState(stepCount: 6)
        state.narrateOneStep() // one step in
        state.recordSuccess()  // the server is already done

        XCTAssertEqual(state.checkedCount, 1, "the 204 must not check five circles at once")
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(state.activeIndex, 1, "the narration is still walking")

        // …and the final check lands exactly when the narration catches up.
        narrate(&state, times: 3)
        XCTAssertEqual(state.checkedCount, 4)
        XCTAssertFalse(state.isComplete)
        state.narrateOneStep()
        XCTAssertTrue(state.isComplete, "the last one completes the set only now")
        XCTAssertEqual(state.checkedCount, 6)
    }

    // MARK: Failure at EVERY phase

    /// A failure stops the narration where it stood: the steps already checked stay
    /// checked, the failed phase is named, and NOTHING beyond it is claimed.
    func testAFailureAtAnyPhaseRendersHonestlyAndNeverAllChecked() {
        for stepCount in [OffboardingSequence.riderSteps.count, OffboardingSequence.ownerSteps.count] {
            for narratedBeforeFailure in 0...(stepCount - 1) {
                var state = OffboardingStepperState(stepCount: stepCount)
                narrate(&state, times: narratedBeforeFailure)
                state.recordFailure()

                XCTAssertTrue(state.hasFailed)
                XCTAssertFalse(
                    state.isComplete,
                    "failure at phase \(narratedBeforeFailure) of \(stepCount) rendered an all-checked stepper"
                )
                XCTAssertEqual(state.checkedCount, narratedBeforeFailure, "checks stop exactly where narration did")
                XCTAssertEqual(state.failedIndex, narratedBeforeFailure, "the failure is named at the phase it reached")
                XCTAssertNil(state.activeIndex, "nothing is in flight after a failure")
                XCTAssertFalse(state.canNarrate, "a failure STOPS the narration, rather than hiding its output")
            }
        }
    }

    func testNarrationAfterAFailureIsRefused() {
        var state = OffboardingStepperState(stepCount: 6)
        state.narrateOneStep()
        state.recordFailure()
        narrate(&state, times: 10)

        XCTAssertEqual(state.checkedCount, 1, "no step may check after the delete has failed")
    }

    /// A late `204` cannot overturn a recorded failure and vice versa — the ONE
    /// call answers once, and a client that let both land would render whichever
    /// arrived second.
    func testTheServerOutcomeIsRecordedOnceAndOnlyOnce() {
        var failedFirst = OffboardingStepperState(stepCount: 4)
        failedFirst.recordFailure()
        failedFirst.recordSuccess()
        XCTAssertTrue(failedFirst.hasFailed)

        var succeededFirst = OffboardingStepperState(stepCount: 4)
        succeededFirst.recordSuccess()
        succeededFirst.recordFailure()
        XCTAssertFalse(succeededFirst.hasFailed)
    }

    // MARK: Retry

    func testRetryResumesRatherThanReplays() {
        var state = OffboardingStepperState(stepCount: 6)
        narrate(&state, times: 2)
        state.recordFailure()
        XCTAssertEqual(state.checkedCount, 2)

        state.retry()
        XCTAssertFalse(state.hasFailed)
        XCTAssertEqual(state.checkedCount, 2, "the two steps already done are not un-done by a retry")
        XCTAssertTrue(state.canNarrate)
        XCTAssertEqual(state.activeIndex, 2, "and the narration picks up at the phase that failed")

        narrate(&state, times: 3)
        state.recordSuccess()
        XCTAssertTrue(state.isComplete)
    }

    func testRetryDoesNothingWhenNothingHasFailed() {
        var state = OffboardingStepperState(stepCount: 4)
        state.recordSuccess()
        state.retry()
        XCTAssertEqual(state.server, .succeeded)
    }
}

// MARK: - MYR-366 — the sequence, the motion, and the manual steps

final class OffboardingSequenceTests: XCTestCase {

    func testBothRolesEndOnTheSameServerGatedStep() {
        XCTAssertEqual(OffboardingSequence.ownerSteps.last, "Account deleted")
        XCTAssertEqual(OffboardingSequence.riderSteps.last, "Account deleted")
    }

    func testTheOwnerSequenceIsTheClientsSix() {
        XCTAssertEqual(OffboardingSequence.ownerSteps, [
            "Rides closed out",
            "Riders\u{2019} access revoked",
            "Tesla access revoked",
            "Vehicle removed from MyRoboTaxi",
            "Notifications cleared",
            "Account deleted",
        ])
    }

    func testTheRiderSequenceIsTheClientsFour() {
        XCTAssertEqual(OffboardingSequence.riderSteps, [
            "Ride requests cancelled",
            "Access to shared Teslas removed",
            "Notifications cleared",
            "Account deleted",
        ])
    }

    /// A rider owns no car and hosts no viewers, so neither of the owner's two
    /// third-party steps may appear in their sequence.
    func testTheRiderSequenceClaimsNothingAboutTeslaOrAVehicle() {
        for step in OffboardingSequence.riderSteps {
            XCTAssertFalse(step.contains("Vehicle removed"), "rider step \"\(step)\"")
            XCTAssertFalse(step.hasPrefix("Tesla access"), "rider step \"\(step)\"")
        }
    }

    func testTheStepsAreDerivedFromTheRoleAndNothingElse() {
        XCTAssertEqual(OffboardingSequence.steps(for: .owner), OffboardingSequence.ownerSteps)
        XCTAssertEqual(OffboardingSequence.steps(for: .shared), OffboardingSequence.riderSteps)
    }

    // MARK: Motion

    /// The client asked for "~0.4s per step, staggered", over "~3-4s total".
    func testOneStepsCheckBeatIsTheClientsFourTenthsOfASecond() {
        XCTAssertEqual(
            OffboardingMotion.outlineDrawDuration + OffboardingMotion.checkDrawDuration,
            OffboardingMotion.checkDuration,
            accuracy: 0.0001,
            "the outline-draw and the check-draw ARE the 0.4s beat; a third phase would overrun it"
        )
    }

    func testBothRolesNarrateInsideTheClientsThreeToFourSeconds() {
        for steps in [OffboardingSequence.ownerSteps, OffboardingSequence.riderSteps] {
            let interval = OffboardingMotion.stepInterval(stepCount: steps.count)
            let total = interval * Double(steps.count - 1)
            XCTAssertEqual(total, OffboardingMotion.narrationDuration, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(total, 3.0)
            XCTAssertLessThanOrEqual(total, 4.0)
            XCTAssertGreaterThanOrEqual(
                interval, OffboardingMotion.checkDuration,
                "a step must finish drawing before the next one starts, or the stagger is a pile-up"
            )
        }
    }

    // MARK: The two manual steps

    func testTheManualStepCaptionsAreTheClientsOwnPaths() {
        XCTAssertEqual(
            ManualOffboardingStep.virtualKey.caption,
            "Remove the MyRoboTaxi key: Car touchscreen \u{2192} Controls \u{2192} Locks \u{2192} tap the MyRoboTaxi key \u{2192} Remove"
        )
        XCTAssertEqual(
            ManualOffboardingStep.appAccess.caption,
            "Revoke app access: Tesla app \u{2192} Profile \u{2192} Third-Party Apps \u{2192} MyRoboTaxi \u{2192} Remove Access"
        )
    }

    /// The ceremony renders `title` + `path` as two elements and the compact
    /// version renders them as two lines; `caption` is the composition of exactly
    /// those two, so the two surfaces cannot drift.
    func testTheCaptionIsComposedFromTheSameTitleAndPathBothSurfacesRender() {
        for step in ManualOffboardingStep.both {
            XCTAssertEqual(step.caption, "\(step.title): \(step.path)")
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.path.isEmpty)
        }
    }

    /// The COMPACT version rides inside a confirm dialog, whose card is capped at
    /// `dialogMaxWidth` (300) less its own 20pt padding either side. Its longest
    /// line is a five-segment menu path, so it is MEASURED at that width rather
    /// than trusted to fit — the `VehicleControlTileCaptionTests` precedent, and
    /// the same class of defect (copy that only fits the device it was written on).
    @MainActor
    func testTheCompactStepsFitTheConfirmDialogsContentWidth() {
        let contentWidth = MRTMetrics.dialogMaxWidth - 40
        let host = UIHostingController(
            rootView: CompactManualOffboardingSteps()
                .frame(width: contentWidth)
        )
        host.view.backgroundColor = .black
        let size = host.sizeThatFits(in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))

        XCTAssertEqual(size.width, contentWidth, accuracy: 0.5, "the card must not overflow the dialog")
        XCTAssertGreaterThan(size.height, 60, "an empty card would mean the steps rendered nothing")
        // A confirm dialog holds a title, a body, this card and three buttons; a
        // block taller than this stops being an aside and starts being the screen.
        XCTAssertLessThan(size.height, 240, "the compact version is \(size.height)pt — that is the ceremony, not the aside")
    }

    func testThereAreExactlyTwoManualStepsAndBothAreTeslas() {
        XCTAssertEqual(ManualOffboardingStep.both.count, 2)
        XCTAssertTrue(ManualOffboardingStep.appAccess.path.contains("Tesla app"))
        XCTAssertTrue(ManualOffboardingStep.virtualKey.path.contains("Car touchscreen"))
    }
}

// MARK: - The locked copy

@MainActor
final class AccountDeletionCopyTests: XCTestCase {

    // MARK: The ONE dialog

    func testTheOwnerDialogSaysExactlyWhatDeletionCostsAnOwner() {
        let config = AccountDeletionDialog.first(role: .owner, onConfirm: {})
        XCTAssertEqual(config.title, "Delete your account?")
        XCTAssertEqual(
            config.message,
            "Removes your Tesla(s) from MyRoboTaxi and revokes everyone\u{2019}s access. This can\u{2019}t be undone \u{2014} you\u{2019}ll be signed out. Ride history you were part of stays with the other party."
        )
        XCTAssertEqual(config.actionLabel, "Delete permanently")
        XCTAssertEqual(config.dismissLabel, "Keep my account")
        XCTAssertEqual(config.kind, .destructive)
        XCTAssertNil(config.secondaryLabel, "this is the app's ordinary two-action confirm, not MYR-360's three-action one")
    }

    func testTheRiderDialogSaysExactlyWhatDeletionCostsARider() {
        let config = AccountDeletionDialog.first(role: .shared, onConfirm: {})
        XCTAssertEqual(config.title, "Delete your account?")
        XCTAssertEqual(
            config.message,
            "Removes your access to every Tesla shared with you and cancels any rides you\u{2019}ve requested. This can\u{2019}t be undone \u{2014} you\u{2019}ll be signed out. Ride history you were part of stays with the other party."
        )
        XCTAssertEqual(config.actionLabel, "Delete permanently")
        XCTAssertEqual(config.dismissLabel, "Keep my account")
        XCTAssertEqual(config.kind, .destructive)
    }

    /// The two roles share a title and a pair of buttons, and differ in exactly one
    /// place — the sentence naming what goes.
    func testTheTwoRolesDifferOnlyInTheConsequenceSentence() {
        let owner = AccountDeletionDialog.first(role: .owner, onConfirm: {})
        let rider = AccountDeletionDialog.first(role: .shared, onConfirm: {})
        XCTAssertEqual(owner.title, rider.title)
        XCTAssertEqual(owner.actionLabel, rider.actionLabel)
        XCTAssertEqual(owner.dismissLabel, rider.dismissLabel)
        XCTAssertNotEqual(owner.message, rider.message)
        XCTAssertTrue(owner.message.contains("Tesla(s) from MyRoboTaxi"))
        XCTAssertTrue(rider.message.contains("shared with you"))
        let tail = "Ride history you were part of stays with the other party."
        XCTAssertTrue(owner.message.hasSuffix(tail))
        XCTAssertTrue(rider.message.hasSuffix(tail))
    }

    /// MYR-366 — the ONE dialog absorbed the second's permanence sentence, and both
    /// role messages carry it VERBATIM and once. This is what stops the merge
    /// re-growing two ways of saying the same thing.
    func testBothRoleMessagesCarryTheOnePermanenceSentenceExactlyOnce() {
        for message in [AccountDeletionDialog.ownerMessage, AccountDeletionDialog.riderMessage] {
            XCTAssertTrue(message.contains(AccountDeletionDialog.permanenceSentence))
            XCTAssertEqual(
                message.components(separatedBy: AccountDeletionDialog.permanenceSentence).count - 1, 1,
                "\"\(message)\" states permanence more than once"
            )
        }
        XCTAssertEqual(
            AccountDeletionDialog.ownerMessage,
            "\(AccountDeletionDialog.ownerConsequences) \(AccountDeletionDialog.permanenceSentence) \(AccountDeletionDialog.historyClause)"
        )
        XCTAssertEqual(
            AccountDeletionDialog.riderMessage,
            "\(AccountDeletionDialog.riderConsequences) \(AccountDeletionDialog.permanenceSentence) \(AccountDeletionDialog.historyClause)"
        )
    }

    /// The REDUNDANCY MYR-366 removed. MYR-355's role sentences ended "…and deletes
    /// your account" one tap above a dialog whose body was "Your account and its
    /// data will be permanently deleted" — the same fact, twice, in two voices.
    func testTheRoleSentencesNoLongerRestateThatTheAccountIsDeleted() {
        for consequences in [AccountDeletionDialog.ownerConsequences, AccountDeletionDialog.riderConsequences] {
            XCTAssertFalse(
                consequences.lowercased().contains("deletes your account"),
                "\"\(consequences)\" repeats what the permanence sentence says"
            )
        }
    }

    /// **NO IDENTITY IN THE DIALOG.** The client's report opened with the account's
    /// email being shown again; a dialog that named the account would put it back on
    /// the one surface where the reader has already been told, twice, whose account
    /// this is.
    func testNeitherDialogNamesTheAccount() {
        for message in [AccountDeletionDialog.ownerMessage, AccountDeletionDialog.riderMessage] {
            XCTAssertFalse(message.contains("@"), "\"\(message)\" carries an address")
        }
        XCTAssertFalse(AccountDeletionDialog.title.contains("@"))
    }

    /// Deliberately NOT a type-to-confirm: Guideline 5.1.1(v) wants deletion
    /// discoverable and confirmable, and a text field adds friction without adding a
    /// decision. One dialog, and it offers a way out.
    func testTheDialogOffersAWayOutThatNamesWhatStaysTrue() {
        let dismiss = AccountDeletionDialog.first(role: .owner, onConfirm: {}).dismissLabel
        XCTAssertFalse(dismiss.isEmpty)
        // "Keep my account" names what stays true — the app's established grammar
        // ("Keep access" / "Keep invite" / "Keep linked" / "Keep sharing").
        XCTAssertTrue(dismiss.hasPrefix("Keep"))
    }

    // MARK: The failure notice, reused by the offboarding screen

    func testTheFailureNoticeSaysNothingWasLostAndInvitesARetry() {
        XCTAssertEqual(
            AccountDeletionDialog.failureNotice,
            "Couldn\u{2019}t delete your account. Nothing was lost \u{2014} try again."
        )
    }

    /// The two slots are the ONE locked string, split on its sentence boundary and
    /// nowhere else — so the halves can never drift from it, and the offboarding
    /// screen's failure treatment reads them rather than restating them.
    func testTheFailureTreatmentsTwoSlotsReassembleTheLockedNoticeExactly() {
        XCTAssertEqual(
            AccountDeletionDialog.failureNoticeTitle + " " + AccountDeletionDialog.failureNoticeBody,
            AccountDeletionDialog.failureNotice
        )
        XCTAssertEqual(OffboardingCopy.failureTitle, AccountDeletionDialog.failureNoticeTitle)
        XCTAssertEqual(OffboardingCopy.failureBody, AccountDeletionDialog.failureNoticeBody)
    }

    /// Typographic apostrophes and an em dash, like every other string in this app
    /// — a straight quote in a dialog next to "Couldn't revoke access" reads as a
    /// different app.
    func testTheCopyUsesTheAppsTypographicPunctuation() {
        let strings = [
            AccountDeletionDialog.ownerMessage,
            AccountDeletionDialog.riderMessage,
            AccountDeletionDialog.permanenceSentence,
            AccountDeletionDialog.failureNotice,
            OffboardingSequence.subtitle,
            OffboardingCopy.ownerEndingSubtitle,
            OffboardingCopy.riderEndingSubtitle,
        ] + OffboardingSequence.ownerSteps + OffboardingSequence.riderSteps
        for text in strings {
            XCTAssertFalse(text.contains("'"), "\"\(text)\" carries a straight apostrophe")
        }
    }

    // MARK: The endings

    /// The owner's ending says the account IS gone BEFORE it asks for two more
    /// things — otherwise the two steps read as conditions on a deletion that has
    /// already happened.
    func testTheOwnerEndingStatesTheDeletionBeforeAskingForAnythingElse() {
        XCTAssertEqual(OffboardingCopy.ownerEndingTitle, "Two steps only you can do")
        XCTAssertTrue(OffboardingCopy.ownerEndingSubtitle.hasPrefix("Your account is deleted."))
    }

    func testTheRiderEndingIsTheClientsTwoSentences() {
        XCTAssertEqual(OffboardingCopy.riderEndingTitle, "Your account is deleted.")
        XCTAssertEqual(OffboardingCopy.riderEndingSubtitle, "Nothing remains.")
    }

    func testBothEndingsLeaveByTheSameOneButton() {
        XCTAssertEqual(OffboardingCopy.doneLabel, "Done")
    }
}

// MARK: - The Account section, on both screens
//
// PRESENCE and TAP TARGET are asserted where they are actually true — on the
// running app, in `App/UITests/AccountDeletionUITests.swift`. A `UIHostingController`
// in a unit test publishes NO accessibility tree for a SwiftUI hierarchy (measured:
// the walk returns zero elements, so every `contains` assertion over it would pass
// or fail for reasons unrelated to the screen), and the MYR-345 lesson is that a
// tap target has to be measured on the frame the SYSTEM reports.
//
// What is left here is what a unit test genuinely owns: the section's copy, and
// the token the row is built on.

@MainActor
final class AccountSectionCopyTests: XCTestCase {

    func testTheSectionAndRowAreNamedPlainly() {
        XCTAssertEqual(AccountDeletionDialog.sectionTitle, "Account")
        XCTAssertEqual(AccountDeletionDialog.deleteRowLabel, "Delete account")
    }

    /// MYR-366 — the ROW opens a question and the dialog's BUTTON answers it, so
    /// they no longer say the same words. MYR-355 made them identical deliberately
    /// (two dialogs, one action read twice); with one dialog the button is the point
    /// of no return and has to say so.
    func testTheRowAndTheConfirmButtonNoLongerSayTheSameThing() {
        XCTAssertNotEqual(AccountDeletionDialog.deleteRowLabel, AccountDeletionDialog.actionLabel)
        XCTAssertEqual(AccountDeletionDialog.actionLabel, "Delete permanently")
    }

    /// The 44pt hard rule (CLAUDE.md), and MYR-345's lesson that a `contentShape`
    /// inset is not a tap target. Both delete rows are built on this token; the
    /// DELIVERED height is measured in the UI test.
    func testTheMinimumTapTargetTokenTheDeleteRowsUseMeetsTheHardRule() {
        XCTAssertGreaterThanOrEqual(MRTMetrics.minTapTarget, 44)
    }
}
