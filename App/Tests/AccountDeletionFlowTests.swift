import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import SwiftUI
import XCTest

// MARK: - MYR-355 — deleting your account (App Store Guideline 5.1.1(v))
//
// Everything asserted here is about the WIRE and the ORDER: how many times the
// endpoint is called on each path through the two dialogs, and — the one that
// matters most — that a FAILED delete leaves the user signed in, with a notice,
// able to try again. `DELETE /api/users/me` is re-runnable by contract, so the
// retry is the recovery; a client that signed someone out on failure would strand
// them outside the only surface that can finish the job.

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

@MainActor
final class AccountDeletionFlowTests: XCTestCase {

    /// A flow plus its endpoint and a counter for the local sign-out + wipe.
    private func makeFlow(
        failuresBeforeSuccess: Int = 0
    ) -> (AccountDeletionFlow, CountingDeletionEndpoint, () -> Int) {
        let endpoint = CountingDeletionEndpoint(failuresBeforeSuccess: failuresBeforeSuccess)
        let signOuts = Counter()
        let flow = AccountDeletionFlow(endpoint: endpoint, onDeleted: { signOuts.bump() })
        return (flow, endpoint, { signOuts.value })
    }

    /// A tiny main-actor counter, so the sign-out callback is observable without a
    /// view.
    @MainActor private final class Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: The happy path

    func testTheFirstDialogLeadsToTheSecondAndOnlyTheSecondDeletes() async {
        let (flow, endpoint, signOuts) = makeFlow()

        flow.begin(role: .owner)
        XCTAssertEqual(flow.step, .firstConfirm)
        var calls = await endpoint.callCount()
        XCTAssertEqual(calls, 0, "raising the first dialog must not touch the network")

        flow.confirmFirstStep()
        XCTAssertEqual(flow.step, .secondConfirm, "the first confirm's whole product is the next question")
        calls = await endpoint.callCount()
        XCTAssertEqual(calls, 0, "the FIRST confirm must not delete anything")

        await flow.confirmDeletion()
        calls = await endpoint.callCount()
        XCTAssertEqual(calls, 1, "the delete goes out exactly once")
        XCTAssertEqual(signOuts(), 1, "success runs the local sign-out + wipe exactly once")
        XCTAssertEqual(flow.step, .none)
        XCTAssertNil(flow.errorNotice)
        XCTAssertFalse(flow.isDeleting)
    }

    func testTheRoleIsCarriedFromBeginIntoTheDialogCopy() {
        let (owner, _, _) = makeFlow()
        owner.begin(role: .owner)
        XCTAssertEqual(owner.role, .owner)
        XCTAssertEqual(owner.firstConfirmConfig.message, AccountDeletionDialog.ownerMessage)

        let (rider, _, _) = makeFlow()
        rider.begin(role: .shared)
        XCTAssertEqual(rider.role, .shared)
        XCTAssertEqual(rider.firstConfirmConfig.message, AccountDeletionDialog.riderMessage)
    }

    // MARK: Cancelling — at EITHER step, nothing happens at all

    func testCancellingAtTheFirstStepDeletesNothing() async {
        let (flow, endpoint, signOuts) = makeFlow()

        flow.begin(role: .owner)
        flow.cancel()

        XCTAssertEqual(flow.step, .none)
        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(signOuts(), 0, "a cancelled delete must not sign anyone out")
        XCTAssertNil(flow.errorNotice, "nothing was attempted, so there is nothing to report")
    }

