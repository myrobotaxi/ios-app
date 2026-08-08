import Foundation
import MyRoboTaxiKit
import Observation

// MARK: - Vehicle command seam (MYR-168 deliverable 2)
//
// `VehicleCommandExecutor` is the M1↔M2 seam for every mutating action inside
// `VehicleControls` (design/app/vehicle-controls.jsx) — lock, climate
// on/off + setpoint + mode + fan, seat heat/vent, trunk, charge port, and
// media playback/track/volume. This issue ships
// `SimulatedVehicleCommandExecutor`, which mutates `controls` locally with no
// network and no artificial delay: the prototype's own `onClick` handlers
// are synchronous `setState` calls (`onClick={() => setLocked(l => !l)}`,
// vehicle-controls.jsx:247 et al.) — there is no pending/spinner state
// anywhere in vehicle-controls.jsx to match.
//
// P11 (Vehicle Commands, MYR-180-183 — Backend: NOT ready) swaps in an
// implementation that calls the signed-command proxy and only mutates
// `controls` after the vehicle acknowledges. Every call site
// (`VehicleControls` and its subviews) stays unchanged, which is why every
// mutator below is `async throws` today even though the simulated path can't
// fail — mirrors `AuthSession`'s documented rationale (AuthSession.swift:4-12).
//
// License-plate editing and media scrub position are NOT vehicle commands:
// Tesla's data has no plate field (see `PlateRow`'s doc comment below, ported
// from vehicle-controls.jsx:124-125) and there is no Fleet API seek-to-
// position, so `setScrubPercent` is a plain synchronous local mutation (no
// await latency while dragging).
//
// MYR-286 — `setPlate` is now a REAL backend write, just not a Tesla one: the
// owner-scoped `PUT /api/tesla/vehicles/{vehicleId}/plate` (rest-api.md §7.14),
// which is the ONLY writer of `Vehicle.licensePlate` anywhere in the stack. That
// is why it was always `async throws`. On the live path it persists and adopts
// the SERVER-NORMALIZED echo; on the simulated path it stays a local mutation so
// the M1 / drift-gate scenes are pixel-identical.

public enum VehicleClimateMode: String, Sendable, Equatable, CaseIterable {
    case auto, cool, heat
}

public enum VehicleSeatPosition: Sendable, Equatable {
    case driver, passenger
}

public enum VehicleSeatClimateMode: String, Sendable, Equatable {
    case heat, cool
}

public enum VehicleTrackDirection: Sendable, Equatable {
    case previous, next
}

// MARK: - Command UX state (MYR-249)
//
// The seam that lets a control render its in-flight / error state without
// knowing whether the executor is simulated or live. Every backend-backed
// control is keyed; the executor tracks a per-key `VehicleControlUIState`, and
// the view reads `executor.uiState(for:)` to show a spinner or an honest error
// line. The simulated executor returns `.idle` for every key (default protocol
// impl below), so the M1 / drift-gate scenes stay pixel-identical (CLAUDE.md).

/// The controls that map to a real §7.9 backend command (MYR-249). `chargePort`
/// is included even though it has NO backend command — the live executor reports
/// it UNSUPPORTED so the tile can be honestly disabled rather than faked.
public enum VehicleControlKey: Sendable, Hashable {
    case lock
    case climate        // auto_conditioning_start / stop (the on/off tile)
    case temp           // set_temps
    case trunk          // actuate_trunk (rear)
    case chargePort     // charge_port_door_open / close (MYR-249 phase 3, v186)
    case driverSeat     // remote_seat_heater_request / remote_seat_cooler_request
    case passengerSeat  // remote_seat_heater_request / remote_seat_cooler_request
    case media          // media_toggle_playback / next / prev (one in flight at a time)
    /// MYR-286 — the owner-entered license plate. NOT a §7.9 Tesla command: it is
    /// the local owner-scoped `PUT /api/tesla/vehicles/{id}/plate` (§7.14), which
    /// touches no Tesla surface at all. It is keyed here anyway because it needs
    /// exactly the same pending/notice UX as the commanded controls — before
    /// MYR-286 `setPlate` wrote only to memory and the edit sheet silently
    /// discarded the owner's input.
    case plate
    /// MYR-316 — the owner's "expected back" entry. Like `.plate` this is NOT a
    /// §7.9 Tesla command but a local owner-scoped write (`PUT
    /// /api/tesla/vehicles/{id}/service-window`), keyed here for the identical
    /// pending/notice UX. Distinct from `.plate` because the two can be in flight
    /// independently and their failures say different things.
    case serviceWindow
    /// MYR-342 — the owner's ride-sharing switch. Third of the same family as
    /// `.plate` and `.serviceWindow`: NOT a §7.9 Tesla command but a local
    /// owner-scoped write (`PUT /api/tesla/vehicles/{id}/ride-share`, rest-api.md
    /// §7.18), keyed here for the identical pending/notice UX. Its own key, not a
    /// share of `.serviceWindow`'s, for the reason the other two are separate: the
    /// writes can be in flight independently and their failures say different
    /// things to an owner.
    case rideShare

