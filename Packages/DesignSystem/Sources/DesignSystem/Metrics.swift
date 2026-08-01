import SwiftUI

// MARK: - Layout metrics
//
// Ported from the design project (Handoff §1, §7). Radii that differ between
// the Flat and Liquid Glass looks are resolved through `MRTSurfaceLook` — use
// `look.cardRadius` / `look.sheetRadius` instead of the raw constants when a
// look is in scope.

/// A LIVE-ONLY line the owner sheet's peek hero carries that the prototype's
/// hero does not, and the room the peek band grows by to hold it
/// (``MRTMetrics/homePeekHeight(base:qualifiers:)``).
///
/// MYR-315 introduced one flat number for both of these. MYR-345 (client defect)
/// is why they are now separate: the reserve is what stands between the hero's
/// last line and the floating nav, so reserving MORE than a line measures puts
/// the surplus straight into that gap — *"Weird gap between menu and synced just
/// now"*. Each case therefore carries what its own line actually measures, and
/// the numbers are pinned against the REAL views in `OwnerPeekBandTests`.
public enum MRTHomePeekQualifier: Sendable, Equatable, CaseIterable {
    /// MYR-315's tappable recency stamp at the FOOT of the hero: a standalone
    /// 13⅓pt row (an 11pt line box, with the 9.5pt semibold glyph beside it
    /// fitting inside) plus the 10pt lead `mrtFreshnessStamp` gives it — the
    /// design's trailing-qualifier rhythm (`components.jsx:559`).
    ///
    /// Its ≥44pt TOUCH region is bigger than that and is deliberately NOT part of
    /// this number: a `contentShape` inset does not move layout, and the region
    /// still stops clear of the nav (MYR-345).
    case freshnessStamp
    /// MYR-316's "Service Estimated Completion · …" line, GROUPED under the hero
    /// header at 2pt (MYR-319) rather than standing alone: a 12pt muted line box
    /// (~14.3pt) plus that 2pt lead. It is the smaller of the two because it is
    /// the header's own second line, not a new block.
    case serviceCompletion

