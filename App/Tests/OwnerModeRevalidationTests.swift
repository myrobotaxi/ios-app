import DesignSystem
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-455 — a STORED owner mode is re-asked, and the owner fleet stops
// adopting the viewer half of its own list.
//
// THE REPORT (external beta, build 202608030843): James Guan, a GUEST holding
// one viewer grant on Thomas's car, used "Switch to Owner" and got the FULL
// owner vehicle-detail surface for that car — the name, the charge, the
// position, and the Lock / Climate / Trunk / Charge control row.
//
// TWO defects, and MYR-441 closed neither of them:
//
//  1. THE ROUTE. MYR-441 gated `switchViewMode`, the one door that ASKS. The
//     stored mode is applied by `routeAfterAuth` without asking, and
//     `clearMode` runs only on sign-out — so an account that reached owner mode
//     before the gate shipped boots back into it on every launch, for ever.
//     A guard on a transition is not a guard on a state.
//
//  2. THE RENDER. `GET /api/vehicles` returns one list holding BOTH the
//     account's own cars and every share it has redeemed. MYR-343 split them
//     for the rider shell; the OWNER fleet never did, so a viewer grant was
//     adopted as if owned. That is why MYR-441's "a shell of EMPTY control
//     tiles" was wrong about its own defect — the shared row carries real data
//     and the §7.1 snapshot is readable under the MYR-435 viewer mask, so what
//     renders is a live-looking sheet with four "Syncing" tiles on it.
//
// BLAST RADIUS, stated because the issue asks for it to be proved rather than
// assumed: NOTHING could actuate. §7.9 is owner-only at the routing layer and
// answers `403 vehicle_not_owned`, as do the plate (§7.14), refresh (§7.15),
// service-window (§7.16) and ride-share (§7.18) writes — rest-api.md §7.5.0:
// "Sharing never grants writes." So this is a mis-scoped UI making a claim
// about a relationship the account does not have, not an authorization hole.
@MainActor
final class OwnerModeRevalidationTests: XCTestCase {

    // MARK: - The pure standing

    func testAListStillInFlightClaimsNothing() {
        XCTAssertEqual(
            OwnerShellStanding.resolve(hasLoaded: false, loadFailed: false, ownedCount: 0, grantCount: 0),
            .resolving
        )
    }

    func testAListThatDidNotAnswerClaimsNothing() {
        XCTAssertEqual(
            OwnerShellStanding.resolve(hasLoaded: false, loadFailed: true, ownedCount: 0, grantCount: 3),
            .unavailable
        )
    }

    func testAnAccountHoldingOnlyGrantsIsTheOneStandingThisIssueRemoves() {
        XCTAssertEqual(
            OwnerShellStanding.resolve(hasLoaded: true, loadFailed: false, ownedCount: 0, grantCount: 1),
            .grantsOnly
        )
    }

    func testOwningAnythingAtAllOutranksEveryGrant() {
        XCTAssertEqual(
            OwnerShellStanding.resolve(hasLoaded: true, loadFailed: false, ownedCount: 1, grantCount: 9),
            .owns
        )
    }

    /// MYR-441's edge, preserved verbatim: no vehicles at all is a FRESH OWNER
    /// pre-link, and the owner shell is where Add-Tesla lives. Demoting them
    /// would strand them in a rider shell with no car and no way to get one.
    func testAnAccountWithNoVehiclesAtAllIsAFreshOwnerAndKeepsTheShell() {
        XCTAssertEqual(
            OwnerShellStanding.resolve(hasLoaded: true, loadFailed: false, ownedCount: 0, grantCount: 0),
            .noVehicles
        )
        XCTAssertFalse(OwnerShellAccess.revokesOwnerMode(standing: .noVehicles))
    }

    // MARK: - The revocation rule, and its asymmetry with the offer

