import Observation

// MARK: - Owner vehicles state (MYR-170 — design/app/screens.jsx 1567,1826-1832)
//
// `SettingsScreen` keeps its own local `vehicles`/`primaryId` in the
// prototype (`uS(VEHICLES)`), independent of `HomeScreen`'s vehicle
// switcher (`vehicleIdx` into the same fixture array, MYR-167). This port
// mirrors that boundary deliberately: unifying Settings' mutable
// unlink/set-primary vehicle list with `OwnerHomeState`'s static
// `VehicleFixtures.vehicles` indexing (so unlinking here also removed a
// vehicle from the Home switcher/map) would be a cross-screen fixture
// refactor touching MYR-167/168, out of scope for MYR-170. Known M1 gap,
// called out in the PR description: unlinking a vehicle in Settings does not
// remove it from the Home vehicle switcher.
//
// Lifted above the owner tab switch in `RootView` (mirrors
// `OwnerHomeState`/`OwnerDrivesState`) so a set-primary/unlink survives
// switching tabs and back.
@Observable
@MainActor
public final class OwnerVehiclesState {
    public var vehicles: [Vehicle]
    public var primaryID: String

    public init() {
        vehicles = VehicleFixtures.vehicles
        primaryID = VehicleFixtures.vehicles[0].id
    }

    /// screens.jsx:1747 `setPrimaryId(v.id)`.
    public func setPrimary(_ id: String) {
        primaryID = id
    }

    /// screens.jsx:1826-1831 — removes the vehicle; if it was primary,
    /// promotes the first remaining vehicle.
    public func unlink(_ id: String) {
        vehicles.removeAll { $0.id == id }
        if primaryID == id, let next = vehicles.first {
            primaryID = next.id
        }
    }
}
