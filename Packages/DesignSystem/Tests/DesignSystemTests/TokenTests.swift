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

    /// MYR-169 — Drives / Drive Summary layout constants (design/app/
    /// screens.jsx:631,635,637,639,754,764,873,890,893,995).
    func testDrivesMetrics() {
        XCTAssertEqual(MRTMetrics.drivesHeaderTop, 74)
        XCTAssertEqual(MRTMetrics.drivesContentBottomPadding, 104)
        XCTAssertEqual(MRTMetrics.drivesSegmentRadius, 12)
        XCTAssertEqual(MRTMetrics.drivesSegmentItemRadius, 9)
        XCTAssertEqual(MRTMetrics.upcomingIconTileSize, 38)
        XCTAssertEqual(MRTMetrics.upcomingCancelButtonSize, 28)
        XCTAssertEqual(MRTMetrics.driveSummaryHeroHeight, 268)
        XCTAssertEqual(MRTMetrics.driveSummaryFloatingButtonSize, 38)
        XCTAssertEqual(MRTMetrics.driveSummaryTileRadius, 18)
    }

    /// MYR-169 — new raw hex colors (literal off-whites, not alpha
    /// compositions of an existing base — see Tokens.swift `Hex` comment).
    func testDrivesHexRoundTrip() {
        let cases: [(name: String, hex: UInt32, color: Color)] = [
            ("goldRowText", 0xF4EFE2, .mrtGoldRowText), // screens.jsx:758,785
            ("drivingRowText", 0xEAF6EC, .mrtDrivingRowText), // screens.jsx:662
            ("dsShareCardPanelTop", 0x14120C, .mrtDsShareCardPanelTop), // screens.jsx:1208
            ("dsShareCardPanelBottom", 0x0F0E0A, .mrtDsShareCardPanelBottom), // screens.jsx:1208
            ("confettiPale", 0xFFE9A8, .mrtConfettiPale), // screens.jsx:1079 COLORS[4]
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

    /// MYR-169 — Drives / Drive Summary alpha compositions (design/app/
    /// screens.jsx 637-1113).
    func testDrivesTintAlphas() {
        let cases: [(name: String, alpha: CGFloat, color: Color)] = [
            ("drivesSegmentTrack", 0.05, .mrtDrivesSegmentTrack), // screens.jsx:637
            ("drivesSortChipActive", CGFloat(0x22) / 255.0, .mrtDrivesSortChipActive), // screens.jsx:683
            ("goldRowTintStart", 0.10, .mrtGoldRowTintStart), // screens.jsx:750,778
            ("goldRowTintMid", 0.03, .mrtGoldRowTintMid), // screens.jsx:750,778
            ("rowTintFaint", 0.018, .mrtRowTintFaint), // screens.jsx:654,750,778
            ("goldRowBorder", 0.20, .mrtGoldRowBorder), // screens.jsx:751,779
            ("drivingRowTintStart", 0.14, .mrtDrivingRowTintStart), // screens.jsx:654
            ("drivingRowTintMid", 0.04, .mrtDrivingRowTintMid), // screens.jsx:654
            ("drivingRowBorder", 0.34, .mrtDrivingRowBorder), // screens.jsx:655
            ("goldTimeLabel", 0.65, .mrtGoldTimeLabel), // screens.jsx:788
            ("upcomingIconFill", 0.16, .mrtUpcomingIconFill), // screens.jsx:754
            ("upcomingIconBorder", 0.28, .mrtUpcomingIconBorder), // screens.jsx:754
            ("drivesCancelButtonFill", 0.06, .mrtDrivesCancelButtonFill), // screens.jsx:764
            ("drivesEmptyIconFill", 0.04, .mrtDrivesEmptyIconFill), // screens.jsx:703
            ("dsTileTintStart", 0.06, .mrtDsTileTintStart), // screens.jsx:993
            ("dsTileTintEnd", 0.025, .mrtDsTileTintEnd), // screens.jsx:993
            ("dsTileBorder", 0.09, .mrtDsTileBorder), // screens.jsx:994
            ("dsScrimTop", 0.62, .mrtDsScrimTop), // screens.jsx:882
            ("dsScrimBottomMid", 0.7, .mrtDsScrimBottomMid), // screens.jsx:883
            ("dsFloatingNavFill", 0.5, .mrtDsFloatingNavFill), // screens.jsx:890,893
            ("goldRowChevron", 0.55, .mrtGoldRowChevron), // screens.jsx:794
            ("drivingRowChevron", 0.6, .mrtDrivingRowChevron), // screens.jsx:671
            ("dsShareCardBorder", 0.3, .mrtDsShareCardBorder), // screens.jsx:1194
            ("dsShareCardPillFill", 0.14, .mrtDsShareCardPillFill), // screens.jsx:1216
            ("dsShareCardScrimStart", 0.2, .mrtDsShareCardScrimStart), // screens.jsx:1202
            ("dsShareCardScrimEnd", 0.7, .mrtDsShareCardScrimEnd), // screens.jsx:1202
            ("dsShareCardOuterRing", 0.06, .mrtDsShareCardOuterRing), // screens.jsx:1194
        ]
        for (name, alpha, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), name)
            XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name): alpha")
        }
    }

    /// `DriveShareCard` layout constants (design/app/screens.jsx:1194-1196).
    func testShareCardMetrics() {
        XCTAssertEqual(MRTMetrics.shareCardWidth, 362)
        XCTAssertEqual(MRTMetrics.shareCardMapHeight, 132)
        XCTAssertEqual(MRTMetrics.shareCardRadius, 20)
    }

    /// MYR-170 — `MRTToggle` layout constants (design/app/components.jsx
    /// `Toggle` 254-272).
    func testToggleMetrics() {
        XCTAssertEqual(MRTMetrics.toggleTrackWidth, 51)
        XCTAssertEqual(MRTMetrics.toggleTrackHeight, 31)
        XCTAssertEqual(MRTMetrics.toggleTrackRadius, 16)
        XCTAssertEqual(MRTMetrics.toggleThumbSize, 27)
        XCTAssertEqual(MRTMetrics.toggleThumbInset, 2)
    }

    /// MYR-170 — Owner Share/Settings + Rider Settings share the same
    /// physical header/content-clearance offsets as Drives (design/app/
    /// screens.jsx:97,398; shared-screens.jsx:694, all `74px …`).
    func testShareSettingsMetrics() {
        XCTAssertEqual(MRTMetrics.shareHeaderTop, 74)
        XCTAssertEqual(MRTMetrics.shareContentBottomPadding, 104)
    }

    /// MYR-170 — the one new raw hex introduced (shared-screens.jsx:468).
    func testShareSettingsHexRoundTrip() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(Color.mrtRiderAvatarGradientEnd).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(UInt32(round(r * 255)), 0x8A)
        XCTAssertEqual(UInt32(round(g * 255)), 0x6F)
        XCTAssertEqual(UInt32(round(b * 255)), 0x28)
        XCTAssertEqual(a, 1.0, accuracy: 0.001)
    }

    /// MYR-170 — new alpha-composed tokens (design/app/screens.jsx
    /// 1246-1834, shared-screens.jsx 444-557, components.jsx Toggle).
    func testShareSettingsTintAlphas() {
        let cases: [(name: String, alpha: CGFloat, color: Color)] = [
            ("toggleThumbShadow", 0.3, .mrtToggleThumbShadow), // components.jsx ~264
            ("inviteVehicleTint", CGFloat(0x1A) / 255.0, .mrtInviteVehicleTint), // screens.jsx:1363
            ("inviteVehicleBorder", CGFloat(0x88) / 255.0, .mrtInviteVehicleBorder), // screens.jsx:1363
            ("inviteAccessTintLight", CGFloat(0x14) / 255.0, .mrtInviteAccessTintLight), // screens.jsx:1385
            ("inviteAccessBorder", CGFloat(0x77) / 255.0, .mrtInviteAccessBorder), // screens.jsx:1385
            ("inviteAccessIconFill", CGFloat(0x22) / 255.0, .mrtInviteAccessIconFill), // screens.jsx:1386
            ("inviteSpinnerTrack", CGFloat(0x33) / 255.0, .mrtInviteSpinnerTrack), // screens.jsx:1423
            ("goldBadgeFill", CGFloat(0x1F) / 255.0, .mrtGoldBadgeFill), // screens.jsx:1610,1727
            ("primaryButtonBorder", CGFloat(0x66) / 255.0, .mrtPrimaryButtonBorder), // screens.jsx:1748
        ]
        for (name, alpha, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), name)
            XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name): alpha")
        }
    }

    /// MYR-191 — SharedViewerScreen idle sheet + ScheduledRideSheet map
    /// preview (design/app/screens.jsx:2078; shared-screens.jsx:352).
    func testRiderShellMetrics() {
        XCTAssertEqual(MRTMetrics.sharedIdleSheetHeight, 286)
        XCTAssertEqual(MRTMetrics.rideMapPreviewHeight, 104)
        XCTAssertEqual(MRTMetrics.modalRadius, 28)
    }

    /// MYR-191 — the two new raw hexes introduced (shared-screens.jsx:136;
    /// design/app/design.jsx:74).
    func testRiderShellHexRoundTrip() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(Color.mrtRequestedRowText).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(UInt32(round(r * 255)), 0xF2)
        XCTAssertEqual(UInt32(round(g * 255)), 0xF2)
        XCTAssertEqual(UInt32(round(b * 255)), 0xF2)
        XCTAssertEqual(a, 1.0, accuracy: 0.001)

        XCTAssertTrue(UIColor(Color.mrtRideSheetFill).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(UInt32(round(r * 255)), 0x14)
        XCTAssertEqual(UInt32(round(g * 255)), 0x14)
        XCTAssertEqual(UInt32(round(b * 255)), 0x16)
        XCTAssertEqual(a, 0.96, accuracy: 0.001)
    }

    /// MYR-191 — new alpha-composed tokens (design/app/shared-screens.jsx
    /// 1-436, ride-request.jsx ExpandingRequestSheet 1071-1261).
    func testRiderShellTintAlphas() {
        let cases: [(name: String, alpha: CGFloat, color: Color)] = [
            ("requestedRowTintStart", 0.05, .mrtRequestedRowTintStart), // shared-screens.jsx:130
            ("requestedRowTintMid", 0.022, .mrtRequestedRowTintMid), // shared-screens.jsx:130
            ("requestedRowTintEnd", 0.012, .mrtRequestedRowTintEnd), // shared-screens.jsx:130
            ("requestedRowBorder", 0.09, .mrtRequestedRowBorder), // shared-screens.jsx:131
            ("rideConfirmedChipFill", 0.16, .mrtRideConfirmedChipFill), // shared-screens.jsx:191
            ("ridePendingChipFill", 0.07, .mrtRidePendingChipFill), // shared-screens.jsx:191
            ("rideForTagFill", CGFloat(0x1A) / 255.0, .mrtRideForTagFill), // shared-screens.jsx:28
            ("rideChipFill", 0.04, .mrtRideChipFill), // shared-screens.jsx:289,302
            ("rideCancelButtonBorder", 0.40, .mrtRideCancelButtonBorder), // shared-screens.jsx:271
            ("rideMapScrim", 0.92, .mrtRideMapScrim), // shared-screens.jsx:359
            ("goldSheetHairline", CGFloat(0x2E) / 255.0, .mrtGoldSheetHairline), // ride-request.jsx:1181
            ("searchGlow", 0.16, .mrtSearchGlow), // components.jsx:676
        ]
        for (name, alpha, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), name)
            XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name): alpha")
        }
    }

    /// MYR-171 — the one new raw hex introduced (ride-request.jsx:647).
    func testRideRequestHexRoundTrip() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(Color.mrtSendFillTrack).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(UInt32(round(r * 255)), 0x3A)
        XCTAssertEqual(UInt32(round(g * 255)), 0x2F)
        XCTAssertEqual(UInt32(round(b * 255)), 0x12)
        XCTAssertEqual(a, 1.0, accuracy: 0.001)
    }

    /// MYR-171 — `IncomingRequestSheet`'s requester-avatar gradient, the
    /// other new raw hex pair introduced (ride-request.jsx:1307).
    func testRideRequestAvatarGradientHexRoundTrip() {
        let cases: [(name: String, hex: UInt32, color: Color)] = [
            ("requesterAvatarStart", 0x6D8EFF, .mrtRequesterAvatarStart),
            ("requesterAvatarEnd", 0x9D7CFF, .mrtRequesterAvatarEnd),
        ]
        for (name, hex, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), name)
            XCTAssertEqual(UInt32(round(r * 255)), (hex >> 16) & 0xFF, "\(name): red")
            XCTAssertEqual(UInt32(round(g * 255)), (hex >> 8) & 0xFF, "\(name): green")
            XCTAssertEqual(UInt32(round(b * 255)), hex & 0xFF, "\(name): blue")
            XCTAssertEqual(a, 1.0, accuracy: 0.001, "\(name): alpha")
        }
    }

    /// MYR-197 — `OutcomeContent`'s accepted checkmark-circle radial
    /// gradient's dark stop, the one new raw hex introduced
    /// (ride-request.jsx:678 `#1a8a3f`).
    func testOutcomeCardHexRoundTrip() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(Color.mrtDrivingDeep).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(UInt32(round(r * 255)), 0x1A)
        XCTAssertEqual(UInt32(round(g * 255)), 0x8A)
        XCTAssertEqual(UInt32(round(b * 255)), 0x3F)
        XCTAssertEqual(a, 1.0, accuracy: 0.001)
    }

    /// MYR-171 — new alpha-composed tokens (design/app/ride-request.jsx
    /// ExpandingRequestSheet/IncomingRequestSheet/RouteSentToast).
    func testRideRequestTintAlphas() {
        let cases: [(name: String, alpha: CGFloat, color: Color)] = [
            ("requestCardFill", 0.035, .mrtRequestCardFill),
            ("plateChipFill", CGFloat(0x1F) / 255.0, .mrtPlateChipFill),
            ("tripLegTrack", 0.10, .mrtTripLegTrack),
        ]
        for (name, alpha, color) in cases {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a), name)
            XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name): alpha")
        }
    }

    /// MYR-171 — `IncomingRequestSheet`/`RouteSentToast` layout constants.
    func testRideRequestMetrics() {
        XCTAssertEqual(MRTMetrics.incomingRequestMapHeight, 132)
        XCTAssertEqual(MRTMetrics.routeSentToastTop, 56)
        XCTAssertEqual(MRTMetrics.rideRequestSearchSheetHeight, 712)
        XCTAssertEqual(MRTMetrics.rideRequestPinDropMapInset, 280)
    }
}
