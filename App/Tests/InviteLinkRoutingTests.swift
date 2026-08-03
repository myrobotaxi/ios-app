import XCTest
import MyRoboTaxiKit
@testable import MyRoboTaxi

// MARK: - MYR-346 — `https://myrobotaxi.app/join/{CODE}`
//
// Universal links cannot be verified end to end yet: the app only ever SEES one
// once `https://myrobotaxi.app/.well-known/apple-app-site-association` is
// deployed and iOS has fetched it for an installed build. Until then
// `simctl openurl` opens Safari, not the app.
//
// So the guard is drawn one layer in, where it is a guard rather than a
// screenshot: the parse/sanitise matrix and the routing matrix are pure
// functions, and these tests ARE those matrices. What is left unproven by them
// is exactly one thing — whether iOS hands us the activity at all — which is a
// property of the AASA and the entitlement, not of this code.

// MARK: - Parsing an incoming link

final class InviteLinkParsingTests: XCTestCase {

    private func code(_ string: String) -> String? {
        guard let url = URL(string: string) else { return nil }
        return InviteLink.code(from: url)
    }

    /// The shape the composer writes and the AASA claims.
    func testTheCanonicalLinkYieldsItsCode() {
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246"), "RBO246")
    }

    /// The link SHARED and the link ACCEPTED are one definition, not two strings
    /// that happen to agree today. This round-trip is the only reason
    /// `ShareInviteMessage` may quote a URL at all.
    func testEveryComposedLinkParsesBackToTheCodeItCarried() {
        for value in ["RBO246", "ABCDEF", "123456", "A1B2C3"] {
            let composed = AppDistribution.inviteJoinURL(code: value)
            XCTAssertEqual(
                code(composed), value,
                "the composer and the parser must agree by construction, not by coincidence"
            )
        }
    }

    /// Forgiving about the CODE. A link retyped by hand, lower-cased by a
    /// client, hyphenated for readability, or percent-encoded in transit still
    /// carries the same six characters — the same normalisation
    /// `RestClient.normalizedInviteCode` applies before POSTing.
    func testTheCodeIsUpperCasedAndStrippedToAlphanumerics() {
        XCTAssertEqual(code("https://myrobotaxi.app/join/rbo246"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO-246"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/rBo246"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO%2D246"), "RBO246")
    }

    /// Noise around the path does not change what the link means.
    func testTrailingSlashesQueriesAndFragmentsAreIgnored() {
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246/"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?utm_source=imessage"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246#top"), "RBO246")
        XCTAssertEqual(code("https://MyRoboTaxi.app/join/RBO246"), "RBO246", "hosts are case-insensitive")
    }

    // MARK: MYR-359 — the `?from=` parameter the app itself now sends

    /// EVERY link this app hands out carries `?from={Name}` when the owner's
    /// account has a name on it, so tolerating the query stopped being politeness
    /// towards other people's tracking parameters and became the difference
    /// between the feature working and not. The code lives in the PATH; the query
    /// is the web page's business and this parser has no opinion about it.
    func testTheFromParameterIsToleratedAndIgnored() {
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?from=Thomas"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/rbo246?from=Thomas"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246/?from=Thomas"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?from=Thomas#top"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?from="), "RBO246", "an empty name is still a link")
        XCTAssertEqual(
            code("https://myrobotaxi.app/join/RBO246?utm_source=imessage&from=Thomas"), "RBO246",
            "a forwarded link picks up parameters on the way"
        )
    }

    // MARK: MYR-368 — the SIGNED link the server now mints

    /// THE VECTOR. A complete server-minted link — `k`, `from` and `to`, with the
    /// 86-character Ed25519 signature in the middle — parses to its code exactly
    /// as the bare link does.
    ///
    /// This is the test that matters most on the receiving end: from MYR-368
    /// forward, EVERY link the product hands out looks like this, so "the parser
    /// ignores the query" stopped being tolerance of other people's tracking
    /// parameters and became the difference between a tapped invite opening the
    /// app and opening Safari. The base64url alphabet is deliberately in frame —
    /// `_` and `-` are code characters' neighbours, and a parser that scanned
    /// rather than read the PATH would have plenty to choke on here.
    func testTheFullSignedLinkParsesToItsCode() {
        XCTAssertEqual(
            code("https://myrobotaxi.app/join/RBO246?k=1.1785942245.fPkcqmLr2p_HezqZtbP6J1NC-jQA0nAOp7hiFqTKZHo9L2YGVkNDx162VsdromPEMSZaMvMhxRCBS_xfaRw0BQ&from=Alex&to=Mira"),
            "RBO246"
        )
    }

    /// The same link in the shapes it actually arrives in: lower-cased by a client
    /// that rewrote it, with a trailing slash, with a fragment, and after a resend
    /// re-signed it onto a different code. Nothing in `k` — a 60-character run of
    /// base64url between two dots, longer than any code and full of code
    /// characters — may influence the answer.
    func testTheSignedLinksQueryNeverSuppliesOrDisturbsTheCode() {
        let signature = "1.1785942245.fPkcqmLr2p_HezqZtbP6J1NC-jQA0nAOp7hiFqTKZHo9L2YGVkNDx162VsdromPEMSZaMvMhxRCBS_xfaRw0BQ"
        XCTAssertEqual(code("https://myrobotaxi.app/join/rbo246?k=\(signature)&from=Alex&to=Mira"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246/?k=\(signature)&from=Alex&to=Mira"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?k=\(signature)&from=Alex&to=Mira#top"), "RBO246")
        XCTAssertEqual(
            code("https://myrobotaxi.app/join/ZKQ913?k=1.1786006800.nTwfey5ahMYPsdJzkOSlGIxz8GIauU3lNwyPHqayXUPPgHFKLWuV6DH6DH0kuOVgk68cLXDkuKUfbDnQLotHoQ&from=Alex&to=Mira"),
            "ZKQ913",
            "a resend re-signs onto a new code"
        )
        // The server OMITS a name it could not sanitize rather than emitting an
        // empty parameter — both grammars have to parse.
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?k=\(signature)&to=Mira"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?k=\(signature)"), "RBO246")
        // And the code is still refused when the PATH does not carry one, however
        // much the query looks like it does.
        XCTAssertNil(code("https://myrobotaxi.app/join/?k=\(signature)&from=RBO246"))
    }

