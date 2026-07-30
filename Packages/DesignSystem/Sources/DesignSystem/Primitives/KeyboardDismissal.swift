import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MRTKeyboard (MYR-239 precedent, generalized by MYR-344)
//
// ONE way to put the keyboard down, because there is exactly one correct way and
// the app now needs it on three surfaces (the rider Search sheet's exit paths,
// MYR-239; the owner's invite composer, MYR-344).
//
// A SwiftUI `@FocusState` write alone is NOT enough on an exit path. It is a
// *request* that lands on the next update; if a presentation (a sheet, a phase
// change) starts in the same runloop turn, the keyboard is still on screen and
// still holding its safe-area inset while the new surface lays out — which is
// how MYR-239's keyboard stranded over a mid-animation sheet, and how MYR-344's
// invite composer laid out INSIDE a keyboard-shrunk container and had its
// "Send invite" CTA cut off below the fold. Force-resigning first responder
// commits the dismissal immediately; the focus binding is still dropped
// alongside it so SwiftUI does not put the keyboard straight back.
public enum MRTKeyboard {

    /// Force-resign whatever holds first responder.
    ///
    /// - Returns: `true` when a responder actually took the action — i.e. the
    ///   keyboard WAS up and is now dismissing. Callers that must present over a
    ///   settled layout use this to decide whether they owe the dismissal its
    ///   animation (see `dismissalSettle`) instead of blanket-delaying every
    ///   presentation for a keyboard that was never there.
    @MainActor
    @discardableResult
    public static func dismiss() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        #else
        return false
        #endif
    }

    /// How long to let a dismissal settle before presenting over the layout it
    /// was compressing. The system keyboard's hide animation is 0.25s
    /// (`UIResponder.keyboardAnimationDurationUserInfoKey` on every current
    /// runtime); a presentation started inside that window still measures the
    /// shrunken container.
    public static let dismissalSettle: Duration = .milliseconds(250)
}
