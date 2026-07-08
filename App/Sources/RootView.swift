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
    case signIn
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
    @State private var session = SimulatedAuthSession()
    @State private var screen: AppScreen = .signIn
    @State private var role: UserRole = .owner
    // Lifted above `.ownerHome`'s tab switch (app.jsx's `vehicleIdx`/`sheet`
    // are App-level state, not HomeScreen-local — screens.jsx:369) so the
    // selected vehicle, sheet detent, and each vehicle's ticking telemetry
    // survive switching to Drives/Share/Settings and back.
    @State private var ownerHomeState = OwnerHomeState()
    @State private var ownerTab = "home"
    /// MYR-169 — mirrors `ownerHomeState`'s reasoning: app.jsx keeps
    /// `ownerUpcoming` App-level, not local to `DrivesScreen`, so a
    /// cancelled reservation and an open drive summary both survive
    /// switching to another tab and back.
    @State private var ownerDrivesState = OwnerDrivesState()
    /// MYR-170 — shared between `InvitesScreen` and `SettingsScreen`; see
    /// `OwnerShareState`'s header comment for why this is lifted+shared
    /// rather than forking the prototype's two independent copies.
    @State private var ownerShareState = OwnerShareState()
    /// MYR-170 — Settings' linked-vehicle list + primary designation; see
    /// `OwnerVehiclesState`'s header comment for its scope boundary vs.
    /// `OwnerHomeState`.
    @State private var ownerVehiclesState = OwnerVehiclesState()
    @State private var sharedTab = "shared"
    @State private var inviteOrigin: InviteOrigin = .onboarding
    /// MYR-191 — mirrors `ownerHomeState`'s reasoning: lifted above the
    /// `sharedTab` switch so the rider's watched vehicle keeps ticking
    /// telemetry across Ride History/Settings and back to Live Map.
    @State private var sharedViewerState = SharedViewerState()
    /// MYR-171 — the M1↔M2 ride-request seam (`RideRequestService`'s header
    /// comment). Lifted here, alongside every other role-scoped state above,
    /// so the SAME instance is visible from both `SharedViewerScreen` (rider)
    /// and `HomeScreen` (owner) — the mechanism that lets one simulated
    /// request bridge across a role switch within a single app session.
    @State private var rideRequestService = SimulatedRideRequestService()
    /// MYR-171 — see `RideHistoryStore`'s header comment: lifted the same way
    /// so a ride that finishes while the rider is on Live Map still lands in
    /// Ride History.
    @State private var rideHistoryStore = RideHistoryStore()

    var body: some View {
        ZStack {
            switch screen {
            case .signIn:
                SignInScreen(session: session) {
                    // First run lands on the choice screen (app.jsx 'empty');
                    // returning-user routing straight to home is a later issue.
                    screen = .emptyState
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
                    if let openID = ownerDrivesState.openDriveID, let drive = DriveFixtures.drive(id: openID) {
                        DriveSummaryScreen(drive: drive) {
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
                        onSignOut: {
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
                        onAddCode: {
                            inviteOrigin = .sharedSettings
                            screen = .inviteCode
                        },
                        onSignOut: {
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
                        RideHistoryScreen(sharedTab: $sharedTab, historyStore: rideHistoryStore)
                    }
                default:
                    SharedViewerScreen(
                        viewerState: sharedViewerState,
                        sharedTab: $sharedTab,
                        rideRequestService: rideRequestService,
                        historyStore: rideHistoryStore
                    )
                }
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
    }
}

#Preview {
    RootView()
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