    /// A hand-edited or hostile query changes nothing about the code — the two
    /// values never meet. (What the WEB does with such a value is guarded on the
    /// web side; here the point is that the app neither reads nor is confused by
    /// it.)
    func testAJunkQueryDoesNotChangeTheCodeTheLinkCarries() {
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?from=%3Cscript%3E"), "RBO246")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?from=ZKQ913"), "RBO246",
                       "a six-character name in the query is not the code")
        XCTAssertEqual(code("https://myrobotaxi.app/join/RBO246?code=ZKQ913"), "RBO246")
        XCTAssertNil(code("https://myrobotaxi.app/join/?from=RBO246"), "the query cannot supply a missing code")
    }

    /// The whole from-matrix, end to end: composed by the shipping builder,
    /// parsed by the shipping parser. Name, no name, and a name that does not
    /// survive sanitisation all have to land on the same code.
    func testEveryComposedLinkInTheFromMatrixParsesBackToItsCode() {
        let names: [String?] = [nil, "", "   ", "Thomas", "  Thomas  ", "Mary-Jane",
                                "José", "<script>alert(1)</script>", "123",
                                String(repeating: "z", count: 99)]
        for name in names {
            let composed = InviteLink.url(code: "RBO246", from: name)
            XCTAssertEqual(
                code(composed), "RBO246",
                "\(String(describing: name)) → \(composed)"
            )
        }
    }

    /// The client's own filter on the name. The page filters again on arrival —
    /// neither side trusts the other — but a link this app writes must never
    /// carry junk in the first place.
    func testTheInviterNameIsFilteredBeforeItEverReachesALink() {
        XCTAssertEqual(InviteLink.inviterName("Thomas"), "Thomas")
        XCTAssertEqual(InviteLink.inviterName("  Thomas\n"), "Thomas")
        XCTAssertEqual(InviteLink.inviterName("Mary-Jane"), "MaryJane", "separators drop, letters stay")
        XCTAssertNil(InviteLink.inviterName("Thomas2"), "a digit means this is not a name")
        XCTAssertEqual(
            InviteLink.inviterName(String(repeating: "a", count: 40)),
            String(repeating: "a", count: InviteLink.inviterNameMaxLength)
        )

        XCTAssertNil(InviteLink.inviterName(nil))
        XCTAssertNil(InviteLink.inviterName(""))
        XCTAssertNil(InviteLink.inviterName("   "))
        XCTAssertNil(InviteLink.inviterName("123"))
        XCTAssertNil(InviteLink.inviterName("Thomas & Co"), "an ampersand is not name punctuation")
        XCTAssertNil(InviteLink.inviterName("<script>alert(1)</script>"))
        // A name we cannot SPELL in ASCII is omitted whole rather than reduced to
        // the letters it happens to share with English.
        XCTAssertNil(InviteLink.inviterName("José"))
        XCTAssertNil(InviteLink.inviterName("Ольга"))
    }

    /// Strict about the ENVELOPE. Each of these is a URL that could plausibly
    /// reach `code(from:)` — from a pasted string, a `myrobotaxi://` callback,
    /// or a look-alike domain — and none of them may produce a code.
    func testAUrlThatIsNotOursYieldsNothing() {
        XCTAssertNil(code("http://myrobotaxi.app/join/RBO246"), "https only — a universal link cannot be http")
        XCTAssertNil(code("myrobotaxi://join/RBO246"), "the custom scheme is the Tesla-link callback, not this")
        XCTAssertNil(code("https://myrobotaxi.app.evil.com/join/RBO246"), "suffix look-alike")
        XCTAssertNil(code("https://evil.com/join/RBO246"))
        XCTAssertNil(code("https://www.myrobotaxi.app/join/RBO246"),
                     "the entitlement claims the bare host; www is not it, so honouring it here would be a lie")
    }

    /// A path we do not recognise belongs to the WEB surface, which will grow
    /// paths this build knows nothing about. It is never an error here.
    func testAPathThatIsNotAJoinLinkYieldsNothing() {
        XCTAssertNil(code("https://myrobotaxi.app/"))
        XCTAssertNil(code("https://myrobotaxi.app/join"))
        XCTAssertNil(code("https://myrobotaxi.app/join/"))
        XCTAssertNil(code("https://myrobotaxi.app/about/RBO246"))
        XCTAssertNil(code("https://myrobotaxi.app/join/RBO246/extra"))
    }

    /// The LENGTH check is what makes auto-submit safe. The field submits on the
    /// 6th character because six characters is the whole code; a link is held to
    /// the same bar, so a truncated or padded link never spends one of the
    /// rider's 10 attempts per minute (§7.5.5) on a code the client could see
    /// was wrong.
    func testACodeOfTheWrongLengthIsRefusedRatherThanTruncated() {
        XCTAssertNil(code("https://myrobotaxi.app/join/RBO24"), "five")
        XCTAssertNil(code("https://myrobotaxi.app/join/RBO2467"), "seven — truncating would redeem a code nobody minted")
        XCTAssertNil(code("https://myrobotaxi.app/join/------"), "six characters, none of them a code")
        XCTAssertNil(code("https://myrobotaxi.app/join/%20%20%20%20%20%20"))
    }

    /// `sanitize` is used directly on a HELD code as well as on a URL segment,
    /// so its own contract is pinned separately.
    func testSanitizePinsTheSixUppercaseAlphanumericRule() {
        XCTAssertEqual(InviteLink.sanitize("rbo246"), "RBO246")
        XCTAssertEqual(InviteLink.sanitize(" RBO 246 "), "RBO246")
        XCTAssertNil(InviteLink.sanitize(""))
        XCTAssertNil(InviteLink.sanitize("RBO24"))
        XCTAssertNil(InviteLink.sanitize("RBO2467"))
    }
}

