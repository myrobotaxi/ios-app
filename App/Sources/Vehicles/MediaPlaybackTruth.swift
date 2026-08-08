import Foundation
import MyRobotaxiContracts

// MARK: - MediaPlaybackTruth (MYR-467) — the position outranks a stale status
//
// External beta, build 202608030843. Two submissions a minute apart from the
// same tester: *"Music is playing but it shows as paused"*, then *"Music
// switched back to playing after I took previous screenshot"*. Same track
// throughout — the transport showed ▶ (i.e. the app asserting PAUSED) at 0:01
// of 3:09, and ⏸ (playing) at 0:11. **The elapsed position advanced ten seconds
// between the two frames, which is independent proof that playback never
// stopped.** Only our rendering of the play/pause state was wrong, for about ten
// seconds, and then it corrected itself.
//
// THE CAUSE IS TWO WIRE FIELDS THAT ARRIVE INDEPENDENTLY AND ARE FOLDED
// INDEPENDENTLY. `mediaPlaybackStatus` and `mediaNowPlayingElapsedMs` are
// separate Tesla emissions in the Media group; `VehicleStateMerger.apply` opens
// with `var state = original`, so a delta that carries only the elapsed position
// **carries the previous status forward verbatim**. That is correct fold
// behaviour and it is not the bug — the merger *routes, it does not interpret*
// (its own words, on these very fields). The bug is that nothing downstream ever
// noticed the two disagreed, so a `Paused` the car had emitted before the track
// changed sat on the transport row while the position underneath it ran on.
//
// THE INVARIANT, stated by the issue and enforced here: **if the playback
// position advances between frames, the state is not paused.**
//
// WHY THIS IS A CONSUMER'S RULE AND NOT A MERGER ARM. The merger is the one
// place that sees two consecutive states, which makes it the tempting home — and
// it is the wrong one for the same reason it already refuses to suppress the
// 18000000 ms radio sentinel: a field it writes is a claim the SERVER made, and
// a client-derived correction written into `VehicleState` would be
// indistinguishable from one. The correction belongs where every other
// reconciliation rule in this app lives, beside the control it moves, as a pure
// function a test can drive with no socket and no clock.
//
// THE HARD PART IS NOT DETECTING THE CONTRADICTION, IT IS KNOWING WHEN IT ENDS.
// A naive "advanced ⇒ playing" flickers: `reconcile` runs on EVERY folded delta
// (a cabin temperature, a GPS fix), and on those frames the position has not
// moved since the last one, so the icon would fall straight back to paused and
// bounce on the next elapsed frame. So the correction LATCHES — and the latch
// needs a release that a genuine pause can pull:
//
//   • **A FRESH ASSERTION RELEASES IT, IMMEDIATELY.** When the car really pauses
//     it EMITS `Paused`, and the value we hold at that moment is `Playing` — so
//     the status CHANGES between frames. A change is the car speaking now; an
//     unchanged status is the merger carrying an old sentence forward. That
//     distinction is the whole mechanism, and it is why a real pause is honoured
//     on the very next frame with no window to wait out.
//   • **A BOUNDED BACKSTOP RELEASES IT ANYWAY.** The one case the rule above
//     cannot see is a pause that happens while the latch is already up and with
//     no `Playing` frame in between — the status then reads `Paused` at both
//     ends and never changes. The position stops advancing, so
//     ``positionEvidenceWindow`` after the last observed advance the latch
//     lapses and the car's own word wins. This is the honest-degradation shape
//     the executor's settle windows already use: hold the evidence, then accept
//     the car's reported reality.
//
// A TRACK CHANGE RESETS EVERYTHING. Elapsed restarts near zero on a new track,
// so a comparison across tracks measures nothing — and the very frame this
// defect appears on is a track change. Advancement is only ever read WITHIN one
// track identity.

/// One observation of the car's media position, as the truth rule sees it.
struct MediaPositionSample: Equatable, Sendable {
    /// What identifies the track this position belongs to. Two samples are only
    /// comparable when these agree — see the file header.
    let track: MediaTrackIdentity
    /// The wire's `mediaNowPlayingElapsedMs`.
    let elapsedMs: Int
    /// When this sample was observed. Only the BACKSTOP reads it.
    let observedAt: Date
}

/// The identity of the playing track, for "is this still the same track?".
///
/// Deliberately the title/artist/album/duration TUPLE rather than the title
/// alone: a station that re-announces the same title for a new segment, and an
/// album track list where two entries share a name, both defeat a title-only
/// key — and getting this wrong compares one track's elapsed against another's,
/// which is the one input the whole rule rests on.
struct MediaTrackIdentity: Equatable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let durationMs: Int?

    init(title: String?, artist: String?, album: String?, durationMs: Int?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
    }

    init(state: VehicleState) {
        self.init(
            title: state.mediaNowPlayingTitle,
            artist: state.mediaNowPlayingArtist,
            album: state.mediaNowPlayingAlbum,
            durationMs: state.mediaNowPlayingDurationMs
        )
    }
}

/// What the truth rule remembers between frames. One value, so the executor
/// holds a single property and every transition is a pure function of it.
struct MediaPlaybackMemory: Equatable, Sendable {
    /// The last position we saw, or `nil` before the first observation.
    var sample: MediaPositionSample?
    /// The last wire status we saw. A CHANGE in this is the car asserting
    /// something now; no change is the merger carrying a value forward.
    var wireStatus: VehicleState.MediaPlaybackStatus?
    /// When the position was last observed to ADVANCE while the wire claimed the
    /// car was not playing — i.e. when the contradiction was last real. `nil`
    /// means the correction is not latched.
    var contradictionObservedAt: Date?

