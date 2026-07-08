import Foundation
import Observation

// MARK: - Telemetry seam (MYR-167 deliverable 1)
//
// `VehicleTelemetrySource` is the M1↔M2 seam: this issue ships
// `SimulatedVehicleTelemetrySource` (a local ticker over fixture data, no
// network — CLAUDE.md "M1 is simulated"). MYR-21's `MyRoboTaxiKit` WS client
// (M2) swaps in a source that decodes `MyRobotaxiContracts.VehicleState`
// frames into the same `VehicleTelemetrySnapshot` shape and drives the
// identical `snapshot` property — `HomeScreen` and `HomeSheetContent` never
// change. Conforming types must be `@Observable` classes (Swift's
// `Observation` tracks field access on the concrete object even when called
// through the protocol's witness table, so `any VehicleTelemetrySource` is
// safe to read from a SwiftUI body).

public enum VehicleTelemetryStatus: String, Sendable, Equatable {
    case driving
    case parked
}

/// Everything a `HomeSheetContent` hero needs to render one tick
/// (screens.jsx `HomeScreen` props `driving, progress, battery, speed` +
/// the `eta` it derives at line 373).
public struct VehicleTelemetrySnapshot: Sendable, Equatable {
    public var status: VehicleTelemetryStatus
    /// 0...1 along the vehicle's `DrivingTrip.route`. Always 0 when parked.
    public var progress: Double
    /// screens.jsx:472 `speed` — 0 when parked.
    public var speedMPH: Int
    /// screens.jsx battery tweak (0...100).
    public var batteryPercent: Double
    /// screens.jsx:373 `eta = Math.max(1, Math.round((1 - progress) * 87))`
    /// — minutes remaining. 0 when parked.
    public var etaMinutes: Int

    public init(
        status: VehicleTelemetryStatus,
        progress: Double,
        speedMPH: Int,
        batteryPercent: Double,
        etaMinutes: Int
    ) {
        self.status = status
        self.progress = progress
        self.speedMPH = speedMPH
        self.batteryPercent = batteryPercent
        self.etaMinutes = etaMinutes
    }
}

/// The M1/M2 seam. `HomeScreen` reads `snapshot`; it doesn't know or care
/// whether the value comes from a local timer (M1) or a live WS frame (M2).
@MainActor
public protocol VehicleTelemetrySource: AnyObject, Observable {
    var snapshot: VehicleTelemetrySnapshot { get }
    /// Begin producing updates. Idempotent.
    func start()
    /// Stop producing updates (e.g. when the screen disappears). Idempotent.
    func stop()
}

/// M1 implementation: a local ticker that animates a driving vehicle along
/// its fixture route — no network. Parked vehicles emit one static snapshot
/// and never tick (screens.jsx has no parked-state animation).
@Observable
@MainActor
public final class SimulatedVehicleTelemetrySource: VehicleTelemetrySource {
    public private(set) var snapshot: VehicleTelemetrySnapshot

    private let totalRouteMinutes: Double
    /// Demo acceleration: the prototype's own auto-advance effect
    /// (app.jsx:51-58) is a no-op stub in the standalone build (its state
    /// mutation was never wired up), so there's no real-time pace to match.
    /// This ticks the full remaining route in ~90s of wall-clock time so the
    /// drift-gate screenshots and simulator runs show visible motion.
    private let demoDurationSeconds: Double = 90
    // `nonisolated(unsafe)`: only ever touched on the main actor except in
    // `deinit`, which Swift always runs nonisolated even for `@MainActor`
    // classes; `Timer.invalidate()` is safe to call from any thread.
    private nonisolated(unsafe) var timer: Timer?
    private let tickInterval: TimeInterval = 1.0 / 30.0

    public init(activity: VehicleActivity) {
        switch activity {
        case .driving:
            // Matches the prototype's default tweaks (app.jsx:12-19):
            // tripProgress 0.42, battery 68, speed 64; eta from screens.jsx:373.
            let progress = 0.42
            totalRouteMinutes = 87
            snapshot = VehicleTelemetrySnapshot(
                status: .driving,
                progress: progress,
                speedMPH: 64,
                batteryPercent: 68,
                etaMinutes: max(1, Int(((1 - progress) * 87).rounded()))
            )
        case .parked:
            totalRouteMinutes = 0
            snapshot = VehicleTelemetrySnapshot(
                status: .parked,
                progress: 0,
                speedMPH: 0,
                batteryPercent: 68,
                etaMinutes: 0
            )
        }
    }

    public func start() {
        guard snapshot.status == .driving, timer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        guard snapshot.status == .driving else { return }

        // app.jsx:51-53's target-speed formula (`55 + Math.sin(Date.now() /
        // 4000) * 18`), smoothed toward like a real ambient fluctuation
        // rather than snapping every tick.
        let t = Date().timeIntervalSinceReferenceDate
        let targetSpeed = 55 + sin(t / 4) * 18
        let smoothedSpeed = Double(snapshot.speedMPH) + (targetSpeed - Double(snapshot.speedMPH)) * 0.06
        snapshot.speedMPH = max(0, Int(smoothedSpeed.rounded()))

        let progressPerTick = tickInterval / demoDurationSeconds
        snapshot.progress = min(1, snapshot.progress + progressPerTick)
        snapshot.etaMinutes = max(0, Int(((1 - snapshot.progress) * totalRouteMinutes).rounded()))
        // Gentle battery drain while driving — cosmetic, not range-modeled.
        snapshot.batteryPercent = max(0, snapshot.batteryPercent - 0.0015)

        if snapshot.progress >= 1 {
            stop()
        }
    }
}
