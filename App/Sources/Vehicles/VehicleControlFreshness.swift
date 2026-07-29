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
//      (`lastUpdated` older than `staleThreshold`). See "WHERE STALENESS IS SAID"
//      below: as of MYR-335 the tiles no longer say it themselves.
//
// A STREAMING car with a still-unknown field stays "Syncing" (the value really
// is in flight and will land). Everything here is pure and takes an injected
// `now`, so it is unit-testable and so the simulated path (lastUpdated == nil,
// every field `isKnown`) renders pixel-identically (no qualifier ever appears).
//
// WHERE STALENESS IS SAID (MYR-335). MYR-260 gave each safety tile its own "X
// ago" qualifier because, at the time, the sheet said NOTHING anywhere about how
// current it was. MYR-315 then put a freshness stamp in the sheet HERO — visible
// at peek, tappable to spend a wake — and a "Not live" footer under the controls
// stack. The per-tile copy became a third statement of the same fact, and the one
// with no room for it: at 4-column width the tiles hold ~50pt of text and the
// qualified subs measure 88pt ("Synced 13m ago") and 92pt ("Closed · 13m ago"),
// so both ellipsized on the owner's phone — "Locked / Synced 13…", "Trunk /
// Closed · 1…". Neither tile can carry BOTH its state and a recency at that
// width on any supported device, so the recency is now stated ONCE, by the stamp,
// and the tiles keep a state that can actually be read. `isStale`/`agoLabel`
// remain — they are what the stamp itself is built from.
enum VehicleControlFreshness {
    /// The em-dash the design pairs with a value-less sub, matching the existing
    /// "— Syncing" grammar so the row reads as intentionally empty, not broken.
    static let dash = "\u{2014}"
    static let syncingSub = "\u{2014} Syncing"
    static let unavailableSub = "\u{2014} Unavailable"

    // MARK: Tile forms (MYR-335)

    /// The QUICK-TILE forms of the two unknown subs. Same two states, said in the
    /// room a 4-column tile actually has: the em-dash prefix and the word
    /// "Unavailable" together measure 75pt against ~50pt of tile, so the full
    /// forms above ellipsized. They stay exactly as they are for the FULL-WIDTH
    /// surfaces that can hold them (the seat-climate rows, `ClimateSection`) —
    /// one type owns both vocabularies rather than each surface inventing copy.
    static let tileSyncingSub = "Syncing"
    static let tileUnavailableSub = "No data"

    /// The honest subtitle for a QUICK TILE whose field is UNKNOWN — the same
    /// decision as ``unknownSub(hasSnapshot:isStreaming:)``, in the tile forms.
    static func tileUnknownSub(hasSnapshot: Bool, isStreaming: Bool?) -> String {
        unknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming) == unavailableSub
            ? tileUnavailableSub
            : tileSyncingSub
    }

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

    /// A compact, bounded "X ago" label for the freshness stamp (MYR-315). Coarse
    /// buckets (minutes / hours / days) keep the hero line short.
    static func agoLabel(since lastUpdated: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(lastUpdated))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
