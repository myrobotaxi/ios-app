import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - LiveVehicleCommandExecutor (MYR-249 — P11 owner actuation, MYR-181–183)
//
// The live `VehicleCommandExecutor`: every owner control that maps to a real §7.9
// Tesla command routes through the backend command endpoint (via the Kit's
// `VehicleCommandSending`); the few controls with no backend command stay local
// mutations, flagged below. This is the executor `LiveVehicleFleet` now injects in
// place of the simulated one (P11 is ready as of MYR-249; phase 3 added charge
// port, seat climate, and media once backend v186 registered them).
//
// Backend-backed (real command sent, then optimistic state on ack):
//   • lock tile          → door_lock / door_unlock
//   • climate on/off     → auto_conditioning_start / auto_conditioning_stop
//   • climate mode: Auto → auto_conditioning_start (returns the car to auto climate,
//                          MYR-274). Cool/Heat are NOT commandable (see below).
//   • set temp ±         → set_temps (driver_temp °C; passenger mirrors)
//   • trunk tile         → actuate_trunk (rear)
//   • charge port tile   → charge_port_door_open / charge_port_door_close (v186;
//                          scope `vehicle_charging_cmds` — a token without it
//                          surfaces `.relinkCharging`)
//   • seat heat/cool     → remote_seat_heater_request (level 0–3) OR
//                          remote_seat_cooler_request (seat_cooler_level 1–4),
//                          chosen by the seat's current mode; the heater/cooler
//                          asymmetry lives in the Kit's seat factories
//   • media play/pause   → media_toggle_playback
//   • media prev/next    → media_prev_track / media_next_track
//   • volume slider      → adjust_volume (0–11; immediate-local + coalesced send —
//                          a continuous slider can't await a round trip per delta,
//                          so it applies at once and best-effort-sends the latest,
//                          with no per-tile spinner/notice surface)
//
// NO backend command in the §7.9 catalog (flagged — kept as a local mutation to
// preserve the control's feel):
//   • climate mode Cool/Heat → no set-mode command; Tesla's API cannot FORCE a
//                          manual cool/heat mode, so these segments are honest
//                          DISPLAY-ONLY reflections of the car's reported mode — a
//                          tap sends NOTHING (MYR-274). Only Auto is actionable.
//   • fan speed          → no fan command
//   • media scrub        → no seek-to-position command (local feedback only)
//
// NOT a Tesla command, but a REAL backend write (MYR-286):
//   • license plate      → `PUT /api/tesla/vehicles/{id}/plate` (§7.14) via the
//                          Kit's `VehiclePlateEndpoint`. Tesla has no plate field
//                          anywhere, so this is a local owner-scoped DB write —
//                          no proxy, no Tesla token, no wake, no virtual key.
//                          Before MYR-286 `setPlate` wrote only to memory and the
//                          edit sheet silently discarded the owner's input.
//
// UX (per MYR-249 task 3): a tap sets the control PENDING (double-tap suppressed
// by the pending guard); the value flips only once the command is acknowledged
// (optimistic-on-ack — the next telemetry frame remains authoritative); an error
// maps to an honest `VehicleCommandNotice` (charge-port `permission_denied` names
// the charging scope). `vehicle_asleep` (503) keeps the control pending with
// "Waking the car…" and retries once with backoff, reflecting that the server
// itself woke+retried (§7.9); if the retry ALSO comes back asleep the notice
// settles as `.asleep` ("Car is asleep — try again shortly"), which is neither a
// still-running wake nor the 502 rejection's copy (MYR-301).
//
// SAFETY: this type is only ever constructed on the LIVE path (`LiveVehicleFleet`,
// built only for a live `AppMode`); the simulated demo never touches it. Tests
// drive it with a fake `VehicleCommandSending` — never a real token.
@Observable
@MainActor
final class LiveVehicleCommandExecutor: VehicleCommandExecutor {
    private(set) var controls: VehicleControlsSnapshot
    private var uiStates: [VehicleControlKey: VehicleControlUIState] = [:]

    /// The controls whose displayed value is CONFIRMED — i.e. the owner has
    /// commanded them and the car acknowledged (optimistic-on-ack), or they are
    /// local-only settings the owner has touched. Everything else renders as an
    /// honest unknown ("—") rather than the seeded fixture (MYR-228 / MYR-251).
    /// The `VehicleState` contract carries none of these actuator states today
    /// (see `VehicleControlField`), so nothing is confirmed until the owner acts.
    private var knownFields: Set<VehicleControlField> = []

    /// MYR-351 — when each SNAPSHOT-ONLY field was last committed by an owner
    /// write whose echo we adopted. Consulted by ``acceptsSnapshotRead(_:issuedAt:)``
    /// and by nothing else.
    ///
    /// Only the three snapshot-only fields (`.plate`, `.serviceWindow`,
    /// `.rideShare`) ever appear here, and the reason is the property they share:
    /// none of them has a WebSocket delta, so a write echo is the ONLY way this
    /// client can hold their current value between cold reads. A streamed control
    /// needs no such ledger — the car re-states it on the next frame, and MYR-249's
    /// rule that telemetry OVERRIDES an optimistic value is correct precisely
    /// because that frame is a genuinely fresh observation.
    private var committedAt: [VehicleControlField: Date] = [:]

    /// MYR-362 — the owner's own stored `expectedEndAt`, held from a service-window
    /// write until the first read ISSUED after it can say which source won.
    ///
    /// The source is a comparison between what the OWNER stored and what the server
    /// RESOLVES, and §7.16 hands a client only the first of those: its `200` echoes
    /// the owner column precisely so a write is never mistaken for an overrule. So
    /// the write has nothing to compare and the comparison has to wait for
    /// `COALESCE(service_etc, service_expected_end_at)` to arrive on §7.0 / §7.1 —
    /// which is the ONLY place either answer was ever provable.
    ///
    /// `nil` means nothing is outstanding: no write yet, a CLEAR (which submits no
    /// instant, so there is nothing to be the source OF), or a classification
    /// already consumed. Consumed exactly ONCE, by the first accepted read, so a
    /// later read that MOVES the value falls through to MYR-320's own rule and
    /// resets to `.unknown` rather than re-asserting a stale claim.
    private var pendingServiceWindowProvenance: Date?

    private let vehicleID: String
    private let sender: any VehicleCommandSending
    /// The §7.14 owner license-plate write (MYR-286). Deliberately a SEPARATE seam
    /// from `sender`: §7.14 is a local owner-scoped DB write with no Tesla call in
    /// it, so it can never be asleep, unpaired, or refused by the car — sharing
    /// the command seam would drag that vocabulary onto a path that cannot produce
    /// it (see `plateNotice(for:)`).
    private let plateEndpoint: any VehiclePlateEndpoint
    /// MYR-316 — the owner "expected back" write seam. Separate from
    /// `plateEndpoint` (rather than one "owner writes" endpoint) so each stays a
    /// one-method protocol a test can stub in isolation, matching the narrowing
    /// every other seam in this file uses.
    private let serviceWindowEndpoint: any VehicleServiceWindowEndpoint
    /// MYR-342 — the §7.18 owner ride-share write seam. Separate again, for the
    /// same narrowing reason: one method, stubbable in isolation. It is NOT folded
    /// into `serviceWindowEndpoint` even though both are §7.1x owner-scoped writes
    /// with the same error catalog, because the two can be in flight independently
    /// and their failures say different things to an owner.
    private let rideShareEndpoint: any VehicleRideShareEndpoint

    /// Fired with the SERVER-NORMALIZED plate after a successful §7.14 write, so
    /// the owner's fleet row can adopt it immediately. There is no WS delta for
    /// this field (§7.14) — without this hook the switcher / Settings rows would
    /// keep showing the old plate until the next `GET /api/vehicles`. Set by
    /// `LiveVehicleFleet`; nil elsewhere.
    var onPlateSaved: ((String) -> Void)?
    /// MYR-316 — fired with the server's RESOLVED window after a successful write,
    /// for the same reason `onPlateSaved` exists: this field has no WS delta
    /// (snapshot-only by contract), so without this hook the owner's fleet row and
    /// the rider-facing summary would keep the stale value until the next
    /// `GET /api/vehicles`. Set by `LiveVehicleFleet`; nil elsewhere.
    var onServiceWindowSaved: ((Date?) -> Void)?
    /// MYR-342 — fired with the server's RESOLVED ride-share position after a
    /// successful §7.18 write, for the same reason the two hooks above exist:
    /// rest-api.md §7.18 states plainly that "a ride-share edit fires no
    /// `vehicle_update` frame", so without this hook the owner's fleet row — and
    /// therefore the RIDER-facing `LiveFleetMemberMapping` built from it — would
    /// keep showing the car as bookable until the next `GET /api/vehicles`. That is
    /// the one of the three where staleness is not merely cosmetic: it is a rider
    /// being offered a car whose owner has just withdrawn it, and a `409
    /// vehicle_unavailable` waiting at the end of the request they fill in.
    /// Set by `LiveVehicleFleet`; nil elsewhere.
    var onRideShareSaved: ((Bool) -> Void)?
    /// Backoff before the single `vehicle_asleep` retry (injectable → `.zero` in
    /// tests for determinism; ~2 s in production, matching the §7.9 wake curve).
    private let wakeRetryDelay: Duration
    private let maxWakeRetries: Int
    /// MYR-301 — how long a SETTLED notice stays on screen before clearing itself.
    /// See ``settle(_:notice:)``.
    private let noticeDisplayDuration: Duration
    /// Per-key monotonic stamp for the settled notice currently on screen, so an
    /// expiry can tell "still mine" from "a newer failure replaced me" without
    /// holding (and having to cancel) a task handle per control.
    private var noticeGeneration: [VehicleControlKey: Int] = [:]
    private let trackCount = 3

