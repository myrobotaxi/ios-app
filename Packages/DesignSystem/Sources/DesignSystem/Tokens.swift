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

    // Bottom nav (floating capsule tab bar)
    /// Tab-bar fill — rgba(22,22,25,0.92) in components.jsx BottomNav.
    static let mrtNavBarFill = Color(hex: Hex.navBarFill, alpha: 0.92)
    /// Tab-bar hairline — rgba(255,255,255,0.09).
    static let mrtNavHairline = Color(hex: Hex.text, alpha: 0.09)
    /// Inactive tab tint — rgba(196,172,108,0.62), muted warm gold.
    static let mrtNavInactive = Color(hex: Hex.navInactive, alpha: 0.62)
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
