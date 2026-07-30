import DesignSystem
import SwiftUI

// MARK: - "That didn't save" / "Couldn't load those" line (MYR-349)
//
// The honest half of the optimistic write. `LivePushPrefsService` flips a row the
// instant it is touched and rolls it back if the `PUT` did not land — and a
// rollback with nothing said is nearly as bad as no rollback at all: a row that
// snapped back looks exactly like a row nobody touched, so the user is left
// believing whatever they believed before. The same holds for a failed `GET`:
// five confident switches nobody fetched are a claim, not a default.
//
// Deliberately the SAME quiet-line grammar as `PushDeniedNotice` (12pt,
// `mrtTextMuted`, its own bottom padding INSIDE the `if` so nothing shifts when
// there is nothing to say) rather than a dialog or a toast — this is a settings
// list, and the design's convention for "we couldn't" here is one muted line
// beside the thing it is about. The `revokeFailed` pill is the other convention in
// this file's neighbourhood, and it is right for a DESTRUCTIVE action that
// happened once; a preference the user can simply touch again is a line, not an
// interruption.
//
// Renders ONLY when the service is holding a message — which the SIMULATED
// service never is, by construction (`statusMessage` is always `nil`). Both
// Settings screens are therefore pixel-identical on every simulated and DEBUG
// capture.
struct PushPrefsNotice: View {
    var message: String?

    var body: some View {
        if let message, !message.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.mrtTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                // Vertical spacing lives INSIDE the `if`, for the reason
                // `PushDeniedNotice` spells out: padding applied from the call
                // site would reserve the space even when nothing renders and move
                // every row below it on the overwhelmingly common path.
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
