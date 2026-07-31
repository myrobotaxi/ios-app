import DesignSystem
import Foundation
import MyRoboTaxiKit
import Observation

// MARK: - Owner home state (MYR-167; fleet seam MYR-201)
//
// Lives above the owner tab switch (app.jsx's `vehicleIdx`/`sheet` are
// App-level state, not HomeScreen-local — screens.jsx:369 HomeScreen just
// receives them as props) so the selected vehicle, sheet detent, and each
// vehicle's ticking telemetry survive switching to Drives/Share/Settings and
// back to Vehicle.
//
// MYR-201 moved the DATA (the fleet list + per-vehicle telemetry/command) behind
// the `VehicleFleet` seam: this object keeps the view-facing selection + detent,
// and delegates everything else to its injected fleet — `SimulatedVehicleFleet`
// (M1 default, offline) or `LiveVehicleFleet` (production telemetry). The choice
// is made at one composition point (`TelemetryComposition`, wired in `RootView`).

@Observable
@MainActor
public final class OwnerHomeState {
    public var selectedVehicleIndex: Int = 0
    public var sheetDetent: MRTSheetDetent = .peek

    /// MYR-292 — the id of the `completed` ride whose "Dropped off ✓" confirmation
    /// the owner has already seen (auto-dismissed after a beat, or acknowledged on a
    /// previous visit to Home). Read through
    /// `OwnerRideStatusLine.dispatchCardVisible`.
    ///
    /// It lives HERE, on the owner-scoped observable, and not in `HomeScreen`
    /// `@State`, for the same reason `selectedVehicleIndex`/`sheetDetent` do:
    /// `HomeScreen` is constructed inside a `switch ownerTab` branch of `RootView`,
    /// so a trip to Drives/Share/Settings DESTROYS the view. With the flag per-mount
    /// the acknowledgement was forgotten on every tab switch — the shared
    /// `rideRequestService.activeRequest` still held the `.completed` ride, so the
    /// banner came back and re-armed its auto-dismiss (MYR-292 defect 1) — and an
    /// auto-dismiss that landed AFTER the owner left wrote into torn-down `@State`
    /// storage and was lost entirely.
    ///
    /// Owner-local: this never touches the shared `activeRequest`, so the rider's
    /// Ride Summary is unaffected (MYR-267).
    public var acknowledgedCompletedRideID: String?

    /// MYR-315 — the freshness stamp's transient state (waking / acknowledged /
    /// notice). Owner-scoped for the same reason `acknowledgedCompletedRideID` is:
    /// `HomeScreen` is built inside a `switch ownerTab` branch of `RootView`, so a
    /// trip to Drives destroys the view — and a wake can easily outlive that. Held
    /// here, an in-flight "Waking Lunar…" is still in flight (and still resolves)
    /// when the owner comes back.
    public private(set) var refreshPhase: VehicleRefreshPhase = .idle

    /// Bumped whenever the owner taps the stamp. The stamp's label is derived from
    /// `Date()`, which SwiftUI has no reason to re-evaluate on its own for a car
    /// that isn't streaming; reading this in the stamp's body makes a tap
    /// re-render it, which IS the acknowledgement in the already-current case.
    public private(set) var refreshTick = 0

    /// In-flight guard: a second tap while a wake is running must not start a
    /// second §7.15 call (the endpoint would answer `429` and the owner would read
    /// their own double-tap as a failure).
    private var refreshTask: Task<Void, Never>?

    /// The fleet backend (simulated fixtures or live Kit). Internal to the app
    /// module — screens read the projected accessors below, not the fleet.
    let fleet: any VehicleFleet

    /// MYR-293 — the OWNER's road-route cache: the dispatched car → pickup leg
    /// drawn on the Home map, and the pickup → destination route previewed on the
    /// incoming-request card. The same `RideRouteStore` the rider's tracking map
    /// has used since MYR-177, with the same MKDirections source, the same 8s
    /// deadline, the same 6-decimal-place cache key and the same deviation-driven
    /// refetch — the owner surfaces simply never consumed it and drew literal
    /// two-point lines instead (the client's *"Fake route poly line rendered"*).
    ///
    /// It lives HERE, on the owner-scoped observable, for the reason
    /// `acknowledgedCompletedRideID` does: `HomeScreen` is built inside a
    /// `switch ownerTab` branch of `RootView`, so a trip to Drives DESTROYS the
    /// view — and a per-mount store would spend a fresh (throttle-budgeted)
    /// MKDirections call on every tab switch for a route it already had.
    ///
    /// `AppleRideRouteProvider` in BOTH modes, matching `SharedViewerState`'s own
    /// store verbatim (MYR-177, client-approved: "the route should be calculated
    /// by Apple Maps until the Tesla integration"). A simulated-only straight-line
    /// provider would mean these two surfaces could never PHOTOGRAPH the road
    /// route this issue adds — every capture would show the pins-only degradation
    /// — which is this repo's own "cold scenes passing while real paths fail"
    /// lesson pointed at a drift gate.
    @ObservationIgnored let rideRouteStore = RideRouteStore(provider: AppleRideRouteProvider())

