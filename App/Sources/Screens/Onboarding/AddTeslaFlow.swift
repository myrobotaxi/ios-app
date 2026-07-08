import SwiftUI
import DesignSystem

// MARK: - Add Your Tesla — owner pairing (MYR-165 — Handoff §5.2,
// design/app/onboarding.jsx:195-401)
//
// intro → (in-app browser auth + consent) → linked → key → waiting → paired,
// tracked by the persistent PairStepper. M1 is fully simulated: the browser
// is the prototype's faux Tesla sheet and the Tesla-app handoff is a timer.
// MYR-115 swaps the browser for ASWebAuthenticationSession through the
// `authenticate` seam (see TeslaAuth.swift) and the timer for real
// virtual-key (BLE) enrollment.
//
// Motion (jsx @keyframes → Handoff §8):
//   mrtRingPulse 2.6s ease-out ×2 (1.3s stagger) — intro rings
//   sheet spring .42s / dampening .86        — browser slide
//   mrtBadgePop + mrtBadgeRing + mrtCheckDraw + mrtTextWord — linked beat
//   mrtShimmer 2.8s (jsx:282; Handoff §5.2 says 2.4s — jsx wins) — key card
//   mrtKeyFloat 1.8s + mrtCardPulse 1.8s ×2 + mrtWaitDot 1.4s — waiting
//   mrtPairBloom .9s + mrtRingPulse 2.2s ×3 + mrtCheckPop + mrtCardRise — paired
struct AddTeslaFlow: View {
    let onComplete: () -> Void
    let onCancel: () -> Void
    /// MYR-115 seam — nil (M1) presents the simulated sheet instead.
    var authenticate: TeslaAuthenticator?

    private enum Phase {
        case intro, linked, key, waiting, paired
    }

    @State private var phase: Phase = .intro
    @State private var browserOpen = false
    private let vehicle = PairedVehicleFixture()

    /// jsx:200 — stepper index per phase; the open browser pins step 1.
    private var stepperStep: Int {
        if browserOpen { return 1 }
        switch phase {
        case .intro: return 0
        case .linked, .key, .waiting: return 2
        case .paired: return 3
        }
    }

