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
    /// MYR-184 — the cumulative tier this grant actually carries, when known
    /// (live rows always; fixtures derive it from `perm`). `perm` remains the
    /// rendered string; this is what any capability decision reads.
    public let tier: ShareAccessLevel?

    public init(id: String? = nil, name: String, email: String?, online: Bool, perm: String, tier: ShareAccessLevel? = nil) {
        self.id = id ?? email ?? name
        self.name = name
        self.email = email
        self.online = online
        self.perm = perm
        self.tier = tier
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

/// Cumulative access tier offered when sharing a Tesla (screens.jsx:1230-1236
/// `SHARE_ACCESS`) — each tier includes every capability of the tiers above it.
public enum ShareAccessLevel: String, CaseIterable, Identifiable, Sendable {
    case live, history, rides

    public var id: String { rawValue }

    /// MYR-184 — recover the tier from the rendered permission label, so a
    /// fixture row (which only ever carried the string) still reports a tier.
    /// Never used on the live path, which maps the wire enum directly.
    public static func fromPermLabel(_ label: String) -> ShareAccessLevel? {
        allCases.first { $0.info.perm == label }
    }

    public var info: ShareAccessInfo {
        switch self {
        case .live:
            ShareAccessInfo(
                title: "Live location",
                desc: "See where your Tesla is, in real time.",
                icon: "location.fill",
                perm: "Live location",
                grants: 1
            )
        case .history:
            ShareAccessInfo(
                title: "Live + history",
                desc: "Everything in Live, plus past trips & drives.",
                icon: "clock.fill",
                perm: "Live + history",
                grants: 2
            )
        case .rides:
            ShareAccessInfo(
                title: "Can request rides",
                desc: "Everything above, plus send the car to pick them up.",
                icon: "car.fill",
                perm: "Can request rides",
                grants: 3
            )
        }
    }
}

public struct ShareAccessInfo: Sendable {
    public let title: String
    public let desc: String
    public let icon: String
    public let perm: String
    /// How many `ShareFixtures.capabilities` rows this tier grants, counting
    /// from the top of the list (screens.jsx:1264 `SHARE_ACCESS[k].grants`).
    public let grants: Int
}

/// One row of the send-invite sheet's cumulative summary card (screens.jsx:1231-1235
/// `SHARE_CAPS`) — "{name} will be able to: …".
public struct ShareCapability: Identifiable, Sendable {
    public let key: String
    public let label: String
    public var id: String { key }
}

public enum ShareFixtures {
    public static let viewers: [Viewer] = [
        Viewer(name: "Mira Chen", email: "mira@chen.co", online: true, perm: "Live location", tier: .live),
        Viewer(name: "Jonas Park", email: "jonas.park@hey", online: true, perm: "Live + history", tier: .history),
        Viewer(name: "Aanya Iyer", email: "aanya@iyer.dev", online: false, perm: "Live location", tier: .live),
    ]

    public static let pending: [PendingInvite] = [
        PendingInvite(name: "Diego Vega", email: "d.vega@studio.io", sent: "2d ago", tier: .live),
    ]

    /// screens.jsx:1231-1235, in display order (top → bottom of the summary card).
    public static let capabilities: [ShareCapability] = [
        ShareCapability(key: "live", label: "See live location"),
        ShareCapability(key: "history", label: "View trip & drive history"),
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