    func testCancellingAtTheSecondStepDeletesNothing() async {
        let (flow, endpoint, signOuts) = makeFlow()

        flow.begin(role: .shared)
        flow.confirmFirstStep()
        XCTAssertEqual(flow.step, .secondConfirm)
        flow.cancel()

        XCTAssertEqual(flow.step, .none)
        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 0, "\"Keep my account\" is a way OUT, not a slower way in")
        XCTAssertEqual(signOuts(), 0)
    }

    /// The dialog card runs `config.action()` and THEN `dismiss()`, so the first
    /// dialog's own presentation binding is set false AFTER the flow has already
    /// moved to the second step. An unguarded setter would close the dialog it
    /// just opened — this pins the guard.
    func testDismissingTheFirstDialogAfterItsConfirmDoesNotCloseTheSecond() {
        let (flow, _, _) = makeFlow()

        flow.begin(role: .owner)
        flow.firstConfirmConfig.action()      // the confirm button's action
        flow.isPresentingFirstConfirm = false // the card's own dismiss(), which follows

        XCTAssertEqual(flow.step, .secondConfirm, "the second dialog must survive the first's dismissal")
        XCTAssertTrue(flow.isPresentingSecondConfirm)
        XCTAssertFalse(flow.isPresentingFirstConfirm)
    }

    // MARK: Failure — stay signed in, say so, and let them retry

    func testAFailedDeleteLeavesTheUserSignedInWithANotice() async {
        let (flow, endpoint, signOuts) = makeFlow(failuresBeforeSuccess: 1)

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        await flow.confirmDeletion()

        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(signOuts(), 0, "a failed delete must NOT sign the user out — the account may still exist")
        XCTAssertEqual(flow.errorNotice, AccountDeletionDialog.failureNotice)
        XCTAssertFalse(flow.isDeleting, "the in-flight flag is released on the failure path too")
        XCTAssertEqual(flow.step, .none, "no dialog is left hanging behind the notice")
    }

    /// THE MID-FAILURE RETRY. The endpoint is re-runnable, so the second attempt is
    /// a real second call — nothing in the client latches after a failure.
    func testARetryAfterAFailureCallsTheEndpointAgainAndCanSucceed() async {
        let (flow, endpoint, signOuts) = makeFlow(failuresBeforeSuccess: 1)

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        await flow.confirmDeletion()
        XCTAssertEqual(flow.errorNotice, AccountDeletionDialog.failureNotice)

        // The user taps "Delete account" again — the row is still there, because
        // they are still signed in.
        flow.begin(role: .owner)
        XCTAssertNil(flow.errorNotice, "beginning again clears the stale notice — it was about the last attempt")
        flow.confirmFirstStep()
        await flow.confirmDeletion()

        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 2, "the retry is a real second DELETE")
        XCTAssertEqual(signOuts(), 1, "and it finishes the job")
        XCTAssertNil(flow.errorNotice)
    }

    // MARK: Re-entry

    func testASecondConfirmWhileADeleteIsInFlightDoesNotSendASecondDelete() async {
        let (flow, endpoint, signOuts) = makeFlow()

        flow.begin(role: .owner)
        flow.confirmFirstStep()
        async let first: Void = flow.confirmDeletion()
        async let second: Void = flow.confirmDeletion()
        _ = await (first, second)

        let calls = await endpoint.callCount()
        XCTAssertEqual(calls, 1, "a double-tap must not send two deletes")
        XCTAssertEqual(signOuts(), 1)
    }

    // MARK: The simulated path

    /// No seam at all is NOT the same as a seam that failed (the
    /// `RideSharePauseFlow.setEnabled` distinction). On the simulated path there is
    /// no server account: the local session IS the whole account, so the confirmed
    /// delete resolves to the local wipe — a complete execution of what was asked,
    /// not a pretend one, and NOT a failure notice.
    func testWithNoEndpointTheConfirmedDeleteStillWipesLocallyAndRaisesNoNotice() async {
        let signOuts = Counter()
        let flow = AccountDeletionFlow(endpoint: nil, onDeleted: { signOuts.bump() })

        flow.begin(role: .shared)
        flow.confirmFirstStep()
        await flow.confirmDeletion()

        XCTAssertEqual(signOuts.value, 1)
        XCTAssertNil(flow.errorNotice)
    }
}

// MARK: - The locked copy

@MainActor
final class AccountDeletionCopyTests: XCTestCase {

    // MARK: First dialog