// MARK: - The host is a three-way contract

final class InviteLinkHostTests: XCTestCase {

    /// This string appears in three places that must agree or the feature is
    /// silently dead: the `applinks:` entitlement (`project.yml`), the domain
    /// serving the AASA, and this parser. Changing it here without changing the
    /// other two produces a link that opens Safari with no error anywhere.
    func testTheHostMatchesTheEntitlementAndTheAasaDomain() {
        XCTAssertEqual(InviteLink.host, "myrobotaxi.app",
                       "project.yml declares `applinks:myrobotaxi.app`")
        XCTAssertEqual(InviteLink.pathComponent, "join",
                       "the AASA claims components `/join/*`")
        XCTAssertEqual(InviteLink.codeLength, 6, "§7.5.1 mints six characters")
        XCTAssertEqual(InviteLink.url(code: "RBO246"), "https://myrobotaxi.app/join/RBO246")
    }
}

// MARK: - Where a link lands

final class InviteLinkRoutingTests: XCTestCase {

    private let link = URL(string: "https://myrobotaxi.app/join/RBO246")!

    private func route(_ screen: AppScreen, busy: Bool = false) -> InviteLinkRoute {
        InviteLinkRouting.route(url: link, context: InviteLinkContext(screen: screen, isBusy: busy))
    }

