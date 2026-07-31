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

    // MARK: - Per-viewer capability edits (MYR-369, PATCH /api/invites/{id})

    /// The vehicle-level ride-share master switch, per owned vehicle
    /// (`VehicleSummary.rideShareEnabled`, §7.18). Read here because MYR-369
    /// RELOCATED that toggle from the owner sheet's "Status & location" card to
    /// the top of the Share tab — it is the same field and the same endpoint, on
    /// the surface where its consequences are actually visible.
    ///
    /// **ABSENT MEANS ENABLED** (contracts 0.20.0, and the rule most likely to be
    /// broken by a tidy refactor). Resolved through `VehicleRideShare.isEnabled`
    /// so the explicit-`false` test is written in exactly one place.
    var vehicleRideShare: [VehicleRideShareRow] { get }

    /// Flip the vehicle-level master switch. OPTIMISTIC with rollback: the row
    /// moves immediately (a toggle that waits for a round trip reads as broken),
    /// adopts the server's ECHO on success, and restores the previous position on
    /// failure — leaving it up would manufacture the exact belief §7.18 refuses
    /// to allow, an owner walking away thinking their car is paused while it is
    /// still taking requests.
    func setVehicleRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws

    /// PATCH one accepted grant's `allowRides`. Optimistic with rollback.
    ///
    /// Meaningful only while the viewer is NOT suspended and the vehicle master
    /// switch is on; the screen disables the control in both cases rather than
    /// sending a write whose effect the owner could not observe.
    func setViewerAllowRides(_ allowRides: Bool, viewer: Viewer) async throws

    /// PATCH one accepted grant's `suspended` — the row's MASTER switch.
    ///
    /// `true` removes the vehicle from that viewer's access set entirely: their
    /// catalog row, snapshot, WebSocket handshake, drives and rides all stop at
    /// once, with the single recorded caveat that an ALREADY-OPEN socket streams
    /// until it reconnects (DV-09; server-side fix is MYR-373). The grant row
    /// survives with its flags intact, so restoring returns exactly what it had —
    /// which is the whole difference from `revoke(_:)`, a permanent tombstone.
    func setViewerSuspended(_ suspended: Bool, viewer: Viewer) async throws
}

// MARK: - Vehicle ride-share row (MYR-369)

/// One owned vehicle's ride-share master switch, as the Share tab's top card
/// renders it.
///
/// THE SHARE TAB HAS NO VEHICLE SELECTION, which is the one real friction in
/// relocating this control: `rideShareEnabled` is per-vehicle (§7.18 writes to
/// ONE `vehicleId`) while the Share tab is the owner's whole sharing picture,
/// fanned out across every owned car. Rather than invent a fleet-wide semantic
/// the server does not have, or silently govern only the first car, the card
/// renders ONE ROW PER OWNED VEHICLE. A single-car owner — the overwhelming case
/// — sees exactly one switch and reads it as the master toggle it is; an owner
/// with three cars gets three honest switches instead of one ambiguous one.
struct VehicleRideShareRow: Identifiable, Equatable, Sendable {
    /// The server vehicle id — the PATH of the §7.18 write, and the row identity.
    let id: String
    let name: String
    /// The owner's STORED preference — what §7.18 holds for this car, resolved
    /// through `VehicleRideShare.isEnabled` so an absent wire value reads as
    /// ENABLED and never as paused.
    ///
    /// **THIS IS NOT THE SWITCH POSITION.** While the car is in service the switch
    /// renders OFF and this value is untouched underneath it — see ``display``.
    let storedEnabled: Bool
    /// Whether the car is in a service bay right now (`Vehicle.isInService`).
    let isInService: Bool
    /// False while this row's own write is in flight, so a second tap cannot
    /// queue a contradictory write behind the first.
    var isBusy: Bool = false

