import SwiftUI
import DesignSystem
import MyRoboTaxiKit

// MARK: - Routing shell (MYR-164)
//
// Deliberately tiny. Adding a screen = add an `AppScreen` case + a `switch`
// arm in `RootView`. Screens never see the router — they get callbacks —
// so later issues (home map, drives, settings, …) extend this without
// rewiring existing screens.

/// Top-level screens. Mirrors the prototype's `screen` state
/// (design/app/app.jsx `aS('…')`), one case per ported screen.
enum AppScreen: Hashable {
    /// MYR-221 — brief launch splash while a stored session is silently resumed
    /// (returning user). Resolves to `.ownerHome` on success or `.signIn` on
    /// failure/no-session. Never shown in the simulator (no stored session).
    case resolvingSession
    case signIn
    /// MYR-224 — owner/rider view chooser, shown once on the live signed-in path
    /// when no view mode is stored yet. Never shown in SIM (which keeps the
    /// existing onboarding role selection) or once a choice is persisted.
    case modeChooser
    /// First-run choice screen (app.jsx 'empty') — Add your Tesla vs Join
    /// with an invite code.
    case emptyState
    /// Owner pairing flow (app.jsx 'addTesla').
    case addTesla
    /// Rider join flow (app.jsx 'inviteCode').
    case inviteCode
    /// Post-pairing walkthrough (tutorials.jsx OwnerTutorial), 5 cards.
    case ownerTutorial
    /// Post-join walkthrough (tutorials.jsx RiderTutorial), 5 cards.
    case riderTutorial
    /// Owner Live Map + tab shell (MYR-167 — screens.jsx `HomeScreen`; Drives
    /// shipped in MYR-169, Share/Settings shipped in MYR-170).
    case ownerHome
    /// Rider tab shell (MYR-170/191 — screens.jsx `SHARED_TABS`). Settings
    /// ships in MYR-170 (`SharedSettingsScreen`); Live Map/Ride History
    /// remain placeholders until MYR-191.
    case sharedHome
}

/// Persona — the prototype's Owner / Shared flow switch
/// (design/app/app.jsx `role`). Sign-in is shared; everything after it
/// branches on this.
enum UserRole: String {
    case owner
    case shared
}

/// Where the "Enter invite code" flow was launched from (app.jsx
/// `inviteFrom`, MYR-170) — decides both the `returning` variant and where
/// `onComplete`/`onCancel` route back to.
enum InviteOrigin {
    /// From the first-run `EmptyScreen` choice — completes into RiderTutorial.
    case onboarding
    /// From `SharedSettingsScreen`'s "Enter invite code" row — returning,
    /// skips the tutorial and returns straight to Settings.
    case sharedSettings
    /// MYR-346 — from a `https://myrobotaxi.app/join/{CODE}` universal link
    /// tapped while the app was already past onboarding. Completing lands on the
    /// rider Live Map (the car they just joined is there); cancelling restores
    /// the exact shell the link interrupted, via ``InviteLinkReturn``.
    ///
    /// A link that arrives on the FIRST-RUN choice screen is `.onboarding`
    /// instead, not this — that rider has no shell to go back to and does want
    /// the tutorial. See `RootView.presentInviteLink`.
    case deepLink
}

/// MYR-346 — where a join link interrupted the user, so Cancel puts them back
/// exactly where they were rather than somewhere merely plausible. Four fields
/// because the shell is four fields; `applyViewMode` would reset the tabs.
private struct InviteLinkReturn: Equatable {
    var role: UserRole
    var screen: AppScreen
    var ownerTab: String
    var sharedTab: String
}

