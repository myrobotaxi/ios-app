import SwiftUI
import DesignSystem

// MARK: - RiderOwnerModeChip (MYR-397 item 2)
//
// *"No way to switch back to owner mode from here."* — the rider tracking map has
// no `MapHeader`, no nav (MYR-198 hides it past idle) and no Settings route, so an
// owner who switched to rider mode to test a ride was stuck on that surface until
// the ride ended.
//
// CLIENT CONSTRAINT (2026-07-31): **render it ONLY for accounts that actually hold
// an owner role.** A viewer who has never linked a Tesla has no owner shell to
// flip to; offering one would either dead-end on the mode chooser or, worse, land
// them in a shell with no vehicle in it — MYR-343's defect pointed the other way.
//
// **THE ROLE IS THE OWNED-VEHICLES PARTITION, NOT A SECOND ANSWER TO THE SAME
// QUESTION.** `SharedVehicleCatalog` already splits the ONE `GET /api/vehicles`
// list into `grants` (viewer rows) and `ownedVehicles` (owner rows, which carry no
// `sharePermission` at all), and `RiderVehicleSet.resolve` is the rule over it.
// This chip reads the SAME partition — `holdsOwnerRole` is `!ownedVehicles
// .isEmpty` — so the tab that says "Your car · Ride from it anytime" (MYR-354) and
// this chip can never disagree about whether the account owns anything. Deriving
// it from anything else (a stored `ViewMode`, a profile flag, the presence of a
// linked Tesla in Settings) would be a second source of truth for one fact, which
// is how one surface ends up offering a shell another surface says does not exist.
//
// It is live-path-only by construction: `SimulatedSharedVehicleCatalog
// .ownedVehicles` is empty, so no simulated boot and no pre-existing DEBUG scene
// renders it and every tracking capture is byte-identical.

/// The gate, as a pure function so the whole matrix is assertable.
enum RiderOwnerModeChipGate {
    /// - Parameters:
    ///   - holdsOwnerRole: does the account own at least one linked vehicle?
    ///   - canSwitchModes: is there a real signed-in account to persist a mode
    ///     choice for? `switchViewMode()` no-ops without one, and a chip whose tap
    ///     does nothing is worse than no chip.
    static func showsChip(holdsOwnerRole: Bool, canSwitchModes: Bool) -> Bool {
        holdsOwnerRole && canSwitchModes
    }
}

/// The compact owner chip, in `MapHeader`'s grammar — the same capsule fill,
/// hairline, height, shadow and physical-edge top offset the vehicle switcher
/// uses, so the two read as one piece of map chrome rather than two.
///
/// Trailing-aligned rather than centred: `MapHeader`'s own slot is the centre of
/// this band and, when the rider tracking map grows one, the two must not collide.
struct RiderOwnerModeChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
                Text("Owner")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
            }
            .padding(.horizontal, 13)
            .frame(height: MRTMetrics.mapChipHeight)
            // ≥44pt tap target over a 40pt chip — `MapHeader.chip`'s own trick.
            .contentShape(Rectangle().inset(by: -2))
            .background(Color.mrtMapChipFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
        .accessibilityIdentifier("mrt.tracking.ownerModeChip")
        .accessibilityLabel("Switch to owner mode")
        // Full-bleed geometry (CLAUDE.md): `mapHeaderTop` is 60pt from the
        // PHYSICAL screen top on the prototype's 393×852 canvas. Building inside
        // the default safe area would stack the ~59pt status-bar inset on top of
        // it — the MYR-196 punch-list bug.
        .padding(.top, MRTMetrics.mapHeaderTop)
        .padding(.trailing, MRTMetrics.pageGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .ignoresSafeArea(edges: .top)
    }
}
