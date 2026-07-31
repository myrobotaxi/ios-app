import DesignSystem
import SwiftUI

// MARK: - Share fixtures (MYR-170 — design/app/screens.jsx 35-42,1226-1245)
//
// M1 ships on fixture data only (CLAUDE.md "M1 is simulated") — no network.
// `Viewer`/`PendingInvite` port `VIEWERS`/`PENDING`; `ShareAccessLevel` ports
// the cumulative `SHARE_ACCESS` tiers offered in the send-invite sheet.

/// Someone with live access to the owner's vehicle(s) (screens.jsx:35-38
/// `VIEWERS`). Shown on both `InvitesScreen` and `SettingsScreen`.
///
/// MYR-184 — the identity moved from `email` to an explicit `id`. The prototype
/// keyed viewers by email because its mock data had one; the SHIPPING contract is
/// code-based and carries no email anywhere (§7.5: "Nothing in this family
/// accepts, stores, or resolves an email address"), so `email` is now SIM-ONLY
/// and the live row is keyed by its server invite id.
public struct Viewer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// SIM ONLY — the prototype's fixture address. `nil` on the live path: the
    /// server never sends one, and rendering a fabricated address on a real
    /// viewer row would be exactly the MYR-228 class of lie.
    public let email: String?
    /// v1 has NO presence signal for a viewer — the wire carries no `isOnline`
    /// (the pre-MYR-184 shape that had one never shipped). Always `false` on the
    /// live path, so the dot stays OFF and the row never claims someone is
    /// watching. The fixtures keep their values so SIM is pixel-identical.
    public let online: Bool
    /// Human-readable permission label, e.g. "Live location" / "Live + history".
    public let perm: String
    /// MYR-184 — the tier this grant carries, when known (live rows always;
    /// fixtures derive it from `perm`). `perm` remains the rendered string.
    ///
    /// MYR-369 — this is now a DERIVED PROJECTION of ``allowRides`` and no longer
    /// the truth about the grant. It survives because the pending row still
    /// carries a genuine invite-time PRESET, and because the row's summary line
    /// reads better off one value than off two booleans. Capability decisions
    /// read ``allowRides`` / ``suspended``.
    public let tier: ShareAccessLevel?

    /// MYR-369 — whether this viewer may REQUEST RIDES in the vehicle. The
    /// per-grant, owner-editable capability that replaced the fixed `rides` tier
    /// (`ShareInvite.allowRides`, `PATCH /api/invites/{id}`).
    ///
    /// NOT INDEPENDENT OF ``suspended``: `true` on a suspended grant allows
    /// NOTHING, because suspension gates everything. The owner's row renders this
    /// switch in its stored position while suspended — that is the contract's own
    /// instruction, so restoring shows what will come back — but must never
    /// present the person as able to ride while it is.
    public let allowRides: Bool

    /// MYR-369 — whether the owner has PAUSED this grant entirely
    /// (`ShareInvite.suspended`). The reversible alternative to revoking: the row
    /// survives with its flags intact and one PATCH restores exactly what it had.
    ///
    /// SUSPENSION GATES EVERYTHING, server-enforced by removing the grant from
    /// the viewer's access set — their catalog row, snapshot, WebSocket
    /// handshake, drives and rides all stop at once. So this is the MASTER switch
    /// on the row, and the ride switch below it is inert while it is on.
    public let suspended: Bool

    public init(
        id: String? = nil,
        name: String,
        email: String?,
        online: Bool,
        perm: String,
        tier: ShareAccessLevel? = nil,
        allowRides: Bool = false,
        suspended: Bool = false
    ) {
        self.id = id ?? email ?? name
        self.name = name
        self.email = email
        self.online = online
        self.perm = perm
        self.tier = tier
        self.allowRides = allowRides
        self.suspended = suspended
    }

    /// The row's own copy of itself with one flag moved — the OPTIMISTIC value a
    /// switch flips to before the PATCH answers, and the value the rollback
    /// restores. A method rather than a `var` so the row stays immutable and the
    /// service replaces it wholesale, which is what makes the rollback provably
    /// exact rather than a second guess at the previous state.
    public func with(allowRides: Bool? = nil, suspended: Bool? = nil) -> Viewer {
        Viewer(
            id: id,
            name: name,
            email: email,
            online: online,
            perm: perm,
            tier: tier,
            allowRides: allowRides ?? self.allowRides,
            suspended: suspended ?? self.suspended
        )
    }
}

