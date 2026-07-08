import SwiftUI

// MARK: - Raw palette (single source of truth for hex values)
//
// Ported from the design project's `app/tokens.js` (`window.T`).
// The app is dark-appearance-only; these are programmatic colors, no asset
// catalog involved. NO hex values may appear outside this file.
//
// Provenance: every value verified against the design project's
// `app/tokens.js` (`window.T`) — the canonical source. Correct here only.
enum Hex {
    // Backgrounds
    static let bg: UInt32 = 0x0A0A0A
    static let bgSecondary: UInt32 = 0x111111
    static let surface: UInt32 = 0x1A1A1A
    static let surfaceHov: UInt32 = 0x222222
    static let elevated: UInt32 = 0x2A2A2A

    // Text
    static let text: UInt32 = 0xFFFFFF
    static let textSec: UInt32 = 0xA0A0A0
    static let textMuted: UInt32 = 0x6B6B6B

    // Brand — Cybercab Gold (the sacred accent)
    static let gold: UInt32 = 0xC9A84C
    static let goldLight: UInt32 = 0xD4C88A
    static let goldDark: UInt32 = 0xA0862E
    static let goldDeep: UInt32 = 0x8C6E2A // deep antique gold-brown — flat onboarding buttons + stepper
    static let goldDeepSoft: UInt32 = 0xB49A56 // stepper labels + active numerals

    // Status
    static let driving: UInt32 = 0x30D158
    static let parked: UInt32 = 0x3B82F6
    static let charging: UInt32 = 0xFFD60A
    static let offline: UInt32 = 0x6B6B6B

    // Danger
    static let danger: UInt32 = 0xFF3B30 // battery low / destructive
    static let dialogRed: UInt32 = 0xFF6B6B // softer red for dialog text

    // Borders
    static let border: UInt32 = 0x1F1F1F
    static let borderSubtle: UInt32 = 0x181818

    // Pure black — base for the overlay scrim rgba(0,0,0,0.6) (Handoff §7).
    static let black: UInt32 = 0x000000

    // Buttons (design/app/components.jsx `Button` variants + MRT_STYLES)
    static let goldButtonLabel: UInt32 = 0x1A1408 // near-black label on solid gold
    static let goldDeepButtonLabel: UInt32 = 0x1C1505 // label on goldDeep (flat onboarding gold)
    static let goldTrace: UInt32 = 0xE7C975 // border-trace highlight (conic 120°/180° stops)
    static let goldTraceBright: UInt32 = 0xFFF3C8 // border-trace hot spot (conic 150° stop)
    static let goldPulse: UInt32 = 0xF0D27A // mrt-gold-pulse peak text color

    // Overlays (Handoff §7)
    static let dialogCard: UInt32 = 0x1A1A1C // confirm-dialog card fill
    static let toastSurface: UInt32 = 0x22221F // success-toast pill fill

    // Brand mark (components.jsx HexLogo/ArrowMark — facet + tile colors)
    static let arrowFacetLight: UInt32 = 0xE4D08A // top-left facet polygon
    static let arrowFacetDark: UInt32 = 0x9C7E2C // bottom-right facet polygon
    static let logoTileTop: UInt32 = 0x1B1407 // tile gradient 0%
    static let logoTileMid: UInt32 = 0x0D0B06 // tile gradient 55%
    static let logoTileBottom: UInt32 = 0x090806 // tile gradient 100%

    // Bottom nav (components.jsx BottomNav)
    static let navBarFill: UInt32 = 0x161619 // rgb(22,22,25), used at 0.92 alpha
    static let navInactive: UInt32 = 0xC4AC6C // rgb(196,172,108), used at 0.62 alpha

    // Sign in (screens.jsx SignInScreen + ParticleLine, MYR-164)
    static let glimpseCream: UInt32 = 0xD0C9B8 // rgb(208,201,184) — ParticleLine non-live line color (screens.jsx `measure()`)