    var body: some View {
        ZStack {
            Color.mrtBg
            OnboardingGoldWash()

            switch phase {
            case .intro:
                intro
            case .linked:
                LinkedTransitionView {
                    phase = .key
                }
            case .key, .waiting:
                keyAndWaiting
            case .paired:
                PairedSuccessView(vehicle: vehicle, onContinue: onComplete)
            }

            PairStepper(step: stepperStep)
                .padding(.horizontal, MRTMetrics.pairStepperGutter)
                .padding(.top, MRTMetrics.pairStepperTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            if phase == .intro {
                OnboardingTopAction(label: "Cancel", action: onCancel)
            }

            // In-app browser — mounted even while closed so the slide-out
            // plays (jsx keeps it in the tree with pointerEvents gated).
            SimulatedTeslaAuthSheet(
                open: browserOpen,
                onGranted: {
                    // jsx:204 — dismiss the instant access is granted.
                    browserOpen = false
                    phase = .linked
                },
                onCancel: { browserOpen = false }
            )
        }
        // jsx positions everything from the physical screen edges; keep the
        // keyboard safe-area region so the password field stays reachable.
        .ignoresSafeArea(.container)
    }

    // MARK: Intro (jsx:234-255)

    private var intro: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                ExpandingPulse(
                    shape: Circle(),
                    size: CGSize(width: 130, height: 130),
                    color: .mrtGoldRing,
                    duration: 2.6,
                    delays: [0, 1.3]
                )
                HexLogo(size: 76, glow: true)
            }
            .padding(.bottom, 34)
            Text("Connect your Tesla")
                .font(.system(size: 25, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 12)
            Text("Sign in with your Tesla account to securely link your vehicle. You'll grant access, then approve a virtual key — it only takes a minute.")
                .font(.system(size: 14.5))
                .lineSpacing(14.5 * 0.55) // line-height 1.55
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            Spacer(minLength: 0)

            MRTButton("Sign in with Tesla", variant: .outlineStatic) {
                signInTapped()
            }
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtTextMuted)
                Text("Secured by Tesla — we never see your password.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.top, 16)
        }
        .padding(.top, 196)
        .padding(.horizontal, MRTMetrics.onboardingGutter)
        .padding(.bottom, 38)
        .mrtFadeUp(duration: 0.4)
    }

    private func signInTapped() {
        if let authenticate {
            // MYR-115 path: system-presented real OAuth.
            Task { @MainActor in
                if await authenticate() == .granted {
                    phase = .linked
                }
            }
        } else {
            browserOpen = true // M1: simulated sheet
        }
    }

    // MARK: Virtual key + waiting (jsx:261-310)

    private var keyAndWaiting: some View {
        let waiting = phase == .waiting
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                if waiting {
                    ExpandingPulse(
                        shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                        size: CGSize(width: 176, height: 112),
                        color: .mrtGoldBorderSoft,
                        lineWidth: 1.5,
                        duration: 1.8,
                        delays: [0, 0.9],
                        scaleFrom: 0.92,
                        scaleTo: 1.5,
                        opacityFrom: 0.55
                    )
                }
                VirtualKeyCard()
                    .modifier(KeyFloat(active: waiting))
            }
            .padding(.bottom, 30)

            if waiting {
                Text("Waiting for approval…")
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 10)
                Text("Approve the virtual key request in the Tesla app to finish pairing.")
                    .font(.system(size: 13.5))
                    .lineSpacing(13.5 * 0.5)
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                WaitDots()
                    .padding(.top, 18)
                Text("Simulating Tesla-app handoff…")
                    .font(.system(size: 10.5))
                    .italic()
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.top, 20)
            } else {
                Text("Authorize a virtual key")
                    .font(.system(size: 23, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 12)
                (
                    Text("Open the Tesla app and approve the key request. This lets MyRoboTaxi unlock, command, and dispatch your ")
                    + Text(vehicle.name).fontWeight(.semibold).foregroundColor(.mrtText)
                    + Text(".")
                )
                .font(.system(size: 14))
                .lineSpacing(14 * 0.55)
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 296)
            }
            Spacer(minLength: 0)

            if !waiting {
                MRTButton("Open Tesla app", variant: .outlineStatic, trailingIcon: "arrow.up.right") {
                    phase = .waiting // jsx:206-209 — simulated handoff
                }
            }
        }
        .padding(.top, 196)
        .padding(.horizontal, MRTMetrics.onboardingGutter)
        .padding(.bottom, 38)
        .mrtFadeUp(duration: 0.4)
        .task(id: waiting) {
            guard waiting else { return }
            try? await Task.sleep(for: .milliseconds(2400))
            phase = .paired
        }
    }
}

// MARK: - Virtual key card (jsx:266-289)

/// Matte-black key card with a centered gold-etched wordmark and a periodic
/// shimmer sweep — reads as etched metal catching light.
private struct VirtualKeyCard: View {
    // CSS linear-gradient(155deg): dx = sin(155°)/2, dy = -cos(155°)/2
    // (same math as the brand tile in DesignSystem/BrandMarks).
    private static let gradientStart155 = UnitPoint(x: 0.5 - 0.2113, y: 0.5 - 0.4532)
    private static let gradientEnd155 = UnitPoint(x: 0.5 + 0.2113, y: 0.5 + 0.4532)

    var body: some View {
        ZStack {
            // linear-gradient(155deg, #1a1a1a 0%, #0d0d0d 52%, #050505 100%)
            LinearGradient(
                stops: [
                    .init(color: .mrtSurface, location: 0),
                    .init(color: .mrtKeyCardMid, location: 0.52),
                    .init(color: .mrtKeyCardDeep, location: 1),
                ],
                startPoint: Self.gradientStart155,
                endPoint: Self.gradientEnd155
            )
            MRTShimmerBand()
            // Centered metallic-etched wordmark. jsx asks for Roboto; per the
            // documented Inter→SF Pro deviation the native app uses SF.
            Text("myrobotaxi")
                .font(.system(size: 17, weight: .medium))
                .tracking(2.4)
                .textCase(.uppercase)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .mrtEtchLight, location: 0),
                            .init(color: .mrtGold, location: 0.48),
                            .init(color: .mrtEtchDark, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.6), radius: 0.25, x: 0, y: 0.5)
        }
        .frame(width: 176, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mrtText.opacity(0.10), lineWidth: MRTMetrics.hairline)
        )
        // 0 16px 36px rgba(0,0,0,0.6) + 0 0 26px goldGlow3 (blur halved)
        .shadow(color: .black.opacity(0.6), radius: 18, x: 0, y: 16)
        .shadow(color: .mrtGoldGlowSoft, radius: 13)
    }
}