    /// The control's name in owner-facing copy (MYR-301). The notice row sits
    /// BELOW the tile row, so it has to say which control it is talking about —
    /// the tile's own label is too far away to carry that on its own.
    public var displayName: String {
        switch self {
        case .lock: "Lock"
        case .climate: "Climate"
        case .temp: "Temperature"
        case .trunk: "Trunk"
        case .chargePort: "Charge port"
        case .driverSeat: "Driver seat"
        case .passengerSeat: "Passenger seat"
        case .media: "Media"
        case .plate: "Plate"
        // MYR-320 — tracks the row's own relabel, so a notice about this write
        // names the field the owner just edited.
        case .serviceWindow: "Service completion date"
        // MYR-342 — the row's own label, so a notice about this write names the
        // switch the owner just flipped.
        case .rideShare: VehicleRideShare.rowLabel
        }
    }

    /// The SF Symbol the quick tile uses, reused by the notice row's disc so the
    /// row is visually tied to the tile that failed (MYR-301). Non-tile controls
    /// don't need one — they render their notice in place, next to themselves.
    public var tileIcon: String? {
        switch self {
        case .lock: "lock.fill"
        case .climate: "fan"
        case .trunk: "car.fill"
        case .chargePort: "bolt.fill"
        // The plate lives in a labelled details ROW, not a tile — its notice
        // renders in place, next to itself, so it needs no disc icon.
        // The plate, the expected-back time and the ride-sharing switch all live
        // in labelled details ROWS, not tiles — their notices render in place,
        // next to themselves.
        case .temp, .driverSeat, .passengerSeat, .media, .plate, .serviceWindow, .rideShare: nil
        }
    }
}

/// The owner action a notice can route to (MYR-301). A notice that names a
/// broken Tesla connection is not just copy — it is a dead end unless the owner
/// can get to the fix from where they read it, so the notice carries the route
/// and every surface that renders notices makes it tappable (44pt).
public enum VehicleCommandNoticeAction: Sendable, Equatable {
    /// Re-run the Tesla account link (the same flow Settings → Tesla Account →
    /// "Add another Tesla" / onboarding uses). Re-consent is what grants a
    /// missing scope (e.g. `vehicle_charging_cmds`).
    case relinkTesla

    /// The gold pill's label on the notice row.
    public var label: String {
        switch self {
        case .relinkTesla: "Reconnect"
        }
    }
}

/// A honest, non-dramatic notice for a failed/transient command (MYR-249).
/// Maps 1:1 from the Kit's `RestError.CommandFailureKind` via
/// `LiveVehicleCommandExecutor.notice(for:)`. Copy is deliberately quiet
/// (design minimalism) and points at the owner action where one exists.
///
/// MYR-301 — a notice now carries THREE things, because the ~80pt control tile
/// cannot hold a sentence (the client saw "Reconnec…"):
///   • `tileText` — a SHORT token that fits the tile sub on one line at the one
///     uniform 11pt size MYR-281 established (no per-tile scaling),
///   • `message` — the FULL honest sentence, rendered on a full-width surface
///     (the notice row under the tiles, the seat row's own line, the media line),
///   • `action` — the route that FIXES it, where one exists.
public enum VehicleCommandNotice: Sendable, Equatable {
    case waking          // vehicle_asleep — in flight: the server/SDK is retrying
    case asleep          // vehicle_asleep — settled: it did NOT wake in time (MYR-301)
    case pairKey         // key_not_paired — pair the virtual key in Tesla
    case relink          // permission_denied / not-owned / auth — reconnect Tesla
    case relinkCharging  // permission_denied on a charge-port command — the token
                         // lacks the `vehicle_charging_cmds` scope specifically
    case cooldown        // rate_limited (429) — brief "just a moment"
    // MYR-301 — command_failed (502): the CAR refused the action.
    // MYR-329 — and now, when the server could name why, WHICH refusal it was.
    // The payload is `nil` whenever we do not know (an older server, a reason
    // outside the allow-list, a token this build predates), and that case must
    // keep reading exactly as it did before this issue.
    case rejected(VehicleCommandRejectionReason?)
    case failed          // transport / invalid / not-found — couldn't reach the car
    // MYR-286 — the two plate outcomes. The plate is NOT a Tesla command (§7.14 is
    // a local owner-scoped DB write with no Tesla call in it), so every notice
    // above that talks about "the car" would be a lie on this path: the car is
    // never asked, never asleep, and never the thing that refused.
    case invalidPlate    // 400 invalid_request — the plate itself violates the rule
    case plateNotSaved   // transport / 404 / 5xx — the write didn't land
    // MYR-316 — the two service-window outcomes. Same reasoning as the plate
    // pair: no Tesla call happens on this path, so nothing here may blame "the
    // car". A 400 here means the instant is not in the future — which the entry
    // sheet already prevents locally, so seeing it means the clock moved under a
    // sheet left open, and the copy says exactly that rather than something vague.
    case serviceWindowPast     // 400 invalid_request — the instant is no longer future
    case serviceWindowNotSaved // transport / 404 / 5xx — the write didn't land
    // MYR-342 — the ride-share switch has ONE failure notice, not a pair, and the
    // asymmetry is the contract's rather than an omission. §7.16's 400 is a
    // SEMANTIC refusal an owner can act on ("that time has passed"), which is why
    // it earns its own line. §7.18 has no such case: `enabled` is a required
    // boolean with no clear and no third state, so a 400 here means the CLIENT
    // sent something malformed — a bug, not a thing the owner did wrong, and
    // nothing they could fix by trying differently. It therefore folds in with
    // auth / ownership / transport / 5xx onto the single honest fact the owner
    // acts on the same way: the switch did not move.
    case rideShareNotSaved     // 400 / 401 / 403 / 404 / transport / 5xx — the write didn't land
    // MYR-360 — a decline in the pause flow did not land, so the pause was NOT
    // committed. Its own case rather than a share of `.rideShareNotSaved`, because
    // the two leave the owner in materially different places: there, nothing
    // happened at all; here, some reservations really were declined and the rest
    // were not, and the switch is still ON on purpose. An owner who reads "Couldn't
    // change ride sharing" would have no idea that riders had already been told
    // their rides are off.
    case reservationNotDeclined
    // MYR-466 — the Auto climate command was APPLIED (200) and the car did not
    // change mode. Its own case rather than a share of `.rejected`, because the
    // two are opposite facts about the same tap: a rejection means the car said
    // no, and this means the car said yes and then carried on as it was. Telling
    // an owner "The car didn't accept that" about a command it demonstrably
    // accepted sends them looking for a refusal that never happened. See
    // `ClimateAutoConfirmation` for why this state exists at all.
    case autoNotAdopted

