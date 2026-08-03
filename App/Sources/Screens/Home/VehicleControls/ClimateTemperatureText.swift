import Foundation

/// How the climate surfaces render a temperature that is not known.
///
/// This was a `private func` on `ClimateSection` until MYR-440. It is promoted
/// here for the reason `RideRequestFieldContentType` was: **a formatter buried in
/// a view body is not assertable, and a named one is.** Nothing about the output
/// changed — the em-dash and the degree suffix are byte-identical, so every
/// existing capture is untouched.
///
/// The promotion earns its keep because MYR-440 made the nil arm REACHABLE ON THE
/// LIVE PATH for the first time. Before it, `VehicleState.interiorTemp` /
/// `.exteriorTemp` were non-optional `Int`, so `VehicleContractMapping` could only
/// ever hand these surfaces a real number once a snapshot had arrived; the dash
/// was reachable only pre-snapshot or under a DEBUG override. The MYR-435 viewer
/// mask withholds both fields outright, so a shared viewer now renders the dash
/// for the whole session — which makes it a real rendering rather than a
/// placeholder, and worth a test that reads the actual string.
enum ClimateTemperatureText {

    /// The em-dash the design uses for an unavailable value.
    ///
    /// Deliberately the same glyph as `BatteryReadout.dash` (U+2014) — the app has
    /// ONE honest-unknown mark, and two surfaces spelling it differently is the
    /// drift this constant exists to prevent. `ClimateTemperatureTextTests` asserts
    /// the two are equal rather than trusting the two literals to stay in step.
    static let dash = "\u{2014}"

    /// `68` → `"68°"`, `nil` → `"—"`.
    ///
    /// The unit is DROPPED with the value rather than left stranded as `"—°"`:
    /// unlike `BatteryReadout`'s `"— used"`, where the trailing word is a label
    /// that still reads as English, a degree sign with no number in front of it
    /// reads as a rendering fault. The LABEL beside this value ("INTERIOR" /
    /// "EXTERIOR", or the "Interior … · Outside …" line) is what survives to say
    /// which reading is missing, so the row is never omitted — only the glyph
    /// swaps, which is the repo's honest-unknown grammar.
    static func degrees(_ value: Int?) -> String {
        value.map { "\($0)°" } ?? dash
    }
}
