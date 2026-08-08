import Foundation
import MyRoboTaxiKit

// MARK: - MYR-465 — the invite screen's refusal state, as ONE value
//
// External beta, build `202608030843`, James Guan (rider): *"When code expired,
// there is no response or notification on UI side telling me the info"* — the
// "Enter invite code" screen after submitting an expired code was visually
// identical to the screen before typing.
//
// **THE CAUSE WAS ONE ASSIGNMENT, AND IT READ AS TIDY.** `InviteCodeFlow.submit`
// split its refusals two ways: the ones that CLEAR the entry got `shakes += 1;
// code = ""; refusal = nil`, and everything else got a line of copy. So the two
// most common answers on this screen — `400 malformed` and, critically,
// `404 unknown / expired / already used / revoked` — were rendered as a 0.4s
// horizontal wobble and nothing else, with `refusal` deliberately set back to
// `nil` so no words could appear.
//
// **AND UNDER REDUCE MOTION THERE WAS NO WOBBLE EITHER.** `Shake`'s own comment
// promised "Reduce Motion → no shake (validation feedback stays visible via
// state)" — a promise about a state this branch had just erased. For a rider with
// Reduce Motion on, a rejected code produced literally zero UI response: the same
// six boxes, emptied, and a caret. **A fallback that points at state nobody set
// is indistinguishable from no fallback at all.**
//
// The refusal is a VALUE now, and there is exactly one place that decides what it
// says. `InviteCodeFlow` assigns it unconditionally, so "shake" and "say
// something" are no longer alternatives: the shake is an *addition* to the words
// for the two failures that are about the code, and never a substitute for them.
//
// ⚠️ **WHAT THE SERVER CAN AND CANNOT TELL APART, AND WHY THAT IS THE CEILING.**
// MYR-465 asks for four distinct states — expired, already used, revoked,
// malformed/unknown. §7.5.5 emits five statuses and only ONE of them is about the
// code being wrong:
//
//   * `400 invalid_request` — malformed after normalization.
//   * `404 not_found` — unknown, **expired**, or already consumed by another
//     account, with an **identical body** for all three; and §7.5.0 adds that
//     re-redeeming a **revoked/suspended** grant's code answers 404 too,
//     "indistinguishably from an unknown or expired code… The server does not
//     announce a suspension to the person it was applied to."
//   * `409 conflict` — the caller already holds access.
//   * `429 rate_limited`, `401`/`5xx`.
//
// That collapse is **deliberate anti-enumeration**, not an oversight: the code
// space is 36^6 and this endpoint is the only rider-facing one, so a body that
// said *which* of the four it hit would turn the join page into an oracle. Three
// of MYR-465's four states are therefore **not distinguishable by any client**,
// and inventing three sentences for one status would be guessing out loud —
// precisely what `ShareRedemptionFailure`'s own doc comment refuses.
//
// So the honest maximum is: **the client distinguishes exactly what the server
// distinguishes** (a separate line per status, `400` and `404` included), and the
// 404's copy ENUMERATES the possibilities with a hedge rather than asserting one.
// "It may have expired or already been used" names both actions a rider can take
// without claiming which happened. Closing the gap properly is a SERVER change
// (a sub-code on the 404, scoped to a caller who can prove they were sent the
// code — e.g. a signed §7.5.6 link) and is reported rather than faked here.

/// One refusal, resolved: what to say, and what to do to the entry field.
///
/// Carries BOTH lines because they answer different questions — the headline says
/// what happened, the guidance says what the rider can do about it — and a single
/// sentence carrying both is either too long for the 280pt column or drops one.
struct InviteCodeRefusalNotice: Equatable, Sendable {
    /// The state, in the fewest words. Delegated VERBATIM to
    /// ``ShareRedemptionFailure/riderMessage`` so the invite screen and any other
    /// consumer of that catalog cannot drift into two vocabularies for one answer.
    let headline: String
    /// The next action. Never blank: a refusal a rider cannot act on is the
    /// silence this issue is about, one step quieter.
    let guidance: String
    /// Whether the six cells empty and re-focus. Delegated VERBATIM to
    /// ``ShareRedemptionFailure/clearsEntry``.
    let clearsEntry: Bool

    /// The prototype's `mrtShake`. Exactly the failures that clear the entry — a
    /// shake is a claim that the CODE is wrong, which is false of the rate limit
    /// and of "you already have access".
    ///
    /// It is a property of the notice rather than a second switch at the call
    /// site so the shake can never again be raised in place of the words.
    var shakes: Bool { clearsEntry }
}

/// The one place a §7.5.5 refusal becomes something the invite screen renders.
enum InviteCodeRefusal {
    static func notice(for failure: ShareRedemptionFailure) -> InviteCodeRefusalNotice {
        InviteCodeRefusalNotice(
            headline: failure.riderMessage,
            guidance: guidance(for: failure),
            clearsEntry: failure.clearsEntry
        )
    }

    /// The action line, one per status the server actually distinguishes.
    private static func guidance(for failure: ShareRedemptionFailure) -> String {
        switch failure {
        case .malformed:
            // `400 invalid_request` is close to unreachable FROM THIS SCREEN —
            // `InviteCodeEntry.sanitize` upper-cases, strips to `[A-Z0-9]` and
            // clamps to six before anything is submitted, so the client cannot
            // normally build a body the server calls malformed. It stays a
            // distinct line because the server distinguishes it, and because the
            // day a link, a paste route or a normalization change does produce
            // one, "check the characters" is the right instruction and "ask for a
            // new code" is not.
            "Check the six characters against the ones the owner sent."
        case .invalidOrExpired:
            // THE 404, i.e. James's case — and the one the server deliberately
            // collapses. It enumerates with a hedge and asserts nothing: "may
            // have" is load-bearing, because unknown / expired / already used /
            // revoked all arrive here identically. Both halves name an action:
            // re-check what you typed, or go and get a fresh code.
            "It may have expired or already been used. Ask the owner to send you a new code."
        case .alreadyHasAccess:
            // `409` — nothing went wrong and nothing is owed. Say where the car
            // already is rather than offering a retry that would 409 again.
            "That Tesla is already in your vehicles \u{2014} there\u{2019}s nothing left to do."
        case .tooManyAttempts:
            // `429` — the code is not the problem, so the guidance must not send
            // the rider off to ask for a different one. Every attempt counts
            // (successes included), so retyping immediately only spends another.
            "Nothing is wrong with the code. Try it again in a minute."
        case .unavailable:
            // `401` / transport / `5xx` — NOT a verdict on the code, so it must
            // not read as one. Same "right now" grammar the rest of the app uses
            // for a degradation something is still trying underneath.
            "We couldn\u{2019}t reach the server. Try again in a moment."
        }
    }
}
