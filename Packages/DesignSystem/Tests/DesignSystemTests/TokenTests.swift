import XCTest
import SwiftUI
@testable import DesignSystem

final class TokenTests: XCTestCase {
    /// Round-trips every hex through Color → UIColor and checks the sRGB
    /// components survive exactly.
    func testHexRoundTrip() {
        let cases: [(name: String, hex: UInt32, color: Color)] = [
            ("bg", 0x0A0A0A, .mrtBg),
            ("bgSecondary", 0x111111, .mrtBgSecondary),
            ("surface", 0x1A1A1A, .mrtSurface),
            ("surfaceHov", 0x222222, .mrtSurfaceHov),
            ("elevated", 0x2A2A2A, .mrtElevated),
            ("text", 0xFFFFFF, .mrtText),
            ("textSec", 0xA0A0A0, .mrtTextSec),
            ("textMuted", 0x6B6B6B, .mrtTextMuted),
            ("gold", 0xC9A84C, .mrtGold),
            ("goldLight", 0xD4C88A, .mrtGoldLight),
            ("goldDark", 0xA0862E, .mrtGoldDark),
            ("goldDeep", 0x8C6E2A, .mrtGoldDeep),
            ("goldDeepSoft", 0xB49A56, .mrtGoldDeepSoft),
            ("batHigh", 0x30D158, .mrtBatHigh),
            ("batMid", 0xFFD60A, .mrtBatMid),
            ("driving", 0x30D158, .mrtDriving),
            ("parked", 0x3B82F6, .mrtParked),
            ("charging", 0xFFD60A, .mrtCharging),
            ("batLow", 0xFF3B30, .mrtBatLow),
            ("dialogRed", 0xFF6B6B, .mrtDialogRed),
            ("border", 0x1F1F1F, .mrtBorder),
        ]

        for (name, hex, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a),
                "\(name): not convertible to RGBA"
            )
            XCTAssertEqual(UInt32(round(r * 255)), (hex >> 16) & 0xFF, "\(name): red")
            XCTAssertEqual(UInt32(round(g * 255)), (hex >> 8) & 0xFF, "\(name): green")
            XCTAssertEqual(UInt32(round(b * 255)), hex & 0xFF, "\(name): blue")
            XCTAssertEqual(a, 1.0, accuracy: 0.001, "\(name): alpha")
        }
    }

    func testGlowAlphas() {
        var a: CGFloat = 0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(Color.mrtGoldGlow).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(a, 0.6, accuracy: 0.001)
        UIColor(Color.mrtGoldGlowSoft).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(a, 0.3, accuracy: 0.001)
    }

    func testLookRadii() {
        XCTAssertEqual(SurfaceLook.flat.cardRadius, 14)
        XCTAssertEqual(SurfaceLook.liquidGlass.cardRadius, 16)
        XCTAssertEqual(SurfaceLook.flat.sheetRadius, 24)
        XCTAssertEqual(SurfaceLook.liquidGlass.sheetRadius, 30)
        XCTAssertEqual(MRTMetrics.minTapTarget, 44)
    }

    func testTypeScaleClamps() {
        XCTAssertEqual(MRTTextStyle.heroNumber(size: 60).size, 40)
        XCTAssertEqual(MRTTextStyle.heroNumber(size: 10).size, 28)
        XCTAssertEqual(MRTTextStyle.label(size: 20).size, 12)
        XCTAssertEqual(MRTTextStyle.screenTitle.tracking, -0.6)
        XCTAssertEqual(MRTTextStyle.label().tracking, 1.2)
    }
}
