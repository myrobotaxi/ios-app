import SwiftUI
import DesignSystem

// MARK: - The VISUAL OFFBOARDING FLOW (MYR-366 — CLIENT-DIRECTED)
//
// TestFlight, Jul 30, on the day-old MYR-355 surface:
//
//   "the delete account is weird. It shows the email again even though its
//    displayed at the top of the settings — follow a more clean design for
//    delete account and it needs to be a visual offboarding flow with visually
//    showing the user as they are offboarded all the steps to offboard them.
//    Kind of like a clean vertical stepper where each circle animates as a check
//    mark to indicate done when flowing through the offboarding and animated
//    visuals in the end to demonstrate how to unpair the tesla virtual key, etc
//    anything else manual required."
//
// His stated priority for this surface, verbatim: **"security, transparency and
// trust is top of mind"**. Everything below is that sentence made structural.
//
// **THE HONESTY GATE IS THE WHOLE DESIGN.** There is exactly ONE network call —
// `DELETE /api/users/me`, §5.1.1(v)'s single endpoint — and it either answers
// `204` or it does not. The stepper does NOT report six server events, because
// six server events do not exist: it NARRATES the teardown sequence the endpoint
// is documented to perform, at a pace a person can read. That is a legitimate
// thing for a progress display to do and an illegitimate thing to hide, so the
// gate is drawn where it can be verified:
//
//   • Every step EXCEPT the last is narration, and may check on the clock alone.
//   • The LAST step ("Account deleted") and the "done" state check ONLY after the
//     real `204`. It is server-gated, and nothing else on this screen is.
//   • A failure STOPS the narration where it stood. The steps already checked
//     stay checked (the teardown is re-runnable, so re-running resumes rather
//     than repeats); the rest never check. **An all-checked stepper over a failed
//     delete is the one thing this screen must never render**, and it is
//     unreachable by construction rather than by care — see
//     `OffboardingStepperState.checkedCount`.
//
// The two orderings that are easy to get wrong are both pinned by tests:
// a `204` that lands BEFORE the narration finishes must NOT jump the last check
// forward (the reader would see steps complete out of order), and a narration
// that finishes BEFORE the `204` must hold a spinner on the last step rather
// than complete on hope.

// MARK: - The narrated sequence

/// The teardown sequence, per role, as the reader's own account experiences it.
///
/// These are the server's documented teardown phases in the order it performs
/// them, phrased in the second person and in the reader's role's terms — the
/// same split `AccountDeletionDialog.ownerMessage` / `.riderMessage` makes, for
/// the same reason: an owner and a rider lose genuinely different things.
///
/// **The last element is always the server-gated one.** `OffboardingStepperState`
/// takes `steps.count - 1` as its narration limit, so adding a step to either
/// list extends the NARRATED part and leaves the gate exactly where it is.
enum OffboardingSequence {
    /// The owner's six. Their car is the thing other people were using, so the
    /// order runs outward — the rides in flight, then the people, then Tesla,
    /// then the car, then the phone, then the account.
    static let ownerSteps = [
        "Rides closed out",
        "Riders\u{2019} access revoked",
        "Tesla access revoked",
        "Vehicle removed from MyRoboTaxi",
        "Notifications cleared",
        "Account deleted",
    ]

    /// The rider's four. A rider owns no car and hosts no viewers, so the two
    /// steps about other people's access are one step about their own.
    static let riderSteps = [
        "Ride requests cancelled",
        "Access to shared Teslas removed",
        "Notifications cleared",
        "Account deleted",
    ]

    static func steps(for role: UserRole) -> [String] {
        role == .owner ? ownerSteps : riderSteps
    }

    /// The screen's own heading + sub-line. Present tense while it runs; the
    /// ending screens say what happened.
    static let title = "Deleting your account"
    static let subtitle = "Here\u{2019}s everything we\u{2019}re removing."
}

// MARK: - Motion tokens
//
// The design kit's own motion grammar, not new numbers: `mrtCheckDraw`
// (onboarding.jsx:225) is a stroke-dashoffset draw, and the outline that
// precedes it is the same construction applied to the circle. The client asked
// for "~0.4s per step, staggered", which is what `checkDuration` is.