    // Onboarding (design/app/onboarding.jsx, MYR-165)
    static let keyCardMid: UInt32 = 0x0D0D0D // virtual-key card gradient 52% (onboarding.jsx:274; 0% stop is `surface` 0x1A1A1A)
    static let keyCardDeep: UInt32 = 0x050505 // virtual-key card gradient 100% (onboarding.jsx:274)
    static let etchLight: UInt32 = 0xF5ECC8 // etched wordmark gradient 0% (onboarding.jsx:286; 48% stop is `gold`)
    static let etchDark: UInt32 = 0x8A6E23 // etched wordmark gradient 100% (onboarding.jsx:286)
    static let linkedGreenLight: UInt32 = 0x3EE06A // linked-badge gradient top (onboarding.jsx:333; bottom stop is `driving`)
    static let linkedCheckStroke: UInt32 = 0x0A2912 // linked-badge drawn checkmark stroke (onboarding.jsx:337)

    // Simulated Tesla OAuth sheet (onboarding.jsx InAppBrowser, MYR-165).
    // Original plausible mock, NOT Tesla's real UI; replaced wholesale by
    // ASWebAuthenticationSession in MYR-115.
    static let teslaRed: UInt32 = 0xE82127 // Tesla brand tile + Sign In button (onboarding.jsx:116,133)
    static let browserBg: UInt32 = 0xF2F2F4 // browser sheet page background (onboarding.jsx:91)
    static let browserChrome: UInt32 = 0xE8E8EC // faux Safari chrome bar (onboarding.jsx:96)
    static let browserText: UInt32 = 0x1C1C1E // primary text on the light sheet (onboarding.jsx:101,121)
    static let browserTextSec: UInt32 = 0x6B6B70 // secondary text (onboarding.jsx:122,124)
    static let browserTextTert: UInt32 = 0x8A8A8F // scope-row subtitles (onboarding.jsx:164)
    static let browserTextFaint: UInt32 = 0xA0A0A5 // revoke-anytime footnote (onboarding.jsx:173)
    static let browserArrow: UInt32 = 0xB0B0B5 // consent header handoff arrow (onboarding.jsx:145)
    static let browserSpinner: UInt32 = 0x8E8E93 // chrome-bar progress spinner (onboarding.jsx:105)
    static let browserGlyph: UInt32 = 0x3A3A3C // URL-bar padlock glyph (onboarding.jsx:102)
    static let linkBlue: UInt32 = 0x0A84FF // iOS-blue links: Cancel, Forgot password? (onboarding.jsx:99,135)
    static let consentGreen: UInt32 = 0x34A853 // consent scope-row checkmarks (onboarding.jsx:166)

    // MYR-166 — tutorials (design/app/tutorials.jsx) — StoryDeck vignette shell
    static let vigCardTop: UInt32 = 0x222228 // MiniScreen gradient 0% — rgba(34,34,40,…) (tutorials.jsx:12)
    static let vigCardBottom: UInt32 = 0x101014 // MiniScreen gradient 100% — rgba(16,16,20,…) (tutorials.jsx:12)
    static let vigStatusPill: UInt32 = 0x141418 // status pill fill — rgba(20,20,24,0.66) (tutorials.jsx:35,192)

    // MYR-167 — Live Map header/switcher chip (design/app/screens.jsx
    // MapHeader:302-350) + picker menu.
    static let mapChipFill: UInt32 = 0x141418 // chip bg rgb(20,20,24) (screens.jsx:307)
    static let mapPickerFill: UInt32 = 0x18181C // picker menu bg rgb(24,24,28) (screens.jsx:324)

    // MYR-166 — map backdrop (design/app/components.jsx MapBackground:305-397),
    // ported for the story-deck live-map vignettes (VigLiveMap/VigTrack).
    static let mapLand: UInt32 = 0x1B1D21 // land base fill (components.jsx:359,365)
    static let mapPark: UInt32 = 0x18221A // park ellipses (components.jsx:369)
    static let mapStreet: UInt32 = 0x26282D // residential street stroke (components.jsx:374)
    static let mapCollectorCasing: UInt32 = 0x2E3138 // collector casing stroke (components.jsx:376)
    static let mapCollectorFill: UInt32 = 0x3C4049 // collector fill stroke (components.jsx:377)
    static let mapFreewayCasing: UInt32 = 0x2A2519 // freeway casing stroke (components.jsx:381)
    static let mapFreewayFill: UInt32 = 0x4C4330 // freeway fill stroke (components.jsx:382)
    static let mapWater: UInt32 = 0x0E1A26 // ocean fill (components.jsx:385)
    static let mapCoast: UInt32 = 0x16273A // coastline stroke (components.jsx:386)
    static let mapLabelOcean: UInt32 = 0x96B4D2 // "Pacific Ocean" label — rgba(150,180,210,…) (components.jsx:389)
    static let mapLabelPark: UInt32 = 0x96C896 // park-name label — rgba(150,200,150,…) (components.jsx:390)
}