struct RootView: View {
    // MYR-201 — forward app foreground/background to the owner fleet so the
    // live `TelemetrySocket` reconnects on resume and settles on suspend via the
    // Kit's transition hooks (no-op for the simulated fleet).
    @Environment(\.scenePhase) private var scenePhase
    // MYR-164 — the sign-in session: SimulatedAuthSession in sim/RELEASE, the real
    // LiveAuthSession (Sign in with Apple → backend session) for a live launch
    // with no static token. Chosen in `init` via `AuthComposition`, which also
    // yields the shared `SessionTokenProvider` threaded into the live fleet below.
    @State private var session: any AuthSession
    @State private var screen: AppScreen = .signIn
    @State private var role: UserRole = .owner
    // MYR-224 — per-user owner/rider view-mode choice. A value-type store over
    // UserDefaults; no @State needed (it holds no observable state itself).
    private let modeStore: any ModeChoiceStore = UserDefaultsModeChoiceStore()
    // Lifted above `.ownerHome`'s tab switch (app.jsx's `vehicleIdx`/`sheet`
    // are App-level state, not HomeScreen-local — screens.jsx:369) so the
    // selected vehicle, sheet detent, and each vehicle's ticking telemetry
    // survive switching to Drives/Share/Settings and back.
    // MYR-201 — the ONE telemetry composition point: simulated fixtures by
    // default (M1 offline demo), or the live Kit-backed fleet when the DEBUG
    // launch env selects it (`MRT_TELEMETRY=live`). No other site branches on
    // sim-vs-live.
    @State private var ownerHomeState: OwnerHomeState
    @State private var ownerTab = "home"
    /// MYR-301 — armed when a vehicle-command notice routes the owner to the
    /// Tesla re-link ("Reconnect Tesla for charging access" → the missing
    /// `vehicle_charging_cmds` scope). Settings consumes it by opening its
    /// EXISTING `AddTeslaFlow` on arrival (see `teslaRelinkRoute`).
    @State private var startTeslaLink = false
    /// MYR-228 — the ONE resolved live/sim flag, kept so `body` can seed the
    /// screen-local scheduled-ride list (`RideHistoryScreen`) empty in live mode.
    /// Every fixture-seeded state above/below is gated on this single decision.
    private let isLiveMode: Bool
    /// MYR-246 — the live in-app Tesla-link authenticator (ASWebAuthenticationSession
    /// against §7.11), or nil on the simulated path. Built once in `init` from the
    /// resolved mode + the sign-in session provider, mirroring the other seams.
    private let teslaAuthenticator: TeslaAuthenticator?
    /// MYR-258 — the live owner car-offboarding teardown call (§7.12), or nil on
    /// the simulated path. Built once in `init` from the resolved mode + session
    /// provider, mirroring `teslaAuthenticator`; combined with the fleet drop +
    /// consent-revoke runner into a `VehicleTeardownSeam` where `SettingsScreen` is
    /// built (needs the live `ownerHomeState` for the drop).
    private let vehicleTeardownRemover: ((String) async throws -> VehicleTeardownResponse)?
    /// MYR-186 — push registration + the permission moments. Always present; on
    /// the simulated path it is INERT (never prompts, never registers, never calls
    /// the network), so the fixture demo and every DEBUG capture scene are
    /// unchanged. Built in `init` from the resolved mode + session provider,
    /// mirroring `teslaAuthenticator` / `vehicleTeardownRemover`.
    @State private var pushCoordinator: PushRegistrationCoordinator
    /// MYR-349 — the ACCOUNT's per-category notification preferences (rest-api.md
    /// §7.19), read and written by BOTH Settings screens. Lifted here for the same
    /// reason every other account-scoped seam is: the owner and the rider shells
    /// are two views of one account, and a preference flipped in one must be the
    /// same value the other renders a moment later after a mode switch.
    ///
    /// Composed off the ONE resolved `AppMode` like `shareService`: the LIVE
    /// service on the live path, the simulated one (the prototype's positions,
    /// zero network) everywhere else — which is what leaves every DEBUG capture
    /// scene byte-identical.
    @State private var pushPrefsService: any PushPrefsService
    /// MYR-169 — mirrors `ownerHomeState`'s reasoning: app.jsx keeps
    /// `ownerUpcoming` App-level, not local to `DrivesScreen`, so a
    /// cancelled reservation and an open drive summary both survive
    /// switching to another tab and back. MYR-228 — seeded empty in live mode
    /// (no reservation backend); see `OwnerDrivesState`'s header comment.
    @State private var ownerDrivesState: OwnerDrivesState
    /// MYR-170 — shared between `InvitesScreen` and `SettingsScreen`; see
    /// `ShareService`'s header comment for why this is lifted+shared rather than
    /// forking the prototype's two independent copies. MYR-184 — it is now the
    /// `any ShareService` seam: `SimulatedShareService` (fixtures, offline demo,
    /// every DEBUG scene) or `LiveShareService` against rest-api.md §7.5, chosen
    /// at the ONE composition point off the ONE resolved `AppMode`. This
    /// supersedes MYR-228's "seed it empty on live" stopgap — the sharing backend
    /// exists now, so the live screen shows the owner's REAL grants.
    @State private var shareService: any ShareService
    /// MYR-184 — the RIDER's half of sharing: which vehicles are shared with this
    /// account, on what tier, plus the §7.5.5 redeem call `InviteCodeFlow` runs.
    /// Deliberately a separate seam from `shareService` (see
    /// `SharedVehicleCatalog`'s header). Lifted here for the same reason every
    /// other role-scoped state is: the catalog a rider seeds by redeeming a code
    /// must still be there when they land on the Live Map a moment later.
    @State private var sharedVehicleCatalog: any SharedVehicleCatalog
    /// MYR-170 — Settings' linked-vehicle list + primary designation; see
    /// `OwnerVehiclesState`'s header comment for its scope boundary vs.
    /// `OwnerHomeState`. MYR-228 — seeded empty in live mode (not wired to the
    /// live fleet; no set-primary/unlink backend).
    @State private var ownerVehiclesState: OwnerVehiclesState
    @State private var sharedTab = "shared"
    @State private var inviteOrigin: InviteOrigin = .onboarding
    /// MYR-346 — a code from a `/join/{CODE}` universal link that has NOT been
    /// presented yet, because the app was still on the sign-in screen or the
    /// user was mid-something. Held, not dropped: nothing else in the system
    /// will ever produce these six characters again. Re-asked on every shell
    /// change (`.onChange(of: inviteLinkContext)`), so it lands the moment the
    /// moment is right.
    @State private var pendingInviteCode: String?
    /// MYR-346 — the code `InviteCodeFlow` is currently prefilled with, or `nil`
    /// when the screen was reached by a tap. Its ONLY consumer is that screen's
    /// `prefilledCode`.
    @State private var inviteLinkCode: String?
    /// MYR-346 — the shell a join link interrupted, restored on Cancel.
    @State private var inviteLinkReturn: InviteLinkReturn?
    /// MYR-191 — mirrors `ownerHomeState`'s reasoning: lifted above the
    /// `sharedTab` switch so the rider's watched vehicle keeps ticking
    /// telemetry across Ride History/Settings and back to Live Map.
    @State private var sharedViewerState = SharedViewerState()
    /// MYR-171 — the M1↔M2 ride-request seam (`RideRequestService`'s header
    /// comment). Lifted here, alongside every other role-scoped state above,
    /// so the SAME instance is visible from both `SharedViewerScreen` (rider)
    /// and `HomeScreen` (owner) — the mechanism that lets one request bridge
    /// across a role switch within a single app session. MYR-209 — now the
    /// `any RideRequestService` seam: `SimulatedRideRequestService` by default
    /// (M1 offline demo, and every DEBUG scene, which are sim-only), or
    /// `LiveRideRequestService` when the launch env selects live
    /// (`MRT_TELEMETRY=live`) via `RideRequestComposition`.
    @State private var rideRequestService: any RideRequestService = SimulatedRideRequestService()
    /// MYR-171 — see `RideHistoryStore`'s header comment: lifted the same way
    /// so a ride that finishes while the rider is on Live Map still lands in
    /// Ride History. MYR-228 — seeded empty in live mode (no ride-history
    /// backend); a ride the rider completes THIS session still appends.
    @State private var rideHistoryStore: RideHistoryStore
    /// MYR-204 — one session-lived place labeler (saved-place → POI/locality →
    /// address) for the owner Drive Summary header. Holds the per-drive label
    /// cache; sim summaries never invoke it (they keep their fixture labels).
    /// MYR-214 — seeded with an EMPTY saved-place list in live mode: the
    /// saved-place proximity layer must not label a live drive endpoint that
    /// happens to sit near an SF fixture coordinate "Home"/"Work" (same
    /// poisoning class as the live search). Sim keeps the fixtures (composed
    /// in `init`). Real saved places arrive with accounts (MYR-193).
    @State private var placeLabeler: PlaceLabeler

