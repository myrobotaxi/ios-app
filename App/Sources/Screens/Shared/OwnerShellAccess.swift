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

// MARK: - MYR-455 — the STORED mode had to be re-asked, and the question is not
// the same one.
//
// **THE DEFECT MYR-441 LEFT OPEN.** That issue gated exactly one transition —
// an account already in the rider shell asking to leave it — and said so in as
// many words above. What it could not gate is a mode ALREADY PERSISTED:
// `RootView.routeAfterAuth` reads the stored `ViewMode` and hands it straight to
// `applyViewMode`, so a viewer who reached owner mode by ANY pre-fix door boots
// back into it on every launch, for ever. `modeStore.clearMode` runs on sign-out
// alone, so the gate arriving in a later build does not reach a choice already
// written to disk. **A guard on the transition is not a guard on the state.**
//
// **⚠️ THE REVOCATION RULE IS NOT `!offersOwnerMode`, AND THAT IS THE WHOLE
// SUBTLETY.** Both are claims, and each must be conservative in its OWN
// direction:
//
//   • OFFERING is a claim that an owner shell exists for you, so `.resolving`
//     and `.unavailable` offer NOTHING (MYR-386: never render an end state
//     before the fetch that would justify it).
//   • REVOKING is a claim that it does NOT, and the same two arms must therefore
//     TAKE NOTHING AWAY. Spelling this `!offersOwnerMode` would demote every
//     genuine owner during the resolving window of every cold launch — a flash
//     from the owner shell to the rider shell and back, which is MYR-343's
//     defect re-entered from the far side by the very code meant to be honest.
//
// So exactly ONE arm revokes: an account the list POSITIVELY reported as holding
// shared grants and nothing of its own. `.empty` keeps the shell (MYR-441's
// fresh-owner-pre-link reasoning, unchanged — Add-Tesla lives there).
//
// The two rules are asserted AGAINST EACH OTHER in `OwnerShellAccessTests`
// rather than derived from each other, so the one account shape where both are
// defined can never disagree.

/// What the account's own `GET /api/vehicles` list says about its standing in
/// the OWNER shell. The same §7.0 split `SharedVehicleCatalog` publishes to the
/// rider side (`role == .viewer` vs not), read from the owner's side of the
/// seam — one wire fact, two readers, and `OwnerShellStandingTests` pins that
/// they partition identically.
enum OwnerShellStanding: Equatable, Sendable {
    /// No answer yet. Claims nothing in either direction.
    case resolving
    /// The read failed. NOT evidence of anything (MYR-326: loading ≠
    /// unavailable, and neither is evidence of absence).
    case unavailable
    /// At least one owned row — a genuine owner.
    case owns
    /// The list ANSWERED: zero owned rows, at least one viewer grant. The only
    /// configuration this issue removes.
    case grantsOnly
    /// The list answered and was empty. A fresh owner who has not linked a Tesla
    /// yet — the owner shell is where Add-Tesla lives.
    case noVehicles

    /// Resolve from the two partition SIZES of the account's §7.0 list.
    ///
    /// Counts rather than rows, so this stays pure Foundation and the whole
    /// matrix is assertable with no catalog, no wire type and no view — the same
    /// property `offersOwnerMode` is written for. The partition itself is
    /// `VehicleRowPartition.isViewerRow`, the ONE predicate the rider catalog
    /// already splits on, so the two sides of the app cannot disagree about which
    /// half a row is in.
    ///
    /// **Any row that is not explicitly `viewer` counts as owned**, verbatim
    /// `LiveSharedVehicleCatalog.ownedVehicles(from:)`'s reasoning: a role this
    /// build cannot rank is far likelier to be a new ownership-shaped role than a
    /// share, and guessing that way fails OPEN — the account keeps the shell it
    /// chose, and every capability is server-enforced regardless.
    static func resolve(hasLoaded: Bool, loadFailed: Bool, ownedCount: Int, grantCount: Int) -> OwnerShellStanding {
        guard hasLoaded else { return loadFailed ? .unavailable : .resolving }
        if ownedCount > 0 { return .owns }
        return grantCount > 0 ? .grantsOnly : .noVehicles
    }
}

enum OwnerShellAccess {

    /// Must this account be TAKEN OUT of the owner shell it is currently in?
    ///
    /// The counterpart to `offersOwnerMode`, and deliberately NOT its negation —
    /// see the note above. True for exactly one standing.
    static func revokesOwnerMode(standing: OwnerShellStanding) -> Bool {
        standing == .grantsOnly
    }

    /// The WHOLE boot-revalidation decision, as one pure function.
    ///
    /// `RootView.revalidateOwnerModeIfNeeded` is a two-line call into this plus
    /// the two writes it authorizes, so every arm of the decision is assertable
    /// with no view, no store and no session — including the two guards that are
    /// easiest to get wrong by reading:
    ///
    ///   • **Only from the owner shell.** A rider is not in the shell this
    ///     revokes, and demoting them would be a no-op that still rewrites their
    ///     stored mode on every list read.
    ///   • **Only with a real account.** The demotion PERSISTS `.rider`, and
    ///     `modeStore` is keyed by user id — there is nothing to write against on
    ///     the SIM / static-token path, which is also what keeps every simulated
    ///     and DEBUG scene byte-identical.
    static func demotesToRider(
        isInOwnerShell: Bool,
        standing: OwnerShellStanding,
        hasSignedInAccount: Bool
    ) -> Bool {
        guard isInOwnerShell, hasSignedInAccount else { return false }
        return revokesOwnerMode(standing: standing)
    }

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