// MARK: - Color tokens

public extension Color {
    // Backgrounds
    static let mrtBg = Color(hex: Hex.bg)
    static let mrtBgSecondary = Color(hex: Hex.bgSecondary)
    static let mrtSurface = Color(hex: Hex.surface)
    static let mrtSurfaceHov = Color(hex: Hex.surfaceHov)
    static let mrtElevated = Color(hex: Hex.elevated)

    // Text
    static let mrtText = Color(hex: Hex.text)
    static let mrtTextSec = Color(hex: Hex.textSec)
    static let mrtTextMuted = Color(hex: Hex.textMuted)

    // Brand gold
    static let mrtGold = Color(hex: Hex.gold)
    static let mrtGoldLight = Color(hex: Hex.goldLight)
    static let mrtGoldDark = Color(hex: Hex.goldDark)
    static let mrtGoldDeep = Color(hex: Hex.goldDeep)
    static let mrtGoldDeepSoft = Color(hex: Hex.goldDeepSoft)
    /// Gold glow, strong — matches the documented CTA glow shadow rgba(201,168,76,0.6).
    static let mrtGoldGlow = Color(hex: Hex.gold, alpha: 0.6)
    /// Gold glow, soft — matches the documented outer glow shadow rgba(201,168,76,0.3).
    static let mrtGoldGlowSoft = Color(hex: Hex.gold, alpha: 0.3)

    // Vehicle status
    static let mrtDriving = Color(hex: Hex.driving)
    static let mrtParked = Color(hex: Hex.parked)
    static let mrtCharging = Color(hex: Hex.charging)
    static let mrtOffline = Color(hex: Hex.offline)

    // Battery (batHigh/batMid share the driving/charging hexes in tokens.js)
    static let mrtBatHigh = Color(hex: Hex.driving)
    static let mrtBatMid = Color(hex: Hex.charging)

    // Danger
    static let mrtBatLow = Color(hex: Hex.danger)
    static let mrtDanger = Color(hex: Hex.danger)
    static let mrtDialogRed = Color(hex: Hex.dialogRed)

    // Borders
    static let mrtBorder = Color(hex: Hex.border)
    static let mrtBorderSubtle = Color(hex: Hex.borderSubtle)

    // Buttons (design/app/components.jsx `Button` variants + MRT_STYLES)
    /// Near-black label on the solid-gold button — `#1a1408`.
    static let mrtGoldButtonLabel = Color(hex: Hex.goldButtonLabel)
    /// Label on the goldDeep (flat-onboarding) gold button — `#1c1505`.
    static let mrtGoldDeepButtonLabel = Color(hex: Hex.goldDeepButtonLabel)
    /// Border-trace highlight — `#E7C975` (mrt-trace-spin conic 120°/180° stops).
    static let mrtGoldTrace = Color(hex: Hex.goldTrace)
    /// Border-trace hot spot — `#FFF3C8` (mrt-trace-spin conic 150° stop).
    static let mrtGoldTraceBright = Color(hex: Hex.goldTraceBright)
    /// Peak text color of the gold text pulse — `#F0D27A` (mrt-gold-pulse).
    static let mrtGoldPulse = Color(hex: Hex.goldPulse)
    /// Faint gold wash behind outline-draw / outline-static — rgba(201,168,76,0.06).
    static let mrtGoldFillFaint = Color(hex: Hex.gold, alpha: 0.06)
    /// Resting outline-draw border — rgba(201,168,76,0.22).
    static let mrtGoldBorderFaint = Color(hex: Hex.gold, alpha: 0.22)
    /// outline-static border — `#C9A84C55`.
    static let mrtGoldBorderSoft = Color(hex: Hex.gold, alpha: Double(0x55) / 255.0)
    /// Ambient glow under the outline-draw CTA — rgba(201,168,76,0.14).
    static let mrtGoldGlowFaint = Color(hex: Hex.gold, alpha: 0.14)

