import SwiftUI
import DesignSystem

// MARK: - Tesla OAuth seam (M1 simulated — MYR-165; real OAuth is MYR-115)
//
// AddTeslaFlow's "Sign in with Tesla" runs the OAuth dance through this seam:
//
//   · M1 (default, `authenticate == nil`): the flow presents
//     `SimulatedTeslaAuthSheet` below — the prototype's faux
//     Safari-View-Controller sheet (onboarding.jsx InAppBrowser). Original
//     plausible mock, NOT Tesla's real UI. No network.
//   · MYR-115: inject an `authenticate` closure that runs
//     `ASWebAuthenticationSession` against the real Tesla Fleet OAuth and
//     resolves `.granted` / `.cancelled`. The system presents its own UI, so
//     the simulated sheet never mounts — nothing else in the flow changes.

enum TeslaAuthOutcome: Equatable {
    case granted
    case cancelled
    /// MYR-246 — the link reached a definite failure (the `/start` call, the
    /// system session, or a §7.11 callback `reason`). Carries honest, user-facing
    /// copy + a retry affordance via `AddTeslaFlow`.
    case failed(TeslaLinkFailure)
}

/// Runs the Tesla OAuth dance end-to-end and reports how it ended.
typealias TeslaAuthenticator = @MainActor () async -> TeslaAuthOutcome

// MARK: - Simulated in-app browser (onboarding.jsx:64-189)
//
// Slides up over the app (`translateY` 100%→0, .42s spring — Handoff §8
// sheet snap), hosts auth → consent → connecting, then auto-dismisses the
// instant access is granted. Stays mounted while closed so the slide-out
// plays, exactly like the jsx.
struct SimulatedTeslaAuthSheet: View {
    let open: Bool
    let onGranted: () -> Void
    let onCancel: () -> Void

    private enum BrowserView {
        case auth, consent, connecting
    }

    @State private var view: BrowserView = .auth
    @State private var password = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // Dim behind (rgba(0,0,0,0.55), .35s ease)
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .opacity(open ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: open)

