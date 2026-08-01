import XCTest
import SwiftUI
@testable import MyRoboTaxi

// MARK: - MYR-392 — owner Settings' "Shared with" card
//
// SIBLING OF MYR-386, AND THE WORSE HALF OF IT. That issue fixed the Share tab,
// where the roster's `.task` at least ASKED, so "No one has access yet" was a
// flash. Owner Settings renders the SAME `shareService.viewers` list behind the
// same bare `isEmpty` — and **never called `load()` at all**: the screen's only
// tasks were `pushPrefs.load()` and `prepareAccountDeletion()`, and
// `ShareService.load()` had exactly two call sites, both on `InvitesScreen`.
//
// So on the live path an owner who opened Settings without ever visiting the
// Share tab sat on phase `.idle` with an empty array for the whole session and
// was told, definitively, that nobody had access to their car. Not a frame — a
// permanent false claim, on the page that also offers to REVOKE the access it
// had never read.
//
// Two things therefore have to hold, and only one of them is a pure function:
// the rule below, and the fact that the screen consults it over a roster it
// actually asked for. The second is what `testTheScreenAsksForTheRosterOnAppear`
// covers here and `SettingsSharedWithUITests` proves through a real launch —
// this repo's own MYR-387 lesson, that a pure test proves the RULE and only a
// mounted screen proves the rule is what the screen reads.
@MainActor
final class SettingsSharedWithTests: XCTestCase {

    private func viewer(_ name: String) -> Viewer {
        Viewer(name: name, email: nil, online: false, perm: "Live location")
    }

    private func resolve(
        phase: ShareRosterLoadPhase,
        viewers: [Viewer]
    ) -> SettingsScreen.SharedWithState {
        SettingsScreen.sharedWithState(phase: phase, viewers: viewers)
    }

    // MARK: - The phase decides what an empty list MEANS

    /// THE DEFECT. A fetch that is running (or, on this screen before the fix,
    /// one that was never started) is not an account with nobody on it.
    func testAnInFlightRosterShimmersAndNeverClaimsTheAccountIsEmpty() {
        XCTAssertEqual(resolve(phase: .loading, viewers: []), .loading)
        XCTAssertNotEqual(resolve(phase: .loading, viewers: []), .empty)
    }

    /// `.idle` shimmers WITH `.loading` — legitimate on this surface only because
    /// this issue also gave the screen a `.task` that asks unconditionally on
    /// appear. Pinned so the two arms cannot be split without revisiting that.
    func testIdleShimmersWithLoadingBecauseTheScreenIsAboutToAsk() {
        XCTAssertEqual(resolve(phase: .idle, viewers: []), .loading)
    }

    /// The honest empty state, and the ONLY route to the notice.
    func testTheNoticeIsReachableOnlyFromACompletedFetch() {
        XCTAssertEqual(resolve(phase: .loaded, viewers: []), .empty)
        for phase: ShareRosterLoadPhase in [.idle, .loading, .failed("nope")] {
            XCTAssertNotEqual(
                resolve(phase: phase, viewers: []), .empty,
                "\(phase) can reach the empty notice — that is MYR-386's defect on this page"
            )
        }
    }

    /// A failed read is not an empty list: it carries the SERVICE'S OWN sentence,
    /// which is what keeps this page and the Share tab saying one thing.
    func testAFailedReadSaysSoInTheServicesOwnWords() {
        XCTAssertEqual(
            resolve(phase: .failed(LiveShareService.unreadableMessage), viewers: []),
            .unavailable(LiveShareService.unreadableMessage)
        )
    }

    // MARK: - Rows in hand outrank every phase

    /// `LiveShareService` re-reads the whole list after every mutation, including
    /// the REVOKE this very page performs. A re-read that blanked a populated card
    /// into a skeleton — or into a failure line — would make that revoke look like
    /// the list falling over.
    func testAPopulatedCardSurvivesAReReadAndAFailedOne() {
        let rows = [viewer("Mira"), viewer("Jonas")]
        for phase: ShareRosterLoadPhase in [.idle, .loading, .loaded, .failed("nope")] {
            XCTAssertEqual(
                resolve(phase: phase, viewers: rows), .people(rows),
                "\(phase) blanked a roster the owner is reading"
            )
        }
    }

