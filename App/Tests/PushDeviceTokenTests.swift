import XCTest
@testable import MyRoboTaxi

/// APNs token hex-encoding (MYR-186).
///
/// The classic way to lose a whole round of on-device push testing is
/// `deviceToken.description`, which on iOS 13+ is `"{length = 32, bytes = 0x…}"`
/// — it registers cleanly, looks plausible in a log, and never delivers.
@MainActor
final class PushDeviceTokenTests: XCTestCase {

    func testEncodesEachByteAsTwoLowercaseHexCharacters() {
        let data = Data([0x00, 0x11, 0xab, 0xff])
        XCTAssertEqual(PushDeviceToken.hex(from: data), "0011abff")
    }

    /// Zero padding is the subtle one: a byte `0x0b` written as `"b"` shifts
    /// every character after it and yields a token APNs has never heard of.
    func testPadsSingleDigitBytesToTwoCharacters() {
        let data = Data([0x0b, 0x00, 0x0f, 0x01])
        XCTAssertEqual(PushDeviceToken.hex(from: data), "0b000f01")
    }

    func testProducesLowercaseOnly() {
        let hex = PushDeviceToken.hex(from: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(hex, "deadbeef")
        XCTAssertEqual(hex, hex.lowercased(), "the contract's token is lowercase hex")
    }

    /// A real APNs token is 32 bytes → 64 characters, with no separators and no
    /// `<`/`>` wrapper.
    func testRealSizedTokenIs64CharactersOfPureHex() {
        let data = Data((0..<32).map { UInt8($0) })
        let hex = PushDeviceToken.hex(from: data)
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit }, "no spaces, angle brackets, or separators")
    }

    /// Never produces the `Data.description` shape, whatever the input.
    func testNeverProducesTheDataDescriptionShape() {
        let hex = PushDeviceToken.hex(from: Data([0x01, 0x02, 0x03]))
        XCTAssertFalse(hex.contains("length"))
        XCTAssertFalse(hex.contains("{"))
        XCTAssertFalse(hex.contains("0x"))
    }

    func testEmptyDataProducesEmptyString() {
        XCTAssertEqual(PushDeviceToken.hex(from: Data()), "")
    }

    /// The `sandbox` flag is the BUILD's APNs environment, and these tests run in
    /// a DEBUG build — so it must report sandbox here. The inverse (a RELEASE /
    /// TestFlight build reporting production) is the half that cannot be asserted
    /// from a test target and is verified on-device instead.
    func testDebugBuildsReportSandbox() {
        #if DEBUG
        XCTAssertTrue(PushEnvironment.isSandbox, "DEBUG builds are signed aps-environment: development")
        #else
        XCTAssertFalse(PushEnvironment.isSandbox, "RELEASE builds (TestFlight/App Store) are production APNs")
        #endif
    }
}
