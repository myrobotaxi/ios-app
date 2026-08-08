import Foundation

// MARK: - VehicleControlReadout (MYR-441)
//
// How the owner sheet's two GRAPHICAL controls — the climate fan bar and the media
// volume slider — render a value the car has not reported.
//
// Both had the same defect and it had the same shape: **the natural spelling for
// "unknown" on a numeric control is `0`, and on these two controls `0` is not a
// neutral rest position — it is a confident reading.** A fan bar at 0 is every
// segment drawn in the off fill, which is pixel-for-pixel a fan confirmed OFF; a
// volume slider at 0 is the thumb pinned to the left edge over an empty track,
// which is pixel-for-pixel a car confirmed MUTED. `MYR-251`'s `isKnown` seam was
// consulted at both call sites and then thrown away into a literal zero, with only
// a 0.5 opacity left to carry the difference.
//
// Named here rather than left inline for `ClimateTemperatureText`'s own reason
// (MYR-440): **a decision buried in a view body is not assertable, and a named one
// is.** The fan row was also internally contradictory before this — its numeral
// already read `"— / 10"` while the bar directly under it drew a confident zero —
// which is what a single home for the decision prevents.
enum VehicleControlReadout {

    /// The fan level the bar should DRAW, or `nil` when the car has not reported
    /// one.
    ///
    /// The regression this exists to catch is one character wide: `known ? value :
    /// 0` compiles, reads as harmless, and re-ships the defect. `FanBar` takes an
    /// `Int?` so the unknown case cannot be expressed as a level at all.
    static func fanLevel(known: Bool, reported: Int) -> Int? {
        known ? reported : nil
    }

    /// The text to set beside the volume slider, or `nil` when there is nothing to
    /// say.
    ///
    /// **`nil` FOR A KNOWN VOLUME IS THE BYTE-IDENTITY GUARANTEE.** That row has
    /// never carried any text — icon, slider, nothing else — so an owner with real
    /// data must see exactly the row they saw before. The dash appears only on the
    /// unknown branch, where a bare empty track said nothing at all about WHY it
    /// was empty; with it, the row reads in the same grammar as the fan row one
    /// card up (`"— / 10"`).
    ///
    /// The glyph is `ClimateTemperatureText.dash`, the app's ONE honest-unknown
    /// mark (asserted equal to `BatteryReadout.dash`), never a second literal.
    static func volumeText(known: Bool) -> String? {
        known ? nil : ClimateTemperatureText.dash
    }
}
