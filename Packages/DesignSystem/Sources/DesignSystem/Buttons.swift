import SwiftUI

// MARK: - MRTButton — the shared 6-variant button
//
// Flat-only port of the prototype's `Button` (design/app/components.jsx,
// Handoff §3). Liquid Glass is out of scope (product decision, 2026-07-06):
// the corner radius is always `MRTMetrics.controlRadius` (12) — never pill —
// and the jsx `flat` prop's goldDeep treatment is exposed as `flatOnboarding`.
//
// Variants (fills/borders/labels verbatim from the jsx variants table):
//   gold           solid gold, near-black label            — primary commit
//   outline        transparent, gold border + label        — secondary
//   outline-muted  transparent, hairline border, white     — tertiary/cancel
//   outline-draw   faint gold wash + ANIMATED border trace — ride CTAs ONLY
//   outline-static faint gold wash + static gold outline   — onboarding CTAs
//   ghost          transparent, secondary label            — inline actions

public enum MRTButtonVariant: String, CaseIterable, Sendable {
    case gold
    case outline
    case outlineMuted = "outline-muted"
    /// Animated gold border trace (2.6s loop) + pulsing gold label.
    /// **Reserved for the in-app ride-request CTAs only** (Request from…,
    /// Confirm pickup, Accept & send, See you soon) — the "actionable moment"
    /// treatment. Do not use anywhere else. Honors Reduce Motion: the trace
    /// freezes to a static gold gradient border and the label pulse stops.
    case outlineDraw = "outline-draw"
    /// The resting look of outline-draw, no animation — onboarding + tutorial
    /// CTAs (Sign in with Tesla, Open Tesla app, Continue, …).
    case outlineStatic = "outline-static"
    case ghost
}

public enum MRTButtonSize: Sendable {
    case sm, md, lg

    /// Visual control height (Handoff §3: sm 38 · md 46 · lg 52). Sizes under
    /// 44pt keep a 44pt hit target via an expanded content shape.
    public var height: CGFloat {
        switch self {
        case .sm: 38
        case .md: 46
        case .lg: 52
        }
    }
}

/// The shared MyRoboTaxi button. All chrome comes from DesignSystem tokens.
///
///     MRTButton("Confirm pickup", variant: .outlineDraw) { … }
///     MRTButton("Cancel", variant: .outlineMuted, size: .sm, fullWidth: false) { … }
///
/// - `flatOnboarding` ports the jsx `flat` prop: gold renders on `goldDeep`
///   with a `#1c1505` label, outline renders goldDeepSoft-on-goldDeep-border
///   (the deep antique gold-brown onboarding treatment).
/// - `leadingIcon` / `trailingIcon` are SF Symbol names (Handoff §4 maps every
///   prototype icon 1:1 to an SF Symbol).
public struct MRTButton: View {
    private let title: String
    private let variant: MRTButtonVariant
    private let size: MRTButtonSize
    private let fullWidth: Bool
    private let flatOnboarding: Bool
    private let leadingIcon: String?
    private let trailingIcon: String?
    private let action: () -> Void

    public init(
        _ title: String,
        variant: MRTButtonVariant = .gold,
        size: MRTButtonSize = .md,
        fullWidth: Bool = true,
        flatOnboarding: Bool = false,
        leadingIcon: String? = nil,
        trailingIcon: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
        self.flatOnboarding = flatOnboarding
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            MRTButtonChrome(
                title: title,
                variant: variant,
                size: size,
                fullWidth: fullWidth,
                flatOnboarding: flatOnboarding,
                leadingIcon: leadingIcon,
                trailingIcon: trailingIcon
            )
        }
        .buttonStyle(MRTPressScaleButtonStyle())
    }
}

// MARK: - Press scale

/// Press → scale 0.98 (Handoff §3). Shared by MRTButton and the dialog's
/// destructive button.
struct MRTPressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Chrome

private struct MRTButtonChrome: View {
    let title: String
    let variant: MRTButtonVariant
    let size: MRTButtonSize
    let fullWidth: Bool
    let flatOnboarding: Bool
    let leadingIcon: String?
    let trailingIcon: String?