    func testTheOwnerFirstDialogSaysExactlyWhatDeletionCostsAnOwner() {
        let config = AccountDeletionDialog.first(role: .owner, onConfirm: {})
        XCTAssertEqual(config.title, "Delete your account?")
        XCTAssertEqual(
            config.message,
            "Removes your Tesla(s) from MyRoboTaxi, revokes everyone\u{2019}s access, and deletes your account. Ride history you were part of stays with the other party."
        )
        XCTAssertEqual(config.actionLabel, "Delete account")
        XCTAssertEqual(config.dismissLabel, "Cancel")
        XCTAssertEqual(config.kind, .destructive)
        XCTAssertNil(config.secondaryLabel, "this is the app's ordinary two-action confirm, not MYR-360's three-action one")
    }

    func testTheRiderFirstDialogSaysExactlyWhatDeletionCostsARider() {
        let config = AccountDeletionDialog.first(role: .shared, onConfirm: {})
        XCTAssertEqual(config.title, "Delete your account?")
        XCTAssertEqual(
            config.message,
            "Removes your access to every Tesla shared with you, cancels any rides you\u{2019}ve requested, and deletes your account. Ride history you were part of stays with the other party."
        )
        XCTAssertEqual(config.actionLabel, "Delete account")
        XCTAssertEqual(config.dismissLabel, "Cancel")
        XCTAssertEqual(config.kind, .destructive)
    }

    /// The two roles share a title and a pair of buttons, and differ in exactly
    /// one place — the sentence naming what goes.
    func testTheTwoRolesDifferOnlyInTheConsequenceSentence() {
        let owner = AccountDeletionDialog.first(role: .owner, onConfirm: {})
        let rider = AccountDeletionDialog.first(role: .shared, onConfirm: {})
        XCTAssertEqual(owner.title, rider.title)
        XCTAssertEqual(owner.actionLabel, rider.actionLabel)
        XCTAssertEqual(owner.dismissLabel, rider.dismissLabel)
        XCTAssertNotEqual(owner.message, rider.message)
        // Each names the thing only that role has.
        XCTAssertTrue(owner.message.contains("Tesla(s) from MyRoboTaxi"))
        XCTAssertTrue(rider.message.contains("shared with you"))
        // Both close on the same true promise about the other party's history.
        let tail = "Ride history you were part of stays with the other party."
        XCTAssertTrue(owner.message.hasSuffix(tail))
        XCTAssertTrue(rider.message.hasSuffix(tail))
    }

    // MARK: Second dialog

    func testTheSecondDialogIsAboutPermanenceAndIsTheSameForBothRoles() {
        let config = AccountDeletionDialog.second(onConfirm: {})
        XCTAssertEqual(config.title, "This can\u{2019}t be undone")
        XCTAssertEqual(
            config.message,
            "Your account and its data will be permanently deleted. You\u{2019}ll be signed out."
        )
        XCTAssertEqual(config.actionLabel, "Delete permanently")
        XCTAssertEqual(config.dismissLabel, "Keep my account")
        XCTAssertEqual(config.kind, .destructive)

        // Role-independent by construction: there is one factory and it takes no
        // role. Pinned through the FLOW, which is what a screen actually reads.
        let owner = AccountDeletionFlow(); owner.begin(role: .owner); owner.confirmFirstStep()
        let rider = AccountDeletionFlow(); rider.begin(role: .shared); rider.confirmFirstStep()
        XCTAssertEqual(owner.secondConfirmConfig.title, rider.secondConfirmConfig.title)
        XCTAssertEqual(owner.secondConfirmConfig.message, rider.secondConfirmConfig.message)
        XCTAssertEqual(owner.secondConfirmConfig.actionLabel, rider.secondConfirmConfig.actionLabel)
    }

    /// The two steps must be told apart at a glance, or the second reads as a
    /// duplicate of the first and gets tapped through.
    func testTheTwoStepsAreVisiblyDifferentQuestions() {
        let first = AccountDeletionDialog.first(role: .owner, onConfirm: {})
        let second = AccountDeletionDialog.second(onConfirm: {})
        XCTAssertNotEqual(first.title, second.title)
        XCTAssertNotEqual(first.actionLabel, second.actionLabel)
        XCTAssertNotEqual(first.dismissLabel, second.dismissLabel)
        XCTAssertNotEqual(first.icon, second.icon, "the glyph moves from the ACTION to its CONSEQUENCE")
        XCTAssertEqual(first.icon, "trash")
        XCTAssertEqual(second.icon, "exclamationmark.triangle.fill")
    }