    // Overlays (Handoff §7)
    /// Confirm-dialog card fill — `#1a1a1c`.
    static let mrtDialogCard = Color(hex: Hex.dialogCard)
    /// Success-toast pill fill — `#22221f`.
    static let mrtToastSurface = Color(hex: Hex.toastSurface)
    /// Full-screen backdrop behind dialogs/sheets — rgba(0,0,0,0.6).
    static let mrtScrim = Color(hex: Hex.black, alpha: 0.6)
    /// Destructive dialog button fill — rgba(255,59,48,0.16).
    static let mrtDangerFill = Color(hex: Hex.danger, alpha: 0.16)
    /// Destructive dialog icon-circle tint — rgba(255,59,48,0.14).
    static let mrtDangerFillSoft = Color(hex: Hex.danger, alpha: 0.14)
    /// Positive dialog icon-circle tint — gold twin of `mrtDangerFillSoft`.
    static let mrtGoldFillSoft = Color(hex: Hex.gold, alpha: 0.14)

    // Brand mark (HexLogo / ArrowMark facets + tile gradient stops)
    static let mrtArrowFacetLight = Color(hex: Hex.arrowFacetLight)
    static let mrtArrowFacetDark = Color(hex: Hex.arrowFacetDark)
    static let mrtLogoTileTop = Color(hex: Hex.logoTileTop)
    static let mrtLogoTileMid = Color(hex: Hex.logoTileMid)
    static let mrtLogoTileBottom = Color(hex: Hex.logoTileBottom)

    // Sign in (screens.jsx SignInScreen + ParticleLine, MYR-164)
    /// Glimpse-line greeting text — rgba(208,201,184,1), the non-live line
    /// color in screens.jsx `ParticleLine.measure()`.
    static let mrtGlimpseCream = Color(hex: Hex.glimpseCream)
    /// Sign-in sheet scrim — rgba(0,0,0,0.5) (screens.jsx SignInScreen
    /// "Scrim" layer; deliberately softer than the 0.6 overlay `mrtScrim`).
    static let mrtScrimSoft = Color(hex: Hex.black, alpha: 0.5)

    // Bottom nav (floating capsule tab bar)
    /// Tab-bar fill — rgba(22,22,25,0.92) in components.jsx BottomNav.
    static let mrtNavBarFill = Color(hex: Hex.navBarFill, alpha: 0.92)
    /// Tab-bar hairline — rgba(255,255,255,0.09).
    static let mrtNavHairline = Color(hex: Hex.text, alpha: 0.09)
    /// Inactive tab tint — rgba(196,172,108,0.62), muted warm gold.
    static let mrtNavInactive = Color(hex: Hex.navInactive, alpha: 0.62)

    // Onboarding (design/app/onboarding.jsx + screens.jsx EmptyScreen, MYR-165)

    /// PairStepper active-step fill — rgba(140,110,42,0.18) (onboarding.jsx:41).
    static let mrtGoldDeepActiveFill = Color(hex: Hex.goldDeep, alpha: 0.18)
    /// PairStepper active-step halo ring — rgba(140,110,42,0.12) (onboarding.jsx:43).
    static let mrtGoldDeepHalo = Color(hex: Hex.goldDeep, alpha: 0.12)
    /// Expanding pulse rings — `#C9A84C44` (onboarding.jsx:240,242,359).
    static let mrtGoldRing = Color(hex: Hex.gold, alpha: Double(0x44) / 255.0)
    /// Paired/joined success-card border — `#C9A84C3a` (onboarding.jsx:374,518).
    static let mrtGoldCardBorder = Color(hex: Hex.gold, alpha: Double(0x3A) / 255.0)
    /// Filled invite-code cell background — rgba(201,168,76,0.10) (onboarding.jsx:460).
    static let mrtGoldCellFill = Color(hex: Hex.gold, alpha: 0.10)
    /// Filled invite-code cell border — `#C9A84C66` (onboarding.jsx:461).
    static let mrtGoldCellBorder = Color(hex: Hex.gold, alpha: Double(0x66) / 255.0)
    /// Active invite-cell focus ring — rgba(201,168,76,0.12) (onboarding.jsx:462).
    static let mrtGoldFocusRing = Color(hex: Hex.gold, alpha: 0.12)
    /// Empty-screen primary card gradient start — `#C9A84C1c` (screens.jsx:272).
    static let mrtGoldCardTint = Color(hex: Hex.gold, alpha: Double(0x1C) / 255.0)
    /// Empty-screen primary card gradient end — `#C9A84C0a` (screens.jsx:272).
    static let mrtGoldCardTintFaint = Color(hex: Hex.gold, alpha: Double(0x0A) / 255.0)
    /// Empty-screen primary icon tile fill — `#C9A84C26` (screens.jsx:276).
    static let mrtGoldIconTile = Color(hex: Hex.gold, alpha: Double(0x26) / 255.0)
    /// Empty-screen quiet card border — `#C9A84C2e` (screens.jsx:273).
    static let mrtGoldBorderQuiet = Color(hex: Hex.gold, alpha: Double(0x2E) / 255.0)

