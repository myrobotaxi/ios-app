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
// The passenger fields are audited in the same pass and were unset for the same
// reason. `.telephoneNumber` also earns the phone field the number pad's autofill
// row, which `.phonePad` alone never provided.

#if canImport(UIKit)
/// The declared content type of every text field in the rider's request flow.
/// These four ARE the flow's text fields — the destination search field and the
/// passenger name/number pair (MYR-353 enumerates the same set for the keyboard
/// rule), so this enum is exhaustive rather than a sample.
enum RideRequestFieldContentType {
    /// The Search sheet's "Where to?" destination field.
    static let destination: UITextContentType = .fullStreetAddress
    /// The "Someone else" passenger's name.
    static let passengerName: UITextContentType = .name
    /// The "Someone else" passenger's mobile number.
    static let passengerPhone: UITextContentType = .telephoneNumber

    /// The types this flow declares. Asserted to exclude `.oneTimeCode` — the
    /// suggestion the client saw — so no future field in the flow can reintroduce
    /// it by copy-paste.
    static let all: [UITextContentType] = [destination, passengerName, passengerPhone]
}
#endif
