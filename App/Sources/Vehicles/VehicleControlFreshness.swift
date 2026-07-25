import Foundation

// MARK: - VehicleControlFreshness (MYR-260)
//
// The pure decision layer behind the quick-tile subtitles. It splits the old
// perpetual "— Syncing" (gated only on `executor.isKnown`) into three HONEST,
// bounded states, so an unknown value is never an indefinite hopeful spinner —
// a client once found his trunk PHYSICALLY OPEN while the app read "Syncing":
//
//   1. CONNECTING  — no snapshot has arrived yet (`lastUpdated == nil`). The
//      value is genuinely transient → "— Syncing" (acceptable).
//   2. UNAVAILABLE — we HAVE a reachable snapshot but the field is unknown AND
//      the car is NOT streaming (offline / in_service / asleep, and the backend's
//      one-shot REST read couldn't fill it). The value is not coming, so the
//      hopeful spinner is a lie → "— Unavailable".
//   3. STALE       — we have a KNOWN last-known value that may be out of date
//      (`lastUpdated` older than `staleThreshold`). Show the value with a bounded
//      "X ago" qualifier so the owner knows (especially safety-relevant
//      Trunk/Lock), rather than presenting old state as current.
//
// A STREAMING car with a still-unknown field stays "— Syncing" (the value really
// is in flight and will land). Everything here is pure and takes an injected
// `now`, so it is unit-testable and so the simulated path (lastUpdated == nil,
// every field `isKnown`) renders pixel-identically (no qualifier ever appears).
enum VehicleControlFreshness {
    /// The em-dash the design pairs with a value-less sub, matching the existing
    /// "— Syncing" grammar so the tile reads as intentionally empty, not broken.
    static let dash = "\u{2014}"
    static let syncingSub = "\u{2014} Syncing"
    static let unavailableSub = "\u{2014} Unavailable"

    /// A last-known value younger than this is treated as fresh (no qualifier).
    /// A streaming car refreshes `lastUpdated` every frame so it never crosses
    /// this; only a stalled / offline / reconnecting snapshot ages past it.
    static let staleThreshold: TimeInterval = 60

    /// The honest subtitle for a quick tile whose field is UNKNOWN. `hasSnapshot`
    /// = we've received any frame at all (a `lastUpdated` exists); `isStreaming`
    /// = the car is online and still delivering (`nil` on the simulated path,
    /// treated as streaming so M1 stays identical).
    static func unknownSub(hasSnapshot: Bool, isStreaming: Bool?) -> String {
        // No snapshot yet → connecting; a streaming car is still delivering the
        // value → both are genuinely transient. ONLY a reachable snapshot from a
        // NON-streaming car means the value will never arrive.
        if hasSnapshot, isStreaming == false { return unavailableSub }
        return syncingSub
    }

    /// Whether a KNOWN value is stale enough to warrant an "X ago" qualifier.
    /// False when there's no read time (simulated / pre-first-frame) or the read
    /// is within the freshness threshold.
    static func isStale(lastUpdated: Date?, now: Date) -> Bool {
        guard let lastUpdated else { return false }
        return now.timeIntervalSince(lastUpdated) >= staleThreshold
    }

    /// A compact, bounded "X ago" label for the stale qualifier. Coarse buckets
    /// (minutes / hours / days) keep it inside the tile's narrow subtitle grammar.
    static func agoLabel(since lastUpdated: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(lastUpdated))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
