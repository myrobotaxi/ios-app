import DesignSystem
import SwiftUI
import UIKit

// MARK: - "Notifications are off" notice (MYR-186)
//
// The one and only recovery affordance in v1, deliberately minimal.
//
// iOS shows the authorization alert exactly once per install. After a denial —
// or after the user switches notifications off in Settings later — the app can do
// nothing but point at the Settings app. The scope rule for that pointer is
// "only where a push-dependent feature is obviously missed", and there is exactly
// one such place: the Settings NOTIFICATIONS section, whose toggles are the one
// surface that visibly promises notifications the device will not deliver.
//
// It is NOT an interstitial, NOT a banner on the map, and NOT a re-prompt: those
// would be new design (the prototype has no such surface) and a re-prompt is a
// silent OS no-op anyway.
//
// Renders ONLY when the system state is `.denied`. Every other state — including
// the entire simulated path, where the coordinator never observes a state at all
// — renders nothing, so both Settings screens stay pixel-identical to the
// prototype for every drift-gate capture.
struct PushDeniedNotice: View {
    var state: PushAuthorizationState
    @Environment(\.openURL) private var openURL

    var body: some View {
        if state == .denied {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are turned off for MyRoboTaxi. These settings take effect once you allow them in iOS Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mrtGold)
                .buttonStyle(.plain)
                // Min tap target 44pt (CLAUDE.md) — the label is ~16pt tall, so
                // the row claims the rest through its frame rather than padding
                // that would push the section's rhythm around.
                .frame(minHeight: 44, alignment: .leading)
            }
            // Vertical spacing lives INSIDE the `if`. A call site that padded the
            // component from outside would reserve that space even when nothing
            // renders, moving every row below it by a few points on the
            // overwhelmingly common non-denied path — exactly the silent layout
            // drift the MYR-196 punch list was about.
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