    public var message: String {
        switch self {
        case .waking: "Waking the car\u{2026}"
        // MYR-301 — 503 `vehicle_asleep` used to settle as "Waking the car…"
        // (claiming an ongoing wake that had in fact given up) and read as the
        // same "couldn't reach the car" class as a 502. It is neither: the car is
        // simply asleep and the wake didn't land in time.
        case .asleep: "Car is asleep \u{2014} try again shortly"
        case .pairKey: "Pair your key in Tesla"
        case .relink: "Reconnect Tesla to allow this"
        // The charge-port commands need the `vehicle_charging_cmds` scope, which
        // the owner's token may not carry (MYR-249) — name the charging permission
        // so the re-link is unambiguous.
        case .relinkCharging: "Reconnect Tesla for charging access"
        // MYR-320 — was "Just a moment…", which the client read on the MEDIA card
        // as the app stalling rather than as a 429 back-off: an ellipsis with no
        // subject looks like something is still loading, and on a transport row
        // that had just been tapped the natural reading was "the skip didn't go
        // through". The replacement supplies the missing subject — the command WAS
        // sent, the pause is the rate limit, not a failure — and drops the
        // in-progress ellipsis for a settled em dash.
        case .cooldown: "Just sent \u{2014} one moment"
        // MYR-301 — 502 `command_failed` is a REJECTION by the vehicle, not a
        // reachability problem: we reached the car and it said no. Saying
        // "couldn't reach the car" for it is dishonest (and hid the asleep case).
        //
        // MYR-329 — "it said no" was still not enough. A TestFlight owner whose
        // climate command was refused by a car in service mode asked whether his
        // battery was the problem, because this line gave him nothing to go on
        // and low battery is the guess a reasonable person makes. When the
        // server names the reason we say it; when it does not, we keep the
        // honest, unchanged line rather than inventing a cause.
        case .rejected(let reason): reason?.noticeMessage ?? "The car didn\u{2019}t accept that"
        case .failed: "Couldn\u{2019}t reach the car"
        // MYR-286 — the server normalizes (trim + uppercase) BEFORE validating, so
        // a 400 means the plate genuinely breaks the rule (charset or the 10-char
        // cap) rather than that the owner typed it lowercase or with stray spaces.
        // The copy says what is wrong (the plate, not the car, not the network)
        // without echoing the rejected value — it is P1 and the server itself
        // never repeats it back.
        case .invalidPlate: "That plate doesn\u{2019}t look right"
        // Reachability / store failure on the plate write. Deliberately NOT
        // "Couldn't reach the car": no Tesla call is involved in §7.14 at all.
        case .plateNotSaved: "Couldn\u{2019}t save the plate"
        // MYR-316 — name the real problem (a time that has passed) and imply the
        // fix (pick a later one) without scolding. The owner most likely left the
        // sheet open past the time they picked.
        case .serviceWindowPast: "Pick a time in the future"
        // Reachability / store failure. Deliberately NOT "Couldn't reach the car":
        // no Tesla call is involved in this write at all.
        case .serviceWindowNotSaved: "Couldn\u{2019}t save the expected time"
        // MYR-342 — the one thing the owner needs to know, and it is deliberately
        // about the SWITCH rather than about "saving": what they care about is
        // whether their car is currently being offered to riders, and the honest
        // answer after a failed write is that it is still in whatever position it
        // was. Not "Couldn't reach the car" — no Tesla call is involved in §7.18
        // at any point — and not a reassurance, because the row has already
        // snapped back to the server's position beside this line.
        case .rideShareNotSaved: "Couldn\u{2019}t change ride sharing"
        // MYR-360 — names the ONE thing the owner has to know to decide what to do
        // next: the pause did not happen. It deliberately does not apologise, does
        // not say how many landed (a number nobody can act on), and does not
        // suggest a retry — flipping again re-reads a now-shorter list and is the
        // obvious next move without being told.
        case .reservationNotDeclined: "Couldn\u{2019}t decline a ride \u{2014} still sharing"
        // MYR-466 — states the OUTCOME the owner is looking at (the segment has
        // just moved back to Cool or Heat beside this line) and names the car as
        // the thing that did not move, because nothing about the app or the
        // network failed. No apology and no retry hint: tapping Auto again sends
        // the same command to a car that already applied it.
        case .autoNotAdopted: "The car stayed on manual climate"
        }
    }

