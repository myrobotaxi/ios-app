import Foundation
import Observation

// MARK: - The tracking sheet says whether it is TRACKING (MYR-449)
//
// **A PREVIEW THAT IMPERSONATES TRACKING IS THE WHOLE COMPLAINT.** External beta,
// build `202608030843`: *"riders were not able to see the live telemetry data from
// the vehicle for the ride share flow and it instead was showing like apple maps
// route after ride was accepted by tesla."*
//
// The tracking map was mounted and correct. What it drew, with no live fix in
// hand, was the leg-2 MKDirections polyline and two pins and NOTHING ELSE —
// MYR-393's `RiderCarMarker.withheld` doing exactly its job, withholding a claim
// it could not support. That rule is right and is unchanged here. What was
// missing is the other half of it: **withholding the marker said nothing, so a
// rider could not tell a tracking surface with no data from a route preview.**
// Two situations, one picture, and the more flattering reading is the one a
// rider takes.
//
// MYR-393 already wrote the qualifier for the case where a fix exists and is OLD
// ("Position from 4 min ago") — `RiderCarFreshnessNote`, consumed verbatim below
// rather than restated, so the two can never drift. The gap was the case where
// there is NO fix at all, which rendered no words whatsoever. This is that arm,
// in the repo's own honest-degradation grammar ("Can't reach your vehicles right
// now", "Can't find a route right now"): **"right now" is load-bearing** — the
// socket and the snapshot ladder are both still trying underneath, so the line
// must read as a situation rather than as a verdict.
//
// The escalation is a CLOCK rather than a second data source, because there is no
// third fact to consult: the app either has a fix or it does not, and the only
// thing that changes while it does not is how long the rider has been looking at
// a map with no car on it. Under the grace that is ordinary (a car waking, a
// snapshot in flight); past it, it is worth naming a likely cause, because *the
// car may simply be asleep and that is not an app failure* — which is precisely
// what an unexplained blank map cannot say.

/// What the tracking surface can honestly claim about the ride's car right now.
///
/// A VALUE rather than a `String?` so the sheet's claim is assertable
/// independently of its copy, and so `claimsLivePosition` — the invariant the
/// sweep turns on — is a property of the STATE rather than a guess about words.
enum RiderTrackingLiveState: Equatable, Sendable {
    /// The simulated path and every pre-existing DEBUG scene. Returned before any
    /// clock or fix is consulted, so every tracking capture is byte-identical —
    /// the same short-circuit `RiderTrackingLadder` and `RiderCarMarker` take, and
    /// for the same reason: a `trackProgress`-driven scene has no telemetry to be
    /// honest with.
    case simulated
    /// A fix is in hand and current. The map's gold marker is the whole statement;
    /// no words are needed and none are rendered.
    case live
    /// A fix is in hand and OLD. MYR-393's own qualifier, unchanged.
    case stale
    /// No fix yet, and not for long enough to be worth explaining.
    case waiting
    /// No fix, and long enough that silence has become the misleading part.
    case unavailable

    /// **THE INVARIANT.** Does this state let the surface stand as a claim that
    /// the car's position is being shown live? Only `.live` and `.simulated` may —
    /// and `.simulated` only because its scene genuinely is driving a car.
    var claimsLivePosition: Bool {
        switch self {
        case .live, .simulated: true
        case .stale, .waiting, .unavailable: false
        }
    }
}

enum RiderTrackingLiveReport {

    /// How long a tracking surface may show no car before it explains itself.
    ///
    /// Thirty seconds is the telemetry investigator's own number and it is bounded
    /// on both sides by real behaviour: a healthy socket authenticates and delivers
    /// its first frame in well under a second, while MYR-319's cold-read ladder can
    /// legitimately take ~21s on a car that is asleep or in service. So anything
    /// tighter would call a normal wake a failure, and anything much looser leaves
    /// the rider with the unexplained blank map this issue exists to remove.
    static let grace: TimeInterval = 30

    /// Resolve the surface's claim.
    ///
    /// - Parameters:
    ///   - marker: MYR-393's verdict, which already owns "is there a fix, and is
    ///     it current". Consulted rather than re-derived, so the words under the
    ///     status line and the glyph on the map can never disagree.
    ///   - openedAt: when this tracking surface began asking. `nil` = not tracking.
    ///   - now: injected.
    static func resolve(marker: RiderCarMarker, openedAt: Date?, now: Date) -> RiderTrackingLiveState {
        switch marker {
        case .simulated:
            return .simulated
        case .live(let stale):
            return stale ? .stale : .live
        case .withheld:
            // No `openedAt` means the clock has not been armed for this surface;
            // treat that as the start rather than as an expiry, so a missing arm
            // can only ever UNDER-claim.
            guard let openedAt, now.timeIntervalSince(openedAt) >= grace else { return .waiting }
            return .unavailable
        }
    }

