import SwiftUI
import DesignSystem
import MyRoboTaxiKit

// MARK: - Deleting your account from Settings (MYR-355)
//
// App Store Review Guideline 5.1.1(v): an app that lets you CREATE an account
// must let you DELETE it, from inside the app, without a support ticket. This is
// that surface, and it is the only account-scoped destructive action in the
// client.
//
// Two things shape everything below.
//
// **It is ONE dialog and then a SCREEN** (MYR-366 — client-directed). MYR-355
// shipped two stacked destructive dialogs: the first stated the consequences in
// the reader's role's terms, the second stated permanence. The client's verdict
// on the result was that the whole surface reads "weird", and asked for the
// second step to become a **visual offboarding flow** instead — a vertical
// stepper that shows the teardown happening. So dialog #2 is GONE and
// `AccountOffboardingScreen` stands where it stood; the ONE remaining dialog
// absorbed its permanence sentence, minus the half of it that repeated the
// consequences it already listed. A text field asking someone to type DELETE
// would still add friction without adding a decision, and the guideline still
// wants deletion discoverable and confirmable rather than laborious.
//
// **A FAILED DELETE LEAVES YOU SIGNED IN.** `DELETE /api/users/me` is
// RE-RUNNABLE by contract — a partial failure leaves a state where calling it
// again finishes the job — so the honest resting state after a failure is
// exactly where the user started, with a notice that says retrying is safe.
// Signing someone out of an account that may still exist would strand them
// outside the only surface that can finish the job. MYR-366 keeps that rule and
// moves the retry ONTO the offboarding screen, where the stepper is already
// showing exactly how far the teardown got.

// MARK: - The copy
//
// A static factory returning `MRTConfirmDialogConfig`s, following the
// `ShareDialogs` / `RideSharePauseDialog` precedent: copy lives next to copy and
// never inline in a view, so it can be read, reviewed and pinned by a test on its
// own (`AccountDeletionCopyTests`).

enum AccountDeletionDialog {
    // MARK: The ONE dialog — what deletion does, per role, and that it is final

    /// The subject is the account, so the title is identical for both roles; what
    /// differs is the list of things that go with it.
    static let title = "Delete your account?"

    /// MYR-366 — the permanence sentence, which used to be the second dialog's
    /// whole body (`"Your account and its data will be permanently deleted.
    /// You'll be signed out."`). With that dialog replaced by the offboarding
    /// screen, this is now the LAST question asked before the `DELETE` runs, so
    /// the fact has to be on it.
    ///
    /// **The redundancy is what was dropped, not the meaning.** The role
    /// sentences below already end by naming the account, and the old pair said
    /// "…and deletes your account" and then "Your account … will be permanently
    /// deleted" one tap apart. The role sentences now stop at the consequences
    /// and this one sentence carries permanence + sign-out for both roles —
    /// deliberately role-INDEPENDENT, because a second sentence that varied by
    /// role would imply the permanence does.
    static let permanenceSentence = "This can\u{2019}t be undone \u{2014} you\u{2019}ll be signed out."

    /// The OWNER's consequences: their cars leave the product and every viewer
    /// they invited loses access.
    static let ownerConsequences = "Removes your Tesla(s) from MyRoboTaxi and revokes everyone\u{2019}s access."

    /// The RIDER's consequences: the shares pointed AT them stop working and their
    /// open requests are cancelled.
    static let riderConsequences = "Removes your access to every Tesla shared with you and cancels any rides you\u{2019}ve requested."

    /// The one line that survives from MYR-355 unchanged, because it answers the
    /// question both roles actually ask: what happens to the rides someone ELSE
    /// was part of.
    static let historyClause = "Ride history you were part of stays with the other party."

    /// The composed owner / rider body: consequences → permanence → history.
    /// Composed rather than written twice so the shared halves are one string
    /// (`AccountDeletionCopyTests` pins the composition).
    static let ownerMessage = "\(ownerConsequences) \(permanenceSentence) \(historyClause)"
    static let riderMessage = "\(riderConsequences) \(permanenceSentence) \(historyClause)"

