import ActivityKit
import Foundation

// MARK: - The ActivityKit seam (MYR-172)
//
// ActivityKit is unreachable from a unit test: `Activity.request` needs a real
// host app with a real installed widget extension, and `ActivityAuthorizationInfo`
// reads a system setting no test can set. So the framework sits behind this
// protocol exactly the way `UNUserNotificationCenter`/`UIApplication` sit behind
// MYR-186's `PushAuthorizing` — one narrow protocol, one thin system conformer
// with no policy in it, and a stub in the tests.
//
// The rule that keeps it honest: NOTHING HERE DECIDES ANYTHING. Every "should we?"
// lives in `RideActivityStateMachine`, which is pure and fully tested. This
// protocol is only "do it".

/// How long after its last update the content should be considered stale.
enum RideActivityStaleness {
    /// ~3 minutes, per MYR-194 decision 4 ("the Activity renders 'as of X min ago'
    /// when updates lapse beyond ~3 min; never a confident stale ETA").
    ///
    /// This is only the LOCAL default, used for the frame the app writes itself. A
    /// server push carries its own `stale-date` in the `aps` dictionary and that
    /// value wins — the server knows when it next intends to speak, and the client
    /// does not. So this number governs exactly one window: from a locally-started
    /// Activity until the first push lands.
    static let window: TimeInterval = 3 * 60

    static func date(from reference: Date = Date()) -> Date {
        reference.addingTimeInterval(window)
    }
}

/// What the app can see of ONE Activity ActivityKit has restored into this
/// process (MYR-405).
///
/// A snapshot, not a handle: the coordinator decides from these and the presenter
/// carries the decision out by ride id, so every lifecycle rule in this feature
/// stays in the pure layer where it can be asserted.
struct RideActivitySnapshot: Equatable, Sendable {
    /// ActivityKit's `ActivityState`, narrowed to the four the app acts on.
    ///
    /// The two that are NOT on screen are the interesting ones. `.ended` means the
    /// app (or the system) already ended it and it is living out its dismissal
    /// policy — including MYR-405's deliberate five-minute completed linger — so
    /// re-ending it would cut that linger short. `.dismissed` means the RIDER
    /// swiped it away, which is a decision this app must not overrule.
    enum Lifecycle: Equatable, Sendable {
        case active
        case stale
        case ended
        case dismissed

        /// Is this Activity still occupying space on the rider's lock screen in a
        /// way the app is still responsible for?
        var isOnScreenAndOurs: Bool {
            switch self {
            case .active, .stale: return true
            case .ended, .dismissed: return false
            }
        }
    }

    let rideID: String
    let lifecycle: Lifecycle
}

/// How long the app waits for ActivityKit's ASYNCHRONOUS restore (MYR-405).
///
/// `Activity.activities` is NOT populated synchronously at launch. A start path
/// that enumerates it on the first turn of the run loop reads an empty array,
/// concludes there is nothing to adopt, and requests a SECOND Activity beside the
/// one already on the lock screen — which is exactly the client's two-banner
/// screenshot. The capture tooling hit the identical race on the same day
/// (`RideActivityDebugLauncher`'s sweep) and was fixed the same way.
enum RideActivityRestore {
    /// ~2s of budget, in 250ms steps. Deliberately generous: this runs on a
    /// background `Task` with nothing on screen waiting for it, and the cost of
    /// being wrong is a duplicate banner that only a reinstall clears.
    static let attempts = 8
    static let interval: Duration = .milliseconds(250)
}

@MainActor
protocol RideActivityPresenting: AnyObject {
    /// Whether the SYSTEM will allow a Live Activity at all. False when the rider
    /// has turned Live Activities off for this app in Settings — a real and
    /// unremarkable state that must not be treated as an error.
    var areActivitiesEnabled: Bool { get }

    /// Whether this presenter currently holds a live Activity.
    var isPresenting: Bool { get }

