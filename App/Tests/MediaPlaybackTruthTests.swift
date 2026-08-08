import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-467 — Paused over a position that was running
//
// External beta, build 202608030843, one tester, two submissions a minute apart:
// *"Music is playing but it shows as paused"* and then *"Music switched back to
// playing after I took previous screenshot"*. Same track, 0:01 → 0:11 of 3:09,
// transport ▶ then ⏸. The position advancing across the pair is what proves the
// app was wrong rather than the car.
//
// The rule under test is the issue's own: **if the playback position advances
// between frames, the state is not paused.** The tests that matter most are the
// ones about when the correction ENDS — a latch with no release is a worse bug
// pointing the other way, and both directions are asserted here.
@MainActor
final class MediaPlaybackTruthTests: XCTestCase {

    private let track = MediaTrackIdentity(
        title: "Used To - Ruhde Remix",
        artist: "Sandro Cavazza, Lou Elliotte, Ruhde",
        album: "Remixes",
        durationMs: 189_000
    )
    private let otherTrack = MediaTrackIdentity(
        title: "Something Else",
        artist: "Somebody",
        album: "Elsewhere",
        durationMs: 210_000
    )

    private let t0 = Date(timeIntervalSince1970: 1_775_000_000)

    // MARK: The reported defect

    /// THE FIELD REPORT, frame for frame. The car's status is a `Paused` carried
    /// forward by the merger (it does not change between the two frames) while the
    /// position runs 1s → 11s. Fails on `main`, where the wire status is read
    /// straight through.
    func testAPositionThatAdvancesUnderAStaleaPausedOverrulesIt() {
        var memory = MediaPlaybackMemory.empty
        let first = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 1_000, memory: memory, now: t0
        )
        // The FIRST sighting has nothing to compare against and is believed: one
        // frame cannot show a position advancing.
        XCTAssertEqual(first.playing, false)
        memory = first.memory

