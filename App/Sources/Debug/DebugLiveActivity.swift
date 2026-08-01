#if DEBUG
import Foundation
import ActivityKit
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

    /// The pickup the sample Activity is collecting from — the static attribute
    /// behind MYR-398's "Meet at {pickup}" line.
    ///
    /// It lives here rather than in the content state because that is where the
    /// contract puts it (§7.21.3), and a capture that seeded it on the wire instead
    /// would photograph a code path the server will never exercise.
    static let samplePickupLabel = "Ferry Building"

    /// Start a sample Activity through the SHIPPING presenter.
    ///
    /// `staleDate` is honoured. See `DebugScene.sampleLiveActivityFrame` for why
    /// the stale arm uses a SHORT FUTURE date rather than a past one, and for the
    /// limits of what a simulator can actually photograph.
    static func start(
        state: RideActivityAttributes.ContentState,
        staleDate: Date?,
        rideID: String = "debug-ride",
        pickupLabel: String? = samplePickupLabel
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
            attributes: RideActivityAttributes(rideID: rideID, pickupLabel: pickupLabel),
            state: state,
            staleDate: staleDate
        )
    }

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
