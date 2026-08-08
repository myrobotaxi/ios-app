import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-453 — `myrobotaxi://join/{CODE}`, the second channel
//
// THE DEFECT THESE EXIST FOR. An external tester tapped an invite link FROM
// TELEGRAM. The app opened on the "Enter invite code" screen with all six cells
// empty. Nothing was broken: iOS does not fire a universal link out of a
// WKWebView-backed in-app browser, Telegram opens `https://` links in exactly
// such a browser by default, and the universal link was the ONLY channel this
// app had. The code had no way in.
//
// So the guard here is not "does the parse work" — MYR-346's suite already
// proves that for the https shape. It is the two properties that make a SECOND
// channel safe to add:
//
//   1. the app-link envelope is strict, and admits nothing the https one would
//      have refused (same `sanitize`, same exact-six bar, same one path shape);
//   2. the https envelope is BYTE-FOR-BYTE what it was — a widened arm on the
//      shared `code(from:)` is exactly the edit that could loosen the rule an
//      attacker can point at a claimed domain, and it must not have.
//
// What these CANNOT prove is that iOS hands the app the URL at all. Unlike the
// universal link, that half IS observable on a simulator (`simctl openurl` opens
// a custom scheme rather than Safari), and it was — see the PR. It is not
// asserted here because the modifier is a property of `RootView`, not of this
// parser.

final class InviteLinkSchemeTests: XCTestCase {

    // MARK: The scheme is a two-way contract

