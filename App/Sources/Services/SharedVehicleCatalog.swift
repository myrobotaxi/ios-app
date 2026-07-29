import Foundation
import MyRoboTaxiKit
import Observation

// MARK: - Shared-vehicle catalog seam (MYR-184) — the RIDER's half of sharing
//
// Deliberately a SECOND seam alongside `ShareService` rather than a wider
// version of it. They are different people on different screens: an owner mints
// and revokes, a rider redeems and watches. One protocol spanning both would put
// `redeem` within reach of the owner's Share tab and `revoke` within reach of the
// rider's Settings, and neither is a call those surfaces should be able to make.
//
// It answers exactly three questions the rider shell asks:
//   • which vehicles are shared with me, and on what tier  (Settings + Live Map)
//   • can I do <X> with this one                            (client-side gating)
//   • does this code work                                   (InviteCodeFlow)

/// One vehicle shared with the signed-in rider.
///
/// Carries BOTH shapes the two rider surfaces need: the presentational strings
/// the Settings row renders, and — on the live path — the real `Vehicle` the Live
/// Map consumes. Sim rows carry no `Vehicle` at all, which is the point: the
/// prototype's "Shared with me" list is three personas with no vehicle behind
/// them, and inventing one would change the simulated render.
struct SharedVehicleGrant: Identifiable, Equatable, Sendable {
    let id: String
    /// SIM ONLY — the prototype's persona ("Alex"/"Mom"/"Jordan").
    ///
    /// `nil` on the live path. THE FLAGGED DECISION (see the PR body): the design
    /// renders a shared car as "{Owner}'s {Vehicle}", but `GET /api/vehicles`
    /// carries NO owner name on a viewer row — only §7.5.5's redeem response has
    /// `ownerFirstName`, and only at the moment of joining. Rather than persist a
    /// name that can go stale, or synthesize one, the live row renders the
    /// vehicle's own nickname alone — which the server explicitly keeps in the
    /// viewer mask FOR THIS PURPOSE (the MYR-184 backend note: viewers see the
    /// nickname because "the rider UI renders a shared car as '{Owner}'s
    /// {Vehicle}'"), and which owners in practice name after themselves
    /// ("Alex's Model 3" is the canonical fixture value).
    let ownerName: String?
    /// SIM ONLY — the prototype's "Roommate"/"Family"/"Friend". Nothing on the
    /// wire corresponds to it; `nil` on the live path.
    let relationship: String?
    /// The vehicle's display name. SIM: the persona's car ("Cybercab"). LIVE:
    /// `VehicleSummary.name`.
    let vehicleName: String
    /// The rendered access line. SIM: the prototype's literal "Request rides".
    /// LIVE: the tier's design label via `ShareTierMapping`.
    let accessLabel: String
    /// The cumulative tier, when known. `nil` only for a tier this build cannot
    /// rank — see `ShareTierMapping.tier(forWire:)`.
    let tier: ShareAccessLevel?
    /// LIVE ONLY — the real vehicle the Live Map watches. `nil` in SIM.
    let vehicle: Vehicle?

    /// The row's title. Live rows have no owner name (see `ownerName`), so they
    /// render the vehicle alone rather than "'s {Vehicle}" with a hole in it.
    var title: String {
        SharedVehicleTitle.compose(owner: ownerName, vehicle: vehicleName)
    }

    /// The row's caption. SIM keeps the prototype's "{relationship} · {access}".
    var caption: String {
        guard let relationship else { return accessLabel }
        return "\(relationship) \u{00B7} \(accessLabel)"
    }

    // MARK: - Client-side capability gates (§7.5.0)
    //
    // CUMULATIVE `>=` over `live < live_history < rides`, never equality — the
    // same comparison every server gate makes. These are AFFORDANCE HINTS ONLY:
    // the server independently enforces all of them, so getting one wrong cannot
    // escalate anything. What they prevent is the app OFFERING something that
    // will 403 — which is the actual product failure (a rider taps "Request a
    // ride" and gets a wall).
    //
    // An UNRANKABLE tier fails CLOSED (nothing offered) rather than open. A tier
    // this build has never seen is, by the contract's append-in-increasing-order
    // rule, strictly higher than `rides` — but offering affordances on a tier we
    // cannot reason about is exactly the guess that produces a 403 wall.

    /// §7.2/§7.3/§7.4 — the drives/history surfaces need `>= live_history`.
    var grantsHistory: Bool {
        guard let tier else { return false }
        return tier == .history || tier == .rides
    }

    /// §7.8 — creating a ride request as a non-owner needs `rides`, the top tier.
    var grantsRides: Bool { tier == .rides }
}

// MARK: - "{Owner}'s {Vehicle}"

