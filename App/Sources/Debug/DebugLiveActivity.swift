#if DEBUG
import CoreLocation
import Foundation
import ActivityKit
import OSLog
import MyRoboTaxiKit
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
        progress: Double? = nil,
        asOfMinutesAgo: Int? = nil
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            eta: etaMinutesFromNow.map {
                Int(Date().addingTimeInterval(TimeInterval($0 * 60)).timeIntervalSince1970)
            },
            vehicleName: vehicleName,
            destination: destination,
            progress: progress,
            // MYR-398 v3 — contracts 0.28.0's `asOf`, the instant the SERVER last
            // learned something. A PAST instant, and seeded only where the capture
            // needs one: every non-stale scene leaves it absent, which is also the
            // arm an older server produces.
            asOf: asOfMinutesAgo.map {
                Int(Date().addingTimeInterval(TimeInterval(-$0 * 60)).timeIntervalSince1970)
            }
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

        await startSecondActivityIfRequested(vehicle: vehicle)
        await repushIfRequested(state: state, staleDate: staleDate, presenter: presenter)
        await advanceIfRequested(from: state)
        // MYR-418 — the server's two-delivery completion, and its cold half.
        await completionSequenceIfRequested(from: state)
        await endOnlyIfRequested(from: state)
    }

    // MARK: - MYR-398 §0 B: photographing the MINIMAL island

    /// `MRT_ACTIVITY_MINIMAL=1` — orthogonal to the scene, and the only route to the
    /// minimal presentation there is.
    ///
    /// **THE MINIMAL VIEW IS NOT A STATE OF ONE ACTIVITY, IT IS WHAT THE ISLAND DOES
    /// WITH TWO.** iOS shows the compact leading/trailing pair while a single
    /// Activity owns the island and falls back to two `minimal` presentations the
    /// moment a second one exists — so no `MRT_ACTIVITY_STATE` value can reach it and
    /// no amount of waiting will produce it. This starts a SECOND Activity, for a
    /// DIFFERENT ride id, purely so the first one is rendered minimally.
    ///
    /// It is deliberately a second ride rather than a duplicate of the first: a
    /// duplicate is MYR-405's defect, and a capture hook that reproduced it would be
    /// indistinguishable from a regression of that fix in the census.
    ///
    /// ⚠️ **AND IT IS NOT ENOUGH — ESTABLISHED BY CAPTURE, iOS 26.5 SIMULATOR.** With
    /// two Activities genuinely live (`count=2 [debug-ride/active,
    /// debug-ride-minimal/active]`, logged below) the island still rendered ONE
    /// compact pill. The minimal split is what the island does with two Activities
    /// **from two different APPS**; a second Activity of the same app leaves the
    /// system to pick one, and it picks the compact presentation. So the minimal
    /// surface joins the LOCK SCREEN on the list of things this repo cannot
    /// photograph, and the hook is kept for the census line that proves why rather
    /// than for a frame it cannot produce.
    private static func startSecondActivityIfRequested(vehicle: RideActivityVehicle?) async {
        guard ProcessInfo.processInfo.environment["MRT_ACTIVITY_MINIMAL"] == "1" else { return }

        let second = SystemRideActivityPresenter()
        heldSecond = second
        let started = await second.start(
            attributes: RideActivityAttributes(rideID: "debug-ride-minimal", vehicle: vehicle),
            state: sampleState(status: .accepted, etaMinutesFromNow: 9, progress: 0.2),
            staleDate: nil
        )
        probeLog.info("MYR398-MINIMAL second activity started=\(started, privacy: .public)")
        census("MYR398-MINIMAL after the second start")
    }

    private static var heldSecond: SystemRideActivityPresenter?

    // MARK: - MYR-398 §0 C: does the arrival beat REPLAY?

    /// `MRT_ACTIVITY_REPUSH=<seconds>` — orthogonal to the scene, read by nothing
    /// else, and the only way the once-only claim can be photographed.
    ///
    /// **THE QUESTION IT ANSWERS.** ActivityKit re-renders on every content update,
    /// and a completed ride is pushed to for its whole five-minute linger by a ticker
    /// that has nothing new to say. If the beat were armed by the view's appearance
    /// — or by any flag the widget process holds — the check would pop back to 0.6
    /// and spring in again on every one of those pushes, on a card the rider has
    /// stopped looking at. The fix is that every value the beat animates is derived
    /// from the resolved slot, so an IDENTICAL frame animates nothing; the probe
    /// pushes exactly that identical frame and the capture is the proof.
    ///
    /// It re-pushes the SAME `ContentState` VERBATIM — not a re-composed one — for
    /// the same reason `DebugShareEndpoint` stores its rows in a reference box: a
    /// probe that rebuilt the frame could differ from the original by an instant and
    /// would then be testing a different question.
    private static func repushIfRequested(
        state: RideActivityAttributes.ContentState,
        staleDate: Date?,
        presenter: SystemRideActivityPresenter
    ) async {
        guard let raw = ProcessInfo.processInfo.environment["MRT_ACTIVITY_REPUSH"],
              let seconds = Double(raw), seconds > 0
        else { return }

        // Detached so the scene's own `.task` is not held open for the whole probe —
        // the capture script backgrounds the app in the meantime, and a Live Activity
        // outliving its app is the entire point of the feature.
        Task.detached { @MainActor in
            for _ in 0..<repushCount {
                try? await Task.sleep(for: .seconds(seconds))
                await presenter.update(state: state, staleDate: staleDate)
                probeLog.info("MYR398-REPUSH pushed the identical frame again")
            }
        }
    }

    /// Enough to span a capture window comfortably, and to make a replay obvious if
    /// there is one: three beats a rider would have seen.
    private static let repushCount = 3

    // MARK: - MYR-398 §0 C: photographing the beat ITSELF

    /// `MRT_ACTIVITY_ADVANCE=<seconds>` — push the LEG'S OWN NEXT STATUS onto the
    /// running Activity after a delay.
    ///
    /// **THE BEAT IS A TRANSITION, SO A SCENE CANNOT SHOW IT.** Every
    /// `MRT_ACTIVITY_STATE` value starts the Activity already IN its state, and §0 C's
    /// whole design is that the beat is keyed to the change rather than to the view's
    /// appearance — so a cold `arrived` scene correctly renders the settled frame and
    /// photographs nothing. This makes the change happen: `accepted → arrived` and
    /// `enroute → completed`, i.e. the two transitions a real ride performs, through
    /// the shipping `update` path an APNs push would take.
    ///
    /// Everything about the frame is the scene's; only the moment is ours.
    static func advanceIfRequested(from state: RideActivityAttributes.ContentState) async {
        guard let raw = ProcessInfo.processInfo.environment["MRT_ACTIVITY_ADVANCE"],
              let seconds = Double(raw), seconds > 0,
              let presenter = held
        else { return }

        let next: LiveActivityRideStatus
        switch state.status {
        case .requested, .accepted: next = .arrived
        case .enroute: next = .completed
        default: return
        }

        Task.detached { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            await presenter.update(
                state: RideActivityAttributes.ContentState(
                    status: next,
                    eta: nil,
                    vehicleName: state.vehicleName,
                    destination: state.destination,
                    progress: 1,
                    asOf: state.asOf
                ),
                staleDate: nil
            )
            probeLog.info("MYR398-ADVANCE pushed \(String(describing: next), privacy: .public)")
        }
    }

    // MARK: - MYR-418: the completion sequence the server now sends

    /// `MRT_ACTIVITY_COMPLETE_SEQUENCE=<seconds>` — the SERVER's own MYR-418
    /// completion sequence, performed against a running Activity: an alerted UPDATE
    /// carrying the completed content state, then the alert-free END carrying **the
    /// same state** one second later.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// **WHY THE SERVER SPLIT IT, AND WHY IT MATTERS ON THIS SIDE.** Apple silently
    /// ignores `aps.alert` on an END event, so the single alerted end the server used
    /// to send never expanded the island — the client's missing check mark. MYR-418
    /// therefore sends the completed state TWICE: once as an alerted update (which
    /// expands) and once as the end (which sets the dismissal policy).
    ///
    /// That makes the second delivery the exact input §0 C's once-only rule was
    /// written for, arriving for a NEW reason: the same completed frame, ~1s after
    /// the first. If the arrival beat were armed by anything the widget process holds
    /// — an `onAppear`, a flag, a state — the check would spring in twice, a second
    /// apart, which is worse than not playing at all. It is not: every value the beat
    /// animates is a pure function of the resolved slot, and an identical frame
    /// changes none of them.
    ///
    /// **THE END CARRIES THE STATE VERBATIM**, the same reference the update pushed,
    /// for `MRT_ACTIVITY_REPUSH`'s own reason: a re-composed frame could differ by an
    /// instant and would then be probing a different question.
    /// ─────────────────────────────────────────────────────────────────────────
    static func completionSequenceIfRequested(from state: RideActivityAttributes.ContentState) async {
        guard let seconds = probeSeconds("MRT_ACTIVITY_COMPLETE_SEQUENCE"), let presenter = held
        else { return }

        let completed = completedFrame(from: state)
        Task.detached { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            await presenter.update(state: completed, staleDate: nil)
            probeLog.info("MYR418-SEQUENCE pushed the completed UPDATE")
            try? await Task.sleep(for: .seconds(endAfterUpdate))
            await presenter.end(state: completed, dismissal: RideActivityDismissal.completedLinger)
            probeLog.info("MYR418-SEQUENCE ended with the SAME completed state")
        }
    }

    /// `MRT_ACTIVITY_END_ONLY=<seconds>` — the COLD half of the same question: an
    /// Activity that never saw the update and meets the completed state for the first
    /// time as the END.
    ///
    /// A real rider reaches this by starting late, by a dropped update, or by an app
    /// relaunch between the two deliveries. The card must render the settled check —
    /// static, with no beat, because a beat needs a transition and this frame is a
    /// first sighting.
    static func endOnlyIfRequested(from state: RideActivityAttributes.ContentState) async {
        guard let seconds = probeSeconds("MRT_ACTIVITY_END_ONLY"), let presenter = held else { return }

        let completed = completedFrame(from: state)
        Task.detached { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            await presenter.end(state: completed, dismissal: RideActivityDismissal.completedLinger)
            probeLog.info("MYR418-ENDONLY ended with a completed state never pushed as an update")
        }
    }

    /// The server's own gap between the two deliveries (`aps.timestamp` 1s apart).
    private static let endAfterUpdate: TimeInterval = 1

    /// The completed frame both probes deliver — the scene's own ride, at `progress`
    /// exactly 1 and with no ETA, which is what §7.21 sends for a finished ride.
    private static func completedFrame(
        from state: RideActivityAttributes.ContentState
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: .completed,
            eta: nil,
            vehicleName: state.vehicleName,
            destination: state.destination,
            progress: 1,
            asOf: state.asOf
        )
    }

    private static func probeSeconds(_ key: String) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let seconds = Double(raw), seconds > 0
        else { return nil }
        return seconds
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

    // MARK: - MYR-415: does the §7.21 registration actually POST?

    /// **`MRT_ACTIVITY_REGISTER=1` — the on-simulator half of MYR-415's proof.**
    ///
    /// `go_live_activities` was empty in production and NOTHING said why: the POST
    /// named the ride's local draft UUID, 404'd, and was swallowed. A unit test can
    /// prove the coordinator posts the right id; only a real launch can show what
    /// ActivityKit actually hands this app, which is the half no test can reach.
    ///
    /// So this runs the PRODUCTION `RideActivityCoordinator` over the PRODUCTION
    /// `SystemRideActivityPresenter` and a REAL `Activity.request(pushType: .token)`,
    /// with a spy in the endpoint slot, and logs every step through `os_log`:
    /// whether a token ever arrived, and if so what id / sandbox flag the
    /// registration carried.
    ///
    /// ⚠️ **A SIMULATOR MAY NEVER ISSUE AN ACTIVITY PUSH TOKEN AT ALL** — there is no
    /// APNs connection behind it — so "no token" here is a statement about the
    /// simulator and NOT evidence about the fix. That is exactly why the probe logs
    /// the ABSENCE explicitly instead of finishing quietly: an empty log and a
    /// broken client looked identical for three days, and that is the thing this
    /// issue is really about.
    static func runRegistrationProbe() async {
        guard ProcessInfo.processInfo.environment["MRT_ACTIVITY_REGISTER"] == "1" else { return }

        let spy = RegistrationProbeEndpoint()
        registrationSpy = spy
        let coordinator = RideActivityCoordinator(
            presenter: SystemRideActivityPresenter(),
            endpoint: spy,
            isLive: true,
            vehicleName: { "Blue Whale" },
            // The two ids DIFFER here on purpose, exactly as they do in production
            // for a ride this device submitted: the record carries the optimistic
            // client UUID and the server's id lives beside it.
            serverRideID: { "myr415-SERVER-ride-id" }
        )
        heldCoordinator = coordinator

        probeLog.info("MYR415-PROBE starting Activity localRideID=\(probeRideID, privacy: .public) serverRideID=myr415-SERVER-ride-id")
        await coordinator.handleRideChange(probeRecord())
        probeLog.info("MYR415-PROBE phase=\(coordinator.phase.rideID ?? "idle", privacy: .public)")

        for seconds in [1, 3, 6, 10] {
            try? await Task.sleep(for: .seconds(1))
            let calls = spy.calls
            probeLog.info(
                "MYR415-PROBE t=\(seconds)s registrationCalls=\(calls.count, privacy: .public) [\(calls.joined(separator: " | "), privacy: .public)]"
            )
        }
        if spy.calls.isEmpty {
            probeLog.notice(
                "MYR415-PROBE NO TOKEN — ActivityKit issued no push token in this process. Expected on a SIMULATOR (no APNs); on a DEVICE this is the defect."
            )
        }
    }

    /// Records what the coordinator asked the wire to do, without a wire.
    private final class RegistrationProbeEndpoint: RideActivityTokenEndpoint, @unchecked Sendable {
        private(set) var calls: [String] = []

        func registerRideActivityToken(
            rideID: String,
            token: String,
            sandbox: Bool
        ) async throws -> LiveActivityRegistrationResponse {
            calls.append("POST ride=\(rideID) token=\(LiveActivityTokenRedaction.redacted(token)) sandbox=\(sandbox)")
            return LiveActivityRegistrationResponse(registered: true, sandbox: sandbox)
        }

        func endRideActivityToken(rideID: String) async throws -> EndLiveActivityResponse {
            calls.append("DELETE ride=\(rideID)")
            return EndLiveActivityResponse(ended: true)
        }
    }

    private static var registrationSpy: RegistrationProbeEndpoint?

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
