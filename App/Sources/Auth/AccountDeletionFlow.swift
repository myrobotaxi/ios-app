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
// **It is a TWO-STEP DIALOG, not a type-to-confirm.** The guideline's own
// framing is that deletion must be *discoverable* and *confirmable*, not
// laborious — a labyrinth is its own review risk. Two explicit destructive
// dialogs is the app's existing confirm grammar used twice: the first states
// what is lost in the reader's own role's terms, the second states that it is
// permanent and offers "Keep my account" as the way out. A text field asking
// someone to type DELETE would add friction without adding a decision.
//
// **A FAILED DELETE LEAVES YOU SIGNED IN.** `DELETE /api/users/me` is
// RE-RUNNABLE by contract — a partial failure leaves a state where calling it
// again finishes the job — so the honest resting state after a failure is
// exactly where the user started, with a notice that says retrying is safe.
// Signing someone out of an account that may still exist would strand them
// outside the only surface that can finish the job.

// MARK: - The copy
//
// A static factory returning `MRTConfirmDialogConfig`s, following the
// `ShareDialogs` / `RideSharePauseDialog` precedent: copy lives next to copy and
// never inline in a view, so it can be read, reviewed and pinned by a test on its
// own (`AccountDeletionCopyTests`).

enum AccountDeletionDialog {
    // MARK: First dialog — what deletion actually does, per role

    /// The subject is the account, so the title is identical for both roles; what
    /// differs is the list of things that go with it.
    static let title = "Delete your account?"

    /// The OWNER's consequences: their cars leave the product, every viewer they
    /// invited loses access, and the account goes.
    static let ownerMessage = "Removes your Tesla(s) from MyRoboTaxi, revokes everyone\u{2019}s access, and deletes your account. Ride history you were part of stays with the other party."

    /// The RIDER's consequences: the shares pointed AT them stop working and their
    /// open requests are cancelled.
    static let riderMessage = "Removes your access to every Tesla shared with you, cancels any rides you\u{2019}ve requested, and deletes your account. Ride history you were part of stays with the other party."

    /// Names the action, not the severity — the severity is the second dialog's
    /// whole job.
    static let actionLabel = "Delete account"
    /// The plain way out of a first step that has decided nothing yet.
    static let dismissLabel = "Cancel"
    /// The first dialog's glyph: what the action does.
    static let icon = "trash"

    // MARK: Second dialog — permanence, identical for both roles

    /// The one fact the first dialog deliberately does not lead with.
    static let confirmTitle = "This can\u{2019}t be undone"
    /// Both consequences of confirming, in the order they happen.
    static let confirmMessage = "Your account and its data will be permanently deleted. You\u{2019}ll be signed out."
    /// The confirm label carries the permanence too, so a mis-tap on a stack of
    /// two red buttons is still a mis-tap on a labelled one.
    static let confirmActionLabel = "Delete permanently"
    /// Names what STAYS true rather than "Cancel" — the same grammar as "Keep
    /// access" / "Keep invite" / "Keep linked" / "Keep sharing".
    static let confirmDismissLabel = "Keep my account"
    /// The second dialog's glyph: the CONSEQUENCE rather than the action, which is
    /// the difference between the two steps.
    static let confirmIcon = "exclamationmark.triangle.fill"

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

    // MARK: Factories

    /// The role-specific first dialog.
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

    /// The second dialog. Deliberately role-INDEPENDENT: "permanent" and "signed
    /// out" are true of both, and a second sentence that varied by role would
    /// imply the permanence does.
    static func second(onConfirm: @escaping () -> Void) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: confirmIcon,
            title: confirmTitle,
            message: confirmMessage,
            actionLabel: confirmActionLabel,
            dismissLabel: confirmDismissLabel,
            action: onConfirm
        )
    }
}

// MARK: - The flow

/// Owns the account-deletion interaction end to end: which role is asking, which
/// of the two dialogs is up, the in-flight write, and the two ways it can end.
///
/// It is a small `@Observable` object rather than a scattering of `@State` across
/// the two settings screens for the same reason `RideSharePauseFlow` is: every
/// assertion worth making here is about the WIRE and the ORDER — that cancelling
/// at either step calls nothing, that confirming calls the endpoint exactly once,
/// that a failure does NOT sign anybody out — and none of that should need a view
/// to run. The screens keep exactly one job: raise it, and render its two dialogs.
@MainActor
@Observable
final class AccountDeletionFlow {

    /// Which dialog is presented. Three states rather than two booleans, because
    /// two booleans have a fourth state ("both up") that must never exist.
    enum Step: Equatable {
        case none
        case firstConfirm
        case secondConfirm
    }

    /// The role the dialogs speak to. Set by `begin(role:)` and never guessed —
    /// the two screens know which shell they are, and the copy differs.
    private(set) var role: UserRole = .owner
    private(set) var step: Step = .none
    /// True while the `DELETE` is in flight. Drives the busy overlay AND guards
    /// re-entry, so a double-tap cannot send two deletes.
    private(set) var isDeleting = false
    /// The failure notice, or `nil`. Settable so the toast's binding can clear it.
    var errorNotice: String?

    /// The account-deletion seam. `nil` off the live path — see `runDelete()` for
    /// what that case does and why it is not a failure.
    var endpoint: (any AccountDeletionEndpoint)?