    /// SIGNED IN, either mode. The flow opens prefilled and submits itself —
    /// the owner shell and the rider shell get the identical treatment, because
    /// an owner tapping a link is a real case (their own, or another owner's)
    /// and there is nothing about the owner shell that makes a code less valid.
    func testASignedInUserInEitherModeGetsThePrefilledFlow() {
        XCTAssertEqual(route(.ownerHome), .presentPrefilledInvite(code: "RBO246"))
        XCTAssertEqual(route(.sharedHome), .presentPrefilledInvite(code: "RBO246"))
    }

    /// The first-run choice screen offers "Join with an invite code" as one of
    /// its two options — a link arriving there is that option arriving from
    /// outside, so it opens immediately rather than waiting for a tap.
    func testTheFirstRunChoiceScreenAcceptsALinkImmediately() {
        XCTAssertEqual(route(.emptyState), .presentPrefilledInvite(code: "RBO246"))
    }

    /// A SECOND link while the flow is already up re-prefills it, rather than
    /// queueing behind the very screen it was trying to reach — which would
    /// deadlock, since that screen never resolves on its own.
    func testASecondLinkRePrefillsTheFlowAlreadyOnScreen() {
        XCTAssertEqual(route(.inviteCode), .presentPrefilledInvite(code: "RBO246"))
    }

    /// SIGNED OUT. Hold the code, run the ordinary sign-in. Note there is no
    /// invite-specific sign-in screen and no banner on the existing one: at this
    /// moment the app has no idea whether the code is even valid, so promising
    /// anything would be premature.
    func testASignedOutUserHoldsTheCodeThroughSignIn() {
        XCTAssertEqual(route(.signIn), .awaitSignIn(code: "RBO246"))
        XCTAssertEqual(route(.resolvingSession), .awaitSignIn(code: "RBO246"),
                       "the returning-user splash is still pre-shell")
    }

    /// MID-RIDE, either side of it. The code is worth 7 days; an unanswered
    /// Accept/Decline and a half-built ride request are worth the next 30
    /// seconds.
    func testARideInProgressDefersTheLinkRatherThanStompingIt() {
        XCTAssertEqual(route(.ownerHome, busy: true), .awaitIdle(code: "RBO246"))
        XCTAssertEqual(route(.sharedHome, busy: true), .awaitIdle(code: "RBO246"))
    }

    /// Mid-onboarding screens each hold state a screen swap would destroy: a
    /// live Tesla OAuth handoff, and someone three cards into a five-card
    /// tutorial.
    ///
    /// MYR-426 took `.modeChooser` OUT of this list — see the test below. It
    /// holds nothing, and the question it asks is the one the link answers.
    func testAnUnfinishedOnboardingFlowDefersTheLink() {
        for screen: AppScreen in [.addTesla, .ownerTutorial, .riderTutorial] {
            XCTAssertEqual(route(screen), .awaitIdle(code: "RBO246"),
                           "\(screen) holds work a link must not discard")
        }
    }

    // MARK: - MYR-426 — the fresh account

    /// THE MAIN GAP THIS ISSUE CLOSES. `.modeChooser` is reachable from exactly
    /// one place — a real signed-in account with no stored `ViewMode` (new, or
    /// signed out; MYR-224 releases the choice with the session) — so a link
    /// landing there is landing on somebody holding no shell, and the "owner or
    /// rider?" question it asks has already been answered by the fact that
    /// somebody invited this person to ride THEIR Tesla.
    ///
    /// It is also the only fresh-account screen on the LIVE path: `.emptyState`
    /// is `PostAuthRouter`'s SIM/static-token arm and a real new tester never
    /// sees it. So before this the code waited behind a fork the tester could
    /// answer wrong and then arrived as a sheet over whichever shell they picked.
    func testTheModeChooserAcceptsALinkBecauseItIsTheAnswerToItsQuestion() {
        XCTAssertEqual(route(.modeChooser), .presentPrefilledInvite(code: "RBO246"))
    }

