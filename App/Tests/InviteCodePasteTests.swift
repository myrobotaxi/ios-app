import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-344 — pasting an invite code
//
// THE CLIENT'S ASK (TestFlight, Jul 29): "No option for me to paste the code
// here." The code arrives inside a text message, and the six-cell entry took
// keystrokes only.
//
// These pin the RULE, which is the part that can be silently wrong: a paste that
// fills the cells with six plausible-but-wrong characters and then auto-submits
// them is worse than no paste at all, because the rider watches their (correct)
// code get rejected. The UI test (`InviteCodePasteUITests`) pins that the
// affordance exists and that a complete paste submits itself.
final class InviteCodePasteTests: XCTestCase {

    // MARK: The keystroke rule (unchanged by this issue — jsx:426-430)

    func testTypingKeepsThePrototypesFilterExactly() {
        XCTAssertEqual(InviteCodeEntry.sanitize("rbo246"), "RBO246", "uppercased")
        XCTAssertEqual(InviteCodeEntry.sanitize("RBO246"), "RBO246")
        XCTAssertEqual(InviteCodeEntry.sanitize("rb o2-4 6"), "RBO246", "non-alphanumerics dropped")
        XCTAssertEqual(InviteCodeEntry.sanitize("RBO2467890"), "RBO246", "clamped to six")
        XCTAssertEqual(InviteCodeEntry.sanitize(""), "")
    }

    /// The ASCII gate. Cyrillic "А" and full-width "Ａ" are alphanumeric to
    /// `CharacterSet`, and a rider who pasted them would watch a code that LOOKS
    /// exactly like theirs get rejected with no way to see why.
    func testLookalikeNonASCIICharactersAreNotCodeCharacters() {
        XCTAssertEqual(InviteCodeEntry.sanitize("\u{0410}BO246"), "BO246", "Cyrillic А dropped")
        XCTAssertEqual(InviteCodeEntry.sanitize("\u{FF21}BO246"), "BO246", "full-width Ａ dropped")
        XCTAssertEqual(InviteCodeEntry.sanitize("caf\u{00E9}"), "CAF")
    }

    func testCompletenessIsExactlySixCharacters() {
        XCTAssertTrue(InviteCodeEntry.isComplete("RBO246"))
        XCTAssertFalse(InviteCodeEntry.isComplete("RBO24"))
        XCTAssertFalse(InviteCodeEntry.isComplete(""))
    }

    // MARK: The paste rule

