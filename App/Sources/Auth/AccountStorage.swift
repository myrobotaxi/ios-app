import Foundation

// MARK: - Account-local persistence (MYR-224)
//
// Two small on-device records that live ALONGSIDE the Keychain refresh token
// (the actual credential, owned by the Kit's `KeychainRefreshTokenStore`):
//
//   • the signed-in user's PROFILE (name/email) — so the greeting + Settings
//     show real identity immediately at launch, before the silent-resume
//     refresh returns, and while offline.
//   • the per-user VIEW MODE choice (owner vs rider shell) — so a returning
//     user routes straight to the shell they last picked.
//
// Storage choice — `UserDefaults`, NOT the Keychain:
//   - Neither value is a secret. The Keychain is reserved for the refresh
//     token (a device-bound credential, §7.10). Name/email/mode are display
//     state; putting them in the Keychain would add ceremony for no security
//     gain and muddy "the Keychain holds the credential" as the one rule.
//   - Both are cleared on sign-out (below), so a signed-out device forgets the
//     identity even though `UserDefaults` would otherwise persist it.
//
// Keying:
//   - PROFILE is a SINGLE record: exactly one session exists per device (one
//     Keychain refresh token), so there is never a second signed-in identity to
//     disambiguate. Overwritten on each sign-in/refresh, cleared on sign-out.
//   - VIEW MODE is keyed by user id (the spec's requirement): the choice is a
//     property of the account, and keying by id keeps one account's choice from
//     leaking to another that later signs in on the same device.

// MARK: Profile store

/// Persists the signed-in ``UserProfile`` so identity survives relaunch/offline.
protocol ProfileStore: Sendable {
    func read() -> UserProfile?
    func write(_ profile: UserProfile)
    func clear()
}

struct UserDefaultsProfileStore: ProfileStore {
    private let defaults: UserDefaults
    private let key = "app.myrobotaxi.session.profile"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func read() -> UserProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }

    func write(_ profile: UserProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}

// MARK: View mode

/// Which shell the signed-in user is viewing. A VIEW choice, not a capability
/// gate — an account with no vehicles can still choose `.owner` (it lands on the
/// owner shell's empty state), and any account can choose `.rider`.
enum ViewMode: String, Equatable, Sendable {
    case owner
    case rider

    /// The opposite shell — what a "Switch mode" row flips to.
    var toggled: ViewMode { self == .owner ? .rider : .owner }
}

// MARK: - Post-auth routing decision (MYR-224)

/// Where a completed sign-in / silent resume routes. A pure value so the routing
/// rule is unit-testable without driving the SwiftUI shell.
enum AuthDestination: Equatable {
    /// No real account (SIM / static-token dev override) → existing onboarding.
    case onboarding
    /// Real account, no stored mode yet → show the owner/rider chooser.
    case chooser
    /// Real account with a stored mode → straight to that shell.
    case shell(ViewMode)
}

enum PostAuthRouter {
    /// - Parameters:
    ///   - user: the real signed-in identity, or `nil` when none (SIM/static).
    ///   - storedMode: the account's persisted view-mode choice, if any.
    static func destination(user: UserProfile?, storedMode: ViewMode?) -> AuthDestination {
        guard user != nil else { return .onboarding }
        if let storedMode { return .shell(storedMode) }
        return .chooser
    }
}

/// Persists the per-user view-mode choice.
protocol ModeChoiceStore: Sendable {
    func mode(forUserID userID: String) -> ViewMode?
    func setMode(_ mode: ViewMode, forUserID userID: String)
    func clearMode(forUserID userID: String)
}

struct UserDefaultsModeChoiceStore: ModeChoiceStore {
    private let defaults: UserDefaults
    private let keyPrefix = "app.myrobotaxi.viewmode."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ userID: String) -> String { keyPrefix + userID }

    func mode(forUserID userID: String) -> ViewMode? {
        defaults.string(forKey: key(userID)).flatMap(ViewMode.init(rawValue:))
    }

    func setMode(_ mode: ViewMode, forUserID userID: String) {
        defaults.set(mode.rawValue, forKey: key(userID))
    }

    func clearMode(forUserID userID: String) {
        defaults.removeObject(forKey: key(userID))
    }
}