    /// M1 default: the fixture-backed simulated fleet (no network).
    public init() {
        self.fleet = SimulatedVehicleFleet()
        #if DEBUG
        // Drift-gate: boot resting at half / on a chosen vehicle for the
        // at-rest captures only.
        if let detent = DebugScene.initialOwnerDetent { self.sheetDetent = detent }
        if let index = DebugScene.initialOwnerVehicleIndex { self.selectedVehicleIndex = index }
        #endif
    }

    /// Live / injected fleet (used by `TelemetryComposition` and tests).
    init(fleet: any VehicleFleet) {
        self.fleet = fleet
    }

    // MARK: Projected fleet accessors

    /// The fleet rows for the switcher. Empty while a live fleet is still
    /// loading (`isConnecting`).
    public var vehicles: [Vehicle] { fleet.vehicles }

    /// True while the live fleet is connecting (list load / first snapshot).
    /// Always false for the simulated fleet.
    public var isConnecting: Bool { fleet.isConnecting }

    /// A subtle status line when the fleet can't be shown (auth/unreachable),
    /// else `nil`. Design minimalism — surfaced quietly.
    public var statusMessage: String? { fleet.statusMessage }

    private var hasSelection: Bool { vehicles.indices.contains(selectedVehicleIndex) }

    /// The selected vehicle, or `nil` when the fleet has no rows yet (live,
    /// mid-connect). Non-nil for every simulated selection.
    public var selectedVehicle: Vehicle? {
        hasSelection ? vehicles[selectedVehicleIndex] : nil
    }

    public var selectedTelemetry: (any VehicleTelemetrySource)? {
        hasSelection ? fleet.telemetry(at: selectedVehicleIndex) : nil
    }

    public var selectedCommandExecutor: (any VehicleCommandExecutor)? {
        hasSelection ? fleet.commandExecutor(at: selectedVehicleIndex) : nil
    }

    /// The drive-history feed for the selected vehicle (MYR-203) — fixtures for
    /// the simulated fleet, the live cursor-paginated feed for the live fleet.
    /// The fleet guards an out-of-range index (live fleet mid-connect) with a
    /// detached empty feed, so this is safe before a selection exists.
    var selectedDrivesFeed: any DrivesFeed {
        fleet.drivesFeed(at: hasSelection ? selectedVehicleIndex : 0)
    }

    /// The design badge state (driving/parked/charging/offline) for the selected
    /// vehicle — `parked` neutral when there's no selection yet.
    public var selectedBadgeStatus: MRTVehicleStatus {
        hasSelection ? fleet.badgeStatus(at: selectedVehicleIndex) : .parked
    }

    /// MYR-277 — the fleet row index for a vehicle id, or `nil` when it isn't in
    /// the loaded fleet (a sim fixture ride's fleet id, or a live ride whose
    /// vehicle isn't loaded).
    func vehicleIndex(forID id: String) -> Int? {
        vehicles.firstIndex { $0.id == id }
    }

    /// MYR-277 C — the live badge status of the TARGET vehicle of an incoming
    /// request (joined by id), so the owner sheet can honestly gate Accept when the
    /// car is in_service/offline. `nil` when the vehicle isn't in the loaded fleet.
    func badgeStatus(forVehicleID id: String) -> MRTVehicleStatus? {
        vehicleIndex(forID: id).map { fleet.badgeStatus(at: $0) }
    }

    /// MYR-277 A2 — the telemetry source of the TARGET vehicle (for its live
    /// position, used to estimate the car→pickup leg). `nil` when not in the fleet.
    func telemetry(forVehicleID id: String) -> (any VehicleTelemetrySource)? {
        vehicleIndex(forID: id).map { fleet.telemetry(at: $0) }
    }

    // MARK: Lifecycle

    public func startTelemetry() {
        fleet.start()
        fleet.setActive(index: selectedVehicleIndex)
    }

    public func stopTelemetry() {
        fleet.stop()
    }

    /// Call when the switcher selection changes so the live fleet narrows its
    /// socket subscription to the new vehicle (no-op for sim).
    public func setActiveVehicle() {
        fleet.setActive(index: selectedVehicleIndex)
    }

    /// MYR-258 (§7.12) — drop a vehicle after its authoritative backend teardown.
    /// Delegates to the fleet (which releases the live source + re-narrows its own
    /// active subscription) and clamps the view-facing selection so the switcher /
    /// Settings list never point past the shortened fleet. Live-path only — the
    /// simulated fleet ignores removal (default no-op).
    public func removeVehicle(id: String) {
        fleet.remove(vehicleID: id)
        if !vehicles.indices.contains(selectedVehicleIndex) {
            selectedVehicleIndex = max(0, vehicles.count - 1)
        }
    }

    public func handleForeground() { fleet.handleForeground() }
    public func handleBackground() { fleet.handleBackground() }

