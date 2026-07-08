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
            // MYR-166 — map backdrop (design/app/components.jsx MapBackground)
            ("mapLand", 0x1B1D21, .mrtMapLand), // components.jsx:359
            ("mapPark", 0x18221A, .mrtMapPark), // components.jsx:369
            ("mapStreet", 0x26282D, .mrtMapStreet), // components.jsx:374
            ("mapCollectorCasing", 0x2E3138, .mrtMapCollectorCasing), // components.jsx:376
            ("mapCollectorFill", 0x3C4049, .mrtMapCollectorFill), // components.jsx:377
            ("mapFreewayCasing", 0x2A2519, .mrtMapFreewayCasing), // components.jsx:381
            ("mapFreewayFill", 0x4C4330, .mrtMapFreewayFill), // components.jsx:382
            ("mapWater", 0x0E1A26, .mrtMapWater), // components.jsx:385
            ("mapCoast", 0x16273A, .mrtMapCoast), // components.jsx:386
            // MYR-168 — Vehicle Controls (design/app/vehicle-controls.jsx)
            ("seatCool", 0x5AC8FA, .mrtSeatCool), // vehicle-controls.jsx:73 `SEAT_COOL`
            ("mediaTrack1Start", 0x2B3A67, .mrtMediaTrack1Start), // vehicle-controls.jsx:200
            ("mediaTrack2Start", 0x7B1E3B, .mrtMediaTrack2Start), // vehicle-controls.jsx:201
            ("mediaTrack2End", 0x1A1A2E, .mrtMediaTrack2End), // vehicle-controls.jsx:201
            ("mediaTrack3Start", 0x0F3443, .mrtMediaTrack3Start), // vehicle-controls.jsx:202
            ("mediaTrack3End", 0x34E89E, .mrtMediaTrack3End), // vehicle-controls.jsx:202
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
            // MYR-166 — tutorials (design/app/tutorials.jsx) — vignette shell
            ("vigCardBorder", 0.10, .mrtVigCardBorder), // tutorials.jsx:13
            ("vigRowFill", 0.05, .mrtVigRowFill), // tutorials.jsx:59
            ("vigRowBorder", 0.08, .mrtVigRowBorder), // tutorials.jsx:59
            ("vigControlFill", 0.06, .mrtVigControlFill), // tutorials.jsx:127
            ("vigControlBorder", 0.12, .mrtVigControlBorder), // tutorials.jsx:127
            ("vigTileOff", 0.04, .mrtVigTileOff), // tutorials.jsx:148
            ("goldTileFaint", 0.12, .mrtGoldTileFaint), // tutorials.jsx:60
            // MYR-166 — map backdrop labels (design/app/components.jsx MapBackground)
            ("mapLabelOcean", 0.36, .mrtMapLabelOcean), // components.jsx:389
            ("mapLabelPark", 0.4, .mrtMapLabelPark), // components.jsx:390
            ("mapLabelStreet", 0.26, .mrtMapLabelStreet), // components.jsx:391
            // MYR-167 — Live Map (design/app/screens.jsx MapHeader/FloatingMapButton)
            ("mapChipBorder", 0.14, .mrtMapChipBorder), // screens.jsx:308
            ("mapChipBorderActive", CGFloat(0x77) / 255.0, .mrtMapChipBorderActive), // screens.jsx:308
            ("mapChipChevronFill", 0.08, .mrtMapChipChevronFill), // screens.jsx:313
            ("mapPickerDivider", 0.07, .mrtMapPickerDivider), // screens.jsx:333
            ("mapPickerRowActive", CGFloat(0x14) / 255.0, .mrtMapPickerRowActive), // screens.jsx:332
            ("mapPickerIconActive", CGFloat(0x22) / 255.0, .mrtMapPickerIconActive), // screens.jsx:335
            ("mapPickerIconInactive", 0.06, .mrtMapPickerIconInactive), // screens.jsx:335
            ("mapCompassLabel", 0.25, .mrtMapCompassLabel), // components.jsx:407
            // MYR-168 — Vehicle Controls (design/app/vehicle-controls.jsx)
            ("controlTileFill", 0.035, .mrtControlTileFill), // vehicle-controls.jsx:30
            ("controlSegmentTrack", 0.05, .mrtControlSegmentTrack), // vehicle-controls.jsx:88,276,313
            ("controlSegmentOff", 0.07, .mrtControlSegmentOff), // vehicle-controls.jsx:64,115
            ("stepButtonFill", 0.06, .mrtStepButtonFill), // vehicle-controls.jsx:136,441
            ("sliderThumbShadow", 0.45, .mrtSliderThumbShadow), // components.jsx:769-770
            ("mediaCoverShadow", 0.35, .mrtMediaCoverShadow), // vehicle-controls.jsx:350
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
            // MYR-166 — tutorials (design/app/tutorials.jsx) — vignette shell
            ("vigCardTop", 0x222228, 0.9, .mrtVigCardTop), // rgba(34,34,40,0.9), tutorials.jsx:12
            ("vigCardBottom", 0x101014, 0.92, .mrtVigCardBottom), // rgba(16,16,20,0.92), tutorials.jsx:12
            ("vigStatusPill", 0x141418, 0.66, .mrtVigStatusPill), // rgba(20,20,24,0.66), tutorials.jsx:35
            // MYR-167 — Live Map chip/picker (design/app/screens.jsx MapHeader)
            ("mapChipFill", 0x141418, 0.72, .mrtMapChipFill), // rgba(20,20,24,0.72), screens.jsx:307
            ("mapPickerFill", 0x18181C, 0.92, .mrtMapPickerFill), // rgba(24,24,28,0.92), screens.jsx:324
            ("floatButtonFill", 0x111111, 0.85, .mrtFloatButtonFill), // rgba(17,17,17,0.85), design.jsx:95
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

    /// MYR-166 — StoryDeck layout constants (design/app/tutorials.jsx:11,320,327,342,345).
    func testTutorialMetrics() {
        XCTAssertEqual(MRTMetrics.vignetteRadius, 28)
        XCTAssertEqual(MRTMetrics.storyKickerTop, 84)
        XCTAssertEqual(MRTMetrics.storyKickerGutter, 26)
        XCTAssertEqual(MRTMetrics.storyContentTop, 128)
        XCTAssertEqual(MRTMetrics.storyContentBottom, 34)
        XCTAssertEqual(MRTMetrics.storyDotActiveWidth, 22)
        XCTAssertEqual(MRTMetrics.storyDotSize, 7)
        XCTAssertEqual(MRTMetrics.storyDotGap, 7)
    }

    /// MYR-167 — Live Map layout constants (design/app/screens.jsx:302,306,
    /// 323,400-401,424; vehicle-controls.jsx:24-41 for the placeholder;
    /// screens.jsx:542 for the sheet content bottom padding).
    func testLiveMapMetrics() {
        XCTAssertEqual(MRTMetrics.mapHeaderTop, 60)
        XCTAssertEqual(MRTMetrics.mapChipHeight, 40)
        XCTAssertEqual(MRTMetrics.mapPickerWidth, 250)
        XCTAssertEqual(MRTMetrics.homePeekHeightDriving, 280)
        XCTAssertEqual(MRTMetrics.homePeekHeightParked, 210)
        XCTAssertEqual(MRTMetrics.homeHalfHeightFraction, 0.58)
        XCTAssertEqual(MRTMetrics.mapButtonBottomGap, 80)
        XCTAssertEqual(MRTMetrics.homeControlsPlaceholderHeight, 84)
        XCTAssertEqual(MRTMetrics.homeSheetContentBottomPadding, 100)
    }

    /// MYR-168 — Vehicle Controls layout constants (design/app/
    /// vehicle-controls.jsx:28,46,51; components.jsx:769-770).
    func testVehicleControlsMetrics() {
        XCTAssertEqual(MRTMetrics.vehicleControlTileRadius, 16)
        XCTAssertEqual(MRTMetrics.vehicleControlsSectionRadius, 18)
        XCTAssertEqual(MRTMetrics.vehicleControlsSectionGap, 18)
        XCTAssertEqual(MRTMetrics.sliderThumbSize, 22)
    }

    func testTypeScaleClamps() {
        XCTAssertEqual(MRTTextStyle.heroNumber(size: 60).size, 40)
        XCTAssertEqual(MRTTextStyle.heroNumber(size: 10).size, 28)
        XCTAssertEqual(MRTTextStyle.label(size: 20).size, 12)
        XCTAssertEqual(MRTTextStyle.screenTitle.tracking, -0.6)
        XCTAssertEqual(MRTTextStyle.label().tracking, 1.2)
    }
}
