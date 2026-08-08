import Foundation

// MARK: - OwnerShellAccess (MYR-441)
//
// **THE DEFECT, IN THE CLIENT'S WORDS (external testers, 2026-08-03):** *"the
// rider had access to switch to owner mode even if they never linked their own
// tesla."*
//
// `switchViewMode()` had NO ownership check and the rider Settings switch row was
// gated on `liveProfile != nil` — i.e. on being SIGNED IN, which every rider is.
// So a shared viewer tapped "Switch to Owner" and landed in the owner shell.
// Nothing leaked: the server applies the MYR-435 viewer mask and every command is
// owner-only. What they got was a **shell of empty control tiles** — a ghost town
// wearing the owner's furniture, which is a dishonest UI rather than a security
// hole, and is exactly the shape MYR-343 fixed pointing the other way (an OWNER in
// rider mode told they had no vehicles).
//
// **THE RULE IS ASKED OF THE MYR-343 PARTITION, NOT RE-DERIVED.**
// `SharedVehicleCatalog` already splits the ONE `GET /api/vehicles` list into
// `grants` (viewer rows) and `ownedVehicles` (owner rows, which carry no
// `sharePermission` at all), and `RiderVehicleSet.resolve` is the ONE rule over
// that split. This gate consults the RESOLUTION rather than the arrays, so the
// rider shell, MYR-354's "Your car · Ride from it anytime" row, MYR-397's tracking
// chip and this switch can never give one account four different answers about
// whether it owns anything. Deriving it from anything else — a stored `ViewMode`,
// a profile flag, the presence of a linked Tesla in the owner's own Settings — is
// a second source of truth for one fact, which is how one surface comes to offer a
// shell another surface says does not exist.
//
// **THE EDGE IS DECIDED HONESTLY, AND IT IS THE REASON THIS IS NOT JUST
// `!ownedVehicles.isEmpty`.** An account with NO VEHICLES AT ALL is a fresh owner
// who has not linked a Tesla yet, and the owner shell is where the Add-Tesla flow
// lives — gating them out would strand them in a rider shell with no car and no
// way to get one. `.empty` therefore OFFERS the switch. The thing this kills is
// narrow and exact: an account holding SHARED GRANTS and ZERO OWNED VEHICLES,
// which is the only configuration that lands in an empty owner shell.
//
// **THE TWO UNRESOLVED ARMS OFFER NOTHING, and that is MYR-386's rule rather than
// timidity.** `.resolving` and `.unavailable` are not evidence of ownership in
// either direction, and an affordance is a CLAIM ("there is an owner shell for
// you") — an honest end state must never be rendered before the fetch that would
// justify it. MYR-354 settled the same question for the vehicle section one card
// above this one: *a list still in flight claims NOTHING*. Recovery is the repo's
// standing low-friction one — the catalog re-reads on resume and the row appears
// when the list answers — so an owner is never trapped, only briefly unoffered.
//
// **THE OTHER TWO DOORS INTO THE OWNER SHELL ARE UNTOUCHED, deliberately.** The
// first-run mode chooser (`RootView.modeChooser` → `modeStore.setMode` +
// `applyViewMode`) and `AddTeslaFlow.onComplete` both reach owner mode WITHOUT
// `switchViewMode`, so a brand-new account still answers "owner or rider?" and
// still lands in the owner shell to pair its first car. This gate governs exactly
// one transition: an account already IN the rider shell asking to leave it.
//
// Pure + static so the whole matrix is assertable with no catalog, no view and no
// clock (`OwnerShellAccessTests`).

enum OwnerShellAccess {

    /// May this account be OFFERED the owner shell?
    ///
    /// - Parameters:
    ///   - vehicleSet: the MYR-343 resolution over the §7.0 list's two partitions.
    ///   - canSwitchModes: is there a real signed-in account to persist a mode
    ///     choice against? `RootView.switchViewMode()` no-ops without one
    ///     (`modeStore.setMode` needs a user id), and an affordance whose tap does
    ///     nothing is worse than no affordance. False in SIM and under the
    ///     static-token dev override, which is what keeps every simulated and
    ///     DEBUG capture byte-identical.
    static func offersOwnerMode(vehicleSet: RiderVehicleSet, canSwitchModes: Bool) -> Bool {
        guard canSwitchModes else { return false }
        switch vehicleSet {
        case .ridable(let adoption):
            // The ONE case this issue removes is `.shared`: a viewer with grants
            // and nothing of their own. `.owned` is a genuine owner self-riding
            // (MYR-343), and the way back to their own shell.
            return adoption.source == .owned
        case .empty:
            // No vehicles at all — a fresh owner pre-link. The owner shell is
            // where Add-Tesla lives, so this is the path IN rather than a shell
            // full of nothing.
            return true
        case .resolving, .unavailable:
            // Not asked yet / did not answer. Claim nothing.
            return false
        }
    }
}
