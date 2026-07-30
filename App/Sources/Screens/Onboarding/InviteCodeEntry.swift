import Foundation

// MARK: - InviteCodeEntry (MYR-344)
//
// The six-cell invite entry's input rules, lifted out of `InviteCodeFlow`'s
// `onChange` so that PASTE and TYPING cannot diverge.
//
// THE CLIENT'S ASK (TestFlight, Jul 29): *"No option for me to paste the code
// here."* The code arrives in a text message — the one place nobody wants to
// transcribe six characters from — and the entry accepted keystrokes only.
//
// TWO rules, not one, because the two inputs are genuinely different:
//
//   • `sanitize` is the KEYSTROKE rule, the prototype's verbatim
//     (onboarding.jsx:426-430): uppercase, keep `[A-Z0-9]`, clamp to 6. Every
//     character the rider types is meant to be in the code, so stripping and
//     clamping is exactly right.
//
//   • `extractCode` is the PASTE rule. A pasted string is a piece of somebody
//     else's message, and applying the keystroke rule to it is wrong in a way
//     that looks right: "code: rbo246!" strips to "CODERBO246" and clamps to
//     **"CODERB"** — six plausible characters, none of them the code, submitted
//     automatically, rejected by the server. So paste finds the CANDIDATE first
//     and only then sanitizes it.
//
// `extractCode` never returns anything `sanitize` would alter: whatever it
// picks is already uppercase `[A-Z0-9]`, six characters or fewer.
enum InviteCodeEntry {
    /// jsx:409 — a code is six characters.
    static let length = 6

    /// The KEYSTROKE rule: uppercase, keep `[A-Z0-9]`, clamp to `length`.
    ///
    /// ASCII-only on purpose: `CharacterSet.alphanumerics` alone would admit
    /// Cyrillic "А" and full-width "Ａ", which look like the code the rider was
    /// sent and are not it — the server would reject them and the rider would
    /// have no way to see why.
    static func sanitize(_ raw: String) -> String {
        String(
            raw.uppercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
                .prefix(length)
                .map(Character.init)
        )
    }

    /// The PASTE rule: find the six-character `[A-Z0-9]` candidate in an
    /// arbitrary pasted string.
    ///
    /// Three passes, in this order, because the order is what makes the common
    /// pastes land:
    ///
    ///  1. **By line.** `ShareInviteMessage.compose` (MYR-340) deliberately puts
    ///     the code ALONE on its own line, so a rider who copies the whole message
    ///     — the most likely thing to happen, since selecting six characters
    ///     inside a text bubble is precisely the chore this issue is about — is
    ///     resolved by the message's own shape. A line-first pass is also what
    ///     keeps that case honest: pass 2 on the full message would hand back
    ///     "THOMAS", the first six-letter word in the opening line.
    ///  2. **By token.** Split on everything that is not `[A-Z0-9]` and take the
    ///     first run of exactly six — the client's own "code: rbo246!" shape,
    ///     where the code shares a line with a label.
    ///  3. **The keystroke rule.** Whatever is left is treated as if it had been
    ///     typed, which fills the cells partially for a short paste ("rbo24") and
    ///     clamps a long unbroken one.
    ///
    /// Returns "" when there is nothing `[A-Z0-9]` in the string at all; the
    /// caller says so rather than silently doing nothing.
    static func extractCode(from raw: String) -> String {
        let upper = raw.uppercased()

        // 1 — a line that IS the code.
        let lines = upper.split(whereSeparator: \.isNewline)
            .map { strip(String($0)) }
            .filter { $0.count == length }
        if let pick = preferred(lines) { return pick }

        // 2 — a six-character run somewhere inside a line.
        let tokens = upper.split { !isCodeCharacter($0) }
            .map(String.init)
            .filter { $0.count == length }
        if let pick = preferred(tokens) { return pick }

        // 3 — treat it as typing.
        return sanitize(upper)
    }

    /// Which of several six-character candidates is the CODE.
    ///
    /// English is full of six-letter words, and they sit in exactly the sentences
    /// codes are handed over in — "your INVITE code is rbo246" offers two
    /// candidates and the wrong one comes first. The tell is that codes are
    /// generated, not written: every code the server has ever minted mixes letters
    /// and digits (RBO246, ZKQ913, ABC123), and no word does. So a mixed candidate
    /// wins, then a digit-bearing one; only if every candidate is pure letters
    /// does position decide, and then it is the LAST — because the code is what
    /// the sentence was building up to ("your invite code is ABCDEF").
    ///
    /// The format is the server's, not ours (§7.5 says only "6-character code"),
    /// so this ORDERS candidates and never REJECTS one: an all-letter code still
    /// resolves, it just falls through to the positional rule.
    private static func preferred(_ candidates: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        if let mixed = candidates.first(where: {
            $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter)
        }) { return mixed }
        if let numeric = candidates.first(where: { $0.contains(where: \.isNumber) }) {
            return numeric
        }
        return candidates.last
    }

    /// Whether a sanitized value is submittable — the same test the 6th keystroke
    /// makes, which is what a pasted full code must be indistinguishable from.
    static func isComplete(_ value: String) -> Bool {
        value.count == length
    }

    // MARK: -

    private static func isCodeCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        return CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
    }

    /// `sanitize` without the clamp — used to measure a candidate before deciding
    /// it is one.
    private static func strip(_ raw: String) -> String {
        String(
            raw.uppercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
                .map(Character.init)
        )
    }
}