    /// The tile sub token (MYR-301). MUST render within the control tile's inner
    /// width (~54pt at the uniform 11pt sub size) so it never ellipsizes — see
    /// `VehicleCommandNoticeTests.testTileTextFitsTheControlTile`, which measures
    /// every case. The FULL `message` is surfaced on the notice row below the
    /// tiles, so nothing is hidden by the shortening.
    public var tileText: String {
        switch self {
        case .waking: "Waking\u{2026}"
        case .asleep: "Asleep"
        case .pairKey: "Pair key"
        case .relink, .relinkCharging: "Re-link"
        // MYR-335 — the trailing ellipsis pushed this to 53.1pt against the
        // 49.75pt tile on the narrowest supported device. The word carries the
        // "wait a beat" sense on its own; the full "Just sent \u{2014} one moment"
        // is on the notice row underneath.
        case .cooldown: "One sec"
        // MYR-329 — every rejection keeps the SAME tile token regardless of
        // reason. The tile has ~54pt for one 11pt line; "In service" and
        // "Battery low" would fit, but "Confirm on screen" would not, and a
        // vocabulary that is specific for some reasons and generic for others
        // reads as a glitch. The reason belongs on the full-width notice row,
        // which has the space to say it properly.
        case .rejected: "Declined"
        case .failed: "Failed"
        // Never rendered on a tile (the plate is a details row, not a tile), but
        // the token is measured with the rest so the vocabulary stays uniform.
        case .invalidPlate: "Check it"
        case .plateNotSaved: "Not saved"
        // MYR-316 — likewise never tile-rendered (the expected-back time is a
        // details row), but tokenized with the rest so the vocabulary stays uniform.
        case .serviceWindowPast: "Too soon"
        case .serviceWindowNotSaved: "Not saved"
        // MYR-342 — likewise never tile-rendered (the switch is a details row),
        // tokenized with the rest so the vocabulary stays uniform and the
        // measuring test keeps covering every case.
        case .rideShareNotSaved: "Not saved"
        // MYR-360 — likewise never tile-rendered (the switch is a details row), but
        // tokenized with the rest so the vocabulary stays uniform and
        // `VehicleCommandNoticeTests` keeps measuring every case. "Still on" states
        // the RESTING position rather than the failed attempt, which is the useful
        // half here: the full sentence on the row says the rest.
        case .reservationNotDeclined: "Still on"
        // MYR-466 — the climate TILE is the on/off control and this notice is
        // about the MODE segment beside it, but the two share the `.climate` key
        // (both are HVAC start/stop), so the token is measured with the rest and
        // must fit. "Manual" is the resting state the segment has just returned
        // to, which is the useful half at tile width; the full sentence is on the
        // notice row underneath.
        case .autoNotAdopted: "Manual"
        }
    }

    /// The owner action that resolves this notice, or `nil` when there is nothing
    /// in-app to route to (waking/cooldown resolve themselves; pairing happens in
    /// the Tesla app; a rejection/unreachable car is retried by tapping again).
    public var action: VehicleCommandNoticeAction? {
        switch self {
        case .relink, .relinkCharging: .relinkTesla
        // MYR-286 — neither plate notice routes anywhere: the fix for an invalid
        // plate is to re-open the edit sheet and correct it (the row is already
        // the tap target), and a failed save is retried by saving again.
        // MYR-316 — same for the service window: a past instant is fixed by
        // re-opening the row and picking a later one; a failed save is retried
        // by saving again. Neither is a broken Tesla connection.
        // MYR-342 — and the same for the ride-share switch: a failed flip is
        // retried by flipping again, and the row is already the tap target.
        // MYR-360 — and the same for a decline that did not land: the row is the
        // tap target, and flipping again re-reads a now-shorter list. Nothing about
        // it is a broken Tesla connection either.
        // MYR-466 — and the same for an Auto that did not take: the Tesla link is
        // demonstrably fine (the command was applied), so a "Reconnect" pill would
        // send the owner to re-authorize an account that is working.
        case .waking, .asleep, .pairKey, .cooldown, .rejected, .failed,
             .invalidPlate, .plateNotSaved,
             .serviceWindowPast, .serviceWindowNotSaved,
             .rideShareNotSaved, .reservationNotDeclined, .autoNotAdopted: nil
        }
    }

    /// Transient notices describe a state that is still MOVING (the car is waking
    /// / cooling down) rather than an attempt that has finished.
    ///
    /// MYR-301 (client defect) — this used to also say the others "persist until
    /// the next tap", and that was the bug: a `.rejected` notice with no expiry and
    /// no clearing trigger short of another command stayed on the client's device
    /// indefinitely. NO notice persists indefinitely any more. A settled notice now
    /// has a bounded display and is also answered by the next successful reconcile
    /// of its control — see `LiveVehicleCommandExecutor`'s "Notice lifecycle"
    /// section, which owns both rules.
    public var isTransient: Bool { self == .waking || self == .cooldown }
}