    /// Everything the row RENDERS — `VehicleRideShare.display` verbatim (MYR-358).
    ///
    /// **DERIVED, NEVER STORED**, which is what makes the relocation structural
    /// rather than a rule the Share tab has to remember. The row cannot be
    /// constructed holding a switch position that disagrees with the facts it
    /// carries, so "an in-service car renders OFF and inert" is not something a
    /// call site can forget or a future service re-implement differently: there is
    /// exactly one expression of it and both services reach it through here.
    ///
    /// The MYR-358 property this preserves: `storedEnabled` is the owner's
    /// standing instruction and a service visit is a temporary fact about the car,
    /// so NOTHING is written on either transition and the stored preference comes
    /// straight back when the visit ends.
    var display: VehicleRideShare.Display {
        VehicleRideShare.display(storedEnabled: storedEnabled, isInService: isInService)
    }

    /// The switch POSITION — off for the whole of a service visit whatever the
    /// owner stored.
    var isEnabled: Bool { display.isOn }
    /// Whether the switch may be moved. False in service, where the position is
    /// derived and there is nothing to commit.
    var isInteractive: Bool { display.isInteractive }
    /// The muted line beneath the car's name.
    var caption: String { display.caption }
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

    /// The COMPLETE server-minted join link for this invite (MYR-368,
    /// `ShareInvite.shareUrl`, contracts 0.22.0) — or `nil` from a server that
    /// predates it, and from `SimulatedShareService`, which mints nothing.
    ///
    /// Carried as the RAW string the wire delivered rather than as a `URL`, so
    /// this type stores exactly what the server said and the parse happens at the
    /// one place that needs a `URL` (`ShareInviteMessage`). It is signed end to
    /// end — the code, the expiry and both display names are inside `k` — so it is
    /// forwarded verbatim or not used at all; there is no partial adoption.
    ///
    /// It CONTAINS the code, so it inherits the code's P1 classification: never
    /// logged, never in an error message, never on a non-owner surface.
    ///
    /// Defaulted so every existing construction site is unchanged and a caller
    /// that has no server link (sim, tests, an older server) simply gets the
    /// MYR-359 fallback — which is the contract's own instruction for the case.
    var shareUrl: String? = nil

