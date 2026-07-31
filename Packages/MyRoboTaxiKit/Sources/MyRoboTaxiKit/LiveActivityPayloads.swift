import Foundation
import MyRobotaxiContracts

// MARK: - Live Activity token registration (MYR-172, rest-api.md §7.21)
//
// The rider's app starts an ActivityKit Live Activity locally when its ride is
// ACCEPTED, then hands the server the Activity's own push token so the server can
// write to that one lock screen. Two calls, both scoped to a single ride:
//
//   POST   /api/ride-requests/{id}/activity-token   { activityToken, sandbox? }
//   DELETE /api/ride-requests/{id}/activity-token   → { ended }
//
// This is a SIBLING of `PushDeviceEndpoint` (MYR-186), not a replacement, and the
// two tokens are genuinely different things. A DEVICE token addresses the phone
// and is registered once per install; an ACTIVITY token addresses ONE Activity on
// ONE ride and is minted per Activity — so it is registered per ride, rotates
// mid-ride, and dies with the Activity. Folding them into one endpoint would have
// meant a token-kind discriminator on a body whose two-key shape is asserted
// (`PushDeviceEndpointTests.testRegisterPutsTokenAndSandboxFlag`), and a device
// row the Activity does not need: per §7.21 the `sandbox` flag is carried
// PER-ACTIVITY precisely because starting a Live Activity requires no notification
// permission, so a rider who declined the prompt has a live Activity and no device
// row at all.
public protocol RideActivityTokenEndpoint: Sendable {
    /// `POST /api/ride-requests/{id}/activity-token` — register (or re-register)
    /// the ActivityKit push token for this ride's Live Activity.
    ///
    /// IDEMPOTENT AND UPSERTING, keyed `(ride, rider)`. A rotation is an ordinary
    /// re-registration: ActivityKit reissues the token during the life of a single
    /// Activity and expects the server to switch to the new one, so the caller
    /// simply posts again. Re-registering after an end also clears the server's end
    /// tombstone, because the client is saying it has a live Activity again.
    ///
    /// Throws `RestError.http(status: 409, …)` when the ride has already reached a
    /// terminal state. That 409 is not a failure to retry — it is the server saying
    /// this Activity will never be pushed to, and per §7.21 it is **the signal to
    /// end the Activity locally**. `RestError.isTerminalRideActivityConflict` is
    /// the spelling.
    ///
    /// The token is P1 — a capability. Whoever holds it, with the team's APNs
    /// signing key, can write to that phone's lock screen. Never log it beyond an
    /// 8-character prefix (`LiveActivityTokenRedaction.prefix`).
    @discardableResult
    func registerRideActivityToken(
        rideID: String,
        token: String,
        sandbox: Bool
    ) async throws -> LiveActivityRegistrationResponse

    /// `DELETE /api/ride-requests/{id}/activity-token` — the app reporting that the
    /// Live Activity has ended on the phone, whether the rider dismissed it or the
    /// app ended it from its own final-state fallback.
    ///
    /// IDEMPOTENT: ending an already-ended Activity answers `200 { ended: false }`,
    /// not an error, "because the client's end and the server's terminal-state push
    /// race by design and both are correct". So a `false` here is never worth
    /// surfacing and never worth retrying.
    @discardableResult
    func endRideActivityToken(rideID: String) async throws -> EndLiveActivityResponse
}

// MARK: - Token redaction

/// The one place a Live Activity push token may be turned into something loggable.
///
/// §7.21 classifies the token P1 and says it must never appear in full in a log, a
/// response or an error message — only an 8-character prefix. Having a single
/// named helper is what makes that greppable; a bare `String(token.prefix(8))` at
/// each call site is the same bytes with no way to audit it.
public enum LiveActivityTokenRedaction {
    public static let prefixLength = 8

    /// An 8-character prefix, for correlating a rotation in the logs without
    /// putting the capability itself there.
    public static func redacted(_ token: String) -> String {
        String(token.prefix(prefixLength))
    }
}

public extension RestError {
    /// True for the `409` that `POST …/activity-token` answers when the ride has
    /// already reached a terminal state.
    ///
    /// Per §7.21 this is the instruction to END THE ACTIVITY LOCALLY, not an error
    /// to retry or surface: the ride is over, the server will never push to that
    /// Activity, and the client is the only thing that can still take it off the
    /// lock screen. Deliberately keyed on the STATUS ALONE rather than on an error
    /// `code`: the §7.21 schema documents the conflict by status and names no
    /// envelope code for it, so matching a code would be matching a value the
    /// contract never promised — and would fail open, leaving the Activity up.
    var isTerminalRideActivityConflict: Bool {
        httpStatus == 409
    }
}