    /// The client's sentence, walked as a state machine: *"upon logging with
    /// apple their code should auto fill in the rider setup flow if new account
    /// and of course they are coming from clicking the link."*
    ///
    /// The tap lands before the app exists (`InviteLinkBridge` holds it), the
    /// code is held silently through Apple sign-in with nothing said about it,
    /// and the FIRST screen a fresh account reaches after account creation opens
    /// the join step prefilled. Nowhere in this sequence is the code dropped, and
    /// nowhere is the tester asked to re-find it.
    func testAFreshAccountsCodeSurvivesAppleSignInAndOpensTheJoinStep() {
        var context = InviteLinkContext(screen: .resolvingSession, isBusy: false)
        XCTAssertEqual(
            InviteLinkRouting.route(code: "RBO246", context: context), .awaitSignIn(code: "RBO246"),
            "cold launch: the mailbox drained onto a shell that does not exist yet"
        )
        context.screen = .signIn
        XCTAssertEqual(
            InviteLinkRouting.route(code: "RBO246", context: context), .awaitSignIn(code: "RBO246"),
            "Sign in with Apple: still held, and the sign-in screen says nothing about it"
        )
        context.screen = .modeChooser
        XCTAssertEqual(
            InviteLinkRouting.route(code: "RBO246", context: context),
            .presentPrefilledInvite(code: "RBO246"),
            "account created, no stored mode — the join step opens carrying the code"
        )
    }

    /// A fresh account is never BUSY — there is no ride to be mid-way through
    /// before the account has a car — but the ordering is asserted anyway,
    /// because `isBusy` is read from live services that a future change could
    /// make true here, and holding on the chooser would be holding for a
    /// condition nothing on that screen can clear.
    func testBusyStillOutranksTheChooserRatherThanBeingIgnoredThere() {
        XCTAssertEqual(route(.modeChooser, busy: true), .awaitIdle(code: "RBO246"))
    }

    /// Pre-auth beats busy: there is no ride to be mid-way through before the
    /// shell exists, and the answer must be the one that resolves.
    func testSignInOutranksBusy() {
        XCTAssertEqual(route(.signIn, busy: true), .awaitSignIn(code: "RBO246"))
    }

    /// EVERY deferral state resolves on its own — sign-in completes, tutorials
    /// end, rides finish — so a held code always terminates rather than waiting
    /// forever. This walks the actual state machine `RootView` re-asks with.
    func testAHeldCodeEventuallyLandsAsTheShellSettles() {
        var context = InviteLinkContext(screen: .signIn, isBusy: false)
        XCTAssertEqual(InviteLinkRouting.route(code: "RBO246", context: context), .awaitSignIn(code: "RBO246"))
        context.screen = .riderTutorial
        XCTAssertEqual(InviteLinkRouting.route(code: "RBO246", context: context), .awaitIdle(code: "RBO246"))
        context.screen = .sharedHome
        context.isBusy = true
        XCTAssertEqual(InviteLinkRouting.route(code: "RBO246", context: context), .awaitIdle(code: "RBO246"))
        context.isBusy = false
        XCTAssertEqual(
            InviteLinkRouting.route(code: "RBO246", context: context),
            .presentPrefilledInvite(code: "RBO246")
        )
    }

