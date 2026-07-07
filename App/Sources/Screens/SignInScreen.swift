import SwiftUI
import AuthenticationServices
import DesignSystem

// MARK: - Sign In (MYR-164 — Handoff §5.1, design/app/screens.jsx SignInScreen)
//
// Brand mark + particle glimpse line at rest; swipe up (or tap) reveals the
// Apple-only sheet; Sign in with Apple → gold bloom hands into the app.
// M1: the button completes a simulated session (no network, MYR-193 slots
// the real path in behind `AuthSession`).
//
// Motion (screens.jsx @keyframes):
//   mrtChevFloat  1.6s ease-in-out, 0.18s stagger — chevron bob
//   mrtLinePulse  1.8s ease-in-out — gold line pulse
//   sheet         0.42s cubic-bezier(0.32,0.72,0,1) → spring(0.42, 0.86)
//   scrim         0.35s ease · affordance fade 0.3s ease
//   mrtSignOut    0.6s cubic-bezier(0.4,0,0.2,1) — content fades + scales 1.07
//   mrtBloom      0.62s cubic-bezier(0.4,0,0.2,1) — gold radial, handoff @560ms
// Reduce Motion: chevrons/pulse static, bloom+zoom replaced by a crossfade.
struct SignInScreen: View {
    let session: any AuthSession
    let onSignedIn: () -> Void

