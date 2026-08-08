import CoreLocation
import Foundation
import Observation

// MARK: - TrackingMarkerInterpolation (MYR-460 — the pure rule)
//
// A device streams GPS fixes at about 1Hz. Drawn honestly, that is a marker that
// TELEPORTS once a second — the client's *"camera not following car"* is partly
// this: a glyph that jumps has no direction of travel to follow, and a camera
// that jumps with it reads as broken rather than as following. Every rideshare
// map answers this the same way: draw the marker MOVING between the two fixes
// you hold, over the interval you observed between them.
//
// ⚠️ THIS IS RENDERING ONLY, AND THAT IS A LAW HERE RATHER THAN A PREFERENCE
// (MYR-237/MYR-389, and MYR-393 which is the same lesson from the other side —
// the client's car sat in a service bay a mile and a half from where a
// clock-driven interpolation had drawn it). The interpolated coordinate is
// allowed to reach exactly one thing: the annotation's position on screen. It
// must never reach a route key, a cache key, a pickup anchor, a deviation test,
// a fit or the follow camera's own centre — all of which take the RAW fix, which
// remains the fact. The distinction is not cosmetic: a tween is this client
// GUESSING where the car is between two things it was told, and a guess may be
// drawn but may not be recorded.
//
// Pure + static, so the whole rule is testable with no map, no socket and no
// clock but the one it is handed.
enum TrackingMarkerInterpolation {

    /// How often the render position is recomputed while a tween is running.
    /// 20Hz — comfortably above the ~15Hz where stepping becomes visible, and
    /// far below a rate that would make rebuilding the map content per tick
    /// expensive. It only runs BETWEEN fixes: a tween that has reached its
    /// target stops the ticker, so a parked car costs nothing.
    static let tickInterval: TimeInterval = 1.0 / 20.0

    /// The interval assumed for the first tween of a session, before two fixes
    /// have been observed and there is anything to measure.
    static let defaultInterval: TimeInterval = 1.0

    /// Clamps on the MEASURED inter-fix interval. The floor stops a burst of
    /// fixes arriving together from producing a zero-length tween; the ceiling
    /// is the important one — a car that goes quiet for 40 seconds and then
    /// reports must not spend 40 seconds gliding to where it already is, which
    /// would be the marker asserting a journey nobody observed.
    static let minInterval: TimeInterval = 0.2
    static let maxInterval: TimeInterval = 3.0

    /// The interval to tween over, from the gap between the previous fix and
    /// this one. `nil` (no previous fix) takes the default.
    static func interval(previousFixAt: Date?, now: Date) -> TimeInterval {
        guard let previousFixAt else { return defaultInterval }
        let measured = now.timeIntervalSince(previousFixAt)
        guard measured.isFinite else { return defaultInterval }
        return min(maxInterval, max(minInterval, measured))
    }

    /// Fraction of the way from one fix to the next, clamped to 0…1.
    static func progress(elapsed: TimeInterval, interval: TimeInterval) -> Double {
        guard interval > 0, elapsed.isFinite, interval.isFinite else { return 1 }
        return min(1, max(0, elapsed / interval))
    }

    /// The render position between two fixes at a given elapsed time.
    ///
    /// `reduceMotion` JUMPS — honestly, to the fix itself. Reduce Motion is a
    /// request not to be shown movement, and a tween is movement this app
    /// invented; the raw fix is both the truthful answer and the still one.
    ///
    /// Longitude is interpolated the SHORT way around, so a trip crossing the
    /// antimeridian tweens across it rather than the long way round the planet.
    /// Nothing in this product drives across it; the alternative is a rule that
    /// is correct only in some hemispheres, which is not cheaper to write.
    static func coordinate(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        elapsed: TimeInterval,
        interval: TimeInterval,
        reduceMotion: Bool
    ) -> CLLocationCoordinate2D {
        guard !reduceMotion else { return to }
        guard from.latitude.isFinite, from.longitude.isFinite,
              to.latitude.isFinite, to.longitude.isFinite else { return to }
        let t = progress(elapsed: elapsed, interval: interval)
        guard t < 1 else { return to }
        var deltaLon = to.longitude - from.longitude
        if deltaLon > 180 { deltaLon -= 360 }
        if deltaLon < -180 { deltaLon += 360 }
        var lon = from.longitude + deltaLon * t
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return CLLocationCoordinate2D(
            latitude: from.latitude + (to.latitude - from.latitude) * t,
            longitude: lon
        )
    }

    /// Whether two fixes are the same place. A device re-reporting an unchanged
    /// coordinate must not restart a tween that has already arrived — that is
    /// how a stationary marker acquires a permanent shimmer.
    static func isSamePlace(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }
}

// MARK: - TrackingMarkerMotion (MYR-460 — the driver)
//
// Holds the two fixes the rule interpolates between and runs the ticker that
// samples it. Deliberately thin: every decision lives in the pure enum above,
// so what is untested here is only "does a timer fire", and what is tested is
// every question about where the glyph goes.
@MainActor
@Observable
final class TrackingMarkerMotion {

    /// Where the glyph is drawn RIGHT NOW, or `nil` when there is no position to
    /// draw at all (MYR-393's withheld marker, carried through unchanged).
    private(set) var rendered: CLLocationCoordinate2D?

    /// Set by the view from the environment. Read at `ingest` time rather than
    /// captured once, so turning Reduce Motion on mid-ride takes effect on the
    /// next fix instead of at the next launch.
    var reduceMotion: Bool = false

    private var from: CLLocationCoordinate2D?
    private var to: CLLocationCoordinate2D?
    private var startedAt: Date?
    private var interval: TimeInterval = TrackingMarkerInterpolation.defaultInterval
    private var previousFixAt: Date?
    private var ticker: Task<Void, Never>?

    /// A fix arrived (or the position went away). Called from the ONE place the
    /// map already observes the raw coordinate changing.
    func ingest(_ coordinate: CLLocationCoordinate2D?, now: Date = Date()) {
        guard let coordinate else {
            // No position: nothing to draw and nothing to tween toward. The
            // marker is withheld rather than left standing at a stale place.
            stop()
            from = nil; to = nil; startedAt = nil; previousFixAt = nil
            rendered = nil
            return
        }
        guard let current = to else {
            // THE FIRST FIX IS NEVER TWEENED. There is no earlier position to
            // come from, and tweening from wherever the map happens to be would
            // animate the glyph in from a place the car has never been.
            from = coordinate; to = coordinate; rendered = coordinate
            startedAt = now; previousFixAt = now
            return
        }
        guard !TrackingMarkerInterpolation.isSamePlace(current, coordinate) else { return }

        interval = TrackingMarkerInterpolation.interval(previousFixAt: previousFixAt, now: now)
        // Start from where the glyph is DRAWN, not from the previous fix: a tween
        // interrupted by an early fix must continue from the screen position the
        // rider is looking at, or the marker snaps backwards before going on.
        from = rendered ?? current
        to = coordinate
        startedAt = now
        previousFixAt = now

        guard !reduceMotion else {
            stop()
            rendered = coordinate
            return
        }
        startTicker()
    }

    /// Stop ticking — the map went away, or the tween finished.
    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let from = self.from, let to = self.to, let startedAt = self.startedAt else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.rendered = TrackingMarkerInterpolation.coordinate(
                    from: from, to: to, elapsed: elapsed,
                    interval: self.interval, reduceMotion: self.reduceMotion
                )
                if elapsed >= self.interval || self.reduceMotion {
                    self.ticker = nil
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(TrackingMarkerInterpolation.tickInterval * 1_000_000_000))
            }
        }
    }
}
