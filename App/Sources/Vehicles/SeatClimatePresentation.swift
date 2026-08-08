import Foundation

// MARK: - SeatClimatePresentation (MYR-280)
//
// The pure decision layer behind the seat-climate section. It fixes the client's
// three complaints (TestFlight 202607251737) — a "SEAT HEATING" label sitting over
// a snowflake, an ambiguous sun-for-heat icon, and no way to switch a seat between
// heat and cool — without any per-view guesswork, so the choices are unit-testable.
//
// Everything here is pure; the views (`ClimateSection.SeatRow`) read it and add no
// styling of their own beyond the existing tokens.

/// MYR-441 — whether this Tesla HAS ventilated (cooled) seats, in the three
/// answers the wire can actually support.
///
/// This replaces a non-optional `Bool` (`Vehicle.seatVent`) that had no way to say
/// "nobody has asked yet", so every unread car was filed as heat-only and the
/// section asserted a **no** it had no evidence for. Making the third state
/// representable is the fix; the label and the toggle merely read it.
public enum SeatClimateCapability: Equatable, Sendable {
    /// The car has cooled seats — the REST spec field says so, or a seat-cooler
    /// read-back is present (MYR-299/308).
    case ventilated
    /// The car does NOT have cooled seats, on the contract's own authority
    /// (`seatCoolingCapable == false`). The one arm that may deny cooling.
    case heatOnly
    /// Not established. No snapshot yet, a server predating MYR-308, or a
    /// response whose seat fields were withheld. **Never rendered as a no.**
    case unknown
}

enum SeatClimatePresentation {
    // Unmistakable, single-metaphor icons: a flame is heat, a snowflake is cool.
    // The old "sun.max.fill" for heat read as brightness, not warmth ("some sun
    // icon… super difficult", client) — flame removes that ambiguity.
    static let heatIcon = "flame.fill"
    static let coolIcon = "snowflake"

    static func icon(mode: VehicleSeatClimateMode) -> String {
        mode == .cool ? coolIcon : heatIcon
    }

