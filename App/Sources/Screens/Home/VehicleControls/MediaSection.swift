import SwiftUI
import DesignSystem

// MARK: - Media section (vehicle-controls.jsx:348-381)
//
// Cover + title/artist, gold scrubber, transport row (prev / play-pause /
// next), and a gold volume slider. Scrub position is local UI-only feedback
// (no Fleet API seek-to-position); volume routes through the command
// executor.
//
// MYR-303 — the card now has TWO now-playing sources, and only one can ever be
// live at a time:
//   • SIM / drift-gate: the `VehicleMediaTrack` fixture (`track`), rendered
//     exactly as before — cover swatch, title, artist, interactive scrubber.
//   • LIVE: a real `VehicleNowPlaying` off the wire (contracts 0.16.0), rendered
//     in the SAME layout structure minus the two things the wire cannot supply:
//     album ART (no artwork field exists anywhere in the contract — a gradient
//     swatch next to a real song would be invented data) and an INTERACTIVE
//     scrubber (there is no seek-to-position command in §7.9, so the live
//     progress line is passive).
//
// MYR-314 — the transport row is GATED on a live media session. `mediaPlaybackStatus`
// absent / `Unknown` / unrecognized means the car has no session to act on, so
// media_toggle_playback / next / prev would be shouting into a void; the buttons
// mute and stop taking taps and the card says why. The play/pause icon reflects
// the WIRE status (streamed live since MYR-298), never a local tap.