    // MYR-200 — seed the debug scene (if any) in `init` so the very first
    // render already shows the requested phase. Applying it later (onAppear/
    // task) proved unreliable at the WindowGroup root and left a Sign-In
    // flash. See `DebugScenes.swift`. Release builds compile only the plain
    // default initializers below.
    @MainActor
    init() {
        // MYR-221 — resolve the ONE launch mode first: `.simulated` (simulator,
        // env-driven) or `.live` (device default, or `MRT_TELEMETRY=live` in the
        // sim). Every composition below reads this single decision instead of each
        // re-reading `MRT_TELEMETRY`.
        let mode = AppMode.resolve()
        // MYR-228 — the ONE live/sim flag every fixture-seeded state gates on.
        // Live surfaces without a ready backend must render an honest empty state,
        // never fixture data (see each state's `live:` init + CLAUDE.md's rule).
        let isLive = mode.live != nil
        isLiveMode = isLive
        _ownerDrivesState = State(initialValue: OwnerDrivesState(live: isLive))
        _ownerVehiclesState = State(initialValue: OwnerVehiclesState(live: isLive))
        _rideHistoryStore = State(initialValue: RideHistoryStore(
            seed: isLive ? [] : RideHistoryFixtures.requestedRides
        ))
        // MYR-221 — a returning user with a stored refresh token skips SignInScreen:
        // start on the resolving splash and silently refresh in `.task` below.
        var startScreen: AppScreen = .signIn
        var startRole: UserRole = .owner
        var startSharedTab = "shared"
        var startOwnerTab = "home"
        // MYR-164 — pick the sign-in session and (in live mode, no static token)
        // the shared backend `SessionTokenProvider`. Threaded into the fleet +
        // ride-request compositions so one session authenticates everything.
        let auth = AuthComposition.make(mode: mode)
        if auth.hasStoredSession { startScreen = .resolvingSession }
        _session = State(initialValue: auth.session)
        let homeState = TelemetryComposition.makeOwnerHomeState(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        )
        _ownerHomeState = State(initialValue: homeState)
        // MYR-184 — both halves of sharing, composed off the same resolved mode +
        // session as everything else. The owner service reads its shareable-vehicle
        // list from the SAME started fleet the Home map uses (a closure, so it
        // follows the fleet as it loads / a car is torn down) — that is MYR-228 fix
        // (a): the send-invite sheet's picker no longer offers fixture cars.
        var share: any ShareService = ShareComposition.makeShareService(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider,
            ownedVehicles: { [weak homeState] in homeState?.vehicles ?? [] }
        )
        var catalog: any SharedVehicleCatalog = ShareComposition.makeSharedVehicleCatalog(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        )
        #if DEBUG
        // MYR-184 — the five sharing capture scenes swap in the PRODUCTION live
        // services driven by `DebugShareEndpoint`. Every other scene leaves both
        // seams exactly as composed, so the whole drift gate is untouched.
        if let scene = DebugScene.current {
            if let override = scene.shareServiceOverride { share = override }
            if let override = scene.sharedCatalogOverride { catalog = override }
        }
        #endif
        _shareService = State(initialValue: share)
        _sharedVehicleCatalog = State(initialValue: catalog)
        // MYR-246 — live Tesla-link authenticator (nil in sim / static-token dev).
        teslaAuthenticator = TeslaLinkComposition.makeAuthenticator(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        )
        // MYR-258 — live car-offboarding teardown call (nil in sim / static-token dev).
        vehicleTeardownRemover = VehicleTeardownComposition.makeRemover(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        )
        // MYR-360 — the reservation seam behind the owner's ride-share pause
        // warning: the owner's upcoming ACCEPTED reservations for one vehicle, plus
        // the decline that withdraws one. `nil` in sim / static-token dev, where the
        // toggle itself does not render.
        //
        // The two `ownerRideSharePauseWarning` capture scenes override it with the
        // SAME production `LiveUpcomingReservations` over a scripted endpoint, so
        // the dialog in the capture was built from a real fetch through the real
        // contract mapping. Nothing else reads the override, so every existing
        // scene — including MYR-342's three — is byte-identical.
        var reservations = RideRequestComposition.makeUpcomingReservations(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        ) as (any UpcomingReservationSource)?
        #if DEBUG
        if let scripted = DebugScene.current?.upcomingReservationSource { reservations = scripted }
        #endif
        upcomingReservations = reservations
        // MYR-186 — push device registration, bound to the same session.
        _pushCoordinator = State(initialValue: PushComposition.makeCoordinator(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        ))
        // MYR-349 — the account's notification preferences (§7.19), bound to the
        // same session. Simulated off the live path, so no DEBUG scene reaches the
        // network and the Settings captures are unchanged.
        _pushPrefsService = State(initialValue: PushPrefsComposition.makeService(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        ))
        // MYR-211 — compose the rider's place-search + location seams (sim
        // fixtures by default; live MapKit/CoreLocation on device / when live).
        let seams = PlaceSearchComposition.make(mode: mode, sessionTokenProvider: auth.sessionTokenProvider)
        // MYR-184/228 fix (c) — the rider's watched vehicle is seeded from the
        // FIXTURES in sim and from NOTHING on live: the real one is adopted from
        // the shared-vehicle catalog (`.onChange`/`.task` in `body`). Passing the
        // fixture here regardless is what made a live rider with zero shares
        // watch "Cybercab".
        let viewer = SharedViewerState(
            vehicle: seams.isLive ? nil : VehicleFixtures.vehicles[0],
            seams: seams,
            recentDestinationsStore: Self.recentDestinationsStore()
        )
        // MYR-214 — the Drive Summary place labeler drops the fixture saved
        // places in live mode (see the `placeLabeler` property comment): a live
        // endpoint near the SF fixture coords must not be labeled "Home".
        _placeLabeler = State(initialValue: PlaceLabeler(
            savedPlaces: seams.isLive ? [] : RideRequestFixtures.savedPlaces
        ))
        // Default to the composed service (sim, or live when the launch env
        // selects it). A DEBUG scene overrides with a concrete simulated service
        // it can `debugSeed` — UNLESS the env composed the live service: the
        // documented live launch recipe combines a scene (ownerHome/ownerDrives,
        // pure navigation) with MRT_TELEMETRY=live, and replacing the live
        // service there silently reverted ride requests to fixtures while the
        // fleet stayed live (found in the MYR-209 live audit). Seeded ride-flow
        // scenes remain sim-only: in live mode the scene still routes and seeds
        // the viewer, but its fixture ride record goes to a throwaway service.
        var service: any RideRequestService = RideRequestComposition.makeService(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        )
        #if DEBUG
        if let scene = DebugScene.current {
            if service is SimulatedRideRequestService {
                let simulated = SimulatedRideRequestService()
                scene.apply(viewer: viewer, service: simulated)
                service = simulated
            } else {
                scene.apply(viewer: viewer, service: SimulatedRideRequestService())
            }
            startScreen = DebugScene.initialScreen
            startRole = DebugScene.initialRole
            startSharedTab = DebugScene.initialSharedTab
            startOwnerTab = DebugScene.initialOwnerTab
        }
        // MYR-346 — a simulated incoming universal link, orthogonal to the scene
        // (it works with no scene at all). Posted to the mailbox HERE, from
        // `init`, so it lands in the same before-the-view-exists window a real
        // cold-launch activation does and is drained by the same `install`.
        if let url = DebugScene.incomingJoinLink {
            InviteLinkBridge.shared.receive(url)
        }
        #endif
        _sharedViewerState = State(initialValue: viewer)
        _rideRequestService = State(initialValue: service)
        _screen = State(initialValue: startScreen)
        _role = State(initialValue: startRole)
        _sharedTab = State(initialValue: startSharedTab)
        _ownerTab = State(initialValue: startOwnerTab)
    }

    /// MYR-356 — where the rider's recent destinations come from.
    ///
    /// The shipping store is `UserDefaults`. A DEBUG SCENE gets an in-memory one
    /// instead, and that is the whole reason the drift gate survives this feature:
    /// recents persist across launches, so a simulator someone had hand-driven the
    /// flow on would otherwise put real rows into `search`'s pre-typing region and
    /// silently drift a capture that has been byte-stable for a dozen issues. Every
    /// scene but `riderRecentDestinations` seeds EMPTY, which is exactly the
    /// pre-issue state.
    @MainActor
    private static func recentDestinationsStore() -> any RecentDestinationsStoring {
        #if DEBUG
        if let scene = DebugScene.current {
            return InMemoryRecentDestinationsStore(scene.seededRecentDestinations)
        }
        #endif
        return UserDefaultsRecentDestinationsStore()
    }

    // MARK: - Post-auth routing (MYR-224)

    /// After a real sign-in or silent resume, route by the account's stored view
    /// mode. No real account (SIM / static-token dev override) → the existing
    /// onboarding choice screen, unchanged. Real account with a stored mode →
    /// straight to that shell. Real account, no stored mode → the chooser.
    @MainActor
    private func routeAfterAuth() {
        let user = session.currentUser
        let stored = user.flatMap { modeStore.mode(forUserID: $0.id) }
        switch PostAuthRouter.destination(user: user, storedMode: stored) {
        case .onboarding: screen = .emptyState
        case .chooser: screen = .modeChooser
        case .shell(let mode): applyViewMode(mode)
        }
    }