    /// Whether the car HAS ventilated (cooled) seats — a capability, decided once
    /// from the wire, not a reading of what the seats are doing right now.
    ///
    /// MYR-299. Nothing in the stack carries a real capability field: the backend
    /// reads only `trim_badging`, and `vehicle_config.seat_type` is never decoded.
    /// The contracted stand-in is the **presence** of the seat-cooler telemetry —
    /// a car without ventilated seats never emits Tesla protos 237/238 at all,
    /// while a car with them emits values that INCLUDE `0` (present-but-off).
    /// So a non-nil `seatCoolerLeft`/`seatCoolerRight` — **including `0`** — is the
    /// capability, and `nil`/`nil` is an honest "this car has no cooled seats".
    ///
    /// This is the fix for the client's report ("Still can't cooling seats… this
    /// Tesla DOES have ventilated seats"). The old input was `seatVentEnabled`,
    /// which is a RUNTIME on/off — is a vent spinning this second — not a
    /// capability, so a vented car with both seats off looked identical to a
    /// heat-only car and Cool was unreachable.
    ///
    /// `seatVentEnabled` is kept as an additional OR-signal (belt and braces): if
    /// the car actively says ventilation is on, that is also proof it has vents,
    /// whatever the cooler fields are doing. `false` is NOT proof of absence, so
    /// only `true` contributes.
    ///
    /// MYR-308 — contracts 0.16.0 finally carries the REAL capability:
    /// `seatCoolingCapable`, read by the server from Tesla's REST
    /// `vehicle_data.vehicle_config.has_seat_cooling`. It OUTRANKS the heuristic in
    /// both directions, because it is a fact about the car rather than an inference
    /// from what the car happens to be emitting:
    ///
    ///   • `true`  → capable. (The heuristic agrees in practice; the spec is simply
    ///     available sooner — a car that has never actuated a cooler still says so.)
    ///   • `false` → NOT capable, AUTHORITATIVELY. The schema is explicit that a
    ///     client "MUST NOT offer seat-cooling controls — no greyed-out row, no
    ///     disabled slider that implies the hardware exists". So an explicit false
    ///     BEATS the presence heuristic even if cooler read-backs are somehow
    ///     present (a firmware quirk emitting 0s on a heat-only car is exactly the
    ///     false positive MYR-299's presence rule cannot see on its own).
    ///   • `nil`   → absent: the server predates MYR-308 or has not completed a
    ///     vehicle-config read yet. The schema requires the fall-back to the MYR-299
    ///     telemetry-presence heuristic — NOT hiding the control outright, which
    ///     would re-break the client's ventilated car on every pre-0.16.0 server.
    ///
    /// **MYR-441 — THIS RETURNED A NON-OPTIONAL `Bool` AND SO HAD NOWHERE TO PUT
    /// "NOBODY HAS ASKED".** Its own doc conceded the gap ("before the first
    /// snapshot every input is `nil` and the section stays honestly heat-only"),
    /// and the contract contradicts it in as many words: an absent
    /// `seatCoolingCapable` *"does NOT mean 'no seat cooling'"*. The function is
    /// **deleted rather than kept as a wrapper** — a `Bool` spelling of this
    /// question that still compiles is exactly the foot-gun MYR-369 removed
    /// `SharePermission.rank` for, and every call site had to be visited anyway.
    ///
    /// **THE POSITIVE HEURISTIC IS A DETECTOR, NOT A DECISION.** MYR-299's rule is
    /// that the PRESENCE of a seat-cooler read-back — including `0` — proves the
    /// hardware exists. Presence is evidence; ABSENCE is not its negation, because
    /// a car that has not been read at all, a server predating MYR-308, and a
    /// response whose cabin group was withheld all look exactly like a car with no
    /// vents. Folding those into `false` is what made the section assert "this
    /// Tesla cannot cool its seats" about cars nobody had asked.
    ///
    /// **THE POSITIVE HEURISTIC IS A DETECTOR, NOT A DECISION.** MYR-299's rule is
    /// that the PRESENCE of a seat-cooler read-back — including `0` — proves the
    /// hardware exists. Presence is evidence; ABSENCE is not its negation, because
    /// a car that has not been read at all, a server predating MYR-308, and a
    /// response whose cabin group was withheld all look exactly like a car with no
    /// vents. Folding those into `false` is what made the section assert "this
    /// Tesla cannot cool its seats" about cars nobody had asked.
    ///
    /// So only `seatCoolingCapable` can say **no**, which is precisely the field
    /// the contract makes authoritative in both directions (MYR-308: an explicit
    /// `false` outranks the heuristic even when cooler read-backs are somehow
    /// present, per the schema's *"MUST NOT offer seat-cooling controls"*).
    /// Everything else is either a positive detection or an honest `.unknown`.
    static func capability(
        seatCoolingCapable: Bool?,
        seatCoolerLeft: Int?,
        seatCoolerRight: Int?,
        seatVentEnabled: Bool?
    ) -> SeatClimateCapability {
        // The REST spec field, authoritative both ways (MYR-308).
        if let seatCoolingCapable { return seatCoolingCapable ? .ventilated : .heatOnly }
        // MYR-299's presence heuristic, as a positive detector only.
        if seatCoolerLeft != nil || seatCoolerRight != nil || seatVentEnabled == true {
            return .ventilated
        }
        return .unknown
    }

    /// Whether the seat section should offer the Heat/Cool toggle and read as
    /// "SEAT CLIMATE" (heat AND cool) rather than "SEAT HEATING". True when the
    /// vehicle HAS ventilated seats OR either seat is currently reading a
    /// COOL state — the crux of the client's incoherence: a seat showing a
    /// snowflake must never sit under a "heating" label with no way to switch it
    /// back. A genuinely heat-only car (no vent hardware, neither seat cooling)
    /// keeps the honest "SEAT HEATING" label and no toggle.
    ///
    /// MYR-299: `seatVent` is now the CAPABILITY (`hasVentilatedSeats`, derived
    /// from cooler-field presence), not the `seatVentEnabled` runtime flag it used
    /// to be. The active-cooling OR-branch stays as a safety net for a car that
    /// reports a cool level before its capability is otherwise established.
    ///
    /// MYR-308 keeps that safety net even though `seatCoolingCapable: false` is
    /// authoritative, and deliberately so: the branch fires only when a seat is
    /// ACTIVELY reading cool, which a heat-only car cannot report. If the two
    /// signals ever did contradict each other, a seat visibly cooling under a
    /// "SEAT HEATING" label with no way to switch it back is the exact incoherence
    /// MYR-280 was filed for — the live reading wins over the spec sheet there.
    ///
    /// MYR-441 — the parameter is the three-state capability now. `.unknown` does
    /// NOT support cool: offering a Heat↔Cool toggle on a car that may not have
    /// the hardware is the schema's own prohibition pointed the other way, and it
    /// would put a control on screen whose command the car would refuse. What
    /// changes for `.unknown` is only the LABEL — see `sectionLabel`.
    static func supportsCool(
        capability: SeatClimateCapability,
        driverMode: VehicleSeatClimateMode,
        passengerMode: VehicleSeatClimateMode
    ) -> Bool {
        capability == .ventilated || driverMode == .cool || passengerMode == .cool
    }

