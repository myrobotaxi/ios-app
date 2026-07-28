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
    /// Tolerant of absence throughout: before the first snapshot every input is
    /// `nil` and the section stays honestly heat-only until the car says otherwise.
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
    static func hasVentilatedSeats(
        seatCoolingCapable: Bool? = nil,
        seatCoolerLeft: Int?,
        seatCoolerRight: Int?,
        seatVentEnabled: Bool?
    ) -> Bool {
        if let seatCoolingCapable { return seatCoolingCapable }
        return seatCoolerLeft != nil || seatCoolerRight != nil || seatVentEnabled == true
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
    static func supportsCool(
        seatVent: Bool,
        driverMode: VehicleSeatClimateMode,
        passengerMode: VehicleSeatClimateMode
    ) -> Bool {
        seatVent || driverMode == .cool || passengerMode == .cool
    }

    static func sectionLabel(supportsCool: Bool) -> String {
        supportsCool ? "SEAT CLIMATE" : "SEAT HEATING"
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
