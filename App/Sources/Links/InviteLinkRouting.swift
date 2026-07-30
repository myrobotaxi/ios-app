import Foundation

// MARK: - What a `/join/{CODE}` universal link means to a running app (MYR-346)
//
// An invite used to travel as SIX CHARACTERS and nothing else: the recipient
// read them out of a text message and retyped them into the six-cell field.
// MYR-340 wrapped those characters in a mini-onboarding; this issue gives them
// an ADDRESS — `https://myrobotaxi.app/join/{CODE}` — a branded web page that
// renders an OG card in the thread and, on a phone that already has the app,
// hands the code straight to it.
//
// Everything here is PURE, for the same reason `PushNotificationRouting` is: the
// whole matrix (which URLs are ours, which codes survive sanitisation, and where
// each one lands given what is on screen) is decided by functions that take
// values and return values, so the tests ARE the matrix. No `UIApplication`, no
// `NSUserActivity`, no screens. The impure half — receiving the activity and
// applying the route — is `InviteLinkBridge` + `RootView`.
//
// TWO RULES SHAPE ALL OF IT:
//
//   1. AN UNRECOGNISED LINK IS NOT AN ERROR. The AASA will claim every path
//      under `/join/*`, and the web surface will grow paths we know nothing
//      about. Anything this file cannot resolve to a well-formed code resolves
//      to `.ignore`, and `RootView` then does NOTHING — the app opens normally,
//      exactly as if the user had launched it from the home screen. It never
//      shows an error for a link, because a link the app cannot use is the
//      WEB's job to render, not the app's.
//
//   2. A LINK NEVER STOMPS WORK IN PROGRESS. A code is worth 7 days; a
//      half-finished ride request, an incoming request waiting on an Accept, or
//      a tutorial someone is three cards into is worth the next 30 seconds.
//      So the route is allowed to say "hold this" — `.awaitSignIn` /
//      `.awaitIdle` — and `RootView` keeps the code and re-asks every time the
//      shell changes. Push (MYR-186) DROPS a tap that arrives at the wrong
//      moment, on the reasoning that its cold-launch refetch reaches the same
//      state anyway. An invite code has no refetch: nothing else in the system
//      will ever produce it again, so dropping it loses it for good.

/// The `https://myrobotaxi.app/join/{CODE}` link — the ONE place the shape of
/// that URL is written down, so the composer that mints it (`ShareInviteMessage`)
/// and the parser that consumes it can never drift apart.
enum InviteLink {

    /// The associated domain. Must match the `applinks:` entry in the target's
    /// entitlement (`project.yml`) and the domain serving the AASA — three places
    /// that have to agree for a link to reach the app at all.
    static let host = "myrobotaxi.app"

    /// The single path component the AASA claims (`components: /join/*`).
    static let pathComponent = "join"

    /// §7.5.1 mints exactly six characters.
    static let codeLength = 6

    /// Compose the shareable link for a minted code.
    ///
    /// The code is a LIVE BEARER CREDENTIAL (§7.5, P1) and this puts it in a URL,
    /// which is a place credentials leak from — referrer headers, browser
    /// history, link previews fetched by a platform's crawler. That is an
    /// accepted trade and not a new one: the code already travels in the clear
    /// through Messages, and the page behind this URL performs no redemption on
    /// its own. Redemption still requires a signed-in account POSTing to §7.5.5,
    /// so possession of the link is exactly as powerful as possession of the six
    /// characters was — no more.
    static func url(code: String) -> String {
        "https://\(host)/\(pathComponent)/\(code)"
    }

    /// Pull a well-formed invite code out of an incoming universal link, or
    /// `nil` if this URL is not one of ours.
    ///
    /// Strict about the ENVELOPE, forgiving about the CODE:
    ///
    ///  • the scheme must be `https` and the host exactly ``host`` — a universal
    ///    link can only ever arrive over https on a claimed domain, so anything
    ///    else is a URL that reached us by some other route and has no business
    ///    redeeming anything;
    ///  • the path must be exactly `/join/{something}` — not `/join`, not
    ///    `/join/A/B`. A deeper path is a web surface we do not know about;
    ///  • the code segment is percent-decoded, upper-cased and stripped to
    ///    `[A-Z0-9]` (so `rbo246`, `RBO-246` and `rbo%20246` all arrive as
    ///    `RBO246` — the same normalisation `RestClient.normalizedInviteCode`
    ///    applies before POSTing), and must then be EXACTLY ``codeLength``.
    ///
    /// The length check is what makes this safe to auto-submit. The entry field
    /// submits on the 6th character because six characters is the whole code;
    /// a link is held to the same bar, so a truncated or padded link can never
    /// spend one of the rider's 10-attempts-per-minute (§7.5.5) on a code the
    /// client could see was wrong.
    static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard url.host()?.lowercased() == host else { return nil }

        // `pathComponents` yields ["/", "join", "CODE"]; a trailing slash adds
        // nothing (Foundation drops it), so this is the exact shape we want.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0].lowercased() == pathComponent else { return nil }

