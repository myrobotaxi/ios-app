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
