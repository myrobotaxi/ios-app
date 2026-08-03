import SwiftUI
import DesignSystem

// MARK: - MYR-428 — the walkthrough's own app
//
// **THE DEMO CANNOT TOUCH LIVE DATA BECAUSE IT HOLDS NO LIVE SEAM.** This host
// composes `AppMode.simulated` explicitly and builds the toured shells against
// THAT — its own `SimulatedRideRequestService`, its own simulated fleet, its own
// fixture history — so the screens the tester drives are the real
// `HomeScreen` / `SharedViewerScreen`, rendering the real controls, over a
// substrate that has no backend to reach. A live tester's own session, fleet,
// ride pipeline and Live Activity coordinator are not passed in and are not
// reachable from here.
//
// That is deliberately an ABSENCE rather than an `if isDemo` guard on the write
// paths — the MYR-385 pattern this repo keeps arriving at ("the simulated picker
// does not *skip* the fetch, it has nothing to fetch with"). There is no branch
// inside the ride flow to get backwards, and no env var: `AppMode` is the ONE
// resolved seam MYR-228 established, and this passes `.simulated` to it directly.
//
// **IT IS ALSO WHY THE FLAG IS MARKED BY THE HOST AND NOT BY THE OVERLAY.** Both
// exits — the last step's CTA and the persistent Skip — set `run.isFinished`, and
// this one observer marks the role seen and hands back. A second write site is
// how "skip" and "complete" come to disagree.

/// Everything one walkthrough needs, built once and held for its lifetime.
///
/// A class rather than a struct because the shells take `@Bindable` state objects
/// and a re-created composition mid-walkthrough would restart the ride the tester
/// is halfway through.
@MainActor
final class FirstRunDemoComposition {
    let rideRequestService: SimulatedRideRequestService
    let viewerState: SharedViewerState
    let ownerHomeState: OwnerHomeState
    let ownerDrivesState: OwnerDrivesState
    let historyStore: RideHistoryStore

    init() {
        // The one decision, stated once. Everything below hangs off it.
        let mode: AppMode = .simulated
        let seams = PlaceSearchComposition.make(mode: mode)

        rideRequestService = SimulatedRideRequestService()
        // An in-memory recents store, for the reason `RootView.recentDestinationsStore()`
        // gives a DEBUG scene: a destination chosen inside a practice run is not a
        // place this rider went, and it must not surface in their real search sheet
        // afterwards.
        viewerState = SharedViewerState(
            vehicle: VehicleFixtures.vehicles[0],
            seams: seams,
            recentDestinationsStore: InMemoryRecentDestinationsStore([])
        )
        ownerHomeState = TelemetryComposition.makeOwnerHomeState(mode: mode)
        ownerDrivesState = OwnerDrivesState(live: false)
        historyStore = RideHistoryStore(seed: RideHistoryFixtures.requestedRides)
    }
}

/// Plays one role's walkthrough over the real screens, then hands back.
struct FirstRunDemoHost: View {
    let role: FirstRunDemoRole
    /// Called exactly once, however the walkthrough ended. The caller marks the
    /// flag and routes to the role's real home surface.
    let onFinished: () -> Void

    @State private var run: FirstRunDemoRun
    @State private var composition = FirstRunDemoComposition()
    @State private var ownerTab = "home"
    @State private var sharedTab = "shared"

    init(role: FirstRunDemoRole, onFinished: @escaping () -> Void) {
        self.role = role
        self.onFinished = onFinished
        _run = State(initialValue: FirstRunDemoRun(role: role))
    }

    var body: some View {
        ZStack {
            shell
            DemoCoachMarkOverlay(run: run)
        }
        .accessibilityIdentifier("mrt.demo.host")
        // ONE finish observer — see this file's header.
        .onChange(of: run.isFinished) { _, finished in
            if finished { onFinished() }
        }
        // The two `.rideStatus` steps. Read off the SAME record the toured screen
        // is rendering, so the walkthrough and the ride cannot disagree about
        // where the ride is.
        .onChange(of: demoRideStatus) { _, status in
            if let status { run.handleRideStatus(status) }
        }
        .onAppear(perform: prepareStep)
        .onChange(of: run.index) { _, _ in prepareStep() }
    }

    // MARK: The toured shells

    @ViewBuilder
    private var shell: some View {
        switch role {
        case .owner:
            HomeScreen(
                homeState: composition.ownerHomeState,
                ownerTab: $ownerTab,
                rideRequestService: composition.rideRequestService,
                drivesState: composition.ownerDrivesState
            )
        case .rider:
            SharedViewerScreen(
                viewerState: composition.viewerState,
                sharedTab: $sharedTab,
                rideRequestService: composition.rideRequestService,
                historyStore: composition.historyStore
            )
        }
    }

    // MARK: Cues
    //
    // A step that is ABOUT a situation has to put the app in it. The cue is the
    // only thing the walkthrough does TO the app — every other transition in both
    // scripts is the tester's own tap on a real control, or the simulated
    // service's own timers running.

    private func prepareStep() {
        switch run.step.id {
        case "ownerIncoming":
            composition.rideRequestService.seedDemoIncomingRequest()
        default:
            break
        }
    }

    /// The demo-facing projection of the ride the toured screen holds.
    private var demoRideStatus: DemoRideStatus? {
        let record = role == .owner
            ? composition.rideRequestService.ownerDispatch
            : composition.rideRequestService.activeRequest
        switch record?.status {
        case .accepted: return .accepted
        case .arrived: return .arrived
        case .enroute: return .enroute
        case .completed: return .completed
        default: return nil
        }
    }
}