    /// Every Activity of this type the process can currently see — a PLAIN,
    /// SYNCHRONOUS read of `Activity.activities` (MYR-405).
    ///
    /// Synchronous and un-retried ON PURPOSE. The list fills in over the first
    /// moments of a process, so "wait until it settles" is a POLICY, and policy
    /// belongs to the coordinator where a stub can drive it. A seam method that
    /// did the waiting itself would put the whole defect back behind ActivityKit,
    /// where no test can reach it.
    var presentedActivities: [RideActivitySnapshot] { get }

    /// Take over a restored Activity as the one this presenter drives, so that
    /// `update`, `end` and `pushTokens` all address it.
    ///
    /// Returns `false` when no Activity for that ride is visible — which, given
    /// the restore race above, is a statement about this instant and not about
    /// the lock screen.
    func adopt(rideID: String) -> Bool

    /// End a restored Activity BY RIDE ID, whether or not it is the one this
    /// presenter holds. The orphan-reaping path (MYR-405) needs to end Activities
    /// this process never started.
    func endActivity(rideID: String, dismissal: RideActivityDismissal) async

    /// The held Activity's own lifecycle, as the system reports it.
    ///
    /// This is how a USER DISMISSAL becomes knowable: a swipe moves the Activity
    /// to `.dismissed` and nothing else tells the app it happened. Without it the
    /// next status change would cheerfully update a card the rider deliberately
    /// removed, or — worse — a relaunch would start a fresh one.
    func activityStates() -> AsyncStream<RideActivitySnapshot.Lifecycle>

    /// Start one. Returns `false` if the system refused (disabled, or the
    /// per-app concurrent limit is reached) — never throws, because there is
    /// nothing the caller could do differently and a rider who disabled Live
    /// Activities is not an exceptional condition.
    func start(
        attributes: RideActivityAttributes,
        state: RideActivityAttributes.ContentState,
        staleDate: Date?
    ) async -> Bool

    func update(state: RideActivityAttributes.ContentState, staleDate: Date?) async

    func end(state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal) async

    /// The Activity's own push tokens, as they are issued and REISSUED.
    ///
    /// A stream rather than a single value because ActivityKit rotates the token
    /// during the life of one Activity and expects the server to switch to the new
    /// one. Missing a rotation does not fail loudly — the old token simply stops
    /// delivering, and the lock screen quietly stops updating.
    func pushTokens() -> AsyncStream<Data>
}

// MARK: - The system conformer

@MainActor
final class SystemRideActivityPresenter: RideActivityPresenting {
    private var activity: Activity<RideActivityAttributes>?

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isPresenting: Bool { activity != nil }

    var presentedActivities: [RideActivitySnapshot] {
        Activity<RideActivityAttributes>.activities.map {
            RideActivitySnapshot(
                rideID: $0.attributes.rideID,
                lifecycle: RideActivitySnapshot.Lifecycle($0.activityState)
            )
        }
    }

    func adopt(rideID: String) -> Bool {
        guard let existing = Activity<RideActivityAttributes>.activities.first(where: {
            $0.attributes.rideID == rideID && $0.activityState.isAdoptable
        }) else { return false }
        activity = existing
        return true
    }

    func endActivity(rideID: String, dismissal: RideActivityDismissal) async {
        for existing in Activity<RideActivityAttributes>.activities
        where existing.attributes.rideID == rideID {
            // THE HELD ACTIVITY IS NEVER ENDED BY ID, and this is what makes
            // "keep one, reap the duplicates" expressible at all. Two Activities can
            // carry the SAME ride id — that is the client's screenshot — so a reap
            // that matched on the id alone would take down the very banner the
            // adoption just kept, and the rider would watch both cards vanish.
            guard existing.id != activity?.id else { continue }
            // `nil` content, deliberately: this Activity is being reaped because it
            // does not describe anything the account is doing, and the app has no
            // honest final frame for a ride it cannot see. Passing `nil` leaves the
            // last content it had and takes it down.
            await existing.end(nil, dismissalPolicy: dismissal.uiPolicy)
        }
    }

