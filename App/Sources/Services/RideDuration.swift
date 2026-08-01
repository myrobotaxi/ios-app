import Foundation

// MARK: - RideDuration (MYR-395) — ONE way this app says how long something takes
//
// r16, the client, on a Grayslake IL → Galleria Dallas booking: *"If over an hour
// convert to hours and min."* His screenshot carries **"2592 min away"** and
// **"2623 min · 1049.2 mi trip"** — forty-three hours, rendered as a four-digit
// count of minutes, in the two places a rider reads before committing to a trip.
//
// Nothing was computing the wrong number. `TripEstimate`'s closed form is right
// (great-circle × 1.3 ÷ 24 mph puts that trip at 2,623 minutes, which is what the
// sheet printed). Every surface simply interpolated the integer straight into its
// own string — **fifteen of them, each with its own `"\(n) min"`** — so there was
// no single place where "and what if it's more than an hour" could be answered.
//
// This is that place, and the reason it is a shared function rather than fifteen
// corrected literals: the next surface to render a duration inherits the rule
// instead of re-deciding it.

/// How long something takes, in the app's one duration grammar.
///
/// - Under an hour: **`"N min"`** — byte-for-byte what every surface printed
///   before this issue, which is what keeps the whole drift gate intact. Sub-hour
///   is the overwhelmingly common case and the client did not ask for it to move.
/// - An exact number of hours: **`"N hr"`** — never `"1 hr 0 min"`, which is how a
///   naive `hours`/`minutes` split reads at every hour boundary.
/// - Otherwise: **`"N hr M min"`**, with `M` in `1...59` by construction.
///
/// **The remainder is a remainder, never the raw count.** The bug this type is
/// most likely to be re-introduced by is `"\(m / 60) hr \(m) min"` — "1 hr 65 min"
/// — which the issue names explicitly and `RideDurationTests` pins against.
enum RideDuration {
    static let minutesPerHour = 60

    /// The one duration string. `minutes` is clamped at 0: a negative estimate is
    /// not a duration, and no surface in this app has a use for "-3 min".
    static func text(minutes: Int) -> String {
        let total = max(0, minutes)
        guard total >= minutesPerHour else { return "\(total) min" }
        let hours = total / minutesPerHour
        let remainder = total % minutesPerHour
        guard remainder > 0 else { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }

    /// The SAME sentence, split at its final unit, for the hero surfaces that set
    /// the number and its unit in different type (the tracking hero's 44pt
    /// countdown, Summary's stat tiles, the Drives ETA pill).
    ///
    /// Splitting the composed string — rather than re-deriving hours and minutes
    /// here — is what makes the two forms unable to disagree: there is exactly one
    /// place that decides whether a duration says "hr", and this is not it.
    /// `("43", "min")` / `("1", "hr")` / `("1 hr 5", "min")` / `("43 hr 43", "min")`.
    static func heroParts(minutes: Int) -> (value: String, unit: String) {
        let composed = text(minutes: minutes)
        guard let split = composed.lastIndex(of: " ") else { return (composed, "") }
        return (String(composed[composed.startIndex..<split]), String(composed[composed.index(after: split)...]))
    }

    /// `"N min away"` / `"43 hr 12 min away"` — the pickup-ETA note
    /// (`RidePickupETADisplay.awayNote`) and the idle placeholder share this
    /// suffix, and the client's "2592 min away" was one of the two lines he
    /// photographed.
    static func awayText(minutes: Int) -> String { "\(text(minutes: minutes)) away" }
}
