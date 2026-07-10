import CoreLocation
import Foundation

// MARK: - CameraSettleLedger (MYR-222 — gesture-vs-programmatic settle classification)
//
// WHY THIS EXISTS: the map camera code needs to know, for every
// `onMapCameraChange(.onEnd)` settle, whether the camera stopped there because
// WE wrote it or because the USER dragged/zoomed. SwiftUI's `Map` exposes no
// change *reason* (iOS 17 target), so both prior mechanisms inferred it from a
// WALL-CLOCK window ("any settle within 1.2s of a programmatic write is
// ours"). That inference is only sound when programmatic writes are RARE.
// MYR-221 made devices default to live, where CoreLocation streams a fix every
// second — the follow/seat writers then write at ≥1Hz, the 1.2s window never
// lapses, and EVERY settle (including the user's own gestures) is
// misattributed as programmatic. That misattribution is the engine of both
// client-reported feedback loops (MYR-222): the idle map that snaps back on
// every pan, and the pin-drop camera that can't be dragged. It is also why
// backgrounding "healed" the app: suspension starves the loop of fixes long
// enough for the 1.2s window to lapse, so the first settle after resume was
// finally classified as the user's.
//
// THE REPLACEMENT — token accounting, no wall clock: every programmatic write
// registers an EXPECTED settle (its target center + requested span). A settle
// is programmatic if and only if it matches an outstanding expectation:
//
//   • center within a small tolerance of the written target (our own settles
//     land on the target to ~1e-13°; the observed worst case is ~3.5e-5° when
//     a follow animation is retargeted mid-flight — the tolerance floor covers
//     it while staying far below any deliberate drag), AND
//   • observed latitude span within the empirical stretch window of the
//     REQUESTED span ([0.95, 4×) — MapKit's inset/aspect fitting shows up to
//     ~2.6× the requested span on a portrait phone with a bottom sheet, the
//     MYR-217 `streetScaleFactor` empirics; a user zoom leaves this window).
//
// Anything else is the user. No timers — the classification is immune to fix
// rate by construction: a thousand fixes queue a thousand expectations, and
// the user's settle matches none of them.
//
// Two deliberate mercies:
//   • a settle matching the LAST matched settle (same center, ~same observed
//     span) is programmatic even with no expectation outstanding — MapKit
//     re-fires `.onEnd` for layout/inset churn at an unchanged camera, and a
//     "user gesture" that ends exactly where the camera already sat is a
//     no-op anyway;
//   • `grantFreePass()` lets ONE unmatched settle through — used for settles
//     we know are coming but whose geometry we can't predict (the initial
//     layout settle at mount, the re-fit after a sheet-inset change).
//
// Pure value type — unit-tested without a map (`CameraSettleLedgerTests`).
struct CameraSettleLedger: Equatable {

    struct ExpectedWrite: Equatable {
        var latitude: Double
        var longitude: Double
        /// The REQUESTED span of the write (degrees) — the settle's observed
        /// span must sit within the stretch window of this.
        var spanDelta: Double
    }

    private struct MatchedSettle: Equatable {
        var latitude: Double
        var longitude: Double
        /// The OBSERVED span of the matched settle — duplicates must be within
        /// `duplicateSpanTolerance` of it (a user zoom at the same center is
        /// NOT a duplicate).
        var observedSpanDelta: Double
    }

    // MARK: Tuning (empirical constants — see header)

    /// Center tolerance as a fraction of the written span.
    static let centerToleranceFraction = 0.005
    /// Center tolerance floor (degrees, ~5.5m) — covers the observed ~3.5e-5°
    /// retarget deviation while staying far below a deliberate drag.
    static let centerToleranceFloor = 5e-5
    /// Observed/requested span window for our own settles. Min < 1 only for
    /// float slack; max mirrors MYR-217's empirical inset-stretch ceiling.
    static let spanStretchMin = 0.95
    static let spanStretchMax = 4.0
    /// A duplicate re-settle must be within this fraction of the last matched
    /// settle's OBSERVED span.
    static let duplicateSpanTolerance = 0.10
    /// Outstanding-expectation cap — writes whose settles never arrive
    /// (retargeted animations) age out as newer ones are consumed.
    static let capacity = 8

    private var pending: [ExpectedWrite] = []
    private var lastMatched: MatchedSettle?
    private var freePasses = 0

    var hasPendingWrites: Bool { !pending.isEmpty }

    // MARK: Recording

    /// Register a programmatic write about to be applied to the camera.
    mutating func expect(center: CLLocationCoordinate2D, spanDelta: Double) {
        pending.append(ExpectedWrite(latitude: center.latitude, longitude: center.longitude, spanDelta: spanDelta))
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
    }

    /// Allow the NEXT unmatched settle to classify as programmatic — for
    /// settles we know are coming but cannot predict (initial layout, a
    /// sheet-inset re-fit). One pass per grant; never accumulates beyond one.
    mutating func grantFreePass() {
        freePasses = 1
    }

    /// Drop all outstanding expectations (the user took the camera, or the
    /// scene was suspended and the settles will never arrive).
    mutating func clear() {
        pending.removeAll()
        lastMatched = nil
        freePasses = 0
    }

    // MARK: Classification

    /// Classify a settle: `true` = one of OUR writes (consumes the matched
    /// expectation and everything older — a retargeted animation never settles
    /// at the superseded targets); `false` = the user moved the camera.
    mutating func classifySettle(center: CLLocationCoordinate2D, latitudeDelta: Double) -> Bool {
        if let index = pending.firstIndex(where: { matches($0, center: center, latitudeDelta: latitudeDelta) }) {
            lastMatched = MatchedSettle(
                latitude: center.latitude, longitude: center.longitude, observedSpanDelta: latitudeDelta
            )
            pending.removeSubrange(0...index)
            return true
        }
        if let last = lastMatched,
           isWithin(tolerance: Self.centerToleranceFloor + last.observedSpanDelta * Self.centerToleranceFraction,
                    latitude: last.latitude, longitude: last.longitude, of: center),
           abs(latitudeDelta - last.observedSpanDelta) <= last.observedSpanDelta * Self.duplicateSpanTolerance {
            return true // layout/inset duplicate of a settle already attributed to us
        }
        if freePasses > 0 {
            freePasses -= 1
            // Remember it — MapKit may re-fire the same layout settle, and a
            // duplicate of a settle we already excused is not a gesture either.
            lastMatched = MatchedSettle(
                latitude: center.latitude, longitude: center.longitude, observedSpanDelta: latitudeDelta
            )
            return true
        }
        return false
    }

    private func matches(_ expected: ExpectedWrite, center: CLLocationCoordinate2D, latitudeDelta: Double) -> Bool {
        let tolerance = max(expected.spanDelta * Self.centerToleranceFraction, Self.centerToleranceFloor)
        guard isWithin(tolerance: tolerance, latitude: expected.latitude, longitude: expected.longitude, of: center) else {
            return false
        }
        let stretch = latitudeDelta / expected.spanDelta
        return stretch >= Self.spanStretchMin && stretch < Self.spanStretchMax
    }

    private func isWithin(tolerance: Double, latitude: Double, longitude: Double, of center: CLLocationCoordinate2D) -> Bool {
        abs(center.latitude - latitude) <= tolerance && abs(center.longitude - longitude) <= tolerance
    }
}