    /// The share-sheet payload — ONE URL and nothing else (MYR-359), built by
    /// `ShareInviteMessage` so the create and resend paths cannot drift.
    ///
    /// MYR-368 — that URL is the SERVER's when it minted one, verbatim, because
    /// the signature in `k` covers every part of it. The client-composed link
    /// below is the documented fallback for a pre-0.22.0 server, and is byte-for
    /// byte what shipped before this issue.
    ///
    /// This was a one-liner carrying the code (MYR-184), then a mini-onboarding
    /// paragraph (MYR-340) with the join link at its head (MYR-346). The
    /// paragraph is gone: iMessage renders the branded card only for a message
    /// that is nothing but a link, so the surrounding prose was what suppressed
    /// the card it was written to introduce. The link is self-sufficient — it
    /// autofills the code on a phone that has the app and lands on a page
    /// carrying the code, the steps and the TestFlight button on one that
    /// doesn't.
    ///
    /// A METHOD, not a stored property: the owner's name belongs to the SESSION,
    /// not to the invite, and `LiveShareService` (which mints the handout) has no
    /// business reading the signed-in profile. The screen that presents the sheet
    /// supplies it — see `InvitesScreen.liveProfile`.
    func shareURL(ownerFirstName: String?) -> URL {
        ShareInviteMessage.shareURL(
            serverURL: shareUrl, code: code, ownerFirstName: ownerFirstName
        )
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

    /// MYR-347 — the roster is now an INPUT, defaulted to the fixtures.
    ///
    /// Every production call site still constructs it with no arguments and gets
    /// the identical fixture roster; the parameters exist so the DEBUG state-
    /// matrix scenes (`ownerShareEmpty` / `ownerSharePendingOnly` /
    /// `ownerShareAcceptedOnly`) can capture the arms of `ShareRosterState` that
    /// a seeded-in-`init` roster made unreachable. Fixture data still reaches
    /// only the simulated path, so MYR-228 is unaffected.
    init(viewers: [Viewer] = ShareFixtures.viewers, pending: [PendingInvite] = ShareFixtures.pending) {
        self.viewers = viewers
        self.pending = pending
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

    // MARK: - Per-viewer capability edits (MYR-369)
    //
    // Local-array edits, exactly like every other mutation here: there is no
    // network on this path, so nothing is in flight and nothing can fail. The
    // switches are therefore fully LIVE in SIM — which is what makes the
    // simulated Share-tab scenes able to capture the control at rest in each of
    // its positions without a backend.

    /// `isInService: false` for every fixture car — the simulated fleet has no
    /// service visits, so the whole simulated Share tab renders exactly what it
    /// did before MYR-358's derivation was restored.
    private(set) var vehicleRideShare: [VehicleRideShareRow] = VehicleFixtures.vehicles.map {
        VehicleRideShareRow(id: $0.id, name: $0.name, storedEnabled: true, isInService: $0.isInService)
    }

    func setVehicleRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws {
        guard let index = vehicleRideShare.firstIndex(where: { $0.id == vehicleID }) else { return }
        let row = vehicleRideShare[index]
        vehicleRideShare[index] = VehicleRideShareRow(
            id: row.id,
            name: row.name,
            storedEnabled: enabled,
            isInService: row.isInService
        )
    }

    func setViewerAllowRides(_ allowRides: Bool, viewer: Viewer) async throws {
        guard let index = viewers.firstIndex(where: { $0.id == viewer.id }) else { return }
        viewers[index] = viewers[index].with(allowRides: allowRides)
    }

    func setViewerSuspended(_ suspended: Bool, viewer: Viewer) async throws {
        guard let index = viewers.firstIndex(where: { $0.id == viewer.id }) else { return }
        viewers[index] = viewers[index].with(suspended: suspended)
    }
}

// MARK: - Tier mapping (MYR-184)

/// The ONE place the design's three access tiers and the contract's
/// `SharePermission` enum meet. Both directions live here so they cannot drift:
/// a mapping that is right in one direction and wrong in the other is exactly how
/// an owner grants "Can request rides" and the recipient gets "Live location".
///
/// MYR-369 — NEITHER SIDE IS CUMULATIVE ANY MORE. This mapping used to carry
/// three tiers in one total order; it now carries two PRESETS that each decide a
/// single flag at redemption. `live_history` survives on the READ side only, as
/// a decode-compat fold, and is unreachable on the write side by construction:
/// `ShareAccessLevel` has no case that produces it.
enum ShareTierMapping {
    /// Design preset → wire value. Total: every case maps.
    ///
    /// There is deliberately NO arm producing `"live_history"`. The tier is
    /// retired and never emitted by the server either, so a client that could
    /// still SEND it would be minting invites at a preset nothing will honour.
    static func wireValue(for tier: ShareAccessLevel) -> String {
        switch tier {
        case .live: return "live"
        case .rides: return "rides"
        }
    }

    /// Wire value → design preset. `nil` for a value this build has never heard of.
    ///
    /// **`live_history` STILL MAPS, AND DELIBERATELY MAPS TO `.live`.** It is
    /// decode-compat: no server emits it, but a legacy row read by a client that
    /// somehow still sees one must render honestly, and the contract's own rule
    /// is that a grant created at that preset now derives `live`. Folding it to
    /// `.live` rather than to `nil` is what keeps such a row labelled instead of
    /// falling through to the neutral "Shared access".
    ///
    /// Callers must NOT substitute a default for a genuinely unknown value. A
    /// value appended by a newer contracts version describes a capability this
    /// build cannot reason about; guessing `live` would mislabel it and guessing
    /// `rides` would offer affordances that will 403.
    static func tier(forWire raw: String) -> ShareAccessLevel? {
        switch raw {
        case "live": return .live
        case "live_history": return .live
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
