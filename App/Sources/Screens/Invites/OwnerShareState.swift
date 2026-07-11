import Observation

// MARK: - Owner share state (MYR-170)
//
// Lifted above the owner tab switch in `RootView` (mirrors
// `OwnerHomeState`/`OwnerDrivesState`'s reasoning — see those files' header
// comments) AND shared between `InvitesScreen` and `SettingsScreen`.
//
// Ambiguity resolution: screens.jsx gives `InvitesScreen` and
// `SettingsScreen` each their own independent `uS(VIEWERS)` copy (revoking a
// viewer on one screen does not remove them from the other — screens.jsx
// :1250,1567). Nothing in the Handoff or `ds/ds-data.jsx` DEVIATIONS/
// OPEN_QUESTIONS calls this out as intentional; it reads as a prototype
// artifact of two screens independently seeding local state from the same
// module-level mock. This port shares one `OwnerShareState` so "Revoke"
// behaves consistently regardless of which tab it's tapped from, matching
// the app's existing state-lifting convention (`OwnerHomeState`,
// `OwnerDrivesState`) instead of forking two copies of the same list.
@Observable
@MainActor
public final class OwnerShareState {
    public var viewers: [Viewer]
    public var pending: [PendingInvite]

    /// MYR-228 — `live` seeds an EMPTY viewers/pending list: there is no live
    /// sharing backend yet (no `/viewers` / `/invites` contract), so the live
    /// path must render the screen's honest empty state ("No one has access
    /// yet."), NEVER the fixture people ("Alex", "Sam", "Jordan"). SIM keeps the
    /// `ShareFixtures` seed so every simulated/DEBUG scene stays pixel-identical.
    public init(live: Bool = false) {
        viewers = live ? [] : ShareFixtures.viewers
        pending = live ? [] : ShareFixtures.pending
    }

    /// screens.jsx:1394 `setViewers(vs => vs.filter(x => x.email !== …))`.
    public func revoke(_ viewer: Viewer) {
        viewers.removeAll { $0.email == viewer.email }
    }

    /// screens.jsx:1422 `setPending(ps => ps.filter(x => x.email !== …))`.
    public func cancelInvite(_ invite: PendingInvite) {
        pending.removeAll { $0.email == invite.email }
    }

    /// screens.jsx:1362-1365 `setPending(ps => ps.map(x => x.email === … ?
    /// { ...x, sent: 'just now' } : x))`.
    public func resend(_ invite: PendingInvite) {
        guard let index = pending.firstIndex(where: { $0.email == invite.email }) else { return }
        pending[index].sent = "just now"
    }

    /// screens.jsx:1258-1266 `doSend` — appends a new pending invite built
    /// from the composed email + chosen access level, most-recent first.
    @discardableResult
    public func sendInvite(email: String, accessLevel: ShareAccessLevel) -> PendingInvite {
        let invite = PendingInvite(
            name: ShareFixtures.name(fromEmail: email),
            email: email,
            sent: "just now"
        )
        pending.insert(invite, at: 0)
        return invite
    }
}
