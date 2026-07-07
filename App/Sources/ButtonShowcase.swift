import SwiftUI
import DesignSystem

/// Dev showcase for MYR-162 — all 6 `MRTButton` variants × 3 sizes plus the
/// three shared overlays (confirm dialog, success toast, bottom sheets).
/// Not routed in the shipping app; point the app root here to eyeball it.
struct ButtonShowcase: View {
    @State private var showDestructiveDialog = false
    @State private var showPositiveDialog = false
    @State private var showToast = false
    @State private var showConfigSheet = false
    @State private var detent: MRTSheetDetent = .peek

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Buttons")
                    .mrtTextStyle(.screenTitle)
                    .foregroundStyle(Color.mrtText)

                variantSection("gold", .gold)
                variantSection("gold — flatOnboarding (goldDeep)", .gold, flatOnboarding: true)
                variantSection("outline", .outline)
                variantSection("outline-muted", .outlineMuted)
                variantSection("outline-draw — ride CTAs only", .outlineDraw)
                variantSection("outline-static", .outlineStatic)
                variantSection("ghost", .ghost)

                overlaySection
                detentSection
            }
            .padding(MRTMetrics.pageGutter)
            .padding(.bottom, 60)
        }
        .background(Color.mrtBg.ignoresSafeArea())
        .mrtConfirmDialog(isPresented: $showDestructiveDialog, config: .init(
            kind: .destructive,
            icon: "person.fill.xmark",
            title: "Revoke access?",
            message: "Jordan will immediately lose access to Alex's Model Y.",
            actionLabel: "Revoke access",
            dismissLabel: "Keep access"
        ) {})
        .mrtConfirmDialog(isPresented: $showPositiveDialog, config: .init(
            kind: .positive,
            icon: "paperplane.fill",
            title: "Resend invite?",
            message: "Sam's invite will be sent again to sam@example.com.",
            actionLabel: "Resend invite",
            dismissLabel: "Keep invite"
        ) { showToast = true })
        .mrtSuccessToast(isPresented: $showToast, message: "Invite resent")
        .mrtConfigSheet(isPresented: $showConfigSheet) { configSheetContent }
    }

    private func variantSection(
        _ title: String,
        _ variant: MRTButtonVariant,
        flatOnboarding: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            Text(title)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            MRTButton("Small", variant: variant, size: .sm, flatOnboarding: flatOnboarding) {}
            MRTButton("Medium", variant: variant, size: .md, flatOnboarding: flatOnboarding) {}
            MRTButton(
                "Large",
                variant: variant,
                size: .lg,
                flatOnboarding: flatOnboarding,
                leadingIcon: "paperplane.fill"
            ) {}
        }
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            Text("Overlays")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            MRTButton("Destructive dialog", variant: .outlineMuted) {
                showDestructiveDialog = true
            }
            MRTButton("Positive dialog", variant: .outline) {
                showPositiveDialog = true
            }
            MRTButton("Success toast", variant: .outlineMuted) {
                showToast = true
            }
            MRTButton("Config sheet", variant: .outlineMuted) {
                showConfigSheet = true
            }
        }
    }

    private var configSheetContent: some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            Text("Vehicle detail")
                .mrtTextStyle(.sectionTitle)
                .foregroundStyle(Color.mrtText)
                .padding(.top, 8)
            Text("Primary is the default vehicle on the map and the one used for new requests and sharing.")
                .mrtTextStyle(.bodySmall)
                .foregroundStyle(Color.mrtTextSec)
            MRTButton("Set as primary", variant: .gold) { showConfigSheet = false }
                .padding(.top, 8)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, MRTMetrics.pageGutter)
    }

    private var detentSection: some View {
        VStack(alignment: .leading, spacing: MRTMetrics.cardGap) {
            Text("Detent sheet — drag the handle")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            ZStack {
                Color.mrtSurface // stand-in for the map
                MRTDetentSheet(detent: $detent, peekHeight: 120) {
                    VStack(spacing: 6) {
                        Text(detent == .peek ? "Peek" : "Half")
                            .mrtTextStyle(.sectionTitle)
                            .foregroundStyle(Color.mrtText)
                        Text("Snaps with spring(0.42, 0.86)")
                            .mrtTextStyle(.bodySmall)
                            .foregroundStyle(Color.mrtTextSec)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous))
        }
    }
}

#Preview {
    ButtonShowcase()
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
