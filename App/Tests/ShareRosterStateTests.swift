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

    /// MYR-386 — the matrix below is about a COMPLETED fetch, which is what every
    /// one of these assertions has always meant. Stating it once here keeps each
    /// test about its own subject; the phase gets its own section at the bottom.
    private func resolve(
        phase: ShareRosterLoadPhase = .loaded,
        viewers: [Viewer] = [],
        pending: [PendingInvite] = []
    ) -> ShareRosterState {
        ShareRosterState.resolve(phase: phase, viewers: viewers, pending: pending)
    }

    // MARK: The four arms

    func testNothingSharedAndNothingPendingIsTheHeroEmptyState() {
        XCTAssertEqual(resolve(viewers: [], pending: []), .empty)
    }

    /// THE CLIENT'S OWN STATE. Before MYR-347 this rendered "VIEWERS · 0", a
    /// consolation sentence and a second header over one row.
    func testPendingOnlyRendersExactlyOneSectionAndNoViewersHeader() {
        let state = resolve(viewers: [], pending: [invite("Diego Vega")])
        guard case .populated(let sections) = state else { return XCTFail("expected content") }
        XCTAssertEqual(sections.map(\.id), ["invited"])
        XCTAssertEqual(sections[0].title, "Invited")
        XCTAssertEqual(sections[0].count, 1)
    }

    func testAcceptedOnlyRendersExactlyOneSectionAndNoInvitedHeader() {
        let state = resolve(viewers: [viewer("Mira Chen")], pending: [])
        guard case .populated(let sections) = state else { return XCTFail("expected content") }
        XCTAssertEqual(sections.map(\.id), ["accepted"])
        XCTAssertEqual(sections[0].title, "Shared with")
        XCTAssertEqual(sections[0].count, 1)
    }

    func testMixedRendersBothSectionsWithAcceptedFirst() {
        let state = resolve(
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
                let state = resolve(
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
                case .loading, .unavailable:
                    // MYR-386 — unreachable from `.loaded`, which is the phase
                    // this whole matrix is about. Asserted rather than defaulted
                    // so a future arm cannot be swallowed by a `default:`.
                    XCTFail("a completed fetch resolved to \(state)")
                }
            }
        }
    }

    /// The empty arm means what its copy says — nothing accepted AND nothing
    /// pending. One row of either kind takes the screen out of it, which is what
    /// keeps the hero from ever appearing over a list (MYR-343's lesson about a
    /// gate that answered a different question than its copy).
    func testOneRowOfEitherKindLeavesTheEmptyState() {
        XCTAssertNotEqual(resolve(viewers: [viewer("A")], pending: []), .empty)
        XCTAssertNotEqual(resolve(viewers: [], pending: [invite("B")]), .empty)
    }

    // MARK: - MYR-386 — the fetch's phase
    //
    // THE CLIENT'S REPORT (TestFlight, build 202607311129): *"Need to add the
    // skeleton loading to this page. It flashes no one added then appears."*
    //
    // `ShareService` had published `isLoading` and `statusMessage` since MYR-184
    // and this screen read NEITHER, so the whole render came off two arrays that
    // start `[]`. An empty array in flight and an empty array that came back empty
    // are the same value, and the screen answered both with the definitive,
    // CTA-bearing hero.

    /// THE DEFECT, as an assertion: a fetch that is genuinely running renders
    /// skeletons, not "no one has access yet".
    func testAnInFlightFetchRendersSkeletonsRatherThanTheEmptyState() {
        XCTAssertEqual(resolve(phase: .loading, viewers: [], pending: []), .loading)
    }

    /// `.idle` shimmers WITH `.loading`, deliberately. `InvitesScreen.task` calls
    /// `load()` unconditionally on appear, so on this screen "not asked yet" is
    /// always "about to ask" — and splitting them would put the empty hero on
    /// screen for exactly the one frame the client photographed.
    func testNotYetAskedRendersSkeletonsToo() {
        XCTAssertEqual(resolve(phase: .idle, viewers: [], pending: []), .loading)
    }

    /// The other half of the fix, and the reason the phase is not just a
    /// `Bool`: the empty state is reachable ONLY from a completed fetch.
    func testTheEmptyStateIsReachableOnlyFromACompletedFetch() {
        for phase: ShareRosterLoadPhase in [.idle, .loading, .failed("nope")] {
            XCTAssertNotEqual(
                resolve(phase: phase, viewers: [], pending: []), .empty,
                "\(phase) claimed the account has shared with nobody"
            )
        }
        XCTAssertEqual(resolve(phase: .loaded, viewers: [], pending: []), .empty)
    }

    /// A FAILED read is its own state and carries the service's sentence. "No one
    /// has access yet" over a list that simply did not load is a lie of exactly
    /// the kind MYR-343 removed from the rider shell — and a worse one here,
    /// because an owner who believes it will re-send an invite that already
    /// landed.
    func testAFailedFetchIsNeverTheEmptyState() {
        XCTAssertEqual(
            resolve(phase: .failed(LiveShareService.unreadableMessage), viewers: [], pending: []),
            .unavailable(LiveShareService.unreadableMessage)
        )
    }

    /// ROWS IN HAND OUTRANK EVERY PHASE. `LiveShareService` re-reads the whole
    /// list after every mutation and on every appearance of the tab, so a
    /// mid-flight or failed re-read that blanked a populated roster into a
    /// skeleton — or into a failure screen — would make a revoke look like the
    /// list falling over. Same rule `LiveSharedVehicleCatalog` applies when it
    /// leaves the last-known grants standing.
    func testARefreshNeverBlanksARosterAlreadyOnScreen() {
        for phase: ShareRosterLoadPhase in [.idle, .loading, .loaded, .failed("nope")] {
            let state = resolve(phase: phase, viewers: [viewer("Mira Chen")], pending: [invite("Diego Vega")])
            guard case .populated(let sections) = state else {
                return XCTFail("\(phase) discarded rows that were already in hand")
            }
            XCTAssertEqual(sections.map(\.id), ["accepted", "invited"])
        }
    }

    /// The skeleton is a PROMISE (MYR-326), so no phase may shimmer forever. Only
    /// the two phases that precede an answer resolve to `.loading`; both terminal
    /// phases resolve to something that stands still.
    func testOnlyAnUnansweredFetchShimmers() {
        XCTAssertNotEqual(resolve(phase: .loaded, viewers: [], pending: []), .loading)
        XCTAssertNotEqual(resolve(phase: .failed("nope"), viewers: [], pending: []), .loading)
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
        // MYR-369 — `.history` is retired; `.rides` is the other surviving preset.
        XCTAssertEqual(
            ShareInviteDetail.line(tier: .rides, sent: "expired"),
            "Location + rides \u{00B7} Invite expired"
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
            "Location \u{00B7} Invited 2d ago"
        )
        XCTAssertEqual(ShareInviteDetail.line(tier: nil, sent: "2d ago"), "Invited 2d ago")
    }
}