        return sanitize(parts[1])
    }

    /// Upper-case, keep only `[A-Z0-9]`, and require exactly ``codeLength``.
    /// Mirrors `RestClient.normalizedInviteCode` plus the field's own `prefix(6)`
    /// — except that this one REJECTS a wrong length rather than truncating,
    /// because a link is machine-written and a wrong length means it was not
    /// written by us.
    static func sanitize(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        let stripped = decoded
            .uppercased()
            .unicodeScalars
            .filter { $0.isASCII && (CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0)) }
            .map(Character.init)

        guard stripped.count == codeLength else { return nil }
        return String(stripped)
    }
}

// MARK: - Context

/// What the app is showing, reduced to the two facts the routing decision needs.
/// Assembled from state that ALREADY exists in `RootView`; holds nothing of its
/// own and is never a source of truth — the same contract `PushSurfaceContext`
/// has.
struct InviteLinkContext: Equatable {

    /// The shell on screen.
    ///
    /// This is ALSO the app's signed-in state, deliberately. `RootView` never
    /// asks `session.isSignedIn` when it routes (`applyPushTapRoute` guards on
    /// `screen == .ownerHome`), and it must not start here: `SimulatedAuthSession
    /// .isSignedIn` is `false` in SIM until someone taps the button and is
    /// `false` in every DEBUG capture scene, all of which boot straight into a
    /// signed-in shell. The SCREEN is the one fact that is true on every path —
    /// `.signIn` / `.resolvingSession` mean "not through the door yet", and
    /// nothing else does.
    var screen: AppScreen

    /// The user is in the middle of something a screen swap would destroy — an
    /// incoming request awaiting an Accept, or a ride request past the idle
    /// sheet. Sourced from the ride-request service and the rider sheet phase,
    /// the same two places `PushSurfaceContext` reads.
    var isBusy: Bool

    init(screen: AppScreen, isBusy: Bool = false) {
        self.screen = screen
        self.isBusy = isBusy
    }
}

// MARK: - Route

/// Where an incoming `/join/{CODE}` link lands. Three of the four cases carry
/// the code, because the code is the whole payload and losing it is the one
/// failure this design refuses to have.
enum InviteLinkRoute: Equatable {

    /// Present `InviteCodeFlow` prefilled with this code and let it submit
    /// itself — the same path as typing the 6th character, so the redeem, the
    /// 1.3s verifying beat, the shake, the rate-limit line and the "you already
    /// have access" line are all the shipping ones. Nothing about the link gets
    /// its own success or failure UI.
    case presentPrefilledInvite(code: String)

    /// Nobody is signed in yet. Hold the code, run the normal sign-in, and
    /// re-ask once the shell settles. There is no invite-specific sign-in
    /// screen and no "you were invited" banner on the existing one: a link that
    /// changed the sign-in screen would be a link that changed what the app
    /// asks of a user before it has any idea whether the code is even valid.
    case awaitSignIn(code: String)

    /// Signed in, but mid-something. Hold the code and re-ask on every shell
    /// change until the moment is right.
    case awaitIdle(code: String)

    /// Not a link this app can spend. Open normally and say nothing.
    case ignore
}

enum InviteLinkRouting {

    /// Resolve an incoming universal link against what is on screen.
    static func route(url: URL, context: InviteLinkContext) -> InviteLinkRoute {
        guard let code = InviteLink.code(from: url) else { return .ignore }
        return route(code: code, context: context)
    }

    /// Resolve an already-sanitised code. Split out from ``route(url:context:)``
    /// so `RootView` can re-ask about a HELD code — which it does on every shell
    /// change — without keeping the original `URL` alive.
    static func route(code: String, context: InviteLinkContext) -> InviteLinkRoute {
        // A held code is re-asked about many times; re-validate rather than
        // trusting the caller, so a malformed value can never reach the field.
        guard let code = InviteLink.sanitize(code) else { return .ignore }

        if isPreAuth(context.screen) { return .awaitSignIn(code: code) }
        if context.isBusy { return .awaitIdle(code: code) }
        if !acceptsInviteNow(context.screen) { return .awaitIdle(code: code) }
        return .presentPrefilledInvite(code: code)
    }

    /// Before the door. Both of these resolve on their own — `.resolvingSession`
    /// into a shell or into `.signIn`, and `.signIn` into a shell once the user
    /// signs in — so holding here always terminates.
    private static func isPreAuth(_ screen: AppScreen) -> Bool {
        switch screen {
        case .resolvingSession, .signIn: return true
        default: return false
        }
    }

    /// Screens the invite flow may replace without destroying anything.
    ///
    /// `.emptyState` is in the list because it is a CHOICE screen whose two
    /// options are "add your Tesla" and "join with a code" — a join link is
    /// simply one of those options arriving from outside. `.inviteCode` is in it
    /// so a second link re-prefills the flow already up rather than being held
    /// behind it forever.
    ///
    /// Everything else is a flow with state in it: `.modeChooser` (an unanswered
    /// question), `.addTesla` (a live OAuth handoff), and the two tutorials
    /// (someone is partway through five cards). Those are held, not stomped.
    private static func acceptsInviteNow(_ screen: AppScreen) -> Bool {
        switch screen {
        case .ownerHome, .sharedHome, .emptyState, .inviteCode: return true
        case .resolvingSession, .signIn, .modeChooser, .addTesla, .ownerTutorial, .riderTutorial: return false
        }
    }
}
