import Foundation

// MARK: - Share-invite message (MYR-340)
//
// TestFlight, Jul 29: "Feels strange just sending a text message, where do they
// go. I feel like we need to include TestFlight link or something. Or can we
// send an invite via email?"
//
// MYR-184 shipped the handout as one line — "Join my Tesla on MyRoboTaxi — code
// RBO246" — and that line was written when it was TRUE that there was nowhere to
// send anyone: no web surface, no public build. The recipient was handed a
// credential and no way to spend it. The public TestFlight link went live on
// 2026-07-29, so the honest message is now a MINI-ONBOARDING: where the app
// comes from, how to sign in, and the code to type, in the order the recipient
// does them.
//
// EMAIL needs no server. The client asked for it as an alternative delivery
// channel, but the same system share sheet already reaches Mail — the gap was
// never the transport, it was that the message said nothing. Nothing here is
// email-specific, and no email infrastructure is added.

/// Where the app is distributed from — the ONE place the public build link
/// lives, so a message, a Settings row, or a future onboarding screen can never
/// quote different URLs.
enum AppDistribution {

    /// The PUBLIC TestFlight join link (App Store Connect ⇢ TestFlight ⇢ the
    /// **Friends & Family** external group, public link enabled 2026-07-29).
    ///
    /// Two facts about this link that a caller has to plan around:
    ///
    ///  • It is CAPPED AT 100 TESTERS. When the group fills, the link starts
    ///    refusing new joins and every invite message quoting it becomes a dead
    ///    end for anyone who has not already installed. The cap is App Store
    ///    Connect's, not ours, and nothing in the client can detect that it has
    ///    been hit — raising it means a larger external group or the App Store.
    ///  • It routes through a public beta build, so a recipient may land on
    ///    "this beta isn't accepting new testers" rather than on the app. That
    ///    is a server-side state we cannot pre-flight from here.
    ///
    /// Plain `https` — Messages and Mail both auto-detect a bare https string
    /// and render it tappable, so no `LPLinkMetadata`/`NSItemProvider` preview
    /// infrastructure is involved on our side.
    ///
    /// MYR-346 — it is no longer the message's LEADING link. It is now the
    /// fallback step, for a recipient who does not have the app: the invite's own
    /// address (``InviteLink/url(code:)``) leads, because that is the URL that
    /// renders the card and that a phone with the app installed opens directly.
    /// This link is still load-bearing and still capped, so both facts above
    /// still apply — a full Friends & Family group breaks the no-app path
    /// exactly as before.
    static let testFlightPublicJoinURL = "https://testflight.apple.com/join/uarZRUbg"

    /// The invite's own web address. Defined by ``InviteLink`` — the same type
    /// the incoming universal-link parser uses — so the link this app HANDS OUT
    /// and the link this app ACCEPTS are one definition rather than two strings
    /// that agree today.
    static func inviteJoinURL(code: String) -> String { InviteLink.url(code: code) }
}

/// Composes the text the owner hands a recipient through the system share sheet.
///
/// Its own type, not a method on a view, because BOTH share paths present the
/// same sheet (a fresh create and a §7.5.4 resend, which mints a new code and
/// kills the old one) and a message that drifted between them would hand half
/// the recipients an incomplete onboarding.
enum ShareInviteMessage {

    /// How long a minted code lasts. §7.5.4's resend "resets `expiresAt` to a
    /// full 7 days"; §7.5.1 mints on the same window.
    ///
    /// Stated in the message as a plain sentence rather than an absolute
    /// timestamp: the handout is composed at mint time and read whenever the
    /// recipient gets round to it, and a formatted date would need a timezone
    /// the sender cannot know. "Expires in 7 days" is true when it is written
    /// and self-evidently relative when it is read.
    static let expiryDays = 7

    /// The share-sheet body.
    ///
    /// - Parameters:
    ///   - code: the server-minted 6-character code. A LIVE BEARER CREDENTIAL
    ///     for vehicle access (§7.5, P1) — never logged.
    ///   - ownerFirstName: the signed-in owner's first name when the account
    ///     actually carries one (`UserProfile.firstName`), otherwise `nil`.
    ///
    /// `nil` is a REAL case, not a defensive branch: Apple hands back a name
    /// only on the FIRST authorization, and a row created before native sign-in
    /// may carry none at all (see `UserProfile`). So the greeting has two
    /// grammars rather than one with a hole in it — the app never renders a
    /// sentence with an empty name in it, the same rule the greeting hero and
    /// Settings already follow.
    static func compose(code: String, ownerFirstName: String?) -> String {
        let opening: String
        if let name = ownerFirstName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            opening = "\(name) shared their Tesla with you on MyRoboTaxi."
        } else {
            // First person, not "Someone" or "A friend": this arrives in a
            // thread the recipient already recognises the sender in, so the
            // sender IS the introduction.
            opening = "I shared my Tesla with you on MyRoboTaxi."
        }

        // MYR-346 — the JOIN LINK leads, alone on its own line directly under the
        // opening. Two reasons, and the ordering is doing both jobs at once:
        //
        //  • THE CARD. Messages, Mail, WhatsApp and Slack all build their
        //    preview from a link in the body, and with more than one they take
        //    the FIRST. Putting the join link first is what makes the thread show
        //    the branded card for this invite instead of TestFlight's generic
        //    "Join the beta" tile — which is what the recipient saw before, and
        //    which said nothing about whose car or which app.
        //  • THE TAP. On a phone that already has the app, this URL IS the
        //    invite: the AASA hands it straight to `InviteLinkRouting`, the code
        //    lands in the field prefilled and submits itself, and steps 2–4 are
        //    never read at all. The steps exist for the phone that does NOT have
        //    the app, where the same URL renders a web page that says the same
        //    four things.
        //
        // The TestFlight link stays, demoted to the no-app step. It is still the
        // only way to get the build, so removing it would strand exactly the
        // recipient this message was rewritten for in MYR-340.
        //
        // The CODE still sits alone on its own line, separated top and bottom.
        // The link makes it unnecessary in the common case, not obsolete: a
        // recipient reading this on a laptop, or forwarding it, or arriving after
        // the app is already installed and signed in, transcribes it by hand.
        return """
        \(opening)

        \(AppDistribution.inviteJoinURL(code: code))

        1. Open the link above
        2. No app yet? Get it here: \(AppDistribution.testFlightPublicJoinURL)
        3. Sign in with Apple
        4. Enter this invite code:

        \(code)

        The code expires in \(expiryDays) days.
        """
    }
}