    func testACleanCodePastesAsItself() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "RBO246"), "RBO246")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "rbo246"), "RBO246")
    }

    /// Copying out of a message bubble almost always brings whitespace with it.
    func testSurroundingWhitespaceAndNewlinesAreIgnored() {
        for raw in ["  RBO246  ", "\nRBO246\n", "RBO246\r\n", "\tRBO246"] {
            XCTAssertEqual(InviteCodeEntry.extractCode(from: raw), "RBO246", "for \(raw.debugDescription)")
        }
    }

    /// The client's own shape. A plain character strip would produce "CODERB"
    /// here — six characters, none of them the code, auto-submitted.
    func testTheCodeIsFoundWhenItSharesALineWithALabel() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "code: rbo246!"), "RBO246")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "Code RBO246"), "RBO246")
        XCTAssertNotEqual(InviteCodeEntry.extractCode(from: "code: rbo246!"), "CODERB")
    }

    /// Six-letter English words sit in exactly the sentences codes are handed over
    /// in. "INVITE" is a candidate of precisely the same shape as the code, and it
    /// comes FIRST — so position alone cannot decide this; the letters-plus-digits
    /// shape of a generated code is what does.
    func testASixLetterWordInTheSameSentenceIsNotMistakenForTheCode() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "your invite code is rbo246."), "RBO246")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "Thomas shared RBO246 with you"), "RBO246")
    }

    /// The format is the server's, not the client's (§7.5 says only "6-character
    /// code"), so an all-letter code must still resolve — it just falls through to
    /// the positional rule instead of the shape one.
    func testAnAllLetterCodeStillResolves() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "your invite code is abcdef"), "ABCDEF")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "ABCDEF"), "ABCDEF")
    }

    /// The likeliest paste of all, and MYR-359 changed what it is: the recipient
    /// copies the LINK out of the thread, because the message is now nothing but
    /// that link. Both grammars — with and without the `?from=` name — resolve to
    /// the code in the path.
    func testPastingTheSharedInviteLinkFindsTheCode() {
        let named = ShareInviteMessage.shareURL(code: "RBO246", ownerFirstName: "Thomas")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: named.absoluteString), "RBO246")

        let anonymous = ShareInviteMessage.shareURL(code: "ZKQ913", ownerFirstName: nil)
        XCTAssertEqual(InviteCodeEntry.extractCode(from: anonymous.absoluteString), "ZKQ913")
    }

    /// The link is read STRUCTURALLY, not scanned. On `?from=Thomas` the token
    /// pass sees two six-character candidates and picks the code only because
    /// codes usually mix letters and digits — an ALL-LETTER code would lose that
    /// coin toss and paste the sender's name into the field. Pass 0 never has the
    /// question: the code is the path segment.
    func testAnAllLetterCodeInALinkIsNotConfusedWithTheSendersName() {
        let url = ShareInviteMessage.shareURL(code: "ABCDEF", ownerFirstName: "Thomas")
        XCTAssertEqual(url.absoluteString, "https://myrobotaxi.app/join/ABCDEF?from=Thomas")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: url.absoluteString), "ABCDEF")
    }

    /// A link pasted the way people actually paste — with a sentence around it,
    /// or with the trailing punctuation of the sentence it was written into.
    func testALinkSurroundedByProseOrPunctuationStillResolves() {
        XCTAssertEqual(
            InviteCodeEntry.extractCode(from: "here you go https://myrobotaxi.app/join/RBO246?from=Thomas"),
            "RBO246"
        )
        XCTAssertEqual(
            InviteCodeEntry.extractCode(from: "join at https://myrobotaxi.app/join/rbo246."),
            "RBO246"
        )
    }

    /// MYR-368 — THE VECTOR. The link the recipient now copies out of the thread
    /// is the SERVER's signed one, and pass 0 reads its code out of the path.
    ///
    /// This is the paste that would go worst without pass 0. The token pass would
    /// see the 86-character signature split into runs by its own `_` and `-`
    /// characters, plus "RBO246", "Alex" and "Mira" — and it picks the first
    /// SIX-character run that mixes letters and digits, which anywhere inside a
    /// base64url blob is a coin toss it has no business taking. Reading the path
    /// never has the question.
    func testPastingTheFullSignedLinkFindsTheCode() {
        let signed = "https://myrobotaxi.app/join/RBO246?k=1.1785942245.fPkcqmLr2p_HezqZtbP6J1NC-jQA0nAOp7hiFqTKZHo9L2YGVkNDx162VsdromPEMSZaMvMhxRCBS_xfaRw0BQ&from=Alex&to=Mira"
        XCTAssertEqual(InviteCodeEntry.extractCode(from: signed), "RBO246")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "  \(signed)\n"), "RBO246")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "here you go \(signed)"), "RBO246")
        XCTAssertEqual(
            InviteCodeEntry.extractCode(from: signed.lowercased()), "RBO246",
            "a client that lower-cased the link on the way through"
        )
        // Extracted values are keystroke-clean, so a complete paste submits on the
        // same beat as the 6th keystroke rather than being rewritten first.
        XCTAssertEqual(InviteCodeEntry.sanitize(InviteCodeEntry.extractCode(from: signed)), "RBO246")
    }

    /// The proof that pass 0 is load-bearing and not a shortcut: an ALL-LETTER
    /// code inside a signed link. Every later pass ranks candidates by "mixes
    /// letters and digits", which this code loses by definition — and the signed
    /// link supplies a great many candidates that win it.
    func testAnAllLetterCodeSurvivesASignedLinkFullOfLookalikeCandidates() {
        let signed = "https://myrobotaxi.app/join/ABCDEF?k=1.1785942245.fPkcqmLr2p_HezqZtbP6J1NC-jQA0nAOp7hiFqTKZHo9L2YGVkNDx162VsdromPEMSZaMvMhxRCBS_xfaRw0BQ&from=Alex&to=Mira"
        XCTAssertEqual(InviteCodeEntry.extractCode(from: signed), "ABCDEF")
    }

    /// A link that is not ours falls through to the ordinary passes rather than
    /// being trusted — pass 0 is a fast path for a known shape, not a rule that
    /// any URL contains a code.
    func testALinkOnAnotherHostIsNotTreatedAsAnInviteLink() {
        XCTAssertEqual(
            InviteCodeEntry.extractCode(from: "https://evil.example/join/HACKED code: RBO246"),
            "RBO246"
        )
    }

    /// Separators inside the code itself — how a code gets read aloud and retyped
    /// by a human relaying it.
    func testASeparatedCodeOnOneLineIsRejoined() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "RBO 246"), "RBO246")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "12-34-56"), "123456")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "r.b.o.2.4.6"), "RBO246")
    }

    func testALongUnbrokenPasteIsClampedAndAShortOnePartiallyFills() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "ABCDEFGH"), "ABCDEF")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "rbo24"), "RBO24")
    }

    /// Nothing to paste. The screen says so quietly rather than shaking (nothing
    /// was rejected) or doing nothing at all (which reads as a broken button).
    func testAPasteWithNoCodeCharactersExtractsNothing() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: ""), "")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "   "), "")
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "!!! — …"), "")
    }

    /// Every value the paste rule can return is already keystroke-clean, so the
    /// `onChange` filter it flows through can never alter it — which is what makes
    /// a pasted complete code submit on the same beat as the 6th keystroke instead
    /// of being rewritten first.
    func testExtractedCodesAreAlreadyKeystrokeClean() {
        let pastes = [
            "RBO246", "rbo246", "  RBO246  ", "code: rbo246!", "RBO 246", "12-34-56",
            "ABCDEFGH", "rbo24", "", "!!!",
            ShareInviteMessage.shareURL(code: "RBO246", ownerFirstName: "Thomas").absoluteString,
            ShareInviteMessage.shareURL(code: "RBO246", ownerFirstName: nil).absoluteString,
        ]
        for paste in pastes {
            let extracted = InviteCodeEntry.extractCode(from: paste)
            XCTAssertEqual(
                InviteCodeEntry.sanitize(extracted), extracted,
                "the keystroke filter must be a no-op on \(paste.debugDescription) → \(extracted)"
            )
            XCTAssertLessThanOrEqual(extracted.count, InviteCodeEntry.length)
        }
    }
}
