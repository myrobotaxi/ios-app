import Foundation

// MARK: - The rider Settings vehicle section (MYR-354)
//
// THE CLIENT'S REPORT (TestFlight, Jul 30): *"Showing no vehicles shared with
// me… I own a vehicle so would it appear here or no? Because technically I can
// request a ride from it."*
//
// He is right on both counts, and the second half is the important one. MYR-343
// already established that **"what is shared with me" is not "what can I ride"**
// and fixed the rider SHELL accordingly: an owner in rider mode has zero
// `role: viewer` rows by definition, so `RiderVehicleSet.resolve` puts the
// account's OWNED car at the head and the empty state means "no vehicles AT
// ALL". Rider Settings never got that memo. It still asked the narrow question
// — `catalog.grants` — so the same account that had just been handed a "Where
// to?" CTA on its own Tesla was told, one tab away, that nothing was shared
// with it. Two surfaces, one account, two contradictory answers.
//
// This type is the ONE rule for the section, and it is deliberately built ON
// TOP of `RiderVehicleSet.resolve` rather than beside it: the empty state
// renders **iff the shell would also resolve `.empty`**, so the tab and the map
// can never disagree again. Pure + static, so the whole matrix (owned / shared /
// both / none, plus resolving and unreachable) is unit-tested with no catalog,
// no view and no clock (`RiderSettingsVehicleSectionTests`).

struct RiderSettingsVehicleSection: Equatable {
    /// One rendered row, in render order. `enterCode` is included rather than
    /// left to the view so the matrix test pins the WHOLE card.
    enum Row: Equatable {
        /// MYR-354 — the account's own Tesla. The row the client was looking for.
        case owned(id: String, name: String)
        /// A redeemed share (`role: viewer`).
        case shared(id: String, title: String, caption: String)
        /// "No vehicles shared with you yet" — reachable ONLY when the account
        /// has nothing of either kind.
        case empty
        /// The list did not answer. NOT `.empty`: one timed-out fetch is not
        /// evidence that an account owns nothing (MYR-326 / MYR-343).
        case unavailable
        /// Always last.
        case enterCode
    }

    let label: String
    let rows: [Row]

    // MARK: Copy

    /// The section label when the account owns at least one car. "Shared with
    /// me" is then simply FALSE of the first row, and titling a section with a
    /// claim its lead row contradicts is how the confusion started.
    static let ownedLabel = "Vehicles"
    /// The prototype's own label (shared-screens.jsx:477), kept verbatim for the
    /// pure-viewer account — which is every simulated capture, so SIM is
    /// unchanged by this rule.
    static let sharedOnlyLabel = "Shared with me"
    /// The owned row's caption. Says the two things the client asked about in
    /// the order he asked them: whose car it is, and that he can ride it.
    static let ownedCaption = "Your car \u{00B7} Ride from it anytime"
    /// Matches `SharedNoVehiclesScreen`'s line verbatim — same fact, same words.
    static let unavailableText = "Can\u{2019}t reach your vehicles right now"

    // MARK: The rule

    /// Resolve the section from the SAME four inputs `RiderVehicleSet.resolve`
    /// takes — by ASKING IT FIRST and rendering rows only on `.ridable`.
    ///
    /// Deferring on every input, rather than only when the lists happen to be
    /// empty, is what makes the two surfaces provably identical: there is no
    /// combination of the four inputs on which the tab can claim something the
    /// map does not. (The first draft of this function built rows whenever the
    /// lists were non-empty and only consulted the shell otherwise, which
    /// disagreed on `hasLoaded == false, loadFailed == true` with rows in hand —
    /// a state that is unreachable through `LiveSharedVehicleCatalog` today, and
    /// exactly the kind of "unreachable" that a later refactor makes reachable.
    /// `testTheEmptyStateAgreesWithTheShellOnEveryInput` failed on it.)
    ///
    /// Order is owned-first for the same reason `RiderVehicleSet` adopts owned
    /// first: the ride is created against `vehicles.first`, so the car at the top
    /// of this list is the car a "Where to?" actually books.
    static func resolve(
        hasLoaded: Bool,
        loadFailed: Bool,
        owned: [Vehicle],
        shared: [SharedVehicleGrant]
    ) -> RiderSettingsVehicleSection {
        var rows: [Row]
        switch RiderVehicleSet.resolve(
            hasLoaded: hasLoaded,
            loadFailed: loadFailed,
            grants: shared,
            ownedVehicles: owned
        ) {
        case .ridable:
            rows = owned.map { .owned(id: $0.id, name: $0.name) }
            rows += shared.map { .shared(id: $0.id, title: $0.title, caption: $0.caption) }
        case .empty:
            rows = [.empty]
        case .unavailable:
            rows = [.unavailable]
        case .resolving:
            // Nothing is known yet, so the card claims nothing — it holds only
            // the invite-code row until the list lands. A skeleton belongs on
            // the shell (MYR-343), which is the surface actually blocked on the
            // answer; a settings SECTION shimmering on its own would be motion
            // about a list nobody is waiting for.
            rows = []
        }

        // The label follows the RENDERED rows, not the raw inputs — "Vehicles"
        // over an unavailable notice would be a claim of the same kind this
        // issue removed.
        let ownsSomething = rows.contains { if case .owned = $0 { return true } else { return false } }
        rows.append(.enterCode)
        return RiderSettingsVehicleSection(
            label: ownsSomething ? ownedLabel : sharedOnlyLabel,
            rows: rows
        )
    }
}
