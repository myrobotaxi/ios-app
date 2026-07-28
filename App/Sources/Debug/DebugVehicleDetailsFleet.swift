#if DEBUG
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugVehicleDetailsFleet (MYR-279 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that boots the REAL owner Home sheet with a live-like
// snapshot so the vehicle-details section can be captured full-frame in the
// simulator without a live backend (the live path is auth-gated and
// non-deterministic). It renders the ACTUAL `VehicleControls`, driven by the
// SAME `VehicleContractMapping` the production live path uses — so the capture
// shows exactly what a real snapshot would render:
//
//   • Make/model = "2026 Model Y Performance" (composed from the snapshot's
//     year + model + trim — the client's bare "Model" bug, fixed).
//   • VIN = the full (owner-masked) VIN from the snapshot.
//   • Software = the Tesla software version from the snapshot.
//   • Color = HONEST empty ("— Unavailable") — onboarding doesn't write it yet
//     (MYR-283); we never fabricate a color.
//   • Tire pressure = HONEST "Available after your next drive" (TPMS is
//     uncontracted; a live-mapped row carries no fixture pressures).
//
// Release builds never compile this file; it is reachable ONLY via the
// `ownerVehicleDetails` debug scene, so the normal `ownerHome` scene (and every
// other path) is untouched and the simulated drift-gate stays identical.
/// The media shape a capture scene seeds onto the live-like snapshot (MYR-303 /
/// MYR-314, contracts 0.16.0). Each case is a REAL wire combination — the fields
/// are set on the `VehicleState` and then travel the production
/// `VehicleContractMapping.nowPlaying` + `LiveVehicleCommandExecutor.reconcile`
/// path, so a capture proves the shipping render rather than a hand-set view.
enum DebugMediaVariant {
    /// No media field at all — the pre-MYR-303 shape every existing scene keeps.
    /// The now-playing block hides (never observed) and, because there is no
    /// `mediaPlaybackStatus` either, the transport row is honestly gated.
    case neverObserved
    /// A real track playing, with a REAL duration + a sane elapsed → the passive
    /// progress line draws. Playback status `Playing` → the transport is live and
    /// the icon is the car's own state.
    case playingTrack
    /// The session ENDED: the car cleared the title to `""` (nothing playing) and
    /// stopped reporting a playback status. The block shows its honest idle line
    /// and the transport gates — the two halves of one real situation.
    case sessionEnded

    func apply(to state: inout VehicleState) {
        switch self {
        case .neverObserved:
            break
        case .playingTrack:
            state.mediaPlaybackStatus = .playing
            state.mediaVolume = 6.6            // 60% of the car's own ceiling
            state.mediaVolumeMax = 11
            state.mediaNowPlayingTitle = "Midnight City"
            state.mediaNowPlayingArtist = "M83"
            state.mediaNowPlayingAlbum = "Hurry Up, We\u{2019}re Dreaming"
            state.mediaPlaybackSource = "Spotify"
            state.mediaNowPlayingDurationMs = 244_000   // 4:04
            state.mediaNowPlayingElapsedMs = 92_000     // 1:32
        case .sessionEnded:
            // `""` — a REAL value meaning "nothing playing", not an absent field.
            state.mediaNowPlayingTitle = ""
            state.mediaNowPlayingArtist = ""
            state.mediaPlaybackSource = "Spotify"
            // No `mediaPlaybackStatus`: the car reports no session → gated.
            state.mediaVolume = 6.6
            state.mediaVolumeMax = 11
        }
    }
}

@Observable
@MainActor
final class DebugVehicleDetailsFleet: VehicleFleet {
    let vehicles: [Vehicle]
    private let source: DebugDetailsTelemetrySource
    private let executor: LiveVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    /// MYR-299 — when `ventedSeatReadBacks` is true the snapshot additionally
    /// carries the seat read-backs of
    /// a VENTILATED car with everything OFF: `seatCoolerLeft`/`seatCoolerRight` are
    /// present at `0` and `seatVentEnabled` is a deliberate `false`. That is the
    /// client's exact car, and it is precisely the combination the old predicate
    /// got wrong — so the capture exercises the shipping presence rule end to end
    /// (through the real `VehicleContractMapping`), not a fixture `seatVent` flag.
    /// MYR-286 — the owner-entered plate carried on the live-shaped snapshot AND
    /// the list row, exactly as a real server emits it (contracts 0.15.0). `nil`
    /// keeps the pre-MYR-286 shape (absent key), so every existing scene renders
    /// byte-identically; a value drives the plate through the REAL
    /// `VehicleContractMapping.plateDisplay` precedence and the REAL
    /// `LiveVehicleCommandExecutor.reconcile`, so a capture that shows the plate
    /// proves the shipping path does — not a hand-set field.
    /// MYR-313 — the badge status the summary carries. Defaults to `.parked` (every
    /// pre-existing scene is byte-identical); `.inService` is the client's exact
    /// MYR-313 condition — the car is in service TODAY while a reservation for
    /// Saturday waits on the owner's decision. It travels through the REAL
    /// `VehicleContractMapping.badgeStatus` fold, so the capture exercises the
    /// shipping predicate rather than a hand-set badge.
    /// MYR-308 — `seatCoolingCapable` is now the REAL contracts-0.16.0 SPEC field
    /// (Tesla REST `vehicle_config.has_seat_cooling`), not the old "seed vented
    /// read-backs" switch that borrowed the name before the field existed; that
    /// switch is now `ventedSeatReadBacks`. `nil` (the default) keeps every
    /// pre-existing scene on the MYR-299 presence heuristic, byte-identically. An
    /// explicit `false` alongside `ventedSeatReadBacks: true` is the precedence
    /// capture: the heuristic WOULD fire and the spec authoritatively overrules it.
    /// MYR-303/314 — `media` seeds the now-playing block + playback status, so the
    /// media card's live states are captureable through the real mapping/reconcile.
    private let badge: MRTVehicleStatus

    init(
        ventedSeatReadBacks: Bool = false,
        seatCoolingCapable: Bool? = nil,
        licensePlate: String? = nil,
        status: VehicleSummary.Status = .parked,
        media: DebugMediaVariant = .neverObserved
    ) {
        // A live-like snapshot: full model/year/trim, full VIN + software version,
        // and a BLANK color (onboarding gap, MYR-283). Streaming/online so the
        // footer honestly reads "Live".
        let state = Self.detailsState(
            ventedSeatReadBacks: ventedSeatReadBacks,
            seatCoolingCapable: seatCoolingCapable,
            licensePlate: licensePlate,
            media: media
        )
        let summary = VehicleSummary(
            vehicleId: "debug-mdy",
            name: "Model Y",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3456",
            status: status,
            chargeLevel: 71,
            estimatedRange: 193,
            lastUpdated: state.lastUpdated,
            role: .owner,
            licensePlate: licensePlate
        )
        // The REAL production mapping: the details rows read exactly what live
        // would render (composed model, snapshot VIN/software, honest color, no
        // fixture tires).
        vehicles = [VehicleContractMapping.vehicle(summary: summary, state: state)]
        badge = VehicleContractMapping.badgeStatus(from: status)
        source = DebugDetailsTelemetrySource(snapshot: VehicleContractMapping.snapshot(from: state))

        let exec = LiveVehicleCommandExecutor(
            vehicleID: summary.vehicleId,
            sender: DebugDetailsNoopSender(),
            // MYR-286 — the REAL §7.14 seam (normalize-then-validate, echo back),
            // so a Save in the scene exercises the shipping persist path.
            plateEndpoint: DebugPlateEndpoint(),
            driving: false,
            // The RAW plate (empty when unset) — `controls.plate` is the editable
            // value, not the `VIN ····xxxx` display fallback (MYR-286).
            plate: VehicleContractMapping.editablePlate(licensePlate: summary.licensePlate)
        )
        exec.reconcile(from: state)
        executor = exec
    }

    func telemetry(at index: Int) -> any VehicleTelemetrySource { source }
    func commandExecutor(at index: Int) -> any VehicleCommandExecutor { executor }
    func drivesFeed(at index: Int) -> any DrivesFeed { feed }
    func badgeStatus(at index: Int) -> MRTVehicleStatus { badge }

    func start() {}
    func stop() {}
    func setActive(index: Int) {}
    func handleForeground() {}
    func handleBackground() {}

    /// A parked, streaming `VehicleState` carrying the MYR-279 detail fields, plus
    /// (MYR-299, opt-in) the vented-car seat read-backs described on `init`.
    static func detailsState(
        ventedSeatReadBacks: Bool = false,
        seatCoolingCapable: Bool? = nil,
        licensePlate: String? = nil,
        media: DebugMediaVariant = .neverObserved
    ) -> VehicleState {
        let iso = ISO8601DateFormatter().string(from: Date())
        var state = VehicleState(
            vehicleId: "debug-mdy",
            name: "Model Y",
            model: "Model Y",
            year: 2026,
            color: "",                       // onboarding gap → honest empty (MYR-283)
            vin: "7SAYGDEE9RA123456",        // full (owner-masked) VIN
            softwareVersion: "2026.14.3",
            trim: "Performance",             // → "2026 Model Y Performance"
            status: .parked,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center · Lot B",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 71,
            estimatedRange: 193,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            // MYR-286 — snapshot-only by contract (§7.14: no WS delta ever carries
            // it), so the details capture is exactly the shape a cold read has.
            licensePlate: licensePlate,
            lastUpdated: iso
        )
        // MYR-308 — the REST-sourced seat SPEC field (contracts 0.16.0), absent by
        // default so every pre-existing scene keeps taking the MYR-299 heuristic.
        state.seatCoolingCapable = seatCoolingCapable
        if ventedSeatReadBacks {
            // Climate ON so `ClimateSection` renders `onContent` — the seat rows
            // only exist there (the off/unknown branches show the temp summary).
            state.isClimateOn = true
            state.fanSpeed = 3
            state.driverTempSetting = 70
            // Both seats OFF, but the cooler fields are PRESENT — the capability
            // signal. `seatVentEnabled: false` is deliberate: under the old
            // predicate this exact car read heat-only and Cool was unreachable.
            state.seatHeaterLeft = 0
            state.seatHeaterRight = 0
            state.seatCoolerLeft = 0
            state.seatCoolerRight = 0
            state.seatVentEnabled = false
        }
        media.apply(to: &state)
        return state
    }
}

// MARK: - DebugDetailsTelemetrySource

/// Holds one fixed live-mapped snapshot for the screenshot (streaming/online so
/// the freshness footer honestly reads "Live").
@Observable
@MainActor
private final class DebugDetailsTelemetrySource: VehicleTelemetrySource {
    private(set) var snapshot: VehicleTelemetrySnapshot
    init(snapshot: VehicleTelemetrySnapshot) { self.snapshot = snapshot }
    func start() {}
    func stop() {}
}

// MARK: - DebugDetailsNoopSender

/// Satisfies the executor's `sender` dependency; never actually invoked (the
/// screenshot path only reconciles, it doesn't send commands).
private struct DebugDetailsNoopSender: VehicleCommandSending {
    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        VehicleCommandResult(status: "ok", command: "noop", vin: nil)
    }
}
#endif