enum OffboardingMotion {
    /// One circle's full outline-draw → check-draw beat.
    static let checkDuration: Double = 0.4
    /// The circle's ring drawing itself, from 12 o'clock, clockwise.
    static let outlineDrawDuration: Double = 0.22
    /// The check drawing itself inside the completed ring.
    static let checkDrawDuration: Double = 0.18
    /// Total wall-clock the NARRATED steps take, whatever the role's step count.
    /// Both roles land inside the client's "~3-4s total" because the interval is
    /// derived from this rather than fixed per step — an owner sees six steps in
    /// the same time a rider sees four, which is what makes the two flows feel
    /// like one product rather than one being twice the wait.
    static let narrationDuration: Double = 3.2

    /// Seconds between one step's check landing and the next one's.
    static func stepInterval(stepCount: Int) -> Double {
        narrationDuration / Double(max(1, stepCount - 1))
    }

    /// The stagger a step at `index` is drawn with once the screen is settled —
    /// used only by the Reduce Motion / already-complete render, where every
    /// check is already at 1 and nothing is timed.
    static let ringDiameter: CGFloat = 28
    static let ringLineWidth: CGFloat = 1.5
    /// Gap between one step row's circle centre and the next.
    static let rowSpacing: CGFloat = 26
}

// MARK: - The state machine

/// Everything the stepper renders, as a value with no view and no clock.
///
/// It is a struct rather than logic inside the screen so the four orderings that
/// matter — failure at each phase, `204`-before-narration, narration-before-`204`,
/// and retry — are each one assertion in `AccountOffboardingTests` instead of a
/// timing-dependent UI test that would be slow and flaky in equal measure.
struct OffboardingStepperState: Equatable {
    /// What the ONE `DELETE` has answered so far.
    enum ServerOutcome: Equatable {
        /// In flight. The last step cannot check.
        case pending
        /// `204 No Content`. The last step may check — once narration reaches it.
        case succeeded
        /// The call threw. Narration stops; nothing further checks.
        case failed
    }

    let stepCount: Int
    /// How many steps the NARRATION has walked. Never exceeds `narrationLimit`.
    private(set) var narrated: Int = 0
    private(set) var server: ServerOutcome = .pending

    init(stepCount: Int) {
        self.stepCount = stepCount
    }

    /// Narration may check every step except the last one.
    var narrationLimit: Int { max(0, stepCount - 1) }

    /// How many circles carry a checkmark.
    ///
    /// **This is the honesty gate**, and it is one expression on purpose: the
    /// full count is returned only when the server said `204` AND the narration
    /// has caught up. Every other combination — pending, failed, or a `204` that
    /// arrived early — returns the narrated count, capped below the last step. A
    /// failed delete therefore CANNOT render an all-checked stepper, whatever a
    /// caller does to the narration.
    var checkedCount: Int {
        if server == .succeeded, narrated >= narrationLimit { return stepCount }
        return min(narrated, narrationLimit)
    }

    var isComplete: Bool { checkedCount == stepCount }
    var hasFailed: Bool { server == .failed }

    /// The step currently in flight — the one wearing the spinner. `nil` once the
    /// flow has completed or failed, because neither state has work in flight.
    var activeIndex: Int? {
        guard !isComplete, !hasFailed else { return nil }
        return checkedCount
    }

    /// The conceptual phase the failure stopped at — the circle that turns red.
    var failedIndex: Int? {
        guard hasFailed else { return nil }
        return min(narrated, narrationLimit)
    }

    /// True while the narration still has a step to walk. False the moment the
    /// server fails, which is what STOPS the narration rather than merely hiding
    /// its output.
    var canNarrate: Bool { server != .failed && narrated < narrationLimit }

    mutating func narrateOneStep() {
        guard canNarrate else { return }
        narrated += 1
    }

    /// The `204`. Idempotent, and never overrides a recorded failure.
    mutating func recordSuccess() {
        guard server == .pending else { return }
        server = .succeeded
    }

