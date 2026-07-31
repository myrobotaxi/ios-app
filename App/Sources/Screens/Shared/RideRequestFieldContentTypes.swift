#if canImport(UIKit)
import UIKit
#endif

// MARK: - MYR-363a — the destination field suggests codes from Messages
//
// THE CLIENT'S REPORT: the ride-request destination search field's QuickType bar
// offers iOS's **one-time-code** suggestion ("From Messages"), over a field whose
// only job is to accept a place.
//
// THE CAUSE IS AN ABSENCE, NOT A LEAK. Grepped across the whole app before this
// file existed, `textContentType` appeared **zero** times — not on the destination
// field, not on the passenger name/phone fields, and not on `InviteCodeFlow`'s
// hidden six-character field either (it declares only `.asciiCapable` +
// `autocorrectionDisabled`). So nothing was inherited from anywhere: the
// destination field simply never told iOS what it holds, and UIKit's heuristics
// classify an unadorned single-line field as a plausible code target whenever a
// message carrying a code is in range. **A field with no declared content type is
// not neutral — it is a field the OS gets to guess about**, and the guess is worst
// exactly where the field is most generic.
//
// The fix is to say what each field is. Kept as named constants rather than three
// modifiers buried in a 1200-line view so the choices are visible in one place and
// `RideRequestFieldContentTypesTests` can pin them — a modifier is not assertable,
// a constant is.
//
// WHY `.fullStreetAddress` for the destination: it is the one type whose autofill
// vocabulary is the same vocabulary the field accepts. `.none` would equally
// suppress the code suggestion, but it also refuses the rider their own saved
// addresses, and it states "this field holds nothing in particular" — which is the
// condition that produced the defect. `.location` is the near miss: iOS reads it as
// a place NAME (a city, a region), so it offers no street addresses at all, and
// this field's own subtitle line is an address.
//
// MYR-382 — THE PASSENGER PAIR IS GONE WITH ITS FIELDS. The "Someone else" flow
// was removed from the rider's booking surface (client-directed — see
// `RideRequestSearchContent`'s "Passenger — REMOVED" note), so the two constants
// that declared its name/number fields have no fields left to declare. They are
// DELETED rather than left standing: a content type with no text field is a
// perfectly-tested value with zero call sites, which MYR-369 records as the
// quietest kind of regression there is. `all` therefore now names exactly the one
// field the flow has, and the `.oneTimeCode` guard is still over the whole set.

#if canImport(UIKit)
/// The declared content type of every text field in the rider's request flow.
/// After MYR-382 that is exactly ONE field — the destination search field — so
/// this enum is still exhaustive rather than a sample.
enum RideRequestFieldContentType {
    /// The Search sheet's "Where to?" destination field.
    static let destination: UITextContentType = .fullStreetAddress

    /// The types this flow declares. Asserted to exclude `.oneTimeCode` — the
    /// suggestion the client saw — so no future field in the flow can reintroduce
    /// it by copy-paste.
    static let all: [UITextContentType] = [destination]
}
#endif
