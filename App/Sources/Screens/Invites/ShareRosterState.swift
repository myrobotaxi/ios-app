import Foundation

// MARK: - Share tab state model (MYR-347)
//
// THE CLIENT'S ASK (TestFlight, Jul 29, AGrw9E8oKTLDNlk5Bgw5RfE): *"This page is
// just awkward. I know the prototype looks like this but weird text in the middle
// saying viewers 0 and then one pending request below. Using proper clean iOS
// design on this page and make it look better."* CLIENT OUTRANKS PROTOTYPE — the
// standing precedent MYR-346 set on the FSD celebration.
//
// What he photographed was not a styling problem, it was a MISSING STATE. The
// prototype's Share tab renders "VIEWERS · N" unconditionally (screens.jsx:113)
// and "PENDING" conditionally (screens.jsx:127), so an account with nothing
// accepted and one invite out — the state EVERY owner is in on day one — showed a
// header counting to zero, a consolation sentence under it, and then a lone row
// under a second header. Three competing pieces of chrome for one row of content.
//
// The fix is a single resolved state rather than two independent `if`s, so
// "collapse an empty section" is not a rule anyone has to remember at the call
// site: a section that has no rows is not IN the model, and therefore cannot
// render a header. `resolve` is a pure function of the two lists the
// `ShareService` seam already publishes — no service change (this issue is
// presentation only), and the whole matrix is unit-testable without a screen.
enum ShareRosterState: Equatable {
    /// Nothing accepted AND nothing pending — the hero empty state. This is the
    /// ONLY arm that renders an explainer + CTA; every other arm is a list.
    case empty
    /// At least one row exists. Carries ONLY non-empty sections, in display
    /// order, which is what structurally forbids an orphaned header.
    case populated([ShareRosterSection])

    /// The one rule over the two published lists.
    ///
    /// Accepted sorts above pending deliberately: an accepted grant is live
    /// access to the owner's car and is the thing they came to audit; a pending
    /// invite is a piece of housekeeping. The prototype already ordered them this
    /// way and nothing about the client's complaint was the order.
    static func resolve(viewers: [Viewer], pending: [PendingInvite]) -> ShareRosterState {
        var sections: [ShareRosterSection] = []
        if !viewers.isEmpty { sections.append(.accepted(viewers)) }
        if !pending.isEmpty { sections.append(.invited(pending)) }
        return sections.isEmpty ? .empty : .populated(sections)
    }
}

/// One rendered group of the roster. Non-empty by construction — `resolve` never
/// builds one from an empty array — so `count` is always ≥ 1 and the count badge
/// never reads "0".
enum ShareRosterSection: Identifiable, Equatable {
    /// Redeemed grants: these people can see the car right now.
    case accepted([Viewer])
    /// Codes that have gone out and not been redeemed.
    case invited([PendingInvite])

    var id: String {
        switch self {
        case .accepted: "accepted"
        case .invited: "invited"
        }
    }

    /// The section header.
    ///
    /// **"Shared with", not "Riding with you"** — a deliberate copy choice. The
    /// accepted list holds every tier, and `live` (the DEFAULT the composer opens
    /// on) grants location only; §7.5.0 has the server 403 a ride created from
    /// below `rides`, and `riderWatchOnly` exists precisely so the client never
    /// offers what will fail. A header that says these people ride the car would
    /// assert the top tier about a list whose most common member is on the bottom
    /// one. "Shared with" is also already the header `SettingsScreen` puts over
    /// this same list, so the two surfaces read as one product.
    var title: String {
        switch self {
        case .accepted: "Shared with"
        case .invited: "Invited"
        }
    }

    var count: Int {
        switch self {
        case .accepted(let viewers): viewers.count
        case .invited(let invites): invites.count
        }
    }
}

// MARK: - Invited-row detail line (MYR-347)

/// The muted line under a pending invite's name: what it grants, and how old it
/// is — "Live + history · Invited 2d ago".
///
/// It exists as a named, pure function because `PendingInvite.sent` is NOT one
/// vocabulary. `SimulatedShareService` writes the prototype's bare relative
/// ("2d ago", "just now"); `LiveShareService.sentLabel` writes the sentence
/// fragment it was designed for — "sent 2d ago", the bare "sent" when `createdAt`
/// will not parse, and "expired" when §7.5.2's expiry has passed and the code
/// silently stopped redeeming. Composing a prefix onto that unexamined is how the
/// first build of this screen shipped "Invited sent 2d ago" into a capture, and
/// would have shipped "Invited expired" — which reads as a date.
enum ShareInviteDetail {