    /// MYR-426 — the promise stated over the WHOLE enum rather than over a list
    /// of screens someone remembered to write down.
    ///
    /// Every screen this app can be on either takes the code NOW or defers it,
    /// and every screen that defers has a named event that ends it. Sweeping the
    /// enum is what makes this a guard rather than a sample: a screen added later
    /// has to appear in one of these two sets, and the second set has to say what
    /// resolves it. Nothing may defer to a condition that never arrives.
    func testNoScreenHoldsACodeForever() {
        /// Every screen either takes the code now, or names the screen the event
        /// that ends it puts the user on.
        enum Landing {
            case now
            case defers(into: AppScreen)
        }
        let matrix: [AppScreen: Landing] = [
            // Accepts now.
            .ownerHome: .now,
            .sharedHome: .now,
            .emptyState: .now,
            .modeChooser: .now,
            .inviteCode: .now,
            // Defers, and what it resolves INTO.
            .resolvingSession: .defers(into: .signIn),   // the silent refresh answers, either way
            .signIn: .defers(into: .modeChooser),        // the account is created
            .addTesla: .defers(into: .ownerTutorial),    // the OAuth handoff returns
            .ownerTutorial: .defers(into: .ownerHome),   // five cards, or Skip
            .riderTutorial: .defers(into: .sharedHome),  // five cards, or Skip
        ]
        let all: [AppScreen] = [
            .resolvingSession, .signIn, .modeChooser, .emptyState, .addTesla,
            .inviteCode, .ownerTutorial, .riderTutorial, .ownerHome, .sharedHome,
        ]
        let landed = InviteLinkRoute.presentPrefilledInvite(code: "RBO246")

        for screen in all {
            guard let entry = matrix[screen] else {
                return XCTFail("\(screen) is not in the matrix — it must accept or name what resolves it")
            }
            let here = route(screen)
            switch entry {
            case .now:
                XCTAssertEqual(here, landed, "\(screen) is listed as accepting immediately")
            case .defers(let next):
                XCTAssertNotEqual(here, .ignore, "\(screen) must never DROP a held code")
                XCTAssertNotEqual(here, landed, "\(screen) is listed as deferring")
                // …and the screen it resolves into is strictly closer to landing:
                // either it accepts, or it defers to something that does.
                var walked = next
                var hops = 0
                while route(walked) != landed {
                    guard case .defers(let onward) = matrix[walked] ?? .now, hops < all.count else {
                        return XCTFail("\(screen) resolves into \(walked), which never lands")
                    }
                    walked = onward
                    hops += 1
                }
            }
        }
    }

    /// AN UNUSABLE LINK IS NOT AN ERROR. The AASA claims `/join/*` and the web
    /// surface will grow paths this build knows nothing about; the app opens
    /// normally and says nothing, because rendering that URL is the web's job.
    func testAnUnusableLinkIsIgnoredFromEveryScreen() {
        let junk = URL(string: "https://myrobotaxi.app/join/nope")!
        for screen: AppScreen in [.signIn, .emptyState, .ownerHome, .sharedHome, .riderTutorial] {
            XCTAssertEqual(
                InviteLinkRouting.route(url: junk, context: InviteLinkContext(screen: screen)),
                .ignore
            )
        }
    }

    /// The code arm re-validates rather than trusting its caller, so a malformed
    /// value can never survive a round of holding and reach the field.
    func testAHeldCodeIsReValidatedNotTrusted() {
        let context = InviteLinkContext(screen: .ownerHome)
        XCTAssertEqual(InviteLinkRouting.route(code: "RB", context: context), .ignore)
        XCTAssertEqual(InviteLinkRouting.route(code: "", context: context), .ignore)
        XCTAssertEqual(
            InviteLinkRouting.route(code: "rbo246", context: context),
            .presentPrefilledInvite(code: "RBO246"),
            "and it normalises, so the field is always handed the canonical form"
        )
    }
}

// MARK: - The owner who taps their own link

@MainActor
final class InviteLinkOwnCodeTests: XCTestCase {

    private func catalog(_ endpoint: ScriptedShareEndpoint) -> LiveSharedVehicleCatalog {
        LiveSharedVehicleCatalog(api: endpoint, listVehicles: { [] })
    }

    /// THE CASE THIS FEATURE CREATES. Before universal links, an owner had no
    /// reason to tap their own invite — the code was six characters in a message
    /// they wrote. Now the message leads with a tappable link, and the owner
    /// tapping it to check that it works is the single most likely first use of
    /// this feature by anybody.
    ///
    /// §7.5.5 answers `409` (the caller OWNS one of the targets), which the Kit
    /// folds to `.alreadyHasAccess`, and the entry screen already renders that
    /// honestly: "You already have access to that Tesla", with the entry LEFT
    /// INTACT and NO shake. That is the whole handling — the link adds no
    /// special-casing, because the screen was already right.
    func testAnOwnersOwnLinkLandsOnTheHonestNoticeNotAShake() async {
        let endpoint = ScriptedShareEndpoint()
        endpoint.redeemResult = .failure(RestError.http(status: 409, code: nil, message: nil, subCode: nil))

        // The code travels the link's own sanitiser first, exactly as it does at
        // runtime, so this exercises the composed path rather than a literal.
        let code = try! XCTUnwrap(InviteLink.code(from: URL(string: AppDistribution.inviteJoinURL(code: "RBO246"))!))

        do {
            _ = try await catalog(endpoint).redeem(code: code)
            XCTFail("a 409 must not read as a join")
        } catch let failure as ShareRedemptionFailure {
            XCTAssertEqual(failure, .alreadyHasAccess)
            XCTAssertFalse(
                failure.clearsEntry,
                "no shake and no clear: nothing is wrong with the code, and wiping it would read as a rejection"
            )
            XCTAssertEqual(failure.riderMessage, "You already have access to that Tesla")
        } catch {
            XCTFail("expected a typed ShareRedemptionFailure, got \(error)")
        }
        XCTAssertEqual(endpoint.calls, [.redeem(code: "RBO246")],
                       "one attempt, on the canonical uppercase code")
    }

