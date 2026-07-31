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

@MainActor
protocol RideActivityPresenting: AnyObject {
    /// Whether the SYSTEM will allow a Live Activity at all. False when the rider
    /// has turned Live Activities off for this app in Settings — a real and
    /// unremarkable state that must not be treated as an error.
    var areActivitiesEnabled: Bool { get }

    /// Whether this presenter currently holds a live Activity.
    var isPresenting: Bool { get }

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

    func start(
        attributes: RideActivityAttributes,
        state: RideActivityAttributes.ContentState,
        staleDate: Date?
    ) async -> Bool {
        guard areActivitiesEnabled else { return false }
        // Never run two. `Activity.request` would happily give us a second one and
        // the rider would get two cards for one ride.
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
