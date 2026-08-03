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
        // **THERE IS DELIBERATELY NO IDENTIFIER ON THIS CONTAINER, AND THE REASON
        // IS A DEFECT IT SHIPPED.** A `.accessibilityIdentifier("mrt.demo.host")`
        // here reads as harmless — a name for the walkthrough's root, so a test can
        // ask whether the demo is still up. It is not harmless: SwiftUI applies a
        // container's accessibility identifier to the ELEMENTS BENEATH IT, and the
        // outermost one wins. Measured on a running app, every control in the
        // toured screen came back carrying `mrt.demo.host` — the MapHeader vehicle
        // chip, the recenter button, all four tab-bar buttons, the incoming card's
        // rows, its **Accept & send** and **Decline** buttons, and the coach mark's
        // own Skip and Next. So `mrt.demo.next` resolved to NOTHING, on every step,
        // from the first frame.
        //
        // Nothing about this was visible to a user: labels and traits survive the
        // smear intact, so VoiceOver read "SKIP", "Next" and "Accept & send"
        // correctly throughout, and a finger reached all three. What it broke was
        // ADDRESSABILITY — every identifier the toured screens publish for their own
        // tests (`mrt.riderSheet`, `mrt.search.dest.<id>`) was overwritten for as
        // long as the walkthrough was on screen. **A walkthrough that renames the
        // app's controls while it runs is not a pure overlay**, which is this
        // feature's whole premise.
        //
        // The walkthrough is addressed by the step it is on — `mrt.demo.step.<id>`,
        // which sits on the caption's own text group and survives, because that
        // group is the innermost thing annotating those leaves. That identifier is
        // strictly more useful than a root marker anyway: it says WHICH step, and
        // its absence is exactly "the walkthrough is gone".
        // ONE finish observer — see this file's header.
        .onChange(of: run.isFinished) { _, finished in
            if finished { onFinished() }
        }
        // EVERY interactive step. Read off the SAME state the toured screen is
        // rendering, so the walkthrough and the app cannot disagree about where
        // the ride is — and so the tester's tap on the real control is what moves
        // the walkthrough, without the walkthrough ever seeing the tap.
        .onChange(of: milestone) { _, reached in
            if let reached { run.handleMilestone(reached) }
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

        case "ownerDroppedOff":
            // **THE RIDER WHO ISN'T THERE.** `arrived → enroute` is the RIDER's
            // transition — `OwnerDispatchStatus.actionTitle` returns nil for
            // `arrived` on purpose, because "a second owner button here would be a
            // way to take the ride enroute with nobody in the car" (MYR-411). The
            // owner walkthrough has no rider, so without this the ride parks at
            // `arrived` forever, the "Dropped off" button never appears, and the
            // step it belongs to can never end. Running it is what found that;
            // no unit test could, because the rule lives in the screen.
            //
            // So the walkthrough plays the missing rider's one line, which is
            // exactly what the copy tells the owner has happened ("Your rider is
            // aboard"). The owner's own closing tap stays real.
            composition.rideRequestService.startRide()

        case "riderComplete":
            // **THE OWNER WHO ISN'T THERE** — the mirror of the step above, and
            // the same discovery. A ride reaches its summary only by
            // `pickedUp` (owner) → `startRide` (rider) → `droppedOff` (owner),
            // and the rider walkthrough has no owner. Left alone, the rider sat
            // on a tracking sheet that would never resolve.
            //
            // The walkthrough plays the two owner beats so the step's own subject
            // — the post-ride summary — actually exists to be pointed at.
            let service = composition.rideRequestService
            service.pickedUp()
            service.startRide()
            service.droppedOff()

        default:
            break
        }
    }

    /// The demo-facing projection of what the app is currently doing.
    ///
    /// The ride states are read off the SERVICE and the two rider-navigation ones
    /// off the viewer's sheet phase — in both cases the same observable the toured
    /// screen renders from, which is the property that makes a real tap on a real
    /// control move the walkthrough without the walkthrough touching that screen.
    ///
    /// Ride status is checked FIRST so a rider who has reached tracking is not
    /// re-reported as `.destinationChosen` by a stale sheet phase.
    private var milestone: DemoMilestone? {
        if let status = composition.rideRequestService.activeRequest?.status {
            switch status {
            case .completed: return .rideCompleted
            case .arrived: return .rideArrived
            case .accepted, .enroute: return .rideAccepted
            case .pending: return role == .rider ? .requestSubmitted : nil
            case .declined: return nil
            }
        }
        guard role == .rider else { return nil }
        switch composition.viewerState.sheetPhase {
        case .review, .booking: return .destinationChosen
        case .search, .pinDrop: return .searchOpened
        default: return nil
        }
    }
}
