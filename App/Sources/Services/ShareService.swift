import Foundation
import Observation

// MARK: - Vehicle-sharing seam (MYR-184)
//
// Before this issue there was NO seam here at all: `OwnerShareState` was one
// concrete `@Observable` that mutated two local arrays, and the live path got the
// same class seeded empty (MYR-228's honest empty state, correct at the time —
// there was no sharing backend). rest-api.md §7.5 shipped, so this becomes the
// same shape every other M1↔M2 boundary in the app already has: ONE protocol,
// a fixture conformer, a Kit-backed conformer, composed at exactly one point
// (`ShareComposition`, wired from `RootView` off the ONE resolved `AppMode` —
// the same wiring as `RideRequestService`).
//
// The protocol is the OWNER's side of sharing. The rider's side (redeem + the
// shared-vehicle catalog) is `SharedVehicleCatalog`, deliberately separate:
// they are different people on different screens, and an owner surface must
// never be able to reach a redeem call.
//
// ASYNC + THROWING, unlike the local-array original. Every mutation is a network
// round trip that can fail, and a share screen that silently drops a failed
// revoke would be telling the owner someone lost access when they did not.

/// One row of the owner's sharing screen, split into the two sections the
/// prototype already renders — accepted grants under "Viewers · N", pending
/// invites under "Pending" (§7.5.2 says the server returns them interleaved and
/// the client splits on `status`).
@MainActor
protocol ShareService: AnyObject, Observable {
    /// Accepted grants — screens.jsx's `VIEWERS` list.
    var viewers: [Viewer] { get }
    /// Unredeemed invites — screens.jsx's `PENDING` list.
    var pending: [PendingInvite] { get }

    /// The vehicles the owner can actually share, for the send-invite sheet's
    /// "select one or more" multi-select.
    ///
    /// THIS IS MYR-228 FIX (a). `InvitesScreen` read `VehicleFixtures.vehicles`
    /// unconditionally — so a live owner picked from "Cybercab"/"Daily", cars
    /// that do not exist on their account, and the resulting invite would have
    /// targeted fixture ids. Sim keeps the fixtures (pixel-identical); live reads
    /// the owner's real fleet.
    var shareableVehicles: [Vehicle] { get }

    /// Whether this service mints CODES (the shipping contract) rather than
    /// sending EMAILS (the prototype's fiction).
    ///
    /// The prototype's send flow is built around an email address: an
    /// `friend@example.com` field, an email-keyboard, an `emailToName` derivation,
    /// and a closing "We emailed {name} a link to join." §7.5 has NO email
    /// anywhere — the recipient field is a `label`, an owner-typed memo capped at
    /// 120 characters, and the artefact is a 6-character code the owner hands out
    /// through the iOS share sheet. `true` therefore switches the composer from
    /// "who do I email" to "what do I call this person", and the closing beat from
    /// a celebration to the share sheet. SIM keeps every prototype pixel.
    var sharesByCode: Bool { get }

    /// True while the first load is in flight. Always `false` in sim (nothing to
    /// load), so no simulated capture can reach a loading branch.
    var isLoading: Bool { get }

    /// A quiet one-line status when the list could not be read — never a dialog
    /// (design minimalism, same convention as `VehicleFleet.statusMessage`).
    var statusMessage: String? { get }

    /// Fetch (or re-fetch) the owner's rows. Idempotent and safe to call on every
    /// appearance of the Share tab. No-op in sim.
    func load() async

    /// Mint one invite across `vehicleIDs`, all on `tier`.
    ///
    /// Returns the HANDOUT — the code plus the copy to share — because §7.5.1's
    /// whole point is that the owner now has something to give someone. The caller
    /// presents the system share sheet with it. Sim returns `nil`: there is no
    /// server to mint a code and a fabricated one would be a live-path-class lie
    /// on the sim path, so the simulated flow keeps its existing "Invite sent"
    /// celebration untouched and pixel-identical.
    @discardableResult
    func createInvite(label: String, tier: ShareAccessLevel, vehicleIDs: [String]) async throws -> ShareHandout?

    /// Revoke an accepted grant (§7.5.3). Idempotent server-side; a `404` means
    /// the grant is already gone, which is the same terminal state, so it is not
    /// surfaced as a failure.
    func revoke(_ viewer: Viewer) async throws

    /// Cancel a pending invite (§7.5.3 — the same endpoint; cancel and revoke
    /// differ only in which section the row was in).
    func cancelInvite(_ invite: PendingInvite) async throws

    /// Re-mint a pending invite's code (§7.5.4). Returns the NEW handout so the
    /// caller can re-present the share sheet — the old code is dead the instant
    /// this returns, so an owner who is not handed the new one is stranded.
    @discardableResult
    func resend(_ invite: PendingInvite) async throws -> ShareHandout?
}

// MARK: - Handout

/// What the owner hands to a recipient: the server-minted code plus the one-line
/// message the system share sheet carries.
///
/// The code is a LIVE BEARER CREDENTIAL for vehicle access (§7.5, P1) — it is
/// never logged, and this type exists partly so it travels as one deliberate
/// value rather than as a loose string threaded through view state.
struct ShareHandout: Equatable, Sendable, Identifiable {
    /// `Identifiable` so `.sheet(item:)` re-presents on a RESEND: the code is the
    /// identity, so a new code is a new sheet even if the previous one is still
    /// settling. (`.sheet(isPresented:)` + a separate value would race here.)
    var id: String { code }
    /// The 6-character code, uppercase `[A-Z0-9]`.
    let code: String
    /// Who the owner said this was for (their own label, echoed back).
    let label: String
    /// Which vehicles it grants — for the confirmation copy, not for the message.
    let vehicleNames: [String]

