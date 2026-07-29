import Foundation

// MARK: - When to ask for notification authorization (MYR-186)
//
// DESIGN DECISION (locked): the app does NOT ask at launch. A cold-launch prompt
// arrives before the user has any reason to want push, and a denial is permanent
// — iOS shows the system alert exactly once per install, and everything after
// that is a trip to Settings. So the ask is deferred to the FIRST MEANINGFUL
// MOMENT, defined per role:
//
//   • OWNER — first arrival on the live home map. That is the moment the owner
//     starts caring about ride requests arriving while the app is closed, which
//     is the entire value of push for them.
//   • RIDER — right after their first ride request SUBMITS. The rider has just
//     asked a human to decide something and now has nothing to do but wait; a
//     notification is the obvious answer to "how will I know?".
//
// The design mirror (`design/`) carries no pre-prompt explainer screen for
// notifications — the Settings notification TOGGLES are the only notification UI
// the prototype has, and inventing a custom priming screen would be new design,
// not a port. So the bare system prompt is what fires. (CLAUDE.md: study the
// prototype, do not invent surfaces.)
//
// This file is a PURE function so the whole matrix is unit-testable without a
// simulator, a notification centre, or a screen: it takes the four inputs and
// returns a decision. Nothing here touches UNUserNotificationCenter.

/// The moments in the app that are allowed to trigger the authorization ask.
/// There are exactly two, one per role; anything else is not a meaningful moment
/// and must not prompt.
enum PushPermissionTrigger: Equatable {
    /// The owner arrived on the live home map (`HomeScreen`'s map tab).
    case ownerLiveHomeAppeared
    /// The rider's ride request just submitted.
    case riderRideRequestSubmitted
}

/// Why an ask was NOT made. Carried (rather than collapsing to a bare `false`)
/// so the tests read as the decision matrix and a future change to one rule
/// cannot silently absorb another.
enum PushPermissionSkipReason: Equatable {
    /// The app is running on fixtures (`AppMode.simulated`, every DEBUG capture
    /// scene). Simulated mode must be behaviourally identical to before this
    /// issue — no prompt, no registration, no drift-gate surprise.
    case notLive
    /// This install has already been asked once. iOS only ever shows the system
    /// alert once, so asking again is a silent no-op — but the one-shot gate is
    /// what makes the app's own behaviour (registration attempts, Settings
    /// affordances) stable rather than re-running on every arrival.
    case alreadyAsked
    /// The trigger does not belong to the current role — e.g. an owner-side
    /// arrival while the rider shell is showing. Each role has exactly one
    /// meaningful moment and only that one may prompt it.
    case triggerNotMeaningfulForRole
}

enum PushPermissionDecision: Equatable {
    /// Present the system authorization prompt now.
    case ask
    /// Do nothing.
    case skip(PushPermissionSkipReason)
}

/// The permission-moment resolver: role × liveness × moment × already-asked → a
/// decision. Pure and total; the caller performs the side effects.
enum PushPermissionMoment {

    /// Decide whether `trigger` is the moment to ask this user for notification
    /// authorization.
    ///
    /// Evaluation order is deliberate and is itself part of the contract:
    /// liveness first (so a simulated run can never prompt regardless of the
    /// other three inputs), then the one-shot gate, then the role/trigger match.
    static func decide(
        role: UserRole,
        isLive: Bool,
        trigger: PushPermissionTrigger,
        hasAsked: Bool
    ) -> PushPermissionDecision {
        // Liveness gates everything. Fixtures + DEBUG scenes never prompt: the
        // drift-gate captures must stay pixel-identical, and a permission alert
        // over a screenshot would be exactly the kind of change CLAUDE.md's
        // "keep the simulated experience pixel-identical" rule forbids.
        guard isLive else { return .skip(.notLive) }
        // One shot per install. Checked BEFORE the role match so a user who was
        // asked as an owner is not asked again after switching to the rider
        // shell — the authorization is per-app, not per-role.
        guard !hasAsked else { return .skip(.alreadyAsked) }

        switch (role, trigger) {
        case (.owner, .ownerLiveHomeAppeared):
            return .ask
        case (.shared, .riderRideRequestSubmitted):
            return .ask
        case (.owner, .riderRideRequestSubmitted), (.shared, .ownerLiveHomeAppeared):
            return .skip(.triggerNotMeaningfulForRole)
        }
    }
}