    /// ⚠️ THE LOAD-BEARING TEST OF THIS WHOLE ISSUE.
    ///
    /// The natural spelling of the revocation is `!offersOwnerMode`, and it is
    /// WRONG. Offering and revoking are both CLAIMS, and each must be
    /// conservative in its own direction: the two unresolved arms offer nothing
    /// AND take nothing away. Spelled as a negation, every genuine owner would
    /// be demoted during the resolving window of every cold launch — the owner
    /// shell flashing to the rider shell and back, which is MYR-343's defect
    /// re-entered by the code written to be honest about it.
    func testRevocationIsNotTheNegationOfTheOfferOnTheTwoUnRESOLVEDARMS() {
        for standing in [OwnerShellStanding.resolving, .unavailable] {
            XCTAssertFalse(
                OwnerShellAccess.revokesOwnerMode(standing: standing),
                "\(standing) must take nothing away — a list that has not answered is not evidence"
            )
        }
        // And the corresponding vehicle sets offer nothing either, so on these
        // two arms BOTH rules say no. That is the asymmetry, in one assertion.
        XCTAssertFalse(OwnerShellAccess.offersOwnerMode(vehicleSet: .resolving, canSwitchModes: true))
        XCTAssertFalse(OwnerShellAccess.offersOwnerMode(vehicleSet: .unavailable, canSwitchModes: true))
    }

    /// The one account shape where both rules ARE defined must get one answer.
    /// Asserted against each other rather than derived from each other, so a
    /// future edit to either cannot silently split them.
    func testTheOfferAndTheRevocationAgreeOnEveryRESOLVEDShape() {
        // Grants only: not offered, and revoked.
        let sharedSet = RiderVehicleSet.ridable(
            RiderVehicleAdoption(source: .shared, vehicle: nil, tier: .rides)
        )
        XCTAssertFalse(OwnerShellAccess.offersOwnerMode(vehicleSet: sharedSet, canSwitchModes: true))
        XCTAssertTrue(OwnerShellAccess.revokesOwnerMode(standing: .grantsOnly))

        // A genuine owner: offered, and never revoked.
        let ownedSet = RiderVehicleSet.ridable(
            RiderVehicleAdoption(source: .owned, vehicle: nil, tier: nil)
        )
        XCTAssertTrue(OwnerShellAccess.offersOwnerMode(vehicleSet: ownedSet, canSwitchModes: true))
        XCTAssertFalse(OwnerShellAccess.revokesOwnerMode(standing: .owns))

        // A fresh owner pre-link: offered, and never revoked.
        XCTAssertTrue(OwnerShellAccess.offersOwnerMode(vehicleSet: .empty, canSwitchModes: true))
        XCTAssertFalse(OwnerShellAccess.revokesOwnerMode(standing: .noVehicles))
    }

    // MARK: - The whole boot decision

    /// THE CLIENT'S ACCOUNT: a grants-only guest whose device persisted `.owner`
    /// before MYR-441 shipped. This is the migration — the demotion fires on the
    /// first launch that gets an answer, and `RootView` persists `.rider` with
    /// it, so it happens at most once per account.
    func testAPreFixPersistedOwnerModeIsDemotedOnceTheListAnswers() {
        XCTAssertTrue(OwnerShellAccess.demotesToRider(
            isInOwnerShell: true,
            standing: .grantsOnly,
            hasSignedInAccount: true
        ))
    }

    /// NO FLASH, AND NO EMPTY SHELL: the two arms a cold launch passes THROUGH
    /// on its way to an answer must move nobody. A real owner's boot sequence is
    /// `.resolving` → `.owns`, and neither step may demote.
    func testARealOwnerIsUntouchedAtEveryStepOfAColdLaunch() {
        for standing in [OwnerShellStanding.resolving, .owns] {
            XCTAssertFalse(OwnerShellAccess.demotesToRider(
                isInOwnerShell: true,
                standing: standing,
                hasSignedInAccount: true
            ), "a genuine owner must never be demoted at \(standing)")
        }
    }

    /// A network blink is not evidence of anything. Without this arm, an owner
    /// on a bad connection would be demoted out of their own shell and would
    /// have the demotion PERSISTED against them.
    func testAFailedListNeverDemotesAnyone() {
        XCTAssertFalse(OwnerShellAccess.demotesToRider(
            isInOwnerShell: true,
            standing: .unavailable,
            hasSignedInAccount: true
        ))
    }