/// The design renders a shared car as "{Owner}'s {Vehicle}" — but the two halves
/// come from different places and, in the common case, OVERLAP.
///
/// `VehicleSummary.name` is the OWNER'S OWN NICKNAME for the car, and owners
/// overwhelmingly name it after themselves: the canonical server fixture is
/// literally `"Alex's Model 3"`. Prefixing the redeem response's `ownerFirstName`
/// onto that yields **"Alex's Alex's Model 3"** — which the first capture of the
/// joined screen showed verbatim.
///
/// So the composition is conditional: prefix the owner only when the nickname is
/// not already about them. Never a string the owner did not effectively write.
enum SharedVehicleTitle {
    static func compose(owner: String?, vehicle: String) -> String {
        let vehicle = vehicle.trimmingCharacters(in: .whitespaces)
        guard let owner = owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty else {
            return vehicle
        }
        guard !vehicle.isEmpty else { return "\(owner)\u{2019}s Tesla" }
        // Case-insensitive, and tolerant of BOTH apostrophes — the server stores
        // whatever the owner typed on their keyboard, which is the straight `'`
        // as often as the curly `’`.
        let normalized = vehicle.lowercased()
        let stem = owner.lowercased()
        if normalized.hasPrefix("\(stem)'") || normalized.hasPrefix("\(stem)\u{2019}") || normalized.hasPrefix("\(stem) ") {
            return vehicle
        }
        return "\(owner)\u{2019}s \(vehicle)"
    }
}

/// What a successful §7.5.5 redemption yields — everything the rider's success
/// screen renders, with no second round trip.
struct RedeemedShare: Equatable, Sendable {
    /// The sharing owner's FIRST NAME only, server-resolved. Always non-empty
    /// (the server's ladder guarantees a fallback), so there is no absent branch.
    let ownerFirstName: String
    /// Never empty — a redemption that granted nothing answers 404 or 409.
    let grants: [SharedVehicleGrant]
}

/// The rider's side of sharing.
@MainActor
protocol SharedVehicleCatalog: AnyObject, Observable {
    /// Vehicles shared with this rider, newest-known first. Empty is a REAL and
    /// common state on the live path (a rider who has not redeemed anything),
    /// and the surfaces that read it render an honest empty state, never a
    /// fixture persona.
    var grants: [SharedVehicleGrant] { get }

    /// True once a load has completed at least once, so a surface can tell
    /// "nothing shared" from "not asked yet" and avoid flashing an empty state
    /// over a list that is one round trip away. Always `true` in sim.
    var hasLoaded: Bool { get }

    /// Fetch the rider's shared vehicles. Idempotent; no-op in sim.
    func load() async

    /// `POST /api/invites/redeem` (§7.5.5). Throws ``ShareRedemptionFailure`` —
    /// the four answers the entry screen can act on — never a raw status code.
    func redeem(code: String) async throws -> RedeemedShare
}

// MARK: - SimulatedSharedVehicleCatalog (the M1 default)

/// The prototype's rider: three personas in "Shared with me", one watched
/// vehicle on the map, and a FORGIVING code check ("any 6 chars joins" —
/// onboarding.jsx:421), which is why `redeem` here cannot fail.
///
/// Every string it publishes is byte-identical to what `SharedSettingsScreen`
/// and `InviteCodeFlow` hardcoded before this issue, so the whole simulated
/// experience and every DEBUG capture stay pixel-identical.
@Observable
@MainActor
final class SimulatedSharedVehicleCatalog: SharedVehicleCatalog {
    /// shared-screens.jsx:456-459 `sharedWith` — a local literal array in the
    /// prototype (not a hoisted fixture like `VIEWERS`), ported the same way and
    /// now living here so the screen reads ONE seam in both modes.
    private(set) var grants: [SharedVehicleGrant] = [
        SharedVehicleGrant(
            id: "alex", ownerName: "Alex", relationship: "Roommate",
            vehicleName: "Cybercab", accessLabel: "Request rides", tier: .rides, vehicle: nil
        ),
        SharedVehicleGrant(
            id: "mom", ownerName: "Mom", relationship: "Family",
            vehicleName: "Model Y", accessLabel: "Request rides", tier: .rides, vehicle: nil
        ),
        SharedVehicleGrant(
            id: "jordan", ownerName: "Jordan", relationship: "Friend",
            vehicleName: "Model 3", accessLabel: "Request rides", tier: .rides, vehicle: nil
        ),
    ]

    var hasLoaded: Bool { true }

    func load() async {}

    /// onboarding.jsx:421 — "forgiving: any 6 chars joins". The host card values
    /// are `InviteHostFixture`'s, unchanged, so the simulated success screen is
    /// the same pixels it was before the redeem call existed.
    func redeem(code: String) async throws -> RedeemedShare {
        let host = InviteHostFixture()
        return RedeemedShare(
            ownerFirstName: host.owner,
            grants: [
                SharedVehicleGrant(
                    id: "invite-host",
                    ownerName: host.owner,
                    relationship: host.relationship,
                    vehicleName: host.name,
                    accessLabel: host.model,
                    tier: .rides,
                    vehicle: nil
                )
            ]
        )
    }
}