/// Owner-facing copy for a named rejection (MYR-329).
///
/// The Kit's `VehicleCommandRejectionReason` is transport vocabulary — the
/// server's canonical token. This is the only place it becomes words a car
/// owner reads, so the copy lives here beside the rest of the notice catalog
/// rather than in the Kit (which ships no user-facing strings).
///
/// Rules the whole table follows, learned from MYR-301's copy pass:
///   • Name the CAUSE, not the failure. The owner already saw that the control
///     did not move; what they came for is why.
///   • Imply the fix where there is one the owner can perform, without a call
///     to action — none of these route anywhere in-app (`action` stays `nil`),
///     so a button-shaped sentence would be a dead end.
///   • Stay one line at the notice row's width, and keep the quiet register of
///     the rest of the catalog: no exclamation, no apology, no blame.
extension VehicleCommandRejectionReason {
    var noticeMessage: String {
        switch self {
        // The client's own case. "Commands are limited" rather than "blocked":
        // Tesla still honors a few, so an absolute claim would be wrong the
        // first time something did work.
        case .vehicleInService: "Car is in service \u{2014} commands are limited"
        // The car is waiting on its own touchscreen, so the fix is entirely
        // physical and the owner needs to know to go to the car.
        case .requiresUserAcknowledgement: "Confirm this on the car\u{2019}s screen"
        case .userNotPresent: "Someone needs to be in the car for that"
        // A setting inside the car, not a broken Tesla link — deliberately
        // worded so it cannot be confused with the `.relink` notices, which are
        // about this app's access rather than the car's own switch.
        case .remoteAccessDisabled: "Remote access is off in the car\u{2019}s settings"
        // The owner's own first guess on Jul 28. When it IS the answer, say so
        // plainly; charging is the fix and needs no explaining.
        case .lowBattery: "Battery is too low for that"
        // The one genuinely transient reason in the set: worth telling the
        // owner to simply try again, which is not true of the others.
        case .vehicleBusy: "Car is busy \u{2014} try again in a moment"
        }
    }
}

/// A control whose CURRENT displayed state the live path may not yet know
/// (MYR-251). The owner's actuator state — lock, climate on/off, setpoint, fan,
/// seat levels, trunk, charge-port, media — is NOT carried by the `VehicleState`
/// contract today (the generated `MyRobotaxiContracts.VehicleState` has no such
/// property; several of these values stream on the WS but are uncontracted, so
/// the Kit cannot fold them without a hand-written wire shape — forbidden by
/// CLAUDE.md). The live executor therefore cannot assert a resting value and
/// renders the control as unknown ("—") until the owner commands it
/// (optimistic-on-ack) or, once the contract grows the field, real telemetry
/// reconciles it (MYR-228: no fixture values on the live path). The simulated
/// executor knows every field (fixtures), keeping the M1 / drift-gate scenes
/// pixel-identical.
public enum VehicleControlField: Sendable, Hashable, CaseIterable {
    case locked
    case climateOn
    case targetTemp
    // The Auto/Cool/Heat segment (MYR-274). Known once the car's HVAC mode is
    // reconciled from the wire (`hvacAutoMode`/`hvacAcEnabled`) or the owner
    // commands Auto (`auto_conditioning_start`). Until then it is honestly unknown
    // (nothing lit) rather than the seeded `.auto` (MYR-228 / MYR-251).
    case climateMode
    case fanSpeed
    case driverSeat
    case passengerSeat
    case trunkOpen
    case chargePortOpen
    case mediaPlaying
    case volume
    /// MYR-286 — the owner-entered plate. Unlike its siblings this one IS on the
    /// read contract (`VehicleState.licensePlate`, contracts 0.15.0), so it
    /// becomes known the moment a snapshot arrives, or when the owner saves one.
    /// Until then the details row shows the designed "Add plate" affordance and
    /// the display surfaces fall back to `VIN ····xxxx` — never a fabricated plate.
    case plate
    /// MYR-316 — the owner's "expected back" entry. Like `.plate` it IS on the
    /// read contract (`VehicleState.serviceEstimatedEndAt`, contracts 0.17.0), so
    /// it becomes known the moment a snapshot arrives or the owner saves one.
    /// Until then the row shows its "Set a time" affordance rather than a
    /// fabricated estimate.
    case serviceWindow
    /// MYR-342 — the owner's ride-sharing switch. On the read contract
    /// (`VehicleState.rideShareEnabled`, contracts 0.20.0), so it becomes known the
    /// moment a snapshot carries it or the owner flips it.
    ///
    /// Its UNKNOWN state is unlike every sibling here, and the difference is the
    /// contract's: an unconfirmed lock or plate renders "—" because there is no
    /// honest default to show, whereas an unconfirmed ride-share position renders
    /// ON — "absent MUST be read as ENABLED". So this key does not gate a "—"; it
    /// only decides which of the two sources ``VehicleRideShare/resolvedEnabled``
    /// reads. There is no dash state and no unknown position, because the server
    /// column is `NOT NULL DEFAULT true` and a car whose owner has never touched
    /// the toggle genuinely IS accepting rides.
    case rideShare
}

/// One control's live command state: pending (a command is in flight — suppress
/// re-fires) and/or a settled notice from the last attempt.
public struct VehicleControlUIState: Sendable, Equatable {
    public var isPending: Bool
    public var notice: VehicleCommandNotice?