    /// MYR-366 — the confirm label is MYR-355's own `"Delete permanently"`,
    /// promoted from the (now absent) second dialog. This tap IS the point of no
    /// return, so the button that performs it has to say so; "Delete account"
    /// stays on the SETTINGS ROW, where it opens a question rather than answering
    /// one.
    static let actionLabel = "Delete permanently"
    /// MYR-355's own second-dialog dismiss, for the same reason the action label
    /// moved: this is the terminal decision, and naming what STAYS true is this
    /// app's grammar for backing out of one ("Keep access" / "Keep invite" /
    /// "Keep linked" / "Keep sharing").
    static let dismissLabel = "Keep my account"
    /// The dialog's glyph: what the action does. It matches the Settings row's
    /// own `trash`, so the row and the dialog read as one action.
    static let icon = "trash"

    // MARK: Failure

    /// The notice a failed delete leaves behind.
    ///
    /// Three sentences' worth of work in one line: it says the delete did not
    /// happen, it says nothing was half-destroyed (which is the reader's first
    /// fear, and is TRUE — the server's teardown is re-runnable, not partial from
    /// the client's point of view), and it says the safe next move. The user is
    /// still signed in when they read it, so "try again" points at a button that
    /// is still there.
    static let failureNotice = "Couldn\u{2019}t delete your account. Nothing was lost \u{2014} try again."

    /// The same notice in the two slots Settings' existing destructive-failure
    /// surface has: `SettingsScreen`'s teardown alert is a `"Couldn't remove this
    /// car"` title over an explanatory line, and this is that grammar with this
    /// copy. Split on the sentence boundary, VERBATIM and in order —
    /// `failureNoticeTitle + " " + failureNoticeBody` is `failureNotice`,
    /// asserted, so the locked string stays the single source of truth and the two
    /// halves can never drift from it.
    ///
    /// It is an ALERT rather than the quiet `mrtSuccessToast` pill the revoke
    /// failure uses, and that was measured rather than chosen: the pill is one
    /// line tall and floats where the `BottomNav` does, so this notice wrapped to
    /// two lines straight through the nav's glyphs and was unreadable on both
    /// screens. A one-line pill is not a container for a two-sentence recovery
    /// instruction.
    static let failureNoticeTitle = "Couldn\u{2019}t delete your account."
    static let failureNoticeBody = "Nothing was lost \u{2014} try again."

    // MARK: The Account section itself
    //
    // The section's own strings live here too rather than inline in two views,
    // for the same reason the dialog's do: they are the same copy on both
    // screens, and two literals is two places for them to drift.

    static let sectionTitle = "Account"
    /// The row label. Deliberately NOT the dialog's `actionLabel` any more
    /// (MYR-366): the row opens a question and the dialog's button answers it, so
    /// the row says what it is FOR and the button says what it DOES.
    static let deleteRowLabel = "Delete account"

    // MARK: Factories

    /// The role-specific dialog — the ONE confirmation (MYR-366).
    static func first(role: UserRole, onConfirm: @escaping () -> Void) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: icon,
            title: title,
            message: role == .owner ? ownerMessage : riderMessage,
            actionLabel: actionLabel,
            dismissLabel: dismissLabel,
            action: onConfirm
        )
    }
}

// MARK: - The flow

/// Owns the account-deletion interaction end to end: which role is asking, which
/// surface is up, the in-flight write, the stepper's state, and the two ways it
/// can end.
///
/// It is a small `@Observable` object rather than a scattering of `@State` across
/// the two settings screens for the same reason `RideSharePauseFlow` is: every
/// assertion worth making here is about the WIRE and the ORDER — that cancelling
/// calls nothing, that confirming calls the endpoint exactly once, that a failure
/// does NOT sign anybody out, that a failed delete never renders an all-checked
/// stepper — and none of that should need a view to run. The screens keep exactly
/// one job: raise it, and render what it says.
@MainActor
@Observable
final class AccountDeletionFlow {

