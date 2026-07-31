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

    // MARK: - Client-side capability gates (§7.5.0, rewritten by MYR-369)
    //
    // **THE CUMULATIVE `>=` IS GONE.** These used to compare over a total order
    // `live < live_history < rides`, mirroring the comparison every server gate
    // made. The 0.23.0 contract retires that order outright: on an accepted grant
    // `sharePermission` is now DERIVED from per-grant flags on every read, emits
    // ONLY `rides` or `live`, and the contract's own guidance is to "gate the
    // ride-request affordance on `== 'rides'`". So these are equality tests now.
    //
    // They remain AFFORDANCE HINTS ONLY: the server independently enforces every
    // gate, so getting one wrong cannot escalate anything. What they prevent is
    // the app OFFERING something that will 403 — the actual product failure (a
    // rider taps "Request a ride" and gets a wall).
    //
    // An UNKNOWN tier still fails CLOSED. `ShareTierMapping.tier(forWire:)`
    // answers `nil` for a value this build has never seen, and offering
    // affordances on a capability we cannot reason about is exactly the guess
    // that produces that wall.

    /// **HISTORY IS OWNER-ONLY NOW, so this is always `false` for a viewer.**
    ///
    /// It is kept as a named property rather than deleted at its call sites
    /// because the FACT it encodes is what changed, and a reader of those call
    /// sites needs to see the answer stated. MYR-369's contract is explicit: "the
    /// history/drives surfaces are OWNER-ONLY as of MYR-369 and no value of this
    /// field opens them." The `live_history` tier that used to open them is
    /// retired and never emitted, and `rides` never implied history in the new
    /// model — it only ever did so through the cumulative order that is gone.
    ///
    /// A viewer reaching §7.2/§7.3/§7.4 would now be refused server-side, so
    /// offering the drives surfaces to one is precisely the 403 wall these gates
    /// exist to prevent.
    var grantsHistory: Bool { false }

    /// §7.8 — creating a ride request as a non-owner needs `rides`, which is now
    /// the projection of the grant's own `allowRides` flag rather than a tier
    /// reached by climbing past `live_history`. Unchanged in spelling, and for
    /// the first time the equality is the contract's own instruction rather than
    /// a shortcut that happened to agree with it.
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

    /// MYR-343 — vehicles this account OWNS outright (`role: owner` rows off the
    /// SAME §7.0 list `grants` is filtered from). Deliberately NOT grants: an
    /// owned car is not shared with anyone and must never appear under "Shared
    /// with me", carries no `sharePermission` (§7.0 emits the key iff `role` is
    /// `viewer`), and is not gated by a tier.
    ///
    /// It lives here because this catalog is the rider shell's ONE reader of
    /// `GET /api/vehicles`, and the shell's actual question is **"is there a car
    /// I can ride?"** — which is not the same question as "what is shared with
    /// me". Answering the second in place of the first is the MYR-343 defect:
    /// an OWNER switching to rider mode has zero viewer rows, so the shell shunted
    /// them to the invite-code prompt even though a self-ride on their own car is
    /// a supported flow (MYR-325 verified it live).
    ///
    /// Empty in sim — the prototype's rider is not an owner, and `grants` is
    /// non-empty there anyway, so every simulated + DEBUG capture is unchanged.
    var ownedVehicles: [Vehicle] { get }

    /// True once a load has completed at least once, so a surface can tell
    /// "nothing shared" from "not asked yet" and avoid flashing an empty state
    /// over a list that is one round trip away. Always `true` in sim.
    var hasLoaded: Bool { get }

    /// MYR-343 — true when a load was ATTEMPTED and failed with nothing known
    /// yet. Distinct from `hasLoaded == false`, which is "still in flight".
    ///
    /// The distinction is what MYR-326's "loading ≠ unavailable" rule demands
    /// once the shell holds a resolving state at all: a placeholder that never
    /// resolves is a promise the app cannot keep, and the honest end state for a
    /// list that did not answer is neither a skeleton nor "nothing is shared with
    /// you". Always `false` in sim.
    var loadFailed: Bool { get }

    /// Fetch the rider's shared vehicles. Idempotent; no-op in sim.
    func load() async

    /// `POST /api/invites/redeem` (§7.5.5). Throws ``ShareRedemptionFailure`` —
    /// the four answers the entry screen can act on — never a raw status code.
    func redeem(code: String) async throws -> RedeemedShare
}