/// An invite that has been sent but not yet accepted (screens.jsx:39-41 `PENDING`).
public struct PendingInvite: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// SIM ONLY — see ``Viewer/email``. `nil` on the live path.
    public let email: String?
    /// LIVE ONLY — the 6-character redemption code, present while the invite is
    /// `pending` (§7.5.2: `code` appears only on pending rows). `nil` in SIM,
    /// which has no server to mint one. This is the thing the owner actually
    /// hands out, so it is what the live row's caption names.
    public let code: String?
    /// "2d ago" / "just now" — a relative-time label, not a real Date; the
    /// prototype never re-renders this against a clock (screens.jsx:1264
    /// sets the literal string `'just now'` on send/resend).
    public var sent: String
    /// MYR-184 — the tier the owner chose. The prototype's `doSend` DISCARDED
    /// `accessLevel` entirely (screens.jsx:1258-1266, and this port's original
    /// `sendInvite(email:accessLevel:)` did the same); carrying it is what lets a
    /// pending row say what it will grant.
    public let tier: ShareAccessLevel?

    public init(
        id: String? = nil,
        name: String,
        email: String?,
        code: String? = nil,
        sent: String,
        tier: ShareAccessLevel? = nil
    ) {
        self.id = id ?? email ?? name
        self.name = name
        self.email = email
        self.code = code
        self.sent = sent
        self.tier = tier
    }

    /// What the row's caption renders before the "· sent" clause. SIM shows the
    /// fixture email verbatim (pixel-identical to the prototype); LIVE shows the
    /// code, which is the only handle either party has on this invite.
    public var captionLead: String {
        if let email { return email }
        if let code { return "Code \(code)" }
        return ""
    }
}

/// The INVITE-TIME PRESET offered when sharing a Tesla (screens.jsx:1230-1236
/// `SHARE_ACCESS`).
///
/// **TWO OPTIONS, AND NO LONGER A TIER LADDER** (MYR-369). The prototype's third
/// option — `history`, "Live + history" — IS RETIRED. Two independent facts
/// killed it, and either alone would have:
///
///  1. The drives/history surfaces are OWNER-ONLY as of MYR-369, so no value of
///     any share preset opens them. An option promising "past trips & drives"
///     would have been offering something the server no longer grants anybody.
///  2. `live_history` IS NEVER EMITTED. The wire enum keeps the member for
///     decode compat — an installed client with it in its decoder keeps working,
///     and `ShareTierMapping.tier(forWire:)` still maps it — but no server
///     response carries it, and a legacy grant created at that preset now
///     derives `live`. Offering a preset that cannot come back is a one-way trip.
///
/// What remains is not an ORDER, it is a preset that decides ONE flag at
/// redemption: `rides` → `allowRides: true`, `live` → `allowRides: false`. After
/// redemption the preset is inert and the per-grant flags are authoritative —
/// which is exactly why the owner's accepted rows carry SWITCHES now rather than
/// a tier label they could not change.
public enum ShareAccessLevel: String, CaseIterable, Identifiable, Sendable {
    case live, rides

    public var id: String { rawValue }

    /// MYR-184 — recover the preset from the rendered permission label, so a
    /// fixture row (which only ever carried the string) still reports one.
    /// Never used on the live path, which maps the wire enum directly.
    public static func fromPermLabel(_ label: String) -> ShareAccessLevel? {
        allCases.first { $0.info.perm == label }
    }

    /// Which per-grant flag this preset resolves to at redemption. The ONE place
    /// the preset→capability mapping is written, so the composer's summary card,
    /// the pending row's label and the server's own redemption rule cannot drift.
    public var allowsRides: Bool { self == .rides }

    public var info: ShareAccessInfo {
        switch self {
        case .live:
            ShareAccessInfo(
                title: "Location",
                desc: "See where your Tesla is, in real time.",
                icon: "location.fill",
                perm: "Location"
            )
        case .rides:
            ShareAccessInfo(
                title: "Location + rides",
                desc: "Everything above, plus send the car to pick them up.",
                icon: "car.fill",
                perm: "Location + rides"
            )
        }
    }
}

public struct ShareAccessInfo: Sendable {
    public let title: String
    public let desc: String
    public let icon: String
    public let perm: String
}

/// One row of the send-invite sheet's cumulative summary card (screens.jsx:1231-1235
/// `SHARE_CAPS`) — "{name} will be able to: …".
public struct ShareCapability: Identifiable, Sendable {
    public let key: String
    public let label: String
    public var id: String { key }
}

extension ShareAccessLevel {
    /// Whether this preset grants one summary-card capability.
    ///
    /// MYR-369 — replaces `index < info.grants`, the cumulative PREFIX render the
    /// composer used. That arithmetic was correct only while the tiers formed a
    /// total order; with `rides` no longer implying anything below it, a prefix
    /// check would tick rows the grant does not carry. Keyed rather than indexed
    /// so re-ordering or adding a capability row cannot silently re-map it.
    public func grants(_ capability: ShareCapability) -> Bool {
        switch capability.key {
        case "live": return true          // every preset grants location
        case "rides": return allowsRides
        default: return false             // a row this build cannot reason about
        }
    }
}

