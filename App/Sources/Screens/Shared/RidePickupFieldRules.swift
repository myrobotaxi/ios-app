import CoreLocation
import Foundation

// MARK: - MYR-445 — the pickup field's two pure rules
//
// The client, r-build `202608022357`: *"the current location is stuck as a static
// placeholder, so I have to type over it. It doesn't disappear when selecting on
// it. Then if i type and search and select new pick up point it sets, but if I go
// backwards back to that search step and change the pick up point, current
// location shows as the placeholder again even though its not actually set and if
// I select current location or any other pick up address it doesn't actually set
// it and is stuck on the first one and doesn't let me fine tune the pick up, the
// map route polyline is also stuck bc the pickup point did not update."*
//
// Two of the four defects are DECISIONS rather than plumbing, and both had been
// made inline inside a 1400-line view / a 2000-line observable where nothing
// could assert on them. They are pure functions here for the reason MYR-398's
// `RideActivityMetrics` was moved: **a promise about behaviour that no test reads
// is a promise about a comment.**

/// MYR-445 defect 1 — what FOCUS does to the pickup field's text.
///
/// MYR-379 drew the "Current location" default as a full-strength `Text` overlay
/// rather than as the system's muted placeholder, deliberately: it is the
/// pickup's real default VALUE and it was full-strength `mrtText` before that
/// issue, so a muted rendering would have been a second, quieter way of changing
/// what an untouched rider sees. **That decision is kept.** What it cost is the
/// client's first sentence: a default that looks exactly like a value, in a field
/// that behaves exactly like a field, reads as text you must delete before you can
/// type — and on the re-entry path (defect 2) it genuinely WAS text.
///
/// So the field behaves like a VALUE on focus, which is the destination field's
/// own grammar restated for a field whose empty state is not a muted prompt:
///
///  • **The default never renders while the field holds first responder.** A
///    cursor next to full-strength "Current location" is the whole of "it doesn't
///    disappear when selecting on it"; an empty focused field cannot be mistaken
///    for one holding a value.
///  • **Focusing a field that holds a committed pickup CLEARS it**, so typing
///    REPLACES rather than appends. This is the "clear-on-focus" half of the
///    issue's own "clear-on-focus or select-all"; clear is chosen over select-all
///    because select-all on a SwiftUI `TextField` is only reachable through a
///    global `UITextField.textDidBeginEditingNotification` observer, i.e. a rule
///    about EVERY field in the app expressed as a side effect, and because a
///    cleared field is a value a pure test can state.
///  • **Blurring without choosing anything RESTORES the draft's label**, so the
///    clear is an editing affordance and never a silent erasure. The draft is the
///    truth (MYR-389); the field is its mirror, and a mirror that empties itself
///    because somebody looked at it is the same lie in the other direction.
///
/// ⚠️ **THE DESTINATION FIELD IS DELIBERATELY UNTOUCHED.** Its empty state is a
/// real, MUTED `TextField("Where to?")` placeholder, which no rider has ever
/// reported as a value and which the system already hides on the first keystroke.
/// Applying a clear-on-focus there would change a field nobody complained about
/// and move MYR-215's chosen-destination CTA state on every tap.
enum RidePickupFieldFocus {

    /// The field's text the moment it GAINS first responder. A field holding a
    /// committed pickup empties so the next keystroke starts a new search; an
    /// already-empty field is unchanged (there is nothing to replace, and
    /// returning a fresh empty string would still be a no-op).
    static func textOnFocusGained(current: String) -> String { "" }

    /// The field's text the moment it LOSES first responder without a choice
    /// having been made. An empty field re-adopts the draft's label — the mirror
    /// re-seeding itself, exactly as arrival does (MYR-389) — and a field the
    /// rider left mid-typing keeps what they typed, because a query in flight is
    /// theirs and not ours to discard.
    static func textOnFocusLost(current: String, draftLabel: String?) -> String {
        guard current.isEmpty else { return current }
        return draftLabel ?? ""
    }

    /// Whether the "Current location" default is drawn over the field. Never
    /// while focused — that is the whole of defect 1 — and never over text.
    static func showsDefaultOverlay(text: String, isFocused: Bool) -> Bool {
        !isFocused && text.isEmpty
    }

    /// Whether the clear (`xmark`) affordance is offered. It is the one control
    /// that expresses "Current location" as an explicit CHOICE rather than as a
    /// default, so it must survive the focus clear above: a rider who taps into
    /// the field to change a set pickup, then decides they want their own feet
    /// after all, has to still have it. An untouched search (no draft, no text)
    /// offers nothing, exactly as before MYR-445.
    static func showsClearAffordance(text: String, hasDraftPickup: Bool) -> Bool {
        !text.isEmpty || hasDraftPickup
    }
}

/// MYR-445 defect 4 — the coordinate the route PREVIEW is keyed on.
///
/// This ladder shipped inline in `SharedViewerScreen.searchPreviewPickup`, where
/// it was correct and unassertable. It is the expression MYR-237's whole
/// anti-jitter story rests on and the one defect 4 is downstream of, so it is
/// stated once, here, and the screen CONSULTS it — the MYR-369
/// `VehicleRideShare.display` lesson, which is that a pure rule with good tests
/// and the wrong consumer is the quietest regression available.
///
/// **A LIVE GPS COORDINATE MUST NEVER REACH THIS.** The "current location" rung is
/// `previewPickupAnchor` — a fix WRITTEN once at a moment the rider chose
/// something, never a fix READ per frame. MYR-237's device trace is what happens
/// otherwise: every jitter re-keys the route cache and the etched line collapses
/// back to loading in a visible ~2s loop.
enum RidePreviewPickup {

    /// - Parameters:
    ///   - requestPickup: the SUBMITTED ride's own pickup, when one exists (nil on
    ///     `.search` by MYR-389's rule — a search is not about any ride but the one
    ///     being typed).
    ///   - draftPickup: the pin the rider confirmed.
    ///   - anchor: `previewPickupAnchor`, MYR-237's written-once fix.
    static func resolve(
        requestPickup: CLLocationCoordinate2D?,
        draftPickup: CLLocationCoordinate2D?,
        anchor: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        requestPickup ?? draftPickup ?? anchor
    }
}