    /// `InviteLink.appScheme` and `CFBundleURLTypes` must agree or the link is
    /// dead with no signal anywhere: iOS refuses to open an app for a scheme it
    /// has not registered, and nothing about that failure reaches the app.
    ///
    /// The scheme was ALREADY registered — for the two Tesla OAuth callbacks
    /// (§7.11/§7.12) — which is why MYR-453 adds no plist entry. This test is
    /// what stops it being REMOVED by someone tidying up the Tesla flow and
    /// taking the invite fallback down with it, silently.
    func testTheSchemeIsTheOneTheAppActuallyRegisters() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App/Tests
            .deletingLastPathComponent()   // App
            .appendingPathComponent("MyRoboTaxi-Info.plist")

        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any]

        let types = try XCTUnwrap(parsed?["CFBundleURLTypes"] as? [[String: Any]],
                                  "App/MyRoboTaxi-Info.plist must declare CFBundleURLTypes")
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes.contains(InviteLink.appScheme),
                      "CFBundleURLTypes declares \(schemes) — it must include `\(InviteLink.appScheme)`")
    }

    /// The canonical string handed to the web page. Composed by the app so the
    /// shape that is published and the shape this parser accepts cannot drift.
    func testTheCanonicalAppLinkIsTheShapeTheParserAccepts() {
        XCTAssertEqual(InviteLink.appURL(code: "RBO246"), "myrobotaxi://join/RBO246")
        XCTAssertEqual(
            InviteLink.code(from: URL(string: InviteLink.appURL(code: "RBO246"))!),
            "RBO246",
            "the composer's own output must round-trip through the parser"
        )
    }

    // MARK: The app-link envelope

    /// `URL(string:)` reads `myrobotaxi://join/ABCDEF` as host `join` + path
    /// `/ABCDEF`, and `myrobotaxi:///join/ABCDEF` as an empty host + path
    /// `/join/ABCDEF`. Those are one link written two ways; both resolve.
    func testBothSpellingsOfTheSameAppLinkResolve() {
        XCTAssertEqual(InviteLink.code(from: URL(string: "myrobotaxi://join/RBO246")!), "RBO246")
        XCTAssertEqual(InviteLink.code(from: URL(string: "myrobotaxi:///join/RBO246")!), "RBO246")
    }

    /// Forgiving about the CODE, exactly as the https arm is: percent-encoding,
    /// case and separators are normalised by the SAME `sanitize`.
    func testTheCodeIsNormalisedExactlyAsTheUniversalLinksIs() {
        for spelling in ["myrobotaxi://join/rbo246",
                         "myrobotaxi://join/RBO-246",
                         "myrobotaxi://join/rbo%20246"] {
            XCTAssertEqual(InviteLink.code(from: URL(string: spelling)!), "RBO246", spelling)
        }
    }

    /// The scheme is matched case-insensitively — iOS lower-cases it, but a
    /// hand-written link on a web page may not.
    func testTheSchemeIsCaseInsensitive() {
        XCTAssertEqual(InviteLink.code(from: URL(string: "MyRoboTaxi://join/RBO246")!), "RBO246")
    }

    /// The query belongs to the web page on BOTH channels. A signed link's `k`
    /// / `from` / `to` must not influence the code, which comes from the path.
    func testTheQueryIsIgnoredOnTheAppLinkToo() {
        let signed = "myrobotaxi://join/RBO246?k=key1.1893456000.abc-def_123&from=Thomas&to=Aarthi"
        XCTAssertEqual(InviteLink.code(from: URL(string: signed)!), "RBO246")
    }

    /// An all-letter code inside a query full of six-character lookalikes. The
    /// sharpest case, and it is safe for the structural reason: the code is read
    /// from the PATH and the query is never scanned.
    func testAnAllLetterAppLinkCodeIsNotConfusedWithTheSendersName() {
        let url = URL(string: "myrobotaxi://join/ABCDEF?from=Thomas&to=Aarthi")!
        XCTAssertEqual(InviteLink.code(from: url), "ABCDEF")
    }

    // MARK: What the app-link envelope refuses

    /// Every refusal is `nil`, which routes to `.ignore` — the app opens
    /// normally and says nothing. A wrong LENGTH is refused rather than
    /// truncated, which is what keeps auto-submit from spending one of the
    /// rider's 10 redeem attempts per minute (§7.5.5) on a code we could see was
    /// malformed.
    func testTheAppLinkEnvelopeIsStrict() {
        let refused = [
            "myrobotaxi://join/ABC",                 // too short
            "myrobotaxi://join/ABCDEFG",             // too long
            "myrobotaxi://join",                     // no code
            "myrobotaxi://join/",                    // no code, trailing slash
            "myrobotaxi://ride/ABCDEF",              // not the join path
            "myrobotaxi://join/ABCDEF/extra",        // a deeper path we know nothing about
            "myrobotaxi://myrobotaxi.app/join/ABCDEF", // three components: not the shape
            "teslamotors://join/ABCDEF",             // somebody else's scheme
            "myrobotaxis://join/ABCDEF",             // a near-miss scheme
        ]
        for spelling in refused {
            XCTAssertNil(InviteLink.code(from: URL(string: spelling)!),
                         "`\(spelling)` must not resolve to a code")
        }
    }

    /// The two Tesla callbacks share this scheme and must stay inert. Before
    /// MYR-453 a stray one (arriving with no `ASWebAuthenticationSession`
    /// running) was silently dropped; now it reaches the parser, and it has to
    /// be dropped just as silently rather than becoming an invite.
    func testTheTeslaCallbacksOnTheSameSchemeAreNotInvites() {
        for callback in ["myrobotaxi://tesla-linked", "myrobotaxi://tesla-unlinked"] {
            let url = URL(string: callback)!
            XCTAssertNil(InviteLink.code(from: url), callback)
            XCTAssertEqual(
                InviteLinkRouting.route(url: url, context: InviteLinkContext(screen: .ownerHome)),
                .ignore,
                "\(callback) must open the app normally and say nothing"
            )
        }
    }

    // MARK: The https rule did not move

    /// The regression guard for the whole change. `code(from:)` grew a second
    /// arm; the arm an attacker can aim at a claimed domain must be exactly what
    /// it was. Stated in both directions so a loosened host, scheme or path
    /// check fails here rather than in production.
    func testTheUniversalLinkRuleIsUnchanged() {
        XCTAssertEqual(InviteLink.code(from: URL(string: "https://myrobotaxi.app/join/RBO246")!),
                       "RBO246", "the shipping shape still resolves")

        let stillRefused = [
            "http://myrobotaxi.app/join/RBO246",        // not https
            "https://myrobotaxi.app.evil.com/join/RBO246", // not our host
            "https://evil.com/join/RBO246",             // not our host
            "https://myrobotaxi.app/join/RBO246/extra", // deeper path
            "https://myrobotaxi.app/join",              // no code
            "https://myrobotaxi.app/invite/RBO246",     // not the join path
        ]
        for spelling in stillRefused {
            XCTAssertNil(InviteLink.code(from: URL(string: spelling)!),
                         "`\(spelling)` must still be refused")
        }
    }

    /// The app scheme must NOT become a way to reach a host-shaped URL, and the
    /// https arm must not start accepting our scheme's two-component form.
    func testNeitherArmLeaksIntoTheOther() {
        XCTAssertNil(InviteLink.code(from: URL(string: "https://join/RBO246")!),
                     "the app-link component rule must not apply to https")
        XCTAssertNil(InviteLink.code(from: URL(string: "myrobotaxi://myrobotaxi.app/join/RBO246")!),
                     "the https host rule must not apply to the app scheme")
    }

    // MARK: Downstream cannot tell the two channels apart

    /// The whole design claim in one test: the channel is resolved away inside
    /// `code(from:)`, so the deferral matrix, the hold and the auto-submit are
    /// the SHIPPING ones rather than a second copy written for the new door.
    func testAnAppLinkRoutesIdenticallyToTheUniversalLinkOnEveryScreen() {
        let web = URL(string: "https://myrobotaxi.app/join/RBO246")!
        let app = URL(string: "myrobotaxi://join/RBO246")!

        // `AppScreen` is `Hashable`, not `CaseIterable` — the same explicit list
        // `testNoScreenHoldsACodeForever` sweeps, for the same reason.
        let all: [AppScreen] = [
            .resolvingSession, .signIn, .modeChooser, .emptyState, .addTesla,
            .inviteCode, .ownerTutorial, .riderTutorial, .ownerHome, .sharedHome,
        ]
        for screen in all {
            for busy in [false, true] {
                let context = InviteLinkContext(screen: screen, isBusy: busy)
                XCTAssertEqual(
                    InviteLinkRouting.route(url: app, context: context),
                    InviteLinkRouting.route(url: web, context: context),
                    "\(screen) busy=\(busy): the two channels must be indistinguishable"
                )
            }
        }
    }

    /// The rider in MYR-453's report: an existing account with no shared
    /// vehicles sits on the rider shell, which ACCEPTS. On the channel she
    /// actually had available, the code now lands prefilled.
    func testTheReportedRidersShellPresentsThePrefilledFlow() {
        let app = URL(string: "myrobotaxi://join/RBO246")!
        XCTAssertEqual(
            InviteLinkRouting.route(url: app, context: InviteLinkContext(screen: .sharedHome)),
            .presentPrefilledInvite(code: "RBO246")
        )
    }

    /// A cold launch through the new door takes the same mailbox: the app link
    /// can arrive before `RootView` exists exactly as the activity can, and
    /// dropping it would lose the code for good.
    @MainActor
    func testAnAppLinkArrivingBeforeAnyListenerIsHeldAndThenDelivered() {
        InviteLinkBridge.shared.resetForTesting()
        defer { InviteLinkBridge.shared.resetForTesting() }

        let url = URL(string: "myrobotaxi://join/RBO246")!
        InviteLinkBridge.shared.receive(url)
        XCTAssertTrue(InviteLinkBridge.shared.hasPendingLinkForTesting)

        var delivered: [URL] = []
        InviteLinkBridge.shared.install { delivered.append($0) }

        XCTAssertEqual(delivered, [url])
        XCTAssertFalse(InviteLinkBridge.shared.hasPendingLinkForTesting)
    }

    // MARK: Paste inherits the new shape for free

    /// `InviteCodeEntry.extractCode`'s pass 0 reads a token STRUCTURALLY through
    /// `InviteLink.code(from:)`, so an app link pasted into the six cells now
    /// resolves too — no second parser, and no change to that file.
    func testPastingAnAppLinkFindsTheCode() {
        XCTAssertEqual(InviteCodeEntry.extractCode(from: "myrobotaxi://join/RBO246"), "RBO246")
        XCTAssertEqual(
            InviteCodeEntry.extractCode(from: "open this: myrobotaxi://join/ABCDEF?from=Thomas"),
            "ABCDEF",
            "an all-letter code in a link must beat the sender's name, structurally"
        )
    }
}
