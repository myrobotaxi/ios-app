@testable import MyRoboTaxi
import MyRoboTaxiKit
import XCTest

// MARK: - MYR-465 — an expired invite code produces no UI response at all
//
// External beta, build `202608030843`, James Guan (rider): *"When code expired,
// there is no response or notification on UI side telling me the info"*.
//
// THE CAUSE IS ONE ASSIGNMENT. `InviteCodeFlow.submit` split its refusals two
// ways — the ones that CLEAR the entry got `shakes += 1; code = ""; refusal =
// nil`, and everything else got a line of copy. So `400 malformed` and, critically,
// the `404` that stands for unknown / EXPIRED / already-used / revoked were
// answered with a 0.4s wobble and nothing else, with the state that could have
// carried words explicitly set back to `nil`.
//
// And under Reduce Motion there was no wobble either: `Shake` renders its content
// unchanged there, on a comment promising that "validation feedback stays visible
// via state" — the very state this branch had just erased. **A fallback that
// points at state nobody set is indistinguishable from no fallback at all.**
//
// These pin the RULE. Only a running app can show the screen consults it, which
// is what `InviteCodeRefusalUITests` (scene `riderInviteExpired`) is for.
final class InviteCodeRefusalTests: XCTestCase {

    private static let all: [ShareRedemptionFailure] = [
        .malformed, .invalidOrExpired, .alreadyHasAccess, .tooManyAttempts, .unavailable,
    ]

    // MARK: The defect

    /// THE RESTORATION GUARD. Every refusal — including the two that shake and
    /// clear the entry, which are the ones that said nothing — resolves to words.
    ///
    /// Restore the defect (`refusal = nil` on the clearing branch, or a `guard
    /// !clearsEntry` in `notice(for:)`) and the two arms below go silent again.
    func testEveryRefusalSaysSomething() {
        for failure in Self.all {
            let notice = InviteCodeRefusal.notice(for: failure)
            XCTAssertFalse(notice.headline.isEmpty, "\(failure) must state what happened")
            XCTAssertFalse(notice.guidance.isEmpty, "\(failure) must state what to do")
        }
    }

    /// The two that were silent, named. A shake is an ADDITION to the words now,
    /// never a substitute for them — so the failures that shake are exactly the
    /// failures that clear, and both still carry a notice.
    func testTheFailuresThatShakeStillCarryTheirWords() {
        for failure in [ShareRedemptionFailure.malformed, .invalidOrExpired] {
            let notice = InviteCodeRefusal.notice(for: failure)
            XCTAssertTrue(notice.shakes, "\(failure) is about the code, so it shakes")
            XCTAssertTrue(notice.clearsEntry)
            XCTAssertFalse(notice.headline.isEmpty, "\(failure) shook AND said nothing — the reported defect")
            XCTAssertFalse(notice.guidance.isEmpty)
        }
    }

    /// And the three that never shook keep not shaking. A shake claims the CODE is
    /// wrong, which is false of the rate limit ("nothing is wrong with it, wait")
    /// and of "you already have access" (they are in).
    func testTheRefusalsThatAreNotAboutTheCodeNeitherShakeNorClear() {
        for failure in [ShareRedemptionFailure.alreadyHasAccess, .tooManyAttempts, .unavailable] {
            let notice = InviteCodeRefusal.notice(for: failure)
            XCTAssertFalse(notice.shakes, "\(failure) is not a claim about the code")
            XCTAssertFalse(notice.clearsEntry)
        }
    }

    // MARK: One grammar, not two

    /// The headline and the clear/shake decision are DELEGATED verbatim to the
    /// §7.5.5 catalog's own properties rather than re-stated here, so this screen
    /// and any other consumer cannot drift into two vocabularies for one answer.
    func testTheNoticeDelegatesRatherThanRestates() {
        for failure in Self.all {
            let notice = InviteCodeRefusal.notice(for: failure)
            XCTAssertEqual(notice.headline, failure.riderMessage)
            XCTAssertEqual(notice.clearsEntry, failure.clearsEntry)
        }
    }

    // MARK: What the server distinguishes, and only that

    /// **THE CLIENT DISTINGUISHES EXACTLY WHAT THE SERVER DISTINGUISHES.** Five
    /// statuses, five distinct action lines — including `400` vs `404`, which
    /// MYR-184 rendered identically because both cleared the entry.
    func testEveryStatusTheServerTellsApartGetsItsOwnGuidance() {
        let lines = Set(Self.all.map { InviteCodeRefusal.notice(for: $0).guidance })
        XCTAssertEqual(lines.count, Self.all.count, "one line per status §7.5.5 emits")
    }

    /// **AND NOT ONE STATE MORE.** MYR-465 asks for expired / already used /
    /// revoked / unknown as four states; §7.5.5 answers all four with an identical
    /// `404` body ON PURPOSE — the code space is 36^6 and this is the only
    /// rider-facing endpoint, so a body that named the cause would make the join
    /// page an oracle. §7.5.0 says the same of a revoked grant in as many words.
    ///
    /// So the 404's copy ENUMERATES with a hedge and asserts nothing. This is the
    /// guard against a later round "improving" it into a claim the wire cannot
    /// support — the client would be guessing out loud on three riders in four.
    func testTheCollapsed404NamesPossibilitiesAndAssertsNone() {
        let notice = InviteCodeRefusal.notice(for: .invalidOrExpired)
        let sentence = "\(notice.headline) \(notice.guidance)".lowercased()
        XCTAssertTrue(sentence.contains("may have"), "hedged, because the server does not say which")
        XCTAssertTrue(sentence.contains("expired"), "names the likeliest cause the rider can act on")
        XCTAssertTrue(sentence.contains("already been used"), "and the other one")
        // The headline itself still commits to nothing — the §7.5.5 catalog's own
        // rule (`VehicleSharingTests` sweeps it), restated here so a copy pass on
        // this screen cannot move a cause into it.
        XCTAssertFalse(notice.headline.lowercased().contains("expired"))
    }

    /// The rate limit must never send the rider off to ask for a different code:
    /// every attempt counts (successes included), so a fresh code spends another.
    func testTheRateLimitDoesNotSendTheRiderForANewCode() {
        let notice = InviteCodeRefusal.notice(for: .tooManyAttempts)
        XCTAssertFalse(notice.guidance.lowercased().contains("new code"))
        XCTAssertTrue(notice.guidance.lowercased().contains("minute"))
    }

    /// An unreachable server is NOT a verdict on the code, so its line must not
    /// read as one — the same rule the catalog's own `.unavailable` message keeps.
    func testAnUnreachableServerIsNotAVerdictOnTheCode() {
        let notice = InviteCodeRefusal.notice(for: .unavailable)
        let sentence = "\(notice.headline) \(notice.guidance)".lowercased()
        XCTAssertFalse(sentence.contains("invalid"))
        XCTAssertFalse(sentence.contains("expired"))
        XCTAssertFalse(sentence.contains("wrong"))
    }
}