    /// Apply a view-mode choice to the shell: pick the role, reset its landing
    /// tab, and route to that shell. Used by the chooser, the Settings switch
    /// row, and a stored-mode resume alike.
    @MainActor
    private func applyViewMode(_ mode: ViewMode) {
        switch mode {
        case .owner:
            role = .owner
            ownerTab = "home"
            screen = .ownerHome
        case .rider:
            role = .shared
            sharedTab = "shared"
            screen = .sharedHome
        }
    }

    /// Flip to the OTHER shell from a Settings "Switch mode" row, persisting the
    /// new choice. Only reachable on the live path (the row renders only when a
    /// real account is signed in).
    @MainActor
    private func switchViewMode() {
        guard let user = session.currentUser else { return }
        let next: ViewMode = (role == .owner ? ViewMode.owner : ViewMode.rider).toggled
        modeStore.setMode(next, forUserID: user.id)
        applyViewMode(next)
    }

    // MARK: - MYR-343 — the rider shell's vehicle set

    /// What the rider shell should present: the catalog's two partitions folded
    /// through the ONE pure rule (`RiderVehicleSet.resolve`). Computed rather than
    /// stored so it can never fall out of step with the catalog it reads, and so
    /// the `.onChange` below tracks the DECISION rather than one input to it.
    private var riderVehicleSet: RiderVehicleSet {
        RiderVehicleSet.resolve(
            hasLoaded: sharedVehicleCatalog.hasLoaded,
            loadFailed: sharedVehicleCatalog.loadFailed,
            grants: sharedVehicleCatalog.grants,
            ownedVehicles: sharedVehicleCatalog.ownedVehicles
        )
    }

    /// Push a resolved vehicle onto the viewer state. Only `.ridable` adopts
    /// anything: `.resolving` deliberately leaves the viewer alone (adopting `nil`
    /// mid-resolution would tear down a perfectly good telemetry source on every
    /// re-ask), and `.empty`/`.unavailable` are surfaces with no map behind them.
    @MainActor
    private func adoptRiderVehicle(_ resolution: RiderVehicleSet) {
        guard case .ridable(let adoption) = resolution else { return }
        sharedViewerState.adopt(adoption)
    }

    /// Clear the account's persisted view mode on sign-out — the choice is
    /// session-scoped (MYR-224 mode semantics: it does NOT survive sign-out, so
    /// the next sign-in re-presents the chooser). Read the id BEFORE `signOut`
    /// clears `currentUser`.
    @MainActor
    private func clearModeOnSignOut() {
        if let id = session.currentUser?.id {
            modeStore.clearMode(forUserID: id)
        }
    }

    /// The identity the chooser renders. The real signed-in user on the live
    /// path; a representative fixture ONLY for the DEBUG `modeChooser` capture
    /// scene (which runs in the simulator, where `currentUser` is nil).
    private var chooserProfile: UserProfile {
        if let user = session.currentUser { return user }
        #if DEBUG
        return DebugScene.sampleProfile
        #else
        return UserProfile(id: "unknown", name: nil, email: nil)
        #endif
    }

    /// MYR-184 — whether `InviteCodeFlow` should self-submit the sample code, so
    /// the two redeem capture scenes can reach their states headlessly. `false`
    /// in every normal launch and every other scene.
    private var autoSubmitsInviteCode: Bool {
        #if DEBUG
        return DebugScene.current?.autoSubmitsInviteCode == true
        #else
        return false
        #endif
    }

    /// MYR-312/313 — the live flag `HomeScreen` renders on: the ONE resolved app
    /// mode, or — only for specific DEBUG capture scenes — a forced `true`, for
    /// surfaces whose behaviour is LIVE-only by construction and therefore
    /// unreachable from a simulated capture:
    ///   • `ownerScheduledLive` (MYR-312/313) — the real requester name and the
    ///     scheduled accept-gate exemption;
    ///   • `ownerFreshnessStale` / `ownerFreshnessWaking` (MYR-315) — the freshness
    ///     stamp, which has no prototype counterpart and no honest simulated input.
    ///   • `ownerRideShareOn` / `ownerRideSharePaused` / `ownerRideSharePending`
    ///     (MYR-342) — the ride-sharing toggle, which is gated on the live path on
    ///     purpose: a switch that cannot reach §7.18 would appear to withdraw the
    ///     owner's car and do nothing.
    /// `false` everywhere else → the fixture persona and no stamp,
    /// pixel-identical (MYR-228).
    private var ownerHomeIsLive: Bool {
        #if DEBUG
        if DebugScene.current?.rendersLiveIncomingRequest == true { return true }
        if DebugScene.current?.rendersLiveVehicleFreshness == true { return true }
        if DebugScene.current?.rendersLiveRideShareToggle == true { return true }
        #endif
        return isLiveMode
    }

    /// MYR-360 — the reservation seam the owner's ride-share pause warning reads
    /// and declines through.
    ///
    /// The live composition, or — only for the two `ownerRideSharePauseWarning`
    /// capture scenes — the SAME production `LiveUpcomingReservations` over a
    /// scripted endpoint, so the reservations in the capture came through the real
    /// fetch and the real contract mapping rather than a hand-set array. `nil`
    /// everywhere else, including the MYR-342 ride-share scenes, which therefore
    /// stay byte-identical.
    private let upcomingReservations: (any UpcomingReservationSource)?

    /// MYR-326 — whether Settings' Tesla Account section reads the LIVE fleet
    /// (and so its loading branch) rather than the fixture `OwnerVehiclesState`
    /// list. The live path, plus the one `ownerSettingsLoading` capture scene:
    /// the `.connecting` state is live-only by construction, so it has no other
    /// route into a headless capture. `ownerSettings` stays on the fixture list
    /// and stays byte-identical (MYR-228 / CLAUDE.md drift gate).
    private var showsLinkedVehicles: Bool {
        #if DEBUG
        if DebugScene.current?.rendersLiveLinkedVehicles == true { return true }
        #endif
        return isLiveMode
    }

    /// The profile the Settings surfaces render as real identity. The live user,
    /// or — only for the DEBUG `ownerSettings`/`riderSettings` capture scenes —
    /// the sample profile, so the real-identity Profile section + "Switch mode"
    /// row are captureable in the simulator. `nil` everywhere else → the fixture
    /// persona (pixel-identical sim).
    private var settingsLiveProfile: UserProfile? {
        if let user = session.currentUser { return user }
        #if DEBUG
        if DebugScene.current?.showsLiveSettings == true { return DebugScene.sampleProfile }
        #endif
        return nil
    }

    /// MYR-340 — the identity the SHARE MESSAGE names. The live user, or — only
    /// for the DEBUG `ownerShareLive` capture scene — the sample profile, so the
    /// named opening line is captureable in a simulator that cannot authenticate.
    /// Same stand-in-for-a-live-session precedent as `settingsLiveProfile`.
    /// `nil` everywhere else, which is exactly the state a live account carrying
    /// no name is in — the message falls back to first-person phrasing.
    private var shareLiveProfile: UserProfile? {
        if let user = session.currentUser { return user }
        #if DEBUG
        if DebugScene.current?.namesShareMessageOwner == true { return DebugScene.sampleProfile }
        #endif
        return nil
    }