    /// MYR-319 — whether the seat block (label, per-seat rows, Heat↔Cool toggle)
    /// belongs on screen for this climate state.
    ///
    /// The seats are a property of the CAR, not of the climate being on: whether
    /// this Tesla has cooled seats is answered by the REST spec field
    /// (`seatCoolingCapable`) on the cold snapshot, and it is true whether the
    /// HVAC is running or not. The block used to live ONLY inside the climate-ON
    /// branch, so the client's car — in service, therefore reporting no
    /// `isClimateOn` at all — could never show it: the snapshot said
    /// `seatCoolingCapable: true` and the owner still saw no Heat↔Cool toggle
    /// anywhere in the sheet.
    ///
    /// Three states, and only one of them hides it:
    ///   • climate CONFIRMED ON → shown (unchanged).
    ///   • climate UNKNOWN (live, car not streaming — the client's case) → shown.
    ///     The rows already carry their own honest known/unknown handling
    ///     (`known:` / `hasSnapshot:` / `isStreaming:`, MYR-260/280), so they read
    ///     "— Unavailable" rather than asserting a seat state nobody confirmed.
    ///   • climate CONFIRMED OFF → hidden, exactly as the prototype has it: the
    ///     off card is its own designed layout (a "Turn on" invitation plus the
    ///     cabin temps), and the seats come back with the HVAC.
    ///
    /// The simulated path can only ever be confirmed on/off — the simulated
    /// executor knows every field — so `.simulated` and every drift-gate scene
    /// render byte-identically.
    static func showsSeatBlock(climateOnKnown: Bool, climateOn: Bool) -> Bool {
        !climateOnKnown || climateOn
    }

    /// MYR-441 — three labels, because the header was carrying the VALUE.
    ///
    /// "SEAT CLIMATE" and "SEAT HEATING" are not two names for one region; the
    /// second is a **claim about the car** ("this Tesla only heats"), and it was
    /// being made about every car whose seat-cooling capability had never been
    /// read. There is no glyph to swap here — the header IS the reading — so the
    /// honest-unknown render is the region's NEUTRAL name, `"SEATS"`, which
    /// asserts nothing in either direction. The trailing "Heat & ventilation"
    /// caption and the Heat↔Cool toggle stay absent, so nothing claims cooling
    /// either. This is the repo's `"—"` grammar with the label and the value
    /// finally separated: the row is never omitted, only the assertion is.
    ///
    /// Live-path-only, and it has no prototype counterpart for the same reason the
    /// MYR-315 freshness stamp does not: a simulated snapshot knows every field,
    /// so `.unknown` is unreachable in SIM and no drift-gate scene grows it.
    ///
    /// Both existing labels are byte-identical for the inputs that produced them
    /// before — a capable car still reads "SEAT CLIMATE", and a car the server
    /// authoritatively says is heat-only (`seatCoolingCapable: false`, the
    /// `ownerVehicleSeatsHeatOnly` scene) still reads "SEAT HEATING".
    static func sectionLabel(capability: SeatClimateCapability, supportsCool: Bool) -> String {
        if supportsCool { return "SEAT CLIMATE" }
        return capability == .heatOnly ? "SEAT HEATING" : "SEATS"
    }

    /// The unmistakable per-seat state caption. Known → "Heating" / "Cooling" /
    /// "Off" (mode stated in words, not left to icon color alone). Unknown (live,
    /// not yet confirmed) → `nil` so the caller shows the honest freshness sub
    /// (Syncing / Unavailable) instead of fabricating a state (MYR-260 pattern).
    static func stateCaption(known: Bool, mode: VehicleSeatClimateMode, level: Int) -> String? {
        guard known else { return nil }
        if level <= 0 { return "Off" }
        return mode == .cool ? "Cooling" : "Heating"
    }
}
