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
    /// The list is genuinely being fetched and NOTHING is known yet — render
    /// skeleton rows (MYR-386). See ``ShareRosterLoadPhase`` for why this is an
    /// arm of the state rather than a `Bool` beside it.
    case loading
    /// Nothing accepted AND nothing pending — the hero empty state. This is the
    /// ONLY arm that renders an explainer + CTA; every other arm is a list.
    ///
    /// **Reachable ONLY from a COMPLETED fetch.** That is the whole of MYR-386.
    case empty
    /// At least one row exists. Carries ONLY non-empty sections, in display
    /// order, which is what structurally forbids an orphaned header.
    case populated([ShareRosterSection])
    /// The fetch FAILED and nothing is in hand. Carries the service's own quiet
    /// sentence. Never `.empty`: "no one has access yet" is a CLAIM about the
    /// account and a failed read does not support it (MYR-343's rule, applied
    /// here).
    case unavailable(String)

    /// The one rule over the phase and the two published lists.
    ///
    /// Accepted sorts above pending deliberately: an accepted grant is live
    /// access to the owner's car and is the thing they came to audit; a pending
    /// invite is a piece of housekeeping. The prototype already ordered them this
    /// way and nothing about the client's complaint was the order.
    ///
    /// **THE PHASE ONLY DECIDES WHAT AN EMPTY PAIR OF LISTS MEANS.** Rows in hand
    /// win over both the loading and the failed phase, which is not a nicety:
    /// `LiveShareService` re-reads the whole list after every mutation and on
    /// every appearance of the tab, so a refresh that blanked the roster into a
    /// skeleton — or into a failure screen — would make a revoke look like the
    /// list falling over. This is the same rule `LiveSharedVehicleCatalog`
    /// already applies when it leaves the last-known grants standing.
    static func resolve(
        phase: ShareRosterLoadPhase,
        viewers: [Viewer],
        pending: [PendingInvite]
    ) -> ShareRosterState {
        var sections: [ShareRosterSection] = []
        if !viewers.isEmpty { sections.append(.accepted(viewers)) }
        if !pending.isEmpty { sections.append(.invited(pending)) }
        if !sections.isEmpty { return .populated(sections) }

        switch phase {
        // `.idle` shimmers with `.loading` DELIBERATELY. On this screen the two
        // are one situation a frame apart — `InvitesScreen.task` calls `load()`
        // unconditionally on appear, so "not asked yet" is always "about to
        // ask", and splitting them would put the empty hero on screen for
        // exactly the one frame the client photographed. The standing rule
        // (shimmer only while a fetch genuinely runs) is kept by the SERVICE:
        // `LiveShareService` leaves `.idle` for `.loaded` the moment it
        // establishes there is nothing to fetch, so no skeleton here outlives a
        // fetch.
        case .idle, .loading: return .loading
        case .loaded: return .empty
        case .failed(let message): return .unavailable(message)
        }
    }
}

// MARK: - Where the invite-list fetch stands (MYR-386)

/// THE CLIENT'S REPORT (TestFlight, build 202607311129): *"Need to add the
/// skeleton loading to this page. It flashes no one added then appears."*
///
/// `ShareService` has published `isLoading: Bool` and `statusMessage: String?`
/// since MYR-184 and **`InvitesScreen` read neither**. So the screen resolved its
/// whole state from two arrays that start `[]`, and an empty array in flight is
/// indistinguishable from an empty array that came back empty: the tab rendered
/// "No one has access yet" — the definitive, CTA-bearing hero — over a fetch that
/// had not answered, then swapped it for the real rows.
///
/// This is MYR-343's lesson for the third time in this codebase (`hasLoaded &&
/// grants.isEmpty`, then `RiderSettingsVehicleSection`, now here): **three
/// genuinely different situations cannot be told apart by one flag, so one of them
/// always borrows another's surface for a frame.** A phase has an arm for each,
/// and the empty state becomes unreachable before a completed fetch rather than
/// merely unlikely.
///
/// Two booleans were not enough either, which is why this replaces them rather
/// than joining them: `isLoading == false, statusMessage == nil` is BOTH
/// "loaded, and genuinely empty" and "nobody has asked yet".
enum ShareRosterLoadPhase: Equatable, Sendable {
    /// Nothing has been asked yet.
    case idle
    /// A fetch is genuinely running right now. The ONLY phase that may shimmer.
    case loading
    /// A fetch COMPLETED and the published lists are its answer. The only phase
    /// from which the empty state is reachable.
    case loaded
    /// A fetch completed by failing, carrying the quiet one-line sentence the
    /// screen shows. Never a dialog (design minimalism, same convention as
    /// `VehicleFleet.statusMessage`).
    case failed(String)
}

// MARK: - What the owner's FLEET is doing (MYR-386)

/// The Share tab's per-vehicle invite fetches are keyed on the owner's vehicle
/// list, so the roster cannot resolve before that list does.
///
/// `LiveShareService.performLoad` has always short-circuited on an empty fleet —
/// correctly, since §7.5.2 is a per-vehicle endpoint and there is nothing to ask.
/// But it could not tell "this account owns no cars" from "the fleet has not
/// answered yet", and both left the roster empty with nothing in flight — i.e.
/// the SECOND source of the client's flash, and the reason a Share tab opened
/// during a cold boot used to sit on the empty hero permanently (nothing re-asked
/// when the fleet landed).
///
/// It is a closure into the SAME started fleet `shareableVehicles` already reads,
/// not a new fetch: the fleet is loaded once, by `OwnerHomeState`, and this screen
/// only asks what it is doing.
enum ShareFleetState: Equatable, Sendable {
    /// `GET /api/vehicles` is in flight — a fetch IS genuinely running, and the
    /// roster is blocked on it, so the skeleton is honest.
    case resolving
    /// The list answered. An empty fleet now genuinely means "no cars", and an
    /// owner with no cars has nothing shared.
    case resolved
    /// The list did not answer. NOT "nothing is shared with you".
    case unreachable
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
    /// - Parameters:
    ///   - vehicleRideShareEnabled: the vehicle switch's DERIVED position — off
    ///     for an owner's pause and off for a service visit alike, because both
    ///     mean nobody can request this car and a per-person ride permission has
    ///     nothing to grant either way.
    ///   - vehicleInService: which of those two it is (MYR-358). It changes only
    ///     the CAPTION, never the enablement: an in-service car is a temporary
    ///     FACT the owner cannot flip, and a caption that said "ride sharing is
    ///     off for this car" would read as a choice they made and send them to a
    ///     switch that is itself inert.
    static func resolve(
        viewer: Viewer,
        vehicleRideShareEnabled: Bool,
        vehicleInService: Bool = false,
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
                //
                // MYR-358 — an IN-SERVICE car gets its own sentence, because the
                // two states are not the same thing said twice. "Ride sharing is
                // off" describes a switch the owner set and can unset; a car in a
                // service bay was withdrawn by nobody, the switch above is inert,
                // and it comes back on its own. Following
                // `VehicleRideShare.inServiceCaption`'s reasoning, this states the
                // FACT and that it resolves itself — and, like that caption,
                // deliberately avoids the word this app has already spent on the
                // owner's own decision.
                ridesCaption: vehicleInService
                    ? (vehicleName.map { "\($0) is in service \u{2014} rides resume automatically" }
                        ?? "This car is in service \u{2014} rides resume automatically")
                    : (vehicleName.map { "Ride sharing is off for \($0)" }
                        ?? "Ride sharing is off for this car")
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
