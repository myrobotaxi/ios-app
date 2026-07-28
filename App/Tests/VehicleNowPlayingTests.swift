import CoreLocation
import XCTest
@testable import MyRoboTaxi
import MyRobotaxiContracts

// MARK: - MYR-303 — now-playing render rules (pure, no view)
//
// The Media card draws whatever this type says and nothing else, so every rule
// the wire imposes is asserted here rather than eyeballed in a screenshot: the
// `null` / `""` split, the radio duration sentinel, the unreliable radio elapsed,
// and the independent delivery of each field.
final class VehicleNowPlayingTests: XCTestCase {

    private func track(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        station: String? = nil,
        source: String? = nil,
        durationMs: Int? = nil,
        elapsedMs: Int? = nil
    ) -> VehicleNowPlaying {
        VehicleNowPlaying(
            title: title, artist: artist, album: album, station: station,
            source: source, durationMs: durationMs, elapsedMs: elapsedMs
        )
    }

    // MARK: The three text lines

    func testTitleLeadsAndArtistAlbumJoinTheSecondaryLine() {
        let reading = track(title: "Midnight City", artist: "M83", album: "Hurry Up, We\u{2019}re Dreaming", source: "Spotify")
        XCTAssertEqual(reading.primaryLine, "Midnight City")
        XCTAssertEqual(reading.secondaryLine, "M83 \u{00B7} Hurry Up, We\u{2019}re Dreaming")
        XCTAssertEqual(reading.sourceLabel, "Spotify")
        XCTAssertFalse(reading.isIdle)
    }

    /// Fields are INDEPENDENTLY delivered (no atomic group, no dependentRequired):
    /// a frame may carry one half and not the other, and each line must resolve on
    /// its own rather than blanking the block.
    func testEachLineResolvesIndependently() {
        XCTAssertEqual(track(title: "Nightcall").secondaryLine, nil, "no artist/album/station → no second line, no empty row")
        XCTAssertEqual(track(title: "Nightcall", artist: "Kavinsky").secondaryLine, "Kavinsky")
        XCTAssertEqual(track(title: "Nightcall", album: "OutRun").secondaryLine, "OutRun", "album alone still reads")
        XCTAssertNil(track(title: "Nightcall").sourceLabel)
        XCTAssertEqual(track(artist: "M83").primaryLine, nil, "an artist with no title/station names nothing to lead with")
    }

    /// A tuned radio with no track metadata is genuinely playing something: the
    /// station carries the title line rather than the card claiming "Nothing
    /// playing" over an audible station. It is never printed twice.
    func testStationLeadsWhenThereIsNoTrackTitle() {
        let radio = track(title: "", station: "KEXP 90.3", source: "TuneIn")
        XCTAssertEqual(radio.primaryLine, "KEXP 90.3")
        XCTAssertNil(radio.secondaryLine, "the station must not repeat itself on the second line")
        XCTAssertEqual(radio.sourceLabel, "TuneIn")
        XCTAssertFalse(radio.isIdle)

        let radioWithTrack = track(title: "Show Me the Way", artist: "Peter Frampton", station: "KEXP 90.3")
        XCTAssertEqual(radioWithTrack.primaryLine, "Show Me the Way")
        XCTAssertEqual(radioWithTrack.secondaryLine, "Peter Frampton")
    }

    /// The station fills the secondary line when the car names no artist/album.
    func testStationBecomesTheSecondaryLineWhenThereIsNoArtistOrAlbum() {
        let reading = track(title: "Traffic and Weather", station: "SiriusXM 80s")
        XCTAssertEqual(reading.primaryLine, "Traffic and Weather")
        XCTAssertEqual(reading.secondaryLine, "SiriusXM 80s")
    }

    // MARK: `null` vs `""` — the state the whole feature turns on

    /// `""` is a REAL answer ("nothing playing"), and the card must say so rather
    /// than keep the finished track on screen. Whitespace-only is the same answer.
    func testEmptyTitleIsTheIdleStateNotAMissingOne() {
        XCTAssertTrue(track(title: "").isIdle)
        XCTAssertTrue(track(title: "", artist: "").isIdle)
        XCTAssertTrue(track(title: "   ").isIdle, "whitespace-only is not a track title")
        XCTAssertNil(track(title: "").primaryLine)
        XCTAssertNil(track(title: "").progress, "an idle card draws no progress")
    }

    /// An idle reading can still carry a live-known source — the card shows it,
    /// because it is a fact the car reported.
    func testIdleStillSurfacesAKnownSource() {
        let ended = track(title: "", artist: "", source: "Spotify")
        XCTAssertTrue(ended.isIdle)
        XCTAssertEqual(ended.sourceLabel, "Spotify")
    }

    // MARK: Progress — the radio sentinel and the unreliable elapsed

