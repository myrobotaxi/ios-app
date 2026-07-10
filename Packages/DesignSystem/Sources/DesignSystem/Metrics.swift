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

    // MARK: Drives / Drive Summary (MYR-169, design/app/screens.jsx 604-1183)

    /// Drives header top inset — clears the status bar (screens.jsx:631
    /// `padding: '74px 24px 16px'`).
    public static let drivesHeaderTop: CGFloat = 74
    /// Drives scroll-content bottom clearance above the floating tab bar
    /// (screens.jsx:635 `paddingBottom: 104`).
    public static let drivesContentBottomPadding: CGFloat = 104
    /// Segmented-control track corner radius (screens.jsx:637).
    public static let drivesSegmentRadius: CGFloat = 12
    /// Segmented-control active-pill corner radius (screens.jsx:639).
    public static let drivesSegmentItemRadius: CGFloat = 9
    /// UpcomingRow icon tile / cancel-button hit area (screens.jsx:754 `width:38`).
    public static let upcomingIconTileSize: CGFloat = 38
    /// UpcomingRow cancel (✕) button visual size — expanded to `minTapTarget`
    /// for the hit target (screens.jsx:764 `width:28`).
    public static let upcomingCancelButtonSize: CGFloat = 28
    /// Drive-summary hero map height (screens.jsx:873 `height: 268`).
    public static let driveSummaryHeroHeight: CGFloat = 268
    /// Drive-summary floating back/share button diameter (screens.jsx:890,893
    /// `width:38, height:38`).
    public static let driveSummaryFloatingButtonSize: CGFloat = 38
    /// Drive-summary `DS_TILE` corner radius — distinct from the generic
    /// `cardRadius` (screens.jsx:995 `borderRadius: 18`).
    public static let driveSummaryTileRadius: CGFloat = 18

    // MARK: DSShareCard (screens.jsx:1192-1224)

    /// Share-card width — the fixed render width for `ImageRenderer`
    /// (screens.jsx `MapBackground width={362}`, 1196).
    public static let shareCardWidth: CGFloat = 362
    /// Share-card hero-map height (screens.jsx:1195 `height: 132`).
    public static let shareCardMapHeight: CGFloat = 132
    /// Share-card corner radius (screens.jsx:1194 `borderRadius: 20`).
    public static let shareCardRadius: CGFloat = 20

    // MARK: Toggle (MYR-170, design/app/components.jsx `Toggle` 254-272)

    /// Track width (components.jsx:255 `width: 51`).
    public static let toggleTrackWidth: CGFloat = 51
    /// Track height (components.jsx:255 `height: 31`).
    public static let toggleTrackHeight: CGFloat = 31
    /// Track corner radius (components.jsx:256 `borderRadius: 16`).
    public static let toggleTrackRadius: CGFloat = 16
    /// Thumb diameter (components.jsx:264 `width: 27, height: 27`).
    public static let toggleThumbSize: CGFloat = 27
    /// Thumb inset from the track edge, both rest positions
    /// (components.jsx:263 `left: value ? 22 : 2`; 22 = 51 - 27 - 2).
    public static let toggleThumbInset: CGFloat = 2

    // MARK: Owner Share / Settings (MYR-170, design/app/screens.jsx
    // 1246-1834, shared-screens.jsx 444-557)

    /// Header top inset, shared by Invites/Settings/SharedSettings — same
    /// physical offset as `drivesHeaderTop` (screens.jsx:97,398;
    /// shared-screens.jsx:694, all `padding: '74px 24px …'`).
    public static let shareHeaderTop: CGFloat = drivesHeaderTop
    /// Scroll-content bottom clearance above the floating tab bar, shared by
    /// Invites/Settings/SharedSettings — same as `drivesContentBottomPadding`
    /// (screens.jsx:101,401; shared-screens.jsx:698, all `paddingBottom: 104`).
    public static let shareContentBottomPadding: CGFloat = drivesContentBottomPadding

    // MARK: Rider shell (MYR-191, design/app/screens.jsx SharedViewerScreen
    // 1855-2242 + ride-request.jsx ExpandingRequestSheet, design/app/
    // shared-screens.jsx RideHistoryScreen/ScheduledRideSheet 1-436).
    //
    // RideHistoryScreen's header/content-clearance offsets are physically
    // identical to Drives/Share/Settings (shared-screens.jsx:62,71, both
    // `74px …` / `paddingBottom: 104`) — reuse `shareHeaderTop` /
    // `shareContentBottomPadding` directly rather than aliasing them again.

    /// SharedViewerScreen idle sheet height when no request is active and no
    /// ride is scheduled — `idleHeight={(reqActive ? 246 : 286) + …}` reduces
    /// to 286 in M1, which never has an active/scheduled ride (screens.jsx:2078).
    public static let sharedIdleSheetHeight: CGFloat = 286
    /// ScheduledRideSheet map-preview panel height (shared-screens.jsx:352 `height: 104`).
    public static let rideMapPreviewHeight: CGFloat = 104
    /// `S.modalSheet`'s top-corner radius in the flat look (design/app/
    /// design.jsx:68 `modalRadius: liquid ? 32 : 28`) — distinct from the
    /// home detent sheet's `sheetRadius` (24) and the generic
    /// `mrtConfigSheet`'s `configSheetRadius` (26, Handoff §7 send-invite/
    /// vehicle-detail sheets). `ScheduledRideSheet` is the first surface to
    /// use it; MYR-171's `IncomingRequestSheet` (also `S.modalSheet`) reuses
    /// the same constant.
    public static let modalRadius: CGFloat = 28

    // MARK: Ride request flow (MYR-171, design/app/ride-request.jsx
    // ExpandingRequestSheet/IncomingRequestSheet)
    //
    // `ExpandingRequestSheet`'s `SHEET_HEIGHTS` constants (ride-request.jsx:
    // 43-52) turn out to be legacy/reference numbers for every phase except
    // idle/search/pinDrop — review/pending/tracking size to content ('auto'
    // in the jsx, ride-request.jsx:1119-1131) and this port does the same
    // (no fixed-height metric needed for those phases).

    /// `IncomingRequestSheet`'s small route-preview map card (owner Home) —
    /// visually shorter than `rideMapPreviewHeight` (104, `ScheduledRideSheet`'s
    /// wider detail-mode preview); the incoming-request card sits above a
    /// denser stat row so it reads closer to ~132pt in the prototype capture.
    public static let incomingRequestMapHeight: CGFloat = 132
    /// `RouteSentToast` distance from the top of the screen — full-bleed
    /// physical-edge offset (ride-request.jsx:1429 `top: 56`).
    public static let routeSentToastTop: CGFloat = 56
    /// `ExpandingRequestSheet`'s Search phase fixed height — the one other
    /// `SHEET_HEIGHTS` entry (besides idle) actually used; every phase after
    /// it sizes to content (ride-request.jsx:47 `SHEET_HEIGHTS.search`, 1128).
    public static let rideRequestSearchSheetHeight: CGFloat = 712
    /// `ExpandingRequestSheet`'s legacy `SHEET_HEIGHTS.pinDrop` reference
    /// value — the live sheet sizes pinDrop to content (ride-request.jsx:
    /// 1129 `h = 'auto'`), but this app's `VehicleMapView` needs a concrete
    /// `bottomContentInset` while the pin-drop sheet is up, and 280 (the
    /// jsx's own retired constant) is a reasonable stand-in for that sheet's
    /// actual auto-height (ride-request.jsx:51 `SHEET_HEIGHTS.pinDrop`).
    public static let rideRequestPinDropMapInset: CGFloat = 280
    /// MYR-216 deliverable 4 — the bottom area the route-fitted trip sheets
    /// (Review / Booking / Tracking) physically cover, plus a margin, used to
    /// inset the route camera fit so both endpoints + the full polyline clear the
    /// sheet (the destination endpoint used to hide behind it). These sheets size
    /// to content ('auto'), so this is a generous representative cover height sized
    /// for the tallest of them — over-insetting a shorter sheet only adds top
    /// margin, it never hides an endpoint. (Summary is excluded: it's a
    /// full-screen takeover, not a peek-above-a-bottom-sheet.)
    public static let rideRequestRouteMapBottomInset: CGFloat = 430
    /// The vertical screen fraction (0 = top edge, 1 = bottom edge) at which the
    /// fixed pin-drop glyph is drawn over the map — it sits ABOVE the sheet so
    /// the rider can see the spot it marks. The confirmed pickup coordinate is the
    /// coordinate MapKit renders UNDER this exact point (MYR-213 converts it via
    /// `MapProxy.convert`), so glyph and pickup share one screen point and can
    /// never drift apart. Kept at MYR-212's tuned resting fraction so the
    /// simulated pin-drop scene renders pixel-identically.
    public static let ridePinDropGlyphScreenFraction: CGFloat = 0.36

    /// Default map camera span (degrees, latitude+longitude) for the owner Home
    /// map and the rider idle/search map — ~6.6km, the neighborhood overview the
    /// prototype's resting map shows. (Was a hardcoded 0.06 in `VehicleMapView`.)
    public static let mapRegionSpanDelta: Double = 0.06

    /// Street-level span (degrees) for the pin-drop camera — 0.004° latitude
    /// ≈ ~440m, so at the pin-drop sheet's bottom inset the unobstructed map shows
    /// a few blocks, matching the prototype's street-grid pin-drop feel. MYR-213:
    /// round 2 opened the pin-drop at the 0.06° overview (~6.6km, the client's
    /// "Legacy Dr to Parker Rd in one view" miles-wide capture).
    /// MYR-215: applied in BOTH live and sim (client-approved deviation — the
    /// rider needs a few-blocks view to confirm an exact pickup regardless of
    /// mode; see `SharedViewerScreen.pinDropRegionSpanDelta`). MYR-213 had
    /// gated it to live to keep the sim scene pixel-identical to the prototype;
    /// that gate is intentionally lifted for pin-drop zoom.
    public static let pinDropStreetSpanDelta: Double = 0.004
}