    // Onboarding — virtual key card + linked badge (onboarding.jsx)
    static let mrtKeyCardMid = Color(hex: Hex.keyCardMid)
    static let mrtKeyCardDeep = Color(hex: Hex.keyCardDeep)
    static let mrtEtchLight = Color(hex: Hex.etchLight)
    static let mrtEtchDark = Color(hex: Hex.etchDark)
    static let mrtLinkedGreenLight = Color(hex: Hex.linkedGreenLight)
    static let mrtLinkedCheckStroke = Color(hex: Hex.linkedCheckStroke)

    // Simulated Tesla OAuth sheet (MYR-165 — swapped for
    // ASWebAuthenticationSession by MYR-115)
    static let mrtTeslaRed = Color(hex: Hex.teslaRed)
    static let mrtBrowserBg = Color(hex: Hex.browserBg)
    static let mrtBrowserChrome = Color(hex: Hex.browserChrome)
    static let mrtBrowserText = Color(hex: Hex.browserText)
    static let mrtBrowserTextSec = Color(hex: Hex.browserTextSec)
    static let mrtBrowserTextTert = Color(hex: Hex.browserTextTert)
    static let mrtBrowserTextFaint = Color(hex: Hex.browserTextFaint)
    static let mrtBrowserArrow = Color(hex: Hex.browserArrow)
    static let mrtBrowserSpinner = Color(hex: Hex.browserSpinner)
    static let mrtBrowserGlyph = Color(hex: Hex.browserGlyph)
    static let mrtLinkBlue = Color(hex: Hex.linkBlue)
    static let mrtConsentGreen = Color(hex: Hex.consentGreen)

    // MYR-166 — tutorials (design/app/tutorials.jsx) — StoryDeck vignette shell
    // MiniScreen card gradient: linear-gradient(160deg, rgba(34,34,40,0.9), rgba(16,16,20,0.92)) (tutorials.jsx:12).
    static let mrtVigCardTop = Color(hex: Hex.vigCardTop, alpha: 0.9)
    static let mrtVigCardBottom = Color(hex: Hex.vigCardBottom, alpha: 0.92)
    /// MiniScreen border — rgba(255,255,255,0.10) (tutorials.jsx:13).
    static let mrtVigCardBorder = Color(hex: Hex.text, alpha: 0.10)
    /// List-row fill shared by every vignette's rows (drives/sharing/history/
    /// shared-cars/request) — rgba(255,255,255,0.05) (tutorials.jsx:59 et al.).
    static let mrtVigRowFill = Color(hex: Hex.text, alpha: 0.05)
    /// List-row border — rgba(255,255,255,0.08) (tutorials.jsx:59 et al.).
    static let mrtVigRowBorder = Color(hex: Hex.text, alpha: 0.08)
    /// Search-bar / Decline-button fill — rgba(255,255,255,0.06)
    /// (tutorials.jsx:127,163).
    static let mrtVigControlFill = Color(hex: Hex.text, alpha: 0.06)
    /// Search-bar / Decline-button border — rgba(255,255,255,0.12)
    /// (tutorials.jsx:127,163).
    static let mrtVigControlBorder = Color(hex: Hex.text, alpha: 0.12)
    /// Climate-tile off-state fill — rgba(255,255,255,0.04) (tutorials.jsx:148).
    static let mrtVigTileOff = Color(hex: Hex.text, alpha: 0.04)
    /// Drive/ride-history icon-tile fill — rgba(201,168,76,0.12)
    /// (tutorials.jsx:60,223).
    static let mrtGoldTileFaint = Color(hex: Hex.gold, alpha: 0.12)
    /// Status-pill fill — rgba(20,20,24,0.66) (tutorials.jsx:35,192).
    static let mrtVigStatusPill = Color(hex: Hex.vigStatusPill, alpha: 0.66)