    /// The local sign-out + wipe, run on success. Owned by `RootView`, which wires
    /// it to the SAME helper the Sign out row's closure calls, so a deleted
    /// account and a signed-out one leave the app in exactly one state.
    var onDeleted: (() -> Void)?

    init(
        endpoint: (any AccountDeletionEndpoint)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.onDeleted = onDeleted
    }

    // MARK: Presentation bindings
    //
    // Computed bindings rather than raw `Binding(get:set:)` at each of the four
    // call sites, so both screens present the pair identically.
    //
    // The setters are GUARDED on the step they belong to, and that guard is
    // load-bearing rather than defensive: `MRTConfirmDialogCard` runs
    // `config.action()` and THEN `dismiss()`, so the first dialog's confirm has
    // already moved the flow to `.secondConfirm` by the time its own binding is
    // set false. An unguarded setter would immediately close the dialog it just
    // opened.

    var isPresentingFirstConfirm: Bool {
        get { step == .firstConfirm }
        set { if !newValue, step == .firstConfirm { step = .none } }
    }

    var isPresentingSecondConfirm: Bool {
        get { step == .secondConfirm }
        set { if !newValue, step == .secondConfirm { step = .none } }
    }

    var isPresentingErrorNotice: Bool {
        get { errorNotice != nil }
        set { if !newValue { errorNotice = nil } }
    }

    /// The presented dialog's config, for whichever step is up.
    var firstConfirmConfig: MRTConfirmDialogConfig {
        AccountDeletionDialog.first(role: role) { [weak self] in self?.confirmFirstStep() }
    }

    var secondConfirmConfig: MRTConfirmDialogConfig {
        AccountDeletionDialog.second { [weak self] in
            guard let self else { return }
            Task { await self.confirmDeletion() }
        }
    }

    // MARK: Entry

    /// The ONE entry point the "Delete account" row calls. Raises the FIRST
    /// dialog; nothing is written and nothing is asked of the server yet.
    ///
    /// Clears any previous failure notice: the user is answering the question
    /// again, and a stale "try again" line beneath a fresh dialog would be reading
    /// about the wrong attempt.
    func begin(role: UserRole) {
        guard !isDeleting else { return }
        self.role = role
        errorNotice = nil
        step = .firstConfirm
    }

    /// The FIRST dialog's confirm: present the SECOND dialog. Still nothing
    /// written — this step's entire product is the next question.
    func confirmFirstStep() {
        guard step == .firstConfirm else { return }
        step = .secondConfirm
    }

    /// Cancelling at EITHER step. Nothing was written at either one, so there is
    /// nothing to undo and no notice to raise: the account is exactly as it was.
    func cancel() {
        step = .none
    }

    // MARK: The delete

    /// The SECOND dialog's confirm: the only path that touches the network.
    ///
    /// On success (`204`) the local sign-out + wipe runs and the app lands on Sign
    /// In. On failure the user is LEFT SIGNED IN with a notice — the endpoint is
    /// re-runnable, so tapping again is safe and finishes the job.
    func confirmDeletion() async {
        guard !isDeleting else { return }
        step = .none
        isDeleting = true
        defer { isDeleting = false }

        do {
            // No seam at all is NOT the same as a seam that failed — the same
            // distinction `RideSharePauseFlow.setEnabled` draws. `endpoint` is
            // `nil` only on the SIMULATED path, where there is no server account to
            // delete: the local session IS the whole account there, so wiping it
            // is the complete and honest execution of what was asked, not a
            // pretend one. On the live path the composition always supplies one.
            try await endpoint?.deleteAccount()
            onDeleted?()
        } catch {
            // Deliberately NOT `session.signOut()`. The account may still exist;
            // the user must stay where the retry is.
            errorNotice = AccountDeletionDialog.failureNotice
        }
    }

    #if DEBUG
    /// How far a DEBUG capture scene drives this flow. Release builds never
    /// compile it.
    enum DebugStage {
        /// The FIRST dialog, up.
        case first
        /// The SECOND dialog, up.
        case second
        /// Both confirmed and the delete RUN — against whatever endpoint the scene
        /// injected, which for `deleteAccountFailed` is a scripted 500.
        case deleted
    }

    /// Stand in for the taps headless capture tooling cannot perform, and NOTHING
    /// else: this calls the same three shipping methods a thumb does, in the same
    /// order, so the copy, the endpoint call and the notice in a capture are all
    /// the production path's.
    func debugDrive(to stage: DebugStage, role: UserRole) async {
        begin(role: role)
        guard stage != .first else { return }
        confirmFirstStep()
        guard stage != .second else { return }
        await confirmDeletion()
    }
    #endif
}

// MARK: - Busy overlay

/// The in-flight overlay for the account `DELETE`, shared verbatim by both
/// settings screens rather than written twice — the same shape (scrim + gold
/// `SpinnerRing` + one line) `SettingsScreen`'s teardown overlay uses, so the two
/// destructive waits in Settings look like one thing.
struct AccountDeletionBusyOverlay: View {
    let isDeleting: Bool

    var body: some View {
        if isDeleting {
            ZStack {
                Color.mrtScrim.ignoresSafeArea()
                VStack(spacing: 14) {
                    SpinnerRing(diameter: 34, lineWidth: 3, trackColor: .mrtBorder, color: .mrtGold, period: 0.8)
                    Text("Deleting your account\u{2026}")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                }
            }
            .transition(.opacity)
        }
    }
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
