import Foundation
import UIKit

// MARK: - The UIKit/SwiftUI seam for universal links (MYR-346)
//
// The pure half of this feature is `InviteLinkRouting`. This is the dumb half:
// it receives an activated URL and hands it to whoever is listening. It makes no
// decisions — same contract as `PushDelegateBridge`, and for the same reason.
//
// WHY A MAILBOX AND NOT JUST A CLOSURE. A universal link tapped from a cold
// state activates the app and delivers the activity DURING launch, which on this
// app's SwiftUI-lifecycle shell can land before `RootView` has appeared and
// installed anything. Push tolerates that window by simply dropping the tap —
// `PushAppDelegate`'s header says so outright — because its cold-launch refetch
// reaches the same surface anyway. An invite code has no refetch. Nothing else
// in the system will ever produce those six characters again, so a URL that
// arrives before anyone is listening is HELD until someone is.
//
// WHY TWO DELIVERY PATHS. `NSUserActivity` reaches a SwiftUI-lifecycle app
// through `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` on a view in
// the scene; it reaches a UIKit-lifecycle app through
// `application(_:continue:restorationHandler:)` on the app delegate. This app is
// SwiftUI-lifecycle WITH a `@UIApplicationDelegateAdaptor` (`PushAppDelegate`),
// which is precisely the configuration where which one fires is a function of
// what UIKit decided to synthesise for the scene — SwiftUI's own scene delegate
// claims the callback when it has one. Rather than bet on that, BOTH feed this
// mailbox and delivery is idempotent: re-routing the same code re-presents the
// same prefilled flow, which is a no-op (`InviteCodeFlow`'s prefill only submits
// when the value actually changes). Guessing wrong in the other direction would
// mean a link that silently does nothing on some iOS version.

/// The hand-off point between the system's universal-link delivery and the
/// SwiftUI app state. One slot, drained by the first listener to install.
@MainActor
final class InviteLinkBridge {
    static let shared = InviteLinkBridge()
    private init() {}

    /// A URL that arrived before `RootView` was listening. At most one is held:
    /// a second activation before the app is up supersedes the first, because it
    /// is the one the user just tapped.
    private var pending: URL?

    /// Installed by `RootView` from `body`, so the closure captures live view
    /// state. Idempotent — a repeat appearance simply re-installs.
    private var handler: ((URL) -> Void)?

    /// The system activated a universal link. Deliver it now, or hold it.
    func receive(_ url: URL) {
        if let handler {
            handler(url)
        } else {
            pending = url
        }
    }

    /// `RootView` is ready. Take the handler and drain anything held.
    func install(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let url = pending {
            pending = nil
            handler(url)
        }
    }

    #if DEBUG
    /// Test seam: forget both the handler and anything held, so one test's
    /// activation cannot leak into the next.
    func resetForTesting() {
        pending = nil
        handler = nil
    }

    /// Test seam: whether a URL is currently held for a listener that has not
    /// arrived yet — the cold-launch window this type exists for.
    var hasPendingLinkForTesting: Bool { pending != nil }
    #endif
}

// MARK: - The UIKit delivery path

extension PushAppDelegate {

    /// A universal link activated the app through the UIKit lifecycle callback.
    ///
    /// Returns `true` unconditionally for a browsing-web activity we recognise
    /// as ours and `false` otherwise, which is the contract's own meaning
    /// ("did you handle it") — a `false` lets the system fall back to opening the
    /// URL in Safari, which for a `/join/{CODE}` page we could not parse is
    /// exactly right: the web surface renders it, we do not.
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              InviteLink.code(from: url) != nil
        else { return false }

        Task { @MainActor in
            InviteLinkBridge.shared.receive(url)
        }
        return true
    }
}
