import AuthenticationServices
import CryptoKit
import Foundation
import MyRoboTaxiKit
import Observation
import UIKit

// MARK: - Auth session (MYR-164)
//
// The seam between the sign-in UI and the auth backend. Two conformers share
// one surface so the sign-in screen never branches on sim-vs-live:
//
//   • `SimulatedAuthSession` — the M1 / SIM default: flips a local flag, touches
//     no network. Every fixture scene and the offline demo run on this, so the
//     sign-in screen stays pixel-identical.
//   • `LiveAuthSession`      — the real Sign in with Apple flow (MYR-164):
//     ASAuthorizationController → Kit `POST /api/auth/apple` → session adoption
//     in a Kit `SessionTokenProvider`. Selected only for a live launch with no
//     static token (see `AuthComposition`).
//
// `signIn()` stays `async throws` for both: the live path throws on cancel /
// failure; the simulated path cannot fail. The sign-in screen distinguishes a
// user-cancel (stay silently) from a failure (calm error affordance) via
// `AuthSignInError`.

@MainActor
protocol AuthSession: AnyObject {
    /// True once a session is established.
    var isSignedIn: Bool { get }

    /// The real signed-in account identity (MYR-224), or `nil` when there is no
    /// real account behind the session. `nil` is the seam the persona surfaces
    /// branch on: SIM (and the static-token dev override) return `nil` so the
    /// greeting/Settings keep their pixel-identical FIXTURE persona; the live
    /// Sign in with Apple session returns the real `{ id, name?, email? }` so
    /// those same surfaces render true identity. Presence of a value ALSO gates
    /// the owner/rider mode chooser + the Settings "Switch mode" row — both exist
    /// only on the live signed-in path.
    var currentUser: UserProfile? { get }

    /// Establishes a session. Live: Sign in with Apple + backend token exchange
    /// (throws ``AuthSignInError`` on cancel/failure). Sim: resolves immediately.
    func signIn() async throws

    /// Tears the session down (Settings "Sign out" flows return here). Live:
    /// revokes the refresh-token family + clears the Keychain (best-effort,
    /// non-blocking). Sim: flips the flag.
    func signOut()

    /// Attempt to SILENTLY resume a stored session at launch — no user
    /// interaction (MYR-221 returning-user auto-route). Live: refresh from the
    /// Keychain refresh token; on success `isSignedIn` becomes true and the app
    /// routes straight in, skipping SignInScreen; on failure (no session / spent
    /// or revoked refresh token / network) it returns false and the app shows
    /// SignInScreen. Sim: no stored session → always false (default below).
    func resumeStoredSession() async -> Bool
}

extension AuthSession {
    /// Default: no resumable session (the simulated session never persists one).
    func resumeStoredSession() async -> Bool { false }
}

/// Why a live sign-in did not complete, so the sign-in screen can react calmly.
enum AuthSignInError: Error {
    /// The user dismissed the Apple sheet — stay on the sheet, show nothing.
    case canceled
    /// Anything else (no credential, bad identity token, backend rejection,
    /// network) — show the calm error affordance.
    case failed
}

/// M1 / SIM stand-in — flips a local flag, touches nothing else.
@MainActor
@Observable
final class SimulatedAuthSession: AuthSession {
    private(set) var isSignedIn = false

    /// Always `nil`: the simulated session carries no real account, so every
    /// persona surface keeps its fixture persona and the mode chooser never
    /// appears (the sim keeps the existing onboarding role selection).
    var currentUser: UserProfile? { nil }

    func signIn() async throws {
        isSignedIn = true
    }

    func signOut() {
        isSignedIn = false
    }
}

/// The real backend session (MYR-164). Owns the native Sign in with Apple
/// interaction and hands the resulting credential to the Kit's
/// ``SessionTokenProvider`` for the `POST /api/auth/apple` exchange.
@MainActor
@Observable
final class LiveAuthSession: AuthSession {
    private(set) var isSignedIn = false

