import Foundation
import MyRoboTaxiKit
import Observation
import OSLog

// MARK: - Push registration coordinator (MYR-186)
//
// The one object that sequences push: when to ask, what to do with a token, when
// to re-send it, and when to tell the server to forget it. Every OS dependency is
// injected (`PushAuthorizing`), as is the network (`PushDeviceEndpoint`, the Kit
// seam) and the persistence (`PushRegistrationStore`), so all of the sequencing
// below is exercised by unit tests with no simulator and no APNs.
//
// TWO INVARIANTS RUN THROUGH THE WHOLE FILE:
//
//  1. PUSH NEVER BLOCKS THE UI. Nothing here is awaited by a screen, nothing
//     surfaces an error banner, and every failure path degrades to "try again
//     next foreground". A device that never manages to register still receives
//     every ride update over the existing telemetry socket — push is an
//     enhancement to that, not a dependency of it.
//
//  2. SIMULATED MODE IS UNTOUCHED. With `isLive == false` the coordinator is
//     inert: it never prompts, never registers, never calls the network. The
//     fixture demo and every DEBUG capture scene behave exactly as they did
//     before this issue (CLAUDE.md's pixel-identical rule).

@MainActor
@Observable
final class PushRegistrationCoordinator {

    /// `nil` on the simulated path — the composition hands over no endpoint, and
    /// every network step below no-ops. Kept as the Kit's own protocol rather
    /// than a local adapter so there is exactly one description of the contract.
    private let endpoint: (any PushDeviceEndpoint)?
    private let authorizer: any PushAuthorizing
    private let store: any PushRegistrationStore
    /// The ONE resolved app mode (`AppMode.live != nil`), threaded from
    /// `RootView.init` like every other live/sim decision.
    private let isLive: Bool
    /// The APNs environment this build is signed into — see `PushEnvironment`.
    private let sandbox: Bool
    /// `CFBundleVersion`, injected so a test can simulate an app upgrade.
    private let build: String

    private let log = Logger(subsystem: "app.myrobotaxi.ios", category: "push")

    /// The most recent authorization state the coordinator observed. Read by
    /// Settings to decide whether to offer the "open Settings" affordance.
    private(set) var authorizationState: PushAuthorizationState = .notDetermined

    init(
        endpoint: (any PushDeviceEndpoint)?,
        authorizer: any PushAuthorizing = SystemPushAuthorizer(),
        store: any PushRegistrationStore = UserDefaultsPushRegistrationStore(),
        isLive: Bool,
        sandbox: Bool = PushEnvironment.isSandbox,
        build: String = PushAppBuild.current
    ) {
        self.endpoint = endpoint
        self.authorizer = authorizer
        self.store = store
        self.isLive = isLive
        self.sandbox = sandbox
        self.build = build
    }

    // MARK: - The permission moment

    /// A meaningful moment happened. Resolve it through
    /// `PushPermissionMoment` and, if it is the moment, ask.
    ///
    /// Safe to call on every occurrence of the moment (every arrival on the owner
    /// home map, every ride submit) — the one-shot gate makes repeats free.
    func handleMeaningfulMoment(_ trigger: PushPermissionTrigger, role: UserRole) async {
        let decision = PushPermissionMoment.decide(
            role: role,
            isLive: isLive,
            trigger: trigger,
            hasAsked: store.hasAskedForAuthorization()
        )
        guard decision == .ask else { return }

        // Record the ask BEFORE presenting. iOS shows the system alert exactly
        // once per install whatever the app believes, so a crash or a kill during
        // the prompt must not leave the gate open — a second "ask" would be a
        // silent no-op that then skipped registration.
        store.setHasAskedForAuthorization(true)

        let granted = await authorizer.requestAuthorization()
        authorizationState = granted ? .authorized : .denied
        log.info("push authorization prompt answered: granted=\(granted, privacy: .public)")
        guard granted else { return }
        authorizer.registerForRemoteNotifications()
    }

    // MARK: - Launch + foreground

