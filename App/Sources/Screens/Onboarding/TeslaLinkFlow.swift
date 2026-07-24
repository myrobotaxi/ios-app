import SwiftUI
import AuthenticationServices
import DesignSystem
import MyRoboTaxiKit

// MARK: - Live in-app Tesla link (rest-api.md §7.11, MYR-246)
//
// The real implementation of the `AddTeslaFlow` `authenticate` seam
// (TeslaAuth.swift): calls `POST /api/tesla/link/start` via the authenticated
// `RestClient`, opens the returned Tesla authorize URL in an
// `ASWebAuthenticationSession` (callback scheme `myrobotaxi`), and maps the
// backend's `myrobotaxi://tesla-linked?status=…` deep link into a
// `TeslaAuthOutcome`. The simulated M1 path (nil authenticator) is untouched.
//
// SECURITY: no token, `state`, `code`, or any URL query material is EVER logged
// or persisted here — the authorize URL is handed straight to the system session
// and the callback is parsed for `status`/`reason` only. The Tesla
// `client_secret` never reaches the device (the server mints the authorize URL
// and completes the code→token exchange).

/// The user-facing outcome of a failed link — a §7.11 callback `reason`, or a
/// local failure (the `/start` call, or the system session) — with honest copy.
/// Every case offers a retry (`AddTeslaFlow` shows a "Try again" affordance).
enum TeslaLinkFailure: Equatable {
    /// §7.11 `tesla_denied` — the user declined on Tesla / refused a scope.
    case teslaDenied
    /// §7.11 `invalid_state` (a.k.a. an expired/replayed link session) — the
    /// 10-min single-use session no longer matched.
    case sessionExpired
    /// §7.11 `missing_code` — Tesla's redirect carried no authorization code.
    case missingCode
    /// §7.11 `exchange_failed` — Tesla rejected the code→token exchange.
    case exchangeFailed
    /// §7.11 `account_not_provisioned` — the caller has no Tesla `Account` row to
    /// write into yet (MVP pre-provisioning prerequisite, §2.1).
    case accountNotProvisioned
    /// §7.11 `persist_failed` — token encryption / DB write failed server-side.
    case persistFailed
    /// The `POST /api/tesla/link/start` call itself failed (network / auth /
    /// malformed authorize URL) — the system session never opened.
    case startFailed
    /// The system session ended in an error that is not a user cancel, or an
    /// unrecognised `reason` on the callback. No material is captured.
    case unknown

    /// Map a §7.11 `reason` query value to a case. Unknown / missing → `.unknown`.
    /// Accepts `session_expired` as an alias for the contract's `invalid_state`.
    init(reason: String?) {
        switch reason {
        case "tesla_denied": self = .teslaDenied
        case "invalid_state", "session_expired": self = .sessionExpired
        case "missing_code": self = .missingCode
        case "exchange_failed": self = .exchangeFailed
        case "account_not_provisioned": self = .accountNotProvisioned
        case "persist_failed": self = .persistFailed
        default: self = .unknown
        }
    }

    /// Short headline for the error surface.
    var title: String {
        switch self {
        case .teslaDenied: return "Tesla access wasn't granted"
        case .sessionExpired: return "That request expired"
        case .missingCode, .exchangeFailed, .unknown: return "Couldn't finish linking"
        case .accountNotProvisioned: return "Account isn't ready yet"
        case .persistFailed: return "Couldn't save the connection"
        case .startFailed: return "Couldn't start Tesla sign-in"
        }
    }

    /// Honest, non-technical explanation + what to do next.
    var message: String {
        switch self {
        case .teslaDenied:
            return "You declined the permissions MyRoboTaxi needs to connect your car. Try again and approve access to link your Tesla."
        case .sessionExpired:
            return "The Tesla sign-in timed out. Please try again — it only takes a minute."
        case .missingCode, .exchangeFailed, .unknown:
            return "We couldn't complete the connection with Tesla. Please try again."
        case .accountNotProvisioned:
            return "This account isn't set up to link a Tesla yet. Finish the one-time setup on the web, then link again here."
        case .persistFailed:
            return "We reached Tesla but couldn't save the connection. Please try again."
        case .startFailed:
            return "We couldn't reach MyRoboTaxi to start the link. Check your connection and try again."
        }
    }
}

// MARK: - Callback deep-link parsing (pure — unit-tested)

/// Parses the backend's `myrobotaxi://tesla-linked?status=…[&reason=…]` redirect
/// (§7.11.2) into a `TeslaAuthOutcome`. Pure and side-effect-free so the whole
/// status→outcome mapping is table-testable without the system session.
enum TeslaLinkCallback {
    /// The registered custom scheme + host the backend 302s to.
    static let scheme = "myrobotaxi"
    static let host = "tesla-linked"

    /// `status=success` → `.granted`; `status=error` → `.failed(reason)`; any
    /// other/absent host or status → `.failed(.unknown)`. Never reads or retains
    /// any other query item (no token material is present, by contract, but we
    /// also never touch it).
    static func outcome(from url: URL) -> TeslaAuthOutcome {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (components.scheme?.lowercased() == scheme),
              (components.host?.lowercased() == host)
        else { return .failed(.unknown) }

        let items = components.queryItems ?? []
        let status = items.first { $0.name == "status" }?.value
        let reason = items.first { $0.name == "reason" }?.value

        switch status {
        case "success":
            return .granted
        case "error":
            return .failed(TeslaLinkFailure(reason: reason))
        default:
            return .failed(.unknown)
        }
    }
}