    /// What the line costs the gap the OWNER sees — measured off full-frame
    /// captures, not derived on paper.
    ///
    /// `serviceCompletion` is 2 + 14⅓ ⇒ **16**: it neither is nor follows the
    /// hero's last line, so its layout cost and its optical cost are the same
    /// number.
    ///
    /// `freshnessStamp` is 10 + 13⅓ ⇒ 23⅓ of LAYOUT, but **25** here. It is the
    /// hero's last line, and the gap under the hero is measured from INK, not from
    /// a layout box: the stamp's glyphs (an 11pt line with a 9.5pt semibold
    /// `arrow.clockwise` beside it) sit ~2pt lower in their box than the 12pt
    /// location line they take over from, so a reserve equal to the layout cost
    /// leaves the visible gap 2pt tighter than the prototype's. Two points is
    /// small and this client measured six; optical parity is the point of the
    /// issue. Verified full-frame: 43.0pt of ink clearance with no qualifier line,
    /// 43.0 with the stamp, 42.7 with both lines.
    public var reservedHeight: CGFloat {
        switch self {
        case .freshnessStamp: 25
        case .serviceCompletion: 16
        }
    }
}

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
    /// Sheet peek height while driving with **no active navigation** (MYR-294) —
    /// a state the prototype does not have, so 280 is not its number.
    ///
    /// 280 is the prototype's band for the prototype's driving hero, which is a
    /// TRIP: a destination headline, an "Arriving in N min · ETA h:mm" pair, and
    /// the trip progress bar. A car that is driving with nowhere programmed has
    /// none of those — it has a status line, a speed and a place — so the honest
    /// hero is ~57pt shorter, and leaving the band at 280 would drop every one of
    /// those points into the gap above the floating nav. That is MYR-345's rule
    /// (a live-only line brings exactly its own room) applied in the direction it
    /// has not been needed before: a live-only hero that DROPS lines gives the
    /// room back rather than banking it as a hole.
    ///
    /// Measured, not derived, and tuned against INK rather than the layout box —
    /// MYR-345's rule, which matters here more than it did there because the two
    /// heroes END ON DIFFERENT KINDS OF THING. The trip hero's last element is
    /// `TripProgressBar`, whose 15pt orb (plus its 2pt ring) OVERFLOWS the bar's
    /// own 14pt frame, so its ink reaches ~2pt BELOW its layout box; the honest
    /// hero's last element is a 12pt location line, whose glyphs stop ~2pt ABOVE
    /// theirs. Layout parity and optical parity therefore disagree by ~4pt, and
    /// the gap the owner actually sees is the optical one.
    ///
    /// Full-frame ink clearance above the floating nav, iPhone 17 Pro:
    /// **42.7pt** for the navigating hero (base and branch alike — unchanged),
    /// 46.7pt at a layout-parity 238, **42.7pt at 234**.
    /// `OwnerPeekBandTests` pins the layout side of the same fact, carrying the
    /// 4pt offset explicitly rather than widening its tolerance to hide it.
    ///
    /// Unreachable on the simulated path: every fixture trip is
    /// `.destination(…)`, so no drift-gate scene sees this band.
    public static let homePeekHeightDrivingNoNavigation: CGFloat = 234
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
    /// The owner sheet's peek band: the prototype's number for the hero's shape,
    /// plus room for each LIVE-ONLY qualifier line the port adds to it.
    ///
    /// MYR-315 (client polish) — `homePeekHeightParked`/`Driving` are the
    /// prototype's numbers for the prototype's content, and the prototype's peek
    /// hero has neither a freshness stamp nor a service-completion line: both are
    /// LIVE-ONLY additions this port made to that block. Adding a line to fixed
    /// bands spent the clearance `BottomSheet` reserves between sheet content and
    /// the floating nav (`homeSheetContentBottomPadding`, components.jsx:542), and
    /// the stamp — an interactive element whose ≥44pt target extends past its ink —
    /// ended up touching the tab bar's own top edge (60pt tall, 26pt up ⇒ 86pt
    /// from the physical edge). The band grows per live-only line actually
    /// rendered, so the added content brings its own room instead of eating the
    /// nav's.
    ///
    /// MYR-345 (the client again) — that room is now PER LINE, not a flat 24 for
    /// whichever line it is: see ``MRTHomePeekQualifier``.
    ///
    /// An EMPTY list returns `base` unchanged — that is the simulated /
    /// drift-gate path, and it is what keeps every existing scene byte-identical.
    public static func homePeekHeight(base: CGFloat, qualifiers: [MRTHomePeekQualifier]) -> CGFloat {
        base + qualifiers.reduce(0) { $0 + $1.reservedHeight }
    }

    // MARK: Tall sheet detent (MYR-332)

    /// The band of screen a sheet at its TALLEST detent leaves showing above
    /// itself, measured from the PHYSICAL top edge.
    ///
    /// This is the design's own number, not an invention: the tallest surface in
    /// the sheet grammar is the rider's search sheet, `SHEET_HEIGHTS.search` =
    /// 712 on the prototype's full-bleed 852 canvas (ride-request.jsx:47) — so
    /// the grammar's "as tall as a sheet goes" leaves exactly 852 − 712 = 140pt
    /// of chrome above it. That band also clears the `MapHeader` vehicle switcher
    /// whole (top 60 + 40pt chip ⇒ its bottom edge at 100), which is what makes
    /// it a legible stop rather than a full-screen takeover: the owner can still
    /// see WHICH car the controls belong to.
    public static let sheetTallTopClearance: CGFloat = 140

    /// The owner sheet's TALL detent (MYR-332, client ask): the controls stack
    /// tops out at the half detent today and the rest is reached only by scrolling
    /// inside it — the client wants to pull the sheet itself higher. Expressed as
    /// the physical screen height less ``sheetTallTopClearance``, so the stop is
    /// the sheet grammar's own tallest surface on any device.
    ///
    /// Returns `nil` when the geometry cannot produce a detent taller than `half`
    /// (a very short screen, or a `half` already at the cap) — the sheet then
    /// keeps exactly its peek/half pair, unchanged.
    public static func sheetTallHeight(screenHeight: CGFloat, halfHeight: CGFloat) -> CGFloat? {
        guard screenHeight.isFinite, halfHeight.isFinite else { return nil }
        let tall = screenHeight - sheetTallTopClearance
        // A tall detent must be meaningfully taller than half, or the extra stop
        // is a second detent the finger cannot tell apart from the first.
        guard tall > halfHeight + 24 else { return nil }
        return tall
    }

    /// Distance from the PHYSICAL bottom edge to the top of the floating
    /// `BottomNav` — its 60pt height plus the 26pt it floats above the edge
    /// (`BottomNav`: `.padding(.bottom, 26)`, components.jsx:566). The number the
    /// sheet's own reserved band (``homeSheetContentBottomPadding``) has to clear.
    public static let bottomNavTopEdge: CGFloat = 86
    /// Total height of `MRTGrabHandle` (4pt bar + 10pt top pad + 6pt bottom
    /// pad). The crossfade owner sheet (MYR-236 r5.3) draws the handle in its
    /// always-opaque base and reserves this at the top of each crossfade layer,
    /// so both layers' content aligns beneath the one stationary handle.
    public static let sheetGrabHandleHeight: CGFloat = 20

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

    // MARK: Share roster (MYR-347 — the client-directed redesign of the owner
    // Share tab's list into native iOS grouped-list grammar. These are OURS, not
    // the prototype's: screens.jsx:113-138 renders two bare header+row stacks
    // with no card, no separator and no empty state, which is the shape the
    // client rejected. Every value is still a token so the screen holds no
    // literals — CLAUDE.md "Tokens only".)

    /// Corner radius of a roster section card.
    public static let shareSectionRadius: CGFloat = 16
    /// Gap above a section header (below the header block or the previous card).
    public static let shareSectionGap: CGFloat = 22
    /// Gap between a section header and its card.
    public static let shareSectionHeaderGap: CGFloat = 9
    /// Horizontal padding INSIDE a roster card.
    public static let shareRowGutter: CGFloat = 14
    /// Vertical padding of a roster row.
    public static let shareRowVerticalPadding: CGFloat = 11
    /// Avatar / leading-tile diameter on a roster row.
    public static let shareRowAvatarSize: CGFloat = 38
    /// Avatar → text column gap.
    public static let shareRowContentGap: CGFloat = 12
    /// Roster-row minimum height (comfortably over the 44pt hard rule; a
    /// two-line row measures ~60 and a three-line one grows past it).
    public static let shareRowMinHeight: CGFloat = 60
    /// Separator inset — the text column's left edge, so a separator starts
    /// where the label does, exactly as iOS insets one past a leading image.
    public static let shareRowSeparatorInset: CGFloat = shareRowGutter
        + shareRowAvatarSize + shareRowContentGap
    /// Gap between the screen header and the empty-state hero.
    public static let shareHeroTopGap: CGFloat = 44
    /// Empty-state hero icon-disc diameter.
    public static let shareHeroIconSize: CGFloat = 64
    /// Empty-state explainer measure — narrow enough to stay a readable
    /// three-line paragraph at 393pt rather than running the full gutter width.
    public static let shareHeroTextWidth: CGFloat = 286
    /// Empty-state CTA width. Not full-bleed: a hero CTA that spans the gutters
    /// reads as a page-level action rather than the answer to the sentence
    /// above it.
    public static let shareHeroCTAWidth: CGFloat = 210

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
    /// MYR-223 deliverable 2 — the idle sheet's ACTUAL height when it is showing
    /// the minimized "Request sent" pending pill instead of the greeting/search
    /// content. The idle sheet drops its fixed `sharedIdleSheetHeight` and hugs
    /// the (much shorter) pill in that state (MYR-199), so the map's bottom inset
    /// must track this shorter chrome — otherwise the MapKit legal attribution,
    /// insetted for the tall 286 greeting sheet, floats at mid-page above the
    /// short pill (the client's on-device screenshot). Sized to the pill card:
    /// the idle sheet's 14 top + ~52 pill row + 98 nav-clearance bottom padding.
    public static let sharedPendingPillSheetHeight: CGFloat = 164
    /// MYR-352 — the gap BELOW the rider idle sheet's availability banner, i.e.
    /// between it and the search bar it sits above. 14 is the search bar's own
    /// `.padding(.bottom, 14)` and `watchOnlyNotice`'s, so the banner keeps the
    /// idle card's existing row rhythm rather than inventing a spacing.
    ///
    /// The banner's own HEIGHT is deliberately NOT a constant here: its headline
    /// wraps for the longer reasons and its second line is conditional, so what it
    /// costs depends on the copy, the vehicle's name and the device width. It is
    /// measured (`RiderIdleBannerHeightKey`) and the idle detent grows by exactly
    /// `measured + this gap` — MYR-345's per-line-reserve rule, where the line's
    /// room can only be known by asking it.
    public static let riderIdleBannerGap: CGFloat = 14
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
    /// MYR-177 — the live tracking sheet is content-sized and noticeably SHORTER
    /// than the Review/Booking sheets (`rideRequestRouteMapBottomInset` was tuned
    /// for those). Reusing 430 for tracking over-reserved the bottom, floating
    /// the leg fit up into the top third with dead map below it (client: "stuck
    /// at the top … should fill screen") and the attribution mid-page. This is
    /// the tracking sheet's real cover height, so the leg-fit camera fills the
    /// true visible band and the attribution sits just above the sheet.
    public static let trackingMapBottomInset: CGFloat = 312
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

    // MARK: - Live ride tracking map (MYR-177)

    /// Padding factor for the leg-fit tracking camera — grows the route's
    /// bounding box just enough for breathing room so the car + pickup (leg 1)
    /// or pickup + destination (leg 2) FILL the unobstructed area above the
    /// sheet (client: "centered to fit and fill screen"), not a small island in
    /// the middle. Tight — the fit already centers in the true visible rect
    /// (top notch + bottom sheet insets), so it only needs a modest margin.
    public static let trackingLegFitPadding: Double = 1.28

    /// Re-fit trigger margin as a fraction of the fitted region's span: the
    /// leg-fit camera re-frames only once the car crosses into the outer
    /// `trackingRefitMarginFraction` band of the region it last framed (i.e. is
    /// about to leave view), NOT on every fix. This is the anti-feedback-loop
    /// knob (MYR-222): a car sitting well inside the frame produces ZERO camera
    /// writes at any fix rate.
    public static let trackingRefitMarginFraction: Double = 0.14

    /// Material-deviation threshold (meters) for the cached ride route: the leg
    /// route is refetched from the provider only when the car strays farther
    /// than this from the cached polyline (it took a different road), never on a
    /// timer. Well inside a city block, comfortably outside normal GPS jitter.
    public static let rideRouteDeviationThresholdMeters: Double = 60

    /// Top inset (points) the leg-fit tracking camera reserves for the device
    /// top chrome (status bar / notch) when centering the route in the true
    /// unobstructed rect — the full-bleed map draws under the notch, so the fit
    /// keeps the car/pickup below it instead of hidden behind it (the MYR-212
    /// "use the real visible rect" lesson, applied to the top edge). A fixed
    /// device metric, like the other full-bleed physical-edge offsets (MYR-196).
    public static let trackingFitTopInset: CGFloat = 88

    /// Bottom offset for the rider recenter button on the live tracking map
    /// (MYR-177) — floats just above the content-sized tracking sheet, mirroring
    /// the idle map's `FloatingMapButton` placement/language.
    public static let trackingRecenterButtonBottom: CGFloat = 340

    /// MYR-271 — the rider tracking sheet's PEEK detent (hosted on the `PanSheet`
    /// engine): the hero band + a hint of the itinerary stays visible while dragging
    /// the card down reveals more of the two-leg map. The FULL detent is the card's
    /// measured natural height.
    public static let trackingSheetPeekHeight: CGFloat = 150

    /// MYR-271 — gap between the rider tracking sheet's SETTLED top edge and the
    /// recenter button's bottom, so the button clears the card in EVERY detent
    /// (re-anchored off the settled detent height, not a fixed offset).
    ///
    /// MYR-397 — it is no longer the SETTLED height the buttons are anchored off:
    /// they are laid out once against the PEEK detent and translated by the engine
    /// as the sheet grows (`SheetEdgeAnchor`), so this gap is now the distance from
    /// the sheet's live top edge at every point of the drag rather than only at
    /// rest. The number is unchanged, so the resting frames are.
    public static let trackingRecenterSheetGap: CGFloat = 22

    /// MYR-397 — the tracking sheet's peek layer sizes to its own content
    /// (`SHEET_HEIGHTS`' rule for every phase past search, ride-request.jsx:47),
    /// so `trackingSheetPeekHeight` above is only the FALLBACK until the first
    /// measurement lands. This is the peek composition's bottom band: smaller than
    /// the full card's 30 because a brief summary ends on its last line of ink,
    /// where the full card ends above a home indicator with a scroll behind it.
    public static let trackingPeekBottomPad: CGFloat = 18

    /// MYR-397 — the gap above the tracking sheet's "Cancel ride" action. Matches
    /// the sheet's own inter-block rhythm (the itinerary/ride-row 12 plus the 6 a
    /// destructive control takes to sit apart from the content it is about).
    public static let trackingCancelTopGap: CGFloat = 18

    // MARK: - Expanded route viewer (MYR-327)
    //
    // The full-screen interactive route surface a map tap opens. It has NO
    // prototype counterpart (a client feature ask, TestFlight ADFCbiKq28), so
    // its chrome is keyed to the Drive Summary hero's own floating nav — same
    // button diameter, same 52pt top offset from the PHYSICAL edge (MYR-196
    // full-bleed geometry) — rather than inventing a second language.

    /// Fit padding for the expanded viewer's initial framing — a touch more
    /// generous than the tracking leg fit (`trackingLegFitPadding`, 1.28)
    /// because nothing covers this map: the whole route should sit clear of the
    /// header chip and the recenter button, not graze the edges.
    public static let expandedRouteFitPadding: Double = 1.15

    /// Smallest span the expanded viewer's fit will produce (~165m of latitude),
    /// replacing `VehicleRoute.fittedRegion`'s default 0.02° (~2.2km) floor for
    /// THIS surface only. That default floor is right for the fixed hero maps,
    /// but on a short trip — the client's own 0.2 mi drive — it is ~10× the route,
    /// so the "zoom in and look at it" view opened city-wide with the route a stub
    /// in the middle. Small enough to frame a couple of blocks, large enough that a
    /// degenerate one-point route still lands on a readable street view.
    public static let expandedRouteMinSpanDelta: Double = 0.0015

    /// Close / recenter / expand button diameter — matches
    /// `driveSummaryFloatingButtonSize` (38) so the chip family reads as one;
    /// each call site expands the hit area to `minTapTarget` (44).
    public static let expandedRouteButtonSize: CGFloat = 38

    /// Top offset of the expanded viewer's header row from the PHYSICAL top
    /// edge — the Drive Summary floating nav's own offset (screens.jsx:889
    /// `top: 52`), so closing the expanded view lands the ✕ where the ‹ was.
    ///
    /// MYR-334: this is a FLOOR, not the final offset. On the Drive Summary the
    /// 52pt row carries a single icon that reads fine beside the clock, but this
    /// surface puts a two/three-line TITLE there, and at 52 its first line runs
    /// straight into the status bar and under the Dynamic Island (the client's
    /// "the start to destination at the top is cutting off", iPhone 17 Pro Max).
    /// The view takes `max(expandedRouteChromeTop, safeAreaTop + …SafeGap)`:
    /// still a PHYSICAL-edge offset (MYR-196), just never one that collides with
    /// system UI.
    public static let expandedRouteChromeTop: CGFloat = 52

    /// Minimum air between the system's own top band (status bar / Dynamic
    /// Island, i.e. the window's top safe-area inset) and the expanded viewer's
    /// header row. Small on purpose — the map stays full-bleed underneath; only
    /// the text moves out from under the clock.
    public static let expandedRouteChromeSafeGap: CGFloat = 8

    /// Bottom offset of the expanded viewer's recenter button from the PHYSICAL
    /// bottom edge. There is no bottom chrome on this takeover, so it sits at
    /// the `BottomNav`'s own 26pt float plus a 20pt breath above the home
    /// indicator.
    public static let expandedRouteRecenterBottom: CGFloat = 46

    /// Bands the expanded viewer's floating chrome occupies, so the route lands
    /// BETWEEN the header chip and the recenter button rather than running under
    /// either. Measured from the PHYSICAL edges (MYR-196).
    ///
    /// MYR-334: these are now the Map's own `.safeAreaPadding`, not a
    /// `VehicleRoute.insetRegion` pre-compensation of the written region — the
    /// MYR-237 rule (`RideRequestRouteMap`), which every other map on the app
    /// already follows: under `safeAreaPadding` MapKit ALREADY fits a `.region`
    /// camera into the unobstructed band, so there must be exactly ONE
    /// compensation. Expressing it as padding is what also lifts MapKit's
    /// attribution off the physical bottom edge, where it was being clipped.
    /// Kept EQUAL top/bottom for two reasons: the route stays optically centred,
    /// and a symmetric band leaves the settled camera's CENTRE identical to the
    /// written one, so `CameraSettleLedger` still recognises our own fit.
    public static let expandedRouteFitTopInset: CGFloat = 112
    public static let expandedRouteFitBottomInset: CGFloat = 112

    /// Legibility scrim height under the expanded viewer's header — the Drive
    /// Summary hero's own top scrim (screens.jsx:882 `height: 100`), grown for
    /// the taller two/three-line header.
    public static let expandedRouteScrimHeight: CGFloat = 140

    /// Vertical gap between the tracking map's recenter button and the expand
    /// chip stacked above it — the 44pt hit target plus a hairline of air, so
    /// the two never share a touch.
    public static let trackingExpandButtonStackGap: CGFloat = 52

    /// Duration of the expanded viewer's open/close cross-fade — the app's own
    /// overlay grammar (`mrt-sched-up`, ride-request.jsx:1053, already used for
    /// the rider's declined notice), on the Handoff §8 sheet-snap curve.
    ///
    /// MYR-334: shorter than the 0.42s it replaced, and there is no longer a
    /// `scale` component at all. See `AnyTransition.mrtRouteExpand` for why a
    /// scale over a live `MKMapView` was the jank.
    public static let expandedRouteFadeDuration: Double = 0.3
}