    /// The other refusals are unchanged by the link — a link is just a faster
    /// way to type, so it inherits the whole matrix rather than a subset.
    func testTheOtherRefusalsAreUnchangedWhenTheCodeCameFromALink() async {
        for (status, expected) in [
            (404, ShareRedemptionFailure.invalidOrExpired),
            (429, ShareRedemptionFailure.tooManyAttempts),
            (400, ShareRedemptionFailure.malformed),
        ] {
            let endpoint = ScriptedShareEndpoint()
            endpoint.redeemResult = .failure(RestError.http(status: status, code: nil, message: nil, subCode: nil))
            do {
                _ = try await catalog(endpoint).redeem(code: "RBO246")
                XCTFail("\(status) must not read as a join")
            } catch let failure as ShareRedemptionFailure {
                XCTAssertEqual(failure, expected)
            } catch {
                XCTFail("expected a typed failure for \(status)")
            }
        }
    }
}

// MARK: - The cold-launch mailbox

@MainActor
final class InviteLinkBridgeTests: XCTestCase {

    override func tearDown() {
        InviteLinkBridge.shared.resetForTesting()
        super.tearDown()
    }

    /// THE COLD-LAUNCH CASE, and the reason this type is not just a closure. A
    /// link tapped from a cold state delivers the activity during launch, which
    /// can land before `RootView` has appeared. Push drops taps in that window
    /// on the reasoning that its refetch reaches the same surface anyway; an
    /// invite code has no refetch, so it is held until someone listens.
    func testAUrlArrivingBeforeAnyListenerIsHeldAndThenDelivered() {
        InviteLinkBridge.shared.resetForTesting()
        let url = URL(string: "https://myrobotaxi.app/join/RBO246")!

        InviteLinkBridge.shared.receive(url)
        XCTAssertTrue(InviteLinkBridge.shared.hasPendingLinkForTesting)

        var delivered: [URL] = []
        InviteLinkBridge.shared.install { delivered.append($0) }

        XCTAssertEqual(delivered, [url], "installing drains what was held")
        XCTAssertFalse(InviteLinkBridge.shared.hasPendingLinkForTesting, "and drains it exactly once")
    }

    /// Warm launch: the listener is already installed, so nothing is held.
    func testAUrlArrivingWithAListenerInstalledGoesStraightThrough() {
        InviteLinkBridge.shared.resetForTesting()
        var delivered: [URL] = []
        InviteLinkBridge.shared.install { delivered.append($0) }

        let url = URL(string: "https://myrobotaxi.app/join/ABCDEF")!
        InviteLinkBridge.shared.receive(url)

        XCTAssertEqual(delivered, [url])
        XCTAssertFalse(InviteLinkBridge.shared.hasPendingLinkForTesting)
    }

    /// Both delivery paths (SwiftUI's `onContinueUserActivity` and the app
    /// delegate's `continue`) feed this mailbox, and on some runtimes both fire
    /// for one activation. The second delivery must be harmless — it resolves to
    /// the same route, which re-prefills the same flow with the same code, and
    /// `InviteCodeFlow.prefill` fires no `onChange` when the value is unchanged.
    func testARepeatedDeliveryOfTheSameLinkResolvesToTheSameRoute() {
        let url = URL(string: "https://myrobotaxi.app/join/RBO246")!
        let context = InviteLinkContext(screen: .ownerHome)
        let first = InviteLinkRouting.route(url: url, context: context)
        let second = InviteLinkRouting.route(url: url, context: context)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, .presentPrefilledInvite(code: "RBO246"))
    }
}