    func activityStates() -> AsyncStream<RideActivitySnapshot.Lifecycle> {
        guard let activity else { return AsyncStream { $0.finish() } }

        return AsyncStream { continuation in
            let task = Task {
                for await state in activity.activityStateUpdates {
                    continuation.yield(RideActivitySnapshot.Lifecycle(state))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start(
        attributes: RideActivityAttributes,
        state: RideActivityAttributes.ContentState,
        staleDate: Date?
    ) async -> Bool {
        guard areActivitiesEnabled else { return false }
        // Never run two. `Activity.request` would happily give us a second one and
        // the rider would get two cards for one ride.
        //
        // ⚠️ MYR-405 — THIS GUARD IS ABOUT A PROCESS, NOT ABOUT A LOCK SCREEN, and
        // reading it as the latter is what shipped the duplicate. `activity` is this
        // INSTANCE's handle and is nil in every new process, while the card started
        // by the last process is still up. The lock-screen-wide question is asked in
        // `RideActivityCoordinator.performStart`, over `presentedActivities`, with
        // the restore budget spent before an empty answer is believed. Keep both:
        // this one is cheap and correct about the one case it covers.
        guard activity == nil else { return false }

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate),
                // `.token` is what makes this a PUSH-updated Activity — it is the
                // request for the per-Activity push token the server needs. Without
                // it `pushTokenUpdates` yields nothing and the Activity can only
                // ever be updated by the app in the foreground, which is precisely
                // the situation a Live Activity exists to survive.
                pushType: .token
            )
            return true
        } catch {
            // Requesting can fail for reasons that are all the system's business
            // (the rider revoked permission a moment ago, too many Activities are
            // running). None is actionable and none is worth surfacing to a rider
            // who is about to be picked up, so the Activity is simply not shown.
            return false
        }
    }

    func update(state: RideActivityAttributes.ContentState, staleDate: Date?) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(state: RideActivityAttributes.ContentState, dismissal: RideActivityDismissal) async {
        guard let activity else { return }
        // The final frame carries NO stale date. Staleness means "this may have
        // moved on without us", and a finished ride cannot: the last frame of a
        // completed ride is permanently accurate, and letting it grey itself out
        // during the 15-minute linger would undo the reason for the linger.
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: dismissal.uiPolicy
        )
        self.activity = nil
    }

    func pushTokens() -> AsyncStream<Data> {
        guard let activity else { return AsyncStream { $0.finish() } }

        return AsyncStream { continuation in
            let task = Task {
                for await token in activity.pushTokenUpdates {
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension RideActivitySnapshot.Lifecycle {
    /// ActivityKit's `ActivityState`, narrowed.
    ///
    /// The enum is `@frozen`-less and Apple has added a case to it before
    /// (`.stale`, iOS 16.2), so the `default` arm is required rather than tidy —
    /// and it maps to `.active`, the conservative reading: an unknown state is an
    /// Activity that may well still be on the lock screen, and treating it as gone
    /// is how an orphan survives a reap.
    init(_ state: ActivityState) {
        switch state {
        case .active: self = .active
        case .stale: self = .stale
        case .ended: self = .ended
        case .dismissed: self = .dismissed
        @unknown default: self = .active
        }
    }
}

private extension ActivityState {
    /// May an Activity in this state be taken over and driven?
    ///
    /// Only one that is still on screen. Adopting an `.ended` Activity would hand
    /// the coordinator a card whose dismissal is already scheduled — it would
    /// register a push token for something the system is in the middle of removing.
    var isAdoptable: Bool {
        RideActivitySnapshot.Lifecycle(self).isOnScreenAndOurs
    }
}

extension RideActivityDismissal {
    /// The ActivityKit spelling.
    ///
    /// `.linger` becomes `.after(now + interval)` rather than `.default`, because
    /// the system default is 4 hours — long enough that yesterday's ride is still
    /// on the lock screen this morning.
    var uiPolicy: ActivityUIDismissalPolicy {
        switch self {
        case .immediate:
            return .immediate
        case .linger(let interval):
            return .after(Date().addingTimeInterval(interval))
        }
    }
}