    // MARK: Manual refresh (MYR-315)

    /// The owner tapped the freshness stamp.
    ///
    /// Three outcomes, decided by the PURE `VehicleFreshnessStamp.wakes` rule:
    ///   • already current (streaming, or read within the shared staleness
    ///     threshold) → acknowledge only. No §7.15 call: it would spend part of a
    ///     finite wake budget, or come back `429` from the endpoint's own cooldown,
    ///     to tell us what we already know.
    ///   • stale / never read → run the refresh with "Waking <name>…" showing,
    ///     because a wake takes seconds and a silent stamp reads as a dead tap.
    ///   • failure → the honest notice (asleep / cooldown / couldn't reach).
    ///
    /// On success the phase simply returns to `.idle`: the REFRESHED DATA arrives
    /// through the normal telemetry pipeline (the fleet re-fetches the snapshot and
    /// emits it on the vehicle's stream), so the stamp re-renders from the same
    /// source it always did rather than from this call's return value.
    public func refreshSelectedVehicle(now: Date = Date()) {
        guard refreshTask == nil else { return }
        refreshTick += 1

        let snapshot = selectedTelemetry?.snapshot
        guard VehicleFreshnessStamp.wakes(
            isStreaming: snapshot?.isStreaming,
            lastUpdated: snapshot?.lastUpdated,
            now: now
        ) else {
            refreshPhase = .acknowledged
            clearAcknowledgement()
            return
        }

        let index = selectedVehicleIndex
        guard let name = selectedVehicle?.name else { return }
        refreshPhase = .waking(name)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.fleet.refreshVehicle(at: index)
                self.refreshPhase = .idle
            } catch {
                self.refreshPhase = .notice(VehicleRefreshNotice.resolve(
                    commandFailureKind: Self.failureKind(for: error)))
            }
            self.refreshTask = nil
        }
    }

    /// How long the no-op acknowledgement holds the stamp before the resting
    /// recency line comes back.
    ///
    /// MYR-345 raised this from 0.9s. At 0.9 the acknowledgement was tuned for a
    /// state change nobody could see (it rendered no copy at all); now that it
    /// carries a sentence, the hold has to be long enough to READ one on a line
    /// the owner is not looking directly at. Still well under the 6s a settled
    /// notice gets (`LiveVehicleCommandExecutor.defaultNoticeDisplayDuration`) —
    /// nothing is wrong here, so it should not linger like something that is.
    public static let acknowledgementDisplayDuration: TimeInterval = 1.8

    /// Hold the no-op acknowledgement just long enough to register as a response,
    /// then fall back to the plain stamp. Guarded on the phase so a real refresh
    /// started in the meantime is never clobbered.
    private func clearAcknowledgement() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.acknowledgementDisplayDuration))
            guard let self, self.refreshPhase == .acknowledged else { return }
            self.refreshPhase = .idle
        }
    }

    /// Fold the Kit's typed §7.9 error catalog onto the slice this surface acts on.
    /// `RestError.commandFailureKind` is the ONE place these codes are interpreted —
    /// never the human message (FR-7.1).
    private static func failureKind(for error: Error) -> VehicleRefreshFailureKind {
        guard let restError = error as? RestError else { return .other }
        switch restError.commandFailureKind {
        case .vehicleAsleep: return .vehicleAsleep
        case .rateLimited: return .rateLimited
        // MYR-345 — the refusal arm, with the server's own reason token when it
        // named one. `commandRejectionReason` is already gated on
        // `commandFailureKind == .commandFailed`, so this is the ONE fold: the
        // typed catalog decides WHICH failure, and the closed token set decides
        // which refusal. Neither reads the human message as prose (FR-7.1).
        case .commandFailed: return .rejected(restError.commandRejectionReason)
        default: return .other
        }
    }

    #if DEBUG
    /// Drift-gate only: park the stamp in a given phase so the waking / notice
    /// states are capturable full-frame without a tap (headless tooling can't tap).
    func debugSeedRefreshPhase(_ phase: VehicleRefreshPhase) {
        refreshPhase = phase
    }
    #endif
}

// MARK: - Read-only linked-vehicles source (MYR-243)
//
// The narrow READ surface the Settings "Tesla Account" section consumes on the
// LIVE path: the owner's real vehicles from the authoritative fleet REST list,
// plus the honest connecting/notice signals — and nothing else. No mutation:
// set-primary / unlink have no backend contract (MYR-228), so the live section
// is display-only. `OwnerHomeState` already holds the started fleet for the
// owner shell, so Settings reads the SAME list that drives Home rather than a
// second fetch. `nil` on the sim / DEBUG path keeps the fixture-backed
// `OwnerVehiclesState` section pixel-identical (MYR-228 rule).
@MainActor
protocol LinkedVehiclesReading: AnyObject, Observable {
    var vehicles: [Vehicle] { get }
    var isConnecting: Bool { get }
    var statusMessage: String? { get }
}

extension OwnerHomeState: LinkedVehiclesReading {}