    static func line(tier: ShareAccessLevel?, sent: String) -> String {
        let age = ageClause(sent)
        guard let tier else { return age }
        return "\(tier.info.perm) \u{00B7} \(age)"
    }

    /// The age half, normalized to ONE grammar across both services.
    static func ageClause(_ sent: String) -> String {
        let trimmed = sent.trimmingCharacters(in: .whitespaces)
        // §7.5.2 — an expired invite is still `pending`; the owner has to be able
        // to tell it apart from a live one, so this is stated rather than aged.
        if trimmed.caseInsensitiveCompare("expired") == .orderedSame { return "Invite expired" }
        var age = trimmed
        if age.lowercased().hasPrefix("sent ") { age = String(age.dropFirst(5)) }
        // No usable age (an unparseable `createdAt`) — say the true thing and
        // stop, rather than inventing a "just now" nobody measured.
        if age.isEmpty || age.caseInsensitiveCompare("sent") == .orderedSame { return "Invited" }
        return "Invited \(age)"
    }
}

// MARK: - Per-viewer control state (MYR-369)

/// What the two switches on ONE accepted row read and whether they may be
/// touched — resolved once, as a pure function, so the copy and the enablement
/// can be asserted without a view.
///
/// This is a named type rather than four expressions inside the row body because
/// the interaction between the three inputs is the whole feature and is easy to
/// get subtly wrong: the vehicle-level pause and a per-grant suspension disable
/// the SAME switch for DIFFERENT reasons, and a row that greys out without
/// distinguishing them tells the owner nothing about how to undo it.
struct ShareViewerControls: Equatable {
    /// The MASTER switch — on when the grant is active. Off writes
    /// `{suspended: true}`, which removes the car from that viewer's world
    /// entirely.
    var locationOn: Bool
    /// The RIDES switch, in its STORED position. Shown in that position even
    /// while the row is suspended, which is the contract's own instruction: a
    /// suspended grant keeps its flags and restoring returns exactly what it had,
    /// so an owner needs to see what is coming back. It is disabled there, not
    /// re-drawn as off — re-drawing it off would be a claim about the stored
    /// value that is simply false.
    var ridesOn: Bool
    /// Whether the RIDES switch may be touched. False while suspended (suspension
    /// gates everything, so the flag beneath it is inert) and false while the
    /// VEHICLE's own ride sharing is off (nobody can request this car at all, so
    /// a per-person ride permission has nothing to grant).
    var ridesInteractive: Bool
    /// The line under the name. Says the CONSEQUENCE, never the mechanism.
    var subtitle: String
    /// Why the rides switch cannot be touched, when it cannot. `nil` when it can
    /// — an explanation under a live control is noise.
    var ridesCaption: String?

    /// The one place the three inputs are combined.
    ///
    /// PRECEDENCE MATTERS AND IS NOT ARBITRARY: suspension is checked FIRST,
    /// because it is the stronger and more specific fact. A suspended viewer of a
    /// car whose ride sharing is also off must be told they cannot see the car at
    /// all — telling them instead that ride requests are paused would name the
    /// lesser of two reasons and send the owner to the wrong switch.
    static func resolve(
        viewer: Viewer,
        vehicleRideShareEnabled: Bool,
        vehicleName: String?
    ) -> ShareViewerControls {
        if viewer.suspended {
            return ShareViewerControls(
                locationOn: false,
                ridesOn: viewer.allowRides,
                ridesInteractive: false,
                // Names the PERSON and the CONSEQUENCE. "Suspended" is the wire's
                // word for it and means nothing to an owner; what they need to
                // know is that this person's access is off and reversible.
                subtitle: "Paused \u{2014} \(viewer.name) can\u{2019}t see this car",
                ridesCaption: "Turn location back on to change this"
            )
        }
        if !vehicleRideShareEnabled {
            return ShareViewerControls(
                locationOn: true,
                ridesOn: viewer.allowRides,
                ridesInteractive: false,
                subtitle: "Can see this car\u{2019}s location",
                // The VEHICLE-LEVEL context, stated where the disabled switch is
                // rather than left for the owner to infer from a card two
                // sections up. Names the car when there is more than one, since
                // on a multi-car account "ride sharing is off" is ambiguous.
                ridesCaption: vehicleName.map { "Ride sharing is off for \($0)" }
                    ?? "Ride sharing is off for this car"
            )
        }
        return ShareViewerControls(
            locationOn: true,
            ridesOn: viewer.allowRides,
            ridesInteractive: true,
            subtitle: viewer.allowRides
                ? "Can see this car and request rides"
                : "Can see this car\u{2019}s location",
            ridesCaption: nil
        )
    }
}