    /// MYR-258 — the live owner car-offboarding seam for `SettingsScreen`, or nil
    /// (sim / static-token dev → the local unlink stays pixel-identical). Bundles
    /// the teardown `DELETE` (`vehicleTeardownRemover`), the fleet drop (so the car
    /// leaves Home + the Settings list the moment it's gone), and the consent-revoke
    /// browser runner. Built here (not in `init`) because the drop closure needs the
    /// live `ownerHomeState`.
    private var teardownSeam: VehicleTeardownSeam? {
        guard isLiveMode, let remove = vehicleTeardownRemover else { return nil }
        return VehicleTeardownSeam(
            remove: remove,
            onRemoved: { ownerHomeState.removeVehicle(id: $0) },
            revoke: VehicleTeardownComposition.makeRevoker()
        )
    }

    /// MYR-301 — where a "Reconnect Tesla" command notice sends the owner: the
    /// Settings tab, with the existing `AddTeslaFlow` armed. Screens report the
    /// intent; this view owns the navigation (same shape as `openDriveID`).
    private var teslaRelinkRoute: TeslaRelinkRoute {
        TeslaRelinkRoute(
            selectTab: { ownerTab = $0 },
            startLink: { startTeslaLink = true }
        )
    }

    // MARK: - Push (MYR-186)

    /// What the app is showing, reduced to the two facts the foreground
    /// banner-suppression decision needs. Read entirely from state that already
    /// exists — this adds no source of truth, and the ride id it reports is the
    /// SERVER's (`activeServerRideID`), because that is what a push carries.
    private var pushSurfaceContext: PushSurfaceContext {
        var ownerIncoming: String?
        var riderTracking: String?
        if role == .owner,
           screen == .ownerHome, ownerTab == "home",
           rideRequestService.incomingRequest != nil {
            // The incoming card renders on exactly this condition — see
            // `HomeScreen.incomingRequest`. MYR-325: both the condition and the id
            // come from the OWNER pipeline. They used to come from the shared slot,
            // which now names the RIDER's ride — suppressing on that id would hide
            // the banner for a request the owner cannot see, the very failure mode
            // `foregroundPresentation`'s ride-specific rule exists to prevent.
            ownerIncoming = rideRequestService.incomingServerRideID
        }
        if role == .shared,
           screen == .sharedHome, sharedTab == "shared",
           sharedViewerState.sheetPhase == .tracking {
            riderTracking = rideRequestService.activeServerRideID
        }
        return PushSurfaceContext(
            role: role,
            ownerIncomingRideID: ownerIncoming,
            riderTrackingRideID: riderTracking
        )
    }

    /// Apply a resolved notification tap. NO new navigation machinery: each arm
    /// selects an EXISTING tab on the shell the user is already in and pokes the
    /// EXISTING refresh that repopulates it — the owner's incoming queue, the
    /// rider's own open-ride adoption. A tap that arrives while signed out (or on
    /// an onboarding screen) routes nowhere; those surfaces do not exist yet, and
    /// the normal post-sign-in refetch reaches the same state anyway.
    @MainActor
    private func applyPushTapRoute(_ route: PushTapRoute, notification: PushRideNotification?) {
        let service = rideRequestService
        switch route {
        case .ownerHome:
            guard screen == .ownerHome else { return }
            ownerTab = "home"
            Task { await service.refreshIncoming() }
        case .riderActiveFlow:
            guard screen == .sharedHome else { return }
            sharedTab = "shared"
            Task { await service.refreshActiveRide() }
        }
    }

    /// Hand `RootView`'s state to the UIKit delegate (see `PushDelegateBridge`).
    /// Installed from `body` rather than `init` so the closures capture the live
    /// view value; idempotent, so a repeat appearance simply re-installs.
    @MainActor
    private func configurePushBridge() {
        PushDelegateBridge.shared.coordinator = pushCoordinator
        PushDelegateBridge.shared.surfaceContext = { pushSurfaceContext }
        PushDelegateBridge.shared.applyTapRoute = { route, notification in
            applyPushTapRoute(route, notification: notification)
        }
    }

    // MARK: - Universal links (MYR-346)

    /// What a `/join/{CODE}` link needs to know about the app right now.
    ///
    /// Both facts come from state that already exists. `isBusy` reads the SAME
    /// two places `pushSurfaceContext` does — the ride-request service's incoming
    /// slot for the owner, the rider sheet's phase for the rider — because those
    /// are the two things in this app that a screen swap would genuinely
    /// destroy: an Accept/Decline nobody has answered, and a ride request the
    /// rider has partly built.
    ///
    /// It does NOT try to detect an arbitrary presented `.sheet`. RootView
    /// cannot see one, and a link activation does not dismiss it — the sheet
    /// stays up over whatever we route to and the user closes it. The two cases
    /// above are the ones worth holding for; claiming to handle "any modal"
    /// would be claiming something this view has no way to know.
    private var inviteLinkContext: InviteLinkContext {
        InviteLinkContext(screen: screen, isBusy: isBusyWithARide)
    }

    /// Mid-ride, either side of it.
    private var isBusyWithARide: Bool {
        switch role {
        case .owner:
            // An incoming request is on the owner's card waiting for an answer.
            return rideRequestService.incomingRequest != nil
        case .shared:
            // The rider is anywhere past the idle sheet — searching, dropping a
            // pin, reviewing, booking, tracking, or reading the summary.
            return sharedViewerState.sheetPhase != .idle
        }
    }

    /// Hand this view's state to the universal-link mailbox. Installed from
    /// `body` for the same reason `configurePushBridge` is — the closure must
    /// capture the live view value — and idempotent for the same reason.
    ///
    /// `install` DRAINS anything the mailbox was holding, which is the cold-launch
    /// case: the system delivers the activity during launch, before this view
    /// exists, and the mailbox keeps it until this line runs.
    @MainActor
    private func configureInviteLinkBridge() {
        InviteLinkBridge.shared.install { url in
            receiveInviteLink(url)
        }
    }

    /// A universal link arrived. Resolve it once, then let ``drainPendingInviteLink``
    /// own everything after that.
    @MainActor
    private func receiveInviteLink(_ url: URL) {
        switch InviteLinkRouting.route(url: url, context: inviteLinkContext) {
        case .ignore:
            // Not a link we can spend. Open normally and say NOTHING — no error,
            // no toast. The web page behind this URL is what renders it.
            break
        case .presentPrefilledInvite(let code), .awaitSignIn(let code), .awaitIdle(let code):
            pendingInviteCode = code
            drainPendingInviteLink()
        }
    }

    /// Re-ask where the held code should go, and present it if the answer is
    /// now "here". Called when a link arrives and on every change to
    /// ``inviteLinkContext`` — which covers the sign-in landing, the tutorial
    /// finishing, and a ride being resolved, without any of those sites knowing
    /// a link is waiting.
    @MainActor
    private func drainPendingInviteLink() {
        guard let held = pendingInviteCode else { return }
        switch InviteLinkRouting.route(code: held, context: inviteLinkContext) {
        case .presentPrefilledInvite(let code):
            pendingInviteCode = nil
            presentInviteLink(code: code)
        case .awaitSignIn, .awaitIdle:
            // Keep holding. Every screen that defers resolves on its own, so
            // this terminates rather than waiting forever.
            break
        case .ignore:
            pendingInviteCode = nil
        }
    }