    /// Which surface is presented. Three states rather than two booleans, because
    /// two booleans have a fourth state ("both up") that must never exist.
    enum Step: Equatable {
        case none
        /// The ONE confirm dialog.
        case firstConfirm
        /// MYR-366 — the full-screen visual offboarding flow, which REPLACED
        /// MYR-355's second dialog. Entering it starts the `DELETE`.
        case offboarding
    }

    /// The role the copy speaks to. Set by `begin(role:)` and never guessed —
    /// the two screens know which shell they are, and both the dialog body and
    /// the narrated sequence differ.
    private(set) var role: UserRole = .owner
    private(set) var step: Step = .none
    /// True while the `DELETE` is in flight. Guards re-entry, so a double-tap
    /// cannot send two deletes.
    private(set) var isDeleting = false
    /// MYR-366 — everything the stepper renders. Sized to the role's sequence the
    /// moment the offboarding screen is raised.
    private(set) var stepper = OffboardingStepperState(stepCount: 0)

    /// The account-deletion seam. `nil` off the live path — see `performDelete()`
    /// for what that case does and why it is not a failure.
    var endpoint: (any AccountDeletionEndpoint)?

    /// The local sign-out + wipe. Owned by `RootView`, which wires it to the SAME
    /// helper the Sign out row's closure calls, so a deleted account and a
    /// signed-out one leave the app in exactly one state.
    ///
    /// MYR-366 — it now runs on the ending screen's **Done**, not on the `204`.
    /// The two manual Tesla steps are the last thing the owner will ever be told
    /// about this account, and wiping the shell out from under them the instant
    /// the server answers would take that screen away before it was read.
    var onDeleted: (() -> Void)?

    /// The narration's pacing, injectable so tests run instantly instead of in
    /// real seconds. Production is a plain sleep.
    var narrationSleep: @Sendable (Double) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    init(
        endpoint: (any AccountDeletionEndpoint)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.onDeleted = onDeleted
    }

    // MARK: Presentation bindings
    //
    // Computed bindings rather than raw `Binding(get:set:)` at each call site, so
    // both screens present the surface identically.
    //
    // The setter is GUARDED on the step it belongs to, and that guard is
    // load-bearing rather than defensive: `MRTConfirmDialogCard` runs
    // `config.action()` and THEN `dismiss()`, so the dialog's confirm has already
    // moved the flow to `.offboarding` by the time its own binding is set false.
    // An unguarded setter would immediately close the surface it just opened.

    var isPresentingFirstConfirm: Bool {
        get { step == .firstConfirm }
        set { if !newValue, step == .firstConfirm { step = .none } }
    }

    /// MYR-366 — the full-screen cover. It has NO user-driven dismissal: by the
    /// time it is up the `DELETE` is running, and the only exits are the ending
    /// screen's Done and the failure treatment's "Not now".
    var isPresentingOffboarding: Bool {
        get { step == .offboarding }
        set { if !newValue, step == .offboarding { step = .none } }
    }

    /// The dialog's config.
    var firstConfirmConfig: MRTConfirmDialogConfig {
        AccountDeletionDialog.first(role: role) { [weak self] in self?.confirmFirstStep() }
    }

    /// The role's narrated sequence, for the screen to render.
    var offboardingSteps: [String] { OffboardingSequence.steps(for: role) }

    // MARK: Entry

    /// The ONE entry point the "Delete account" row calls. Raises the dialog;
    /// nothing is written and nothing is asked of the server yet.
    func begin(role: UserRole) {
        guard !isDeleting else { return }
        self.role = role
        step = .firstConfirm
    }

    /// The dialog's confirm: raise the offboarding screen. Still nothing written
    /// HERE — the screen's `.task` starts the `DELETE` when it appears, which is
    /// what makes the narration and the network call start together rather than
    /// the call trailing a screen that is already narrating.
    func confirmFirstStep() {
        guard step == .firstConfirm else { return }
        stepper = OffboardingStepperState(stepCount: offboardingSteps.count)
        step = .offboarding
    }

    /// Cancelling the dialog. Nothing was written, so there is nothing to undo and
    /// no notice to raise: the account is exactly as it was.
    func cancel() {
        step = .none
    }

    // MARK: The offboarding run

