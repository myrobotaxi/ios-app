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

    /// Whether the seat section should offer the Heat/Cool toggle and read as
    /// "SEAT CLIMATE" (heat AND cool) rather than "SEAT HEATING". True when the
    /// vehicle advertises ventilated seats OR either seat is currently reading a
    /// COOL state — the crux of the client's incoherence: a seat showing a
    /// snowflake must never sit under a "heating" label with no way to switch it
    /// back. A genuinely heat-only car (no vent, neither seat cooling) keeps the
    /// honest "SEAT HEATING" label and no toggle.
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
