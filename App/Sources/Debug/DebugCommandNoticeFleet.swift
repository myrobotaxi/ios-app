#if DEBUG
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - DebugCommandNoticeFleet (MYR-301 — drift-gate / screenshot only)
//
// A DEBUG-only fleet that boots the REAL owner Home sheet holding a REAL command
// notice, so the truncation fix and the re-link route are screenshot-verifiable
// without a live backend (a `permission_denied` needs a token that is missing a
// scope — not something a capture can arrange).
//
// It is built from the shipping path end to end: the production
// `LiveVehicleCommandExecutor`, seeded through the same `reconcile` a real
// snapshot uses, then driven with a REAL command against a sender that fails
// with the REAL §7.9 error. The notice on screen is therefore whatever
// `RestError.commandFailureKind` → `notice(for:key:)` actually produces — a
// capture that reads "Re-link" on the tile and the full sentence on the row
// proves the shipping mapping does too (same discipline as MYR-233's busy
// fleet-member capture).
//
//   • `.chargeRelink` — 403 `permission_denied` on `charge_port_door_open`, i.e.
//     the client's exact TestFlight bug: a token without `vehicle_charging_cmds`.
//     Tile sub "Re-link"; the row carries "Reconnect Tesla for charging access"
//     + the gold Reconnect pill.
//   • `.asleep`       — 503 `vehicle_asleep` that survives the wake retry, on the
//     Lock tile. Tile sub "Asleep"; row "Car is asleep — try again shortly"
//     (MYR-301's 502-vs-503 split; no action — it resolves itself).
//   • `.seatRelink`   — the same 403 on a seat command, to capture the in-place
//     notice line inside the Climate card (the surface that already had room for
//     the full message and now also carries the route).
//   • `.climateRejected` — 502 `command_failed` on `auto_conditioning_stop`: the
//     client's OTHER reported bug, "The car didn't accept that" stuck on screen
//     forever. This variant is the LIFECYCLE capture rather than a copy capture —
//     the notice now clears itself after
//     `LiveVehicleCommandExecutor.defaultNoticeDisplayDuration`, so capture at
//     t≈2s (banner up) and t≈8s (gone), the same two-shot pattern
//     `ownerDispatchedCompleted` uses for the 5s "Dropped off ✓" dismissal.
//   • `.climateRejectedInService` — MYR-329, the SAME 502 on the SAME command,
//     with the server naming the cause: `message` carries the canonical token
//     `vehicle_in_service` (rest-api.md §7.9). The capture reads
//     "Car is in service — commands are limited" instead of the generic line,
//     and it is a genuine before/after against `.climateRejected`, which keeps
//     `message: nil` and stays byte-identical. This is the client's Jul 28
//     situation exactly: he asked whether a low battery was the cause because
//     the generic copy gave him nothing else to reason from. No other capture
//     route exists — it needs a car actually sitting in service mode behind a
//     real auth session, refusing a real command.
//
// NOTE (MYR-301, this round) — that bounded display applies to the three variants
// above too: they settle a REAL notice, and a real settled notice no longer lives
// forever. Take their captures inside the display window.
//
// Release builds never compile this file; it is reachable ONLY via the
// `ownerNoticeCharge` / `ownerNoticeAsleep` / `ownerNoticeSeat` debug scenes, so
// every other path — including the simulated drift-gate scenes — is untouched.
enum DebugCommandNoticeVariant {
    case chargeRelink, asleep, seatRelink, climateRejected
    // MYR-329 — the named rejection. Separate from `.climateRejected` so that
    // scene stays pixel-identical for the MYR-301 lifecycle capture.
    case climateRejectedInService
}

@Observable
@MainActor
final class DebugCommandNoticeFleet: VehicleFleet {
    let vehicles: [Vehicle]
    private let source: DebugClimateTelemetrySource
    private let executor: LiveVehicleCommandExecutor
    private let feed = SimulatedDrivesFeed()

    var isConnecting: Bool { false }
    var statusMessage: String? { nil }

    init(variant: DebugCommandNoticeVariant) {
        let vehicle = VehicleFixtures.vehicles[0]
        vehicles = [vehicle]

        let readAt = Date()
        // Reuse the populated live-like snapshot the climate capture scene uses,
        // so the sheet reads as a real car and the ONLY new thing on screen is
        // the notice (reuse, don't fork — CLAUDE.md).
        source = DebugClimateTelemetrySource(lastUpdated: readAt)

        let exec = LiveVehicleCommandExecutor(
            vehicleID: vehicle.id,
            sender: DebugFailingCommandSender(error: Self.error(for: variant)),
            plateEndpoint: DebugPlateEndpoint(),
            // MYR-316 — never exercised in these scenes (none is in service), but
            // the seam is required; the stub keeps the executor total.
            serviceWindowEndpoint: DebugServiceWindowEndpoint(),
            // MYR-342 — the §7.18 seam. These scenes never flip the switch, so it
            // is only here to keep the executor's seam total; the row itself is
            // live-only and none of them render it.
            rideShareEndpoint: DebugRideShareEndpoint(),
            driving: false,
            plate: vehicle.plate,
            wakeRetryDelay: .zero,
            // The asleep capture needs the retry to be EXHAUSTED (that is the
            // state that used to lie with "Waking the car…"), so no retry here.
            maxWakeRetries: 0
        )
        exec.reconcile(
            from: DebugClimateModeFleet.climateState(variant: .auto, lastUpdated: readAt),
            snapshotReadIssuedAt: Date()
        )
        executor = exec

        // Drive the real command; the scripted failure settles the real notice
        // within a run-loop turn, long before any screenshot is taken.
        Task { @MainActor in
            switch variant {
            case .chargeRelink: try? await exec.setChargePortOpen(true)
            case .asleep: try? await exec.setLocked(false)
            case .seatRelink: try? await exec.setSeatHeatLevel(.driver, level: 3)
            // The client's own action: turning climate OFF, and the car saying no.
            case .climateRejected, .climateRejectedInService: try? await exec.setClimateOn(false)
            }
        }
    }

    /// The REAL §7.9 wire error each variant provokes.
    private static func error(for variant: DebugCommandNoticeVariant) -> RestError {
        switch variant {
        case .chargeRelink, .seatRelink:
            return .http(status: 403, code: ErrorPayload.Code(rawValue: "permission_denied"), message: nil, subCode: nil)
        case .asleep:
            return .http(status: 503, code: ErrorPayload.Code(rawValue: "vehicle_asleep"), message: nil, subCode: nil)
        // 502 `command_failed` — we REACHED the car and it refused (MYR-301's
        // rejection branch, `.rejected`).
        case .climateRejected:
            return .http(status: 502, code: ErrorPayload.Code(rawValue: "command_failed"), message: nil, subCode: nil)
        // MYR-329 — the same 502, with the server naming the cause. The message
        // is the REAL wire sentence `commandFailedMessage` builds server-side
        // (internal/commands/reject_reason.go), so the capture exercises the
        // shipping `RestError.commandRejectionReason` parse rather than a
        // hand-set notice.
        case .climateRejectedInService:
            return .http(
                status: 502,
                code: ErrorPayload.Code(rawValue: "command_failed"),
                message: "vehicle command failed: vehicle_in_service",
                subCode: nil
            )
        }
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
}

// MARK: - DebugFailingCommandSender

/// Fails every command with one fixed `RestError`, so the executor's REAL error
/// mapping produces the notice under capture.
private struct DebugFailingCommandSender: VehicleCommandSending {
    let error: RestError

    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        throw error
    }
}
#endif