    public init(isPending: Bool = false, notice: VehicleCommandNotice? = nil) {
        self.isPending = isPending
        self.notice = notice
    }

    public static let idle = VehicleControlUIState()
}

// MARK: - Service-window provenance (MYR-320)

/// Where the resolved service window came from — as far as the app can HONESTLY
/// tell, which is the whole point of the type.
///
/// THE CONSTRAINT: contracts 0.18.0 carries NO source discriminator on either read
/// shape. `VehicleState.serviceEstimatedEndAt` is a single resolved instant, and
/// the server's precedence behind it (Tesla's `service_etc` first, the owner's
/// entry second) is invisible on the wire — the Kit's own
/// `VehicleServiceWindowPayloads` says so in as many words: "a client CANNOT tell
/// from the wire which source produced the value it reads back".
///
/// THE ONE PLACE THE APP LEARNS IT ANYWAY: the write echo. The owner submits an
/// instant; the server answers with what it RESOLVED. If the echo comes back
/// different, Tesla's estimate demonstrably outranked the entry — Tesla has one,
/// and it is what is on screen. If the echo matches exactly, precedence had
/// nothing to apply — Tesla holds no estimate for this visit and the value shown
/// is the owner's own. Both are OBSERVED FACTS about a round trip that happened,
/// not inferences about a value read cold.
///
/// So `.unknown` is not a failure mode, it is the honest resting state — a fresh
/// launch reading a stored window knows nothing about its provenance and says
/// nothing about it. The row renders a source note ONLY in the two proven cases.
/// (If the read shape ever grows a discriminator, this type is where it lands and
/// every consumer keeps working.)
public enum ServiceWindowSource: Sendable, Equatable {
    /// No proof either way — render NO source note. The state after any cold read.
    case unknown
    /// PROVEN: the server's echo disagreed with the owner's submission, so Tesla's
    /// own estimate is what is being shown.
    case tesla
    /// PROVEN: the server adopted the owner's submission verbatim, so Tesla has no
    /// estimate for this visit and this value was set by hand.
    case manual
}

/// Everything a `VehicleControls` tree needs to render one tick of the
/// controls surface (vehicle-controls.jsx:208-225 `useState` block).
public struct VehicleControlsSnapshot: Sendable, Equatable {
    public var locked: Bool
    public var climateOn: Bool
    public var targetTemp: Int
    public var climateMode: VehicleClimateMode
    public var fanSpeed: Int
    public var driverSeatHeatLevel: Int
    public var driverSeatMode: VehicleSeatClimateMode
    public var passengerSeatHeatLevel: Int
    public var passengerSeatMode: VehicleSeatClimateMode
    public var trunkOpen: Bool
    public var chargePortOpen: Bool
    public var mediaPlaying: Bool
    public var trackIndex: Int
    public var volume: Double
    public var scrubPercent: Double
    /// The RAW owner-entered license plate — empty when none is set (MYR-286).
    /// NOT the display string: the `VIN ····xxxx` fallback belongs to
    /// `VehicleContractMapping.plateDisplay` and to `Vehicle.plate`, which is what
    /// the switcher / Settings rows / rider chip render. Keeping this one raw is
    /// what lets the edit sheet prefill exactly what the owner typed and lets an
    /// unset plate render the designed "Add plate" affordance instead of a VIN the
    /// owner cannot edit. The simulated executor seeds it from the fixture plate,
    /// so M1 is unchanged.
    public var plate: String
    /// MYR-316 — the RAW resolved service window (`serviceEstimatedEndAt`), or
    /// `nil` when none is known. This is the value the "Expected back" row shows
    /// and the entry sheet prefills; it is the SERVER'S RESOLVED value, which may
    /// be Tesla's estimate rather than the owner's own entry (the wire carries no
    /// source discriminator, and the owner does not need one — the server keeps
    /// Tesla-precedence and the app simply renders what it resolved).
    ///
    /// Always `nil` on the simulated path, which is what keeps the M1 /
    /// drift-gate sheets pixel-identical: a nil window renders nothing anywhere.
    public var serviceEstimatedEndAt: Date?
    /// MYR-320 — what the app can HONESTLY say about where
    /// ``serviceEstimatedEndAt`` came from. `.unknown` (the default, and what a
    /// cold launch always holds) renders no source note at all. See
    /// ``ServiceWindowSource``.
    public var serviceWindowSource: ServiceWindowSource = .unknown
    /// MYR-342 — the owner's ride-sharing switch (contracts 0.20.0
    /// `rideShareEnabled`): `true` = riders can request this car, `false` = the
    /// owner has PAUSED requests. This is the position the toggle row renders and
    /// the value the write echoes back.
    ///
    /// Defaults to `true`, and that default is the contract's own rather than a
    /// convenient choice: "TRUE is the ordinary state and the state every vehicle
    /// starts in", the server column is `BOOLEAN NOT NULL DEFAULT true`, and an
    /// absent wire value MUST read as enabled. It is therefore also what keeps the
    /// simulated path and every drift-gate scene unchanged — the simulated executor
    /// never writes it and the row is live-only, so nothing renders from it there.
    ///
    /// Note there is no optional here and no unknown state, unlike
    /// `serviceEstimatedEndAt` beside it. That is deliberate: the honest-unknown
    /// treatment the rest of this struct uses would produce a switch with no
    /// position, and the contract is explicit that absence is not unknown — it is
    /// enabled. The MYR-251 ledger still tracks whether the value was CONFIRMED
    /// (`isKnown(.rideShare)`), which is what ``VehicleRideShare/resolvedEnabled``
    /// consults; it just never produces a dash.
    public var rideShareEnabled: Bool = true

