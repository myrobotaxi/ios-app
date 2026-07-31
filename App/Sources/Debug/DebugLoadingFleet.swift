#if DEBUG
import CoreLocation
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugLoadingFleet (MYR-326 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that HOLDS STILL in each of the live path's loading states,
// so the MYR-326 skeletons can be captured full-frame headlessly.
//
// They cannot be captured any other way. Each one is, by definition, a state the
// app leaves as fast as it can: on a healthy account the fleet list lands in a
// few hundred milliseconds and the cold snapshot right behind it, and the state
// that lasts long enough to screenshot — the client's — needs a REAL car that is
// asleep or in service, behind a real auth session, answering `503
// vehicle_asleep` on a schedule no test can arrange. The simulated fleet is no
// help either: `SimulatedVehicleFleet.isConnecting` is `false` by construction
// (fixtures are present at t=0), which is exactly why every existing drift-gate
// scene stays byte-identical through this issue.
//
// So each variant below parks the app in one loading branch and never leaves it:
// `isConnecting` stays true, or the drives feed stays `isLoading`, with nothing
// scheduled to resolve them. Everything the capture SHOWS is still the shipping
// view code — these fleets only decide what is and isn't known yet.
//
// Release builds never compile this file; it is reachable only via the
// `ownerConnectingCold` / `ownerConnecting` / `ownerDrivesLoading` /
// `ownerSettingsLoading` scenes.
@Observable
@MainActor
final class DebugLoadingFleet: VehicleFleet {

    /// Which loading branch to hold.
    enum Variant {
        /// NOTHING is known yet — the `GET /api/vehicles` list is still in
        /// flight. The switcher chip has no name to show, so it is a placeholder
        /// too. This is the first ~300ms of every live boot.
        case fleetListPending
        /// The list HAS landed (the car's name is real and on screen) and the
        /// cold `/snapshot` has not. This is the CLIENT'S state: the one MYR-319's
        /// 0/0.8/3/9s retry schedule exists for, and the one his screenshot was
        /// taken in — which is why the skeleton keeps the real switcher and
        /// places placeholders only in the sheet.
        case snapshotPending
        /// Fleet + snapshot are both in, and the owner opened Drives: the first
        /// page of `GET /api/vehicles/{id}/drives` is in flight.
        case drivesPending
        /// MYR-387 — THE RETRIES ARE SPENT. The list landed, the cold
        /// `/snapshot` never did, and `ColdSnapshotLoad.budget()` has expired:
        /// `isConnecting` is false, the honest line is published, and there is
        /// nothing in flight behind it.
        ///
        /// It had **no capture route at all** before this issue, and worse, no
        /// RENDER: `HomeScreen`'s content branch needed only a vehicle ROW, which
        /// the successful list had already provided, so this state rendered the
        /// full map + sheet built on a snapshot that does not exist. The scene
        /// exists to photograph the honest end state and its retry affordance.
        case coldReadFailed
        /// MYR-387 — the snapshot ARRIVED and carries **no fix**: `latitude` and
        /// `longitude` are websocket-protocol §2.3's `(0, 0)` sentinel. Real for
        /// a car whose GPS has not reported since the backend last read it.
        ///
        /// The map must open on the device's last-known position for this car
        /// (widened, and with NO vehicle pin), or — with no cache — on MapKit's
        /// own wide framing. What it must never do is centre on the Gulf of
        /// Guinea, which reads as a completely black screen. Injects no cached
        /// position, so this scene captures the `.unpositioned` arm.
        case noFix
    }

    let vehicles: [Vehicle]
    private let variant: Variant
    private let source: DebugLoadingTelemetrySource
    private let executor: SimulatedVehicleCommandExecutor
    private let feed: any DrivesFeed

    /// True for the two Home variants — nothing scheduled will ever flip it, so
    /// the skeleton holds for the screenshot.
    var isConnecting: Bool {
        switch variant {
        case .fleetListPending, .snapshotPending: return true
        case .drivesPending, .coldReadFailed, .noFix: return false
        }
    }

    /// `nil` for MYR-326's four: a status message would END the loading state
    /// (`LiveVehicleFleet.isConnecting` suppresses on one), which is the honest
    /// branch those scenes are specifically NOT capturing.
    ///
    /// MYR-387's `coldReadFailed` is the opposite scene — it exists to capture
    /// exactly that line, built by the SHIPPING `ColdSnapshotLoad
    /// .unreachableMessage` off the name the list gave us, not a literal.
    var statusMessage: String? {
        variant == .coldReadFailed ? ColdSnapshotLoad.unreachableMessage(vehicleName: "Lunar") : nil
    }

    /// MYR-387 — `coldReadFailed` is the ONE variant with no snapshot behind it,
    /// which is what makes `OwnerHomePresentation` resolve `.unavailable` instead
    /// of keeping a sheet full of last-known values up.
    var hasLiveSnapshotForActiveVehicle: Bool { variant != .coldReadFailed }

    /// MYR-387 — the scene captures the retry AFFORDANCE, not a recovery: there
    /// is no server behind it to answer, so the state has to hold still for the
    /// screenshot. Tapping it is a no-op here and a real re-ask in production.
    func retry() {}

    init(variant: Variant) {
        self.variant = variant
        let state = Self.parkedState(hasFix: variant != .noFix)
        let summary = Self.summary(state: state)
        // The list is only "known" once it has landed — the whole difference
        // between the two Home variants.
        // MYR-387 — `coldReadFailed` holds the LIST row and NOTHING else, which
        // is the whole shape of the client's situation: the car's name is known
        // and its position is not. Passing `state: nil` runs the real
        // `placeholderActivity` fold, so the scene reaches the honest branch by
        // the production route rather than by a flag.
        switch variant {
        case .fleetListPending:
            vehicles = []
        case .coldReadFailed:
            vehicles = [VehicleContractMapping.vehicle(summary: summary, state: nil)]
        case .snapshotPending, .drivesPending, .noFix:
            vehicles = [VehicleContractMapping.vehicle(summary: summary, state: state)]
        }
        // The Drives variant needs a real snapshot behind it: its screen renders
        // the header's odometer figure off the selected telemetry, and a
        // half-loaded header would confuse what the capture is about.
        source = DebugLoadingTelemetrySource(
            snapshot: VehicleContractMapping.snapshot(from: state)
        )
        executor = SimulatedVehicleCommandExecutor(driving: false, plate: "")
        feed = variant == .drivesPending ? DebugLoadingDrivesFeed() : SimulatedDrivesFeed()
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource { source }
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executor }
    func drivesFeed(at index: Int) -> any DrivesFeed { feed }
    func badgeStatus(at index: Int) -> MRTVehicleStatus { .parked }

    func start() {}
    func stop() {}
    func setActive(index: Int) {}
    func handleForeground() {}
    func handleBackground() {}

    /// The live-shaped row the two "list has landed" variants show. Real name,
    /// real model/year — the point of `snapshotPending` is that these ARE known
    /// while the sheet still has nothing to put in it.
    private static func summary(state: VehicleState) -> VehicleSummary {
        VehicleSummary(
            vehicleId: "debug-loading",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3456",
            status: .parked,
            chargeLevel: 64,
            estimatedRange: 174,
            lastUpdated: state.lastUpdated,
            role: .owner,
            licensePlate: nil
        )
    }

    private static func parkedState(hasFix: Bool = true) -> VehicleState {
        VehicleState(
            vehicleId: "debug-loading",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vin: "7SAYGDEE9RA123456",
            softwareVersion: "2026.14.3",
            trim: "Performance",
            status: .parked,
            speed: 0,
            heading: 0,
            // MYR-387 — `(0, 0)` is §2.3's NO-FIX sentinel, not a place. The
            // `noFix` scene emits it exactly as a real server does.
            latitude: hasFix ? 37.7955 : 0,
            longitude: hasFix ? -122.3937 : 0,
            locationName: hasFix ? "Embarcadero Center \u{00B7} Lot B" : "",
            locationAddress: hasFix ? "1 Embarcadero Ctr, San Francisco" : "",
            gearPosition: .p,
            chargeLevel: 64,
            estimatedRange: 174,
            interiorTemp: 58,
            exteriorTemp: 55,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            lastUpdated: ISO8601DateFormatter().string(from: Date())
        )
    }
}

// MARK: - Sources

/// Holds one fixed live-mapped snapshot. The two Home variants never show it
/// (`isConnecting` gates them), so it exists for the Drives variant's header.
@Observable
@MainActor
private final class DebugLoadingTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot
    init(snapshot: VehicleTelemetrySnapshot) { self.snapshot = snapshot }
    func start() {}
    func stop() {}
}

/// A drives feed whose first page never arrives: `isLoading` is permanently
/// true, with no rows and no status message, which is exactly the branch
/// `DrivesScreen.emptyHistoryContent` renders its skeleton from.
@Observable
@MainActor
private final class DebugLoadingDrivesFeed: DrivesFeed {
    let drives: [Drive] = []
    let isLoading = true
    let statusMessage: String? = nil
    let hasMore = false

    func loadInitial() {}
    func loadMore() {}
    func refresh() {}
    func drive(id: String) -> Drive? { nil }
    func routeCoordinates(driveID: String) async -> [CLLocationCoordinate2D] { [] }
}
#endif