// MARK: - Start-request plumbing (testable with a fake `TeslaLinkEndpoint`)

/// Error surfaced when the `/start` response can't yield a usable authorize URL.
enum TeslaLinkStartError: Error, Equatable {
    /// The `authorizeUrl` field wasn't a well-formed absolute `https` URL.
    case invalidAuthorizeURL
}

/// The "call `/tesla/link/start` and hand back the authorize URL" step, split out
/// from the system-session glue so it can be unit-tested with a fake client.
struct TeslaLinkStarter {
    let client: any TeslaLinkEndpoint

    /// Fetch the authorize URL. Validates it is an absolute `https` URL (Tesla's
    /// authorize origin) before returning — a malformed value fails fast rather
    /// than opening a bogus session.
    func authorizeURL() async throws -> URL {
        let response = try await client.teslaLinkStart()
        guard let url = URL(string: response.authorizeUrl),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { throw TeslaLinkStartError.invalidAuthorizeURL }
        return url
    }
}

// MARK: - Live authenticator (ASWebAuthenticationSession)

/// Runs the real Tesla link end-to-end: `/start` → `ASWebAuthenticationSession`
/// (scheme `myrobotaxi`, NON-ephemeral so an existing Tesla web session is
/// reused) → parse the callback. Retained for the flow's lifetime by the closure
/// `TeslaLinkComposition` stores into `AddTeslaFlow.authenticate`.
@MainActor
final class LiveTeslaAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let starter: TeslaLinkStarter
    /// Held so the in-flight session isn't deallocated (which would cancel it).
    private var session: ASWebAuthenticationSession?

    init(starter: TeslaLinkStarter) {
        self.starter = starter
    }

    /// The `TeslaAuthenticator` entry point. Never throws — every failure is a
    /// typed `TeslaAuthOutcome`.
    func authenticate() async -> TeslaAuthOutcome {
        let authorizeURL: URL
        do {
            authorizeURL = try await starter.authorizeURL()
        } catch {
            // No URL/token material logged — just the typed failure.
            return .failed(.startFailed)
        }

        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: TeslaLinkCallback.scheme
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(returning: .cancelled)
                    } else {
                        continuation.resume(returning: .failed(.unknown))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(returning: .failed(.unknown))
                    return
                }
                continuation.resume(returning: TeslaLinkCallback.outcome(from: callbackURL))
            }
            session.presentationContextProvider = self
            // Owners very likely have a live Tesla web session — reuse it rather
            // than forcing a fresh login (task constraint).
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(returning: .failed(.startFailed))
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

// MARK: - Composition point

/// Builds the live Tesla-link authenticator on the LIVE path, or `nil`
/// (simulated) — mirroring `TelemetryComposition` / `AuthComposition`. Reuses the
/// live fleet's resolved environment + session token provider so the link `/start`
/// call carries the exact signed-in owner's Bearer.
enum TeslaLinkComposition {
    @MainActor
    static func makeAuthenticator(
        mode: AppMode,
        sessionTokenProvider: SessionTokenProvider? = nil
    ) -> TeslaAuthenticator? {
        guard let config = TelemetryComposition.liveFleetConfig(
            mode: mode,
            sessionTokenProvider: sessionTokenProvider
        ) else { return nil }
        let client = RestClient(environment: config.environment, tokenProvider: config.tokenProvider)
        let authenticator = LiveTeslaAuthenticator(starter: TeslaLinkStarter(client: client))
        // The closure retains `authenticator` for the flow's lifetime (needed so
        // the presentation-context provider outlives the async session).
        return { await authenticator.authenticate() }
    }
}

// MARK: - Virtual-key pairing

/// The Tesla virtual-key enrollment handoff URL (`tesla.com/_ak/<app domain>`).
/// Opening it hands off to the Tesla app so the owner approves MyRoboTaxi's
/// virtual key on the vehicle.
enum TeslaVirtualKey {
    static let pairingURL = URL(string: "https://tesla.com/_ak/myrobotaxi.app")!
}

// MARK: - Error surface (live link failure)

/// Honest failure state shown in place of the `AddTeslaFlow` intro when a live
/// link attempt fails. Renders the reason's copy and a retry affordance (plus a
/// way back out). Reuses the onboarding gutter + button so it sits pixel-natural
/// inside the flow's existing gold-wash background.
struct TeslaLinkErrorView: View {
    let failure: TeslaLinkFailure
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 26)

            Text(failure.title)
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Color.mrtText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            Text(failure.message)
                .font(.system(size: 14.5))
                .lineSpacing(14.5 * 0.55)
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer(minLength: 0)

            MRTButton("Try again", variant: .outlineStatic, action: onRetry)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtTextMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.top, 196)
        .padding(.horizontal, MRTMetrics.onboardingGutter)
        .padding(.bottom, 38)
        .mrtFadeUp(duration: 0.4)
    }
}
