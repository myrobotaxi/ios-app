import Foundation
import UIKit
import UserNotifications

// MARK: - Notification-authorization seam (MYR-186)
//
// `UNUserNotificationCenter.current()` cannot be constructed, stubbed, or driven
// from a unit test, and `registerForRemoteNotifications()` needs a real
// `UIApplication`. Both are therefore behind this one narrow protocol — the same
// narrowing the Kit uses for `HTTPPerforming` — so `PushRegistrationCoordinator`
// (where all the sequencing logic lives) is fully testable with no OS state.

/// The app's own authorization vocabulary. Deliberately smaller than
/// `UNAuthorizationStatus`: the app only ever branches three ways, and a local
/// enum keeps the tests free of the `UserNotifications` framework.
enum PushAuthorizationState: Equatable, Sendable {
    /// Never asked — the system prompt is still available exactly once.
    case notDetermined
    /// Asked and granted (including provisional/ephemeral grants — anything that
    /// can receive a token).
    case authorized
    /// Asked and refused, or switched off later in Settings. The only route back
    /// is the Settings app.
    case denied
}

protocol PushAuthorizing: Sendable {
    /// The current system authorization state.
    func authorizationState() async -> PushAuthorizationState
    /// Present the system prompt. Returns whether authorization was granted.
    /// Calling this when the state is not `.notDetermined` is a silent no-op at
    /// the OS level, which is precisely why the app keeps its own one-shot gate.
    func requestAuthorization() async -> Bool
    /// Ask APNs for a device token. The token arrives asynchronously on the app
    /// delegate, never as a return value.
    @MainActor func registerForRemoteNotifications()
}

/// The production conformer, over `UNUserNotificationCenter` + `UIApplication`.
struct SystemPushAuthorizer: PushAuthorizing {

    func authorizationState() async -> PushAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            // A future status the app has no opinion about is treated as "not
            // authorized but already decided" — never as an invitation to prompt.
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        // `.alert, .sound, .badge` is the whole v1 ask: ride alerts are banners
        // with copy. No critical/provisional variants — a provisional grant would
        // deliver ride requests silently to Notification Centre, which is exactly
        // the failure mode push is here to fix.
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return granted ?? false
    }

    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