    // MYR-167 — Live Map (design/app/screens.jsx HomeScreen/MapHeader/
    // FloatingMapButton, real MapKit screen — distinct from the MYR-166
    // MapBackground vignette tokens below).
    /// Vehicle-switcher chip fill — rgba(20,20,24,0.72) (screens.jsx:307).
    static let mrtMapChipFill = Color(hex: Hex.mapChipFill, alpha: 0.72)
    /// Chip/picker hairline border, resting — rgba(255,255,255,0.14)
    /// (screens.jsx:308,325).
    static let mrtMapChipBorder = Color(hex: Hex.text, alpha: 0.14)
    /// Chip hairline border, picker open — `#C9A84C77` (screens.jsx:308).
    static let mrtMapChipBorderActive = Color(hex: Hex.gold, alpha: Double(0x77) / 255.0)
    /// Chip disclosure-chevron circle fill — rgba(255,255,255,0.08) (screens.jsx:313).
    static let mrtMapChipChevronFill = Color(hex: Hex.text, alpha: 0.08)
    /// Picker menu fill — rgba(24,24,28,0.92) (screens.jsx:324).
    static let mrtMapPickerFill = Color(hex: Hex.mapPickerFill, alpha: 0.92)
    /// Picker row divider — rgba(255,255,255,0.07) (screens.jsx:333).
    static let mrtMapPickerDivider = Color(hex: Hex.text, alpha: 0.07)
    /// Active picker row wash — `#C9A84C14` (screens.jsx:332).
    static let mrtMapPickerRowActive = Color(hex: Hex.gold, alpha: Double(0x14) / 255.0)
    /// Active picker row icon-tile fill — `#C9A84C22` (screens.jsx:335).
    static let mrtMapPickerIconActive = Color(hex: Hex.gold, alpha: Double(0x22) / 255.0)
    /// Inactive picker row icon-tile fill — rgba(255,255,255,0.06) (screens.jsx:335).
    static let mrtMapPickerIconInactive = Color(hex: Hex.text, alpha: 0.06)
    /// Floating recenter-button fill — rgba(17,17,17,0.85), the flat
    /// `floatBtn` surface (design.jsx:95).
    static let mrtFloatButtonFill = Color(hex: Hex.bgSecondary, alpha: 0.85)
    /// Compass N/S/E/W labels — rgba(255,255,255,0.25) (components.jsx:407).
    static let mrtMapCompassLabel = Color(hex: Hex.text, alpha: 0.25)

    // MYR-166 — map backdrop (design/app/components.jsx MapBackground),
    // ported for the story-deck live-map vignettes.
    static let mrtMapLand = Color(hex: Hex.mapLand)
    static let mrtMapPark = Color(hex: Hex.mapPark)
    static let mrtMapStreet = Color(hex: Hex.mapStreet)
    static let mrtMapCollectorCasing = Color(hex: Hex.mapCollectorCasing)
    static let mrtMapCollectorFill = Color(hex: Hex.mapCollectorFill)
    static let mrtMapFreewayCasing = Color(hex: Hex.mapFreewayCasing)
    static let mrtMapFreewayFill = Color(hex: Hex.mapFreewayFill)
    static let mrtMapWater = Color(hex: Hex.mapWater)
    static let mrtMapCoast = Color(hex: Hex.mapCoast)
    /// "Pacific Ocean" label — rgba(150,180,210,0.36) (components.jsx:389).
    static let mrtMapLabelOcean = Color(hex: Hex.mapLabelOcean, alpha: 0.36)
    /// Park-name label — rgba(150,200,150,0.4) (components.jsx:390).
    static let mrtMapLabelPark = Color(hex: Hex.mapLabelPark, alpha: 0.4)
    /// Street-name label — rgba(255,255,255,0.26) (components.jsx:391).
    static let mrtMapLabelStreet = Color(hex: Hex.text, alpha: 0.26)
}

// MARK: - Hex init

extension Color {
    /// Builds a display-P3-agnostic sRGB color from a 24-bit RGB hex value.
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