    /// Font 15/±600, tracking -0.1 (Handoff §3); scales with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
            }
            Text(title)
            if let trailingIcon {
                Image(systemName: trailingIcon)
            }
        }
        .font(.system(size: fontSize, weight: fontWeight))
        .tracking(-0.1)
        .lineLimit(1)
        .modifier(MRTButtonLabelColor(variant: variant, flatOnboarding: flatOnboarding))
        .padding(.horizontal, 18)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(height: size.height)
        .background(fill, in: shape)
        .overlay(borderOverlay.allowsHitTesting(false))
        .shadow(
            color: variant == .outlineDraw ? .mrtGoldGlowFaint : .clear,
            radius: 8
        )
        // 44pt minimum hit target: expand the tappable shape (not the layout)
        // for the 38pt small size.
        .contentShape(Rectangle().inset(by: min(0, (size.height - MRTMetrics.minTapTarget) / 2)))
    }

    private var fontWeight: Font.Weight {
        switch variant {
        case .gold, .outlineDraw, .outlineStatic: .semibold // 600
        default: .medium // 500
        }
    }

    private var fill: Color {
        if flatOnboarding, variant == .gold { return .mrtGoldDeep }
        switch variant {
        case .gold: return .mrtGold
        case .outlineDraw, .outlineStatic: return .mrtGoldFillFaint
        case .outline, .outlineMuted, .ghost: return .clear
        }
    }

    @ViewBuilder private var borderOverlay: some View {
        if variant == .outlineDraw {
            MRTTraceBorder(shape: shape)
        } else if let borderColor {
            shape.strokeBorder(borderColor, lineWidth: 1)
        }
    }

    private var borderColor: Color? {
        if flatOnboarding {
            if variant == .gold { return nil }
            if variant == .outline { return .mrtGoldDeep }
        }
        switch variant {
        case .gold, .ghost, .outlineDraw: return nil
        case .outline: return .mrtGold
        case .outlineStatic: return .mrtGoldBorderSoft
        case .outlineMuted: return .mrtBorder
        }
    }
}

// MARK: - Label color (static, or pulsing gold for outline-draw)

private struct MRTButtonLabelColor: ViewModifier {
    let variant: MRTButtonVariant
    let flatOnboarding: Bool

    func body(content: Content) -> some View {
        if variant == .outlineDraw {
            content.modifier(MRTGoldPulse())
        } else {
            content.foregroundStyle(staticColor)
        }
    }

    private var staticColor: Color {
        if flatOnboarding {
            if variant == .gold { return .mrtGoldDeepButtonLabel }
            if variant == .outline { return .mrtGoldDeepSoft }
        }
        switch variant {
        case .gold: return .mrtGoldButtonLabel
        case .outline, .outlineStatic: return .mrtGold
        case .outlineMuted: return .mrtText
        case .ghost: return .mrtTextSec
        case .outlineDraw: return .mrtGold // unreachable; pulse handles it
        }
    }
}

/// Port of `mrt-gold-pulse` (components.jsx MRT_STYLES): the label breathes
/// gold → #F0D27A with a soft glow, 2.4s ease-in-out loop. Reduce Motion →
/// static #F0D27A, no glow animation (the jsx `prefers-reduced-motion` block).
private struct MRTGoldPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content.foregroundStyle(Color.mrtGoldPulse)
        } else {
            content
                .foregroundStyle(pulsing ? Color.mrtGoldPulse : .mrtGold)
                .shadow(color: .mrtGoldPulse.opacity(pulsing ? 0.55 : 0), radius: 7)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
        }
    }
}

// MARK: - Border trace (outline-draw)

/// Port of `mrt-trace-spin` (components.jsx MRT_STYLES `.mrt-draw-btn`): a
/// bright highlight travels around the border on a 2.6s linear loop —
/// a conic gradient stroke (the ::before layer) plus a blurred comet glow
/// riding just outside it (the ::after layer). Reduce Motion → static
/// #E7C975→gold gradient border at 0.85 opacity, comet hidden (the jsx
/// `prefers-reduced-motion` fallback).
struct MRTTraceBorder: View {
    let shape: RoundedRectangle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// conic-gradient stops of `.mrt-draw-btn::before` (degrees ÷ 360).
    static let traceStops: [Gradient.Stop] = [
        .init(color: .mrtGoldGlowSoft, location: 0), //   0° rgba(201,168,76,0.30)
        .init(color: .mrtGoldGlowSoft, location: 70.0 / 360.0),
        .init(color: .mrtGoldTrace, location: 120.0 / 360.0), // #E7C975
        .init(color: .mrtGoldTraceBright, location: 150.0 / 360.0), // #FFF3C8
        .init(color: .mrtGoldTrace, location: 180.0 / 360.0),
        .init(color: .mrtGoldGlowSoft, location: 240.0 / 360.0),
        .init(color: .mrtGoldGlowSoft, location: 1),
    ]

    /// conic-gradient stops of the comet layer `.mrt-draw-btn::after`.
    static let cometStops: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 120.0 / 360.0),
        .init(color: .mrtGoldTraceBright.opacity(0.5), location: 150.0 / 360.0),
        .init(color: .clear, location: 180.0 / 360.0),
        .init(color: .clear, location: 1),
    ]

    var body: some View {
        if reduceMotion {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.mrtGoldTrace, .mrtGold],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .opacity(0.85)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let angle = Angle.degrees(t.truncatingRemainder(dividingBy: 2.6) / 2.6 * 360)
                ZStack {
                    // Comet glow riding just outside the border (::after).
                    shape
                        .inset(by: -1)
                        .stroke(
                            AngularGradient(stops: Self.cometStops, center: .center, angle: angle),
                            lineWidth: 2
                        )
                        .blur(radius: 4)
                    // The border trace itself (::before).
                    shape
                        .strokeBorder(
                            AngularGradient(stops: Self.traceStops, center: .center, angle: angle),
                            lineWidth: 1.5
                        )
                }
            }
        }
    }
}
