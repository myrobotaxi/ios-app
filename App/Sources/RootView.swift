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
    // MYR-428 — has this device already played each role's first-run walkthrough?
    // Device-scoped and deliberately never released on sign-out; see
    // `FirstRunDemo.swift` rule 1.
    private let firstRunDemoStore: any FirstRunDemoStoring = RootView.makeFirstRunDemoStore()
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
    /// MYR-355 — the live `DELETE /api/users/me` seam behind both settings
    /// screens' "Delete account" row, or `nil` on the simulated path (where the
    /// local session IS the whole account). Built once in `init` from the resolved
    /// mode + session provider, mirroring `vehicleTeardownRemover`.
    private let accountDeletionEndpoint: (any AccountDeletionEndpoint)?
    /// MYR-186 — push registration + the permission moments. Always present; on
    /// the simulated path it is INERT (never prompts, never registers, never calls
    /// the network), so the fixture demo and every DEBUG capture scene are
    /// unchanged. Built in `init` from the resolved mode + session provider,
    /// mirroring `teslaAuthenticator` / `vehicleTeardownRemover`.
    @State private var pushCoordinator: PushRegistrationCoordinator
    /// MYR-172 — the rider's ride Live Activity. Always present; INERT on the
    /// simulated path (never calls ActivityKit, never calls the network), so the
    /// fixture demo and every DEBUG capture scene are unchanged — a fixture ride
    /// must never put a real card on a real lock screen.
    ///
    /// It lives HERE rather than in `SharedViewerScreen` because a Live Activity
    /// outlives the screen that started it: the rider can switch to the owner tab,
    /// or leave the app entirely, and the ride goes on. A coordinator owned by the
    /// rider screen would be torn down at exactly the moments the Activity matters
    /// most.
    @State private var rideActivityCoordinator: RideActivityCoordinator
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
    /// MYR-377 — the rider's Scheduled tab against `GET /api/ride-requests`. `nil`
    /// in SIM / static-token dev, where the screen keeps the prototype's fixture
    /// reservations and every DEBUG scene with them.
    @State private var riderScheduledRidesStore: RiderScheduledRidesStore?
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
        // (`_ownerDrivesState` is composed further down, once the MYR-360
        // reservation seam exists — MYR-376 gave Drives → Upcoming a real server
        // read and it takes that same instance.)
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
            ownedVehicles: { [weak homeState] in homeState?.vehicles ?? [] },
            // MYR-386 — the SAME fleet, read for what it is doing rather than for
            // what it holds. `isConnecting` is true from construction until the
            // list lands (`!hasLoaded`) and is suppressed once a `statusMessage`
            // is set, so the failure is checked first. A fleet that has not
            // answered leaves the Share tab's roster genuinely in flight; before
            // this the tab took its empty vehicle list as proof that nothing was
            // shared, rendered the hero, and never re-asked.
            fleetState: { [weak homeState] in
                guard let homeState else { return .resolved }
                if homeState.statusMessage != nil { return .unreachable }
                return homeState.isConnecting ? .resolving : .resolved
            }
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
        // MYR-355 — the live account-deletion endpoint (nil in sim / static-token
        // dev). The DEBUG dialog + ending scenes leave it exactly as composed;
        // only MYR-366's `ownerOffboarding` (a call that never answers) and
        // `offboardingFailed` (a delayed scripted 500) override it, both behind
        // the PRODUCTION flow, so every other scene is byte-identical.
        var deletionEndpoint = AccountDeletionComposition.makeEndpoint(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        )
        #if DEBUG
        if let scripted = DebugScene.current?.accountDeletionEndpoint { deletionEndpoint = scripted }
        #endif
        accountDeletionEndpoint = deletionEndpoint
        // MYR-360 — the reservation seam behind the owner's ride-share pause
        // warning: the owner's upcoming ACCEPTED reservations for one vehicle, plus
        // the decline that withdraws one. `nil` in sim / static-token dev, where the
        // toggle itself does not render.
        //
        // The two `ownerRideSharePauseWarning` capture scenes override it with the
        // SAME production `LiveUpcomingReservations` over a scripted endpoint, so
        // the dialog in the capture was built from a real fetch through the real
        // contract mapping. Nothing else reads the override, so every other scene
        // is byte-identical.
        //
        // MYR-369 — it reaches `InvitesScreen` as well as `HomeScreen` now, because
        // the ride-share switch (and therefore the pause pre-flight) moved to the
        // Share tab. ONE instance for both, so two surfaces can never read
        // different answers about the same car's reservations.
        var reservations = RideRequestComposition.makeUpcomingReservations(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider
        ) as (any UpcomingReservationSource)?
        #if DEBUG
        if let scripted = DebugScene.current?.upcomingReservationSource { reservations = scripted }
        #endif
        upcomingReservations = reservations
        // MYR-376 — Drives → Upcoming takes the SAME reservation instance the
        // Share tab's pause pre-flight reads. Two owner surfaces that name the
        // same car's reservations must never be able to give different answers,
        // which is exactly why MYR-369 made `HomeScreen` and `InvitesScreen`
        // share one; this is that rule extended to the third.
        _ownerDrivesState = State(initialValue: OwnerDrivesState(live: isLive, reservations: reservations))
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
        var seams = PlaceSearchComposition.make(mode: mode, sessionTokenProvider: auth.sessionTokenProvider)
        #if DEBUG
        // MYR-385 — `riderScheduleBooked` injects a §7.22 WIRE STUB at COMPOSITION
        // time, the same shape `recentDestinationsStore()` below swaps its store
        // with, rather than through a mutable hole on the shipping store. Every
        // other scene leaves this `nil`, which for a simulated boot is what the
        // seam already was — so no simulated capture can construct the read.
        if let bookedWindows = DebugScene.current?.bookedWindowsProvider {
            seams.bookedWindows = bookedWindows
        }
        // MYR-422 — the two summary scenes inject the §7.2/§7.4 WIRE at composition
        // time, the same way. Every other scene leaves this `nil`, which for a
        // simulated boot is what the seam already was, so no simulated capture can
        // construct the post-ride drive join.
        if let driveRoutes = DebugScene.current?.driveRoutesProvider {
            seams.driveRoutes = driveRoutes
        }
        #endif
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
            // MYR-396 — `ownerDispatchColdAdopted` is the one scene whose subject
            // is a SERVER READ, so it composes the production
            // `LiveRideRequestService` over a scripted §7.8 endpoint and lets the
            // real `start()` sequence run. Applied AFTER the seeding above, which
            // for this scene is a no-op (it seeds nothing — the record comes off
            // the wire). Every other scene leaves this `nil`.
            if let coldAdopted = scene.rideRequestServiceOverride { service = coldAdopted }
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
        // MYR-377 — the rider's Scheduled tab. Composed AFTER `viewer`, because the
        // car a row names is resolved through the rider's own already-loaded fleet
        // (`SharedViewerState.liveFleetMembers`, MYR-352's whole-list publish) —
        // joined on `vehicleId`, exactly as the owner's incoming card joins its own.
        // A closure and not a snapshot: the fleet lands asynchronously, so a list
        // captured here would be empty for the entire session.
        var scheduledRides = RideRequestComposition.makeScheduledRides(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider,
            vehicleNames: { [weak viewer] vehicleID in
                guard let member = viewer?.liveFleetMembers.first(where: { $0.id == vehicleID }) else { return nil }
                return RiderScheduledRideVehicle(name: member.owner, relationship: member.relationship)
            }
        ) as (any RiderScheduledRideSource)?
        #if DEBUG
        if let scripted = DebugScene.current?.scheduledRideSource { scheduledRides = scripted }
        #endif
        _riderScheduledRidesStore = State(initialValue: scheduledRides.map { RiderScheduledRidesStore(source: $0) })
        // MYR-172 — the rider's Live Activity, bound to the same session. Inert in
        // simulated mode, exactly like the push coordinator above.
        //
        // Composed AFTER `viewer` (MYR-398 v3) because the Activity's static vehicle
        // attribute is read off the rider's own already-loaded fleet — the same list
        // `liveFleetMember` reads, through the one seam that gates it on
        // `isLiveLocation`. A closure and not a snapshot: the list lands
        // asynchronously, so a value captured here would be `nil` for the session,
        // and it is read once per `Activity.request` rather than per frame.
        //
        // ⚠️ MYR-415 — and composed AFTER `service` too, which is the whole reason
        // it moved down here. The §7.21 registration must name the SERVER's ride id
        // (`activeServerRideID`), NOT `RideRequestRecord.id` — which for a ride this
        // device submitted is a client `UUID` that the server has never seen. Taking
        // it off the FINAL `service` matters as much as taking it at all: the DEBUG
        // block above may replace `service` wholesale, and a closure captured over
        // the pre-override value would answer for a service nothing else is using.
        _rideActivityCoordinator = State(initialValue: RideActivityComposition.makeCoordinator(
            mode: mode,
            sessionTokenProvider: auth.sessionTokenProvider,
            vehicle: { [weak viewer] in viewer?.liveActivityVehicle },
            serverRideID: { [weak service] in service?.activeServerRideID }
        ))
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
        // MYR-426 — a code held through sign-in lands in the SAME state update
        // the post-auth screen does. `.onChange(of: inviteLinkContext)` would
        // deliver it too, but only AFTER that screen has rendered once — so the
        // tester would see one frame of the chooser (or of an empty rider shell
        // captioned "no vehicles shared with you") before the prefilled flow
        // covered it. That flash is MYR-343's lesson on the surface this issue
        // is about: the shell someone is about to leave must not narrate a
        // situation that is already resolved. A no-op when nothing is held.
        drainPendingInviteLink()
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
            screen = playsFirstRunDemo(.owner) ? .ownerTutorial : .ownerHome
        case .rider:
            role = .shared
            sharedTab = "shared"
            screen = playsFirstRunDemo(.rider) ? .riderTutorial : .sharedHome
        }
    }

    // MARK: - MYR-428 — the first-run walkthrough gate
    //
    // **ONE FUNNEL, THREE DOORS.** The client asked for the walkthrough on first
    // owner sign-in, on first rider sign-in, and on a switch into rider mode.
    // `applyViewMode` is already the single place all three arrive — the mode
    // chooser (MYR-224), the Settings switch row, and a stored-mode resume — so
    // the gate is asked there, once, rather than at each door. That is MYR-389's
    // entry-invariant lesson: a rule stated at the entrance cannot be forgotten by
    // an exit somebody adds later.
    //
    // **MYR-444 — THE OTHER TWO DOORS ASK THE SAME QUESTION NOW.** MYR-428 let
    // onboarding route to `.ownerTutorial` / `.riderTutorial` on its own (after
    // pairing a Tesla, after redeeming an invite code) and called that "the fourth
    // door needs no gate": with the walkthrough always on, an ungated route and a
    // gated one were indistinguishable, and finishing marked the flag so the shell
    // never showed it twice. A kill switch makes the difference load-bearing — an
    // ungated door is a door the switch does not reach — so all four call
    // `playsFirstRunDemo` and the client's "not for anyone" is a property of this
    // one function rather than of four call sites agreeing.

    @MainActor
    private func playsFirstRunDemo(_ demoRole: FirstRunDemoRole) -> Bool {
        FirstRunDemoGate.playsWalkthrough(for: demoRole, record: firstRunDemoStore.read())
    }

    /// Scope the flags away from DEBUG scenes, exactly as
    /// `recentDestinationsStore()` scopes recents — with the seed INVERTED,
    /// because a scene needs the walkthrough already seen rather than already
    /// forgotten. A capture of `ownerHome` must photograph owner Home, not a coach
    /// mark over it, so **the demo is unreachable from every DEBUG scene by
    /// construction** and every existing scene stays byte-identical.
    private static func makeFirstRunDemoStore() -> any FirstRunDemoStoring {
        #if DEBUG
        if DebugScene.current != nil {
            return InMemoryFirstRunDemoStore(.allSeen())
        }
        #endif
        return UserDefaultsFirstRunDemoStore()
    }

    /// Flip to the OTHER shell from a Settings "Switch mode" row, persisting the
    /// new choice. Only reachable on the live path (the row renders only when a
    /// real account is signed in).
    ///
    /// **MYR-441 — THE RIDER→OWNER DIRECTION IS GATED, AND THE ACTION IS GATED AS
    /// WELL AS THE AFFORDANCE.** The client's report was that a shared viewer
    /// could reach the owner shell, and the affordances are where that was fixed
    /// (`OwnerShellAccess`, consulted by the rider Settings row and MYR-397's
    /// tracking chip). This guard is the second half of the same rule: an action
    /// must not outlive the affordance that reaches it. Every caller of this
    /// method today is one of those two gated controls, so the guard is
    /// unreachable in practice — which is the point. A third control added later
    /// cannot re-open the door by forgetting to ask, and the rule is stated where
    /// the transition happens rather than only where it is drawn.
    ///
    /// The OWNER→RIDER direction is deliberately ungated: every owner may ride,
    /// and MYR-343 is the whole reason the rider shell handles an owner correctly.
    @MainActor
    private func switchViewMode() {
        guard let user = session.currentUser else { return }
        let next: ViewMode = (role == .owner ? ViewMode.owner : ViewMode.rider).toggled
        if next == .owner {
            guard OwnerShellAccess.offersOwnerMode(
                vehicleSet: riderVehicleSet,
                canSwitchModes: true
            ) else { return }
        }
        modeStore.setMode(next, forUserID: user.id)
        applyViewMode(next)
    }

    // MARK: - MYR-455 — re-asking the ownership question of a STORED view mode

    /// Demote an account that is sitting in the owner shell without owning
    /// anything, once its own vehicle list has positively said so.
    ///
    /// **WHY A TRANSITION GUARD WAS NOT ENOUGH.** MYR-441 gated `switchViewMode`,
    /// which is the only door that ASKS. `routeAfterAuth` does not ask — it reads
    /// the persisted `ViewMode` and applies it — and `modeStore.clearMode` runs
    /// only on sign-out, so a viewer who reached owner mode through any pre-fix
    /// door (that ungated switch, or the first-run chooser, which is ungated by
    /// design) boots straight back into the owner shell on every launch, for ever.
    /// The gate shipped and the accounts it was written for never met it.
    ///
    /// **IT DEMOTES ON A POSITIVE ANSWER ONLY**, which is what keeps a real owner
    /// from ever seeing this. `.resolving` and `.unavailable` take nothing away
    /// (`OwnerShellAccess.revokesOwnerMode` is deliberately not the negation of
    /// `offersOwnerMode` — see its header), so the owner shell is never blanked
    /// by a list still in flight or a network blink. `.noVehicles` keeps the
    /// shell too: that is a fresh owner pre-link, and Add-Tesla lives there.
    ///
    /// **THE STORED MODE IS REWRITTEN, not just the live one.** Demoting the
    /// session alone would replay this on every launch — owner shell, list lands,
    /// flip to rider — turning a one-time correction into a permanent flash.
    /// Persisting `.rider` makes the next boot land on the rider shell directly,
    /// so the correction happens at most once per account.
    ///
    /// The one honest cost, stated rather than hidden: on the FIRST launch after
    /// this fix, an affected account does see the owner shell for as long as its
    /// `GET /api/vehicles` takes to answer. Holding the route until the list
    /// lands would avoid that, and would put every legitimate owner's cold launch
    /// behind a network read to fix a state almost nobody is in — so the flash is
    /// taken, once, on the wrong state, in exchange for never delaying the right
    /// one.
    @MainActor
    private func revalidateOwnerModeIfNeeded(_ standing: OwnerShellStanding) {
        let user = session.currentUser
        guard OwnerShellAccess.demotesToRider(
            isInOwnerShell: role == .owner,
            standing: standing,
            hasSignedInAccount: user != nil
        ), let user else { return }
        modeStore.setMode(.rider, forUserID: user.id)
        applyViewMode(.rider)
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

    /// Push a resolved vehicle onto the viewer state.
    ///
    /// `.resolving` deliberately leaves the viewer alone — adopting `nil`
    /// mid-resolution would tear down a perfectly good telemetry source on every
    /// re-ask. `.unavailable` likewise: a list that did not ANSWER is not
    /// evidence the car is gone, and releasing on a transient failure would drop
    /// a live stream every time the network blinked.
    ///
    /// **`.empty` NOW RELEASES, and that is MYR-369's viewer half.** Suspension
    /// is enforced by REMOVING the grant from the viewer's access set, so a
    /// suspended car does not arrive marked — it simply STOPS BEING IN
    /// `GET /api/vehicles`. For a viewer whose only car was suspended, the next
    /// list refresh therefore resolves `.empty` while `sharedVehicle`, the tier
    /// and the `RiderLiveVehicleLocator` subscription all still point at it.
    ///
    /// Before this, `.empty` returned without touching any of that: the shell
    /// swapped to `SharedNoVehiclesScreen` (so the user saw an honest empty
    /// state) while the viewer state kept a socket open on a car the account no
    /// longer has access to, and any later `.ridable` resolution or stale read of
    /// `sharedVehicle` got the revoked one. Nothing crashed — there is no
    /// index-based access anywhere on this path — but the strand was real, and
    /// MYR-369 makes it reachable routinely rather than only on a revoke.
    ///
    /// Releasing here is also what the DV-09 caveat needs from the client: the
    /// server does not tear the socket down on suspend (MYR-373 covers that), so
    /// an already-open stream keeps delivering until it reconnects. `adopt(nil)`
    /// calls `watch(vehicleID: nil)`, which is the client dropping it on the next
    /// list read — the earliest honest moment available to this side.
    @MainActor
    private func adoptRiderVehicle(_ resolution: RiderVehicleSet) {
        switch resolution {
        case .ridable(let adoption):
            sharedViewerState.adopt(adoption)
        case .empty:
            sharedViewerState.adopt(nil)
        case .resolving, .unavailable:
            break
        }
    }

    /// MYR-478 — RE-READ the §7.0 list the rider's ride capability is derived
    /// from, and re-adopt over whatever lands.
    ///
    /// **The withdrawal of `allowRides` reaches this device by NO channel.** §7.5.7
    /// busts the server's own cached access set and stops there; the socket
    /// teardown is deliberately limited to SUSPENSION, because `allowRides` has no
    /// WebSocket effect — the contract's own note says so and records the client
    /// half as tracked separately. So the grantee keeps rendering "Location +
    /// rides" and keeps being offered the booking flow until it independently
    /// re-reads, which is exactly what the external-beta pair reported from both
    /// sides (MYR-451).
    ///
    /// It is the SAME two statements the shell's existing catalog refreshes already
    /// ran, lifted to one place rather than copied out twice more — the tier is
    /// re-derived by `adoptRiderVehicle` off `RiderVehicleSet`, which carries it,
    /// so nothing new decides what the capability is. (The rider-shell-entry
    /// `.task` below keeps its inline `await` form on purpose: inside a `.task`
    /// the read is cancelled when the shell goes away, which a detached `Task`
    /// would not be.)
    ///
    /// Cheap and safe to over-call: `LiveSharedVehicleCatalog.load()` cancels any
    /// read already in flight, a FAILED read changes nothing and leaves the
    /// last-known grants standing (MYR-326), and `adopt` is idempotent by vehicle
    /// id, so a refresh that finds no change does not restart the telemetry source
    /// or jump the map. **No-op in sim**: `SimulatedSharedVehicleCatalog.load()`
    /// answers from memory and its grants carry no tier, so every simulated and
    /// DEBUG capture is byte-identical.
    ///
    /// ⚠️ **KNOWN COST, STATED RATHER THAN HIDDEN.** On a foreground this now makes
    /// the rider shell's SECOND `GET /api/vehicles`: `RiderLiveVehicleLocator
    /// .handleForeground` already re-reads the same list for MYR-402's availability
    /// gate. They are two readers of one endpoint because they want different
    /// fields — the locator wants `hasActiveRide` folded into a `FleetMember`,
    /// which carries no `sharePermission` at all, and the catalog wants the grant
    /// tier. Widening `FleetMember` to carry a capability would put an access tier
    /// on a type whose job is the Review row and would touch every fixture that
    /// builds one, so the duplicate read is the smaller thing to accept here.
    /// Collapsing the rider shell onto ONE §7.0 reader is worth doing on its own.
    @MainActor
    private func refreshRiderVehicleSet() {
        Task {
            await sharedVehicleCatalog.load()
            adoptRiderVehicle(riderVehicleSet)
        }
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

    /// The LOCAL end-of-session sequence, in the one order it has always run:
    /// release the persisted view mode, hand the APNs token back while the Bearer
    /// is still valid (MYR-186), release the live socket + streams on the owner
    /// shell (MYR-201), drop the session, land on Sign In.
    ///
    /// MYR-355 lifted it out of the two sign-out closures so ACCOUNT DELETION can
    /// call the identical thing. A deleted account and a signed-out one must leave
    /// the app in exactly one state, and the surest way to guarantee that is for
    /// there to be exactly one implementation of it.
    ///
    /// `stopsTelemetry` is the only difference between the two shells, and it is
    /// the pre-existing one: the rider shell never started the owner fleet.
    @MainActor
    private func signOutLocally(stopsTelemetry: Bool) {
        clearModeOnSignOut()
        // MYR-396 — release the remembered owner dispatch with the session. It is a
        // single record on a device that holds one session at a time (the same
        // reasoning `UserDefaultsProfileStore` is written on), so the next account
        // must not inherit the previous one's ride.
        rideRequestService.forgetOwnerDispatch()
        unregisterPushOnSignOut()
        if stopsTelemetry { ownerHomeState.stopTelemetry() }
        session.signOut()
        screen = .signIn
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
        // MYR-369 — `rendersLiveRideShareToggle` is GONE with the owner-sheet row
        // it forced into existence. The ride-share scenes are Share-tab scenes now
        // and reach their live rendering through `shareServiceOverride` instead.
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
        switch route {
        case .ownerHome:
            guard screen == .ownerHome else { return }
            ownerTab = "home"
        case .riderActiveFlow:
            guard screen == .sharedHome else { return }
            sharedTab = "shared"
        }
        refreshForPushRoute(route)
    }

    /// MYR-424 — a ride-lifecycle push ARRIVED while the app was foreground. Poke
    /// the same refreshes a tap would, and DO NOT NAVIGATE.
    ///
    /// The distinction is the whole design. A tap is the user asking to be taken
    /// somewhere, so `applyPushTapRoute` selects a tab. A push merely arriving is
    /// not: yanking a rider's tab out from under them because a banner slid down
    /// would be a worse bug than the one being fixed. What arrival justifies is
    /// making whatever they ARE looking at correct — which for r20's rider means
    /// the pending pill learning that its ride was declined.
    ///
    /// Nor is it gated on `screen`, unlike the tap arms above: those guards exist
    /// because they navigate, and there is no surface for which a stale ride
    /// record is preferable. `refreshActiveRide` / `refreshOwnerDispatch` are both
    /// no-ops unless this device actually holds a server-confirmed ride, so the
    /// ungated call costs nothing on a signed-out or onboarding shell.
    @MainActor
    private func applyPushRideRefresh(_ notification: PushRideNotification) {
        refreshForPushRoute(PushNotificationRouting.tapRoute(notification: notification, role: role))
    }

    /// The refresh half of a push, shared by the tap door and the arrival door so
    /// there is ONE definition of "what a push about a ride makes us re-read"
    /// (MYR-396's derive-at-one-door lesson, applied to the funnel itself).
    @MainActor
    private func refreshForPushRoute(_ route: PushTapRoute) {
        let service = rideRequestService
        switch route {
        case .ownerHome:
            // MYR-396 — the dispatch first, for the same reason `start()` orders
            // them that way: a ride already accepted owns the owner's slot, and the
            // still-`requested` ones queue behind it.
            Task {
                await service.refreshOwnerDispatch()
                await service.refreshIncoming()
            }
        case .riderActiveFlow:
            // MYR-402 — `refreshActiveRide` RE-READS the held ride through
            // `integrate` before it adopts, so this is the door through which an
            // owner's decline reaches a rider whose socket missed the frame.
            Task { await service.refreshActiveRide() }
            // MYR-402 — the third of the invariant's three events. A `ride.cancelled`
            // push is the clearest case: the push lands on a rider whose ride is over,
            // and the surface it lands on is the idle sheet, whose availability gate
            // is still reading the list row from before the ride.
            sharedViewerState.refreshRideEndGateInputs()
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
        // MYR-424 — the arrival door (see `applyPushRideRefresh`).
        PushDelegateBridge.shared.applyRideRefresh = { notification in
            applyPushRideRefresh(notification)
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
    ///
    /// **MYR-426 — `.modeChooser` IS FIRST RUN, and takes the first-run
    /// grammar.** It is reachable from exactly one place (a real account with no
    /// stored `ViewMode` — new, or signed out, which MYR-224 treats the same),
    /// so a link landing there belongs to someone holding no shell: they want
    /// the RiderTutorial after joining, and there is nothing behind them to go
    /// back to — which is `.onboarding`, verbatim. The one thing it does NOT share with
    /// `.emptyState` is the fallback: Cancel must return to the CHOOSER, not to
    /// `PostAuthRouter`'s SIM/static-token screen, so the return snapshot is
    /// taken here where `.emptyState` deliberately takes none.
    @MainActor
    private func presentInviteLink(code: String) {
        if screen == .emptyState || screen == .modeChooser {
            inviteOrigin = .onboarding
            inviteLinkReturn = screen == .modeChooser
                ? InviteLinkReturn(
                    role: role, screen: .modeChooser, ownerTab: ownerTab, sharedTab: sharedTab
                )
                : nil
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

    /// MYR-426 — a fresh account that JOINED a car is a rider, so record it.
    ///
    /// Without this the invite lands correctly and then the next launch asks the
    /// chooser's question all over again, of someone who has already answered it
    /// by redeeming a code.
    ///
    /// It persists the shell they are actually being PUT ON. Both completion
    /// arms that reach here land the user on the rider side — MYR-346 decided
    /// that deliberately ("not back to where they came from, which may be the
    /// owner shell, where the car they just gained access to does not appear at
    /// all") — so writing anything else would leave the next launch disagreeing
    /// with this one. Written only when the account has NO stored mode, so an
    /// owner who redeems somebody else's invite from inside their own session
    /// keeps the owner shell they chose; the Settings switch row is the way back
    /// for anyone the default is wrong for. The SIM/static path has no
    /// `currentUser` and writes nothing at all, which is what leaves every DEBUG
    /// scene untouched.
    @MainActor
    private func adoptRiderModeAfterJoin() {
        guard let id = session.currentUser?.id, modeStore.mode(forUserID: id) == nil else { return }
        modeStore.setMode(.rider, forUserID: id)
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
        // MYR-172 — and take the Live Activity down. The card names the rider's
        // DESTINATION, which is P1 and scoped to that one rider; it must not
        // outlive the session that was allowed to see it, and it certainly must not
        // still be there when the next account signs in on this phone.
        Task { await rideActivityCoordinator.handleSignOut() }
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
                        // MYR-426 — a TAP has no shell to restore. Clear any
                        // snapshot an earlier link left, now that the
                        // `.onboarding` cancel path consults one.
                        inviteLinkReturn = nil
                        screen = .inviteCode
                    }
                )
            case .addTesla:
                // app.jsx:94 — onComplete → OwnerTutorial, onCancel → back to
                // the choice screen.
                AddTeslaFlow(
                    onComplete: {
                        role = .owner
                        ownerTab = "home"
                        // MYR-444 — this hand-off used to route to the tutorial
                        // unconditionally, on MYR-428's reasoning that onboarding
                        // "needs no gate". That was true while the walkthrough was
                        // always on; with a kill switch it made this door the one
                        // that ignores it. Every door asks the same question now.
                        screen = playsFirstRunDemo(.owner) ? .ownerTutorial : .ownerHome
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
                        // MYR-426 — they hold a share now, so the account's view
                        // mode is settled if it was not already.
                        adoptRiderModeAfterJoin()
                        switch inviteOrigin {
                        case .onboarding:
                            role = .shared
                            sharedTab = "shared"
                            // MYR-444 — same correction as `AddTeslaFlow`'s
                            // hand-off: the invite-link arrival is one of the
                            // first entries the client named, so it consults the
                            // gate rather than routing past it. With the demo off
                            // this lands exactly where finishing the walkthrough
                            // landed — the rider Live Map, watching the car the
                            // code just granted.
                            screen = playsFirstRunDemo(.rider) ? .riderTutorial : .sharedHome
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
                            // MYR-426 — the snapshot, when there is one, is the
                            // MODE CHOOSER a fresh account's link arrived over;
                            // its absence still falls back to the first-run
                            // choice screen, which is what a tap on that screen
                            // has always restored.
                            restoreAfterInviteLink()
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
            // MYR-428 — these two cases keep their place in the routing matrix
            // (and their deferral in `InviteLinkRouting.acceptsInviteNow`: a link
            // must not interrupt a walkthrough) but no longer render the 5-card
            // story deck. They host the INTERACTIVE walkthrough — the real
            // screens, over the walkthrough's own simulated seams, under a
            // coach-mark layer. See `FirstRunDemoScript.swift` for why the demo
            // absorbs the decks rather than preceding them.
            //
            // Hosting it HERE rather than as an overlay raised after landing is
            // what keeps the hand-off flash-free: routing to the shell first and
            // covering it a frame later is exactly the thing MYR-426 moved the
            // invite drain into `routeAfterAuth` to avoid.
            //
            // `onFinished` fires once for BOTH exits — the closing CTA and the
            // persistent Skip — so skipping marks the role seen just as
            // completing does, and neither replays.
            case .ownerTutorial:
                FirstRunDemoHost(role: .owner) {
                    firstRunDemoStore.markSeen(.owner)
                    screen = .ownerHome
                }
            case .riderTutorial:
                FirstRunDemoHost(role: .rider) {
                    firstRunDemoStore.markSeen(.rider)
                    sharedTab = "shared"
                    screen = .sharedHome
                }
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
                        liveProfile: shareLiveProfile,
                        // MYR-360, re-homed by MYR-369 — the SAME reservation
                        // source `HomeScreen` takes, so the pause pre-flight
                        // follows the switch to the surface that now owns it.
                        upcomingReservations: upcomingReservations
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
                        // MYR-355 — the sign-out sequence lives in ONE place now
                        // (`signOutLocally`), because account deletion ends by
                        // running exactly it. Same order, same steps as before.
                        onSignOut: { signOutLocally(stopsTelemetry: true) },
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
                        pushPrefs: pushPrefsService,
                        // MYR-355 — `DELETE /api/users/me` + the SAME local wipe
                        // the Sign out row runs. nil endpoint in SIM, where there
                        // is no server account to delete.
                        accountDeletion: accountDeletionEndpoint,
                        onAccountDeleted: { signOutLocally(stopsTelemetry: true) }
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
                        isLive: ownerHomeIsLive
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
                        // MYR-224 — real profile (nil in SIM → fixture persona).
                        // MYR-441 — non-nil is now only HALF the "Switch to Owner"
                        // row's gate; the page also asks the catalog whether this
                        // account owns anything (`OwnerShellAccess`).
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
                        // MYR-355 — the same one implementation the owner shell
                        // calls; the rider shell never started the owner fleet, so
                        // it stops no telemetry (unchanged from before).
                        onSignOut: { signOutLocally(stopsTelemetry: false) },
                        accountDeletion: accountDeletionEndpoint,
                        onAccountDeleted: { signOutLocally(stopsTelemetry: false) }
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
                        // MYR-228 — the SIMULATED scheduled list is screen-local
                        // @State seeded from the fixtures; live seeds it empty.
                        // MYR-377 — and live now READS the rider's own reservations
                        // through `scheduledStore`, which is what the "no
                        // scheduled-ride backend" comment here used to stand in for.
                        RideHistoryScreen(
                            sharedTab: $sharedTab,
                            historyStore: rideHistoryStore,
                            isLive: isLiveMode,
                            scheduledStore: riderScheduledRidesStore
                        )
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
                            },
                            // MYR-397 item 2 / MYR-441 — the tracking map's owner
                            // chip, gated on the account actually holding an owner
                            // role. It is handed the WHOLE resolution this shell
                            // was rendered from rather than a boolean derived
                            // beside it, so the chip, the shell, MYR-354's "Your
                            // car" row and the Settings switch row all consult ONE
                            // fact (`OwnerShellAccess`).
                            vehicleSet: riderVehicleSet,
                            // `nil` without a real signed-in account: `switchViewMode`
                            // needs a user id to persist the choice against and
                            // no-ops without one, so the chip must not offer the tap
                            // at all (`RiderOwnerModeChipGate`).
                            onSwitchToOwnerMode: session.currentUser == nil ? nil : { switchViewMode() }
                        )
                    }
                }
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
        // MYR-186 — hand this view's state to the UIKit push delegate.
        .onAppear { configurePushBridge() }
        #if DEBUG
        // MYR-172 — the `riderLiveActivity` capture scene. Unset for every other
        // scene, so nothing else in the drift gate changes by a pixel.
        .task {
            guard let frame = DebugScene.current?.sampleLiveActivityFrame else { return }
            await RideActivityDebugLauncher.start(state: frame.state, staleDate: frame.staleDate)
        }
        // MYR-405 — `MRT_ACTIVITY_ORPHAN=seed|relaunch`, the two-process repro of
        // the restore race. Orthogonal to the scene and unset for every capture.
        .task { await RideActivityDebugLauncher.runOrphanProbe() }
        // MYR-415 — `MRT_ACTIVITY_REGISTER=1`, the on-simulator observation of the
        // §7.21 registration: whether ActivityKit issues a token at all, and which
        // ride id the POST names. Orthogonal to the scene and unset for every
        // capture.
        .task { await RideActivityDebugLauncher.runRegistrationProbe() }
        #endif
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
        // MYR-453 — THE SECOND CHANNEL, and the reason a tapped invite could
        // reach the code screen with the code missing.
        //
        // Until this line the universal link was the ONLY way a code could enter
        // the app, and iOS does not fire a universal link out of a WKWebView-backed
        // in-app browser — which is what Telegram (and most messaging apps) open
        // an `https://` link in. The tester's link therefore resolved to the web
        // page, she arrived in the app with no activity, and the six cells were
        // empty with nothing anywhere able to fill them.
        //
        // The `myrobotaxi` scheme was ALREADY registered for the two Tesla OAuth
        // callbacks, so the app could always be opened this way; what was missing
        // was anyone listening. Anything the parser does not recognise — including
        // a stray `myrobotaxi://tesla-linked` that arrives with no
        // ASWebAuthenticationSession running — routes to `.ignore` and does
        // nothing, exactly as it did when this modifier did not exist.
        //
        // It feeds the SAME mailbox, so a scheme link inherits the cold-launch
        // hold, the deferral matrix and the auto-submit without a second copy of
        // any of it. The web page emitting `InviteLink.appURL(code:)` is the other
        // half and is not this repo's to ship.
        .onOpenURL { url in
            InviteLinkBridge.shared.receive(url)
        }
        // MYR-346 — re-ask where a HELD code should go whenever the shell moves.
        // This is the whole deferral mechanism: sign-in landing, a tutorial
        // finishing, an incoming request being answered, a ride reaching its
        // summary — none of those sites know a link is waiting, and none of them
        // need to.
        .onChange(of: inviteLinkContext) { _, _ in drainPendingInviteLink() }
        // MYR-381 — THE RESERVATION SURFACES REACT TO THE SOCKET NOW.
        //
        // *"Took a long time for ride declined to appear on the rider side."* The
        // rider's Scheduled tab and the owner's Drives → Upcoming are narrow read
        // seams of their own (MYR-376/377) — deliberately, since a list of rides
        // nobody is on has nothing to do with the two ride PIPELINES — and the
        // price was that they refreshed on appearance and foreground and nothing
        // else, while the frame that made them wrong was already in the app.
        //
        // It is wired HERE rather than in the two screens because the state both
        // read outlives them: `RootView`'s own `switch` destroys `RideHistoryScreen`
        // and `DrivesScreen` on every tab change, and the moment a reservation is
        // declined is very often a moment the rider is looking at something else.
        // Refreshing at the root means the list is already right when they arrive,
        // rather than right one `.task` after they arrive.
        //
        // The tick is `0` forever on the simulated path, so this fires exactly zero
        // times in SIM and in every DEBUG scene.
        .onChange(of: rideRequestService.scheduledSurfaceTick) { _, _ in
            Task { await riderScheduledRidesStore?.load() }
            Task {
                await ownerDrivesState.loadUpcoming(
                    vehicleID: ownerHomeState.selectedVehicle?.id,
                    force: true
                )
            }
        }
        // MYR-184 — keep the rider's watched vehicle in step with the catalog.
        // MYR-343 — off the whole RESOLUTION, not off `grants` alone: the vehicle
        // the map watches is the owner's own car when they have one, and a change
        // in the owned partition has to reach the map exactly as a change in the
        // shared one does. Runs on every catalog change, so redeeming a code still
        // lands a real car on the map without a relaunch.
        .onChange(of: riderVehicleSet) { _, resolution in
            adoptRiderVehicle(resolution)
        }
        // MYR-455 — the owner shell re-asks the ownership question the STORED
        // view mode never had to answer. Fires when the fleet's own §7.0 read
        // lands (and on any later refetch), and demotes only on a positive
        // grants-only answer — see `revalidateOwnerModeIfNeeded`.
        .onChange(of: ownerHomeState.ownerShellStanding) { _, standing in
            revalidateOwnerModeIfNeeded(standing)
        }
        // MYR-432 — a §6.2 close (4002, "permission revoked") funnels into the
        // release machinery that ALREADY EXISTS, rather than into a second one.
        // The socket has pruned its own subscription by now; what has to move is
        // the CATALOG, because `riderVehicleSet` above is computed from it and is
        // the only thing that resolves `.empty` and releases the map. Re-reading
        // it here is exactly the MYR-369 viewer half, triggered seconds after the
        // revoke instead of on the next foreground.
        .onChange(of: sharedViewerState.riderAccessRevocationTick) { _, _ in
            sharedViewerState.refreshRideEndGateInputs()
            refreshRiderVehicleSet()
        }
        // MYR-478 — RIDE-FLOW ENTRY, the second of the two capability funnels.
        //
        // A rider reaching for "Where to?" (or a Home/Work chip) is about to
        // compose a request against a capability this device last read when it
        // entered the shell, so the list is re-read here and the CTA degrades to
        // the existing `riderWatchOnly` notice if the owner has withdrawn Rides
        // since.
        //
        // It does NOT gate the tap: the read is in flight behind a sheet that is
        // already opening, because making an interaction wait on a network answer
        // is how a tap comes to feel broken. A withdrawal that lands mid-flow is
        // caught instead by the create-path `403`, which routes through
        // `SharedViewerScreen.handleVehicleUnavailable` and bumps this same tick
        // — one funnel, three doors, rather than a second refresh path.
        .onChange(of: sharedViewerState.rideCapabilityRefreshTick) { _, _ in
            refreshRiderVehicleSet()
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
        // MYR-172 — the Live Activity follows the rider's own ride, wherever the
        // rider happens to be in the app. Observing the WHOLE record (not just
        // `status`, which is what `SharedViewerScreen` watches) is deliberate: a
        // remotely CANCELLED ride is ERASED rather than transitioned, so
        // `activeRequest` goes straight to `nil` and a status-only observer would
        // see `nil == nil` and never fire — leaving a card up for a ride that no
        // longer exists.
        .onChange(of: rideRequestService.activeRequest) { _, record in
            Task { await rideActivityCoordinator.handleRideChange(record) }
        }
        // MYR-415 — THE SERVER'S RIDE ID LANDS ON ITS OWN SCHEDULE, AND NOTHING
        // ELSE OBSERVES IT.
        //
        // MYR-398 v3 starts the Activity at REQUEST, which is before the create POST
        // has fired at all (MYR-218's send grace window), so ActivityKit's token
        // routinely arrives while `activeServerRideID` is still nil and the
        // registration has to wait for it. The create's acknowledgement does NOT
        // change `activeRequest` on the common path — `fireSend` sets
        // `riderServerRideID` and only calls `applyRemote` when the server has
        // already advanced the status — so the observer above never fires for it and
        // the held token would sit until the next status change.
        //
        // Watching the id itself is what closes that window. `handleRideChange`'s
        // own flush covers the launch/foreground/status-change routes; this covers
        // the one moment none of them see.
        .onChange(of: rideRequestService.activeServerRideID) { _, _ in
            Task { await rideActivityCoordinator.handleServerRideIDChange() }
        }
        // MYR-405 — RECONCILE THE LOCK SCREEN WITH THE ACCOUNT, AT LAUNCH.
        //
        // `onChange` above cannot do this and never could: it reasons from the
        // coordinator's `phase`, which is THIS process's memory and is empty at
        // launch, so an Activity started by a previous process is invisible to it.
        // The client's orphan is exactly that Activity — "IN RIDE · Not updating",
        // never ended, unreachable by every code path the app had. This is also
        // where the ADOPT half lands: the start path used to enumerate
        // `Activity.activities` mid-restore, read empty, and request a SECOND card.
        //
        // It runs once per process, ahead of any ride change, and reaps nothing
        // until the rider's own ride list has answered (`hasResolvedActiveRide`) —
        // a launch with no signal must never take a live ride's card down.
        .task {
            await rideActivityCoordinator.handleLaunchOrForeground {
                RideActivityAccountRide(
                    record: rideRequestService.activeRequest,
                    isResolved: rideRequestService.hasResolvedActiveRide
                )
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
                // MYR-172 — re-evaluate the Live Activity against whatever the ride
                // looks like NOW. This is the local final-state fallback's other
                // half: while the app was away the ride may have completed, been
                // declined or been cancelled outright, and if the terminal PUSH was
                // missed (prefs off, APNs dropped it, the phone was offline) the
                // card is still sitting on the lock screen claiming a ride is
                // running. Pushes are the primary channel; this is the backstop.
                //
                // MYR-405 — and it now RECONCILES first. The backstop above only
                // ever asked "does the record disagree with what I remember
                // presenting"; a duplicate, an orphan from a previous process, or a
                // card the rider swiped away are all invisible to that question.
                // Reaping is still gated on the ride pipeline having answered, so a
                // foreground with no network changes nothing.
                Task {
                    await rideActivityCoordinator.handleLaunchOrForeground {
                        RideActivityAccountRide(
                            record: rideRequestService.activeRequest,
                            isResolved: rideRequestService.hasResolvedActiveRide
                        )
                    }
                }
                // MYR-376/377 — a reservation that came DUE while the app was
                // suspended is still dormant on this device: the sweeper's stamp
                // arrives with no WS frame, and a sleeping `Task` does not fire.
                // The service's timer covers a foregrounded app; this covers the
                // one it cannot. Makes no request unless something dormant is held
                // and its moment has actually passed.
                Task { await rideRequestService.refreshDueReservations() }
                // MYR-396 — and the OWNER's live dispatch. A force-quit is the
                // reported case, but a long suspend is the same situation with a
                // different cause: the socket dropped, whatever frames arrived
                // while the app was away are gone, and the card has to be able to
                // come back from the server. Costs no request unless this device
                // remembers a ride it accepted and is not already holding it.
                Task { await rideRequestService.refreshOwnerDispatch() }
                // MYR-402 — and the RIDER's held ride, for the symmetrical reason
                // and against the symmetrical gap. MYR-396 gave the owner pipeline a
                // foreground re-read and the rider pipeline still had none: its only
                // refresh was `refreshActiveRide`, which was adopt-only, so a ride
                // cancelled server-side while the app was suspended stayed in the
                // rider's slot and MYR-341's placeholder stayed shut behind it. The
                // Live Activity's own foreground backstop two Tasks above is written
                // on exactly this reasoning ("if the terminal PUSH was missed… the
                // card is still sitting on the lock screen") — the ride's own record
                // needed the same one. Costs no request unless this device holds a
                // server-confirmed rider ride.
                Task { await rideRequestService.refreshActiveRide() }
                // MYR-424 — and the CHANNEL those refetches are standing in for.
                // The two Tasks above recover the data once; this recovers the
                // socket that is supposed to keep it recovered. It is the wire
                // every other socket in the app already has (`LiveVehicleFleet`,
                // `RiderLiveVehicleLocator`) and the ride socket never did, which
                // is how a terminally-`auth_failed` ride stream survived a
                // foreground and kept the rider deaf for the rest of the process.
                Task { await rideRequestService.handleForeground() }
                // MYR-343 — a rider whose vehicle list never answered is sitting on
                // the honest "can't reach" line with nothing in flight behind it.
                // Recovery is the low-friction one MYR-326 settled on (a resume
                // re-asks), not a retry button. No-op in sim.
                //
                // MYR-478 — AND IT IS UNCONDITIONAL NOW, which is the first of the
                // two capability funnels. The guard used to be `loadFailed &&
                // !hasLoaded`, i.e. it recovered a list that had NEVER answered
                // and refreshed nothing that had — so on a healthy session the
                // rider's share tier was whatever the shell read on entry, for the
                // life of the process. An owner turning Rides off therefore
                // reached the rider only after they left and re-entered the shell
                // or force-quit, which is MYR-402's signature on the neighbouring
                // read. Still scoped to the rider shell, still one request, and
                // still a no-op in sim.
                if screen == .sharedHome {
                    refreshRiderVehicleSet()
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