// `mrtShimmer` (jsx:222, applied at 2.8s ease-in-out infinite, jsx:282) —
// MYR-199 lifted the implementation to `DesignSystem.MRTShimmerBand`
// (reused by the tracking flow's plate-chip shimmer); `VirtualKeyCard` above
// just points at it now.

/// `mrtKeyFloat` (jsx:215): the card bobs ±7pt while waiting, 1.8s
/// ease-in-out. Reduce Motion → static.
private struct KeyFloat: ViewModifier {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .offset(y: up ? -7 : 0)
            .onChange(of: active, initial: true) { _, isActive in
                if isActive && !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        up = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { up = false }
                }
            }
    }
}

/// `mrtWaitDot` (jsx:221,302-303): three 7pt gold dots breathing
/// 0.25→1→0.25 over 1.4s, staggered 0.18s. Reduce Motion → static dots.
private struct WaitDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if reduceMotion {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in dot.opacity(0.6) }
            }
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        dot.opacity(opacity(elapsed: elapsed, index: index))
                    }
                }
            }
        }
    }

    private var dot: some View {
        Circle().fill(Color.mrtGold).frame(width: 7, height: 7)
    }

    /// keyframes: 0%,80%,100% → 0.25 · 40% → 1 (ease-in-out between).
    private func opacity(elapsed: TimeInterval, index: Int) -> Double {
        let local = elapsed - Double(index) * 0.18
        guard local >= 0 else { return 0.25 }
        let phase = local.truncatingRemainder(dividingBy: 1.4) / 1.4
        if phase < 0.4 {
            return 0.25 + 0.75 * UnitCurve.easeInOut.value(at: phase / 0.4)
        } else if phase < 0.8 {
            return 1 - 0.75 * UnitCurve.easeInOut.value(at: (phase - 0.4) / 0.4)
        }
        return 0.25
    }
}

// MARK: - Linked transition (jsx:323-345)

/// Green-check success beat shown when the user returns from the in-app
/// browser, before the virtual-key screen. Auto-advances after 1.75s.
private struct LinkedTransitionView: View {
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var checkDrawn = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // mrtBadgeRing ×2: scale 0.6→2.1, opacity 0.7→0, 1.5s
                // ease-out, delays 0.3/0.75, fill both (one-shot).
                OneShotRing(delay: 0.3)
                OneShotRing(delay: 0.75)
                badge
            }
            .frame(width: 86, height: 86)
            .padding(.bottom, 30)

            Text("Tesla account linked")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 9)
                .modifier(TextWordReveal(delay: 0.42))
            Text("Secure connection established")
                .font(.system(size: 14))
                .foregroundStyle(Color.mrtTextSec)
                .modifier(TextWordReveal(delay: 0.52))
        }
        .padding(.horizontal, MRTMetrics.onboardingGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mrtFadeUp(duration: 0.4)
        .task {
            try? await Task.sleep(for: .milliseconds(1750))
            onDone()
        }
    }

    /// mrtBadgePop: scale 0→1.15 (60%)→1, 0.6s cubic-bezier(0.34,1.56,0.64,1).
    @ViewBuilder private var badge: some View {
        if reduceMotion {
            badgeCore
        } else {
            badgeCore
                .keyframeAnimator(initialValue: 0.0, trigger: popped) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(1.15, duration: 0.36)
                        CubicKeyframe(1.0, duration: 0.24)
                    }
                }
        }
    }

    private var badgeCore: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [.mrtLinkedGreenLight, .mrtDriving],
                    startPoint: HexLogo.tileGradientStart160,
                    endPoint: HexLogo.tileGradientEnd160
                )
            )
            // inset 0 1px 0 rgba(255,255,255,0.45) — top inner highlight
            Circle()
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
            // mrtCheckDraw: dash 24→0, 0.5s ease-out, 0.36s delay
            CheckDrawShape()
                .trim(from: 0, to: checkDrawn || reduceMotion ? 1 : 0)
                .stroke(
                    Color.mrtLinkedCheckStroke,
                    // strokeWidth 2.6 in the 24-unit viewBox, drawn at 46pt
                    style: StrokeStyle(lineWidth: 2.6 * 46.0 / 24.0, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 46, height: 46)
                .animation(.easeOut(duration: 0.5).delay(0.36), value: checkDrawn)
        }
        .frame(width: 86, height: 86)
        .shadow(color: Color.mrtDriving.opacity(0.45), radius: 18, x: 0, y: 14)
        .onAppear {
            popped = true
            checkDrawn = true
        }
    }
}

