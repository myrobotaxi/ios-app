import SwiftUI
import DesignSystem

// MARK: - Shared onboarding chrome (MYR-165 — design/app/onboarding.jsx)
//
// The bits every onboarding surface shares: the brand gold wash, the ghost
// top-right Cancel, the expanding pulse rings, the celebration bloom /
// check-pop / card-rise, and the spinner. All motion honors Reduce Motion
// with static fallbacks (CLAUDE.md hard rule; the jsx animations are inline
// styles, so the fallback design is ours: loops freeze to their resting
// look, one-shot entrances become plain fades).

// MARK: Gold wash

/// Brand gold wash shared by every onboarding surface (onboarding.jsx:10-13;
/// EmptyScreen uses the 380pt variant, screens.jsx:261):
/// radial-gradient(140% 100% at 50% -20%, goldGlow3 0%, transparent 65%).
struct OnboardingGoldWash: View {
    var height: CGFloat = 360

    var body: some View {
        RadialGradient(
            stops: [
                .init(color: .mrtGoldGlowSoft, location: 0),
                .init(color: Color.mrtGoldGlowSoft.opacity(0), location: 0.65),
            ],
            center: UnitPoint(x: 0.5, y: -0.2),
            startRadius: 0,
            endRadius: height
        )
        // rx = 140% of width vs ry = height ⇒ stretch x around the gradient
        // center to make the CSS ellipse (same approach as SignInScreen).
        .scaleEffect(x: 1.48, y: 1, anchor: UnitPoint(x: 0.5, y: -0.2))
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

// MARK: Top action

/// Small ghost "Skip / Cancel" affordance, top-right (onboarding.jsx:16-24;
/// top 82, right 20, 15/500 textSec). Padded out to the 44pt hit target.
struct OnboardingTopAction: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .padding(6)
                .frame(minWidth: MRTMetrics.minTapTarget, minHeight: MRTMetrics.minTapTarget)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, MRTMetrics.onboardingTopActionTop - 6)
        .padding(.trailing, 20 - 6)
    }
}

// MARK: Expanding pulses

/// A set of staggered, endlessly expanding stroked shapes — `mrtRingPulse`
/// (scale 0.4→2.6, opacity 0.7→0) and `mrtCardPulse` (0.92→1.5, 0.55→0),
/// onboarding.jsx:216,223. Delayed rings stay hidden until their first cycle
/// (CSS `animation-fill-mode: backwards` reading). Reduce Motion → a single
/// static shape at rest size.
struct ExpandingPulse<S: InsettableShape>: View {
    let shape: S
    var size: CGSize
    var color: Color
    var lineWidth: CGFloat = 1
    var duration: Double
    var delays: [Double] = [0]
    var scaleFrom: CGFloat = 0.4
    var scaleTo: CGFloat = 2.6
    var opacityFrom: Double = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if reduceMotion {
            staticShape
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                ZStack {
                    ForEach(delays.indices, id: \.self) { index in
                        let local = elapsed - delays[index]
                        if local >= 0 {
                            let phase = (local.truncatingRemainder(dividingBy: duration)) / duration
                            let p = UnitCurve.easeOut.value(at: phase) // CSS ease-out
                            shape
                                .strokeBorder(color, lineWidth: lineWidth)
                                .frame(width: size.width, height: size.height)
                                .scaleEffect(scaleFrom + (scaleTo - scaleFrom) * p)
                                .opacity(opacityFrom * (1 - p))
                        }
                    }
                }
            }
        }
    }

    private var staticShape: some View {
        shape
            .strokeBorder(color, lineWidth: lineWidth)
            .frame(width: size.width, height: size.height)
    }
}

// MARK: Fade-up entrance

/// `mrtFadeUp` (onboarding.jsx:220): opacity 0→1, translateY 12→0, ease,
/// with a start delay ("both" fill). Reduce Motion → fade only.
struct FadeUp: ViewModifier {
    var duration: Double = 0.5
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                withAnimation(
                    .timingCurve(0.25, 0.1, 0.25, 1, duration: duration).delay(delay)
                ) {
                    shown = true
                }
            }
    }
}

extension View {
    func mrtFadeUp(duration: Double = 0.5, delay: Double = 0) -> some View {
        modifier(FadeUp(duration: duration, delay: delay))
    }
}

// MARK: Success celebration pieces (PairedSuccess / JoinedSuccess)