    /// One-in-flight coalescer for the volume slider (`adjust_volume`): while a
    /// send is outstanding the newest drag value is stashed and sent when it
    /// settles, so a drag fires the first + last value (not every delta) without
    /// blocking the thumb. Best-effort — a slider has no spinner/notice surface.
    private var volumeSending = false
    private var pendingVolume: Double?
    /// MYR-303 — the car's last-reported `mediaVolumeMax` (contracts 0.16.0), the
    /// ceiling BOTH directions scale against: wire→UI in `reconcile` and UI→wire in
    /// `sendVolume`. `nil` until the car streams one (it is near-constant per
    /// vehicle and changes far less often than the level itself), and the fallback
    /// is Tesla's usual 11 — treated as the assumption it is, not as a contract.
    private var observedVolumeMax: Double?

    /// Settle-window guard for the commanded boolean toggles (climate/lock/trunk/
    /// charge-port). The in-flight `isPending` guard only protects UNTIL the command
    /// acks — but the car keeps streaming the OLD state for a few seconds AFTER the
    /// ack until it actually reflects the change. Once MYR-272 folds these fields on
    /// every live delta, that stale frame lands ~1s after the ack and clobbers the
    /// optimistic value back (client: "turned climate off, it loaded then showed On
    /// again"). After a command acks we record the COMMANDED value + a deadline;
    /// reconcile ignores a DISAGREEING streamed value for that key until it confirms
    /// (agrees) or the deadline passes (then we accept the car's reported reality —
    /// honest, e.g. a service center keeping HVAC on). Mirrors the volume coalescer.
    private var settleHold: [VehicleControlKey: (want: Bool, until: Date)] = [:]
    private let settleWindow: TimeInterval

    /// Seat-climate settle-window guard (MYR-280), the two-field analogue of
    /// `settleHold`: a seat's committed state is (mode, level), not a bool. After a
    /// seat command acks we record the commanded (mode, level) + a deadline;
    /// `reconcileSeat` ignores a DISAGREEING streamed frame for that seat until the
    /// car confirms it or the deadline lapses — so a stale WS frame (the level the
    /// car streamed a second ago, or a heater read-back arriving after we switched
    /// to cool) can't clobber the optimistic seat state, exactly as MYR-272 fixed
    /// for the boolean toggles.
    private var seatSettleHold: [VehicleControlKey: (mode: VehicleSeatClimateMode, level: Int, until: Date)] = [:]

    /// The Auto command's outstanding CONFIRMATION (MYR-274 window, MYR-466
    /// verdict). Tapping Auto commands `auto_conditioning_start`; after it acks we
    /// optimistically show `.auto` and record the deadline here.
    /// `reconcileClimateMode` then ignores a DISAGREEING streamed mode (a stale
    /// `Override` the car keeps reporting for a second or two) until the car
    /// confirms `On`/Auto or the window lapses — as MYR-272 fixed for the boolean
    /// toggles.
    ///
    /// MYR-466 — what changed is the LAPSED arm. It used to drop the hold and
    /// silently adopt the car's mode, which is how a tap on Auto became a segment
    /// that flipped back to Cool with nothing said. It is now a
    /// `ClimateAutoVerdict.notAdopted`: the car's mode is still adopted (it is the
    /// truth) and the owner is told why the segment moved.
    private var climateAutoPending: ClimateAutoConfirmation.Pending?

    /// MYR-467 — what the media truth rule remembers between frames: the last
    /// position sample, the last wire status, and whether the position has
    /// recently contradicted a `Paused`. See `MediaPlaybackTruth`.
    private var mediaMemory: MediaPlaybackMemory = .empty

    init(
        vehicleID: String,
        sender: any VehicleCommandSending,
        plateEndpoint: any VehiclePlateEndpoint,
        serviceWindowEndpoint: any VehicleServiceWindowEndpoint,
        rideShareEndpoint: any VehicleRideShareEndpoint,
        driving: Bool,
        plate: String,
        wakeRetryDelay: Duration = .seconds(2),
        maxWakeRetries: Int = 1,
        settleWindow: TimeInterval = 15,
        noticeDisplayDuration: Duration = LiveVehicleCommandExecutor.defaultNoticeDisplayDuration
    ) {
        self.vehicleID = vehicleID
        self.sender = sender
        self.plateEndpoint = plateEndpoint
        self.serviceWindowEndpoint = serviceWindowEndpoint
        self.rideShareEndpoint = rideShareEndpoint
        self.wakeRetryDelay = wakeRetryDelay
        self.maxWakeRetries = maxWakeRetries
        self.settleWindow = settleWindow
        self.noticeDisplayDuration = noticeDisplayDuration
        // Seed identical to the simulated executor, but on the live path these
        // values are NEVER displayed until `knownFields` confirms them (MYR-251):
        // they only serve as the optimistic base a command mutates. The UI reads
        // `isKnown(_:)` and shows "—" for every field the owner hasn't yet
        // commanded, so no fixture value ever renders on the live path (MYR-228).
        controls = VehicleControlsSnapshot(
            locked: true,
            climateOn: true,
            targetTemp: 70,
            climateMode: .auto,
            fanSpeed: 3,
            driverSeatHeatLevel: 2,
            driverSeatMode: .heat,
            passengerSeatHeatLevel: 0,
            passengerSeatMode: .heat,
            trunkOpen: false,
            chargePortOpen: false,
            mediaPlaying: driving,
            trackIndex: 0,
            volume: 45,
            scrubPercent: 38,
            plate: plate
        )
    }

    // MARK: Command UX seam

    func uiState(for key: VehicleControlKey) -> VehicleControlUIState {
        uiStates[key] ?? .idle
    }

    // MARK: - Notice lifecycle (MYR-301 — the stuck banner)
    //
    // THE DEFECT this section fixes, reported from the client's device: the
    // `.rejected` climate notice ("The car didn't accept that") stayed up
    // indefinitely. A settled notice had exactly ONE clearing trigger — issuing
    // another command for the SAME control, which sets the key pending with
    // `notice: nil` — and no expiry at all. `reconcile(from:)` never touched
    // notices. So an owner who tapped once, was refused once, and did not tap
    // again kept a failure banner about a moment that had long passed.
    //
    // THE TWO RULES SHIPPED, both of which had to exist because either alone
    // leaves a real hole:
    //
    //   1. BOUNDED DISPLAY. Every settled notice clears itself after
    //      ``defaultNoticeDisplayDuration``. A notice is a report about ONE
    //      attempt, not a persistent status: the fact it describes stops being
    //      true the moment the owner could act on it again. This follows the
    //      repo's own banner precedent — the owner's "Dropped off ✓" confirmation
    //      auto-dismisses after 5s (`HomeScreen.scheduleDroppedOffDismiss`,
    //      MYR-292) — with a slightly longer window because a notice carries a
    //      SENTENCE to read (and sometimes a "Reconnect" pill to reach) rather
    //      than a three-word confirmation.
    //   2. RECONCILE CLEARS. When the car reports where a control ACTUALLY is,
    //      the notice about a failed attempt to move it is answered, and goes at
    //      once rather than waiting out the window. Without this the owner can be
    //      looking at a live, correct, reconciled tile with a stale failure line
    //      underneath it.
    //
    // The expiry deliberately lives HERE, on the executor, and never in a view:
    // the executor is owned by `LiveVehicleFleet` and outlives `HomeScreen`, so a
    // notice survives a tab switch (it is not re-armed or wiped by a remount) and
    // an expiry that fires while nothing is mounted still lands in live storage.
    // That is the MYR-292 lesson — an auto-dismiss written into torn-down `@State`
    // is a banner that comes back — applied to this surface.

    /// How long a settled notice stays on screen. 6s: long enough to read the
    /// longest message in the catalog and reach a 44pt "Reconnect" pill, short
    /// enough that it cannot become furniture. Sits alongside MYR-292's 5s
    /// confirmation rather than diverging from it.
    static let defaultNoticeDisplayDuration: Duration = .seconds(6)

    /// Settle `key` on `notice` and arm its bounded display.
    ///
    /// Every settled (non-pending) notice goes through here, so there is exactly
    /// one place the expiry rule is applied and no failure path can accidentally
    /// opt out of it. In-flight notices (`.waking`) are NOT settled and never pass
    /// through: they resolve with the command they belong to.
    /// MYR-360 — the protocol's notice seam, routed into `settle` and nothing else.
    ///
    /// It exists so the pause flow's failures (a reservation that would not decline,
    /// a reservation list that would not load) land on the ride-share row through
    /// the SAME path a failed §7.18 write does, rather than through a second notice
    /// surface with its own lifetime. `settle`'s shape, generation guard and 6s
    /// window are untouched — this adds a caller, not a rule.
    func raiseNotice(_ notice: VehicleCommandNotice, for key: VehicleControlKey) {
        settle(key, notice: notice)
    }