    /// The offboarding screen's `.task`. Starts the ONE `DELETE` and the narration
    /// TOGETHER, then lets `OffboardingStepperState` reconcile whichever finishes
    /// first.
    ///
    /// Both orderings are real and both are handled by the state machine rather
    /// than here: a `204` that lands early cannot jump the last check forward
    /// (`checkedCount` requires the narration to have caught up), and a narration
    /// that finishes early leaves the last step spinning until the answer comes.
    func runOffboarding() async {
        guard step == .offboarding, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        async let narration: Void = narrate()
        await performDelete()
        await narration
    }

    /// "Try again" on the failure treatment. The endpoint is re-runnable by
    /// contract, so this RESUMES: the steps already checked stay checked and the
    /// narration continues from where the failure stopped it.
    func retryOffboarding() async {
        guard step == .offboarding, stepper.hasFailed, !isDeleting else { return }
        stepper.retry()
        isDeleting = true
        defer { isDeleting = false }
        async let narration: Void = narrate()
        await performDelete()
        await narration
    }

    /// The ending screen's **Done** — the ONLY place the local wipe runs.
    func finish() {
        step = .none
        onDeleted?()
    }

    /// The failure treatment's "Not now": back to Settings, STILL SIGNED IN. The
    /// account may still exist and the row is still there to try again from.
    func dismissAfterFailure() {
        guard stepper.hasFailed else { return }
        step = .none
    }

    // MARK: Pieces

    /// Walks the narrated steps on the clock. Stops the moment the state machine
    /// says it may not narrate — which a recorded FAILURE makes true, so a failure
    /// stops the narration rather than merely hiding its output.
    private func narrate() async {
        let interval = OffboardingMotion.stepInterval(stepCount: stepper.stepCount)
        while stepper.canNarrate {
            await narrationSleep(interval)
            guard stepper.canNarrate else { return }
            stepper.narrateOneStep()
        }
    }

    /// The ONE network call this whole feature makes.
    private func performDelete() async {
        do {
            // No seam at all is NOT the same as a seam that failed — the same
            // distinction `RideSharePauseFlow.setEnabled` draws. `endpoint` is
            // `nil` only on the SIMULATED path, where there is no server account to
            // delete: the local session IS the whole account there, so wiping it
            // is the complete and honest execution of what was asked, not a
            // pretend one. On the live path the composition always supplies one.
            try await endpoint?.deleteAccount()
            stepper.recordSuccess()
        } catch {
            // Deliberately NOT `session.signOut()`. The account may still exist;
            // the user must stay where the retry is.
            stepper.recordFailure()
        }
    }

    #if DEBUG
    /// How far a DEBUG capture scene drives this flow. Release builds never
    /// compile it.
    enum DebugStage {
        /// The confirm dialog, up.
        case dialog
        /// Confirmed, and the offboarding screen RUNNING against whatever endpoint
        /// the scene injected — a hang (mid-flight / spinner held on the last
        /// step), a scripted 500 (the failure treatment), or nothing at all
        /// (simulated success → the ending screen).
        case offboarding
    }

    /// Stand in for the taps headless capture tooling cannot perform, and NOTHING
    /// else: this calls the same shipping methods a thumb does, in the same order,
    /// so the copy, the endpoint call, the stepper and the ending in a capture are
    /// all the production path's.
    func debugDrive(to stage: DebugStage, role: UserRole) async {
        begin(role: role)
        guard stage != .dialog else { return }
        confirmFirstStep()
        await runOffboarding()
    }
    #endif
}

// MARK: - Composition point

/// Builds the live account-deletion endpoint on the LIVE path, or `nil`
/// (simulated) — mirrors `VehicleTeardownComposition.makeRemover`. Reuses the
/// live fleet's resolved environment + session token provider so the `DELETE`
/// carries the exact signed-in user's Bearer.
enum AccountDeletionComposition {
    @MainActor
    static func makeEndpoint(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> (any AccountDeletionEndpoint)? {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else { return nil }
        return RestClient(environment: config.environment, tokenProvider: config.tokenProvider)
    }
}