// MARK: - MYR-343 — the rider shell's vehicle-set resolution
//
// THE CLIENT'S REPORT (TestFlight, Jul 29): "When I switched to rider mode as an
// owner I briefly saw the rider home page and then it prompted me to enter a
// code." TWO defects in one sentence, and this type answers both.
//
//  1. WRONG QUESTION. MYR-184 gated the rider shell on `grants.isEmpty` — i.e.
//     on SHARES. An owner in rider mode has zero `role: viewer` rows by
//     definition, so the zero-shared-vehicles empty state swallowed an account
//     that owns a car outright. Self-rides are a supported flow (MYR-325 tested
//     one live), and the ride path never had this bug: `RiderLiveVehicleLocator`
//     has always taken `vehicles.first` regardless of role, which for an owner IS
//     their own car. Only the shell gate and the adopted map vehicle regressed.
//     The empty state now means what its copy says — no vehicles AT ALL, neither
//     owned nor shared.
//
//  2. THE FLASH. The gate was `hasLoaded && grants.isEmpty`, so the not-yet-loaded
//     case fell through to the ELSE branch and rendered the rider home over an
//     unresolved vehicle set, then swapped. There is no ordering of a two-way
//     boolean that avoids this: three genuinely different situations (not asked
//     yet / has a car / has none) cannot be told apart by one flag, so one of them
//     has to borrow another's surface for a frame. The resolution below is
//     three-way (four, with the honest failure), and the shell presents NOTHING
//     until the set resolves — a skeleton, per MYR-326's grammar, never a
//     flash-then-swap.
//
// Pure + static so both rules are unit-testable with no catalog, no view, and no
// clock (`RiderVehicleSetTests`).

/// What the rider shell adopts for the Live Map: one vehicle plus the tier that
/// gates its affordances.
struct RiderVehicleAdoption: Equatable {
    /// Which half of the §7.0 list this vehicle came from. Carried so the shell's
    /// choice is legible in tests and at the call site, never re-derived.
    enum Source: Equatable {
        /// A `role: owner` row — the account's own car (MYR-343 self-ride).
        case owned
        /// A `role: viewer` row — a redeemed share.
        case shared
    }

    let source: Source
    /// The vehicle to watch. `nil` for a SIM grant, which carries no `Vehicle`
    /// by construction (the prototype's "Shared with me" is three personas with
    /// no car behind them) — the sim viewer keeps its fixture seed, unchanged.
    let vehicle: Vehicle?
    /// The share tier, or `nil` when tiers DO NOT APPLY — which is the owner's
    /// own car as well as the simulated path. `SharedViewerState.canRequestRides`
    /// already reads a nil tier as "not gated", which is correct for an owner:
    /// §7.8's non-owner gate is not one they can fail.
    let tier: ShareAccessLevel?
}

/// The rider shell's four honest answers to "what should I present?".
enum RiderVehicleSet: Equatable {
    /// The vehicle set is still being resolved. The shell shows a skeleton and
    /// commits to NOTHING — this is the state whose absence produced the flash.
    case resolving
    /// There is a car to ride. Adopt it and render the Live Map.
    case ridable(RiderVehicleAdoption)
    /// No vehicles at all — neither owned nor shared. The invite-code empty state,
    /// which is now the only thing it ever claimed to be.
    case empty
    /// The list did not answer and nothing is known. NOT `.empty`: telling a rider
    /// they have no vehicles because one fetch timed out is a claim the app cannot
    /// support (`LiveSharedVehicleCatalog.load` deliberately leaves the last-known
    /// grants standing for the same reason).
    case unavailable

    /// THE ADOPTION RULE.
    ///
    /// **Owned wins.** An account holding both an owned car and a redeemed share
    /// self-rides its own car. Two reasons, and the second is the load-bearing one:
    ///
    ///  • The owner's car is unambiguously theirs — no tier, no §7.8 gate, no 403
    ///    to guess at. A share can sit on `live`, in which case the shell would
    ///    have to hide the "Where to?" CTA from someone who owns a Tesla.
    ///  • CONSISTENCY WITH THE RIDE ITSELF. `RiderLiveVehicleLocator` publishes
    ///    `vehicles.first` as the `FleetMember` the Review/Booking cards render and
    ///    the request is created against. Adopting a SHARED car onto the map while
    ///    the ride is created against the OWNED one would put two different cars on
    ///    two halves of one flow. Preferring owned keeps the map and the ride
    ///    naming the same vehicle.
    ///
    /// FLAGGED (per the brief): this is a product choice, not a contract rule.
    /// §7.0 states no precedence between an owner row and a viewer row, and an
    /// owner who wants to ride someone ELSE's shared car has no way to pick it
    /// here — the rider shell watches exactly one vehicle (the multi-vehicle
    /// picker is MYR-91 scope). If that becomes the wanted flow, this function is
    /// the one place it changes.
    static func resolve(
        hasLoaded: Bool,
        loadFailed: Bool,
        grants: [SharedVehicleGrant],
        ownedVehicles: [Vehicle]
    ) -> RiderVehicleSet {
        // A successful load always wins over a stale failure flag: `hasLoaded`
        // only becomes true when a list actually landed.
        guard hasLoaded else { return loadFailed ? .unavailable : .resolving }
        if let owned = ownedVehicles.first {
            return .ridable(RiderVehicleAdoption(source: .owned, vehicle: owned, tier: nil))
        }
        if let grant = grants.first {
            return .ridable(RiderVehicleAdoption(source: .shared, vehicle: grant.vehicle, tier: grant.tier))
        }
        return .empty
    }
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

    /// MYR-343 — the prototype's rider is not an owner. Empty here means the
    /// simulated shell resolves to the FIRST grant exactly as it did before this
    /// issue, so every simulated + DEBUG rider capture is byte-identical.
    var ownedVehicles: [Vehicle] { [] }

    /// Nothing can fail in sim: `load()` is a no-op that always "succeeds".
    var loadFailed: Bool { false }

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