    /// Open `InviteCodeFlow` on a code that came from a link.
    ///
    /// The ORIGIN is chosen from where the user was, so the existing return
    /// semantics do the work: a rider sitting on the first-run choice screen is
    /// `.onboarding` (Continue → RiderTutorial, Cancel → back to the choice) —
    /// byte-identical to tapping "Join with an invite code" there, which is
    /// exactly what the link means at that moment. Anyone already in a shell is
    /// `.deepLink`, and their shell is remembered so Cancel restores it.
    @MainActor
    private func presentInviteLink(code: String) {
        if screen == .emptyState {
            inviteOrigin = .onboarding
            inviteLinkReturn = nil
        } else {
            inviteOrigin = .deepLink
            // Don't overwrite a snapshot taken by an earlier link — the shell we
            // want back is the one BEFORE any of this, not `.inviteCode`.
            if screen != .inviteCode {
                inviteLinkReturn = InviteLinkReturn(
                    role: role, screen: screen, ownerTab: ownerTab, sharedTab: sharedTab
                )
            }
        }
        inviteLinkCode = code
        screen = .inviteCode
    }

    /// Put the user back exactly where the link found them.
    @MainActor
    private func restoreAfterInviteLink() {
        guard let saved = inviteLinkReturn else {
            // No snapshot — the link was the first thing that happened. The
            // choice screen is the honest place to land.
            screen = .emptyState
            return
        }
        inviteLinkReturn = nil
        role = saved.role
        ownerTab = saved.ownerTab
        sharedTab = saved.sharedTab
        screen = saved.screen
    }

    /// MYR-186 — sign-out teardown shared by both shells: tell the backend to
    /// forget this device, so the next account on this phone does not inherit the
    /// previous one's ride alerts. Called BEFORE `session.signOut()` so the
    /// `DELETE` still carries a valid Bearer. Best-effort and non-blocking, like
    /// the token revoke it runs alongside (`LiveAuthSession.signOut`).
    @MainActor
    private func unregisterPushOnSignOut() {
        pushCoordinator.handleSignOut()
    }