                sheet
                    .padding(.top, 20) // jsx: sheet top 20
                    .offset(y: open ? 0 : proxy.size.height + 40)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.2)
                            : .spring(response: 0.42, dampingFraction: 0.86),
                        value: open
                    )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(open)
        .onChange(of: open) { _, isOpen in
            // jsx: if (open) { setView('auth'); setPw(''); }
            if isOpen {
                view = .auth
                password = ""
            }
        }
        .accessibilityHidden(!open)
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            chrome
            body_
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 40, topTrailingRadius: 40)
                .fill(Color.mrtBrowserBg)
                // 0 -30px 80px rgba(0,0,0,0.6) (blur halved)
                .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: -30)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 40, topTrailingRadius: 40))
        .accessibilityAddTraits(.isModal)
    }

    /// Faux Safari chrome: Cancel · padlock+auth.tesla.com pill · spinner.
    private var chrome: some View {
        HStack(spacing: 12) {
            Button("Cancel", action: onCancel)
                .font(.system(size: 15))
                .foregroundStyle(Color.mrtLinkBlue)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtBrowserGlyph)
                Text("auth.tesla.com")
                    .font(.system(size: 13.5))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtBrowserText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // 18pt gap-ring spinner, visible while connecting (jsx:105-106)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.mrtBrowserSpinner, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 18, height: 18)
                .modifier(SpinRotation(period: 0.9, active: view == .connecting))
                .opacity(view == .connecting ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: view == .connecting)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.horizontal, 18)
        .background(Color.mrtBrowserChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: MRTMetrics.hairline)
        }
    }

    // MARK: Page body

    private var body_: some View {
        ZStack {
            authPage
                .opacity(view == .auth ? 1 : 0)
                .offset(x: view == .auth ? 0 : -16)
                .animation(.easeInOut(duration: 0.3), value: view == .auth)
                .allowsHitTesting(view == .auth)

            if view != .auth {
                consentPage
                    .opacity(view == .consent ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.3), value: view == .consent)
            }

            if view == .connecting {
                connectingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// AUTH — email prefilled + password → Sign In (onboarding.jsx:111-136).
    private var authPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                teslaTile(size: 46, radius: 12, fontSize: 26)
                    .shadow(color: Color.mrtTeslaRed.opacity(0.32), radius: 9, x: 0, y: 6)
                    .padding(.bottom, 16)
                Text("Sign in to Tesla")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtBrowserText)
                Text("to continue to MyRoboTaxi")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mrtBrowserTextSec)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 34)

            fieldLabel("Email")
            fieldBox {
                // verbatim: keeps SwiftUI from auto-linking the address blue
                Text(verbatim: "owner@icloud.com")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.mrtBrowserText)
            }
            .padding(.bottom, 16)

            fieldLabel("Password")
            fieldBox {
                SecureField("••••••••", text: $password)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.mrtBrowserText)
            }
            .padding(.bottom, 24)

            Button {
                view = .consent
            } label: {
                Text("Sign In")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.mrtTeslaRed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.mrtTeslaRed.opacity(0.3), radius: 9, x: 0, y: 6)
            }
            .buttonStyle(.plain)

            Text("Forgot password?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mrtLinkBlue)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
        }
        .padding(.top, 40)
        .padding(.horizontal, 30)
        .padding(.bottom, 30)
    }

    /// CONSENT — Tesla↔MyRoboTaxi handoff + 4 scope rows → Allow access
    /// (onboarding.jsx:138-176).
    private var consentPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                teslaTile(size: 38, radius: 10, fontSize: 21)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.mrtBrowserArrow)
                HexLogo(size: 38)
            }
            .padding(.bottom, 8)

            Text("MyRoboTaxi wants access to your Tesla")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtBrowserText)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .padding(.horizontal, 10)
            Text("Review what you're sharing")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtBrowserTextSec)
                .padding(.top, 6)
                .padding(.bottom, 22)

            VStack(spacing: 0) {
                ForEach(Array(Self.scopes.enumerated()), id: \.offset) { index, scope in
                    if index > 0 {
                        Rectangle().fill(Color.black.opacity(0.07)).frame(height: MRTMetrics.hairline)
                    }
                    scopeRow(scope)
                }
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: MRTMetrics.hairline)
            )
            .padding(.bottom, 22)

            Button {
                view = .connecting
            } label: {
                Text("Allow access")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.mrtBrowserText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.mrtBrowserTextSec)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Text("You can revoke access anytime in your Tesla account.")
                .font(.system(size: 11))
                .lineSpacing(11 * 0.5)
                .foregroundStyle(Color.mrtBrowserTextFaint)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
        .padding(.top, 34)
        .padding(.horizontal, 26)
        .padding(.bottom, 30)
    }

    /// CONNECTING — brief beat, then hand back to the app
    /// (onboarding.jsx:71-75,178-185; ~1.15s).
    private var connectingOverlay: some View {
        ZStack {
            Color.mrtBrowserBg.opacity(0.92)
            VStack(spacing: 18) {
                SpinnerRing(
                    diameter: 38,
                    lineWidth: 3,
                    trackColor: .black.opacity(0.12),
                    color: .mrtTeslaRed,
                    period: 0.8
                )
                Text("Connecting to MyRoboTaxi…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mrtBrowserText)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1150))
            onGranted()
        }
    }

    // MARK: Pieces

    private static let scopes: [(icon: String, title: String, sub: String)] = [
        ("car.fill", "Vehicle information", "Model, battery, status"),
        ("location.fill", "Location", "Live position while shared"),
        ("lock.fill", "Commands", "Lock, climate, media"),
        ("bolt.fill", "Charging", "Start, stop, monitor"),
    ]

    private func scopeRow(_ scope: (icon: String, title: String, sub: String)) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.mrtTeslaRed.opacity(0.08))
                .overlay(
                    Image(systemName: scope.icon)
                        .font(.system(size: 16, weight: .medium)) // SFIcon 18
                        .foregroundStyle(Color.mrtTeslaRed)
                )
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(scope.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.mrtBrowserText)
                Text(scope.sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtBrowserTextTert)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold)) // SFIcon 15 / weight 2.2
                .foregroundStyle(Color.mrtConsentGreen)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
    }

    private func teslaTile(size: CGFloat, radius: CGFloat, fontSize: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.mrtTeslaRed)
            .overlay(
                Text("T")
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.mrtBrowserTextSec)
            .padding(.bottom, 7)
    }

    private func fieldBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.14), lineWidth: MRTMetrics.hairline)
            )
    }
}

/// Continuous linear rotation (`mrtBrowserSpin`), gated on `active` and
/// Reduce Motion.
private struct SpinRotation: ViewModifier {
    let period: Double
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion || !active {
            content
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content.rotationEffect(
                    .degrees(t.truncatingRemainder(dividingBy: period) / period * 360)
                )
            }
        }
    }
}
