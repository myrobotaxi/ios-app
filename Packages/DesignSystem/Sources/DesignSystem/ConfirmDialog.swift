import SwiftUI

// MARK: - MRTConfirmDialog — center confirmation alert (Handoff §7)
//
// Used by: revoke access, cancel invite, unlink Tesla, cancel reservation,
// sign out. Backdrop rgba(0,0,0,0.6) fades in; the #1a1a1c card (radius 22,
// max-width 300) rises with a ~0.28s spring. Layout: 46×46 tinted icon circle
// (red for destructive, gold for positive) → title 17/600 → body 13 textSec →
// stacked buttons (destructive rgba(255,59,48,0.16)/#FF6B6B, positive gold,
// dismiss outline-muted).

/// Configuration for `mrtConfirmDialog(isPresented:config:)`.
public struct MRTConfirmDialogConfig {
    public enum Kind: Sendable {
        /// Red treatment — revoke / cancel / unlink / sign out.
        case destructive
        /// Gold treatment — resend invite and other affirmative confirms.
        case positive
    }

    public var kind: Kind
    /// SF Symbol shown in the 46×46 tinted circle.
    public var icon: String
    /// Title, 17/600.
    public var title: String
    /// Body copy naming the subject, 13 textSec.
    public var message: String
    /// Label of the confirm button (destructive red fill or gold fill).
    public var actionLabel: String
    /// MYR-360 — the OPTIONAL third action, sitting between the confirm button and
    /// the dismiss button. `nil` (the default) is the two-action dialog every
    /// existing caller builds, and it must stay EXACTLY that: the label is the only
    /// thing that adds a button, so with it absent the card lays out the same two
    /// children in the same `VStack(spacing: 8)` it always did.
    ///
    /// It exists because MYR-360's pause warning genuinely has three answers —
    /// decline the reservations and pause, pause anyway, keep sharing — and none of
    /// them is a variant of another. Forking a second dialog component for the one
    /// screen that needs three would break "Reuse, don't fork" (CLAUDE.md) and
    /// would put the app's confirm grammar in two places for good.
    ///
    /// Styled `.outlineMuted`, the same variant the dismiss button uses: it is the
    /// alternative-but-not-recommended path, so it must not compete with the confirm
    /// button for the eye, and the app has exactly one tertiary treatment.
    public var secondaryLabel: String?
    /// Runs when the secondary button is tapped (the dialog dismisses itself, the
    /// same as the confirm button does). Ignored while `secondaryLabel` is `nil` —
    /// the LABEL is what renders the button.
    public var secondaryAction: (() -> Void)?
    /// Label of the outline-muted dismiss button
    /// ("Keep access" / "Keep invite" / "Keep linked" / "Cancel" / "Not now").
    public var dismissLabel: String
    /// Runs when the confirm button is tapped (the dialog dismisses itself).
    public var action: () -> Void

    public init(
        kind: Kind,
        icon: String,
        title: String,
        message: String,
        actionLabel: String,
        secondaryLabel: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        dismissLabel: String = "Cancel",
        action: @escaping () -> Void
    ) {
        self.kind = kind
        self.icon = icon
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.secondaryLabel = secondaryLabel
        self.secondaryAction = secondaryAction
        self.dismissLabel = dismissLabel
        self.action = action
    }
}

public extension View {
    /// Presents the shared MyRoboTaxi confirmation dialog over this view.
    /// Apply at the screen root so the scrim covers the whole screen.
    func mrtConfirmDialog(
        isPresented: Binding<Bool>,
        config: MRTConfirmDialogConfig
    ) -> some View {
        modifier(MRTConfirmDialogModifier(isPresented: isPresented, config: config))
    }
}

// MARK: - Presentation

private struct MRTConfirmDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let config: MRTConfirmDialogConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    Color.mrtScrim
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    MRTConfirmDialogCard(config: config) { isPresented = false }
                        .transition(
                            reduceMotion
                                ? AnyTransition.opacity
                                : AnyTransition.offset(y: 16).combined(with: .opacity)
                        )
                }
            }
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.28, dampingFraction: 0.8), // mrt-sched-up ~.28s
                value: isPresented
            )
        }
    }
}

// MARK: - Card

// Internal rather than private ONLY so `ConfirmDialogTests` can host the card
// directly and MEASURE it (MYR-360's byte-identical proof is a measurement, not a
// promise). Nothing outside this package can see it, and nothing about its
// rendering changes with the visibility.
struct MRTConfirmDialogCard: View {
    let config: MRTConfirmDialogConfig
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            iconCircle
            Text(config.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.mrtText)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Text(config.message)
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            VStack(spacing: 8) {
                actionButton
                // MYR-360 — the optional third action. `nil` renders NOTHING (an
                // absent optional view is not a laid-out child, so the stack's 8pt
                // spacing is not spent on it either), which is what keeps every
                // existing two-action dialog byte-identical.
                if let secondaryLabel = config.secondaryLabel {
                    MRTButton(secondaryLabel, variant: .outlineMuted) {
                        config.secondaryAction?()
                        dismiss()
                    }
                }
                MRTButton(config.dismissLabel, variant: .outlineMuted, action: dismiss)
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(maxWidth: MRTMetrics.dialogMaxWidth)
        .background(
            Color.mrtDialogCard,
            in: RoundedRectangle(cornerRadius: MRTMetrics.dialogRadius, style: .continuous)
        )
        .padding(.horizontal, MRTMetrics.pageGutter)
        .accessibilityAddTraits(.isModal)
    }

    private var iconCircle: some View {
        ZStack {
            Circle().fill(
                config.kind == .destructive ? Color.mrtDangerFillSoft : .mrtGoldFillSoft
            )
            Image(systemName: config.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(
                    config.kind == .destructive ? Color.mrtDialogRed : .mrtGold
                )
        }
        .frame(width: MRTMetrics.dialogIconSize, height: MRTMetrics.dialogIconSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var actionButton: some View {
        switch config.kind {
        case .positive:
            MRTButton(config.actionLabel, variant: .gold) {
                config.action()
                dismiss()
            }
        case .destructive:
            // Not one of the 6 shared variants — the dialog-only red button
            // (rgba(255,59,48,0.16) fill, #FF6B6B label, Handoff §7).
            Button {
                config.action()
                dismiss()
            } label: {
                Text(config.actionLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtDialogRed)
                    .frame(maxWidth: .infinity)
                    .frame(height: MRTButtonSize.md.height)
                    .background(
                        Color.mrtDangerFill,
                        in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(MRTPressScaleButtonStyle())
        }
    }
}
