import SwiftUI
import DesignSystem

// MARK: - InvitesScreen (MYR-170, design/app/screens.jsx 1246-1557, Handoff §5.7)
//
// Owner Share tab: email field + Send (invalid/empty → shake), a Viewers
// list (Revoke → confirm → toast) and a Pending list (Resend → gold confirm
// + toast, Cancel → red confirm). A valid email opens the send-invite sheet:
// recipient → vehicle multi-select (≥1 enforced) → cumulative access tier →
// live summary card → Send invite → sending spinner (1150ms) → gold check
// "Invite sent" (950ms) → adds to Pending + toast. Renders its own
// `BottomNav` like every other owner screen (see `HomeScreen`'s header
// comment) — replaces the MYR-167 `PlaceholderScreen` for the "invites" tab.
struct InvitesScreen: View {
    @Bindable var shareState: OwnerShareState
    @Binding var ownerTab: String

    @State private var email = ""
    @State private var emailError = false
    @State private var emailShakeTrigger = 0

    @State private var confirmRevoke: Viewer?
    @State private var revokedToastName: String?
    @State private var confirmCancelInvite: PendingInvite?
    @State private var confirmResend: PendingInvite?
    @State private var resentToastName: String?
    @State private var sentToastEmail: String?

    private enum SendStep { case config, sending, done }
    @State private var sendStep: SendStep?
    @State private var accessLevel: ShareAccessLevel = .live
    @State private var shareVehicleIDs: Set<String> = [VehicleFixtures.vehicles[0].id]

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        emailRow
                        viewersSection
                        pendingSection
                    }
                    .padding(.bottom, MRTMetrics.shareContentBottomPadding)
                }
            }
            // screens.jsx:97 `padding: '74px 24px 18px'` is measured from the
            // physical screen edge (full-bleed canvas) — see CLAUDE.md "Hard
            // rules" full-bleed geometry.
            .ignoresSafeArea(.container, edges: .top)
        }
        .mrtBottomNav(selection: $ownerTab)
        .mrtConfigSheet(
            isPresented: Binding(get: { sendStep != nil }, set: { if !$0 { sendStep = nil } }),
            showsCloseButton: sendStep == .config
        ) {
            sendSheetContent
        }
        .mrtConfirmDialog(
            isPresented: Binding(get: { confirmResend != nil }, set: { if !$0 { confirmResend = nil } }),
            config: resendDialogConfig
        )
        .mrtConfirmDialog(
            isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
            config: revokeDialogConfig
        )
        .mrtConfirmDialog(
            isPresented: Binding(get: { confirmCancelInvite != nil }, set: { if !$0 { confirmCancelInvite = nil } }),
            config: cancelInviteDialogConfig
        )
        .mrtSuccessToast(
            isPresented: Binding(get: { revokedToastName != nil }, set: { if !$0 { revokedToastName = nil } }),
            message: "Access revoked for \(revokedToastName ?? "")"
        )
        .mrtSuccessToast(
            isPresented: Binding(get: { resentToastName != nil }, set: { if !$0 { resentToastName = nil } }),
            message: "Invite resent to \(resentToastName ?? "")"
        )
        .mrtSuccessToast(
            isPresented: Binding(get: { sentToastEmail != nil }, set: { if !$0 { sentToastEmail = nil } }),
            message: "Invite sent to \(sentToastEmail ?? "")"
        )
    }

    // MARK: Header (screens.jsx:97-100)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Share Your Tesla")
                .mrtTextStyle(.screenTitle)
                .foregroundStyle(Color.mrtText)
            Text("Let friends and family see live location and trips.")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.shareHeaderTop)
        .padding(.bottom, 18)
    }

    // MARK: Email + invite row (screens.jsx:103-111)

    private var validEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^.+@.+\..+$"#, options: .regularExpression) != nil
    }

    private var emailRow: some View {
        HStack(spacing: 10) {
            TextField("", text: $email)
                .textFieldStyle(.plain)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))
                .tint(Color.mrtGold)
                .foregroundStyle(Color.mrtText)
                // `TextField(_:text:prompt:)`'s built-in `prompt:` param
                // renders the placeholder wrong here, so this uses a manual
                // overlay `Text` instead — see the `Text(verbatim:)` note
                // just below for the actual reason.
                .overlay(alignment: .leading) {
                    if email.isEmpty {
                        // `Text(_:)` from a string literal parses Markdown
                        // (SwiftUI default since iOS 15), which auto-links
                        // bare email-shaped text and renders the "link" in
                        // the accent/tint color — silently overriding
                        // `.foregroundStyle` below. `Text(verbatim:)` skips
                        // Markdown parsing so the placeholder actually
                        // renders `mrtTextMuted`, not system blue.
                        Text(verbatim: "friend@example.com")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.mrtTextMuted)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                        .strokeBorder(emailError ? Color.mrtDialogRed : Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                )
                .modifier(InviteShake(trigger: emailShakeTrigger))
                .onSubmit { openSend() }
            MRTButton("Send", fullWidth: false, action: openSend)
                .frame(width: 110)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 28)
    }

    private func openSend() {
        guard validEmail else {
            emailError = true
            emailShakeTrigger += 1
            Task {
                try? await Task.sleep(for: .milliseconds(500)) // jsx:1256
                emailError = false
            }
            return
        }
        accessLevel = .live
        shareVehicleIDs = [VehicleFixtures.vehicles[0].id]
        sendStep = .config
    }

    // MARK: Viewers (screens.jsx:113-125)

    private var viewersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Viewers \u{00B7} \(shareState.viewers.count)")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.bottom, 14)
            if shareState.viewers.isEmpty {
                Text("No one has access yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.bottom, 14)
            }
            ForEach(shareState.viewers) { viewer in
                ViewerRow(viewer: viewer) { confirmRevoke = viewer }
            }
        }
    }

    // MARK: Pending (screens.jsx:127-138)

    @ViewBuilder
    private var pendingSection: some View {
        if !shareState.pending.isEmpty {
            Text("Pending")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.top, 20)
                .padding(.bottom, 14)
            ForEach(shareState.pending) { invite in
                PendingRow(
                    invite: invite,
                    onResend: { confirmResend = invite },
                    onCancel: { confirmCancelInvite = invite }
                )
            }
        }
    }

    // MARK: Send-invite sheet (screens.jsx:1330-1546, Handoff §7)

    @ViewBuilder
    private var sendSheetContent: some View {
        switch sendStep {
        case .config: sendConfigContent
        case .sending: sendingContent
        case .done: sentDoneContent
        case nil: EmptyView()
        }
    }

    private var sendConfigContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Invite to your Tesla")
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 4)
            Text("Choose what they can see and do.")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 18)

            recipientRow
                .padding(.bottom, 20)

            HStack(alignment: .lastTextBaseline) {
                Text("Vehicles")
                    .mrtTextStyle(.label())
                    .foregroundStyle(Color.mrtTextMuted)
                Spacer(minLength: 0)
                Text("Select one or more")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.bottom, 9)

            HStack(spacing: 8) {
                ForEach(VehicleFixtures.vehicles) { vehicle in
                    vehicleCard(vehicle)
                }
            }
            .padding(.bottom, 20)

            Text("Access")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 9)

            VStack(spacing: 8) {
                ForEach(ShareAccessLevel.allCases) { level in
                    accessRow(level)
                }
            }

            summaryCard
                .padding(.top, 12)

            MRTButton("Send invite", action: doSend)
                .padding(.top, 14)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private var recipientRow: some View {
        HStack(spacing: 12) {
            Avatar(name: ShareFixtures.name(fromEmail: email), size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(ShareFixtures.name(fromEmail: email))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                Text(email)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
    }

    private func toggleVehicle(_ id: String) {
        if shareVehicleIDs.contains(id) {
            if shareVehicleIDs.count > 1 { shareVehicleIDs.remove(id) }
        } else {
            shareVehicleIDs.insert(id)
        }
    }

    private func vehicleCard(_ vehicle: Vehicle) -> some View {
        let on = shareVehicleIDs.contains(vehicle.id)
        return Button {
            toggleVehicle(vehicle.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: "car.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(on ? Color.mrtGold : Color.mrtTextSec)
                    Spacer(minLength: 0)
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(on ? Color.mrtGold : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(on ? Color.mrtGold : Color.mrtBorder, lineWidth: 1.5)
                            )
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Color.mrtGoldButtonLabel)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                Text(vehicle.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                Text(vehicle.plate)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.mrtTextMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                on ? Color.mrtInviteVehicleTint : Color.mrtSurface,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(on ? Color.mrtInviteVehicleBorder : Color.mrtBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func accessRow(_ level: ShareAccessLevel) -> some View {
        let on = accessLevel == level
        let info = level.info
        return Button {
            accessLevel = level
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.mrtInviteAccessIconFill : Color.mrtElevated)
                    Image(systemName: info.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(on ? Color.mrtGold : Color.mrtTextSec)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mrtText)
                    Text(info.desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(on ? Color.mrtGold : Color.mrtBorder, lineWidth: 1.5)
                    if on {
                        Circle().fill(Color.mrtGold).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                on ? Color.mrtInviteAccessTintLight : Color.mrtSurface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on ? Color.mrtInviteAccessBorder : Color.mrtBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var summaryCard: some View {
        let recipientFirst = ShareFixtures.name(fromEmail: email).split(separator: " ").first.map(String.init)
            ?? ShareFixtures.name(fromEmail: email)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(recipientFirst) will be able to:")
                .font(.system(size: 11))
                .tracking(0.2)
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 6)
            ForEach(Array(ShareFixtures.capabilities.enumerated()), id: \.element.id) { index, cap in
                let granted = index < accessLevel.info.grants
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(granted ? Color.mrtGoldIconTile : Color.clear)
                        if !granted {
                            Circle().strokeBorder(Color.mrtBorder, lineWidth: 1)
                        }
                        if granted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Color.mrtGold)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(cap.label)
                        .font(.system(size: 12.5, weight: granted ? .medium : .regular))
                        .foregroundStyle(granted ? Color.mrtText : Color.mrtTextMuted)
                }
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
    }

    private var sendingContent: some View {
        VStack(spacing: 0) {
            SpinnerRing(diameter: 40, lineWidth: 3, trackColor: .mrtInviteSpinnerTrack, color: .mrtGold, period: 0.8)
            Text("Sending invite\u{2026}")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mrtText)
                .padding(.top, 18)
            Text(email)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
        .padding(.bottom, 26)
    }

    private var sentDoneContent: some View {
        VStack(spacing: 0) {
            InviteSentCheckBadge()
                .padding(.bottom, 16)
            Text("Invite sent")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.mrtText)
            Text("We emailed \(ShareFixtures.name(fromEmail: email)) a link to join.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 24)
    }

    /// screens.jsx:1258-1266 `doSend` — sending (1150ms) → done (950ms) →
    /// appends to Pending, fires the toast, closes the sheet, clears the field.
    private func doSend() {
        sendStep = .sending
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1150))
            guard sendStep == .sending else { return }
            sendStep = .done
            try? await Task.sleep(for: .milliseconds(950))
            let addr = email.trimmingCharacters(in: .whitespacesAndNewlines)
            shareState.sendInvite(email: addr, accessLevel: accessLevel)
            sentToastEmail = addr
            sendStep = nil
            email = ""
        }
    }

    // MARK: Dialogs (screens.jsx:1362-1422)

    private var resendDialogConfig: MRTConfirmDialogConfig {
        let invite = confirmResend
        return ShareDialogs.resend(invite ?? PendingInvite(name: "", email: "", sent: "")) {
            guard let invite else { return }
            shareState.resend(invite)
            resentToastName = invite.name
        }
    }

    private var revokeDialogConfig: MRTConfirmDialogConfig {
        let viewer = confirmRevoke
        return ShareDialogs.revoke(viewer ?? Viewer(name: "", email: "", online: false, perm: "")) {
            guard let viewer else { return }
            shareState.revoke(viewer)
            revokedToastName = viewer.name
        }
    }

    private var cancelInviteDialogConfig: MRTConfirmDialogConfig {
        let invite = confirmCancelInvite
        return ShareDialogs.cancelInvite(invite ?? PendingInvite(name: "", email: "", sent: "")) {
            guard let invite else { return }
            shareState.cancelInvite(invite)
        }
    }
}

// MARK: - Invite-sent check badge (screens.jsx:1432-1436 `mrt-check-pop`)
//
// 56pt gold check disc — a smaller twin of `SuccessCheckBadge` (72pt, used by
// the onboarding celebrations) with this screen's own glow radius
// (`0 8px 26px goldGlow6` vs onboarding's `0 10px 34px`). Reduce Motion → static.
private struct InviteSentCheckBadge: View {
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
                        CubicKeyframe(1.15, duration: 0.3)
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
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.mrtGoldButtonLabel)
        }
        .frame(width: 56, height: 56)
        .shadow(color: .mrtGoldGlow, radius: 13, x: 0, y: 8) // CSS blur halved for SwiftUI sigma
    }
}

// MARK: - Email shake (screens.jsx:1327 `mrt-invite-shake` — 0.4s ease,
// magnitude 6px; a smaller twin of `InviteCodeFlow`'s 7px `Shake`, kept
// screen-local since the two prototype keyframes use different magnitudes.)
private struct InviteShake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
                    view.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(0, duration: 0.0001)
                        LinearKeyframe(-6, duration: 0.08)
                        LinearKeyframe(6, duration: 0.08)
                        LinearKeyframe(-6, duration: 0.08)
                        LinearKeyframe(6, duration: 0.08)
                        LinearKeyframe(0, duration: 0.08)
                    }
                }
        }
    }
}

#Preview {
    InvitesScreen(shareState: OwnerShareState(), ownerTab: .constant("invites"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
