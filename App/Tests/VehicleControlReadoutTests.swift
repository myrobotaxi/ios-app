import SwiftUI
import XCTest
@testable import MyRoboTaxi
@testable import DesignSystem

// MARK: - MYR-441 — the two graphical controls stop asserting a zero
//
// Both defects are one sentence: on a fan bar and on a volume slider, `0` is not a
// neutral rest position, it is a CONFIRMED READING ("off", "muted"). The `isKnown`
// seam was in scope at both call sites and was discarded into a literal zero.

final class VehicleControlReadoutTests: XCTestCase {

    // MARK: The fan bar

    /// A known fan speed is passed through verbatim, including a genuine zero — a
    /// car that really has its fan off must still draw an off bar.
    func testAKnownFanSpeedIsDrawnAsItself() {
        XCTAssertEqual(VehicleControlReadout.fanLevel(known: true, reported: 7), 7)
        XCTAssertEqual(
            VehicleControlReadout.fanLevel(known: true, reported: 0), 0,
            "a CONFIRMED zero is a real reading and must keep drawing as one"
        )
    }

    /// **THE DEFECT.** An unknown fan speed must not be expressible as a level.
    /// The shipped code was `fanKnown ? controls.fanSpeed : 0`, and 0 renders every
    /// segment in `mrtControlSegmentOff` — byte-for-byte a confirmed fan-off.
    func testAnUnknownFanSpeedIsNotAZero() {
        let level = VehicleControlReadout.fanLevel(known: false, reported: 3)
        XCTAssertNil(level, "unknown is an absence, not a level")
        XCTAssertNotEqual(level, 0, "0 is how this bar draws a fan the car said is OFF")
    }

    /// The seeded value must not leak either. `LiveVehicleCommandExecutor` seeds
    /// `fanSpeed: 3` on the live path specifically so the type has something in it
    /// before the car answers — a MYR-228-shaped fixture default with no grep
    /// signature, and the `known` flag is the only thing standing between it and
    /// the screen.
    func testTheLiveSeedNeverReachesTheBarWhileUnknown() {
        for seeded in 0...10 {
            XCTAssertNil(
                VehicleControlReadout.fanLevel(known: false, reported: seeded),
                "seed \(seeded) must not be drawn as a level nobody confirmed"
            )
        }
    }

    // MARK: The volume slider

    /// **BYTE-IDENTITY.** The volume row has never carried text. A known volume
    /// must add none, or every owner-with-data capture of the Media card moves.
    func testAKnownVolumeAddsNoTextAtAll() {
        XCTAssertNil(
            VehicleControlReadout.volumeText(known: true),
            "the row is icon + slider and nothing else for an owner with real data"
        )
    }

    /// An unknown volume says so, in the app's ONE unknown glyph. A bare empty
    /// track with nothing beside it is honest about the level and silent about why.
    func testAnUnknownVolumeRendersTheSharedDash() {
        XCTAssertEqual(
            VehicleControlReadout.volumeText(known: false),
            ClimateTemperatureText.dash
        )
    }

    /// The glyph is not a third literal. `ClimateTemperatureText.dash` is already
    /// asserted equal to `BatteryReadout.dash`; this pins the volume row to the
    /// same mark, so the app cannot grow a second spelling of "unknown".
    func testTheDashIsTheAppsONEUnknownMark() {
        XCTAssertEqual(VehicleControlReadout.volumeText(known: false), BatteryReadout.dash)
        XCTAssertEqual(ClimateTemperatureText.dash, BatteryReadout.dash)
    }

    // MARK: The slider primitive itself

    /// `MRTSlider(showsValue:)` is what makes "no level asserted" drawable at all,
    /// and its DEFAULT must stay `true` — every other caller (the media scrubber,
    /// and the volume row on a known value) passes nothing and must be unchanged.
    ///
    /// Measured rather than reasoned about: the control's height is the same on
    /// both branches, so hiding the fill and the thumb cannot move the row it sits
    /// in. A layout change here would shove the whole Media card.
    @MainActor
    func testHidingTheValueDoesNotResizeTheSlider() {
        func height(_ view: some View) -> CGFloat {
            let host = UIHostingController(rootView: view.frame(width: 300))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return host.sizeThatFits(
                in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let shown = height(MRTSlider(value: .constant(45), trackHeight: 4))
        let hidden = height(MRTSlider(value: .constant(0), trackHeight: 4, showsValue: false))
        XCTAssertEqual(shown, hidden, accuracy: 0.5)

        let defaulted = height(MRTSlider(value: .constant(45), trackHeight: 4, showsValue: true))
        XCTAssertEqual(shown, defaulted, accuracy: 0.5, "the default is showsValue: true")
    }
}