    private func settle(_ key: VehicleControlKey, notice: VehicleCommandNotice) {
        let generation = (noticeGeneration[key] ?? 0) + 1
        noticeGeneration[key] = generation
        uiStates[key] = VehicleControlUIState(isPending: false, notice: notice)
        let duration = noticeDisplayDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            // Still the notice we armed for? A newer failure (or a new command)
            // bumps the generation and owns the surface from then on.
            guard let self, self.noticeGeneration[key] == generation else { return }
            self.clearNotice(key, force: true)
        }
    }

    /// Drop `key`'s settled notice. A no-op while a command is in flight — that
    /// notice belongs to the running attempt (`.waking`) and is cleared by it.
    ///
    /// MYR-466 — `force` is the bounded-display expiry's own door, and one notice
    /// needs it. `.autoNotAdopted` is the first notice in this catalog that is
    /// RAISED BY a reconcile rather than by a failed round trip, so MYR-301's
    /// clear path 2 ("the car just told us where the control really is, which
    /// answers the notice") is pointed at the very frame that earned it. Left
    /// unguarded it is wiped within a second by the NEXT frame — through the
    /// `.climate` key's climate-on arm, which reconciles ahead of the mode and
    /// clears the shared key — and the owner is back to a segment that moved with
    /// no explanation. It is left to its 6s window and to the next command on the
    /// key (`beginPending` replaces the state outright), which are the two
    /// lifetimes MYR-301 gives every settled notice.
    private func clearNotice(_ key: VehicleControlKey, force: Bool = false) {
        guard let state = uiStates[key], let notice = state.notice, !state.isPending else { return }
        if !force, notice == .autoNotAdopted { return }
        noticeGeneration[key] = (noticeGeneration[key] ?? 0) + 1
        uiStates[key] = VehicleControlUIState(isPending: false, notice: nil)
    }

    /// Take `key` pending for a new attempt, disowning any expiry still armed for
    /// the notice this attempt replaces. (Without the bump, a late expiry from the
    /// PREVIOUS failure could fire during the new attempt; it would be a no-op
    /// today, but only by accident of ordering.)
    private func beginPending(_ key: VehicleControlKey) {
        noticeGeneration[key] = (noticeGeneration[key] ?? 0) + 1
        uiStates[key] = VehicleControlUIState(isPending: true, notice: nil)
    }

    /// MYR-251 — a live control's value is only KNOWN once the owner has
    /// commanded it (optimistic-on-ack) or touched a local-only setting. Until
    /// then the UI shows an honest "—" instead of the seeded placeholder, because
    /// the `VehicleState` contract carries no actuator state today.
    func isKnown(_ field: VehicleControlField) -> Bool {
        knownFields.contains(field)
    }

    // MARK: Telemetry reconciliation (MYR-252 — v0.12.0 cabin read-back)
    //
    // The v0.12.0 `VehicleState` now carries the owner-actuator state as OPTIONAL
    // fields. Each field PRESENT on the wire reconciles its control to the car's
    // REAL value and marks it KNOWN (`isKnown` → true), so the tile stops showing
    // "—" and shows true state; each field ABSENT stays honestly unknown — never a
    // fixture (MYR-228 / MYR-251). Telemetry is authoritative and OVERRIDES the
    // optimistic-on-ack value a prior command applied (MYR-249): a command ack
    // shows the optimistic state, the next telemetry frame confirms/corrects it.
    // The one exception is a control whose command is still in flight (pending) —
    // its value is left for the ack + next frame so the tile doesn't flicker
    // mid-command.
    //
    // Called on every cold snapshot and every folded delta via the Kit's
    // `LiveVehicleState.onStateChanged` hook (wired in `LiveVehicleFleet`).
    //
    // MYR-351 — `snapshotReadIssuedAt` is when the `/snapshot` GET behind this
    // state's SNAPSHOT-ONLY fields was ISSUED. It is what the three arms at the
    // bottom of this method consult before adopting, and the reason the whole
    // parameter exists; every other arm ignores it (see `acceptsSnapshotRead`).
    func reconcile(from state: VehicleState, snapshotReadIssuedAt: Date) {
        // Climate on/off — use the server-DERIVED `isClimateOn` ONLY. The backend
        // OMITS it (→ nil) when `hvacPower` is "Unknown", so an absent value stays
        // honestly unknown; the raw `hvacPower` "Unknown" must NEVER read as
        // climate-on (MYR-251/252 honesty fix). We deliberately do not consult
        // `state.hvacPower` here.
        if let on = state.isClimateOn {
            reconcileControlled(.climateOn, key: .climate, wire: on) { self.controls.climateOn = $0 }
        }

        if let locked = state.locked {
            reconcileControlled(.locked, key: .lock, wire: locked) { self.controls.locked = $0 }
        }

        // Single target-temp tile mirrors the DRIVER setpoint (matches
        // `setTargetTemp`, which commands `driver_temp`). Passenger setpoint is on
        // the wire (`passengerTempSetting`) but has no separate tile.
        if let temp = state.driverTempSetting {
            reconcileField(.targetTemp, key: .temp) { self.controls.targetTemp = min(82, max(60, temp)) }
        }

        if let fan = state.fanSpeed {
            reconcileField(.fanSpeed, key: nil) { self.controls.fanSpeed = min(10, max(0, fan)) }
        }

        // Climate mode (Auto/Cool/Heat) — reconcile the car's REAL mode onto the
        // segment and mark it known, honoring the in-flight/settle discipline so a
        // stale frame can't clobber a just-commanded Auto (MYR-274).
        reconcileClimateMode(autoMode: state.hvacAutoMode, acEnabled: state.hvacAcEnabled)

        reconcileSeat(.driver, key: .driverSeat, heater: state.seatHeaterLeft, cooler: state.seatCoolerLeft)
        reconcileSeat(.passenger, key: .passengerSeat, heater: state.seatHeaterRight, cooler: state.seatCoolerRight)

        if let trunk = state.trunkOpen {
            reconcileControlled(.trunkOpen, key: .trunk, wire: trunk) { self.controls.trunkOpen = $0 }
        }

        if let port = state.chargePortDoorOpen {
            reconcileControlled(.chargePortOpen, key: .chargePort, wire: port) { self.controls.chargePortOpen = $0 }
        }

        // Media playback — the enum carries an explicit `.unknown`; treat it (and
        // any unrecognized value) as honestly unknown, never a fabricated play/pause.
        //
        // MYR-314 — this arm is now the media SESSION gate as well as the icon's
        // source, and it is deliberately SYMMETRIC: a known status marks the field
        // known (transport enabled, icon = the car's real state), and an absent /
        // `Unknown` / unrecognized status UN-knows it again (transport disabled,
        // "Start media in the car first"). Insert-only known-ness would latch: the
        // gate would open on the first session and never close when the owner
        // stopped media in the car, leaving live-looking transport buttons that
        // command nothing. The optimistic post-ack value is protected by the same
        // settle window the boolean toggles use, so a stale frame can't flicker the
        // icon back mid-command (MYR-272 discipline).
        //
        // MYR-467 — the status is no longer read straight off the wire. The
        // external-beta report was a transport row asserting PAUSED while the
        // track position advanced ten seconds underneath it, because
        // `mediaPlaybackStatus` and `mediaNowPlayingElapsedMs` are independent
        // Tesla emissions and a delta carrying only the position folds the old
        // status forward verbatim. `MediaPlaybackTruth` enforces the invariant
        // the issue asked for — a position that advances is not a paused car —
        // and owns the memory that keeps the correction from flickering on the
        // frames that carry no media news. It never fabricates a session: an
        // absent / `Unknown` status still un-knows the field below, exactly as
        // MYR-314 requires.
        let mediaVerdict = MediaPlaybackTruth.resolve(
            wire: state.mediaPlaybackStatus,
            track: MediaTrackIdentity(state: state),
            positionMs: state.mediaNowPlayingElapsedMs,
            memory: mediaMemory
        )
        mediaMemory = mediaVerdict.memory
        if let playing = mediaVerdict.playing {
            reconcileControlled(.mediaPlaying, key: .media, wire: playing) { self.controls.mediaPlaying = $0 }
        } else {
            knownFields.remove(.mediaPlaying)
            settleHold[.media] = nil
        }

        // Media volume — wire 0…`mediaVolumeMax` (fractional) → UI 0–100. Skip while
        // the slider's own coalescer has a send outstanding so a live frame can't
        // yank the thumb out from under a drag.
        //
        // MYR-303 — the ceiling is the car's OWN `mediaVolumeMax` (contracts
        // 0.16.0) when it has streamed one. The contract is explicit that a client
        // rendering a volume slider must compute against it rather than hard-code
        // 11: the ceiling is per-vehicle and varies by model/firmware, so a car with
        // a max of 10 rendered its full volume as 91% under the old constant.
        if let vol = state.mediaVolume, !volumeSending, pendingVolume == nil {
            let max = Self.volumeMax(state.mediaVolumeMax)
            observedVolumeMax = state.mediaVolumeMax
            reconcileField(.volume, key: .media) {
                self.controls.volume = min(100, Swift.max(0, vol / max * 100))
            }
        } else if let wireMax = state.mediaVolumeMax {
            // Adopt a ceiling that arrives without a level (they are independently
            // delivered) so the next send scales correctly.
            observedVolumeMax = wireMax
        }

        // MYR-286 — the owner-entered plate, reconciled exactly like the sibling
        // fields (skip while a save is in flight; the ack + next read settle it).
        //
        // SNAPSHOT-ONLY, by contract: rest-api.md §7.14 states there is NO
        // WebSocket delta for `licensePlate` in v1 — a `vehicle_update` frame
        // NEVER carries it and a plate edit fires no push — so this arm only ever
        // runs on a cold `/snapshot` read, never on a folded delta. (That is the
        // same reason the Kit's MYR-298 tripwire lists it under
        // `snapshotOnlyFields` rather than folding it in the merger.)
        //
        // The value is stored RAW: an EMPTY string is a real, meaningful answer
        // ("the owner has not set one") and must be adopted, not skipped, or a
        // cleared plate would linger on the row forever. The `VIN ····xxxx`
        // fallback is applied at DISPLAY time by `VehicleContractMapping`, never
        // baked in here — baking it in is what would put an uneditable VIN into
        // the edit sheet.
        //
        // MYR-351 — and it does NOT only run on a cold read, which is the sentence
        // above that was wrong and the defect this guard closes. `reconcile` is
        // wired to `LiveVehicleState.onStateChanged`, which fires on every folded
        // delta too, and `VehicleStateMerger.apply` opens with `var state = original`
        // — so a delta carries the last snapshot's plate forward verbatim and used
        // to re-apply it over a save the owner had just made.
        if let plate = state.licensePlate,
           acceptsSnapshotRead(.plate, issuedAt: snapshotReadIssuedAt) {
            reconcileField(.plate, key: .plate) {
                self.controls.plate = VehicleContractMapping.editablePlate(licensePlate: plate)
            }
        }

        // MYR-316 — the resolved service window, reconciled exactly like the plate
        // above and SNAPSHOT-ONLY for the same contractual reason (a
        // `vehicle_update` frame never carries `serviceEstimatedEndAt`), so this
        // arm only ever runs on a cold `/snapshot` read.
        //
        // Unconditional, NOT `if let`: nil is a real, meaningful answer here —
        // "no window is known", which is both the common case (Tesla has no
        // appointment record) and what a car leaving `in_service` produces, since
        // the server clears the field on that transition. Skipping the nil would
        // leave a completed visit's estimate on screen forever, and — worse —
        // would leave the rider's scheduling floor standing after the car came
        // back. This is the one place a nil MUST be adopted rather than ignored.
        // `knownFields` is the MYR-251 "has this been confirmed?" ledger, and it
        // must NOT be set from an ABSENT wire value (the MYR-228 honesty
        // tripwire). So the VALUE is adopted unconditionally while the KNOWN flag
        // is only raised for an actual window — which reads correctly either way:
        // "known" here means "we hold a window", and holding none is the state the
        // nil already expresses.
        //
        // MYR-351 — the `isPending` gate below was the ONLY protection this arm
        // had, and it covers only the milliseconds the write is in flight. The
        // owner's report ("popped right back after a few seconds") is the frame
        // that arrived AFTER the echo settled: a delta carrying the pre-clear
        // snapshot's instant forward, walking straight through a pending flag that
        // had already been lowered. `acceptsSnapshotRead` is the missing half —
        // pending guards the write's OWN window, the read stamp guards everything
        // that was already in the post.
        let resolvedWindow = state.serviceEstimatedEndAt.flatMap(VehicleContractMapping.parseTimestamp)
        if uiState(for: .serviceWindow).isPending == false,
           acceptsSnapshotRead(.serviceWindow, issuedAt: snapshotReadIssuedAt) {
            // MYR-362 — THIS is where the source becomes provable, and it is the
            // only place it ever was. A read reaching here was ISSUED after our
            // commit (`acceptsSnapshotRead`), so its `serviceEstimatedEndAt` is
            // `COALESCE(service_etc, service_expected_end_at)` computed with the
            // owner's entry already in the table: it comes back EQUAL to what we
            // stored only when Tesla had no `service_etc` to outrank it, and
            // DIFFERENT only when Tesla did. That is exactly MYR-320's predicate —
            // the same `provenance` classifier, unchanged — fed from the read
            // instead of from a write echo that could never have known.
            //
            // Consumed once. Every later read falls through to MYR-320's own rule
            // below, so a window that MOVES again drops the note rather than
            // carrying a claim about a different instant.
            if let submitted = pendingServiceWindowProvenance {
                pendingServiceWindowProvenance = nil
                controls.serviceWindowSource = Self.provenance(submitted: submitted, resolved: resolvedWindow)
            } else if controls.serviceEstimatedEndAt != resolvedWindow {
                // MYR-320 — a read that MOVES the value invalidates whatever was
                // last proved about its source: the instant on screen is no longer
                // the instant we classified, so the note that described it would
                // now be describing something else. Fall back to `.unknown` (no
                // note) rather than carrying a stale claim forward. A read that
                // agrees with what we hold changes nothing.
                controls.serviceWindowSource = .unknown
            }
            controls.serviceEstimatedEndAt = resolvedWindow
            if resolvedWindow != nil { knownFields.insert(.serviceWindow) }
        }

        // MYR-342 — the owner's ride-share switch, reconciled like the two above
        // and SNAPSHOT-ONLY for the same contractual reason (rest-api.md §7.18: a
        // ride-share edit fires no push, and a `vehicle_update` never carries the
        // field), so this arm only ever runs on a cold `/snapshot` read.
        //
        // `if let`, NOT unconditional — the exact opposite of the service window
        // directly above, and the difference is what the nil MEANS on each field.
        // A nil window is a real answer ("no window is known") that must be adopted
        // or a completed visit's estimate would linger. A nil here is the ABSENCE
        // of an answer: the server column is `NOT NULL DEFAULT true`, so a live
        // server always sends a boolean, and a missing key means only that the
        // server predates 0.20.0. Adopting it would be doubly wrong — it would
        // overwrite a position the owner had just set, and it would raise the
        // MYR-251 known flag off an ABSENT wire value, which is the MYR-228 honesty
        // tripwire. Absence is handled where the contract says it is handled: at
        // READ time, by `VehicleRideShare.isEnabled` resolving nil to ON.
        //
        // Skipped while a write is in flight, so a snapshot landing mid-flip cannot
        // clobber the optimistic position — the echo settles it a moment later.
        //
        // MYR-351 — same missing half, and the report it produced was the loudest
        // of the three: "whenever I turn off ride share it switches back on". A
        // paused car's next telemetry frame carried the pre-pause snapshot's `true`
        // forward and un-paused it, seconds after the owner walked away believing
        // the switch had taken.
        if let wireRideShare = state.rideShareEnabled,
           uiState(for: .rideShare).isPending == false,
           acceptsSnapshotRead(.rideShare, issuedAt: snapshotReadIssuedAt) {
            controls.rideShareEnabled = wireRideShare
            knownFields.insert(.rideShare)
        }
    }

    /// MYR-351 — whether a read ISSUED at `issuedAt` is allowed to overwrite this
    /// SNAPSHOT-ONLY field, i.e. whether it can possibly have seen our last write
    /// to it.
    ///
    /// Never written to → nothing to protect, adopt. Written to → adopt only a read
    /// that went out AFTER the commit. Everything else is information we already
    /// know to be superseded, whether it reaches us as a delta carrying the old
    /// snapshot's value forward or as a `/snapshot` response that straddled the
    /// write.
    ///
    /// THE GUARD MUST NOT LATCH, and this is why the comparison is against the READ
    /// rather than a flag: the moment a genuinely newer read arrives it wins in
    /// full, including a value that contradicts what we committed. A car that left
    /// service, an owner who flipped the switch on another device, a plate edited on
    /// the web — all of them reach this client on the next cold read exactly as they
    /// did before. What can no longer happen is the PAST overwriting the present.
    private func acceptsSnapshotRead(_ field: VehicleControlField, issuedAt: Date) -> Bool {
        guard let committed = committedAt[field] else { return true }
        return issuedAt > committed
    }

    /// Apply a wire value to a control and mark it KNOWN — unless a command for its
    /// `key` is currently in flight (leave the optimistic in-flight value alone; the
    /// ack + next frame reconcile it). `key: nil` for controls with no command
    /// (fan) — always applied.
    private func reconcileField(_ field: VehicleControlField, key: VehicleControlKey?, apply: () -> Void) {
        if let key, uiState(for: key).isPending { return }
        apply()
        knownFields.insert(field)
        // MYR-301 clear path 2 — the car just told us where this control really
        // is, which answers any settled notice about a failed attempt to move it.
        if let key { clearNotice(key) }
    }

    /// Like `reconcileField` for a COMMANDED boolean toggle, but also honors the
    /// post-ack settle window: after a command applies, a streamed value that
    /// DISAGREES with what we commanded is ignored until the car confirms (agrees)
    /// or the deadline lapses — so a stale frame can't yank the tile back (the
    /// climate-off revert, MYR-272). Confirmation or timeout clears the hold and the
    /// live stream resumes driving the tile (incl. a genuine external change).
    private func reconcileControlled(
        _ field: VehicleControlField, key: VehicleControlKey, wire: Bool, assign: (Bool) -> Void
    ) {
        if uiState(for: key).isPending { return } // command still in flight
        if let hold = settleHold[key] {
            if wire == hold.want {
                settleHold[key] = nil // the car confirmed the commanded state
            } else if Date() < hold.until {
                return // settling — ignore a stale frame that disagrees with the command
            } else {
                settleHold[key] = nil // timed out — accept the car's reported reality (honest)
            }
        }
        assign(wire)
        knownFields.insert(field)
        clearNotice(key) // MYR-301 clear path 2 — see `reconcileField`
    }

    /// Reconcile one seat from its heater + cooler read-back levels (both 0–3 on the
    /// wire, matching the UI's level scale). Active cooling (cooler > 0) wins the
    /// mode; else active heating (heater > 0) → heat; else the seat is OFF and the
    /// wire is mode-ambiguous, so the seat's current/armed mode is PRESERVED (never
    /// forced to heat — MYR-280). Absent on both → stays unknown.
    private func reconcileSeat(_ seat: VehicleSeatPosition, key: VehicleControlKey, heater: Int?, cooler: Int?) {
        guard heater != nil || cooler != nil else { return }
        if uiState(for: key).isPending { return } // command still in flight
        let mode: VehicleSeatClimateMode
        let level: Int
        if let cooler, cooler > 0 {
            mode = .cool
            level = min(3, max(0, cooler))
        } else if let heater, heater > 0 {
            mode = .heat
            level = min(3, max(0, heater))
        } else {
            // Seat is OFF (no active heat or cool on the wire). An off seat streams
            // heater=0/cooler=0 IDENTICALLY whether the owner armed it to Heat or
            // Cool — the wire cannot distinguish the two. Defaulting to .heat here
            // silently reverted a seat the owner had just switched to Cool-but-off
            // back to Heat once the settle window lapsed (the MYR-280 "impossible to
            // toggle heated↔cooled" complaint, for the off state). Preserve the
            // seat's current/armed mode instead; a genuine actuation (level > 0)
            // still wins the mode in the branches above. This also lets an all-zero
            // frame CONFIRM a `(.cool, 0)` settle hold instead of disagreeing with it.
            mode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
            level = 0
        }
        // Post-ack settle window (MYR-280): ignore a streamed seat state that
        // DISAGREES with the just-commanded (mode, level) until the car confirms it
        // or the window lapses (then accept the car's reported reality — honest).
        if let hold = seatSettleHold[key] {
            if mode == hold.mode && level == hold.level {
                seatSettleHold[key] = nil // the car confirmed the commanded state
            } else if Date() < hold.until {
                return // settling — ignore a stale frame that disagrees
            } else {
                seatSettleHold[key] = nil // timed out — accept the car's reality
            }
        }
        switch seat {
        case .driver:
            controls.driverSeatMode = mode
            controls.driverSeatHeatLevel = level
            knownFields.insert(.driverSeat)
        case .passenger:
            controls.passengerSeatMode = mode
            controls.passengerSeatHeatLevel = level
            knownFields.insert(.passengerSeat)
        }
        clearNotice(key) // MYR-301 clear path 2 — see `reconcileField`
    }

    /// Reconcile the car's reported HVAC mode onto the Auto/Cool/Heat segment
    /// (MYR-274). Only a KNOWN `On`/`Override` asserts a mode (and marks the field
    /// known); an `Unknown`/absent frame leaves the segment as-is — it never
    /// fabricates a mode and never downgrades a value already known (honest-unknown
    /// is the INITIAL state, before any command or reconcile). While the Auto
    /// command is in flight the frame is left for the ack; after the ack a settle
    /// window holds the optimistic Auto against a stale `Override` frame until the
    /// car confirms `On`/Auto or the deadline lapses (then the car's reality wins).
    ///
    /// MYR-466 — the lapsed arm SPEAKS now. See `ClimateAutoConfirmation` for the
    /// whole triage; the short version is that `auto_conditioning_start` is a
    /// power command rather than a mode command, so on a car already running in
    /// manual it returns `200 applied` and changes nothing — and this method,
    /// doing exactly what it was written to do, then moved the segment back to
    /// Cool with no explanation. The car's mode is still adopted; the silence is
    /// what is fixed.
    private func reconcileClimateMode(autoMode: VehicleState.HvacAutoMode?, acEnabled: Bool?) {
        guard let mode = Self.climateMode(autoMode: autoMode, acEnabled: acEnabled) else { return }
        if uiState(for: .climate).isPending { return } // Auto command still in flight
        var notAdopted = false
        if let pending = climateAutoPending {
            switch ClimateAutoConfirmation.verdict(reported: mode, pending: pending) {
            case .confirmed:
                climateAutoPending = nil // the car adopted Auto
            case .awaiting:
                return // settling — ignore a stale frame that disagrees with the command
            case .notAdopted:
                climateAutoPending = nil
                notAdopted = true
            }
        }
        controls.climateMode = mode
        knownFields.insert(.climateMode)
        if notAdopted {
            // The notice REPLACES the clear below rather than following it: this
            // frame is the evidence the command did not land, so answering it with
            // MYR-301's "the car told us where the control really is, so the
            // notice is spent" would delete the sentence in the same statement
            // that earned it.
            settle(.climate, notice: .autoNotAdopted)
            return
        }
        // Every LATER frame is prevented from clearing it inside `clearNotice`
        // itself rather than here — the `.climate` key's climate-on arm reconciles
        // ahead of this one and would otherwise wipe the sentence on the next
        // frame. See that method's MYR-466 note.
        clearNotice(.climate) // MYR-301 clear path 2 — see `reconcileField`
    }

    /// Fold the HVAC auto-mode + AC-enabled read-back onto the app's Auto/Cool/Heat
    /// segment. Only a KNOWN auto state asserts a mode: `On` → Auto; `Override`
    /// (manual) → Cool when the AC compressor is on, else Heat. `Unknown`/
    /// unrecognized/absent → nil (leave the last-shown mode untouched — honest).
    static func climateMode(autoMode: VehicleState.HvacAutoMode?, acEnabled: Bool?) -> VehicleClimateMode? {
        switch autoMode {
        case .on: return .auto
        case .override: return (acEnabled == true) ? .cool : .heat
        case .unknown, .unrecognized, .none: return nil
        }
    }

    /// Tesla's usual volume ceiling, used ONLY when the car has never reported its
    /// own `mediaVolumeMax`. The contract permits this fallback but is explicit
    /// that it is an assumption, not a guarantee — hence the single named constant
    /// rather than an 11 sprinkled through the scaling math.
    static let assumedVolumeMax = 11.0

    /// The ceiling to scale the volume slider against: the car's reported maximum
    /// when it is present and positive, else the assumed 11. A zero/negative wire
    /// value is rejected rather than propagated — it would divide the whole slider
    /// by zero.
    static func volumeMax(_ wire: Double?) -> Double {
        guard let wire, wire > 0 else { return assumedVolumeMax }
        return wire
    }

    /// Map the media playback enum onto the play/pause boolean. `Unknown` and any
    /// unrecognized value return nil so the control stays honestly unknown (MYR-251)
    /// rather than asserting a fabricated play/pause.
    ///
    /// MYR-467 — this is the CAR'S OWN reading and it now lives beside the rule
    /// that may overrule it (`MediaPlaybackTruth.playing(from:)`), which this
    /// delegates to so the two can never drift. `reconcile` no longer calls it
    /// directly: it asks the truth rule, which consults this and then checks the
    /// answer against the track position.
    static func mediaPlaying(from status: VehicleState.MediaPlaybackStatus) -> Bool? {
        MediaPlaybackTruth.playing(from: status)
    }

    // Every keyed control now maps to a real §7.9 command (charge port joined the
    // catalog in v186), so `isSupported` keeps the protocol default (`true`).

    /// Map the Kit's typed §7.9 failure onto an honest control notice. `key` lets
    /// a `permission_denied` on the charge port name the charging scope
    /// specifically (`vehicle_charging_cmds`), which the owner's token may lack.
    ///
    /// MYR-301 splits two outcomes the old table folded into one line:
    ///   • 503 `vehicle_asleep` that SURVIVES the wake retry settles as `.asleep`
    ///     ("Car is asleep — try again shortly"), not as a still-running
    ///     "Waking the car…" (which claimed a wake that had already given up) and
    ///     not as the 502's "Couldn't reach the car" (we reached it fine).
    ///   • 502 `command_failed` settles as `.rejected` — the car received the
    ///     command and refused it, which is a different fact (and a different
    ///     owner response) from being unable to reach it at all.
    /// `.transport`/`.invalidRequest`/`.notFound`/`.other` keep `.failed`.
    ///
    /// MYR-329 adds `reason`: the cause the SERVER named on a `command_failed`,
    /// or `nil` when it named none. It rides only the `.rejected` branch — the
    /// one outcome that means the car itself refused — so no other notice can
    /// be altered by it, and `.asleep` in particular is untouched (an asleep car
    /// never reaches this branch: `attempt` intercepts `.vehicleAsleep` while
    /// retries remain, and the server classifies asleep-class reasons as
    /// `503 vehicle_asleep` rather than `502 command_failed` in the first place).
    static func notice(
        for kind: RestError.CommandFailureKind,
        key: VehicleControlKey,
        reason: VehicleCommandRejectionReason? = nil
    ) -> VehicleCommandNotice {
        // MYR-286 — the plate write is §7.14, not §7.9. No Tesla call happens on
        // that path at all, so the whole "car" vocabulary below (asleep, waking,
        // key not paired, the car refused it) is unreachable AND untrue there.
        if key == .plate { return plateNotice(for: kind) }
        return switch kind {
        case .vehicleAsleep: .asleep
        case .keyNotPaired: .pairKey
        case .permissionDenied: key == .chargePort ? .relinkCharging : .relink
        case .notOwned, .auth: .relink
        case .rateLimited: .cooldown
        case .commandFailed: .rejected(reason)
        case .invalidRequest, .notFound, .transport, .other: .failed
        }
    }

    /// MYR-286 — the §7.14 plate-write error catalog, folded to honest copy.
    ///
    ///   • `400 invalid_request` is the ONE outcome that is about the plate
    ///     itself: the server normalizes (trim + uppercase) and only THEN
    ///     validates, so this can't be a casing/whitespace complaint — the value
    ///     really does break the charset or the 10-character cap.
    ///   • `403 vehicle_not_owned` / `401` are account problems, and take the
    ///     existing re-link route like every other control.
    ///   • Everything else (transport, `404 not_found`, `500 internal_error`)
    ///     means the write simply didn't land. It is NOT "couldn't reach the car":
    ///     §7.14 never contacts the car, so `.failed`'s copy would be a lie.
    ///   • `vehicleAsleep` / `keyNotPaired` / `commandFailed` are §7.9-only
    ///     outcomes this endpoint cannot produce; they are folded into the same
    ///     honest "couldn't save" rather than being given car-shaped copy.
    static func plateNotice(for kind: RestError.CommandFailureKind) -> VehicleCommandNotice {
        switch kind {
        case .invalidRequest: .invalidPlate
        case .permissionDenied, .notOwned, .auth: .relink
        case .rateLimited: .cooldown
        case .vehicleAsleep, .keyNotPaired, .commandFailed, .notFound, .transport, .other: .plateNotSaved
        }
    }

    // MARK: Backend-backed commands (§7.9)

    func setLocked(_ locked: Bool) async throws {
        await run(.lock, command: locked ? .doorLock : .doorUnlock) { [weak self] in
            self?.controls.locked = locked
            self?.knownFields.insert(.locked)
            self?.holdSettle(.lock, want: locked)
        }
    }

    func setClimateOn(_ on: Bool) async throws {
        await run(.climate, command: on ? .autoConditioningStart : .autoConditioningStop) { [weak self] in
            self?.controls.climateOn = on
            self?.knownFields.insert(.climateOn)
            self?.holdSettle(.climate, want: on)
        }
    }

    func setTargetTemp(_ temp: Int) async throws {
        let clamped = min(82, max(60, temp)) // vehicle-controls.jsx:262,270 (°F)
        await run(.temp, command: .setTemps(driverTempC: Self.celsius(fromFahrenheit: clamped), passengerTempC: nil)) { [weak self] in
            self?.controls.targetTemp = clamped
            self?.knownFields.insert(.targetTemp)
        }
    }

    func setTrunkOpen(_ open: Bool) async throws {
        // The tile toggles the REAR trunk (the design's single trunk affordance);
        // front-trunk actuation waits on a UI that offers the choice.
        await run(.trunk, command: .actuateTrunk(.rear)) { [weak self] in
            self?.controls.trunkOpen = open
            self?.knownFields.insert(.trunkOpen)
            self?.holdSettle(.trunk, want: open)
        }
    }

    func setChargePortOpen(_ open: Bool) async throws {
        // v186: charge_port_door_open / close. Scope `vehicle_charging_cmds` — a
        // token lacking it surfaces `.relinkCharging` (see `notice(for:key:)`).
        await run(.chargePort, command: open ? .chargePortDoorOpen : .chargePortDoorClose) { [weak self] in
            self?.controls.chargePortOpen = open
            self?.knownFields.insert(.chargePortOpen)
            self?.holdSettle(.chargePort, want: open)
        }
    }

    /// Start the post-ack settle window for a commanded toggle (see `settleHold`).
    private func holdSettle(_ key: VehicleControlKey, want: Bool) {
        settleHold[key] = (want: want, until: Date().addingTimeInterval(settleWindow))
    }

    /// Start the post-ack settle window for a commanded seat (see `seatSettleHold`).
    private func holdSeatSettle(_ key: VehicleControlKey, mode: VehicleSeatClimateMode, level: Int) {
        seatSettleHold[key] = (mode: mode, level: level, until: Date().addingTimeInterval(settleWindow))
    }

    func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws {
        let clamped = min(3, max(0, level))
        let key = Self.seatKey(seat)
        let side = Self.seatSide(seat)
        // The level squares actuate whichever mode the seat is armed to (the UI's
        // accent follows the mode) — heater for .heat, cooler for .cool. The Kit
        // factories own the seat_position + level-scale (0–3 vs 1–4) mapping.
        let mode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
        let command: VehicleCommand = mode == .cool
            ? .seatCooler(side, uiLevel: clamped)
            : .seatHeater(side, uiLevel: clamped)
        await run(key, command: command) { [weak self] in
            guard let self else { return }
            switch seat {
            case .driver:
                self.controls.driverSeatHeatLevel = clamped
                self.knownFields.insert(.driverSeat)
            case .passenger:
                self.controls.passengerSeatHeatLevel = clamped
                self.knownFields.insert(.passengerSeat)
            }
            // Hold the optimistic (mode, level) against a stale frame (MYR-280).
            self.holdSeatSettle(key, mode: mode, level: clamped)
        }
    }

    func setSeatClimateMode(_ seat: VehicleSeatPosition, mode newMode: VehicleSeatClimateMode) async throws {
        let oldMode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
        let oldLevel = seat == .driver ? controls.driverSeatHeatLevel : controls.passengerSeatHeatLevel
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // vehicle-controls.jsx:90 — switching Heat/Cool resets the level.
            switch seat {
            case .driver:
                self.controls.driverSeatMode = newMode
                self.controls.driverSeatHeatLevel = 0
                self.knownFields.insert(.driverSeat)
            case .passenger:
                self.controls.passengerSeatMode = newMode
                self.controls.passengerSeatHeatLevel = 0
                self.knownFields.insert(.passengerSeat)
            }
            // Hold the optimistic mode switch against a stale frame (MYR-280) — e.g.
            // the heater level the car streamed just before it stopped for cool.
            self.holdSeatSettle(Self.seatKey(seat), mode: newMode, level: 0)
        }
        // Nothing was actively heating/cooling → the mode switch is a pure local
        // arm change (no vehicle actuation to make).
        guard oldLevel > 0 else { apply(); return }
        // The design's reset-to-0 means the previously-active element must stop on
        // the car: send the OFF for the OLD mode, then flip mode + level locally.
        let side = Self.seatSide(seat)
        let offCommand: VehicleCommand = oldMode == .cool
            ? .seatCooler(side, uiLevel: 0)
            : .seatHeater(side, uiLevel: 0)
        await run(Self.seatKey(seat), command: offCommand, apply: apply)
    }

    func setMediaPlaying(_ playing: Bool) async throws {
        // media_toggle_playback is a toggle regardless of direction; `playing` is
        // the optimistic target applied on ack.
        //
        // MYR-314 — the tap does NOT mark the field known. Known-ness is the wire's
        // to give (`mediaPlaybackStatus`, streamed live since MYR-298): before this,
        // a single tap made the app assert a playback state forever, on a car that
        // might have no media session at all, and the icon then reflected the last
        // LOCAL tap rather than the car. The optimistic value is still applied on
        // ack (the tap only reaches here when the wire already opened the gate) and
        // held against a stale frame for the settle window, exactly like the
        // boolean toggles.
        await run(.media, command: .mediaTogglePlayback) { [weak self] in
            self?.controls.mediaPlaying = playing
            self?.holdSettle(.media, want: playing)
        }
    }

    func skipTrack(_ direction: VehicleTrackDirection) async throws {
        let command: VehicleCommand = direction == .next ? .mediaNextTrack : .mediaPrevTrack
        await run(.media, command: command) { [weak self] in
            guard let self else { return }
            switch direction {
            case .previous: self.controls.trackIndex = (self.controls.trackIndex + self.trackCount - 1) % self.trackCount
            case .next: self.controls.trackIndex = (self.controls.trackIndex + 1) % self.trackCount
            }
            // The displayed track list is placeholder art (see MediaSection); the
            // real command skips the car's track while the UI cycles optimistically.
            self.controls.scrubPercent = 0
        }
    }

    func setVolume(_ volume: Double) async throws {
        // A continuous slider can't await a round trip per drag delta, so apply
        // immediately (smooth thumb) and best-effort-send the latest value with a
        // one-in-flight coalescer. adjust_volume takes 0–11; the UI is 0–100.
        let clamped = min(100, max(0, volume))
        controls.volume = clamped
        knownFields.insert(.volume)
        sendVolume(clamped)
    }

    func setScrubPercent(_ percent: Double) {
        // No seek-to-position command in §7.9 — local feedback only (flagged).
        controls.scrubPercent = min(100, max(0, percent))
    }

    // MARK: Climate mode — Auto is a real command; Cool/Heat are display-only (MYR-274)

    /// The Auto/Cool/Heat segment. Per the product decision (Thomas, MYR-274) —
    /// "Auto real, Cool/Heat reflect state":
    ///   • **Auto** is the one actionable control: it sends the real Tesla
    ///     `auto_conditioning_start`, returning the car to auto climate, then
    ///     optimistically shows `.auto` on ack with a settle-window hold so a stale
    ///     `Override`/absent frame can't immediately flip it back (MYR-272 discipline).
    ///     **MYR-466 — and it is a REQUEST, not a result.** `auto_conditioning_start`
    ///     is Tesla's HVAC POWER command; there is no Fleet command for the auto
    ///     MODE, so a car already running in manual applies it, answers 200, and
    ///     stays in manual. The optimistic Auto is therefore held pending a
    ///     confirmation the car may never give, and a window that lapses on a
    ///     disagreeing frame surfaces `.autoNotAdopted` instead of springing the
    ///     segment back in silence. See `ClimateAutoConfirmation`.
    ///   • **Cool/Heat** are HONEST DISPLAY-ONLY: Tesla's API has no command to force
    ///     a manual cool/heat mode, so a tap sends NOTHING and mutates NOTHING — the
    ///     segment merely REFLECTS the mode the car reports (`reconcileClimateMode`).
    /// Reuses the `.climate` key so an Auto command shares the pending/settle
    /// discipline of climate on/off (both are HVAC start/stop — never fire two at once).
    func setClimateMode(_ mode: VehicleClimateMode) async throws {
        guard mode == .auto else { return } // Cool/Heat are non-commanding reflections
        await run(.climate, command: .autoConditioningStart) { [weak self] in
            guard let self else { return }
            self.controls.climateMode = .auto
            self.knownFields.insert(.climateMode)
            self.climateAutoPending = ClimateAutoConfirmation.Pending(
                deadline: Date().addingTimeInterval(self.settleWindow)
            )
            // `auto_conditioning_start` physically turns the HVAC ON, so move the
            // climate on/off tile in lockstep — optimistically on + held against a
            // stale `isClimateOn=false` frame — instead of lagging a telemetry frame.
            self.controls.climateOn = true
            self.knownFields.insert(.climateOn)
            self.holdSettle(.climate, want: true)
        }
    }

    // MARK: No backend command — local mutation, flagged (see header)

    func setFanSpeed(_ speed: Int) async throws {
        // No §7.9 fan command and no wire field — a local-only setting. Touching
        // it confirms the owner's chosen value, so it becomes known (MYR-251).
        controls.fanSpeed = min(10, max(0, speed))
        knownFields.insert(.fanSpeed)
    }

    // MARK: - License plate (§7.14 — a real write, but NOT a Tesla command)

    /// Persist the owner-entered plate through `PUT /api/tesla/vehicles/{id}/plate`
    /// (MYR-286). Before this, the live executor wrote `controls.plate` and nothing
    /// else — the edit sheet's Save looked like it worked and the value was gone on
    /// the next launch.
    ///
    /// Three deliberate properties:
    ///
    ///  • **The SERVER's normalized echo is adopted, never the raw input.** The
    ///    server trims + uppercases before validating, so `"  abc 1234  "` is
    ///    stored as `"ABC 1234"`. Showing what the owner typed would leave the UI
    ///    disagreeing with the database until the next snapshot — and re-deriving
    ///    the normalization client-side would be a second implementation of a rule
    ///    the contract says not to re-implement.
    ///  • **`plate` is sent VERBATIM** for the same reason: normalization is the
    ///    server's job, and the endpoint is explicitly built to accept messy input.
    ///  • **The echo is broadcast** via `onPlateSaved`, because §7.14 fires no WS
    ///    push — the owner's own fleet row would otherwise keep the stale plate
    ///    until the next `GET /api/vehicles`.
    ///
    /// Shares the `.plate` key's pending/notice discipline with the commanded
    /// controls (double-save suppressed while in flight), but NOT the wake-retry:
    /// there is no car in this path to wake.
    func setPlate(_ plate: String) async throws {
        guard uiState(for: .plate).isPending == false else { return }
        beginPending(.plate)
        do {
            let response = try await plateEndpoint.setLicensePlate(plate, vehicleID: vehicleID)
            controls.plate = response.licensePlate
            knownFields.insert(.plate)
            // MYR-351 — stamp the commit so a read ISSUED before this echo cannot
            // put the old plate back (see `acceptsSnapshotRead`).
            committedAt[.plate] = Date()
            uiStates[.plate] = .idle
            onPlateSaved?(response.licensePlate)
        } catch let error as RestError {
            settle(.plate, notice: Self.plateNotice(for: error.commandFailureKind))
        } catch {
            settle(.plate, notice: .plateNotSaved)
        }
    }

    // MARK: - Service window (MYR-316 — a real write, but NOT a Tesla command)

    /// Persist the owner's "expected back" time through
    /// `PUT /api/tesla/vehicles/{id}/service-window` (MYR-316). `nil` clears.
    ///
    /// The properties that matter, all of which mirror `setPlate` because the two
    /// endpoints are the same KIND of thing (an owner-scoped DB write with no
    /// Tesla call anywhere in it):
    ///
    ///  • **The server's echo is adopted, never the submitted instant** — and
    ///    MYR-362 is what that sentence actually means. §7.16's `200` echoes the
    ///    **OWNER COLUMN** (`expectedEndAt`), not the resolved
    ///    `serviceEstimatedEndAt`, because "echoing the resolved value would make a
    ///    client believe its write had been overruled when it has merely been
    ///    outranked by Tesla on the next read". MYR-316 read that backwards and
    ///    shaped `VehicleServiceWindowResponse` around a key the server has never
    ///    sent; the property was optional, so every save decoded a silent `nil`,
    ///    committed it, and left the owner's just-typed date nowhere on a sheet
    ///    whose write had returned `200` — the client's report.
    ///  • **The RESOLVED window is not knowable here, so it is not claimed here.**
    ///    `COALESCE(service_etc, service_expected_end_at)` lives on the read
    ///    surfaces (§7.0 / §7.1) and Tesla's estimate may outrank what we just
    ///    stored. §7.16 names the two legal responses to that — adopt this echo
    ///    optimistically, or re-read — and this method does BOTH: it adopts, and
    ///    MYR-351's guard is deliberately non-latching, so the first `/snapshot`
    ///    ISSUED after this commit replaces the value in full if Tesla won.
    ///  • **A past instant is rejected LOCALLY first** (`VehicleServiceWindow
    ///    .isEnterable`), so the common mistake costs no round trip. The 400 arm
    ///    below is the defensive path for the case the local check cannot catch —
    ///    a sheet left open until the picked time passed.
    ///  • **The echo is broadcast** via `onServiceWindowSaved`, because there is
    ///    no WS push for this field (snapshot-only by contract). Broadcasting the
    ///    mis-decoded `nil` was the second half of the defect: it wrote NULL into
    ///    the summary row the RIDER-facing `LiveFleetMemberMapping` reads, so an
    ///    owner setting a completion date withdrew their own scheduling floor.
    ///
    /// Shares the `.serviceWindow` key's pending/notice discipline with the
    /// commanded controls (a double-save while in flight is suppressed), but NOT
    /// the wake-retry: there is no car in this path to wake.
    func setServiceWindow(_ expectedEndAt: Date?) async throws {
        guard uiState(for: .serviceWindow).isPending == false else { return }
        beginPending(.serviceWindow)
        do {
            let response = try await serviceWindowEndpoint.setServiceWindow(
                expectedEndAt: expectedEndAt.map(Self.rfc3339.string(from:)),
                vehicleID: vehicleID
            )
            let stored = response.expectedEndAt.flatMap(VehicleContractMapping.parseTimestamp)
            controls.serviceEstimatedEndAt = stored
            // MYR-320 → MYR-362 — the echo is NOT the moment the source becomes
            // knowable, and treating it as one is how MYR-320's caption would
            // become a fabrication. §7.16 echoes the owner's own column, so the
            // echo agrees with the submission ALWAYS and by construction: running
            // `provenance` on it would answer `.manual` on every save, asserting
            // "Tesla hasn't provided an estimate for this visit" about a car whose
            // estimate we have not looked at. Nothing is provable yet, so nothing
            // is claimed — and the pair is HELD for the first read issued after
            // this commit, which is where `COALESCE(service_etc, …)` finally says
            // which source won (see `reconcile`).
            controls.serviceWindowSource = .unknown
            pendingServiceWindowProvenance = stored
            knownFields.insert(.serviceWindow)
            // MYR-351 — stamp the commit. A CLEAR needs this as much as a set does:
            // `stored` is nil, so there is no value to distinguish it by, and the
            // stale read that resurrects it looks identical to a legitimate one.
            committedAt[.serviceWindow] = Date()
            uiStates[.serviceWindow] = .idle
            onServiceWindowSaved?(stored)
        } catch let error as RestError {
            settle(.serviceWindow, notice: Self.serviceWindowNotice(for: error.commandFailureKind))
        } catch {
            settle(.serviceWindow, notice: .serviceWindowNotSaved)
        }
    }

    /// MYR-342 — pause or resume ride requests for this vehicle (rest-api.md
    /// §7.18). The `setServiceWindow` recipe above, with three differences, each of
    /// which is the contract asserting itself:
    ///
    ///  1. IT FLIPS OPTIMISTICALLY. A toggle that waits for a round trip before
    ///     moving reads as broken — the finger leaves the switch and nothing
    ///     happens — so the position changes immediately and the ECHO confirms it.
    ///     The service window has no equivalent because its editor is a sheet with
    ///     a Save button, where the wait is legible.
    ///  2. IT ROLLS BACK ON FAILURE. The optimistic flip is a claim about the
    ///     SERVER's state, and if the write did not land that claim is false. A
    ///     toggle left sitting in the position the owner chose while the server
    ///     holds the other one is the worst possible outcome here: the owner walks
    ///     away believing their car is paused while it is still taking requests —
    ///     the exact failure §7.18 names when it forbids reporting a failed write
    ///     as success. So the row snaps back, and the notice beside it says why.
    ///  3. IT ADOPTS THE ECHO, not the bool it sent. Today those always agree
    ///     (§7.18: "this server writes exactly what was asked"), and the contract
    ///     echoes anyway so a future server can refuse or coerce without breaking
    ///     clients. Adopting our own submission would be correct by luck.
    ///
    /// The `isPending` guard makes a double-tap a no-op rather than a second write,
    /// exactly as it does for every other keyed control.
    func setRideShareEnabled(_ enabled: Bool) async throws {
        guard uiState(for: .rideShare).isPending == false else { return }
        let previous = controls.rideShareEnabled
        let wasKnown = knownFields.contains(.rideShare)
        // Optimistic flip — see (1). Marked KNOWN alongside it, because the two are
        // one claim: from this instant the resolver must prefer the executor over a
        // snapshot that CANNOT carry the new value (the field has no WS delta).
        // Without raising the flag the row would render from the snapshot and snap
        // straight back to the old position under the owner's finger — which is the
        // very defect `VehicleRideShare.resolvedEnabled` exists to prevent.
        controls.rideShareEnabled = enabled
        knownFields.insert(.rideShare)
        beginPending(.rideShare)
        do {
            let response = try await rideShareEndpoint.setRideShareEnabled(enabled, vehicleID: vehicleID)
            controls.rideShareEnabled = response.enabled // adopt the ECHO — see (3)
            // MYR-351 — stamp the commit, so the next telemetry frame carrying the
            // pre-flip snapshot's boolean forward cannot un-pause the car.
            committedAt[.rideShare] = Date()
            uiStates[.rideShare] = .idle
            onRideShareSaved?(response.enabled)
        } catch {
            // Roll back BOTH halves of the optimistic claim — see (2). Restoring the
            // known flag matters as much as the value: leaving it raised would make
            // a never-confirmed default outrank a snapshot that does know the
            // answer, so a failed flip on a cold-launched paused car would leave the
            // switch reading ON against a server that holds OFF.
            controls.rideShareEnabled = previous
            if !wasKnown { knownFields.remove(.rideShare) }
            // ONE notice for every failure. §7.18's 400 is a malformed-body bug
            // rather than something the owner did, so unlike the service window
            // there is nothing to tell them apart FOR — see
            // `VehicleCommandNotice.rideShareNotSaved`.
            settle(.rideShare, notice: .rideShareNotSaved)
        }
    }

    #if DEBUG
    /// MYR-320 — seed the service-window provenance a write echo WOULD have
    /// proved, for the capture scenes. The source caption is only reachable after
    /// a Save, and headless capture tooling cannot tap a row inside a half-detent
    /// scroll — the same standing-in-for-a-tap precedent as `ownerFreshnessWaking`'s
    /// seeded `.waking` phase.
    ///
    /// It takes the ECHO PAIR rather than a `ServiceWindowSource`, deliberately:
    /// the classification still runs through the shipping ``provenance(submitted:
    /// resolved:)``, so a capture proves the predicate rather than a hand-set
    /// string. Release builds never compile it.
    func debugSeedServiceWindowSource(submitted: Date?, resolved: Date?) {
        controls.serviceWindowSource = Self.provenance(submitted: submitted, resolved: resolved)
    }
    #endif

    /// The service-window write's own notice vocabulary. NONE of the §7.9
    /// car-shaped notices apply: no Tesla call happens on this path, so the car is
    /// never asked, never asleep, and never the thing that refused. `400
    /// invalid_request` is the ONE semantic failure (the instant is not in the
    /// future); everything else — auth, ownership, not-found, transport, 5xx — is
    /// "the write didn't land", which is a single fact the owner acts on the same
    /// way (try again).
    private static func serviceWindowNotice(for kind: RestError.CommandFailureKind) -> VehicleCommandNotice {
        kind == .invalidRequest ? .serviceWindowPast : .serviceWindowNotSaved
    }

    /// MYR-320 — classify a service window into a provenance the app can honestly
    /// display. Pure and static so the whole matrix is unit-testable without a
    /// network.
    ///
    /// MYR-362 — the CLASSIFIER is unchanged; what changed is where its two
    /// arguments come from. `submitted` is the owner's own stored entry (§7.16's
    /// echo) and `resolved` is `COALESCE(service_etc, service_expected_end_at)` off
    /// a READ issued after that write — never the write's own echo, which is the
    /// owner column and therefore agrees with the submission unconditionally. Fed
    /// from the echo this function answers `.manual` every time, which is a claim
    /// about Tesla made without looking at Tesla.
    ///
    /// A CLEAR (`submitted == nil`) always yields `.unknown`, whatever comes back:
    /// clearing the owner's entry leaves either nothing (nil echo — no source to
    /// name) or Tesla's estimate surfacing from underneath. The latter looks like
    /// proof of Tesla, but it is proof only that SOMETHING remained after the
    /// owner's entry was removed, and claiming a source off that would be exactly
    /// the guess-dressed-as-fact this type exists to avoid.
    ///
    /// The comparison is to the SECOND, not by `==`: the submission is encoded to
    /// RFC 3339 with fractional seconds and the server may normalize what it
    /// stores, so byte-equal instants can differ by a rounding artifact that means
    /// nothing. A sub-second difference is never a Tesla estimate winning.
    /// `nonisolated` because it is pure — it touches no executor state, so it
    /// belongs to the actor only by lexical accident, and hoisting it out is what
    /// lets the matrix be asserted without a main-actor hop.
    nonisolated static func provenance(submitted: Date?, resolved: Date?) -> ServiceWindowSource {
        guard let submitted else { return .unknown }
        guard let resolved else {
            // Submitted a real instant and got nothing back: the server neither
            // adopted it nor substituted Tesla's. Nothing is provable.
            return .unknown
        }
        return abs(resolved.timeIntervalSince(submitted)) < 1 ? .manual : .tesla
    }

    /// RFC 3339 UTC with milliseconds — the exact shape the server emits and
    /// accepts, matching `RideRequestContractMapping`'s `scheduledFor` encoder so
    /// the two owner/rider-side instants are written identically.
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    // MARK: - Seat helpers

    private static func seatKey(_ seat: VehicleSeatPosition) -> VehicleControlKey {
        seat == .driver ? .driverSeat : .passengerSeat
    }

    private static func seatSide(_ seat: VehicleSeatPosition) -> VehicleCommand.SeatSide {
        seat == .driver ? .driver : .passenger
    }

    // MARK: - Volume coalescer (best-effort adjust_volume)

    /// Send `uiVolume` (0–100) as `adjust_volume` (0–11), coalescing to one send
    /// in flight — a queued newer value replaces an older one and is sent when the
    /// current send settles. Errors are swallowed (the slider has no error surface).
    private func sendVolume(_ uiVolume: Double) {
        guard !volumeSending else { pendingVolume = uiVolume; return }
        volumeSending = true
        // MYR-303 — scale against the car's OWN ceiling when it has reported one,
        // so a full slider means full volume on a car whose max isn't 11 (and never
        // sends a level above what the car accepts).
        let wire = uiVolume / 100 * Self.volumeMax(observedVolumeMax)
        let sender = self.sender
        let vehicleID = self.vehicleID
        Task { @MainActor [weak self] in
            _ = try? await sender.sendCommand(.adjustVolume(volume: wire), vehicleID: vehicleID)
            guard let self else { return }
            self.volumeSending = false
            if let next = self.pendingVolume {
                self.pendingVolume = nil
                self.sendVolume(next)
            }
        }
    }

    // MARK: - Command runner

    /// Fahrenheit → Celsius, rounded to Tesla's 0.5° granularity.
    static func celsius(fromFahrenheit f: Int) -> Double {
        let c = (Double(f) - 32) * 5 / 9
        return (c * 2).rounded() / 2
    }

    /// Send `command`; on ack run `apply` (optimistic state flip) and clear the
    /// control; on error map to an honest notice. Suppresses re-fires while a
    /// command for `key` is already in flight (double-tap suppression).
    private func run(_ key: VehicleControlKey, command: VehicleCommand, apply: @escaping @MainActor () -> Void) async {
        guard uiState(for: key).isPending == false else { return }
        beginPending(key)
        await attempt(key, command: command, apply: apply, wakeRetriesLeft: maxWakeRetries)
    }

    private func attempt(
        _ key: VehicleControlKey,
        command: VehicleCommand,
        apply: @MainActor () -> Void,
        wakeRetriesLeft: Int
    ) async {
        do {
            _ = try await sender.sendCommand(command, vehicleID: vehicleID)
            apply()
            uiStates[key] = .idle
        } catch let error as RestError {
            let kind = error.commandFailureKind
            if kind == .vehicleAsleep, wakeRetriesLeft > 0 {
                // Transient — the server already woke+retried; reflect the wake and
                // retry once with backoff (§7.9).
                uiStates[key] = VehicleControlUIState(isPending: true, notice: .waking)
                try? await Task.sleep(for: wakeRetryDelay)
                await attempt(key, command: command, apply: apply, wakeRetriesLeft: wakeRetriesLeft - 1)
                return
            }
            // MYR-329 — `commandRejectionReason` is non-nil only when the server
            // NAMED the cause on a `command_failed`, so passing it here can
            // never change any other outcome. The MYR-301 lifecycle is untouched:
            // this is still one `settle`, still bounded, still cleared by the
            // next successful reconcile.
            settle(key, notice: Self.notice(for: kind, key: key, reason: error.commandRejectionReason))
        } catch {
            settle(key, notice: .failed)
        }
    }
}
