import DesignSystem
import SwiftUI
import UIKit

// MARK: - The one system answer this feature never showed anyone (MYR-479)
//
// `ActivityAuthorizationInfo().areActivitiesEnabled` has been readable through
// `RideActivityPresenting` since MYR-172, and until this issue it was consulted in
// exactly one place — `SystemRideActivityPresenter.start`, which returns `false` and
// says nothing. The coordinator's own comment calls that "ordinary", and it is: a
// rider may simply have Live Activities off, and the in-app tracking sheet carries
// the ride either way.
//
// **WHAT IS NOT ORDINARY IS THAT NOBODY COULD FIND OUT.** There was no banner, no
// row, no log line and no Settings hint, so a rider whose ride never reached their
// lock screen, and the person triaging it, had the same evidence: none. MYR-461's
// triage instruction was literally *"her device's LA permission state has not been
// verified and should be"* — and there was nothing in the app that could verify it.
//
// This is the smallest honest fix: state the fact where the rider already goes to
// change it, in the same slot and the same grammar MYR-186's `PushDeniedNotice`
// uses. It is deliberately NOT a prompt — there is no system prompt for Live
// Activities, only the Settings toggle — and deliberately not an error.

/// Whether the system will allow this app a Live Activity.
///
/// Three cases rather than a `Bool`, for this repo's standing reason: "we have not
/// asked" is a third situation and folding it into `false` would put a notice on
/// every simulated boot and every DEBUG capture. `.unknown` is what the simulated
/// path reports for ever — `RideActivityCoordinator` is built INERT there and never
/// touches ActivityKit — so no capture can grow this line.
enum LiveActivityAuthorizationState: Equatable, Sendable {
    /// Never asked. Simulated mode, and the window before the first launch pass.
    case unknown
    /// The rider allows Live Activities for this app.
    case enabled
    /// Switched off in iOS Settings. The only route back is the Settings app.
    case disabled
}

/// The Settings hint, rendered ONLY when Live Activities are switched off.
///
/// Written to `PushDeniedNotice`'s pattern down to the details that matter: the
/// vertical spacing lives INSIDE the conditional (a call site padding from outside
/// would reserve the space on the overwhelmingly common enabled path and move every
/// row below it), and the button claims the 44pt tap floor through `minHeight`
/// rather than through padding that would push the section's rhythm around.
struct LiveActivityDeniedNotice: View {
    var state: LiveActivityAuthorizationState
    @Environment(\.openURL) private var openURL

    var body: some View {
        if state == .disabled {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.message)
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
                .frame(minHeight: 44, alignment: .leading)
            }
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Named so a test can assert the sentence without re-typing it, and so the two
    /// Settings screens cannot drift into two wordings of one fact.
    ///
    /// It names the two SURFACES rather than the feature, because "Live Activities"
    /// is Apple's word for a thing most riders know only as "the thing on my lock
    /// screen" — and it says what is lost rather than what is off, which is the
    /// difference between a setting and a consequence.
    static let message = """
        Live Activities are turned off for MyRoboTaxi, so your ride won't appear on \
        the Lock Screen or in the Dynamic Island.
        """
}
