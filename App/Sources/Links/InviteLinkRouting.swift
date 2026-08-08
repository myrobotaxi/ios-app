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
// MYR-453 — THERE ARE TWO CHANNELS NOW, AND ONLY ONE ROUTING MATRIX. A code can
// arrive as the `https://myrobotaxi.app/join/{CODE}` universal link or as the
// `myrobotaxi://join/{CODE}` app link, because iOS will not fire the former from
// a WKWebView-backed in-app browser and a tester's Telegram tap therefore reached
// the app with nothing to fill the cells. The difference lives ENTIRELY in
// `code(from:)`'s two envelope arms: both resolve to six sanitised characters and
// everything downstream — the route, the hold, the drain, the auto-submit — cannot
// tell them apart, which is the point. See `code(fromAppLink:)`.
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

    /// The app's own URL scheme — the SECOND channel a code can arrive on, and
    /// the reason MYR-453 exists (see ``code(fromAppLink:)``). Declared in
    /// `App/MyRoboTaxi-Info.plist` under `CFBundleURLTypes` — the additive plist,
    /// not `project.yml`, because `CFBundleURLTypes` has no `INFOPLIST_KEY_*`
    /// spelling. `InviteLinkSchemeTests` reads that plist and pins the two
    /// against each other: a scheme the app does not claim is a link iOS will
    /// not open, and nothing about that failure reaches this code.
    ///
    /// It was ALREADY registered, for the Tesla OAuth callbacks (§7.11/§7.12),
    /// which is why this issue adds no plist entry — only a listener.
    static let appScheme = "myrobotaxi"

    /// §7.5.1 mints exactly six characters.
    static let codeLength = 6

    /// The query parameter carrying the SENDER's first name (MYR-359), so the
    /// landing page can title itself "{Name} invited you to ride their Tesla".
    /// The page is the only consumer; nothing in the app reads it back (see
    /// ``code(from:)``).
    static let inviterQueryItem = "from"

    /// How much of a first name travels. Twenty letters is longer than any first
    /// name the heading has room for and short enough that the URL stays a URL —
    /// the cap exists so a pathological profile value cannot make the link
    /// unshareable, not because names are expected to reach it.
    static let inviterNameMaxLength = 20

    /// The codeless landing page. The one literal URL in this file, and the
    /// fallback for the (unreachable) case where a composed link will not parse.
    static let landingURL = URL(string: "https://\(host)/\(pathComponent)")!

    /// Compose the shareable link for a minted code, optionally naming the
    /// sender.
    ///
    /// The code is a LIVE BEARER CREDENTIAL (§7.5, P1) and this puts it in a URL,
    /// which is a place credentials leak from — referrer headers, browser
    /// history, link previews fetched by a platform's crawler. That is an
    /// accepted trade and not a new one: the code already travels in the clear
    /// through Messages, and the page behind this URL performs no redemption on
    /// its own. Redemption still requires a signed-in account POSTing to §7.5.5,
    /// so possession of the link is exactly as powerful as possession of the six
    /// characters was — no more.
    ///
    /// The NAME is a different kind of value and gets a different rule: it is
    /// rendered by a web page into an OG title that anyone the link is forwarded
    /// to can read, so it is filtered to letters here (``inviterName(_:)``) and
    /// filtered AGAIN, independently, by the page. Neither side trusts the
    /// other; the client's filter is what keeps a well-formed link from ever
    /// carrying junk, and the server's is what keeps a hand-edited one from
    /// rendering it.
    ///
    /// Built through `URLComponents` rather than by interpolation so the query
    /// is percent-encoded by Foundation. With a `[A-Za-z]`-only value that is a
    /// no-op today — which is the point: it stays correct if the rule ever
    /// loosens.
    static func url(code: String, from ownerFirstName: String? = nil) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(pathComponent)/\(code)"
        if let name = inviterName(ownerFirstName) {
            components.queryItems = [URLQueryItem(name: inviterQueryItem, value: name)]
        }
        return components.string ?? "https://\(host)/\(pathComponent)/\(code)"
    }

    /// The sender's first name as it may appear in a link, or `nil` when there
    /// is nothing safe to say.
    ///
    /// Strict on purpose. The value ends up in a page title that is scraped,
    /// cached by messaging apps and shown to people who were never sent the
    /// invite, so the question it asks is "is this PLAINLY A NAME?" — never
    /// "what can be salvaged from this":
    ///
    ///  • trimmed, and empty means absent (`UserProfile.firstName` is genuinely
    ///    `nil` for anyone Apple did not hand a name for on the FIRST
    ///    authorization — a real case, not a defensive branch);
    ///  • the input may contain ONLY letters and the punctuation names are
    ///    actually written with — space, hyphen, apostrophe, period. Anything
    ///    else (a digit, an angle bracket, an ampersand, a slash) means this
    ///    string is not a name, and the whole value is dropped rather than
    ///    scrubbed: "Thomas3" is not evidence that the owner is called Thomas,
    ///    and `<script>alert(1)</script>` scrubbed down to its letters would put
    ///    "scriptalertscript invited you to ride their Tesla" in a page title;
    ///  • the surviving punctuation is then removed, so "Mary-Jane" and
    ///    "Mary Jane" travel as "MaryJane". The heading reads correctly and the
    ///    URL carries one bare token;
    ///  • a name carrying letters OUTSIDE `[A-Za-z]` — "José", "Ольга", "美咲" —
    ///    is omitted ENTIRELY rather than reduced to the ASCII it happens to
    ///    contain. "Jos invited you to ride their Tesla" misspells someone to a
    ///    stranger; the generic heading merely declines to name them, which is
    ///    the kinder failure. (`[A-Za-z]` is the WEB's accepted alphabet, so
    ///    this is a limit of the feature, not of this function — widening it
    ///    means widening both sides together.);
    ///  • the survivor is capped at ``inviterNameMaxLength``.
    ///
    /// `nil` is returned rather than `""` so callers cannot accidentally emit
    /// `?from=`, which the page would have to treat as absent anyway.
    static func inviterName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }

        // Everything in it must be a letter or name punctuation. One character
        // that is neither disqualifies the whole value.
        let isNameCharacter: (Unicode.Scalar) -> Bool = { scalar in
            isASCIILetter(scalar) || nameSeparators.contains(scalar)
        }
        guard trimmed.unicodeScalars.allSatisfy(isNameCharacter) else { return nil }

        let letters = trimmed.unicodeScalars.filter(isASCIILetter).map(Character.init)
        guard !letters.isEmpty else { return nil }
        return String(letters.prefix(inviterNameMaxLength))
    }

    /// The punctuation a first name may legitimately contain. Tolerated on the
    /// way in, dropped on the way out — both curly and straight apostrophes,
    /// because iOS substitutes the curly one as you type.
    private static let nameSeparators = CharacterSet(charactersIn: " -'\u{2019}.")

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII
            && (CharacterSet.uppercaseLetters.contains(scalar)
                || CharacterSet.lowercaseLetters.contains(scalar))
    }

    /// Pull a well-formed invite code out of an incoming link, or `nil` if this
    /// URL is not one of ours.
    ///
    /// TWO ENVELOPES, STATED SEPARATELY (MYR-453): the `https://` universal link
    /// and the `myrobotaxi://` app link. They are two functions rather than one
    /// widened check on purpose — an edit that loosens the app-link rule must not
    /// be able to loosen the https rule, which is the one that can be aimed at a
    /// claimed domain. Everything past this point sees only six characters and
    /// cannot tell which door they came through.
    static func code(from url: URL) -> String? {
        code(fromUniversalLink: url) ?? code(fromAppLink: url)
    }

    /// The UNIVERSAL-LINK envelope (MYR-346). Unchanged by MYR-453.
    ///
    /// Strict about the ENVELOPE, forgiving about the CODE:
    ///
    ///  • the scheme must be `https` and the host exactly ``host`` — a universal
    ///    link can only ever arrive over https on a claimed domain, so anything
    ///    else is a URL that reached us by some other route and has no business
    ///    redeeming anything;
    ///  • the path must be exactly `/join/{something}` — not `/join`, not
    ///    `/join/A/B`. A deeper path is a web surface we do not know about;
    ///  • the QUERY IS IGNORED, whatever it holds. The code lives in the PATH,
    ///    and everything after `?` belongs to the web page: `?from=` (MYR-359,
    ///    which every link this app hands out now carries when the owner has a
    ///    name on their account), and whatever tracking or campaign parameters a
    ///    forwarded link picks up on its way through other people's apps. A
    ///    parser that let the query decide anything would refuse the app's own
    ///    links — this is the one branch where being strict about the envelope
    ///    would break the feature rather than protect it;
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
    private static func code(fromUniversalLink url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        guard url.host()?.lowercased() == host else { return nil }

        // `pathComponents` yields ["/", "join", "CODE"]; a trailing slash adds
        // nothing (Foundation drops it), so this is the exact shape we want.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0].lowercased() == pathComponent else { return nil }

        return sanitize(parts[1])
    }

    /// The APP-LINK envelope — `myrobotaxi://join/{CODE}` (MYR-453).
    ///
    /// **WHY A SECOND CHANNEL EXISTS AT ALL.** A universal link is the ONLY way
    /// a code could reach this app, and iOS declines to fire one from a
    /// WKWebView-backed in-app browser — which is what Telegram, and most
    /// messaging apps, open an `https://` link in by default. The tester who
    /// filed MYR-453 tapped an invite from Telegram: the link resolved to the web
    /// page instead of the app, and by the time she reached the app there was no
    /// activity, no URL, and therefore no code. A custom scheme is the standard
    /// escape hatch precisely because it is NOT http(s): an in-app browser cannot
    /// load it itself, so it hands it to the system, which opens us.
    ///
    /// **IT GRANTS NOTHING THE UNIVERSAL LINK DID NOT.** The two carry the same
    /// payload — six characters — and this parser applies the identical
    /// ``sanitize`` and the identical length bar, so the same auto-submit rule
    /// holds. The code is already a bearer credential that travels in the clear
    /// (see ``url(code:from:)``), redemption still requires a signed-in account
    /// POSTing to §7.5.5, and MYR-368's `?k=` signature is verified by the WEB
    /// SHELL and has never been read by this app on either channel. So a scheme
    /// link is exactly as privileged as the https link it stands in for — no
    /// more, which is the whole bar this had to clear.
    ///
    /// **TWO SPELLINGS, ONE SHAPE.** `URL(string:)` parses
    /// `myrobotaxi://join/ABCDEF` as host `join` + path `/ABCDEF`, and
    /// `myrobotaxi:///join/ABCDEF` as an empty host + path `/join/ABCDEF`. Those
    /// are the same link written two ways and both are accepted, by normalising
    /// the authority and the path into ONE component list that must be exactly
    /// `["join", CODE]`. Everything else is refused — `myrobotaxi://myrobotaxi
    /// .app/join/ABCDEF` included, since a three-component form is a shape
    /// nobody was told to write. ``appURL(code:)`` is the canonical string the
    /// web page should emit, so there is one spelling to hand over and one to
    /// pin in a test.
    ///
    /// The QUERY is ignored here for the same reason it is on the https arm.
    private static func code(fromAppLink url: URL) -> String? {
        guard url.scheme?.lowercased() == appScheme else { return nil }

        var parts: [String] = []
        if let authority = url.host(), !authority.isEmpty { parts.append(authority) }
        parts.append(contentsOf: url.pathComponents.filter { $0 != "/" })

        guard parts.count == 2, parts[0].lowercased() == pathComponent else { return nil }

        return sanitize(parts[1])
    }

    /// The canonical app-link string for a code — what the web join page's
    /// "Open in the app" button should point at (MYR-453). Composed here rather
    /// than typed on the web side so the shape this parser accepts and the shape
    /// that gets published are one fact.
    static func appURL(code: String) -> String {
        "\(appScheme)://\(pathComponent)/\(code)"
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
    /// **`.modeChooser` JOINED THEM IN MYR-426, and it is the same argument.**
    /// MYR-346 filed it with the flows that hold work, as "an unanswered
    /// question". It holds no work at all — nothing is typed into it, nothing is
    /// in flight behind it, and dismissing it destroys nothing — and the
    /// question it asks is the one the link has ALREADY ANSWERED: a
    /// `/join/{CODE}` link means somebody invited this person to view or ride
    /// THEIR Tesla, which is the rider answer. It is also the app's proof that
    /// the person holds NO SHELL: `RootView` reaches it from exactly one place,
    /// when `PostAuthRouter` finds a real signed-in user with no stored
    /// `ViewMode` — a brand-new account, or one that signed out, since MYR-224
    /// releases the choice with the session. Either way there is nothing behind
    /// them to protect and nothing on the screen to lose.
    ///
    /// Deferring there was the client's gap. On the LIVE path a new tester goes
    /// sign-in → chooser → shell and never sees `.emptyState` at all (that screen
    /// is the SIM/static-token arm of `PostAuthRouter`), so the held code waited
    /// behind a fork the tester could answer WRONG, and then arrived as a rider
    /// sheet over whichever shell they had just picked. The client's words are
    /// "upon logging with apple their code should auto fill in the rider setup
    /// flow if new account" — which is this screen, and this moment.
    ///
    /// Everything else is a flow with state in it: `.addTesla` (a live OAuth
    /// handoff) and the two tutorials (someone is partway through five cards).
    /// Those are held, not stomped.
    private static func acceptsInviteNow(_ screen: AppScreen) -> Bool {
        switch screen {
        case .ownerHome, .sharedHome, .emptyState, .modeChooser, .inviteCode: return true
        case .resolvingSession, .signIn, .addTesla, .ownerTutorial, .riderTutorial: return false
        }
    }
}