    /// Called once per launch (and on every foreground). Two jobs:
    ///
    ///  • If the user has ALREADY authorized, re-arm APNs. `registerForRemote
    ///    Notifications()` is how the app learns its current token, and the token
    ///    can change out from under it — restore from backup, reinstall, some OS
    ///    upgrades. Re-registering every launch is Apple's documented guidance and
    ///    is what makes rotation a non-event.
    ///  • Retry a `PUT` that failed earlier (`pendingToken`). This is the whole
    ///    retry policy: no timers, no backoff loop, no queue depth — just "next
    ///    time the app is in front of the user, try once more".
    func handleForeground() async {
        guard isLive else { return }
        authorizationState = await authorizer.authorizationState()
        guard authorizationState == .authorized else { return }
        authorizer.registerForRemoteNotifications()
        await retryPendingRegistration()
    }

    // MARK: - Token delivery

    /// APNs handed the app a token (`didRegisterForRemoteNotificationsWithDevice
    /// Token`). Hex-encode it and send it up if the server does not already know
    /// this exact (token, build) pair.
    func handleDeviceToken(_ tokenData: Data) async {
        let token = PushDeviceToken.hex(from: tokenData)
        guard !token.isEmpty else { return }
        guard isLive, let endpoint else { return }

        // Skip the network only when the server has confirmed THIS token from
        // THIS build. A rotated token obviously re-registers; so does the same
        // token after an app upgrade, because an upgrade is the other documented
        // way a registration can go stale server-side and it costs one idempotent
        // call to be sure.
        if let confirmed = store.confirmedRegistration(),
           confirmed.token == token,
           confirmed.build == build,
           store.pendingToken() == nil {
            return
        }

        store.setPendingToken(token)
        await send(token: token, using: endpoint)
    }

    /// APNs refused to issue a token. Nothing to retry against — there is no
    /// token — so this is recorded and dropped. `handleForeground` will ask again
    /// next time the app comes forward.
    func handleRegistrationFailure(_ error: any Error) {
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Sign-out

    /// Tell the backend to forget this device, so the next account signed in on
    /// this phone does not inherit the previous one's ride alerts.
    ///
    /// Best-effort and NON-BLOCKING by contract: the caller (`RootView`'s
    /// sign-out closures) must not await this, and a failure must not delay or
    /// fail the sign-out. Local state is cleared either way — a device that
    /// cannot reach the server is still, as far as this install is concerned,
    /// unregistered, and leaving a stale "confirmed" record behind would suppress
    /// the re-registration the next sign-in needs.
    ///
    /// `hasAskedForAuthorization` is deliberately NOT cleared: system
    /// authorization is per-install, not per-account, so re-prompting after a
    /// sign-out would be a silent OS no-op that merely re-opened the app's gate.
    func handleSignOut() {
        let token = store.confirmedRegistration()?.token ?? store.pendingToken()
        store.setConfirmedRegistration(nil)
        store.setPendingToken(nil)

        guard isLive, let endpoint, let token, !token.isEmpty else { return }
        let sandbox = self.sandbox
        let log = self.log
        Task.detached {
            do {
                try await endpoint.unregisterPushDevice(token: token, sandbox: sandbox)
            } catch {
                // Nothing to do and nothing to tell the user: the account is
                // already signed out locally, and the server drops unknown
                // tokens on its own once APNs reports them unregistered.
                log.notice("push unregister failed on sign-out: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Registration transport

    private func retryPendingRegistration() async {
        guard let endpoint, let token = store.pendingToken(), !token.isEmpty else { return }
        await send(token: token, using: endpoint)
    }

    private func send(token: String, using endpoint: any PushDeviceEndpoint) async {
        do {
            try await endpoint.registerPushDevice(token: token, sandbox: sandbox)
            store.setConfirmedRegistration(PushConfirmedRegistration(token: token, build: build))
            store.setPendingToken(nil)
            log.info("push device registered (sandbox=\(self.sandbox, privacy: .public))")
        } catch {
            // The token stays pending and `handleForeground` retries it. No
            // backoff loop, no user-visible failure — see the file header.
            log.notice("push device registration failed, will retry next foreground: \(error.localizedDescription, privacy: .public)")
        }
    }
}