    /// Deliberately NOT a type-to-confirm: Guideline 5.1.1(v) wants deletion
    /// discoverable and confirmable, and a text field adds friction without adding
    /// a decision. Two dialogs, two taps, and both offer a way out.
    func testDeletionIsTwoTapsAndBothStepsOfferAWayOut() {
        XCTAssertFalse(AccountDeletionDialog.first(role: .owner, onConfirm: {}).dismissLabel.isEmpty)
        XCTAssertFalse(AccountDeletionDialog.second(onConfirm: {}).dismissLabel.isEmpty)
        // "Keep my account" names what stays true — the app's established grammar
        // ("Keep access" / "Keep invite" / "Keep linked" / "Keep sharing").
        XCTAssertTrue(AccountDeletionDialog.second(onConfirm: {}).dismissLabel.hasPrefix("Keep"))
    }

    // MARK: The failure notice

    func testTheFailureNoticeSaysNothingWasLostAndInvitesARetry() {
        XCTAssertEqual(
            AccountDeletionDialog.failureNotice,
            "Couldn\u{2019}t delete your account. Nothing was lost \u{2014} try again."
        )
    }

    /// The alert's two slots are the ONE locked string, split on its sentence
    /// boundary and nowhere else — so the halves can never drift from it.
    func testTheAlertsTwoSlotsReassembleTheLockedNoticeExactly() {
        XCTAssertEqual(
            AccountDeletionDialog.failureNoticeTitle + " " + AccountDeletionDialog.failureNoticeBody,
            AccountDeletionDialog.failureNotice
        )
        XCTAssertEqual(AccountDeletionDialog.failureNoticeTitle, "Couldn\u{2019}t delete your account.")
        XCTAssertEqual(AccountDeletionDialog.failureNoticeBody, "Nothing was lost \u{2014} try again.")
    }

    /// Typographic apostrophes and an em dash, like every other string in this app
    /// — a straight quote in a dialog next to "Couldn't revoke access" reads as a
    /// different app.
    func testTheCopyUsesTheAppsTypographicPunctuation() {
        let strings = [
            AccountDeletionDialog.ownerMessage,
            AccountDeletionDialog.riderMessage,
            AccountDeletionDialog.confirmTitle,
            AccountDeletionDialog.confirmMessage,
            AccountDeletionDialog.failureNotice,
        ]
        for text in strings {
            XCTAssertFalse(text.contains("'"), "\"\(text)\" carries a straight apostrophe")
        }
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
// the token both rows are built on.

@MainActor
final class AccountSectionCopyTests: XCTestCase {

    /// The caption under the name. It is the whole answer to "why can't I change
    /// this?", which is the question a display-only name provokes.
    func testTheNameRowSaysWhereTheNameCameFrom() {
        XCTAssertEqual(AccountDeletionDialog.nameProvenanceCaption, "Set by Apple when you signed in")
    }

    func testTheSectionAndRowAreNamedPlainly() {
        XCTAssertEqual(AccountDeletionDialog.sectionTitle, "Account")
        XCTAssertEqual(AccountDeletionDialog.deleteRowLabel, "Delete account")
        // The row and the first dialog's confirm button say the same words, so the
        // tap that opens the dialog and the tap that advances it read as one action.
        XCTAssertEqual(AccountDeletionDialog.deleteRowLabel, AccountDeletionDialog.actionLabel)
    }

    /// The 44pt hard rule (CLAUDE.md), and MYR-345's lesson that a `contentShape`
    /// inset is not a tap target. Both delete rows are built on this token; the
    /// DELIVERED height is measured in the UI test.
    func testTheMinimumTapTargetTokenTheDeleteRowsUseMeetsTheHardRule() {
        XCTAssertGreaterThanOrEqual(MRTMetrics.minTapTarget, 44)
    }
}
