import SwiftUI

// MARK: - Layout metrics
//
// Ported from the design project (Handoff §1, §7). Radii that differ between
// the Flat and Liquid Glass looks are resolved through `MRTSurfaceLook` — use
// `look.cardRadius` / `look.sheetRadius` instead of the raw constants when a
// look is in scope.

public enum MRTMetrics {
    /// Horizontal page padding.
    public static let pageGutter: CGFloat = 24
    /// Vertical gap between stacked cards.
    public static let cardGap: CGFloat = 12
    /// Card corner radius in the Liquid Glass look (default).
    public static let cardRadius: CGFloat = 16
    /// Card corner radius in the Flat look.
    public static let cardRadiusFlat: CGFloat = 14
    /// Inputs and buttons.
    public static let controlRadius: CGFloat = 12
    /// Bottom sheet top corners in the Flat look (default).
    public static let sheetRadius: CGFloat = 24
    /// Bottom sheet top corners in the Liquid Glass look.
    public static let sheetRadiusLiquid: CGFloat = 30
    /// Minimum hit target for any interactive element.
    public static let minTapTarget: CGFloat = 44
    /// Hairline border width used by the Flat look.
    public static let hairline: CGFloat = 0.5

    // MARK: Overlays (Handoff §7)

    /// Confirm-dialog card corner radius.
    public static let dialogRadius: CGFloat = 22
    /// Confirm-dialog card max width.
    public static let dialogMaxWidth: CGFloat = 300
    /// Confirm-dialog tinted icon-circle diameter.
    public static let dialogIconSize: CGFloat = 46
    /// Config bottom-sheet top-corner radius (§7 — 26, distinct from the
    /// home detent sheet's look-resolved 24/30).
    public static let configSheetRadius: CGFloat = 26
    /// Success-toast default bottom offset — clears the floating tab bar.
    public static let toastBottomOffset: CGFloat = 116
    /// Home detent-sheet peek height (components.jsx `BottomSheet` peekH).
    public static let sheetPeekHeight: CGFloat = 260

    // MARK: Sign in (MYR-164, design/app/screens.jsx SignInScreen)

    /// Sign in with Apple button height (screens.jsx sign-in sheet button,
    /// `height: 54`).
    public static let appleButtonHeight: CGFloat = 54
    /// Sign in with Apple button corner radius (screens.jsx sign-in sheet
    /// button, `borderRadius: 14`).
    public static let appleButtonRadius: CGFloat = 14

    // MARK: Onboarding (MYR-165, design/app/onboarding.jsx)

    /// PairStepper distance from the top of the screen (onboarding.jsx:32
    /// `top: 124` — clears the top-right Cancel action, Handoff §5.2).
    public static let pairStepperTop: CGFloat = 124
    /// PairStepper horizontal inset (onboarding.jsx:32 `left/right: 28`).
    public static let pairStepperGutter: CGFloat = 28
    /// Onboarding flows' content gutter (onboarding.jsx `padding…: 30`).
    public static let onboardingGutter: CGFloat = 30
    /// Top-right ghost Skip/Cancel offset (onboarding.jsx:19 `top: 82`).
    public static let onboardingTopActionTop: CGFloat = 82

    // MARK: Tutorials / StoryDeck (MYR-166, design/app/tutorials.jsx)

    /// Vignette shell (`MiniScreen`) corner radius (tutorials.jsx:11).
    public static let vignetteRadius: CGFloat = 28
    /// Kicker row distance from the top (tutorials.jsx:320 `top: 84`).
    public static let storyKickerTop: CGFloat = 84
    /// Kicker row left inset (tutorials.jsx:320 `left: 26`).
    public static let storyKickerGutter: CGFloat = 26
    /// Swipe surface top padding, clears the kicker/Skip row (tutorials.jsx:327
    /// `paddingTop: 128`).
    public static let storyContentTop: CGFloat = 128
    /// Swipe surface bottom padding (tutorials.jsx:327 `paddingBottom: 34`).
    public static let storyContentBottom: CGFloat = 34
    /// Page-dot active width (tutorials.jsx:345).
    public static let storyDotActiveWidth: CGFloat = 22
    /// Page-dot size (both axes for an inactive dot, height for the active
    /// pill) (tutorials.jsx:345).
    public static let storyDotSize: CGFloat = 7
    /// Gap between page dots (tutorials.jsx:342).
    public static let storyDotGap: CGFloat = 7

    // MARK: Live Map (MYR-167, design/app/screens.jsx HomeScreen/MapHeader)

    /// MapHeader distance from the top of the screen (screens.jsx:302 `top: 60`).
    public static let mapHeaderTop: CGFloat = 60
    /// Vehicle-switcher chip height (screens.jsx:306 `height: 40`).
    public static let mapChipHeight: CGFloat = 40
    /// Vehicle-switcher picker menu width (screens.jsx:323 `width: 250`).
    public static let mapPickerWidth: CGFloat = 250
    /// Sheet peek height while driving (screens.jsx:400 `peekH`).
    public static let homePeekHeightDriving: CGFloat = 280
    /// Sheet peek height while parked, "floating" style — the only
    /// `parkedStyle` variant this app ships (screens.jsx:400,369 default).
    public static let homePeekHeightParked: CGFloat = 210
    /// Sheet half-detent as a fraction of the map container's height
    /// (screens.jsx:401 `Math.round(mapHeight * 0.58)`).
    public static let homeHalfHeightFraction: CGFloat = 0.58
    /// Recenter `FloatingMapButton` clearance above the sheet peek
    /// (screens.jsx:424 `bottom={peekH + 80}`).
    public static let mapButtonBottomGap: CGFloat = 80
    /// Reserved height for the half-detent `VehicleControls` placeholder —
    /// approximates one `ControlTile` row (vehicle-controls.jsx:24-41: 20pt
    /// icon + 8pt gap + two text lines + 13/12pt vertical padding), which
    /// MYR-168 fills in.
    public static let homeControlsPlaceholderHeight: CGFloat = 84
    /// Sheet scroll-content bottom clearance above the floating tab bar
    /// (screens.jsx:542 `padding: '6px 24px 100px'`).
    public static let homeSheetContentBottomPadding: CGFloat = 100

    // MARK: Vehicle Controls (MYR-168, design/app/vehicle-controls.jsx)

    /// `ControlTile` corner radius (vehicle-controls.jsx:28).
    public static let vehicleControlTileRadius: CGFloat = 16
    /// `SectionCard` corner radius — 18, distinct from the generic `.control`
    /// surface's 12 (vehicle-controls.jsx:51 `borderRadius: 18`).
    public static let vehicleControlsSectionRadius: CGFloat = 18
    /// Gap above each `SectionCard` (vehicle-controls.jsx:46 `marginTop: 18`).
    public static let vehicleControlsSectionGap: CGFloat = 18
    /// `mrt-range` thumb diameter (components.jsx:769-770).
    public static let sliderThumbSize: CGFloat = 22
}