    /// The throw. Idempotent, and never overrides a recorded success.
    mutating func recordFailure() {
        guard server == .pending else { return }
        server = .failed
    }

    /// "Try again". The endpoint is re-runnable by contract, so the steps already
    /// checked are NOT un-checked: re-running finishes the job from where it got
    /// to, and un-checking would claim the previous attempt undid itself.
    mutating func retry() {
        guard server == .failed else { return }
        server = .pending
    }
}

// MARK: - Copy

/// The offboarding screen's own strings, next to the sequence they narrate —
/// the `AccountDeletionDialog` precedent (copy lives with copy, never inline in
/// a view, so a test can pin it).
enum OffboardingCopy {
    /// The failure treatment reuses MYR-355's LOCKED notice verbatim, split at
    /// the sentence boundary exactly as the alert does. The words were argued
    /// once; a second wording of the same fact is a second thing to keep true.
    static let failureTitle = AccountDeletionDialog.failureNoticeTitle
    static let failureBody = AccountDeletionDialog.failureNoticeBody
    /// The endpoint is re-runnable, so the recovery is the action and not a
    /// support address.
    static let retryLabel = "Try again"
    /// The way back to a Settings screen the user is still signed in to — MYR-355's
    /// rule, which this screen inherits whole.
    static let failureDismissLabel = "Not now"

    // MARK: The owner's ending

    static let ownerEndingTitle = "Two steps only you can do"
    /// States the account IS gone before asking for anything else. The two steps
    /// are Tesla's to perform and nothing in this app can reach them.
    static let ownerEndingSubtitle = "Your account is deleted. These last two live on Tesla\u{2019}s side \u{2014} we can\u{2019}t do them for you."

    // MARK: The rider's ending

    static let riderEndingTitle = "Your account is deleted."
    static let riderEndingSubtitle = "Nothing remains."

    static let doneLabel = "Done"
}

// MARK: - The two manual steps (shared with the vehicle-removal flow)

/// The two things only the owner can do, in one place.
///
/// They are needed by TWO surfaces — the offboarding ending (the full ceremony,
/// animated) and MYR-258's last-vehicle removal confirm (a compact static
/// version, because removing your only car leaves the same key on the same
/// screen and the same grant in the same Tesla account) — so the copy is one
/// value and both render it. Two literals would be two places for the menu path
/// to go stale the next time Tesla moves it.
///
/// `caption` is what the client asked for verbatim: the title, then the literal
/// path. `title` and `path` exist separately because the compact version sets
/// them on two lines and the ceremony sets the caption whole, and
/// `AccountOffboardingTests` asserts the two can never disagree.
struct ManualOffboardingStep: Equatable, Identifiable {
    let id: String
    let icon: String
    let title: String
    let path: String

    var caption: String { "\(title): \(path)" }

    /// (a) The virtual key. There is no Fleet API and no deep link for this —
    /// §7.12 says `automatable: false` — so instructions are the whole of what
    /// any client can offer, which is exactly why they are worth animating.
    static let virtualKey = ManualOffboardingStep(
        id: "virtualKey",
        icon: "key.horizontal",
        title: "Remove the MyRoboTaxi key",
        path: "Car touchscreen \u{2192} Controls \u{2192} Locks \u{2192} tap the MyRoboTaxi key \u{2192} Remove"
    )

    /// (b) The OAuth grant. Only Tesla can revoke a third-party grant, and only
    /// the account holder can ask it to.
    static let appAccess = ManualOffboardingStep(
        id: "appAccess",
        icon: "person.crop.circle.badge.xmark",
        title: "Revoke app access",
        path: "Tesla app \u{2192} Profile \u{2192} Third-Party Apps \u{2192} MyRoboTaxi \u{2192} Remove Access"
    )

    static let both: [ManualOffboardingStep] = [.virtualKey, .appAccess]

    /// The heading the COMPACT version wears when it rides inside the
    /// last-vehicle removal confirm. The ceremony has its own screen title.
    static let compactHeading = "Two steps only you can do"
}
