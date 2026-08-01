#if DEBUG
import CoreLocation
import Foundation
import ActivityKit
import OSLog
import MyRobotaxiContracts

// MARK: - Live Activity capture hook (MYR-172)
//
// A Live Activity is rendered by a SEPARATE PROCESS (the widget extension) on a
// surface the app cannot draw on — the lock screen and the Dynamic Island. So
// unlike every other DEBUG scene, this one cannot be captured by booting the app
// into a state and screenshotting the app: the app has to START a real Activity
// and the picture has to be taken of the SYSTEM.
//
// This is the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`
// (`initialRefreshPhase`) and `ownerServiceWindowEditor`
// (`opensServiceWindowEditor`): headless tooling cannot perform the gesture, so
// the scene performs it and lets the SHIPPING code do everything after it.
//
// WHAT IS SEEDED, AND WHAT IS REAL. The seeded part is exactly one thing — the
// content state, which on a live path arrives from the server over APNs and cannot
// be conjured on a simulator that has no APNs at all. Everything else is
// production code: `SystemRideActivityPresenter` is the shipping presenter,
// `RideActivityAttributes` is the shipping attributes type, and what the system
// renders is the shipping widget extension. So a capture taken this way shows the
// real layout fed a real-shaped payload, which is the most a simulator can
// honestly offer.
//
// `#if DEBUG` whole, so Release never compiles it, and no scene but
// `riderLiveActivity` consults it — every other capture is byte-identical.

@MainActor
enum RideActivityDebugLauncher {