    func testProgressDrawsOnlyForARealDurationAndSaneElapsed() {
        let reading = track(title: "Midnight City", durationMs: 244_000, elapsedMs: 61_000)
        let progress = try? XCTUnwrap(reading.progress)
        XCTAssertEqual(progress?.fraction ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(progress?.elapsedLabel, "1:01")
        XCTAssertEqual(progress?.durationLabel, "4:04")
    }

    /// The 18000000 ms radio sentinel is NOT a five-hour track. Drawing against it
    /// yields a scrubber that crawls from 0% and never moves — the schema forbids
    /// it outright, and we draw nothing rather than invent a "live" indicator.
    func testRadioDurationSentinelSuppressesProgressEntirely() {
        let radio = track(
            title: "Morning Edition",
            station: "KQED 88.5",
            durationMs: VehicleNowPlaying.radioDurationSentinelMs,
            elapsedMs: 120_000
        )
        XCTAssertNil(radio.progress)
        XCTAssertEqual(radio.primaryLine, "Morning Edition", "the block still renders — only the progress line is suppressed")
    }

    /// A radio elapsed can exceed, stall at, or run past its reported duration. Any
    /// of those would draw a full or overflowing bar, so they suppress the line.
    func testNonsensicalElapsedSuppressesProgress() {
        XCTAssertNil(track(title: "T", durationMs: 200_000, elapsedMs: 260_000).progress, "elapsed past the end")
        XCTAssertNil(track(title: "T", durationMs: 200_000, elapsedMs: 200_000).progress, "elapsed exactly at the end")
        XCTAssertNil(track(title: "T", durationMs: 200_000, elapsedMs: -5).progress, "negative elapsed")
        XCTAssertNil(track(title: "T", durationMs: 200_000).progress, "no elapsed at all")
        XCTAssertNil(track(title: "T", elapsedMs: 5_000).progress, "no duration at all")
        XCTAssertNil(track(title: "T", durationMs: 0, elapsedMs: 0).progress, "a zero duration is not a denominator")
    }

    func testTimeLabelMatchesThePrototypesMSSFormat() {
        XCTAssertEqual(VehicleNowPlaying.timeLabel(ms: 0), "0:00")
        XCTAssertEqual(VehicleNowPlaying.timeLabel(ms: 9_000), "0:09")
        XCTAssertEqual(VehicleNowPlaying.timeLabel(ms: 222_000), "3:42")
        XCTAssertEqual(VehicleNowPlaying.timeLabel(ms: 3_723_000), "62:03")
    }

    // MARK: Mapping — VehicleState → VehicleNowPlaying

    /// A car that has NEVER streamed a media field maps to `nil`: the block hides.
    /// This is MYR-264's rule — an unknown track is drawn as nothing, never as a
    /// placeholder — and it is what keeps a pre-0.16.0 server honest too.
    func testNeverObservedMapsToNilSoTheBlockHides() {
        XCTAssertNil(VehicleContractMapping.nowPlaying(from: Contracts.parkedState()))
    }

    /// A single observed field is enough to have a block — each is independently
    /// delivered, so waiting for a full set would hide real data.
    func testAnySingleObservedFieldProducesAReading() {
        var state = Contracts.parkedState()
        state.mediaPlaybackSource = "Bluetooth"
        let reading = VehicleContractMapping.nowPlaying(from: state)
        XCTAssertEqual(reading?.sourceLabel, "Bluetooth")
        XCTAssertEqual(reading?.isIdle, true, "a source with no title is honestly idle, not a fabricated track")
    }

    /// The `""` distinction SURVIVES the mapping: an empty title is a reading (the
    /// idle card), not a `nil` that would hide the block as if media never existed.
    func testEmptyTitleMapsToAReadingNotToNil() {
        var state = Contracts.parkedState()
        state.mediaNowPlayingTitle = ""
        let reading = VehicleContractMapping.nowPlaying(from: state)
        XCTAssertNotNil(reading, "`\"\"` means 'nothing playing' — the card renders its idle state")
        XCTAssertEqual(reading?.isIdle, true)
    }

    func testFullSnapshotMapsEveryNowPlayingField() {
        var state = Contracts.parkedState()
        state.mediaNowPlayingTitle = "Resonance"
        state.mediaNowPlayingArtist = "HOME"
        state.mediaNowPlayingAlbum = "Odyssey"
        state.mediaNowPlayingStation = "Chillhop"
        state.mediaPlaybackSource = "Spotify"
        state.mediaNowPlayingDurationMs = 213_000
        state.mediaNowPlayingElapsedMs = 42_000

        let snapshot = VehicleContractMapping.snapshot(from: state)
        let reading = try? XCTUnwrap(snapshot.nowPlaying)
        XCTAssertEqual(reading?.primaryLine, "Resonance")
        XCTAssertEqual(reading?.secondaryLine, "HOME \u{00B7} Odyssey")
        XCTAssertEqual(reading?.sourceLabel, "Spotify")
        XCTAssertEqual(reading?.progress?.durationLabel, "3:33")
        XCTAssertEqual(reading?.progress?.elapsedLabel, "0:42")
    }

    /// The simulated path never produces a reading — which is exactly what keeps
    /// the M1 / drift-gate media card on its fixture track, pixel-identical.
    @MainActor
    func testSimulatedTelemetryHasNoNowPlaying() {
        let sim = SimulatedVehicleTelemetrySource(activity: .parked(
            ParkedLocation(label: "Home", coordinate: .init(latitude: 37.77, longitude: -122.41), parkedSince: nil)
        ))
        XCTAssertNil(sim.snapshot.nowPlaying)
    }
}
