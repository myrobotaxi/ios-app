import Foundation

// MARK: - VehicleNowPlaying (MYR-303 — contracts 0.16.0)
//
// The pure decision layer behind the Media card's now-playing block. It turns the
// six free-text/numeric wire fields into the three lines the design draws (title,
// artist · album / station, source) plus an optional passive progress reading —
// and, just as importantly, decides when to draw NOTHING.
//
// Why a type instead of `if let`s in the view: every rule here is a wire-semantics
// rule with a contract behind it (see below), each one has a way of being silently
// wrong on screen, and none of them is testable inside a SwiftUI body. `MediaSection`
// reads this and adds no interpretation of its own.
//
// The three wire semantics that drive everything (vehicle-state-schema.md):
//
//  1. **`null` ≠ `""`.** `null` means the field was NEVER OBSERVED — the car has
//     not streamed one since the server started recording, or the server predates
//     MYR-303. It NEVER means "something is playing whose title we couldn't read",
//     so the honest response is to render nothing (MYR-264's rule: no placeholder
//     track, ever). `""` means the opposite and is a real answer: something WAS
//     playing and now nothing is. The display must CLEAR to an idle state — not
//     keep the last title on screen, and not vanish as if media had never existed.
//
//  2. **The 18000000 ms duration sentinel.** Tesla reports 5 hours as a placeholder
//     for radio and other continuous sources. It is not a five-hour track, and the
//     schema forbids computing a completion percentage against it: paired with the
//     radio-unreliable elapsed it renders a scrubber that crawls from 0% and never
//     moves. We suppress progress entirely rather than invent a "live" indicator
//     the prototype has no vocabulary for.
//
//  3. **Every field is independently delivered.** There is no atomic group and no
//     `dependentRequired` pairing among them: a frame may carry an artist with no
//     title, a station with no track, a source with neither. So each line resolves
//     on its own and an absent one collapses without leaving a gap — never a
//     blanked block because one half is missing.

/// A live now-playing reading, built ONLY from a real `VehicleState` (see
/// ``VehicleContractMapping/nowPlaying(from:)``). Its presence is therefore itself
/// the live signal: the simulated path never produces one, which is what keeps the
/// M1 / drift-gate media card pixel-identical (CLAUDE.md).
public struct VehicleNowPlaying: Sendable, Equatable {
    /// `nil` = never observed; `""` = nothing playing. Both are meaningful — see
    /// the header. Free text from Tesla: arbitrary length, any script, no
    /// normalization, so every display site truncates rather than assuming a bound.
    public var title: String?
    public var artist: String?
    public var album: String?
    /// The station/channel WITHIN a source (an FM/satellite channel, a playlist).
    public var station: String?
    /// The INPUT doing the playing (an app name, `Bluetooth`, `USB`, a tuner).
    /// Opaque display text — never switched on, never mapped to an icon set.
    public var source: String?
    /// Track length in ms. `18_000_000` is the radio sentinel, not a duration.
    public var durationMs: Int?
    /// Playback offset in ms. Sampled, not a ticking clock, and explicitly
    /// unreliable on radio — clamped and cross-checked before it is ever drawn.
    public var elapsedMs: Int?

    /// Tesla's placeholder duration for continuous sources (5 h in ms). Never a
    /// real track length; never a denominator.
    public static let radioDurationSentinelMs = 18_000_000

    /// The title line. Prefers the track title; falls back to the STATION when
    /// there is no track title but the car names a channel — a tuned radio with no
    /// track metadata is genuinely playing something, and naming it is honest,
    /// whereas "Nothing playing" over an audible station would not be. `nil` means
    /// there is nothing live-known to name → ``isIdle``.
    public var primaryLine: String? {
        Self.nonEmpty(title) ?? Self.nonEmpty(station)
    }

    /// The secondary line: "artist · album" when the car names them, else the
    /// station (when it isn't already carrying the title line). Each half is
    /// optional and drops out silently — the schema expects `album` to be absent
    /// far more often than the others (radio and many streaming sources have none).
    public var secondaryLine: String? {
        let details = [Self.nonEmpty(artist), Self.nonEmpty(album)].compactMap { $0 }
        if !details.isEmpty { return details.joined(separator: " \u{00B7} ") }
        // No artist/album: surface the station here, unless it is already the
        // title line (never print the same string twice).
        guard let station = Self.nonEmpty(station), station != primaryLine else { return nil }
        return station
    }

    /// The small source label ("Spotify", "Bluetooth", "USB"), or `nil`.
    public var sourceLabel: String? { Self.nonEmpty(source) }

    /// True when media HAS been observed for this car but nothing is playing right
    /// now (the `""` case, or every text field empty). The card then shows its
    /// honest idle line instead of a stale title.
    public var isIdle: Bool { primaryLine == nil }

    /// The passive progress reading, or `nil` when one must NOT be drawn. Requires,
    /// in order: something actually playing; a REAL duration (present, positive,
    /// and not the radio sentinel); and a SANE elapsed (present, non-negative, and
    /// strictly less than the duration — a radio elapsed routinely runs past its
    /// reported duration, and a value at or past the end would draw a full bar on a
    /// track that just started).
    ///
    /// Freshness caveat, deliberately not hidden: a `/snapshot`-persisted elapsed
    /// is stale by construction (it was the position at the last frame, not at read
    /// time). We draw it as a passive line and never animate or interpolate it, and
    /// the card's existing freshness footer ("Updated just now · Live" vs "Last
    /// contact … · Not live") is what qualifies the whole surface's age.
    public var progress: Progress? {
        guard !isIdle else { return nil }
        guard let durationMs, durationMs > 0, durationMs != Self.radioDurationSentinelMs else { return nil }
        guard let elapsedMs, elapsedMs >= 0, elapsedMs < durationMs else { return nil }
        return Progress(
            fraction: Double(elapsedMs) / Double(durationMs),
            elapsedLabel: Self.timeLabel(ms: elapsedMs),
            durationLabel: Self.timeLabel(ms: durationMs)
        )
    }

    /// A drawable progress reading — a 0…1 fraction plus the two m:ss labels the
    /// prototype's scrubber row prints at either end.
    public struct Progress: Sendable, Equatable {
        public var fraction: Double
        public var elapsedLabel: String
        public var durationLabel: String
    }

    /// `m:ss`, matching the prototype's `fmtTime` (vehicle-controls.jsx:233-237).
    public static func timeLabel(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    public static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