        let second = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 11_000, memory: memory, now: t0.addingTimeInterval(10)
        )
        XCTAssertEqual(second.playing, true, "the track moved ten seconds; the car is not paused")
        XCTAssertTrue(second.correctedFromPosition)
    }

    /// The correction must not FLICKER. `reconcile` runs on every folded delta —
    /// a cabin temperature, a GPS fix — and those frames carry the same media
    /// values as the last one. Without the latch the icon would bounce
    /// paused/playing for the whole contradiction.
    func testTheCorrectionHoldsAcrossFramesThatCarryNoMediaNews() {
        var memory = MediaPlaybackMemory.empty
        memory = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 1_000, memory: memory, now: t0
        ).memory
        memory = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 11_000, memory: memory, now: t0.addingTimeInterval(10)
        ).memory

        for offset in [10.5, 11.0, 11.5, 12.0] {
            let frame = MediaPlaybackTruth.resolve(
                wire: .paused, track: track, positionMs: 11_000,
                memory: memory, now: t0.addingTimeInterval(offset)
            )
            XCTAssertEqual(frame.playing, true, "an unchanged frame is not evidence the car stopped")
            memory = frame.memory
        }
    }

    // MARK: When the correction ends

    /// **A GENUINE PAUSE IS BELIEVED ON THE VERY NEXT FRAME.** When the car really
    /// pauses it EMITS `Paused`, and the status we hold at that moment is
    /// `Playing` — so the value CHANGES. A change is the car speaking now; an
    /// unchanged status is the merger carrying an old sentence forward. This is
    /// the distinction that lets the latch be safe.
    func testARealPauseIsHonouredImmediatelyBecauseItChangesTheStatus() {
        var memory = MediaPlaybackMemory.empty
        // Contradiction, then the car catches up and says Playing.
        memory = MediaPlaybackTruth.resolve(wire: .paused, track: track, positionMs: 1_000, memory: memory, now: t0).memory
        memory = MediaPlaybackTruth.resolve(wire: .paused, track: track, positionMs: 11_000, memory: memory, now: t0.addingTimeInterval(10)).memory
        let caughtUp = MediaPlaybackTruth.resolve(
            wire: .playing, track: track, positionMs: 12_000, memory: memory, now: t0.addingTimeInterval(11)
        )
        XCTAssertEqual(caughtUp.playing, true)
        XCTAssertFalse(caughtUp.correctedFromPosition, "the car agrees now — nothing is being overruled")
        memory = caughtUp.memory

        // The rider hits pause in the car. Status CHANGES Playing → Paused, one
        // second later, well inside the backstop window.
        let paused = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 12_000, memory: memory, now: t0.addingTimeInterval(12)
        )
        XCTAssertEqual(paused.playing, false, "a fresh assertion beats a spent latch, with no window to wait out")
        XCTAssertFalse(paused.correctedFromPosition)
    }

    /// The backstop, for the one case the fresh-assertion rule cannot see: the
    /// status reads `Paused` on both sides of a real pause and never changes. The
    /// position stops advancing, so the latch lapses and the car's word wins.
    func testTheLatchLapsesWhenThePositionStopsAdvancingAndTheStatusNeverChanges() {
        var memory = MediaPlaybackMemory.empty
        memory = MediaPlaybackTruth.resolve(wire: .paused, track: track, positionMs: 1_000, memory: memory, now: t0).memory
        memory = MediaPlaybackTruth.resolve(wire: .paused, track: track, positionMs: 11_000, memory: memory, now: t0.addingTimeInterval(10)).memory

        let justInside = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 11_000,
            memory: memory, now: t0.addingTimeInterval(10 + MediaPlaybackTruth.positionEvidenceWindow - 1)
        )
        XCTAssertEqual(justInside.playing, true)

        let pastIt = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 11_000,
            memory: memory, now: t0.addingTimeInterval(10 + MediaPlaybackTruth.positionEvidenceWindow + 1)
        )
        XCTAssertEqual(pastIt.playing, false, "the evidence has expired; accept the car's reported reality")
        XCTAssertFalse(pastIt.correctedFromPosition)
    }

    // MARK: What is never evidence

    /// A re-delivered IDENTICAL position is the merger carrying a value forward,
    /// exactly as it does the status — not a track that moved.
    func testAnUnchangedPositionIsNotAnAdvance() {
        var memory = MediaPlaybackMemory.empty
        memory = MediaPlaybackTruth.resolve(wire: .paused, track: track, positionMs: 5_000, memory: memory, now: t0).memory
        let again = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 5_000, memory: memory, now: t0.addingTimeInterval(3)
        )
        XCTAssertEqual(again.playing, false)
        XCTAssertFalse(again.correctedFromPosition)
    }

    /// Elapsed restarts near zero on a new track, so a comparison across the
    /// boundary measures nothing — and a track change is the very frame this
    /// defect appears on.
    func testATrackChangeIsNeverComparedAcross() {
        var memory = MediaPlaybackMemory.empty
        memory = MediaPlaybackTruth.resolve(wire: .paused, track: otherTrack, positionMs: 1_000, memory: memory, now: t0).memory
        let newTrack = MediaPlaybackTruth.resolve(
            wire: .paused, track: track, positionMs: 9_000, memory: memory, now: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(newTrack.playing, false, "9s of a NEW track is not 8s of progress on the old one")
        XCTAssertFalse(newTrack.correctedFromPosition)
    }

    /// **The rule corrects a stated `paused`; it never invents a session.**
    /// MYR-314's gate stands: an absent / `Unknown` status leaves the field
    /// honestly unknown (transport disabled, "Start media in the car first"), and
    /// a position advancing underneath it does not open the transport row over a
    /// car that has not said it has media.
    func testAnUnknownStatusStaysUnknownHoweverThePositionMoves() {
        var memory = MediaPlaybackMemory.empty
        memory = MediaPlaybackTruth.resolve(wire: nil, track: track, positionMs: 1_000, memory: memory, now: t0).memory
        let advancing = MediaPlaybackTruth.resolve(
            wire: nil, track: track, positionMs: 11_000, memory: memory, now: t0.addingTimeInterval(10)
        )
        XCTAssertNil(advancing.playing)

        let unknownEnum = MediaPlaybackTruth.resolve(
            wire: .unknown, track: track, positionMs: 21_000, memory: advancing.memory, now: t0.addingTimeInterval(20)
        )
        XCTAssertNil(unknownEnum.playing)
    }

    /// `Stopped` is corrected on exactly the same evidence as `Paused` — both
    /// assert the car is not playing, and both are equally contradicted by a
    /// position that moves.
    func testStoppedIsCorrectedTheSameWayPausedIs() {
        var memory = MediaPlaybackMemory.empty
        memory = MediaPlaybackTruth.resolve(wire: .stopped, track: track, positionMs: 1_000, memory: memory, now: t0).memory
        let advancing = MediaPlaybackTruth.resolve(
            wire: .stopped, track: track, positionMs: 4_000, memory: memory, now: t0.addingTimeInterval(3)
        )
        XCTAssertEqual(advancing.playing, true)
    }

    // MARK: Through the executor

    /// The rule reaching the control the owner actually looks at. Two frames off
    /// the wire, folded by the shipping `reconcile`, and the transport row ends up
    /// on PLAY-ing rather than the ▶ the tester photographed.
    func testTheTransportRowFollowsThePositionThroughTheRealReconcile() {
        let exec = LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: ScriptedCommandSender(),
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            rideShareEndpoint: ScriptedRideShareEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 1,
            settleWindow: 15,
            noticeDisplayDuration: .seconds(600)
        )

        func frame(elapsedMs: Int) -> VehicleState {
            var state = Contracts.parkedState()
            state.mediaPlaybackStatus = .paused
            state.mediaNowPlayingTitle = "Used To - Ruhde Remix"
            state.mediaNowPlayingArtist = "Sandro Cavazza, Lou Elliotte, Ruhde"
            state.mediaNowPlayingAlbum = "Remixes"
            state.mediaNowPlayingDurationMs = 189_000
            state.mediaNowPlayingElapsedMs = elapsedMs
            return state
        }

        exec.reconcile(from: frame(elapsedMs: 1_000), snapshotReadIssuedAt: Date())
        XCTAssertTrue(exec.isKnown(.mediaPlaying))
        XCTAssertFalse(exec.controls.mediaPlaying, "one frame cannot show a position advancing")

        exec.reconcile(from: frame(elapsedMs: 11_000), snapshotReadIssuedAt: Date())
        XCTAssertTrue(
            exec.controls.mediaPlaying,
            "the track advanced ten seconds under a Paused the merger carried forward"
        )
    }

    /// The no-session arm through the real reconcile, unchanged from MYR-314: a
    /// car that cleared its media un-knows the field whatever the last position
    /// was, so the transport row goes muted rather than staying live.
    func testAClearedMediaSessionStillUnKnowsTheFieldThroughTheRealReconcile() {
        let exec = LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: ScriptedCommandSender(),
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            rideShareEndpoint: ScriptedRideShareEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 1,
            settleWindow: 15,
            noticeDisplayDuration: .seconds(600)
        )

        var playing = Contracts.parkedState()
        playing.mediaPlaybackStatus = .playing
        playing.mediaNowPlayingTitle = "Used To - Ruhde Remix"
        playing.mediaNowPlayingElapsedMs = 1_000
        exec.reconcile(from: playing, snapshotReadIssuedAt: Date())
        XCTAssertTrue(exec.isKnown(.mediaPlaying))

        var cleared = Contracts.parkedState()
        cleared.mediaNowPlayingTitle = ""
        exec.reconcile(from: cleared, snapshotReadIssuedAt: Date())
        XCTAssertFalse(exec.isKnown(.mediaPlaying), "no status, no session — MYR-314's gate is untouched")
    }
}