/// `mrtPairBloom` (onboarding.jsx:217): a gold radial that blasts out once —
/// scale 0.2→3.4, opacity 0→0.9 (at 30%)→0, 0.9s cubic-bezier(0.4,0,0.2,1).
/// Reduce Motion → skipped entirely (decorative).
struct SuccessBloom: View {
    var diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fired = false

    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.4, y: 0),
        endControlPoint: UnitPoint(x: 0.2, y: 1)
    )

    var body: some View {
        if !reduceMotion {
            RadialGradient(
                stops: [
                    .init(color: .mrtGold, location: 0),
                    .init(color: Color.mrtGold.opacity(0.4), location: 0.34),
                    .init(color: Color.mrtGold.opacity(0), location: 0.68),
                ],
                center: .center,
                startRadius: 0,
                endRadius: diameter / 2
            )
            .frame(width: diameter, height: diameter)
            .keyframeAnimator(initialValue: BloomValues(), trigger: fired) { view, values in
                // initialValue starts at opacity 0, so nothing shows until
                // the trigger fires.
                view
                    .scaleEffect(values.scale)
                    .opacity(values.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(3.4, duration: 0.9, timingCurve: Self.curve)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.9, duration: 0.9 * 0.3, timingCurve: Self.curve)
                    LinearKeyframe(0, duration: 0.9 * 0.7, timingCurve: Self.curve)
                }
            }
            .onAppear { fired = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private struct BloomValues {
        var scale: CGFloat = 0.2
        var opacity: Double = 0
    }
}

/// The 72pt gold check disc with `mrtCheckPop` (onboarding.jsx:219,363-367):
/// scale 0→1.18 (at 60%)→1, 0.5s cubic-bezier(0.34,1.56,0.64,1).
/// Reduce Motion → static.
struct SuccessCheckBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false

    var body: some View {
        if reduceMotion {
            core
        } else {
            core
                .keyframeAnimator(initialValue: 0.0, trigger: popped) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(1.18, duration: 0.3)
                        CubicKeyframe(1.0, duration: 0.2)
                    }
                }
                .onAppear { popped = true }
        }
    }

    private var core: some View {
        ZStack {
            Circle().fill(Color.mrtGold)
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold)) // SFIcon 36 / weight 2.6
                .foregroundStyle(Color.mrtGoldButtonLabel) // #1a1408
        }
        .frame(width: 72, height: 72)
        // 0 10px 34px goldGlow6 (CSS blur halved for SwiftUI sigma)
        .shadow(color: .mrtGoldGlow, radius: 17, x: 0, y: 10)
    }
}

/// `mrtCardRise` (onboarding.jsx:218): opacity 0→1, translateY 22→0,
/// scale 0.96→1, 0.55s cubic-bezier(0.22,1,0.36,1); the flows trigger it
/// after their reveal delay. Reduce Motion → fade only.
struct CardRise: ViewModifier {
    /// Delay before the card reveals (jsx `setTimeout(setShowCard)`).
    var after: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 22)
            .scaleEffect(shown || reduceMotion ? 1 : 0.96)
            .task {
                try? await Task.sleep(for: .milliseconds(Int(after * 1000)))
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.55)) {
                    shown = true
                }
            }
    }
}

/// The paired/joined vehicle-card chrome (onboarding.jsx:372-375,516-519):
/// gold-tinted 160° gradient, gold3a hairline, deep drop shadow, radius 20.
struct SuccessCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        content
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [.mrtGoldFillSoft, Color.mrtText.opacity(0.03)],
                        startPoint: HexLogo.tileGradientStart160,
                        endPoint: HexLogo.tileGradientEnd160
                    )
                )
            }
            .overlay(shape.strokeBorder(Color.mrtGoldCardBorder, lineWidth: MRTMetrics.hairline))
            // 0 16px 40px rgba(0,0,0,0.45)
            .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 16)
    }
}

extension HexLogo {
    /// CSS `linear-gradient(160deg, …)` endpoints (same math as the brand
    /// tile's 155°): dx = sin(160°)/2, dy = -cos(160°)/2.
    static let tileGradientStart160 = UnitPoint(x: 0.5 - 0.1710, y: 0.5 - 0.4698)
    static let tileGradientEnd160 = UnitPoint(x: 0.5 + 0.1710, y: 0.5 + 0.4698)
}

// MARK: Spinner

/// The CSS border-spinner: a faint full ring with a highlighted top arc,
/// rotating linearly (`mrtBrowserSpin`, onboarding.jsx:214). Reduce Motion →
/// static arc.
struct SpinnerRing: View {
    var diameter: CGFloat
    var lineWidth: CGFloat
    var trackColor: Color
    var color: Color
    var period: Double = 0.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ring(angle: .zero)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ring(angle: .degrees(t.truncatingRemainder(dividingBy: period) / period * 360))
            }
        }
    }

    private func ring(angle: Angle) -> some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90) + angle) // border-top-color start
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: Fixtures (M1 — mirrors onboarding.jsx fallbacks + screens.jsx mocks)

/// The vehicle the pairing flow celebrates — `VEHICLES[0]`
/// (design/app/screens.jsx:10, mirrored in onboarding.jsx:198).
struct PairedVehicleFixture {
    let name = "Cybercab"
    let model = "2026 Tesla Cybercab"
    let color = "Mercury Silver"
    let plate = "RBO-2046"
}

/// The host the invite flow joins — `FLEET[0]`
/// (design/app/screens.jsx:16, mirrored in onboarding.jsx:414).
struct InviteHostFixture {
    let owner = "Alex"
    let relationship = "Roommate"
    let name = "Model Y"
    let model = "2025 Tesla Model Y"
}