    // MARK: - This card is about ACCESS, not about invites

    /// It resolves from the ACCEPTED list alone, which is the one place it may not
    /// simply defer to `ShareRosterState.resolve`: that state models the Share
    /// tab's two sections, and this card renders exactly one thing — who can see
    /// the car right now. An account whose only rows are pending invites has
    /// shared with nobody, so the notice is honest there.
    func testPendingInvitesAloneAreStillNobodyWithAccess() {
        XCTAssertEqual(resolve(phase: .loaded, viewers: []), .empty)
        // …and the Share tab, asked about the same account, renders its own
        // populated arm. The two are different questions, not a disagreement.
        XCTAssertEqual(
            ShareRosterState.resolve(phase: .loaded, viewers: [], pending: ShareFixtures.pending),
            .populated([.invited(ShareFixtures.pending)])
        )
    }

    // MARK: - The simulated path is unchanged

    /// Every simulated + DEBUG Settings capture: `.loaded` from the first frame
    /// with the fixture roster in hand, so the card renders exactly what it always
    /// did and no capture can reach a skeleton or a failure line.
    func testTheSimulatedPathCannotReachASkeletonOrAFailure() {
        let service = SimulatedShareService()
        XCTAssertEqual(service.rosterPhase, .loaded)
        XCTAssertEqual(
            resolve(phase: service.rosterPhase, viewers: service.viewers),
            .people(ShareFixtures.viewers)
        )
    }

    // MARK: - The headline: the screen ASKS

    /// **FAILING-FIRST ON THE PRE-FIX SCREEN**, and the whole point of this issue:
    /// `SettingsScreen` had no `.task` that touched the sharing seam, so this
    /// count stayed 0 and the card resolved from an array nobody had fetched.
    ///
    /// Mounted rather than reasoned about, for the reason MYR-387 wrote down: a
    /// pure rule with good tests and the wrong consumer is the quietest regression
    /// available, and `load()` having two call sites on ANOTHER screen is exactly
    /// that shape.
    func testTheScreenAsksForTheRosterOnAppear() async {
        let service = LoadCountingShareService()
        let host = UIHostingController(
            rootView: SettingsScreen(
                shareService: service,
                vehiclesState: OwnerVehiclesState(),
                ownerTab: .constant("settings"),
                onSignOut: {}
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        // `.task` runs on the main actor after the view appears; yield until it
        // has, bounded so a regression fails rather than hangs.
        for _ in 0..<1_000 where service.loadCount == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(
            service.loadCount, 1,
            "owner Settings renders the roster without ever asking for it — MYR-392"
        )
    }
}

// MARK: - The load spy

/// Records the thing that was missing. Everything else answers like the
/// simulated service, so mounting the screen over it is otherwise the simulated
/// path — the only observation being whether anything on that page ever asks.
///
/// File scope rather than nested: `@Observable` cannot be applied to a `private`
/// nested type (its generated extension cannot see it).
@Observable
@MainActor
final class LoadCountingShareService: ShareService {
    private(set) var viewers: [Viewer] = []
    private(set) var pending: [PendingInvite] = []
    var shareableVehicles: [Vehicle] { [] }
    var sharesByCode: Bool { true }
    var rosterPhase: ShareRosterLoadPhase = .idle
    var vehicleRideShare: [VehicleRideShareRow] { [] }
    var loadCount = 0

    func load() async {
        loadCount += 1
        rosterPhase = .loaded
    }
    func createInvite(label: String, tier: ShareAccessLevel, vehicleIDs: [String]) async throws -> ShareHandout? { nil }
    func revoke(_ viewer: Viewer) async throws {}
    func cancelInvite(_ invite: PendingInvite) async throws {}
    func resend(_ invite: PendingInvite) async throws -> ShareHandout? { nil }
    func setVehicleRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws {}
    func setViewerAllowRides(_ allowRides: Bool, viewer: Viewer) async throws {}
    func setViewerSuspended(_ suspended: Bool, viewer: Viewer) async throws {}
}
