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
            ("borderSubtle", 0x181818, .mrtBorderSubtle),
            ("offline", 0x6B6B6B, .mrtOffline),
            // MYR-162 — buttons + overlays
            ("goldButtonLabel", 0x1A1408, .mrtGoldButtonLabel),
            ("goldDeepButtonLabel", 0x1C1505, .mrtGoldDeepButtonLabel),
            ("goldTrace", 0xE7C975, .mrtGoldTrace),
            ("goldTraceBright", 0xFFF3C8, .mrtGoldTraceBright),
            ("goldPulse", 0xF0D27A, .mrtGoldPulse),
            ("dialogCard", 0x1A1A1C, .mrtDialogCard),
            ("toastSurface", 0x22221F, .mrtToastSurface),
            // MYR-163 — brand mark
            ("arrowFacetLight", 0xE4D08A, .mrtArrowFacetLight),
            ("arrowFacetDark", 0x9C7E2C, .mrtArrowFacetDark),
            ("logoTileTop", 0x1B1407, .mrtLogoTileTop),
            ("logoTileMid", 0x0D0B06, .mrtLogoTileMid),
            ("logoTileBottom", 0x090806, .mrtLogoTileBottom),
            // MYR-164 — sign in
            ("glimpseCream", 0xD0C9B8, .mrtGlimpseCream), // screens.jsx ParticleLine '208,201,184'
            // MYR-165 — onboarding (design/app/onboarding.jsx)
            ("keyCardMid", 0x0D0D0D, .mrtKeyCardMid), // jsx:274
            ("keyCardDeep", 0x050505, .mrtKeyCardDeep), // jsx:274
            ("etchLight", 0xF5ECC8, .mrtEtchLight), // jsx:286
            ("etchDark", 0x8A6E23, .mrtEtchDark), // jsx:286
            ("linkedGreenLight", 0x3EE06A, .mrtLinkedGreenLight), // jsx:333
            ("linkedCheckStroke", 0x0A2912, .mrtLinkedCheckStroke), // jsx:337
            // MYR-165 — simulated Tesla OAuth sheet (onboarding.jsx InAppBrowser)
            ("teslaRed", 0xE82127, .mrtTeslaRed), // jsx:116
            ("browserBg", 0xF2F2F4, .mrtBrowserBg), // jsx:91
            ("browserChrome", 0xE8E8EC, .mrtBrowserChrome), // jsx:96
            ("browserText", 0x1C1C1E, .mrtBrowserText), // jsx:101
            ("browserTextSec", 0x6B6B70, .mrtBrowserTextSec), // jsx:122
            ("browserTextTert", 0x8A8A8F, .mrtBrowserTextTert), // jsx:164
            ("browserTextFaint", 0xA0A0A5, .mrtBrowserTextFaint), // jsx:173
            ("browserArrow", 0xB0B0B5, .mrtBrowserArrow), // jsx:145
            ("browserSpinner", 0x8E8E93, .mrtBrowserSpinner), // jsx:105
            ("browserGlyph", 0x3A3A3C, .mrtBrowserGlyph), // jsx:102
            ("linkBlue", 0x0A84FF, .mrtLinkBlue), // jsx:99
            ("consentGreen", 0x34A853, .mrtConsentGreen), // jsx:166
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

    /// The alpha-composed tints introduced for MYR-162 (button chrome +
    /// dialog fills + scrim) carry the exact rgba() alphas from the design.
    func testComponentTintAlphas() {
        let cases: [(name: String, alpha: CGFloat, color: Color)] = [
            ("goldFillFaint", 0.06, .mrtGoldFillFaint),
            ("goldBorderFaint", 0.22, .mrtGoldBorderFaint),
            ("goldBorderSoft", CGFloat(0x55) / 255.0, .mrtGoldBorderSoft),
            ("goldGlowFaint", 0.14, .mrtGoldGlowFaint),
            ("goldFillSoft", 0.14, .mrtGoldFillSoft),
            ("dangerFill", 0.16, .mrtDangerFill),
            ("dangerFillSoft", 0.14, .mrtDangerFillSoft),
            ("scrim", 0.6, .mrtScrim),
            ("scrimSoft", 0.5, .mrtScrimSoft), // MYR-164 — screens.jsx SignInScreen scrim rgba(0,0,0,0.5)
            // MYR-165 — onboarding tints (design/app/onboarding.jsx + screens.jsx EmptyScreen)
            ("goldDeepActiveFill", 0.18, .mrtGoldDeepActiveFill), // onboarding.jsx:41
            ("goldDeepHalo", 0.12, .mrtGoldDeepHalo), // onboarding.jsx:43
            ("goldRing", CGFloat(0x44) / 255.0, .mrtGoldRing), // onboarding.jsx:240
            ("goldCardBorder", CGFloat(0x3A) / 255.0, .mrtGoldCardBorder), // onboarding.jsx:374
            ("goldCellFill", 0.10, .mrtGoldCellFill), // onboarding.jsx:460
            ("goldCellBorder", CGFloat(0x66) / 255.0, .mrtGoldCellBorder), // onboarding.jsx:461
            ("goldFocusRing", 0.12, .mrtGoldFocusRing), // onboarding.jsx:462
            ("goldCardTint", CGFloat(0x1C) / 255.0, .mrtGoldCardTint), // screens.jsx:272
            ("goldCardTintFaint", CGFloat(0x0A) / 255.0, .mrtGoldCardTintFaint), // screens.jsx:272
            ("goldIconTile", CGFloat(0x26) / 255.0, .mrtGoldIconTile), // screens.jsx:276
            ("goldBorderQuiet", CGFloat(0x2E) / 255.0, .mrtGoldBorderQuiet), // screens.jsx:273
        ]
        for (name, alpha, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), name)
            XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name): alpha")
        }
    }

    /// Bottom-nav colors carry their alpha baked in — verify RGB + alpha.
    func testNavColorComponents() {
        let cases: [(name: String, hex: UInt32, alpha: CGFloat, color: Color)] = [
            ("navBarFill", 0x161619, 0.92, .mrtNavBarFill), // rgba(22,22,25,0.92)
            ("navHairline", 0xFFFFFF, 0.09, .mrtNavHairline), // rgba(255,255,255,0.09)
            ("navInactive", 0xC4AC6C, 0.62, .mrtNavInactive), // rgba(196,172,108,0.62)
        ]
        for (name, hex, alpha, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a),
                "\(name): not convertible to RGBA"
            )
            XCTAssertEqual(UInt32(round(r * 255)), (hex >> 16) & 0xFF, "\(name): red")
            XCTAssertEqual(UInt32(round(g * 255)), (hex >> 8) & 0xFF, "\(name): green")
            XCTAssertEqual(UInt32(round(b * 255)), hex & 0xFF, "\(name): blue")
            XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name): alpha")
        }
    }

    func testLookRadii() {
        XCTAssertEqual(MRTSurfaceLook.flat.cardRadius, 14)
        XCTAssertEqual(MRTSurfaceLook.liquidGlass.cardRadius, 16)
        XCTAssertEqual(MRTSurfaceLook.flat.sheetRadius, 24)
        XCTAssertEqual(MRTSurfaceLook.liquidGlass.sheetRadius, 30)
        XCTAssertEqual(MRTMetrics.minTapTarget, 44)
    }

    /// MYR-164 — sign-in sheet Apple button (screens.jsx SignInScreen:
    /// height 54, borderRadius 14).
    func testSignInMetrics() {
        XCTAssertEqual(MRTMetrics.appleButtonHeight, 54)
        XCTAssertEqual(MRTMetrics.appleButtonRadius, 14)
    }

    /// MYR-165 — onboarding layout constants (design/app/onboarding.jsx:19,32
    /// and the flows' `padding…: 30`).
    func testOnboardingMetrics() {
        XCTAssertEqual(MRTMetrics.pairStepperTop, 124)
        XCTAssertEqual(MRTMetrics.pairStepperGutter, 28)
        XCTAssertEqual(MRTMetrics.onboardingGutter, 30)
        XCTAssertEqual(MRTMetrics.onboardingTopActionTop, 82)
    }

    /// MYR-165 — the stepper ships the prototype's exact four labels
    /// (onboarding.jsx:30).
    func testPairStepperLabels() {
        XCTAssertEqual(PairStepper.defaultSteps, ["Sign in", "Linked", "Virtual key", "Paired"])
    }

    func testTypeScaleClamps() {
        XCTAssertEqual(MRTTextStyle.heroNumber(size: 60).size, 40)
        XCTAssertEqual(MRTTextStyle.heroNumber(size: 10).size, 28)
        XCTAssertEqual(MRTTextStyle.label(size: 20).size, 12)
        XCTAssertEqual(MRTTextStyle.screenTitle.tracking, -0.6)
        XCTAssertEqual(MRTTextStyle.label().tracking, 1.2)
    }
}
