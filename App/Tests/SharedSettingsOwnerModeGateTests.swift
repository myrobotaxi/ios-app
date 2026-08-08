import SwiftUI
import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

// MARK: - MYR-441 — the rider Settings "Switch to Owner" row
//
// `OwnerShellAccessTests` proves the RULE. This proves the SCREEN consults it,
// with a real catalog behind it and the real profile gate in front — which is the
// half MYR-369's `VehicleRideShare.display` showed a pure suite cannot reach: that
// function kept passing every one of its own tests while having zero call sites.
//
// The row was gated on `liveProfile != nil` — true of every signed-in rider — so
// the surface external testers walked through is exactly this one.

/// A catalog whose two partitions and load state are settable, so the four
/// account shapes can be driven through the SHIPPING resolution.
@Observable
@MainActor
private final class StubCatalog: SharedVehicleCatalog {
    var grants: [SharedVehicleGrant]
    var ownedVehicles: [Vehicle]
    var hasLoaded: Bool
    var loadFailed: Bool

    init(
        grants: [SharedVehicleGrant] = [],
        ownedVehicles: [Vehicle] = [],
        hasLoaded: Bool = true,
        loadFailed: Bool = false
    ) {
        self.grants = grants
        self.ownedVehicles = ownedVehicles
        self.hasLoaded = hasLoaded
        self.loadFailed = loadFailed
    }

    func load() async {}
    func redeem(code: String) async throws -> RedeemedShare {
        throw ShareRedemptionFailure.unavailable
    }
}

@MainActor
final class SharedSettingsOwnerModeGateTests: XCTestCase {

    private static let viewerGrant = SharedVehicleGrant(
        id: "alex", ownerName: "Alex", relationship: "Roommate",
        vehicleName: "Cybercab", accessLabel: "Request rides",
        tier: .rides, vehicle: nil
    )

    private func screen(
        catalog: StubCatalog,
        profile: UserProfile? = UserProfile(id: "u-1", name: "Thomas Nandola")
    ) -> SharedSettingsScreen {
        SharedSettingsScreen(
            sharedTab: .constant("sharedSettings"),
            liveProfile: profile,
            catalog: catalog,
            onAddCode: {},
            onSignOut: {}
        )
    }

    /// **THE CLIENT'S ACCOUNT.** Signed in, one redeemed share, no car of their
    /// own. Before MYR-441 the row rendered here, because being signed in was the
    /// whole gate.
    func testAViewerOnlyAccountSeesNoOwnerSwitch() {
        let catalog = StubCatalog(grants: [Self.viewerGrant], ownedVehicles: [])
        XCTAssertFalse(
            screen(catalog: catalog).offersOwnerMode,
            "a shared viewer must not be offered a shell with nothing in it"
        )
    }

    /// The owner half — MYR-343's self-riding owner needs the way back.
    func testAnOwnerSeesTheOwnerSwitch() {
        let catalog = StubCatalog(grants: [], ownedVehicles: [VehicleFixtures.vehicles[0]])
        XCTAssertTrue(screen(catalog: catalog).offersOwnerMode)
    }

    /// An account holding BOTH is an owner (MYR-343's "owned wins"), and reads as
    /// one here too — the tab and the map cannot give it two different answers.
    func testAnAccountHoldingBothOwnsSomethingAndKeepsTheSwitch() {
        let catalog = StubCatalog(grants: [Self.viewerGrant], ownedVehicles: [VehicleFixtures.vehicles[0]])
        XCTAssertTrue(screen(catalog: catalog).offersOwnerMode)
    }

    /// **THE EDGE.** A fresh account with nothing at all keeps its path INTO owner
    /// mode, because that is where pairing a first Tesla happens.
    func testAFreshNoVehicleAccountKeepsItsOwnerOnboardingPath() {
        XCTAssertTrue(
            screen(catalog: StubCatalog()).offersOwnerMode,
            "gating this account out would strand a new owner in a rider shell with no car"
        )
    }

    /// A list still in flight, and one that failed, both claim nothing — MYR-354's
    /// rule for the vehicle section one card above, applied to the affordance.
    func testAnUnresolvedCatalogOffersNothing() {
        XCTAssertFalse(
            screen(catalog: StubCatalog(hasLoaded: false)).offersOwnerMode,
            "in flight")
        XCTAssertFalse(
            screen(catalog: StubCatalog(hasLoaded: false, loadFailed: true)).offersOwnerMode,
            "did not answer")
    }

    /// **SIM IS UNCHANGED, WHICH IS WHY NO CAPTURE MOVES.** `liveProfile` is nil on
    /// the simulated path, and that was the ENTIRE gate before this issue — so the
    /// row was already absent from every simulated and DEBUG rider-Settings frame
    /// and still is. Driven through the real simulated catalog, whose grants are
    /// non-empty and whose owned list is not, i.e. the one shape that would newly
    /// lose the row if the profile gate were ever dropped.
    func testTheSimulatedPathRendersNoSwitchRowExactlyAsBefore() {
        let simulated = SimulatedSharedVehicleCatalog()
        XCTAssertFalse(simulated.grants.isEmpty)
        XCTAssertTrue(simulated.ownedVehicles.isEmpty)

        let sim = SharedSettingsScreen(
            sharedTab: .constant("sharedSettings"),
            liveProfile: nil,
            catalog: simulated,
            onAddCode: {},
            onSignOut: {}
        )
        XCTAssertFalse(sim.offersOwnerMode)
    }

    /// The profile half survives on its own: even an OWNER gets no row without an
    /// account to persist the choice against, because `switchViewMode()` would
    /// no-op and a dead control is worse than none.
    func testEvenAnOwnerGetsNoRowWithoutASignedInAccount() {
        let catalog = StubCatalog(ownedVehicles: [VehicleFixtures.vehicles[0]])
        XCTAssertFalse(screen(catalog: catalog, profile: nil).offersOwnerMode)
    }
}