    var body: some View {
        ZStack {
            switch screen {
            case .resolvingSession:
                // MYR-221 — calm brand splash while the stored session refreshes.
                ResolvingSessionView()
            case .signIn:
                SignInScreen(session: session) {
                    // MYR-224 — after a real sign-in, route by the account's stored
                    // view mode (chooser if none). SIM/static falls through to the
                    // existing onboarding choice screen (app.jsx 'empty').
                    routeAfterAuth()
                }
            case .modeChooser:
                // MYR-224 — the live chooser. `chooserProfile` resolves the real
                // signed-in identity (or a DEBUG fixture for the capture scene).
                ModeChooserScreen(profile: chooserProfile) { mode in
                    if let id = session.currentUser?.id {
                        modeStore.setMode(mode, forUserID: id)
                    }
                    applyViewMode(mode)
                }
            case .emptyState:
                // app.jsx:92 — the two self-describing paths.
                EmptyScreen(
                    onAdd: { screen = .addTesla },
                    onInvite: {
                        inviteOrigin = .onboarding
                        screen = .inviteCode
                    }
                )
            case .addTesla:
                // app.jsx:94 — onComplete → OwnerTutorial, onCancel → back to
                // the choice screen.
                AddTeslaFlow(
                    onComplete: {
                        role = .owner
                        screen = .ownerTutorial
                    },
                    onCancel: { screen = .emptyState },
                    // MYR-246 — live path wires the real authenticator; sim passes
                    // nil (keeps the simulated sheet pixel-identical). onLinked
                    // refreshes the owner fleet so newly linked vehicles surface.
                    authenticate: teslaAuthenticator,
                    onLinked: isLiveMode ? { ownerHomeState.startTelemetry() } : nil
                )
            case .inviteCode:
                // app.jsx:98-101 — onComplete/onCancel route on `inviteOrigin`
                // (MYR-170): from onboarding, into RiderTutorial / back to the
                // choice screen; from rider Settings ("returning"), skip the
                // tutorial entirely and land back on Settings.
                InviteCodeFlow(
                    onComplete: {
                        inviteLinkCode = nil
                        switch inviteOrigin {
                        case .onboarding:
                            role = .shared
                            screen = .riderTutorial
                        case .sharedSettings:
                            role = .shared
                            screen = .sharedHome
                            sharedTab = "sharedSettings"
                        case .deepLink:
                            // MYR-346 — they just joined a car; the car is on the
                            // rider Live Map. Not the tutorial (they are already
                            // past onboarding) and not back to where they came
                            // from (which may be the owner shell, where the car
                            // they just gained access to does not appear at all).
                            inviteLinkReturn = nil
                            role = .shared
                            sharedTab = "shared"
                            screen = .sharedHome
                        }
                    },
                    onCancel: {
                        inviteLinkCode = nil
                        switch inviteOrigin {
                        case .onboarding:
                            screen = .emptyState
                        case .sharedSettings:
                            screen = .sharedHome
                            sharedTab = "sharedSettings"
                        case .deepLink:
                            restoreAfterInviteLink()
                        }
                    },
                    returning: inviteOrigin != .onboarding,
                    // MYR-184 — the REAL §7.5.5 redeem call. Before this the
                    // `validate` seam was never passed at all, so its `{ _ in true }`
                    // default meant every six characters "joined" on the live path
                    // too, and the success screen then celebrated a fixture host.
                    redeem: { code in try await sharedVehicleCatalog.redeem(code: code) },
                    // MYR-184 — the two invite-code capture scenes submit the
                    // sample code on appear; headless tooling cannot type into
                    // the hidden six-cell field. Unset everywhere else.
                    autoSubmitsSampleCode: autoSubmitsInviteCode,
                    // MYR-346 — the code a `/join/{CODE}` link carried. Seats
                    // itself in the field and submits exactly as the 6th typed
                    // character does. `nil` on every tap-reached presentation,
                    // so this screen is unchanged for everyone else.
                    prefilledCode: inviteLinkCode
                )
            case .ownerTutorial:
                // tutorials.jsx:363 — onDone (Continue on the last card, or
                // Skip) → Live Map (MYR-167).
                OwnerTutorial(onDone: { screen = .ownerHome })
            case .riderTutorial:
                // tutorials.jsx:374 — onDone → Shared Live Map.
                RiderTutorial(onDone: {
                    sharedTab = "shared"
                    screen = .sharedHome
                })
            case .ownerHome:
                // app.jsx:110-115 — HomeScreen owns the "home" tab; Drives
                // (MYR-169), Share, and Settings (MYR-170) are the rest.
                switch ownerTab {
                case "drives":
                    // app.jsx:112-114 — `drives`/`driveSummary` are two
                    // distinct top-level `screen` values sharing the "drives"
                    // nav tab; this mirrors that with an in-tab push rather
                    // than a second `AppScreen` case (screens never see the
                    // router — DrivesScreen just reports which id opened).
                    if let openID = ownerDrivesState.openDriveID,
                       let drive = ownerHomeState.selectedDrivesFeed.drive(id: openID) {
                        // MYR-203 — resolve the opened drive from the fleet's
                        // drive feed (fixtures for sim, the live pages for live)
                        // rather than the fixture array directly.
                        DriveSummaryScreen(
                            drive: drive,
                            // MYR-204 — a live drive lazily fetches its §7.4 route
                            // polyline + resolves header place labels; a sim drive
                            // (non-empty baked `route`) ignores both, unchanged.
                            routeProvider: { id in
                                await ownerHomeState.selectedDrivesFeed.routeCoordinates(driveID: id)
                            },
                            placeLabeler: placeLabeler
                        ) {
                            ownerDrivesState.openDriveID = nil
                        }
                    } else {
                        // MYR-287 — `isLive` gates the header's lifetime-odometer
                        // figure (real snapshot odometer live, the prototype's
                        // 42,184 literal in SIM).
                        DrivesScreen(
                            homeState: ownerHomeState,
                            drivesState: ownerDrivesState,
                            ownerTab: $ownerTab,
                            isLive: isLiveMode
                        )
                    }
                case "invites":
                    // MYR-340 — the owner's identity reaches only the share
                    // message (nil in SIM → first-person phrasing; the tab
                    // itself renders nothing from it and stays byte-identical).
                    InvitesScreen(
                        shareService: shareService,
                        ownerTab: $ownerTab,
                        liveProfile: shareLiveProfile
                    )
                case "settings":
                    SettingsScreen(
                        shareService: shareService,
                        vehiclesState: ownerVehiclesState,
                        ownerTab: $ownerTab,
                        // MYR-224 — real profile (nil in SIM → fixture persona);
                        // the "Switch to Rider" row renders only when non-nil.
                        liveProfile: settingsLiveProfile,
                        onSwitchMode: switchViewMode,
                        // MYR-243 — on the LIVE path, read the Tesla Account
                        // section from the same started fleet Home uses (read-only
                        // real vehicles). `nil` in SIM / DEBUG keeps the fixture
                        // `OwnerVehiclesState` list pixel-identical (MYR-228).
                        linkedVehicles: showsLinkedVehicles ? ownerHomeState : nil,
                        onSignOut: {
                            // MYR-201 — release the live socket + streams before
                            // dropping the session (no-op for the simulated fleet).
                            clearModeOnSignOut()
                            // MYR-186 — before the session drops, so the DELETE
                            // still carries a valid Bearer.
                            unregisterPushOnSignOut()
                            ownerHomeState.stopTelemetry()
                            session.signOut()
                            screen = .signIn
                        },
                        // MYR-246 — Settings' "Add another Tesla" runs the real
                        // browser-sheet link flow on the live path (nil in SIM
                        // keeps the fixture sheet); refresh the fleet on link.
                        teslaAuthenticator: teslaAuthenticator,
                        onTeslaLinked: isLiveMode ? { ownerHomeState.startTelemetry() } : nil,
                        // MYR-301 — a command notice ("Reconnect Tesla for charging
                        // access") routes here with the flow armed, so the owner
                        // lands ON the link flow instead of hunting for it.
                        startTeslaLink: $startTeslaLink,
                        // MYR-258 — live "Remove this car" teardown (§7.12): the real
                        // DELETE + fleet drop (so the car leaves Home + this list at
                        // once) + consent-revoke browser session. nil in SIM keeps
                        // the local unlink pixel-identical (MYR-228).
                        teardown: teardownSeam,
                        // MYR-186 — drives the "notifications are off" notice
                        // under the toggles. `.notDetermined` in SIM → nothing.
                        pushAuthorization: pushCoordinator.authorizationState,
                        // MYR-349 — the toggles themselves. `LivePushPrefsService`
                        // against §7.19 on the live path; the simulated service
                        // (the prototype's own positions, zero network) otherwise,
                        // which is what keeps every DEBUG capture unchanged.
                        pushPrefs: pushPrefsService
                    )
                default:
                    HomeScreen(
                        homeState: ownerHomeState,
                        ownerTab: $ownerTab,
                        rideRequestService: rideRequestService,
                        drivesState: ownerDrivesState,
                        // MYR-301 — the vehicle-controls command notices route
                        // their fix here (Settings + the link flow armed).
                        onRelinkTesla: { teslaRelinkRoute() },
                        // MYR-264 — the ONE resolved live flag gates the incoming
                        // request sheet's rider/vehicle identity + the media block
                        // (fixtures render only in SIM / DEBUG scenes). MYR-315 —
                        // it also gates the freshness stamp, which the prototype
                        // has no counterpart for.
                        isLive: ownerHomeIsLive,
                        // MYR-360 — the reservation seam behind the ride-share
                        // pause warning. `nil` off the live path (and in the
                        // MYR-342 capture scenes), where the pause commits exactly
                        // as it did before this issue.
                        upcomingReservations: upcomingReservations
                    )
                    // MYR-186 — the OWNER's permission moment: arrival on the live
                    // home map. Deliberately keyed off the coordinator's own
                    // liveness (the resolved `AppMode`), NOT `ownerHomeIsLive`,
                    // which some DEBUG capture scenes force true — a drift-gate
                    // screenshot must never grow a permission alert.
                    .task {
                        await pushCoordinator.handleMeaningfulMoment(
                            .ownerLiveHomeAppeared,
                            role: role
                        )
                    }
                }
            case .sharedHome:
                // app.jsx:110-115 — SharedSettingsScreen owns the
                // "sharedSettings" tab (MYR-170); Live Map (MYR-191
                // `SharedViewerScreen`) and Ride History (MYR-191
                // `RideHistoryScreen`) round out the rider shell.
                switch sharedTab {
                case "sharedSettings":
                    SharedSettingsScreen(
                        sharedTab: $sharedTab,
                        // MYR-224 — real profile (nil in SIM → fixture persona);
                        // the "Switch to Owner" row renders only when non-nil.
                        liveProfile: settingsLiveProfile,
                        // MYR-184 — "Shared with me" now reads the REAL catalog
                        // (`role: viewer` rows off §7.0). This supersedes MYR-255's
                        // "live shows an honest empty state because there is no
                        // endpoint": there is one now. Sim keeps the three fixture
                        // personas, pixel-identical.
                        catalog: sharedVehicleCatalog,
                        // MYR-186 — see the owner Settings call above.
                        pushAuthorization: pushCoordinator.authorizationState,
                        // MYR-349 — see the owner Settings call above. BOTH rider
                        // rows read the one `rideLifecycle` category.
                        pushPrefs: pushPrefsService,
                        onSwitchMode: switchViewMode,
                        onAddCode: {
                            inviteOrigin = .sharedSettings
                            screen = .inviteCode
                        },
                        onSignOut: {
                            clearModeOnSignOut()
                            // MYR-186 — same ordering as the owner shell above.
                            unregisterPushOnSignOut()
                            session.signOut()
                            screen = .signIn
                        }
                    )
                case "rideHistory":
                    // app.jsx:127-129 `screen==='rideSummary'` — an in-tab
                    // push mirroring `.ownerHome`'s `drives`/`driveSummary`
                    // handling above (MYR-169): `RideHistoryScreen` reports
                    // which completed ride opened via `RideHistoryStore
                    // .openRideID` (MYR-197) rather than a second `AppScreen`
                    // case, reusing the SAME `DriveSummaryScreen` the owner's
                    // `DrivesScreen` pushes (`RequestedRide.asDrive` adapts
                    // the shape).
                    if let openID = rideHistoryStore.openRideID,
                       let ride = rideHistoryStore.completedRides.first(where: { $0.id == openID }) {
                        DriveSummaryScreen(drive: ride.asDrive) {
                            rideHistoryStore.openRideID = nil
                        }
                    } else {
                        // MYR-228 — scheduled rides are screen-local @State; seed
                        // them empty in live mode (no scheduled-ride backend) so the
                        // Scheduled tab shows its honest "No scheduled rides" state,
                        // never the fixture reservations.
                        RideHistoryScreen(sharedTab: $sharedTab, historyStore: rideHistoryStore, isLive: isLiveMode)
                    }
                default:
                    // MYR-184 — a rider with NOTHING shared with them has no map
                    // to show. Before that issue the screen rendered anyway, on
                    // `VehicleFixtures.vehicles[0]` (MYR-228 fix (c)).
                    //
                    // MYR-343 — but "nothing shared" was the WRONG question, and
                    // asking it behind a two-way boolean produced the client's two
                    // defects at once: an OWNER in rider mode (zero viewer rows,
                    // one owned car) was routed to the invite-code prompt, and the
                    // not-yet-loaded case fell through to the rider home first, so
                    // he SAW that home for a frame before the swap. The shell now
                    // switches on the whole vehicle-set resolution and presents
                    // nothing until it resolves. See `RiderVehicleSet`.
                    //
                    // The simulated catalog reports loaded-with-grants from the
                    // first frame and owns nothing, so it resolves to `.ridable`
                    // on the same grant it always did — every DEBUG rider scene is
                    // byte-identical.
                    switch riderVehicleSet {
                    case .resolving:
                        RiderVehiclesLoadingSkeleton(sharedTab: $sharedTab)
                    case .unavailable:
                        SharedVehiclesUnreachableScreen(sharedTab: $sharedTab)
                    case .empty:
                        SharedNoVehiclesScreen(sharedTab: $sharedTab) {
                            inviteOrigin = .sharedSettings
                            screen = .inviteCode
                        }
                    case .ridable:
                        SharedViewerScreen(
                            viewerState: sharedViewerState,
                            sharedTab: $sharedTab,
                            rideRequestService: rideRequestService,
                            historyStore: rideHistoryStore,
                            // MYR-224 — real rider identity for the greeting + summary
                            // (nil in SIM → the fixture "Sam", pixel-identical).
                            liveProfile: session.currentUser,
                            // MYR-186 — the RIDER's permission moment: their request
                            // just submitted, and the owner's answer is now the only
                            // thing they are waiting on.
                            onRideRequestSubmitted: {
                                Task {
                                    await pushCoordinator.handleMeaningfulMoment(
                                        .riderRideRequestSubmitted,
                                        role: role
                                    )
                                }
                            }
                        )
                    }
                }
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
        // MYR-186 — hand this view's state to the UIKit push delegate.
        .onAppear { configurePushBridge() }
        // MYR-346 — same hand-off for universal links, and the drain of anything
        // the mailbox held through a cold launch.
        .onAppear { configureInviteLinkBridge() }
        // MYR-346 — the SwiftUI delivery path for `applinks:myrobotaxi.app`. The
        // app-delegate path (`PushAppDelegate.application(_:continue:_:)`) feeds
        // the same mailbox; whichever one iOS uses, the code arrives once and
        // re-delivery is a no-op. See `InviteLinkBridge`'s header.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            InviteLinkBridge.shared.receive(url)
        }
        // MYR-346 — re-ask where a HELD code should go whenever the shell moves.
        // This is the whole deferral mechanism: sign-in landing, a tutorial
        // finishing, an incoming request being answered, a ride reaching its
        // summary — none of those sites know a link is waiting, and none of them
        // need to.
        .onChange(of: inviteLinkContext) { _, _ in drainPendingInviteLink() }
        // MYR-184 — keep the rider's watched vehicle in step with the catalog.
        // MYR-343 — off the whole RESOLUTION, not off `grants` alone: the vehicle
        // the map watches is the owner's own car when they have one, and a change
        // in the owned partition has to reach the map exactly as a change in the
        // shared one does. Runs on every catalog change, so redeeming a code still
        // lands a real car on the map without a relaunch.
        .onChange(of: riderVehicleSet) { _, resolution in
            adoptRiderVehicle(resolution)
        }
        // MYR-184 — load the rider's shared vehicles when the rider shell is on
        // screen. No-op in sim; idempotent, so the tab churn costs nothing.
        .task(id: screen == .sharedHome) {
            guard screen == .sharedHome else { return }
            await sharedVehicleCatalog.load()
            adoptRiderVehicle(riderVehicleSet)
        }
        // MYR-221 — returning-user silent resume. Runs once at launch when the
        // start screen is the resolving splash (a stored refresh token exists):
        // refresh silently and route straight into the app on success, or fall
        // back to SignInScreen on no-session / expired / network failure.
        .task {
            guard screen == .resolvingSession else { return }
            if await session.resumeStoredSession() {
                // MYR-224 — route by the resumed account's stored view mode; a
                // session that predates the choice (no stored mode) lands on the
                // chooser rather than defaulting silently into the owner shell.
                routeAfterAuth()
            } else {
                screen = .signIn
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // MYR-222: the rider's location stream joins the owner fleet in
            // explicit suspend/resume handling — see `SharedViewerState
            // .handleBackground()`'s header comment.
            switch phase {
            case .active:
                ownerHomeState.handleForeground()
                sharedViewerState.handleForeground()
                // MYR-186 — re-arm APNs (the token can rotate) and retry a
                // registration PUT that failed earlier. Inert unless the user has
                // already authorized; never blocks anything on screen.
                Task { await pushCoordinator.handleForeground() }
                // MYR-343 — a rider whose vehicle list never answered is sitting on
                // the honest "can't reach" line with nothing in flight behind it.
                // Recovery is the low-friction one MYR-326 settled on (a resume
                // re-asks), not a retry button. No-op in sim, and skipped entirely
                // once a list has landed, so a healthy session costs nothing.
                if screen == .sharedHome, sharedVehicleCatalog.loadFailed, !sharedVehicleCatalog.hasLoaded {
                    Task {
                        await sharedVehicleCatalog.load()
                        adoptRiderVehicle(riderVehicleSet)
                    }
                }
            case .background:
                ownerHomeState.handleBackground()
                sharedViewerState.handleBackground()
            default: break
            }
        }
    }
}

// MARK: - Resolving-session splash (MYR-221)

/// A calm brand-only splash shown for the brief moment a returning user's stored
/// session is silently refreshed at launch. Deliberately motion-free and
/// token-only — it either crossfades into the app (resume ok) or into
/// SignInScreen (resume failed), so it must sit neutrally under both. The brand
/// mark matches SignInScreen's so the SignInScreen fallback is seamless.
private struct ResolvingSessionView: View {
    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 28) {
                HexLogo(size: 62)
                Wordmark(size: 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signing in")
    }
}

#Preview {
    RootView()
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
