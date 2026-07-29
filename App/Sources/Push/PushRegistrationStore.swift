import Foundation

// MARK: - Push registration persistence (MYR-186)
//
// Follows `AccountStorage.swift`'s conventions exactly: a `Sendable` protocol in
// front of a `UserDefaults` value type with an injectable suite, so tests use a
// scratch suite and never touch the real one. Nothing stored here is a secret —
// an APNs device token is a routing address, not a credential — so per that
// file's documented rule ("the Keychain is reserved for the refresh token") it
// belongs in `UserDefaults`, not the Keychain.

/// The small amount of state push registration has to remember across launches.
protocol PushRegistrationStore: Sendable {
    /// Whether this install has already been shown the system authorization
    /// prompt. The one-shot gate behind `PushPermissionMoment`.
    func hasAskedForAuthorization() -> Bool
    func setHasAskedForAuthorization(_ value: Bool)

    /// The token the server has CONFIRMED (a `PUT` that returned 2xx), together
    /// with the app build that confirmed it. Both are needed to answer "does the
    /// server already know this device?" — a token can rotate, and an app upgrade
    /// is its own reason to re-assert registration even when the token did not
    /// change.
    func confirmedRegistration() -> PushConfirmedRegistration?
    func setConfirmedRegistration(_ value: PushConfirmedRegistration?)

    /// A token whose `PUT` has NOT yet succeeded. Persisted so a failed
    /// registration is retried on the next foreground instead of being lost with
    /// the process — push must never block or retry in the user's face.
    func pendingToken() -> String?
    func setPendingToken(_ value: String?)
}

/// A token the backend has acknowledged, stamped with the build that sent it.
struct PushConfirmedRegistration: Codable, Equatable, Sendable {
    var token: String
    /// `CFBundleVersion` at the time of confirmation. A changed value means the
    /// app was upgraded and the registration is re-asserted (MYR-186: "re-send on
    /// token rotation and on app upgrade").
    var build: String
}

struct UserDefaultsPushRegistrationStore: PushRegistrationStore {
    private let defaults: UserDefaults
    private let askedKey = "app.myrobotaxi.push.hasAsked"
    private let confirmedKey = "app.myrobotaxi.push.confirmedRegistration"
    private let pendingKey = "app.myrobotaxi.push.pendingToken"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func hasAskedForAuthorization() -> Bool { defaults.bool(forKey: askedKey) }

    func setHasAskedForAuthorization(_ value: Bool) { defaults.set(value, forKey: askedKey) }

    func confirmedRegistration() -> PushConfirmedRegistration? {
        guard let data = defaults.data(forKey: confirmedKey) else { return nil }
        return try? JSONDecoder().decode(PushConfirmedRegistration.self, from: data)
    }

    func setConfirmedRegistration(_ value: PushConfirmedRegistration?) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: confirmedKey)
            return
        }
        defaults.set(data, forKey: confirmedKey)
    }

    func pendingToken() -> String? { defaults.string(forKey: pendingKey) }

    func setPendingToken(_ value: String?) {
        guard let value, !value.isEmpty else {
            defaults.removeObject(forKey: pendingKey)
            return
        }
        defaults.set(value, forKey: pendingKey)
    }
}

/// The current app build (`CFBundleVersion`), the stamp on a confirmed
/// registration. Injectable for tests; `"0"` if the key is somehow absent, which
/// simply makes every launch look like the same build.
enum PushAppBuild {
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