    /// A content state shaped exactly like the schema's printed example, with the
    /// ETA moved into the near future so the countdown is live in the capture.
    ///
    /// The instant is `now + minutes` rather than the schema's literal
    /// `1785535200`, because that one is fixed in wall-clock time and is in the
    /// past for anyone capturing after it — which would render an expired countdown,
    /// a picture of the wrong thing. The SHAPE is the example's; only the instant
    /// moves.
    static func sampleState(
        status: LiveActivityRideStatus = .enroute,
        etaMinutesFromNow: Int? = 4,
        vehicleName: String = "Blue Whale",
        destination: String = "Home",
        progress: Double? = nil
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            eta: etaMinutesFromNow.map {
                Int(Date().addingTimeInterval(TimeInterval($0 * 60)).timeIntervalSince1970)
            },
            vehicleName: vehicleName,
            destination: destination,
            progress: progress
        )
    }

    /// The car the sample Activity identifies — the STATIC attribute behind
    /// MYR-398 v3's pickup subline, `7SRJ294 · Silver Model Y`.
    ///
    /// It is the board's own fixture, so a capture can be read straight against
    /// `design/la/la-data.jsx`. It lives in the ATTRIBUTES rather than in the content
    /// state because that is where the shipping path puts it — a capture that seeded
    /// it on the wire would photograph a code path the server will never exercise.
    ///
    /// The YEAR is real and the TRIM is deliberately `nil`: contracts 0.27.0's
    /// `VehicleSummary` carries no trim at all, so a scene that supplied one would
    /// photograph a subline no live rider can reach. See `RideActivityVehicle.trim`.
    static let sampleVehicle = RideActivityVehicle(
        plate: "7SRJ294",
        color: "Silver",
        model: "Model Y",
        year: 2026,
        trim: nil
    )

    /// Start a sample Activity through the SHIPPING presenter.
    ///
    /// `staleDate` is honoured. See `DebugScene.sampleLiveActivityFrame` for why
    /// the stale arm uses a SHORT FUTURE date rather than a past one, and for the
    /// limits of what a simulator can actually photograph.
    static func start(
        state: RideActivityAttributes.ContentState,
        staleDate: Date?,
        rideID: String = "debug-ride",
        vehicle: RideActivityVehicle? = sampleVehicle
    ) async {
        // END ANY ACTIVITY LEFT OVER FROM A PREVIOUS CAPTURE FIRST.
        //
        // Established by capture, not by reading: `simctl terminate` does NOT end
        // an app's Live Activities — that is the entire point of the feature, since
        // a ride outlives the app process. So a second `MRT_ACTIVITY_STATE` run
        // silently photographed the FIRST run's Activity, and the give-away was an
        // `arrived` capture (which carries no ETA at all) rendering a live
        // countdown. Without this sweep every capture after the first is a picture
        // of the wrong state, and it looks entirely plausible.
        // MYR-398 — AND THE SWEEP HAS TO WAIT FOR THE LIST, which the first version
        // of it did not. `Activity.activities` is restored ASYNCHRONOUSLY after
        // launch, so a sweep on the first turn of the run loop routinely reads an
        // EMPTY array, ends nothing, and requests a second Activity beside the
        // orphan — and the island then shows whichever one it likes, usually the
        // older. Re-established by capture, exactly as the original trap was: a
        // `noProgress` frame (which carries no ETA at all, by construction) was
        // photographed rendering a live gold countdown.
        //
        // So the sweep RETRIES until the list is empty or the budget runs out. It
        // is cheap on the healthy path — a first-ever launch finds nothing on the
        // first pass and returns immediately — and it is the difference between a
        // capture of this build and a plausible-looking picture of the last one.
        for _ in 0..<sweepAttempts {
            let existing = Activity<RideActivityAttributes>.activities
            guard !existing.isEmpty else {
                try? await Task.sleep(nanoseconds: sweepInterval)
                if Activity<RideActivityAttributes>.activities.isEmpty { break }
                continue
            }
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            try? await Task.sleep(nanoseconds: sweepInterval)
        }

        let presenter = SystemRideActivityPresenter()
        held = presenter
        _ = await presenter.start(
            attributes: RideActivityAttributes(rideID: rideID, vehicle: vehicle),
            state: state,
            staleDate: staleDate
        )
    }

    // MARK: - MYR-405: the two-process repro of the restore race

    /// `MRT_ACTIVITY_ORPHAN=seed|relaunch` — orthogonal to the scene, read by
    /// nothing else, and the ONLY way this defect can be photographed.
    ///
    /// The race is a property of a PROCESS BOUNDARY: `Activity.activities` is
    /// restored asynchronously, so an in-process test can never produce the
    /// half-restored read that starts a second card. Two `simctl launch`es can.
    ///
    ///  • **`seed`** starts an Activity for the ride and stops. `simctl terminate`
    ///    then kills the app WITHOUT ending it — that is the whole point of a Live
    ///    Activity, and it is what leaves the "previous process's card" behind.
    ///  • **`relaunch`** runs the PRODUCTION `RideActivityCoordinator` over the
    ///    PRODUCTION `SystemRideActivityPresenter` for the SAME ride, immediately,
    ///    i.e. exactly what `RootView`'s ride observer does when a cold launch
    ///    adopts an open ride. Nothing is stubbed but the endpoint (there is no
    ///    server here), so the census below is the shipping start path's own answer.
    ///
    /// The census is the evidence: TWO Activities is the client's screenshot; ONE
    /// Activity plus an `adopt` is the fix.
    static func runOrphanProbe() async {
        guard let mode = ProcessInfo.processInfo.environment["MRT_ACTIVITY_ORPHAN"] else { return }
        census("t=0 (first turn of the run loop, mid-restore)")

        switch mode {
        case "seed":
            let presenter = SystemRideActivityPresenter()
            held = presenter
            _ = await presenter.start(
                attributes: RideActivityAttributes(rideID: probeRideID, vehicle: sampleVehicle),
                state: sampleState(status: .enroute),
                staleDate: RideActivityStaleness.date()
            )
        case "relaunch":
            let coordinator = RideActivityCoordinator(
                presenter: SystemRideActivityPresenter(),
                endpoint: nil,
                isLive: true,
                vehicleName: { "Blue Whale" }
            )
            heldCoordinator = coordinator
            await coordinator.handleRideChange(probeRecord())
            probeLog.info("MYR405-PROBE coordinator phase=\(coordinator.phase.rideID ?? "idle", privacy: .public)")
        default:
            return
        }

        for seconds in [1, 3, 6] {
            try? await Task.sleep(for: .seconds(1))
            census("t=\(seconds)s")
        }
    }

    /// Emitted through `os_log` rather than `print`, following the MYR-222 camera
    /// trace: `simctl launch --console` does not reliably carry a SwiftUI app's
    /// stdout, and `log stream` is what the repo's other on-simulator probes read.
    private static func census(_ label: String) {
        let activities = Activity<RideActivityAttributes>.activities
        let rows = activities
            .map { "\($0.attributes.rideID)/\($0.activityState)" }
            .joined(separator: ", ")
        probeLog.info("MYR405-PROBE \(label, privacy: .public) count=\(activities.count, privacy: .public) [\(rows, privacy: .public)]")
    }

    private static let probeLog = Logger(subsystem: "app.myrobotaxi.ios", category: "liveactivity")

    private static let probeRideID = "myr405-orphan-probe"

    private static func probeRecord() -> RideRequestRecord {
        let pickup = RidePlace(
            id: "pickup", label: "Ferry Building", subtitle: nil, miles: 0, minutes: 0,
            icon: "location.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        )
        let destination = RidePlace(
            id: "dest", label: "Home", subtitle: nil, miles: 4.2, minutes: 12,
            icon: "house.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
        )
        var record = RideRequestRecord(
            id: probeRideID,
            input: RideRequestInput(pickup: pickup, destination: destination, fleetMemberID: "vehicle-1"),
            status: .enroute
        )
        record.status = .enroute
        return record
    }

    private static var heldCoordinator: RideActivityCoordinator?

    /// Retained for the life of the process so the Activity is not torn down when
    /// the starting scope exits.
    private static var held: SystemRideActivityPresenter?

    /// How hard the pre-start sweep tries. ~1.5s of budget in total, which is well
    /// inside the 2s a capture script waits before backgrounding the app and far
    /// less than any capture's own settle.
    private static let sweepAttempts = 6
    private static let sweepInterval: UInt64 = 250_000_000
}
#endif