    /// The real signed-in identity (MYR-224). Populated on sign-in (the
    /// `/api/auth/apple` response) and on silent resume (from the refresh the
    /// provider performs — `sessionProvider.sessionUser()`), persisted to
    /// ``profileStore`` so it is available immediately on the next launch and
    /// offline, and cleared on sign-out. Eagerly seeded from the store in `init`
    /// so a returning user's greeting/Settings never flash empty before resume.
    private(set) var currentUser: UserProfile?

    private let sessionProvider: SessionTokenProvider
    private let profileStore: any ProfileStore
    private let appleController = AppleSignInController()

    init(sessionProvider: SessionTokenProvider, profileStore: any ProfileStore = UserDefaultsProfileStore()) {
        self.sessionProvider = sessionProvider
        self.profileStore = profileStore
        self.currentUser = profileStore.read()
    }

    func signIn() async throws {
        // Nonce: a random raw value; the SHA-256 of it is set on the Apple
        // request AND forwarded to the backend. Apple embeds the value we set
        // verbatim into the identity token's `nonce` claim, so the value we send
        // the backend equals that claim (rest-api.md §7.10.1 "must equal the
        // token's nonce claim"). Replay protection for the identity token.
        let rawNonce = Self.randomNonce()
        let hashedNonce = Self.sha256(rawNonce)

        let credential = try await appleController.authorize(hashedNonce: hashedNonce)

        guard
            let identityTokenData = credential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            throw AuthSignInError.failed
        }

        // Apple returns the name only on the FIRST authorization; forward it when
        // present so the backend can persist it (§7.10.1). Empty → omit.
        let formatter = PersonNameComponentsFormatter()
        let fullName = credential.fullName.map { formatter.string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }

        let request = AppleSignInRequest(
            identityToken: identityToken,
            fullName: fullName,
            email: credential.email,
            nonce: hashedNonce
        )

        do {
            let user = try await sessionProvider.completeAppleSignIn(request)
            adoptProfile(user)
        } catch {
            throw AuthSignInError.failed
        }
        isSignedIn = true
    }

    /// Silent resume (MYR-221): ask the session provider for an access token,
    /// which refreshes from the stored Keychain refresh token. Success →
    /// signed-in (route straight into the app). A `notSignedIn` (no stored token),
    /// `sessionExpired` (refresh rejected — provider already cleared it), or a
    /// network error all resolve to false → the app shows SignInScreen.
    func resumeStoredSession() async -> Bool {
        do {
            _ = try await sessionProvider.token()
            // The refresh `token()` just performed returns the server's current
            // `{ id, name?, email? }` — the recovery path for a session that
            // predates local profile persistence (no `/api/auth/me` exists).
            // Falls back to the eagerly-loaded stored profile if absent.
            if let user = await sessionProvider.sessionUser() {
                adoptProfile(user)
            }
            isSignedIn = true
            return true
        } catch {
            return false
        }
    }

    func signOut() {
        // Local state clears immediately; the network revoke + Keychain clear run
        // best-effort in the background (revoke is idempotent, §7.10.3). The
        // profile is display state, cleared synchronously so a signed-out device
        // forgets the identity at once.
        isSignedIn = false
        currentUser = nil
        profileStore.clear()
        let provider = sessionProvider
        Task { await provider.signOut() }
    }

    /// Adopt a fresh identity: publish it to `currentUser` and persist it.
    private func adoptProfile(_ user: AuthUser) {
        let profile = UserProfile(id: user.id, name: user.name, email: user.email)
        currentUser = profile
        profileStore.write(profile)
    }

    // MARK: Nonce

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Apple authorization controller

/// Bridges `ASAuthorizationController`'s delegate + presentation-anchor callback
/// world into a single `async throws` call. Finds the active window scene itself
/// (no anchor passed from SwiftUI). Retained by ``LiveAuthSession``; the
/// in-flight controller is kept alive by the suspended `authorize` frame.
final class AppleSignInController: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    @MainActor
    func authorize(hashedNonce: String) async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { continuation = nil }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AuthSignInError.failed)
            return
        }
        continuation?.resume(returning: credential)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer { continuation = nil }
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            continuation?.resume(throwing: AuthSignInError.canceled)
        } else {
            continuation?.resume(throwing: AuthSignInError.failed)
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