    /// The muted line under the status word, or `nil` when nothing honest needs
    /// saying. Rendered in the SAME slot MYR-393's freshness note already owns
    /// (`mrt.tracking.freshnessNote`, on both the peek and the full layer), so
    /// this adds words to an existing element rather than a new one.
    ///
    /// `vehicleName` is the sheet's own resolved name ("your ride" when the car
    /// has no nickname), so a nameless car never produces "Waiting for  to report".
    static func note(
        state: RiderTrackingLiveState,
        marker: RiderCarMarker,
        lastUpdated: Date?,
        vehicleName: String,
        now: Date
    ) -> String? {
        switch state {
        case .simulated, .live:
            // Byte-identical to pre-MYR-449: the simulated scenes render nothing
            // here, and a current live fix needs no qualifier.
            return nil
        case .stale:
            // MYR-393's sentence, VERBATIM and via its own type. The spec's
            // "Last seen <n> min ago" is this line already — restating it in new
            // words would be a second grammar for one fact.
            return RiderCarFreshnessNote.text(marker: marker, lastUpdated: lastUpdated, now: now)
        case .waiting:
            return "Waiting for live location from \(vehicleName)…"
        case .unavailable:
            // Names the likeliest cause on purpose. A Tesla that is asleep reports
            // nothing, which is normal and is not the app failing — and a rider
            // given no reason at all assumes the worse of the two.
            return "Live location unavailable right now — \(vehicleName) may be asleep"
        }
    }
}

// MARK: - The clock behind the escalation

/// Arms when the tracking surface opens and ticks while it is up, so the 30s
/// escalation renders on a surface where — by definition — nothing else is
/// arriving to trigger a re-render.
///
/// An `@Observable` TICK rather than a `TimelineView`, for two reasons. The read
/// happens inside `SharedViewerScreen.body`, which is at the type-checker's budget
/// (MYR-422: "adding one more `.onChange` fails the build outright"), so the
/// re-render has to come from Observation rather than from new view structure.
/// And the same tick is where the MYR-449 RECOVERY hangs — the client cannot tell
/// a quiet car from a silently dark socket, so after the grace it stops waiting
/// and re-establishes the stream.
@MainActor
@Observable
final class RiderTrackingLiveWatch {

    /// When the current tracking surface began asking, or `nil` while not tracking.
    private(set) var openedAt: Date?

    /// Advanced by the timer. Nothing reads its VALUE — it exists so Observation
    /// re-runs the body that reads it, which is what makes a clock-driven
    /// escalation visible at all.
    private(set) var tick = 0

    /// How often the escalation is re-evaluated. Well under the grace, so the
    /// line turns over within a few seconds of the threshold rather than on it.
    static let interval: TimeInterval = 5

    /// Fired at most ONCE per armed surface, the first time the grace elapses with
    /// still no live fix. See `RiderLiveVehicleLocator.recoverDarkStream`.
    @ObservationIgnored var onGraceElapsed: (@MainActor () -> Void)?

    /// Whether a live fix is in hand — supplied by the owner so this type holds no
    /// opinion about where telemetry comes from.
    @ObservationIgnored var hasLiveFix: (@MainActor () -> Bool)?

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var firedGrace = false

    /// Begin (or restart) the clock. Idempotent while already armed, so the
    /// repeated phase writes a SwiftUI body performs cannot restart the grace and
    /// hold the surface in `.waiting` for ever.
    func arm(now: Date = Date()) {
        guard openedAt == nil else { return }
        openedAt = now
        firedGrace = false
        let interval = Self.interval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.advance()
            }
        }
    }

    /// Stop and forget. The surface is gone, so its grace is meaningless and its
    /// recovery must not fire behind it.
    func disarm() {
        timer?.cancel()
        timer = nil
        openedAt = nil
        firedGrace = false
    }

    /// One tick. Internal rather than private so a test can drive the escalation
    /// without sleeping through it.
    func advance(now: Date = Date()) {
        tick &+= 1
        guard !firedGrace, let openedAt else { return }
        guard now.timeIntervalSince(openedAt) >= RiderTrackingLiveReport.grace else { return }
        // A car that IS reporting needs no recovery, however long it took.
        guard hasLiveFix?() != true else { return }
        firedGrace = true
        onGraceElapsed?()
    }
}
