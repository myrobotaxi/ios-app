#if DEBUG
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - DebugAccountDeletionEndpoint (MYR-355 — drift-gate / screenshot only)
//
// A stand-in for `DELETE /api/users/me`, so the `deleteAccountFailed` scene can
// exercise the REAL `AccountDeletionFlow` (two dialogs → the endpoint call → the
// failure notice, user still signed in) without a live backend and without
// deleting anything.
//
// It is the WIRE that is injected and nothing else — the same "real code path,
// injected wire" precedent as `DebugServiceWindowEndpoint` / `DebugShareEndpoint`.
// The scene sets `failure` and the shipping flow does the rest, so what the
// capture shows is what the app would build from a real server's 500 rather than
// a hand-set notice string.
//
// The failure state has NO other capture route: reaching it against a real
// backend would mean holding a real account, behind a real auth session, and
// getting the server to fail a delete on purpose — and if it succeeded instead,
// the account would be gone.
//
// Release builds never compile this file.
struct DebugAccountDeletionEndpoint: AccountDeletionEndpoint {
    /// When set, every call fails with this error instead of succeeding (drives
    /// the failure capture). `nil` is the `204 No Content` success the contract
    /// documents.
    var failure: RestError?
    /// MYR-366 — seconds to wait before answering. The offboarding stepper
    /// reconciles a narration and a network call, so WHEN the answer lands is
    /// half of what a capture is about: a failure that returned instantly would
    /// stop the narration at step zero and show nothing of the "stopped part-way"
    /// state the treatment exists for.
    var delay: Double = 0
    /// MYR-366 — never answer at all. This is the ONLY way to capture the honesty
    /// gate: the narration finished, the last step still spinning, because no
    /// `204` has arrived. Against a real backend that window is milliseconds
    /// wide, and it is precisely the window in which the client's trust question
    /// ("is this screen telling me the truth?") is decided.
    var hangs = false

    func deleteAccount() async throws {
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        if hangs {
            // Sleeps until the task is cancelled (the screen going away), which
            // throws `CancellationError` — a cancelled capture, never a rendered
            // failure.
            try await Task.sleep(for: .seconds(60 * 60))
        }
        if let failure { throw failure }
    }

    /// The `500 internal_error` the contract's error catalog names, in the
    /// standard typed envelope. Deliberately a 500 rather than a 4xx: it is the
    /// case where the client did everything right, which is exactly when the
    /// notice has to say "nothing was lost — try again" and mean it.
    static let internalError = RestError.http(
        status: 500,
        code: ErrorPayload.Code(rawValue: "internal_error"),
        message: "account deletion failed",
        subCode: nil
    )
}
#endif
