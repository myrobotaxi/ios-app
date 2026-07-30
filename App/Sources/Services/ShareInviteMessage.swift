import Foundation

// MARK: - Share-invite payload (MYR-340 → MYR-346 → MYR-359)
//
// TestFlight, Jul 30: the branded invite card never appears in the thread.
//
// MYR-340 made the handout a mini-onboarding paragraph; MYR-346 gave the code an
// address and moved that link to the front of the paragraph so the FIRST link in
// the body would be the one platforms preview. That was the right ordering and
// still produced no card, because iMessage's rule is not "preview the first
// link" — it is "a message that is NOTHING BUT a link becomes a rich link".
// Steps, a bare code and an expiry sentence wrapped around the URL are exactly
// what disqualifies it: the recipient sees a wall of text with a blue link in
// it, which is the state the client reported.
//
// So the payload is now the URL and nothing else. Nothing is lost by that,
// because everything the paragraph said is said by the link itself:
//
//  • a phone WITH the app never reads prose — the AASA hands `/join/{CODE}`
//    straight to `InviteLinkRouting`, the code lands prefilled and submits
//    itself (MYR-346);
//  • a phone WITHOUT the app lands on the branded page at the other end, which
//    shows the code, a copy button, the TestFlight button and the same three
//    steps, server-rendered.
//
// The paragraph was a worse copy of that page, delivered as text.

/// Where the app is distributed from — the ONE place the public build link
/// lives, so a Settings row, a future onboarding screen or an operator quoting
/// it can never disagree about where the build comes from.
enum AppDistribution {

    /// The PUBLIC TestFlight join link (App Store Connect ⇢ TestFlight ⇢ the
    /// **Friends & Family** external group, public link enabled 2026-07-29).
    ///
    /// **No longer part of the share payload** (MYR-359). It is carried by the
    /// invite's own landing page, which is where a recipient without the app
    /// arrives anyway — and where the button can say what it is next to the code
    /// and the steps. Quoting it in the message was what made the message more
    /// than a link, and a message that is more than a link renders no card.
    ///
    /// Two facts about the link that survive the demotion, because the landing
    /// page inherits both: it is CAPPED AT 100 TESTERS (when the Friends &
    /// Family group fills, the link refuses new joins and nothing on either side
    /// can detect it), and it routes through a public beta build, so a recipient
    /// may land on "this beta isn't accepting new testers".
    ///
    /// Kept here rather than deleted so the fact has one home in this client;
    /// `ShareInviteMessageTests` asserts it is ABSENT from the payload, which is
    /// what keeps the demotion from quietly reversing.
    static let testFlightPublicJoinURL = "https://testflight.apple.com/join/uarZRUbg"

    /// The invite's own web address. Defined by ``InviteLink`` — the same type
    /// the incoming universal-link parser uses — so the link this app HANDS OUT
    /// and the link this app ACCEPTS are one definition rather than two strings
    /// that agree today.
    static func inviteJoinURL(code: String, from ownerFirstName: String? = nil) -> String {
        InviteLink.url(code: code, from: ownerFirstName)
    }
}

/// Builds what the owner actually hands a recipient through the system share
/// sheet: **one URL, and nothing else.**
///
/// Its own type, not a method on a view, because BOTH share paths present the
/// same sheet (a fresh create and a §7.5.4 resend, which mints a new code and
/// kills the old one) and a payload that drifted between them would hand half
/// the recipients a card and half a wall of text.
enum ShareInviteMessage {

    /// The share-sheet item.
    ///
    /// - Parameters:
    ///   - code: the server-minted 6-character code. A LIVE BEARER CREDENTIAL
    ///     for vehicle access (§7.5, P1) — never logged.
    ///   - ownerFirstName: the signed-in owner's first name when the account
    ///     actually carries one (`UserProfile.firstName`), otherwise `nil`.
    ///
    /// The name travels as the `?from=` query parameter, which the landing page
    /// turns into "{Name} invited you to ride their Tesla" in the OG title and
    /// the page heading. `nil` — or anything that does not survive
    /// ``InviteLink/inviterName(_:)`` — omits the parameter entirely rather than
    /// sending an empty one, so the page falls back to its generic copy instead
    /// of rendering a sentence with a hole in it. That is the same two-grammar
    /// rule the paragraph used to implement in Swift; it now lives on the page,
    /// where the recipient actually reads it.
    ///
    /// A `URL`, not a `String`, because it is handed to `UIActivityViewController`
    /// as a URL activity item. Messages treats a URL item as the message's whole
    /// subject and renders the rich card; a string item — even a string that IS
    /// a URL — is text that happens to contain a link.
    static func shareURL(code: String, ownerFirstName: String?) -> URL {
        URL(string: InviteLink.url(code: code, from: ownerFirstName)) ?? InviteLink.landingURL
    }
}
