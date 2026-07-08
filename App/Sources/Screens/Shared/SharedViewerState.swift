import DesignSystem
import Observation

// MARK: - Rider sheet phase (MYR-191)
//
// screens.jsx's `SharedViewerScreen` drives its expanding request sheet off
// a local `phase` string (screens.jsx:1869 `useState(initialPhase || 'idle')`)
// that `ExpandingRequestSheet` switches on (design/app/ride-request.jsx
// 1218-1249: 'idle' | 'search' | 'pinDrop' | 'review' | 'pending' |
// 'tracking'). This issue (MYR-191, "rider shell") ships only the resting
// map + greeting sheet; the request→booking→tracking→summary flow is
// MYR-171's scope. `RiderSheetPhase` is the seam: MYR-171 adds a case per
// phase above (each backed by the same porting work `ExpandingRequestSheet`
// already did in the prototype) and extends `SharedViewerScreen`'s body
// switch to match — nothing about M1's `.idle` rendering needs to change.
public enum RiderSheetPhase: Equatable, Sendable {
    case idle
    // MYR-171 adds: .search, .pinDrop, .review, .pending, .tracking
    // (+ the requestState-driven .rejected banner).
}

// MARK: - Shared viewer state (MYR-191)
//
// Owns the rider's live-map telemetry + sheet phase, lifted above the
// `sharedTab` switch in `RootView` — mirrors `OwnerHomeState`'s reasoning
// (see that file's header comment) so the watched vehicle's ticking
// telemetry survives switching to Ride History/Settings and back.
@Observable
@MainActor
public final class SharedViewerState {
    /// The one shared vehicle the rider is watching on the live map
    /// (screens.jsx:1865 `v = VEHICLES[0]`). Riders don't get a fleet
    /// switcher on the idle map — `FLEET` (screens.jsx:15-19, the Teslas
    /// shared with the rider) only comes into play once MYR-171's Review
    /// step lets them choose whose Tesla to request; M1 fixes the rider's
    /// view to the one shared vehicle, reusing the same fixture + telemetry
    /// seam MYR-167 built for the owner's map.
    public let vehicle: Vehicle
    public let telemetrySource: any VehicleTelemetrySource

    /// MYR-191 extension point — see `RiderSheetPhase`.
    public var sheetPhase: RiderSheetPhase = .idle

    public init(vehicle: Vehicle = VehicleFixtures.vehicles[0]) {
        self.vehicle = vehicle
        telemetrySource = SimulatedVehicleTelemetrySource(activity: vehicle.activity)
    }

    public var snapshot: VehicleTelemetrySnapshot { telemetrySource.snapshot }

    public func startTelemetry() { telemetrySource.start() }
    public func stopTelemetry() { telemetrySource.stop() }
}