    /// The share-sheet body. Short on purpose: it is read in a Messages bubble,
    /// and the code is the only part that matters, so it lands last and alone.
    /// No link — there is no web surface to deep-link to, and inventing one
    /// would send recipients somewhere that does not exist.
    var message: String {
        "Join my Tesla on MyRoboTaxi — code \(code)"
    }
}

// MARK: - SimulatedShareService (the M1 default)

/// The fixture-backed sharing screen — byte-for-byte the behavior
/// `OwnerShareState` shipped in MYR-170, now behind the seam.
///
/// Every method is synchronous work wrapped in an `async` signature: there is no
/// network here and there never will be, so nothing can fail and nothing can be
/// in flight (`isLoading` is `false` by construction, `statusMessage` always
/// `nil`). That is what keeps every simulated + DEBUG capture pixel-identical.
///
/// Ambiguity resolution carried over from `OwnerShareState`: screens.jsx gives
/// `InvitesScreen` and `SettingsScreen` each their own independent `uS(VIEWERS)`
/// copy (revoking on one does not remove them from the other — screens.jsx
/// :1250,1567). Nothing in the Handoff or `ds/ds-data.jsx` calls that out as
/// intentional; it reads as a prototype artifact of two screens seeding local
/// state from the same module-level mock. This port shares ONE service so
/// "Revoke" behaves consistently from either tab.
@Observable
@MainActor
final class SimulatedShareService: ShareService {
    private(set) var viewers: [Viewer]
    private(set) var pending: [PendingInvite]

    var shareableVehicles: [Vehicle] { VehicleFixtures.vehicles }
    /// The prototype emails; it has no server to mint a code.
    var sharesByCode: Bool { false }
    var isLoading: Bool { false }
    var statusMessage: String? { nil }

    init() {
        viewers = ShareFixtures.viewers
        pending = ShareFixtures.pending
    }

    func load() async {}

    /// screens.jsx:1258-1266 `doSend` — appends a new pending invite, most-recent
    /// first. MYR-184: the chosen tier is now CARRIED onto the row instead of
    /// being discarded (the prototype dropped `accessLevel` on the floor), which
    /// is a data fix, not a visual one — the pending row's rendered text is
    /// unchanged, so SIM stays pixel-identical.
    @discardableResult
    func createInvite(label: String, tier: ShareAccessLevel, vehicleIDs: [String]) async throws -> ShareHandout? {
        let invite = PendingInvite(
            name: ShareFixtures.name(fromEmail: label),
            email: label,
            sent: "just now",
            tier: tier
        )
        pending.insert(invite, at: 0)
        // No code: nothing minted it. The simulated flow keeps the prototype's
        // "Invite sent" sheet rather than a share sheet with a fake code.
        return nil
    }

    /// screens.jsx:1394 `setViewers(vs => vs.filter(x => x.email !== …))`.
    func revoke(_ viewer: Viewer) async throws {
        viewers.removeAll { $0.id == viewer.id }
    }

    /// screens.jsx:1422 `setPending(ps => ps.filter(x => x.email !== …))`.
    func cancelInvite(_ invite: PendingInvite) async throws {
        pending.removeAll { $0.id == invite.id }
    }

    /// screens.jsx:1362-1365 `setPending(ps => ps.map(x => x.email === … ?
    /// { ...x, sent: 'just now' } : x))`.
    @discardableResult
    func resend(_ invite: PendingInvite) async throws -> ShareHandout? {
        guard let index = pending.firstIndex(where: { $0.id == invite.id }) else { return nil }
        pending[index].sent = "just now"
        return nil
    }
}

// MARK: - Tier mapping (MYR-184)

/// The ONE place the design's three access tiers and the contract's
/// `SharePermission` enum meet. Both directions live here so they cannot drift:
/// a mapping that is right in one direction and wrong in the other is exactly how
/// an owner grants "Can request rides" and the recipient gets "Live location".
///
/// The design labels are the contract's own documented pairing (the generated
/// `SharePermission` doc comment names them: `live` → "Live location",
/// `live_history` → "Live + history", `rides` → "Can request rides"), and both
/// sides are STRICTLY CUMULATIVE in the same order.
enum ShareTierMapping {
    /// Design tier → wire value. Total: every case maps.
    static func wireValue(for tier: ShareAccessLevel) -> String {
        switch tier {
        case .live: return "live"
        case .history: return "live_history"
        case .rides: return "rides"
        }
    }

    /// Wire value → design tier. `nil` for a tier this build has never heard of.
    ///
    /// Callers must NOT substitute a default here. A tier appended by a newer
    /// contracts version is, by the contract's own rule, strictly HIGHER than
    /// `rides`; guessing `live` would mislabel the row downward and guessing
    /// `rides` would offer affordances we cannot reason about. The row renders
    /// the honest "Shared access" instead — see `permLabel(forWire:)`.
    static func tier(forWire raw: String) -> ShareAccessLevel? {
        switch raw {
        case "live": return .live
        case "live_history": return .history
        case "rides": return .rides
        default: return nil
        }
    }

    /// The rendered permission string for a row — the design's own label when the
    /// tier is known, and a neutral, non-committal one when it is not.
    static func permLabel(forWire raw: String) -> String {
        tier(forWire: raw)?.info.perm ?? "Shared access"
    }
}
