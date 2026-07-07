import Foundation
import SwiftUI

// MARK: - Avatar (components.jsx) — initials circle, stable hue from name

public struct Avatar: View {
    private let name: String
    private let size: CGFloat
    private let online: Bool

    public init(name: String = "?", size: CGFloat = 36, online: Bool = false) {
        self.name = name
        self.size = size
        self.online = online
    }

    /// JS: `name.split(' ').map(s => s[0]).slice(0, 2).join('').toUpperCase()`
    static func initials(for name: String) -> String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }

    /// JS: `name.split('').reduce((a, c) => a + c.charCodeAt(0), 0) % 360`
    /// — UTF-16 code units, identical to Swift's `utf16` view, so the hue
    /// (and color) matches the prototype for any name.
    static func hue(for name: String) -> Int {
        name.utf16.reduce(0) { $0 + Int($1) } % 360
    }

    /// CSS `oklch(0.4 0.08 hue)` for this name.
    static func color(for name: String) -> Color {
        oklch(l: 0.4, c: 0.08, hueDegrees: Double(hue(for: name)))
    }

    /// Exact CSS Color 4 OKLCH → sRGB conversion (OKLab → LMS → linear sRGB),
    /// so avatar colors match the prototype rather than approximating with HSB.
    static func oklch(l: Double, c: Double, hueDegrees: Double) -> Color {
        let h = hueDegrees * .pi / 180
        let a = c * cos(h)
        let b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_
        let M = m_ * m_ * m_
        let S = s_ * s_ * s_
        let rLin = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let gLin = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bLin = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(.sRGB, red: gamma(rLin), green: gamma(gLin), blue: gamma(bLin), opacity: 1)
    }

    public var body: some View {
        ZStack {
            Circle().fill(Self.color(for: name))
            Text(Self.initials(for: name))
                .font(.system(size: size * 0.36, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(Color.mrtText)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if online {
                // driving-green dot with a 2pt `bg` ring
                Circle()
                    .fill(Color.mrtDriving)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .padding(2)
                    .background(Circle().fill(Color.mrtBg))
            }
        }
    }
}