public enum ShareFixtures {
    /// MYR-369 — the middle persona moves off the retired `history` preset. Jonas
    /// keeps his distinct row by carrying the RIDES flag instead, so the fixture
    /// roster still exercises both switch positions (and the SUSPENDED arm, which
    /// had no fixture at all before this issue and is the state the whole feature
    /// exists for).
    public static let viewers: [Viewer] = [
        Viewer(name: "Mira Chen", email: "mira@chen.co", online: true, perm: "Location", tier: .live),
        Viewer(
            name: "Jonas Park", email: "jonas.park@hey", online: true,
            perm: "Location + rides", tier: .rides, allowRides: true
        ),
        Viewer(
            name: "Aanya Iyer", email: "aanya@iyer.dev", online: false,
            perm: "Location", tier: .live, suspended: true
        ),
    ]

    public static let pending: [PendingInvite] = [
        PendingInvite(name: "Diego Vega", email: "d.vega@studio.io", sent: "2d ago", tier: .live),
    ]

    /// screens.jsx:1231-1235, in display order (top → bottom of the summary card).
    ///
    /// MYR-369 — the history row is GONE with the tier it described. The list is
    /// no longer a cumulative PREFIX either (the composer used to check the first
    /// N rows off `ShareAccessInfo.grants`); each row is now checked against the
    /// preset's own capability, which is the only reading that survives the flags
    /// becoming independent.
    public static let capabilities: [ShareCapability] = [
        ShareCapability(key: "live", label: "See live location"),
        ShareCapability(key: "rides", label: "Request rides — send the car"),
    ]

    /// screens.jsx:1237-1240 `emailToName` — "mira.chen@x.com" → "Mira Chen".
    public static func name(fromEmail email: String) -> String {
        let local = String(email.split(separator: "@", maxSplits: 1).first ?? "")
        let cleaned = local.replacingOccurrences(of: "[._-]+", with: " ", options: .regularExpression)
        let words = cleaned.split(separator: " ").filter { !$0.isEmpty }
        let name = words
            .map { word -> String in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
        return name.isEmpty ? email : name
    }
}

// MARK: - Shared dialog copy (Invites' Revoke dialog is byte-identical to
// Settings' — screens.jsx:1370-1394 vs 1601-1625 — factored once so both
// screens stay in sync, matching CLAUDE.md "Reuse, don't fork").

public enum ShareDialogs {
    /// "Revoke access?" — used by both InvitesScreen and SettingsScreen.
    public static func revoke(_ viewer: Viewer, action: @escaping () -> Void) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "person.fill",
            title: "Revoke access?",
            message: "\(viewer.name) will no longer see your vehicle\u{2019}s location or trips. You can re-invite them anytime.",
            actionLabel: "Revoke access",
            dismissLabel: "Keep access",
            action: action
        )
    }

    /// "Resend invite?" — positive/gold, InvitesScreen only.
    ///
    /// MYR-184: the SIM copy is the prototype's verbatim (an email it has a
    /// fixture address for). The LIVE copy says what actually happens — §7.5.4
    /// mints a NEW code and invalidates the previous one across every vehicle the
    /// invite covers — because "we'll email it again" would be false twice over
    /// (no email is sent, and the old code stops working).
    public static func resend(_ invite: PendingInvite, action: @escaping () -> Void) -> MRTConfirmDialogConfig {
        let message: String
        if let email = invite.email {
            message = "We\u{2019}ll email the invite to \(email) again."
        } else {
            message = "\(invite.name) gets a new code to share. The old code stops working right away."
        }
        return MRTConfirmDialogConfig(
            kind: .positive,
            icon: "paperplane.fill",
            title: "Resend invite?",
            message: message,
            actionLabel: "Resend invite",
            dismissLabel: "Not now",
            action: action
        )
    }

    /// "Cancel invite?" — InvitesScreen only.
    public static func cancelInvite(_ invite: PendingInvite, action: @escaping () -> Void) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "envelope.fill",
            title: "Cancel invite?",
            message: "The invite to \(invite.name) will be withdrawn. You can invite them again later.",
            actionLabel: "Cancel invite",
            dismissLabel: "Keep invite",
            action: action
        )
    }

    /// "Sign out?" — owner copy (SettingsScreen).
    public static func signOutOwner(action: @escaping () -> Void) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "arrow.up.right",
            title: "Sign out?",
            message: "You'll need to sign in again to access your Tesla. Your linked vehicles stay connected.",
            actionLabel: "Sign out",
            dismissLabel: "Cancel",
            action: action
        )
    }

    /// "Sign out?" — guest copy (SharedSettingsScreen).
    public static func signOutGuest(action: @escaping () -> Void) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "arrow.up.right",
            title: "Sign out?",
            message: "You'll need an invite code to rejoin. The vehicles shared with you stay available when you sign back in.",
            actionLabel: "Sign out",
            dismissLabel: "Cancel",
            action: action
        )
    }
}