    public init(
        locked: Bool,
        climateOn: Bool,
        targetTemp: Int,
        climateMode: VehicleClimateMode,
        fanSpeed: Int,
        driverSeatHeatLevel: Int,
        driverSeatMode: VehicleSeatClimateMode,
        passengerSeatHeatLevel: Int,
        passengerSeatMode: VehicleSeatClimateMode,
        trunkOpen: Bool,
        chargePortOpen: Bool,
        mediaPlaying: Bool,
        trackIndex: Int,
        volume: Double,
        scrubPercent: Double,
        plate: String,
        serviceEstimatedEndAt: Date? = nil
    ) {
        self.locked = locked
        self.climateOn = climateOn
        self.targetTemp = targetTemp
        self.climateMode = climateMode
        self.fanSpeed = fanSpeed
        self.driverSeatHeatLevel = driverSeatHeatLevel
        self.driverSeatMode = driverSeatMode
        self.passengerSeatHeatLevel = passengerSeatHeatLevel
        self.passengerSeatMode = passengerSeatMode
        self.trunkOpen = trunkOpen
        self.chargePortOpen = chargePortOpen
        self.mediaPlaying = mediaPlaying
        self.trackIndex = trackIndex
        self.volume = volume
        self.scrubPercent = scrubPercent
        self.plate = plate
        self.serviceEstimatedEndAt = serviceEstimatedEndAt
    }
}

/// The M1/M2 seam for vehicle commands. `VehicleControls` reads `controls`;
/// it doesn't know or care whether a mutator resolves a local optimistic
/// write (M1) or a round trip through the signed-command proxy (M2/P11).
/// Conforming types must be `@Observable` classes (see
/// `VehicleTelemetrySource`'s doc comment, VehicleTelemetry.swift:12-15, for
/// why `any VehicleCommandExecutor` is still safe to read from a SwiftUI body).
@MainActor
public protocol VehicleCommandExecutor: AnyObject, Observable {
    var controls: VehicleControlsSnapshot { get }

    func setLocked(_ locked: Bool) async throws
    func setClimateOn(_ on: Bool) async throws
    func setTargetTemp(_ temp: Int) async throws
    func setClimateMode(_ mode: VehicleClimateMode) async throws
    func setFanSpeed(_ speed: Int) async throws
    func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws
    func setSeatClimateMode(_ seat: VehicleSeatPosition, mode: VehicleSeatClimateMode) async throws
    func setTrunkOpen(_ open: Bool) async throws
    func setChargePortOpen(_ open: Bool) async throws
    func setMediaPlaying(_ playing: Bool) async throws
    func skipTrack(_ direction: VehicleTrackDirection) async throws
    func setVolume(_ volume: Double) async throws
    func setPlate(_ plate: String) async throws
    /// MYR-316 — persist the owner's "expected back" time (`nil` clears). Like
    /// `setPlate` this is NOT a Tesla command: it is an owner-scoped write whose
    /// response carries the server's RESOLVED window, which the executor adopts.
    func setServiceWindow(_ expectedEndAt: Date?) async throws
    /// MYR-342 — pause (`false`) or resume (`true`) ride requests for this vehicle.
    /// Like `setPlate`/`setServiceWindow` this is NOT a Tesla command: it is an
    /// owner-scoped write (rest-api.md §7.18) whose response carries the server's
    /// RESOLVED position, which the executor adopts instead of the bool it sent.
    func setRideShareEnabled(_ enabled: Bool) async throws

    /// Continuous scrub drag — not a vehicle command (see header); synchronous
    /// so the slider tracks the finger with no await latency.
    func setScrubPercent(_ percent: Double)

    // MARK: Command UX seam (MYR-249)

    /// The in-flight / error state for a backend-backed control. Default `.idle`
    /// (below) — the simulated executor never has an in-flight command, keeping
    /// the M1 / drift-gate scenes pixel-identical.
    func uiState(for key: VehicleControlKey) -> VehicleControlUIState

    /// Whether a control maps to a real backend command on THIS executor. Default
    /// `true` (below) — simulated everything is interactive. The live executor
    /// returns `false` for `.chargePort` (no §7.9 command) so the tile is honestly
    /// disabled rather than faked.
    func isSupported(_ key: VehicleControlKey) -> Bool

    // MARK: Honest-state seam (MYR-251)

    /// Whether THIS executor knows the control's current displayed state. Default
    /// `true` (below) — the simulated executor's fixtures are authoritative, so
    /// M1 / drift-gate scenes render every value and stay pixel-identical. The
    /// live executor returns `false` until the field is confirmed by a command
    /// ack, so an unconfirmed control renders a design-consistent unknown ("—")
    /// instead of a fixture value on the live path (MYR-228 / MYR-251).
    func isKnown(_ field: VehicleControlField) -> Bool

    // MARK: Notice seam (MYR-360)

