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
    /// the notice capture). `nil` is the `204 No Content` success the contract
    /// documents — which, run through the flow, signs the app out.
    var failure: RestError?

    func deleteAccount() async throws {
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
