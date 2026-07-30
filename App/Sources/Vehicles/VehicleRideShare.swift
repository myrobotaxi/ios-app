import Foundation

// MARK: - VehicleRideShare (MYR-342)
//
// The PURE decision layer for the owner's ride-sharing switch — the single
// nullable boolean `rideShareEnabled` (contracts 0.20.0), which says whether this
// car's OWNER currently accepts ride requests against it. Two consumers, two
// rules, both here so each is unit-testable without a view, a network, or a
// backend:
//
//   1. THE OWNER'S TOGGLE — the row in the Status & location card: its position,
//      and the sub-caption that says what that position means.
//   2. THE RIDER'S AVAILABILITY — whether the car reads as PAUSED, which
//      `LiveFleetMemberMapping` folds into `FleetUnavailability`.
//
// THE HONESTY RULE THAT GOVERNS BOTH — and it points the OPPOSITE way from
// `VehicleServiceWindow`'s, which is exactly why it is written out rather than
// assumed: `nil` means ENABLED. Absent is not "unknown", not "we couldn't read
// it", and above all not "paused". The contract states the consumer rule in as
// many words: "ABSENT means the server predates contracts v0.20.0 and MUST be read
// as ENABLED (true). Absence NEVER means paused — consumers MUST NOT render a
// paused state, MUST NOT hide the ride-request affordance, and MUST NOT fail
// closed on a missing key."
//
// So every predicate here tests `== false` EXPLICITLY. `!= true` would be the
// obvious spelling and would be exactly wrong: it makes every pre-0.20.0 server,
// and every row a build predates, withdraw a car nobody withdrew.
//
// WHAT THIS SWITCH IS, in one line, because it decides where the row lives: it is
// OWNER INTENT, not vehicle state. `status == .inService`, `hasActiveRide`, and
// `offline` are all facts the car (or the ride system) reports about itself and
// all of them END on their own. A pause is open-ended and nothing but the owner
// reaching for the switch again clears it — which is why the server applies it to
// SCHEDULED rides too, a deliberate deviation from the reservation exemption
// MYR-313 grants the others (rest-api.md §7.18).

public enum VehicleRideShare {

    // MARK: - 1. The predicate

    /// Whether the owner has PAUSED ride requests for this vehicle.
    ///
    /// THE one place `rideShareEnabled` is interpreted. Explicit-false, never
    /// `!= true` — see the header. `nil` (absent key, older server) and `true`
    /// both mean the car is taking requests.
    public static func isPaused(_ rideShareEnabled: Bool?) -> Bool {
        rideShareEnabled == false
    }

    /// The toggle's position for a raw wire value — the inverse of ``isPaused(_:)``,
    /// named for the surface that reads it so a call site never has to negate.
    public static func isEnabled(_ rideShareEnabled: Bool?) -> Bool {
        !isPaused(rideShareEnabled)
    }

    // MARK: - 1b. THE resolver — one value, the owner's read surface

    /// The switch position the owner's toggle displays, from the ONE source the
    /// sheet must share.
    ///
    /// The same shape, and the same reasoning, as
    /// ``VehicleServiceWindow/resolvedEndAt(committed:isCommitted:snapshot:)`` —
    /// and it exists here BEFORE the equivalent defect can ship rather than after,
    /// because this field has the identical delivery property that caused it:
    /// `rideShareEnabled` carries NO WebSocket delta (rest-api.md §7.18: "a
    /// ride-share edit fires no `vehicle_update` frame"), so a snapshot cannot
    /// catch up with a write until the next cold REST read. A surface reading the
    /// snapshot alone would show a flip that the server accepted as if nothing had
    /// happened — which reads exactly like a toggle that does not work.
    ///
    /// THE COMMITTED SIDE IS THE SOURCE, and it is a strict superset rather than a
    /// competing opinion: the executor adopts the write ECHO on every successful
    /// PUT and adopts the wire value off every snapshot that carried one, so once
    /// anything has been committed it holds the same answer the snapshot does or a
    /// newer one.
    ///
    /// `isCommitted` is what makes a PAUSE stick. "Prefer the non-nil value" would
    /// be the obvious rule and would be wrong here in a way it is not for the
    /// service window: `false` is a perfectly ordinary Bool, so there is no "empty"
    /// spelling to fall back through — the only thing distinguishing "the owner
    /// just paused this" from "we have never been told" is whether a write or a
    /// read has confirmed it.
    ///
    /// Nothing committed → the snapshot is all we know, and an ABSENT snapshot
    /// value resolves to ENABLED (never paused). That is the cold-launch path and
    /// the whole simulated path, where both sides are nil — so every drift-gate
    /// scene renders a switch that is ON, which is what the pre-MYR-342 app
    /// effectively was.
    public static func resolvedEnabled(committed: Bool?, isCommitted: Bool, snapshot: Bool?) -> Bool {
        isCommitted ? isEnabled(committed) : isEnabled(snapshot)
    }

    // MARK: - 2. The owner's copy

    /// The toggle row's label. Names the FEATURE, not the action — a row label
    /// that said "Pause ride sharing" would read as a button and would invert its
    /// own meaning the moment the switch was already off.
    public static let rowLabel = "Ride sharing"

    /// The muted sub-caption beneath the label, which is where the row does its
    /// real work: a bare switch labelled "Ride sharing" leaves an owner to guess
    /// which way is which. Both halves state the CONSEQUENCE in the rider's terms —
    /// what does this position mean for someone trying to book the car — rather
    /// than restating the switch position, which the switch already shows.
    ///
    /// The paused half leads with the state word so the row scans at a glance in a
    /// dense sheet, then says plainly what is off. It deliberately does NOT
    /// apologise or imply a fault: pausing is a normal, temporary thing an owner
    /// chose, and copy that framed it as a problem would push them to un-pause a
    /// car they meant to withdraw.
    public static func rowCaption(isEnabled: Bool) -> String {
        isEnabled
            ? "Riders can request this car"
            : "Paused \u{2014} ride requests are off"
    }
}

// MARK: - The resolver, bound to the two objects the owner sheet actually holds

@MainActor
public extension VehicleRideShare {
    /// ``resolvedEnabled(committed:isCommitted:snapshot:)`` applied to the executor
    /// + snapshot pair the owner sheet already has in hand. Keeping the pure rule
    /// and this binding in one file is what stops a call site from re-deriving
    /// "which one wins" for itself — the split that caused MYR-316's stale-window
    /// defect on the sibling field.
    ///
    /// `isKnown(.rideShare)` is the executor's own MYR-251 ledger of confirmed
    /// fields; the write raises it on every successful flip and `reconcile` raises
    /// it whenever a snapshot actually carried a boolean (never off an absent one —
    /// the MYR-228 tripwire). The simulated executor answers `true` with its `true`
    /// value, which agrees with its always-nil snapshot, so M1 resolves to ON
    /// exactly as it did before this issue existed.
    static func resolvedEnabled(
        executor: any VehicleCommandExecutor,
        snapshot: VehicleTelemetrySnapshot
    ) -> Bool {
        resolvedEnabled(
            committed: executor.controls.rideShareEnabled,
            isCommitted: executor.isKnown(.rideShare),
            snapshot: snapshot.rideShareEnabled
        )
    }
}