    /// The rider shell is not the shell this revokes. Firing there would rewrite
    /// a stored mode on every list read for no reason.
    func testARiderIsNotDemotedOutOfAShellTheyAreNotIn() {
        XCTAssertFalse(OwnerShellAccess.demotesToRider(
            isInOwnerShell: false,
            standing: .grantsOnly,
            hasSignedInAccount: true
        ))
    }

    /// The demotion PERSISTS `.rider`, and `modeStore` is keyed by user id —
    /// there is nothing to write against on the SIM / static-token path. This is
    /// also what keeps every simulated and DEBUG scene byte-identical, since
    /// `SimulatedAuthSession.currentUser` is nil by construction.
    func testNothingIsDemotedWithoutAnAccountToPersistTheChoiceAgainst() {
        XCTAssertFalse(OwnerShellAccess.demotesToRider(
            isInOwnerShell: true,
            standing: .grantsOnly,
            hasSignedInAccount: false
        ))
    }

    // MARK: - The owner fleet, over the REAL wire

    private func makeFleet(_ items: [VehicleSummary]) -> LiveVehicleFleet {
        LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: StubHTTP(status: 200, body: Contracts.listResponse(items)),
            channelFactory: ParkedChannelFactory()
        ))
    }

    private func viewerRow(_ id: String, name: String) -> VehicleSummary {
        Contracts.summary(vehicleId: id, name: name, role: .viewer, sharePermission: .rides)
    }

    private func ownedRow(_ id: String, name: String) -> VehicleSummary {
        Contracts.summary(vehicleId: id, name: name, role: .owner)
    }

    /// THE SCREENSHOT, AS A TEST. A grants-only account's owner shell must hold
    /// NO vehicle — so there is no row to select, no sheet to render and no
    /// control tile to draw over somebody else's car.
    func testTheOwnerFleetRefusesTheViewerHalfOfItsOwnList() async {
        let fleet = makeFleet([viewerRow("lunar", name: "Lunar")])
        fleet.start()
        await eventually { fleet.ownerShellStanding != .resolving }

        XCTAssertTrue(fleet.vehicles.isEmpty, "a shared car must never enter the OWNER fleet")
        XCTAssertEqual(fleet.ownerShellStanding, .grantsOnly)
        fleet.stop()
    }

    /// The mixed account is the shape the mode fix alone would NOT have saved:
    /// it owns a car, so it passes every ownership gate legitimately, and its
    /// owner shell was still rendering control tiles for a car it only views.
    func testAMixedAccountSeesOnlyItsOwnCarInTheOwnerShell() async {
        let fleet = makeFleet([
            viewerRow("lunar", name: "Lunar"),
            ownedRow("mine", name: "My Model 3"),
        ])
        fleet.start()
        await eventually { !fleet.vehicles.isEmpty }

        XCTAssertEqual(fleet.vehicles.map(\.id), ["mine"])
        XCTAssertEqual(fleet.ownerShellStanding, .owns)
        // The parallel arrays stayed aligned to the FILTERED list — an off-by-one
        // here would hand the owner another car's telemetry.
        XCTAssertEqual(fleet.badgeStatus(at: 0), .parked)
        fleet.stop()
    }

    func testAGenuineOwnerFleetIsUnchanged() async {
        let fleet = makeFleet([ownedRow("v1", name: "Cybercab"), ownedRow("v2", name: "Daily")])
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }

        XCTAssertEqual(fleet.vehicles.map(\.id), ["v1", "v2"])
        XCTAssertEqual(fleet.ownerShellStanding, .owns)
        fleet.stop()
    }

    /// An account with no rows at all is `.noVehicles`, NOT `.grantsOnly` — the
    /// fresh owner keeps the shell. This is why the standing is resolved from
    /// the RAW list before the filter: after it, a grants-only viewer and a
    /// brand-new owner both have zero owned rows and are indistinguishable.
    func testAnEmptyListIsAFreshOwnerRatherThanAViewer() async {
        let fleet = makeFleet([])
        fleet.start()
        await eventually { fleet.ownerShellStanding != .resolving }

        XCTAssertEqual(fleet.ownerShellStanding, .noVehicles)
        XCTAssertFalse(OwnerShellAccess.revokesOwnerMode(standing: fleet.ownerShellStanding))
        fleet.stop()
    }

    func testAFailedListPublishesUnavailableRatherThanAnOwnershipVerdict() async {
        let fleet = LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: StubHTTP(status: 401, body: Contracts.errorEnvelope()),
            channelFactory: ParkedChannelFactory()
        ))
        fleet.start()
        await eventually { fleet.statusMessage != nil }

        XCTAssertEqual(fleet.ownerShellStanding, .unavailable)
        fleet.stop()
    }

    // MARK: - ONE partition, both shells

    /// The owner fleet and the rider catalog split the SAME list, and a second
    /// inline `role == .viewer` in the fleet would have been a second source of
    /// truth for one wire fact — precisely how one account comes to get two
    /// different answers from two surfaces. They share `VehicleRowPartition`;
    /// this asserts the halves are complementary on a mixed list.
    func testBothShellsPartitionOneListIdentically() {
        let rows = [
            viewerRow("lunar", name: "Lunar"),
            ownedRow("mine", name: "My Model 3"),
            viewerRow("bob", name: "Bob's car"),
        ]
        let grants = LiveSharedVehicleCatalog.grants(from: rows)
        let owned = LiveSharedVehicleCatalog.ownedVehicles(from: rows)

        XCTAssertEqual(grants.map(\.id), ["lunar", "bob"])
        XCTAssertEqual(owned.map(\.id), ["mine"])
        XCTAssertEqual(grants.count + owned.count, rows.count, "every row lands in exactly one half")
    }

    /// FAILS OPEN, deliberately. A role this build cannot rank counts as OWNED,
    /// verbatim `ownedVehicles(from:)`'s reasoning — so a newer server emitting
    /// an ownership-shaped role neither hides the car from its owner nor demotes
    /// them out of their shell.
    func testAnUnrecognisedRoleCountsAsOwnedAndDemotesNobody() async {
        let row = Contracts.summary(vehicleId: "v1", name: "Cybercab", role: .unrecognized("co_owner"))
        let fleet = makeFleet([row])
        fleet.start()
        await eventually { fleet.ownerShellStanding != .resolving }

        XCTAssertEqual(fleet.vehicles.map(\.id), ["v1"])
        XCTAssertEqual(fleet.ownerShellStanding, .owns)
        XCTAssertFalse(OwnerShellAccess.revokesOwnerMode(standing: fleet.ownerShellStanding))
        fleet.stop()
    }

    // MARK: - The projection the shell actually reads

    /// MYR-387 defect 2 / `VehicleRideShare.display`: a pure rule with good tests
    /// and the wrong consumer is the quietest regression available. `RootView`
    /// reads the standing through `OwnerHomeState`, so the forwarding is pinned
    /// rather than assumed.
    func testOwnerHomeStateForwardsTheStandingItIsAskedFor() async {
        let fleet = makeFleet([viewerRow("lunar", name: "Lunar")])
        let state = OwnerHomeState(fleet: fleet)
        XCTAssertEqual(state.ownerShellStanding, .resolving)

        fleet.start()
        await eventually { state.ownerShellStanding != .resolving }
        XCTAssertEqual(state.ownerShellStanding, .grantsOnly)
        fleet.stop()
    }

    /// Every simulated and DEBUG capture fleet takes the seam's default, so no
    /// scene can grow a demotion and the whole drift gate is untouched.
    func testTheSimulatedFleetCanNeverRevokeOwnerMode() {
        let fleet = SimulatedVehicleFleet()
        XCTAssertEqual(fleet.ownerShellStanding, .owns)
        XCTAssertFalse(OwnerShellAccess.revokesOwnerMode(standing: fleet.ownerShellStanding))
    }

    // MARK: - Poll helper

    /// The repo's standing per-suite copy (`LiveVehicleFleetTests` et al.) —
    /// each suite keeps its own so no shared harness couples them.
    private func eventually(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}