    static let empty = MediaPlaybackMemory()
}

/// The verdict for one frame: what to show, and what to remember.
struct MediaPlaybackVerdict: Equatable, Sendable {
    /// The play/pause boolean the transport row should render, or `nil` for the
    /// honestly-unknown / no-session state (MYR-314's gate, untouched).
    let playing: Bool?
    /// Whether this verdict OVERRODE the wire — i.e. the car said paused and the
    /// position proved otherwise. Nothing renders differently from it; it exists
    /// so the tests can name the arm and so a future surface can explain itself.
    let correctedFromPosition: Bool
    /// The memory to carry into the next frame.
    let memory: MediaPlaybackMemory
}

enum MediaPlaybackTruth {

    /// How long a position advance keeps vouching for playback once the car has
    /// stopped saying so and stopped moving the position.
    ///
    /// This is the BACKSTOP only — a real pause is released by the fresh-assertion
    /// rule on the next frame, with no wait at all (see the file header), so this
    /// window is only ever spent on the pathological case where the status reads
    /// `Paused` on both sides of a pause and never changes.
    ///
    /// 20s: comfortably longer than the ~10s contradiction the field report
    /// measured and than any plausible gap between two `MediaNowPlayingElapsed`
    /// emissions, so continuous playback re-arms it long before it lapses; short
    /// enough that a car stuck in that corner is not described as playing for
    /// anything like the length of a track.
    static let positionEvidenceWindow: TimeInterval = 20

    /// Resolve one frame.
    ///
    /// `wire` is the status as folded onto `VehicleState`; `positionMs` is
    /// `mediaNowPlayingElapsedMs`. Both may be absent, and both being absent is
    /// the ordinary no-media-session case.
    static func resolve(
        wire: VehicleState.MediaPlaybackStatus?,
        track: MediaTrackIdentity,
        positionMs: Int?,
        memory: MediaPlaybackMemory,
        now: Date = Date()
    ) -> MediaPlaybackVerdict {
        var next = memory
        let statusChanged = memory.wireStatus != wire
        next.wireStatus = wire

        // A new track invalidates every position fact we hold: elapsed restarts,
        // so comparing across the boundary measures nothing (file header).
        let sameTrack = memory.sample?.track == track
        if !sameTrack { next.contradictionObservedAt = nil }

        // Did the position ADVANCE, strictly, within one track? A re-delivered
        // identical position is not evidence of anything — it is the merger
        // carrying the last value forward, exactly as it does the status.
        let previousMs = sameTrack ? memory.sample?.elapsedMs : nil
        let advanced: Bool = {
            guard let positionMs, let previousMs else { return false }
            return positionMs > previousMs
        }()

        if let positionMs {
            next.sample = MediaPositionSample(track: track, elapsedMs: positionMs, observedAt: now)
        } else if !sameTrack {
            next.sample = nil
        }

        // The car's own play/pause reading, unchanged from MYR-314: `Unknown`
        // and any unrecognized value stay honestly unknown rather than
        // fabricating a state, and that arm is NOT one this rule may fill in.
        // A position advancing while the car reports NOTHING is not a
        // contradiction to resolve — it is a session we were never told about,
        // and manufacturing one here would re-open the transport row over a car
        // that has not said it has media. The rule corrects a stated `paused`;
        // it never invents a state.
        let wirePlaying = wire.flatMap(playing(from:))
        guard let wirePlaying else {
            next.contradictionObservedAt = nil
            return MediaPlaybackVerdict(playing: nil, correctedFromPosition: false, memory: next)
        }
        if wirePlaying {
            // The car says it is playing. Nothing to correct, and the latch is
            // spent — the next `Paused` will be a CHANGE, i.e. a fresh assertion.
            next.contradictionObservedAt = nil
            return MediaPlaybackVerdict(playing: true, correctedFromPosition: false, memory: next)
        }

        // The car says paused/stopped.
        if advanced {
            next.contradictionObservedAt = now
            return MediaPlaybackVerdict(playing: true, correctedFromPosition: true, memory: next)
        }
        if statusChanged {
            // A FRESH ASSERTION. The value we held was something else, so this
            // `Paused` is the car speaking now rather than a sentence carried
            // forward — believe it, and drop any latch.
            next.contradictionObservedAt = nil
            return MediaPlaybackVerdict(playing: false, correctedFromPosition: false, memory: next)
        }
        if let since = memory.contradictionObservedAt, now.timeIntervalSince(since) < positionEvidenceWindow {
            // Latched, and still inside the backstop: hold the correction rather
            // than flickering on the frames that carry no media news at all.
            return MediaPlaybackVerdict(playing: true, correctedFromPosition: true, memory: next)
        }
        next.contradictionObservedAt = nil
        return MediaPlaybackVerdict(playing: false, correctedFromPosition: false, memory: next)
    }

    /// The car's own reading, mapped onto the play/pause boolean.
    ///
    /// `Unknown` and any unrecognized value return `nil` so the control stays
    /// honestly unknown (MYR-251) — the pre-MYR-467 behaviour of
    /// `LiveVehicleCommandExecutor.mediaPlaying(from:)`, which now delegates here
    /// so there is exactly one mapping.
    static func playing(from status: VehicleState.MediaPlaybackStatus) -> Bool? {
        switch status {
        case .playing: return true
        case .paused, .stopped: return false
        case .unknown, .unrecognized: return nil
        }
    }
}
