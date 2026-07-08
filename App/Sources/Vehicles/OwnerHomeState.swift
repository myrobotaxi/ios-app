import DesignSystem
import Observation

// MARK: - Owner home state (MYR-167)
//
// Lives above the owner tab switch (app.jsx's `vehicleIdx`/`sheet` are
// App-level state, not HomeScreen-local — screens.jsx:369 HomeScreen just
// receives them as props) so the selected vehicle, sheet detent, and each
// vehicle's ticking telemetry survive switching to Drives/Share/Settings and
// back to Vehicle.

@Observable
@MainActor
public final class OwnerHomeState {
    public var selectedVehicleIndex: Int = 0
    public var sheetDetent: MRTSheetDetent = .peek

    /// One simulated telemetry source per fixture vehicle, keyed by array
    /// index (stable — `VehicleFixtures.vehicles` never mutates at runtime).
    public let telemetrySources: [any VehicleTelemetrySource]

    public init() {
        telemetrySources = VehicleFixtures.vehicles.map { SimulatedVehicleTelemetrySource(activity: $0.activity) }
    }

    public var selectedVehicle: Vehicle {
        VehicleFixtures.vehicles[selectedVehicleIndex]
    }

    public var selectedTelemetry: any VehicleTelemetrySource {
        telemetrySources[selectedVehicleIndex]
    }

    public func startTelemetry() {
        telemetrySources.forEach { $0.start() }
    }

    public func stopTelemetry() {
        telemetrySources.forEach { $0.stop() }
    }
}