/// One `mrtBadgeRing` (jsx:226,329-331): fill `both` shows the ring resting
/// at scale 0.6 / opacity 0.7 until its delay, then it expands out once.
private struct OneShotRing: View {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fired = false

    var body: some View {
        if !reduceMotion {
            Circle()
                .strokeBorder(Color.mrtDriving, lineWidth: 1.5)
                .scaleEffect(fired ? 2.1 : 0.6)
                .opacity(fired ? 0 : 0.7)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.5).delay(delay)) {
                        fired = true
                    }
                }
        }
    }
}

/// jsx check path `M5 12.5l4.5 4.5L19 6.5` in a 24×24 viewBox.
private struct CheckDrawShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
        }
        path.move(to: point(5, 12.5))
        path.addLine(to: point(9.5, 17))
        path.addLine(to: point(19, 6.5))
        return path
    }
}

/// `mrtTextWord` (jsx:227): opacity 0→1, translateX -6→0, blur 3→0, 0.5s
/// ease-out with delay. Reduce Motion → fade only.
private struct TextWordReveal: ViewModifier {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown || reduceMotion ? 0 : -6)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .onAppear {
                withAnimation(.easeOut(duration: 0.5).delay(delay)) {
                    shown = true
                }
            }
    }
}

// MARK: - Paired success (jsx:347-401)

/// Celebratory finish: gold bloom + expanding rings + check pop, then the
/// real vehicle card rises in.
private struct PairedSuccessView: View {
    let vehicle: PairedVehicleFixture
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            // Blooms + rings anchored at (50%, 42%) of the screen (jsx:354-359).
            GeometryReader { proxy in
                ZStack {
                    SuccessBloom(diameter: 300)
                    ExpandingPulse(
                        shape: Circle(),
                        size: CGSize(width: 160, height: 160),
                        color: .mrtGoldBorderSoft,
                        lineWidth: 1.5,
                        duration: 2.2,
                        delays: [0, 0.5, 1.0]
                    )
                }
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                SuccessCheckBadge()
                    .padding(.bottom, 26)
                Text("You're paired")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtText)
                    .padding(.bottom, 8)
                    .mrtFadeUp(delay: 0.15)
                Text("Your Tesla is ready to go.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mrtTextSec)
                    .padding(.bottom, 30)
                    .mrtFadeUp(delay: 0.25)
                vehicleCard
                    .modifier(CardRise(after: 0.48)) // jsx:349 setTimeout 480
                Spacer(minLength: 0)

                MRTButton("Continue", variant: .outlineStatic, action: onContinue)
                    .mrtFadeUp(delay: 0.5)
            }
            .padding(.top, 150)
            .padding(.horizontal, MRTMetrics.onboardingGutter)
            .padding(.bottom, 38)
        }
        .clipped()
    }

    /// The real product vehicle card (jsx:372-395) — no illustration.
    private var vehicleCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HexLogo(size: 52, glow: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vehicle.name)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.mrtText)
                    Text(vehicle.model)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                pairedChip
            }
            HStack(alignment: .top, spacing: 18) {
                statColumn("Color", vehicle.color)
                statColumn("Plate", vehicle.plate)
                statColumn("Virtual key", "Active", valueColor: .mrtGold)
            }
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtText.opacity(0.08)).frame(height: MRTMetrics.hairline)
            }
            .padding(.top, 16)
        }
        .padding(18)
        .modifier(SuccessCardBackground())
    }

    private var pairedChip: some View {
        HStack(spacing: 6) {
            PulseDot(color: .mrtDriving, size: 6)
            Text("Paired")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mrtDriving)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 11)
        .background(Color.mrtDriving.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mrtDriving.opacity(Double(0x44) / 255.0), lineWidth: MRTMetrics.hairline)
        )
    }

    private func statColumn(_ label: String, _ value: String, valueColor: Color = .mrtText) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.mrtTextMuted)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    AddTeslaFlow(onComplete: {}, onCancel: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