struct MediaSection: View {
    let controls: VehicleControlsSnapshot
    let executor: any VehicleCommandExecutor
    /// The now-playing track — a pure fixture (`VehicleMediaTrack`). `nil` on the
    /// live path (MYR-264): media title/artist/cover are not on the `VehicleState`
    /// contract, so the now-playing block + scrubber are honest-hidden rather than
    /// showing a fake song ("Midnight City · M83"). The transport row + volume
    /// slider route REAL commands (MYR-249/251) and remain. Always non-nil in SIM,
    /// so the M1 / drift-gate media section is pixel-identical.
    let track: VehicleMediaTrack?
    /// MYR-303 — the REAL now-playing block off the wire (contracts 0.16.0). `nil`
    /// in SIM and on a live car that has never streamed a media field, in which
    /// case nothing here renders and the card is exactly what MYR-264 left. Only a
    /// real `VehicleState` can produce one (`VehicleContractMapping.nowPlaying`),
    /// so this is also what tells the view it is on the live media path.
    var nowPlaying: VehicleNowPlaying? = nil
    /// MYR-301 — routes a media re-link notice to the existing Tesla link flow
    /// (see `VehicleControls.onRelinkTesla`).
    var onRelinkTesla: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live command state for the transport row (MYR-249 phase 3: play/pause +
    /// skip route through media_toggle_playback / media_next_track /
    /// media_prev_track). `.idle` on the simulated path → pixel-identical M1.
    private var mediaState: VehicleControlUIState { executor.uiState(for: .media) }

    /// MYR-314 — whether the car currently reports a media SESSION. On the live
    /// path this is the wire `mediaPlaybackStatus` folded to a known play/pause
    /// (Playing / Paused / Stopped); absent, `Unknown`, and any unrecognized value
    /// leave it false and un-know the field, so the gate re-arms when a session
    /// ends instead of latching. `true` on the simulated path (the executor's
    /// fixtures are authoritative), which keeps M1 / drift-gate identical.
    private var hasMediaSession: Bool { executor.isKnown(.mediaPlaying) }
    /// MYR-251 — volume is unknown on the live path until it is read or commanded.
    private var volumeKnown: Bool { executor.isKnown(.volume) }

    private var scrubBinding: Binding<Double> {
        Binding(get: { controls.scrubPercent }, set: { executor.setScrubPercent($0) })
    }

    /// MYR-441 — the getter still answers `0` for an unknown volume, and that is
    /// now safe because nothing DRAWS it: the row passes `showsValue: false`, so
    /// `MRTSlider` renders the bare track with no fill and no thumb. Before this,
    /// the 0 reached the thumb and pinned it to the left edge over an empty track,
    /// which is precisely how this control draws a car that is MUTED — a confident
    /// reading of a value the car had never reported. The binding keeps a real
    /// `Double` because the drag must still work: setting the volume is also what
    /// CONFIRMS the field (MYR-251) and returns the slider to its known rendering.
    private var volumeBinding: Binding<Double> {
        Binding(
            get: { volumeKnown ? controls.volume : 0 },
            set: { newValue in Task { try? await executor.setVolume(newValue) } }
        )
    }

    /// vehicle-controls.jsx:233-237 `fmtTime` — a 3:42 track.
    private func formattedTime(_ percent: Double) -> String {
        let totalSeconds = Int((percent / 100 * 222).rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    var body: some View {
        SectionCard(title: "Media") {
            VStack(alignment: .leading, spacing: 0) {
                // MYR-303 — a REAL now-playing reading always wins. It exists only
                // when a live `VehicleState` carried media fields, so this branch
                // is unreachable in SIM (where `nowPlaying` is nil and the fixture
                // renders below, pixel-identical) and is the only branch on live
                // (where MYR-264 already passes `track: nil`). Ordering it first is
                // what lets a DEBUG capture scene inject a live-shaped snapshot
                // into the simulated shell and still exercise the shipping render.
                if let nowPlaying {
                    liveNowPlaying(nowPlaying)
                } else if let track {
                    // MYR-264 — the FIXTURE block + interactive scrubber (SIM /
                    // drift-gate only; the live path passes nil).
                    HStack(spacing: 13) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(
                                colors: [track.gradientStart, track.gradientEnd],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 52, height: 52)
                            .shadow(color: .mrtMediaCoverShadow, radius: 5, y: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 15, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundStyle(Color.mrtText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(track.artist)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.mrtTextSec)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.bottom, 14)

                    MRTSlider(value: scrubBinding, trackHeight: 4)
                    HStack {
                        Text(formattedTime(controls.scrubPercent))
                        Spacer()
                        Text("3:42")
                    }
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }

                transportRow

                // A settled media notice (re-link / pairing / waking / …) on a
                // quiet centered line — never rendered on the simulated path.
                if let notice = mediaState.notice {
                    // MYR-301 — full message (the row is sheet-wide); a re-link
                    // notice becomes a 44pt tap target routing to the link flow.
                    VehicleCommandNoticeLine(notice: notice, alignment: .center, onAction: onRelinkTesla)
                        .padding(.top, 10)
                }

                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 15)).foregroundStyle(Color.mrtTextSec)
                    MRTSlider(value: volumeBinding, trackHeight: 4, showsValue: volumeKnown)
                    // MYR-441 — the honest-unknown mark, and the ONLY thing this
                    // row gains. It appears solely on the unknown branch, so a
                    // known volume is byte-identical to before; the row carried no
                    // text at all, so a bare track with nothing beside it said
                    // nothing about WHY it was empty. This is the fan row's own
                    // grammar one card up ("— / 10"), and `ClimateTemperatureText
                    // .dash` is the app's ONE unknown glyph rather than a second
                    // literal (it is asserted equal to `BatteryReadout.dash`).
                    if let volumeText = VehicleControlReadout.volumeText(known: volumeKnown) {
                        Text(volumeText)
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.mrtText)
                    }
                }
                // Unknown volume (live path, uncommanded) shows a neutral slider at
                // rest, dimmed — no asserted level (MYR-251/441).
                .opacity(volumeKnown ? 1 : 0.5)
                .padding(.top, 16)
            }
        }
    }

    // MARK: - Live now-playing (MYR-303)

    /// The wire's now-playing block, in the prototype media card's own layout: a
    /// 15pt semibold primary line over a 12.5pt secondary, then (when it exists) a
    /// passive progress line with the same 4pt track and 10.5pt tabular time row
    /// the fixture scrubber uses. Every line renders ONLY from a live-known value.
    ///
    /// Two deliberate departures from the fixture block, both because the wire has
    /// no such value and inventing one is the MYR-264 bug:
    ///   • **No cover swatch.** No artwork field exists in the contract, and a
    ///     gradient rectangle beside a REAL song reads as this car's album art.
    ///     The text stack takes the full width instead — the same typography, the
    ///     same 14pt gap below.
    ///   • **No interactive scrubber.** §7.9 has no seek-to-position command, so a
    ///     draggable thumb would be a control that does nothing. The line is a
    ///     passive reading, drawn only when the duration is real and the elapsed is
    ///     sane (see `VehicleNowPlaying.progress`).
    @ViewBuilder
    private func liveNowPlaying(_ nowPlaying: VehicleNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let primary = nowPlaying.primaryLine {
                Text(primary)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let secondary = nowPlaying.secondaryLine {
                    Text(secondary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                // The `""` case: media HAS been observed on this car and nothing is
                // playing now. Say so plainly at the title's size in the muted tone
                // — never the previous track, never a blank row (MYR-264 honesty).
                Text("Nothing playing")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtTextMuted)
                    .lineLimit(1)
            }
            if let source = nowPlaying.sourceLabel {
                Text(source)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mrtTextMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)

        if let progress = nowPlaying.progress {
            // The fixture scrubber's geometry (4pt track, gold fill) without the
            // thumb — a reading, not a control.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mrtElevated).frame(height: 4)
                    Capsule()
                        .fill(Color.mrtGold)
                        .frame(width: max(4, geo.size.width * progress.fraction), height: 4)
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(progress.elapsedLabel) of \(progress.durationLabel)")
            HStack {
                Text(progress.elapsedLabel)
                Spacer()
                Text(progress.durationLabel)
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(Color.mrtTextMuted)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Transport (MYR-314)

    /// Prev / play-pause / next, plus the honest sub-copy when there is no session.
    ///
    /// Gated (`hasMediaSession == false`) the row is muted and takes no taps: with
    /// no session in the car there is nothing for `media_toggle_playback` to toggle
    /// and nothing for next/prev to skip, so live buttons would produce either
    /// silence or a "the car didn't accept that" notice for a perfectly healthy
    /// car. The sub-copy names the ONE thing that fixes it, in the car.
    ///
    /// Ungated, the play/pause icon is the WIRE status (`controls.mediaPlaying`,
    /// reconciled from `mediaPlaybackStatus` since MYR-298) — the executor no
    /// longer marks the field known off a local tap, so the icon cannot drift into
    /// asserting a playback state the car never reported.
    private var transportRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 30) {
                transportButton("backward.fill", size: 22) {
                    Task { try? await executor.skipTrack(.previous) }
                }
                .opacity(mediaState.isPending ? 0.5 : 1)
                Button {
                    Task { try? await executor.setMediaPlaying(!controls.mediaPlaying) }
                } label: {
                    // Pending → a spinner in the gold circle (Reduce Motion
                    // falls back to the static icon dimmed). Idle renders the
                    // bare icon exactly as before, so the M1 / drift-gate
                    // scenes are pixel-identical.
                    Group {
                        if mediaState.isPending, !reduceMotion {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.mrtGoldButtonLabel)
                        } else {
                            // No session → the neutral play.fill affordance. The
                            // seeded `mediaPlaying` is NOT a wire fact (it seeds
                            // from `driving`), so a gated row must never render it
                            // as a pause icon claiming the car is playing.
                            Image(systemName: hasMediaSession && controls.mediaPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.mrtGoldButtonLabel)
                                .opacity(mediaState.isPending ? 0.5 : 1)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .background(Color.mrtGold, in: Circle())
                }
                .buttonStyle(.plain)
                transportButton("forward.fill", size: 22) {
                    Task { try? await executor.skipTrack(.next) }
                }
                .opacity(mediaState.isPending ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity)
            // Muted + inert with no session. `.disabled` alone would also dim the
            // gold disc unevenly across platforms, so the opacity is explicit and
            // the whole row stops hit-testing.
            .opacity(hasMediaSession ? 1 : 0.4)
            .disabled(!hasMediaSession)
            .allowsHitTesting(hasMediaSession)
            .accessibilityHint(hasMediaSession ? "" : Self.noSessionCopy)

            if !hasMediaSession {
                Text(Self.noSessionCopy)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mrtTextMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
        }
    }

    /// The honest reason the transport is inert — it names the action that fixes
    /// it, and it is deliberately about the CAR: nothing in the app can start a
    /// media session (there is no §7.9 "play this" command, only a toggle).
    static let noSessionCopy = "Start media in the car first"

    private func transportButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(Color.mrtText)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fixture (vehicle-controls.jsx:199-203 `TRACKS`)

/// Fake album art — decorative only, matches the jsx's own placeholder
/// `TRACKS` fixture (no real media integration in M1 or M2).
struct VehicleMediaTrack: Identifiable {
    let id: Int
    let title: String
    let artist: String
    let gradientStart: Color
    let gradientEnd: Color

    static let all: [VehicleMediaTrack] = [
        VehicleMediaTrack(id: 0, title: "Midnight City", artist: "M83", gradientStart: .mrtMediaTrack1Start, gradientEnd: .mrtGold),
        VehicleMediaTrack(id: 1, title: "Nightcall", artist: "Kavinsky", gradientStart: .mrtMediaTrack2Start, gradientEnd: .mrtMediaTrack2End),
        VehicleMediaTrack(id: 2, title: "Resonance", artist: "HOME", gradientStart: .mrtMediaTrack3Start, gradientEnd: .mrtMediaTrack3End),
    ]
}
