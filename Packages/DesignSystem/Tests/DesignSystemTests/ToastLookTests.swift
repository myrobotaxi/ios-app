import XCTest
import SwiftUI
@testable import DesignSystem

// MARK: - Toast looks (MYR-381)
//
// TestFlight r14: "Couldn't cancel that ride" rendered behind a GOLD CHECKMARK.
// The pill has been parameterized since MYR-220, so nothing was missing except a
// NAME for the other look — and an unnamed variant is one every call site has to
// spell from memory, which is how a failure came to wear the success glyph.
final class MRTToastLookTests: XCTestCase {

    func testTheFailureLookIsNotTheSuccessLook() {
        XCTAssertEqual(MRTToastLook.successImage, "checkmark", "every existing caller is unchanged")
        XCTAssertNotEqual(MRTToastLook.failureImage, MRTToastLook.successImage)
        XCTAssertNotEqual(MRTToastLook.failureTint, MRTToastLook.successTint)
    }

    /// A refusal may never be drawn with a confirmation glyph. Asserted on the
    /// SYMBOL NAME, because the symbol is where a reader takes the meaning from —
    /// the client read the ✓ before he read the sentence.
    func testAFailureToastCarriesNoCheckmark() {
        XCTAssertFalse(MRTToastLook.failureImage.contains("checkmark"))
        XCTAssertEqual(MRTToastLook.failureImage, "exclamationmark.circle.fill")
        XCTAssertEqual(MRTToastLook.failureTint, Color.mrtDialogRed)
    }
}
