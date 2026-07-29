import Foundation

// MARK: - APNs token encoding + build environment (MYR-186)

/// Hex encoding of the raw APNs device token.
///
/// The token arrives as `Data` in
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` and the
/// backend contract wants lowercase hex. This exists as a named, tested function
/// rather than an inline `map` because the classic way to get this wrong is
/// `token.description`: on iOS 13+ that is `"{length = 32, bytes = 0x0011…}"`,
/// which registers cleanly, looks plausible in a log, and then silently never
/// delivers a notification. Two-character zero padding matters for the same
/// reason — a byte `0x0b` written as `"b"` shifts every character after it.
enum PushDeviceToken {

    /// Lowercase, zero-padded hex — two characters per byte, no separators.
    /// Empty data yields an empty string (never a token the server would store).
    static func hex(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Which APNs environment THIS BUILD is signed into — the `sandbox` flag on
/// `PUT/DELETE /api/push/devices`.
///
/// A device token is only valid against the APNs environment that minted it, and
/// nothing in the token says which one that was, so the server has to be told.
/// The answer is a property of the BUILD, not of the run: it is decided by the
/// `aps-environment` entitlement the build was signed with (see `project.yml`).
///
///   • DEBUG builds — signed `development` → sandbox APNs → `true`.
///   • RELEASE builds, which is what `xcodebuild -exportArchive` produces for
///     TestFlight and the App Store — re-signed by the managed distribution
///     profile carrying `aps-environment: production` → `false`.
///
/// So **TestFlight builds are production APNs**, not sandbox. That is the single
/// most common way to lose a whole round of on-device push testing: a build that
/// registers as sandbox but is signed production gets a token APNs will never
/// route to.
enum PushEnvironment {

    /// `true` when this build talks to the APNs SANDBOX.
    static var isSandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
