import SwiftUI
import DesignSystem

// MARK: - Media section (vehicle-controls.jsx:348-381)
//
// Cover + title/artist, gold scrubber, transport row (prev / play-pause /
// next), and a gold volume slider. Scrub position is local UI-only feedback
// (no Fleet API seek-to-position); volume routes through the command
// executor.

struct MediaSection: View {
    let controls: VehicleControlsSnapshot
    let executor: any VehicleCommandExecutor
    let track: VehicleMediaTrack

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live command state for the transport row (MYR-249 phase 3: play/pause +
    /// skip route through media_toggle_playback / media_next_track /
    /// media_prev_track). `.idle` on the simulated path → pixel-identical M1.
    private var mediaState: VehicleControlUIState { executor.uiState(for: .media) }

    private var scrubBinding: Binding<Double> {
        Binding(get: { controls.scrubPercent }, set: { executor.setScrubPercent($0) })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { controls.volume }, set: { newValue in Task { try? await executor.setVolume(newValue) } })
    }

    /// vehicle-controls.jsx:233-237 `fmtTime` — a 3:42 track.
    private func formattedTime(_ percent: Double) -> String {
        let totalSeconds = Int((percent / 100 * 222).rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    var body: some View {
        SectionCard(title: "Media") {
            VStack(alignment: .leading, spacing: 0) {
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
                                Image(systemName: controls.mediaPlaying ? "pause.fill" : "play.fill")
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

                // A settled media notice (re-link / pairing / waking / …) on a
                // quiet centered line — never rendered on the simulated path.
                if let notice = mediaState.notice {
                    Text(notice.message)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.mrtTextSec)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }

                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 15)).foregroundStyle(Color.mrtTextSec)
                    MRTSlider(value: volumeBinding, trackHeight: 4)
                }
                .padding(.top, 16)
            }
        }
    }

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
