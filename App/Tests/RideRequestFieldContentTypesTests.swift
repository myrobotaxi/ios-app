import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import MyRoboTaxi

// MARK: - MYR-363a — the destination field says what it holds
//
// FAILING-FIRST: `RideRequestFieldContentType` did not exist on origin/main
// (7faf34b), and neither did a single `textContentType` anywhere in `App/` or
// `Packages/` — grepped, zero hits. Every assertion below was unreachable.
//
// A `.textContentType` modifier is not assertable from a test, and a UI test cannot
// read the QuickType bar's contents, so the guard is on the VALUES the view applies
// — the same "put the number in a token a test can assert on" rule MYR-339 states
// for `celebrationBlendMode`.

#if canImport(UIKit)
final class RideRequestFieldContentTypesTests: XCTestCase {

    /// The defect, stated directly: the destination field must not be a code field.
    func testNoFieldInTheRequestFlowDeclaresAOneTimeCode() {
        XCTAssertFalse(RideRequestFieldContentType.all.contains(.oneTimeCode))
    }

    /// …and none of them is left UNDECLARED either, which is the condition that
    /// actually produced the bug. An empty content type is a field iOS gets to guess
    /// about.
    func testEveryFieldInTheRequestFlowDeclaresSomething() {
        for type in RideRequestFieldContentType.all {
            XCTAssertFalse(type.rawValue.isEmpty)
        }
    }

    /// `.fullStreetAddress` over `.location`: the field's own subtitle line is an
    /// ADDRESS, and `.location` offers place names only.
    func testTheDestinationFieldIsAnAddressField() {
        XCTAssertEqual(RideRequestFieldContentType.destination, .fullStreetAddress)
    }

    func testThePassengerFieldsAreANameAndATelephoneNumber() {
        XCTAssertEqual(RideRequestFieldContentType.passengerName, .name)
        XCTAssertEqual(RideRequestFieldContentType.passengerPhone, .telephoneNumber)
    }

    /// Three fields, three distinct declarations — a copy-pasted modifier would show
    /// up here as a duplicate.
    func testTheThreeDeclarationsAreDistinct() {
        XCTAssertEqual(Set(RideRequestFieldContentType.all.map(\.rawValue)).count, 3)
    }
}
#endif
