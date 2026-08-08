import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-441 — who may be offered the owner shell
//
// The client's report, from external testers: *"the rider had access to switch to
// owner mode even if they never linked their own tesla."*
//
// The rule is one pure function over the MYR-343 resolution, so the whole matrix
// is swept here rather than sampled, and the two surfaces that draw the affordance
// (`SharedSettingsScreen`'s "Switch to Owner" row and MYR-397's tracking chip) are
// asserted to read the SAME function rather than two derivations of it.
final class OwnerShellAccessTests: XCTestCase {

    private func adoption(_ source: RiderVehicleAdoption.Source) -> RiderVehicleAdoption {
        RiderVehicleAdoption(
            source: source,
            vehicle: source == .owned ? VehicleFixtures.vehicles[0] : nil,
            tier: source == .shared ? .rides : nil
        )
    }

    // MARK: The defect

    /// **THE BUG, STATED.** A shared viewer holds grants and owns nothing, so
    /// `RiderVehicleSet.resolve` hands back a `.shared` adoption. That account must
    /// not be offered the owner shell: post-MYR-435 what it would find there is a
    /// grid of empty control tiles.
    func testAViewerWithSharedGrantsAndNoOwnedCarIsNotOfferedOwnerMode() {
        XCTAssertFalse(
            OwnerShellAccess.offersOwnerMode(
                vehicleSet: .ridable(adoption(.shared)), canSwitchModes: true),
            "a share is not ownership — this is the exact configuration external testers walked through"
        )
    }

    /// Driven through the REAL catalog resolution rather than a hand-built enum
    /// value, because the thing that has to hold is that a viewer-shaped LIST
    /// produces a viewer-shaped answer. A stub that only ever asserted the enum
    /// would pass with the partition wired backwards.
    @MainActor
    func testAViewerShapedVehicleListResolvesToNoOwnerAffordance() {
        let grants = [
            SharedVehicleGrant(
                id: "alex", ownerName: "Alex", relationship: "Roommate",
                vehicleName: "Cybercab", accessLabel: "Request rides",
                tier: .rides, vehicle: nil
            )
        ]
        let resolved = RiderVehicleSet.resolve(
            hasLoaded: true, loadFailed: false, grants: grants, ownedVehicles: []
        )
        XCTAssertFalse(OwnerShellAccess.offersOwnerMode(vehicleSet: resolved, canSwitchModes: true))
    }

    // MARK: The two accounts that KEEP the affordance

    /// A genuine owner in rider mode (MYR-343's self-ride) needs the way back.
    func testAnOwnerIsOfferedOwnerMode() {
        XCTAssertTrue(
            OwnerShellAccess.offersOwnerMode(
                vehicleSet: .ridable(adoption(.owned)), canSwitchModes: true)
        )
    }

    /// **THE EDGE, AND THE REASON THIS IS NOT `!ownedVehicles.isEmpty`.** An
    /// account with NO vehicles at all is a fresh owner who has not paired a Tesla
    /// yet, and the Add-Tesla flow lives in the owner shell. Gating them out would
    /// strand them in a rider shell with no car and no way to get one — which is
    /// MYR-343's defect re-entered by this issue's own door.
    func testAnAccountWithNoVehiclesAtAllKeepsItsOwnerOnboardingPath() {
        XCTAssertTrue(
            OwnerShellAccess.offersOwnerMode(vehicleSet: .empty, canSwitchModes: true),
            "no vehicles at all is a fresh owner pre-link, not a viewer"
        )
    }

    /// The pair, side by side: the ONE thing that distinguishes them is whether a
    /// SHARE is present. Stated as one assertion so the asymmetry is legible.
    func testHavingSharesIsExactlyWhatWithdrawsTheAffordanceFromACarlessAccount() {
        XCTAssertTrue(OwnerShellAccess.offersOwnerMode(vehicleSet: .empty, canSwitchModes: true))
        XCTAssertFalse(
            OwnerShellAccess.offersOwnerMode(
                vehicleSet: .ridable(adoption(.shared)), canSwitchModes: true),
            "adding one redeemed share is the whole difference between the two accounts"
        )
    }

    // MARK: The unresolved arms claim nothing

    /// MYR-386's rule: an affordance is a claim, and a claim must not be made
    /// before the fetch that would justify it. Recovery is the standing
    /// low-friction one — the catalog re-reads and the row appears.
    func testAnUnresolvedVehicleSetOffersNothing() {
        XCTAssertFalse(OwnerShellAccess.offersOwnerMode(vehicleSet: .resolving, canSwitchModes: true))
        XCTAssertFalse(OwnerShellAccess.offersOwnerMode(vehicleSet: .unavailable, canSwitchModes: true))
    }

    // MARK: The second half of the gate

    /// `switchViewMode()` persists against a user id and no-ops without one, so an
    /// affordance offered on the simulated path would be a control whose tap does
    /// nothing. This is also what keeps every simulated and DEBUG capture
    /// byte-identical: `canSwitchModes` is false there.
    func testNothingIsOfferedWithoutAnAccountToPersistTheChoiceAgainst() {
        for set: RiderVehicleSet in [
            .ridable(adoption(.owned)), .ridable(adoption(.shared)), .empty, .resolving, .unavailable
        ] {
            XCTAssertFalse(
                OwnerShellAccess.offersOwnerMode(vehicleSet: set, canSwitchModes: false),
                "\(set) must offer nothing with no signed-in account"
            )
        }
    }

    // MARK: One rule, two surfaces

    /// MYR-397's tracking chip used to spell its own gate (`!ownedVehicles
    /// .isEmpty`) while the Settings row spelled a weaker one (`liveProfile !=
    /// nil`). Two spellings of one question is how the weaker one came to ship.
    /// The chip delegates now, and this sweeps the whole enum to prove it —
    /// re-implementing the ladder inside `RiderOwnerModeChipGate` would fail here.
    func testTheTrackingChipAndTheSettingsRowAskTheONESameQuestion() {
        for set: RiderVehicleSet in [
            .ridable(adoption(.owned)), .ridable(adoption(.shared)), .empty, .resolving, .unavailable
        ] {
            for canSwitch in [true, false] {
                XCTAssertEqual(
                    RiderOwnerModeChipGate.showsChip(vehicleSet: set, canSwitchModes: canSwitch),
                    OwnerShellAccess.offersOwnerMode(vehicleSet: set, canSwitchModes: canSwitch),
                    "\(set) / canSwitch=\(canSwitch): the chip must not have a second opinion"
                )
            }
        }
    }
}