    /// Raise a SETTLED notice for `key` from a caller that owns the attempt but not
    /// this executor's command machinery.
    ///
    /// MYR-360's pause flow is the one such caller: its work is a read and a set of
    /// declines on the ride-request API, and its failures still have to reach the
    /// owner where every other ride-share failure does — the row beside the switch.
    /// Duplicating the notice surface for it would give one row two notice systems
    /// with two lifetimes.
    ///
    /// The live executor routes this straight into the EXISTING `settle`, so the
    /// notice inherits the whole MYR-301 lifecycle unchanged: the same generation
    /// guard, the same 6s bounded display, the same clear-on-reconcile. Default:
    /// no-op — the simulated executor renders no notices at all, which is what
    /// keeps every M1 / drift-gate scene pixel-identical.
    func raiseNotice(_ notice: VehicleCommandNotice, for key: VehicleControlKey)
}

public extension VehicleCommandExecutor {
    func uiState(for key: VehicleControlKey) -> VehicleControlUIState { .idle }
    func raiseNotice(_ notice: VehicleCommandNotice, for key: VehicleControlKey) {}
    func isSupported(_ key: VehicleControlKey) -> Bool { true }
    func isKnown(_ field: VehicleControlField) -> Bool { true }
}

/// M1 implementation: mutates `controls` synchronously and locally, matching
/// the prototype's own `useState` setters — no network, no delay.
@Observable
@MainActor
public final class SimulatedVehicleCommandExecutor: VehicleCommandExecutor {
    public private(set) var controls: VehicleControlsSnapshot

    /// Number of fake tracks in the media fixture (vehicle-controls.jsx:199-203
    /// `TRACKS`) — kept in sync with `VehicleMediaTrack.all.count`.
    private let trackCount = 3

    /// vehicle-controls.jsx:205-225 defaults. `mediaPlaying` seeds from
    /// `driving` (jsx `useState(driving)`, line 222); `plate` from the
    /// vehicle fixture (jsx `v.plate || ''`, line 220).
    public init(driving: Bool, plate: String) {
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

    public func setLocked(_ locked: Bool) async throws {
        controls.locked = locked
    }

    public func setClimateOn(_ on: Bool) async throws {
        controls.climateOn = on
    }

    public func setTargetTemp(_ temp: Int) async throws {
        controls.targetTemp = min(82, max(60, temp)) // vehicle-controls.jsx:262,270
    }

    public func setClimateMode(_ mode: VehicleClimateMode) async throws {
        controls.climateMode = mode
    }

    public func setFanSpeed(_ speed: Int) async throws {
        controls.fanSpeed = min(10, max(0, speed))
    }

    public func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws {
        let clamped = min(3, max(0, level))
        switch seat {
        case .driver: controls.driverSeatHeatLevel = clamped
        case .passenger: controls.passengerSeatHeatLevel = clamped
        }
    }

    public func setSeatClimateMode(_ seat: VehicleSeatPosition, mode: VehicleSeatClimateMode) async throws {
        // vehicle-controls.jsx:90 — switching Heat/Cool resets the level.
        switch seat {
        case .driver:
            controls.driverSeatMode = mode
            controls.driverSeatHeatLevel = 0
        case .passenger:
            controls.passengerSeatMode = mode
            controls.passengerSeatHeatLevel = 0
        }
    }

    public func setTrunkOpen(_ open: Bool) async throws {
        controls.trunkOpen = open
    }

    public func setChargePortOpen(_ open: Bool) async throws {
        controls.chargePortOpen = open
    }

    public func setMediaPlaying(_ playing: Bool) async throws {
        controls.mediaPlaying = playing
    }

    public func skipTrack(_ direction: VehicleTrackDirection) async throws {
        switch direction {
        case .previous: controls.trackIndex = (controls.trackIndex + trackCount - 1) % trackCount
        case .next: controls.trackIndex = (controls.trackIndex + 1) % trackCount
        }
        controls.scrubPercent = 0 // vehicle-controls.jsx:365,371
    }

    public func setVolume(_ volume: Double) async throws {
        controls.volume = min(100, max(0, volume))
    }

    public func setScrubPercent(_ percent: Double) {
        controls.scrubPercent = min(100, max(0, percent))
    }

    /// MYR-316 — M1 has no backend and no in-service vehicle in its fixtures, so
    /// this writes locally like every other simulated setter. It exists to keep
    /// the seam total; nothing in the simulated fleet ever calls it, and the
    /// simulated `serviceEstimatedEndAt` stays nil, so every drift-gate scene
    /// renders exactly as it did before this issue.
    public func setServiceWindow(_ expectedEndAt: Date?) async throws {
        controls.serviceEstimatedEndAt = expectedEndAt
    }

    public func setPlate(_ plate: String) async throws {
        controls.plate = plate
    }

    /// MYR-342 — M1 has no backend, and the toggle row is LIVE-ONLY (it is gated
    /// on `VehicleControls.isLive`, the same live-only gate MYR-315's freshness
    /// stamp uses), so nothing in the simulated fleet ever calls this. It writes
    /// locally like every other simulated setter purely to keep the seam total;
    /// the simulated `rideShareEnabled` therefore stays at its `true` default and
    /// every drift-gate scene renders exactly as it did before this issue.
    public func setRideShareEnabled(_ enabled: Bool) async throws {
        controls.rideShareEnabled = enabled
    }
}
