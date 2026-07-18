import SwiftUI
import DesignSystem

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
    /// MYR-228 — the ONE resolved live/sim flag, kept so `body` can seed the
    /// screen-local scheduled-ride list (`RideHistoryScreen`) empty in live mode.
    /// Every fixture-seeded state above/below is gated on this single decision.
    private let isLiveMode: Bool
    /// MYR-169 — mirrors `ownerHomeState`'s reasoning: app.jsx keeps
    /// `ownerUpcoming` App-level, not local to `DrivesScreen`, so a
    /// cancelled reservation and an open drive summary both survive
    /// switching to another tab and back. MYR-228 — seeded empty in live mode
    /// (no reservation backend); see `OwnerDrivesState`'s header comment.
    @State private var ownerDrivesState: OwnerDrivesState
    /// MYR-170 — shared between `InvitesScreen` and `SettingsScreen`; see
    /// `OwnerShareState`'s header comment for why this is lifted+shared
    /// rather than forking the prototype's two independent copies. MYR-228 —
    /// seeded empty in live mode (no sharing backend).
    @State private var ownerShareState: OwnerShareState
    /// MYR-170 — Settings' linked-vehicle list + primary designation; see
    /// `OwnerVehiclesState`'s header comment for its scope boundary vs.
    /// `OwnerHomeState`. MYR-228 — seeded empty in live mode (not wired to the
    /// live fleet; no set-primary/unlink backend).
    @State private var ownerVehiclesState: OwnerVehiclesState
    @State private var sharedTab = "shared"
    @State private var inviteOrigin: InviteOrigin = .onboarding
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
        _ownerShareState = State(initialValue: OwnerShareState(live: isLive))
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
        _ownerHomeState = State(initialValue: TelemetryComposition.makeOwnerHomeState(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        ))
        // MYR-211 — compose the rider's place-search + location seams (sim
        // fixtures by default; live MapKit/CoreLocation on device / when live).
        let seams = PlaceSearchComposition.make(mode: mode, sessionTokenProvider: auth.sessionTokenProvider)
        let viewer = SharedViewerState(seams: seams)
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
        #endif
        _sharedViewerState = State(initialValue: viewer)
        _rideRequestService = State(initialValue: service)
        _screen = State(initialValue: startScreen)
        _role = State(initialValue: startRole)
        _sharedTab = State(initialValue: startSharedTab)
        _ownerTab = State(initialValue: startOwnerTab)
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
                    onCancel: { screen = .emptyState }
                )
            case .inviteCode:
                // app.jsx:98-101 — onComplete/onCancel route on `inviteOrigin`
                // (MYR-170): from onboarding, into RiderTutorial / back to the
                // choice screen; from rider Settings ("returning"), skip the
                // tutorial entirely and land back on Settings.
                InviteCodeFlow(
                    onComplete: {
                        switch inviteOrigin {
                        case .onboarding:
                            role = .shared
                            screen = .riderTutorial
                        case .sharedSettings:
                            role = .shared
                            screen = .sharedHome
                            sharedTab = "sharedSettings"
                        }
                    },
                    onCancel: {
                        switch inviteOrigin {
                        case .onboarding:
                            screen = .emptyState
                        case .sharedSettings:
                            screen = .sharedHome
                            sharedTab = "sharedSettings"
                        }
                    },
                    returning: inviteOrigin == .sharedSettings
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
                        DrivesScreen(homeState: ownerHomeState, drivesState: ownerDrivesState, ownerTab: $ownerTab)
                    }
                case "invites":
                    InvitesScreen(shareState: ownerShareState, ownerTab: $ownerTab)
                case "settings":
                    SettingsScreen(
                        shareState: ownerShareState,
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
                        linkedVehicles: isLiveMode ? ownerHomeState : nil,
                        onSignOut: {
                            // MYR-201 — release the live socket + streams before
                            // dropping the session (no-op for the simulated fleet).
                            clearModeOnSignOut()
                            ownerHomeState.stopTelemetry()
                            session.signOut()
                            screen = .signIn
                        }
                    )
                default:
                    HomeScreen(
                        homeState: ownerHomeState,
                        ownerTab: $ownerTab,
                        rideRequestService: rideRequestService,
                        drivesState: ownerDrivesState
                    )
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
                        onSwitchMode: switchViewMode,
                        onAddCode: {
                            inviteOrigin = .sharedSettings
                            screen = .inviteCode
                        },
                        onSignOut: {
                            clearModeOnSignOut()
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
                    SharedViewerScreen(
                        viewerState: sharedViewerState,
                        sharedTab: $sharedTab,
                        rideRequestService: rideRequestService,
                        historyStore: rideHistoryStore,
                        // MYR-224 — real rider identity for the greeting + summary
                        // (nil in SIM → the fixture "Sam", pixel-identical).
                        liveProfile: session.currentUser
                    )
                }
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
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
