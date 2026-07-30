import Foundation

// MARK: - Account deletion (MYR-355)
//
// `DELETE /api/users/me` — the App Store review requirement (Guideline 5.1.1(v):
// an account created in the app must be deletable from inside the app). It is
// the ONLY account-scoped destructive surface in this client, and it is
// deliberately narrower than every other endpoint family here: NO request body,
// NO response body, no ids, no options.
//
// There are no payload DTOs in this file, and that is the contract rather than an
// omission — the request carries nothing but the Bearer, and success is `204 No
// Content`. A file of wire shapes for a call with no wire shapes would be an
// invitation to invent one.

/// The account-deletion surface (MYR-355), factored into its own protocol so
/// callers depend only on "delete my account" and can be tested with a stub — the
/// same narrowing pattern as ``VehicleTeardownEndpoint`` / ``PushDeviceEndpoint``.
/// `RestClient` is the production conformer.
///
/// Deliberately NOT folded into ``AuthenticationEndpoint``: revoking a session is
/// a token operation the account survives, while this deletes the account itself
/// and every row hanging off it. They share a subject and nothing else, and the
/// §7.10 identity endpoints run the PRE-AUTH pipeline (no Bearer, no refresh
/// retry) which this call must not.
public protocol AccountDeletionEndpoint: Sendable {
    /// `DELETE /api/users/me` (MYR-355) — delete the signed-in account.
    /// Authenticated (Bearer + the standard single 401 refresh-retry). NO request
    /// body; success is `204 No Content`.
    ///
    /// **RE-RUNNABLE BY CONTRACT.** A partial failure server-side leaves a state
    /// in which calling this again finishes the job, so a caller that failed
    /// mid-way may — and should — simply offer the user a retry. That property is
    /// what lets the client keep the user SIGNED IN on failure instead of
    /// half-tearing-down a session whose account may or may not still exist.
    ///
    /// Throws a typed `RestError` on any non-2xx — `401 auth_failed` (surfaced
    /// only after the one refresh-retry), `429 rate_limited`, `500 internal_error`.
    /// There is no reauth sub-code gate in this round: the caller must not branch
    /// on one.
    func deleteAccount() async throws
}
