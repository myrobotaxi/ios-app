import SwiftUI
import AuthenticationServices
import MyRoboTaxiKit

// MARK: - Owner car offboarding — live teardown seam (rest-api.md §7.12, MYR-258)
//
// The live-path glue behind SettingsScreen's "Remove this car" flow: the Kit
// `DELETE /api/tesla/vehicles/{id}` call, the fleet drop so the car leaves the
// list immediately, and the owner-only consent-revoke browser session that opens
// the response's `revokeUrl`. The simulated M1 path (nil seam) keeps the existing
// local `vehiclesState.unlink` — untouched, pixel-identical (MYR-228).
//
// SECURITY: the teardown carries only the vehicle cuid on the authenticated
// pipeline; the consent-revoke session opens the server-provided `revokeUrl`
// (public, no secret) and never reads or retains any callback query material —
// the redirect just signals the owner returned.

// MARK: - Consent-revoke callback parsing (pure — unit-tested)

/// How the owner-confirmed Tesla consent-revoke session ended.
enum TeslaUnlinkOutcome: Equatable {
    /// Tesla redirected back to `myrobotaxi://tesla-unlinked` — the owner
    /// completed (or dismissed) the consent-revoke page and returned to the app.
    case completed
    /// The owner cancelled the system browser session before returning.
    case cancelled
    /// The session ended without a recognizable callback (an error, or a stray
    /// redirect). No material is captured.
    case unknown
}

/// Parses the Tesla consent-revoke redirect
/// `myrobotaxi://tesla-unlinked` (the `back_url` baked into §7.12's `revokeUrl`)
/// into a `TeslaUnlinkOutcome`. Pure and side-effect-free — mirrors
/// `TeslaLinkCallback`. Unlike the link callback there is no `status`/`reason`
/// contract on the revoke redirect (Tesla owns that page), so a matching
/// scheme+host is simply the owner returning; anything else is `.unknown`.
enum TeslaUnlinkCallback {
    /// The registered custom scheme (shared with the link callback) + the host the
    /// revoke `back_url` points at.
    static let scheme = "myrobotaxi"
    static let host = "tesla-unlinked"

    static func outcome(from url: URL) -> TeslaUnlinkOutcome {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host
        else { return .unknown }
        return .completed
    }
}

// MARK: - Live consent-revoke session (ASWebAuthenticationSession)

/// The "open the owner-confirmed consent-revoke URL" entry point. Never throws —
/// every ending is a typed `TeslaUnlinkOutcome`.
typealias TeslaRevoker = @MainActor (URL) async -> TeslaUnlinkOutcome

/// Opens the §7.12 `revokeUrl` in an `ASWebAuthenticationSession` (scheme
/// `myrobotaxi`, NON-ephemeral so the owner's existing Tesla web session is
/// reused) and parses the `myrobotaxi://tesla-unlinked` return. Mirrors
/// `LiveTeslaAuthenticator`'s anchor + retention pattern.
@MainActor
final class LiveTeslaRevokeSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Held so the in-flight session isn't deallocated (which would cancel it).
    private var session: ASWebAuthenticationSession?

    func run(url: URL) async -> TeslaUnlinkOutcome {
        await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: TeslaUnlinkCallback.scheme
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(returning: .cancelled)
                    } else {
                        continuation.resume(returning: .unknown)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(returning: .unknown)
                    return
                }
                continuation.resume(returning: TeslaUnlinkCallback.outcome(from: callbackURL))
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(returning: .unknown)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - The teardown seam consumed by SettingsScreen

/// The bundle of live-only capabilities the SettingsScreen "Remove this car" flow
/// needs. `nil` on sim / DEBUG keeps the existing local unlink pixel-identical.
struct VehicleTeardownSeam {
    /// `DELETE /api/tesla/vehicles/{id}` — the authoritative teardown call.
    let remove: (String) async throws -> VehicleTeardownResponse
    /// Drop the car from the authoritative fleet the moment the teardown succeeds
    /// (updates both Home and the Settings list — they read the same fleet).
    let onRemoved: (String) -> Void
    /// Open the §7.12 `revokeUrl` in the system browser (owner-only follow-up).
    let revoke: TeslaRevoker
}

// MARK: - Composition point

/// Builds the live teardown seam on the LIVE path, or `nil` (simulated) — mirrors
/// `TeslaLinkComposition`. Reuses the live fleet's resolved environment + session
/// token provider so the `DELETE` carries the exact signed-in owner's Bearer.
enum VehicleTeardownComposition {
    /// The Kit `removeVehicle` call, bound to the live environment + session, or
    /// `nil` on the simulated path.
    @MainActor
    static func makeRemover(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> ((String) async throws -> VehicleTeardownResponse)? {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else { return nil }
        let client = RestClient(environment: config.environment, tokenProvider: config.tokenProvider)
        return { try await client.removeVehicle(vehicleID: $0) }
    }

    /// The consent-revoke browser runner. Constructs a fresh session per call and
    /// retains it for the duration of the async run (the local binding outlives the
    /// system session, exactly like `TeslaLinkComposition`'s authenticator).
    @MainActor
    static func makeRevoker() -> TeslaRevoker {
        { url in await LiveTeslaRevokeSession().run(url: url) }
    }
}
