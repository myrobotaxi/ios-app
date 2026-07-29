import Foundation
import UIKit
import UserNotifications

// MARK: - The UIKit half of push (MYR-186)
//
// APNs only speaks to a `UIApplicationDelegate`, and notification presentation
// only to a `UNUserNotificationCenterDelegate`. Neither can be a SwiftUI view, so
// this file is the one UIKit seam — and it is deliberately DUMB. It owns no
// policy: every decision (should we suppress this banner? where does this tap
// land?) is made by the pure resolvers in `PushNotificationRouting`, and every
// side effect by `PushRegistrationCoordinator`. The delegate just forwards.
//
// The delegate is instantiated by SwiftUI (`@UIApplicationDelegateAdaptor`)
// before `RootView` exists, so the two meet at `PushDelegateBridge` — a tiny
// main-actor mailbox `RootView` fills in once it has composed its state.

/// The hand-off point between the UIKit delegate and the SwiftUI app state.
/// Every member is set by `RootView`; all are optional so the app is well-defined
/// during the window before `RootView` has appeared (a notification tapped in
/// that window is simply not routed — the surfaces it would route to do not
/// exist yet, and the cold-launch refetch reaches the same state anyway).
@MainActor
final class PushDelegateBridge {
    static let shared = PushDelegateBridge()
    private init() {}

    /// Receives token delivery / failure and the foreground retry.
    var coordinator: PushRegistrationCoordinator?
    /// What the app is showing right now, for the banner-suppression decision.
    var surfaceContext: (() -> PushSurfaceContext)?
    /// Applies a resolved tap route to the existing app state.
    var applyTapRoute: ((PushTapRoute, PushRideNotification?) -> Void)?
}

/// The app delegate. Registers itself as the notification-centre delegate at
/// launch and forwards the four callbacks push needs.
///
/// It does NOT call `registerForRemoteNotifications()` at launch: that is the
/// coordinator's decision, taken only once the user has actually authorized
/// (`PushRegistrationCoordinator.handleForeground`). Registering here would ask
/// APNs for a token on a device that has never been prompted.
final class PushAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushDelegateBridge.shared.coordinator?.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Task { @MainActor in
            PushDelegateBridge.shared.coordinator?.handleRegistrationFailure(error)
        }
    }
}

// MARK: - Notification presentation + taps

extension PushAppDelegate: UNUserNotificationCenterDelegate {

    /// The app is in the FOREGROUND and a notification arrived. Ask the pure
    /// resolver whether the user is already looking at this ride's surface.
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = PushRideNotification.from(userInfo: notification.request.content.userInfo)
        guard let context = PushDelegateBridge.shared.surfaceContext?() else {
            // No app state yet — present, rather than silently swallow.
            return [.banner, .sound]
        }
        switch PushNotificationRouting.foregroundPresentation(notification: payload, context: context) {
        case .present: return [.banner, .sound]
        case .suppress: return []
        }
    }

    /// The user TAPPED a notification (or an action on it). Resolve the route and
    /// hand it to `RootView`, which arrives at the surface through existing state.
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = PushRideNotification.from(userInfo: response.notification.request.content.userInfo)
        guard let context = PushDelegateBridge.shared.surfaceContext?() else { return }
        let route = PushNotificationRouting.tapRoute(notification: payload, role: context.role)
        PushDelegateBridge.shared.applyTapRoute?(route, payload)
    }
}
