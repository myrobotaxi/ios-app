import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-347 — the Share tab's state matrix
//
// The client's complaint was a STATE the screen did not have: "weird text in the
// middle saying viewers 0 and then one pending request below". The prototype
// rendered the viewers header unconditionally, so an account with nothing
// accepted and one invite out got a header counting to zero.
//
// These tests are over `ShareRosterState.resolve`, which is the whole rule. The
// invariant that matters is structural rather than cosmetic: an empty section is
// NOT IN THE MODEL, so no view can render a header for one even by mistake.
final class ShareRosterStateTests: XCTestCase {

    private func viewer(_ name: String, perm: String = "Live location") -> Viewer {
        Viewer(name: name, email: nil, online: false, perm: perm, tier: .live)
    }

    private func invite(_ name: String) -> PendingInvite {
        PendingInvite(name: name, email: nil, code: "RBO246", sent: "2d ago", tier: .live)
    }

    // MARK: The four arms

    func testNothingSharedAndNothingPendingIsTheHeroEmptyState() {
        XCTAssertEqual(ShareRosterState.resolve(viewers: [], pending: []), .empty)
    }

    /// THE CLIENT'S OWN STATE. Before MYR-347 this rendered "VIEWERS · 0", a
    /// consolation sentence and a second header over one row.
    func testPendingOnlyRendersExactlyOneSectionAndNoViewersHeader() {
        let state = ShareRosterState.resolve(viewers: [], pending: [invite("Diego Vega")])
        guard case .populated(let sections) = state else { return XCTFail("expected content") }
        XCTAssertEqual(sections.map(\.id), ["invited"])
        XCTAssertEqual(sections[0].title, "Invited")
        XCTAssertEqual(sections[0].count, 1)
    }

    func testAcceptedOnlyRendersExactlyOneSectionAndNoInvitedHeader() {
        let state = ShareRosterState.resolve(viewers: [viewer("Mira Chen")], pending: [])
        guard case .populated(let sections) = state else { return XCTFail("expected content") }
        XCTAssertEqual(sections.map(\.id), ["accepted"])
        XCTAssertEqual(sections[0].title, "Shared with")
        XCTAssertEqual(sections[0].count, 1)
    }

    func testMixedRendersBothSectionsWithAcceptedFirst() {
        let state = ShareRosterState.resolve(
            viewers: [viewer("Mira Chen"), viewer("Jonas Park")],
            pending: [invite("Diego Vega")]
        )
        guard case .populated(let sections) = state else { return XCTFail("expected content") }
        XCTAssertEqual(sections.map(\.id), ["accepted", "invited"])
        XCTAssertEqual(sections.map(\.count), [2, 1])
    }

    // MARK: The invariant the client actually reported

    /// The structural form of "no orphaned section headers": across every
    /// combination of list sizes, a section that exists has rows in it. There is
    /// no arrangement of inputs that produces a zero count, so the "· 0" header
    /// is unreachable rather than merely unrendered.
    func testNoResolvedSectionIsEverEmpty() {
        for viewerCount in 0...3 {
            for pendingCount in 0...3 {
                let state = ShareRosterState.resolve(
                    viewers: (0..<viewerCount).map { viewer("Viewer \($0)") },
                    pending: (0..<pendingCount).map { invite("Invite \($0)") }
                )
                switch state {
                case .empty:
                    XCTAssertEqual(viewerCount + pendingCount, 0, "empty only when both lists are")
                case .populated(let sections):
                    XCTAssertFalse(sections.isEmpty)
                    for section in sections {
                        XCTAssertGreaterThan(
                            section.count, 0,
                            "\(section.title) rendered with \(viewerCount)/\(pendingCount)"
                        )
                    }
                }
            }
        }
    }

    /// The empty arm means what its copy says — nothing accepted AND nothing
    /// pending. One row of either kind takes the screen out of it, which is what
    /// keeps the hero from ever appearing over a list (MYR-343's lesson about a
    /// gate that answered a different question than its copy).
    func testOneRowOfEitherKindLeavesTheEmptyState() {
        XCTAssertNotEqual(ShareRosterState.resolve(viewers: [viewer("A")], pending: []), .empty)
        XCTAssertNotEqual(ShareRosterState.resolve(viewers: [], pending: [invite("B")]), .empty)
    }

    // MARK: Copy

    /// "Shared with", NOT "Riding with you". The accepted list holds every tier
    /// and `live` — the composer's default — grants location only; §7.5.0 has the
    /// server 403 a ride created below `rides`. A header asserting rides about
    /// this list would be the `riderWatchOnly` mistake from the owner's side.
    /// It is also the header `SettingsScreen` already puts over the same rows.
    func testTheAcceptedHeaderDoesNotClaimRideAccess() {
        let section = ShareRosterSection.accepted([viewer("Mira Chen", perm: "Live location")])
        XCTAssertEqual(section.title, "Shared with")
        XCTAssertFalse(section.title.lowercased().contains("rid"))
    }

    // MARK: The invited row's detail line
    //
    // `PendingInvite.sent` is TWO vocabularies — the simulated service writes the
    // prototype's bare relative and `LiveShareService.sentLabel` writes a sentence
    // fragment ("sent 2d ago") plus two non-ages ("sent", "expired"). Prefixing it
    // unexamined put "Invited sent 2d ago" into the first live capture of this
    // screen, which is why the composition is a named function with its own tests.

    func testTheSimulatedRelativeReadsAsOneSentence() {
        XCTAssertEqual(ShareInviteDetail.ageClause("2d ago"), "Invited 2d ago")
        XCTAssertEqual(ShareInviteDetail.ageClause("just now"), "Invited just now")
    }

    func testTheLiveSentPrefixIsNotDoubled() {
        XCTAssertEqual(ShareInviteDetail.ageClause("sent 2d ago"), "Invited 2d ago")
        XCTAssertEqual(ShareInviteDetail.ageClause("sent 5m ago"), "Invited 5m ago")
    }

    /// §7.5.2 — expiry is not a status, so an expired invite is still `pending`
    /// and sits in the same list as a live one. It must SAY so; "Invited expired"
    /// would read as a date.
    func testAnExpiredInviteSaysItIsExpiredRatherThanBeingAged() {
        XCTAssertEqual(ShareInviteDetail.ageClause("expired"), "Invite expired")
        XCTAssertEqual(
            ShareInviteDetail.line(tier: .history, sent: "expired"),
            "Live + history \u{00B7} Invite expired"
        )
    }

    /// `sentLabel` falls back to a bare "sent" when `createdAt` will not parse.
    /// There is no age to state, so none is invented.
    func testAnUnparseableCreatedAtStatesNoAge() {
        XCTAssertEqual(ShareInviteDetail.ageClause("sent"), "Invited")
        XCTAssertEqual(ShareInviteDetail.ageClause(""), "Invited")
    }

    func testTheTierLeadsTheDetailLineAndIsOmittedWhenUnknown() {
        XCTAssertEqual(
            ShareInviteDetail.line(tier: .live, sent: "2d ago"),
            "Live location \u{00B7} Invited 2d ago"
        )
        XCTAssertEqual(ShareInviteDetail.line(tier: nil, sent: "2d ago"), "Invited 2d ago")
    }
}