    @State private var sheetOpen = false
    @State private var leaving = false
    @State private var affordanceAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// mrtSignOut / mrtBloom share this curve (cubic-bezier(0.4,0,0.2,1)).
    private static let signOutCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.4, y: 0),
        endControlPoint: UnitPoint(x: 0.2, y: 1)
    )

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()

            // Everything that fades (and zooms) out on sign-in.
            content
                .opacity(leaving ? 0 : 1)
                .scaleEffect(reduceMotion ? 1 : (leaving ? 1.07 : 1))
                .animation(
                    reduceMotion
                        ? .easeInOut(duration: 0.45) // simple crossfade fallback
                        : .timingCurve(0.4, 0, 0.2, 1, duration: 0.6), // mrtSignOut
                    value: leaving
                )

            // Gold bloom on sign-in (outside the fading layer, like the jsx).
            if !reduceMotion {
                bloom
            }
        }
        .onAppear {
            if !reduceMotion { affordanceAnimating = true }
        }
    }

    // MARK: Layers

    private var content: some View {
        ZStack {
            goldWash
            brand
            affordance
            scrim
            loginSheetLayer
        }
    }

    /// Soft gold wash from the top: radial-gradient(140% 100% at 50% -20%,
    /// goldGlow3 0%, transparent 65%), height 380 (screens.jsx).
    private var goldWash: some View {
        RadialGradient(
            stops: [
                .init(color: .mrtGoldGlowSoft, location: 0),
                .init(color: Color.mrtGoldGlowSoft.opacity(0), location: 0.65),
            ],
            center: UnitPoint(x: 0.5, y: -0.2),
            startRadius: 0,
            endRadius: 380 // ry = 100% of the 380pt band
        )
        // rx = 140% of the frame width vs ry = 380 ⇒ stretch x around the
        // gradient's own center to make the CSS ellipse.
        .scaleEffect(x: 1.48, y: 1, anchor: UnitPoint(x: 0.5, y: -0.2))
        .frame(height: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Centered brand: HexLogo 62 (28 below) + Wordmark 28 + glimpse line
    /// (12 above, inside SignInGlimpseLine's layout).
    private var brand: some View {
        VStack(spacing: 0) {
            HexLogo(size: 62)
                .padding(.bottom, 28)
            Wordmark(size: 28)
            SignInGlimpseLine()
                .padding(.top, 12) // canvas marginTop: 12
        }
        .padding(.horizontal, 32) // jsx padding: '0 32px'
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// Swipe-up affordance: chevrons + pulsing gold line + caption, in a
    /// 168pt-tall touch band (tap, or drag up > 44pt, opens the sheet).
    private var affordance: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                chevron(delay: 0)
                chevron(delay: 0.18)
            }
            pulseLine
            Text("Swipe up to sign in")
                .font(.system(size: 12.5, weight: .medium)) // jsx 12.5/500
                .tracking(0.3)
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 168, alignment: .bottom) // jsx height: 168
        .contentShape(Rectangle())
        .onTapGesture { openSheet() }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    // jsx onMove: dragStart - clientY > 44 opens.
                    if value.translation.height < -44 { openSheet() }
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(sheetOpen ? 0 : 1)
        .animation(.easeInOut(duration: 0.3), value: sheetOpen) // jsx 0.3s ease
        .allowsHitTesting(!sheetOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sign in")
        .accessibilityHint("Opens the sign-in options")
        .accessibilityAddTraits(.isButton)
    }

    /// One floating chevron (mrtChevFloat: translateY 2 → -3, opacity
    /// 0.45 → 1, 1.6s ease-in-out infinite ⇒ 0.8s autoreversing).
    private func chevron(delay: Double) -> some View {
        ChevronUpShape()
            .stroke(Color.mrtGold, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 20, height: 11)
            .offset(y: affordanceAnimating ? -3 : 2)
            .opacity(affordanceAnimating ? 1 : 0.45)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(delay),
                value: affordanceAnimating
            )
    }

    /// 132×3 gold gradient line (mrtLinePulse: opacity 0.35 → 1,
    /// scaleX 0.65 → 1, 1.8s ease-in-out infinite ⇒ 0.9s autoreversing).
    private var pulseLine: some View {
        LinearGradient(
            colors: [Color.mrtGold.opacity(0), .mrtGold, Color.mrtGold.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 132, height: 3)
        .clipShape(Capsule()) // borderRadius: 2
        .scaleEffect(x: affordanceAnimating ? 1 : 0.65)
        .opacity(affordanceAnimating ? 1 : 0.35)
        .animation(
            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: affordanceAnimating
        )
    }

    /// rgba(0,0,0,0.5) scrim, 0.35s ease fade, tap closes (screens.jsx).
    private var scrim: some View {
        Color.mrtScrimSoft
            .ignoresSafeArea()
            .opacity(sheetOpen ? 1 : 0)
            .animation(.easeInOut(duration: 0.35), value: sheetOpen)
            .onTapGesture { closeSheet() }
            .allowsHitTesting(sheetOpen)
            .accessibilityHidden(true)
    }

    private var loginSheetLayer: some View {
        ZStack(alignment: .bottom) {
            if sheetOpen {
                loginSheet
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 0.42s cubic-bezier(0.32,0.72,0,1) → spring(0.42, 0.86) (Handoff §8).
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.2)
                : .spring(response: 0.42, dampingFraction: 0.86),
            value: sheetOpen
        )
    }

    /// The Apple-only login sheet (screens.jsx "Login sheet"). Screen-specific
    /// by design — 24pt top radius + 0.5 scrim + no close button, distinct
    /// from the shared 26pt/0.6 config sheet.
    private var loginSheet: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.mrtElevated)
                .frame(width: 38, height: 4) // jsx grabber 38×4
                .padding(.bottom, 22)
            Text("Welcome")
                .font(.system(size: 21, weight: .semibold)) // jsx 21/600
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 4)
            Text("Continue with your Apple Account.")
                .font(.system(size: 13.5)) // jsx 13.5/400
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 26)
            AppleSignInButton { signIn() }
                .frame(height: MRTMetrics.appleButtonHeight)
                .accessibilityLabel("Sign in with Apple")
            Text("By continuing, you agree to our Terms and Privacy.")
                .font(.system(size: 11)) // jsx 11, line-height 1.5
                .lineSpacing(3)
                .foregroundStyle(Color.mrtTextMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
        }
        .padding(.top, 14) // jsx padding: '14px 24px 34px' — the 34pt bottom
        .padding(.horizontal, MRTMetrics.pageGutter) // maps to the safe area.
        .frame(maxWidth: .infinity)
        .background {
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: MRTMetrics.sheetRadius,
                topTrailingRadius: MRTMetrics.sheetRadius,
                style: .continuous
            )
            shape
                .fill(Color.mrtBgSecondary)
                .overlay(shape.strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                // box-shadow 0 -20px 50px rgba(0,0,0,0.6) (blur halved).
                .shadow(color: .black.opacity(0.6), radius: 25, x: 0, y: -20)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityAddTraits(.isModal)
    }

    /// mrtBloom: 260pt gold radial at screen center, scale 0.2 → 4.2 with
    /// opacity 0 → 0.85 (at 35%) → 0 over 0.62s, cubic-bezier(0.4,0,0.2,1).
    private var bloom: some View {
        RadialGradient(
            stops: [
                .init(color: .mrtGold, location: 0),
                .init(color: Color.mrtGold.opacity(0.5), location: 0.35),
                .init(color: Color.mrtGold.opacity(0), location: 0.7),
            ],
            center: .center,
            startRadius: 0,
            endRadius: 130
        )
        .frame(width: 260, height: 260)
        .keyframeAnimator(
            initialValue: BloomValues(),
            trigger: leaving
        ) { view, values in
            view
                .scaleEffect(values.scale)
                .opacity(leaving ? values.opacity : 0)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                LinearKeyframe(4.2, duration: 0.62, timingCurve: Self.signOutCurve)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0.85, duration: 0.62 * 0.35, timingCurve: Self.signOutCurve)
                LinearKeyframe(0, duration: 0.62 * 0.65, timingCurve: Self.signOutCurve)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct BloomValues {
        var scale = 0.2
        var opacity = 0.0
    }

    // MARK: Actions

    private func openSheet() {
        guard !sheetOpen, !leaving else { return }
        sheetOpen = true
    }

    private func closeSheet() {
        sheetOpen = false
    }

    /// doSignIn(): establish the session, then run the bloom/fade and hand
    /// off 560ms in (screens.jsx setTimeout(onSignIn, 560)).
    private func signIn() {
        guard !leaving else { return }
        Task { @MainActor in
            do {
                try await session.signIn() // M1: simulated, cannot fail
            } catch {
                return // MYR-193: cancel/error keeps the user on the sheet
            }
            leaving = true
            try? await Task.sleep(for: .milliseconds(560))
            onSignedIn()
        }
    }
}

// MARK: - Chevron (jsx: <path d="M2 8L10 2.5L18 8"/> in a 20×11 viewBox)

private struct ChevronUpShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 20 * rect.width, y: rect.minY + y / 11 * rect.height)
        }
        path.move(to: point(2, 8))
        path.addLine(to: point(10, 2.5))
        path.addLine(to: point(18, 8))
        return path
    }
}

// MARK: - Apple button

/// The real Apple-provided button chrome (AuthenticationServices,
/// `ASAuthorizationAppleIDButton`, white style, 14pt radius per the jsx).
/// M1 wires the tap straight to the simulated session — no
/// ASAuthorizationController until MYR-193.
private struct AppleSignInButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(
            authorizationButtonType: .signIn,
            authorizationButtonStyle: .white
        )
        button.cornerRadius = MRTMetrics.appleButtonRadius
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.didTap),
            for: .touchUpInside
        )
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func didTap() { action() }
    }
}

#Preview {
    SignInScreen(session: SimulatedAuthSession()) {}
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
