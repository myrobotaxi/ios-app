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
    /// MYR-184 — the `ShareService` seam (was the concrete `OwnerShareState`).
    /// `let`, not `@Bindable`: this screen only READS the lists and CALLS the
    /// mutations; it never binds a field to service state.
    let shareService: any ShareService
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
    /// MYR-184 — a mutation that FAILED. Surfaced as the same quiet bottom pill
    /// the successes use, because the alternative (saying nothing) tells the
    /// owner someone lost access when they did not.
    @State private var failureToast: String?

    private enum SendStep { case config, sending, done }
    @State private var sendStep: SendStep?
    @State private var accessLevel: ShareAccessLevel = .live
    @State private var shareVehicleIDs: Set<String> = []
    /// MYR-184 — the minted code, held only long enough to present the system
    /// share sheet. Set by a create OR a resend; the sheet is the whole point of
    /// both on the live path (§7.5: the owner "sends the code out-of-band through
    /// the iOS system share sheet").
    @State private var handout: ShareHandout?

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
            message: sentToastMessage
        )
        .mrtSuccessToast(
            isPresented: Binding(get: { failureToast != nil }, set: { if !$0 { failureToast = nil } }),
            message: failureToast ?? ""
        )
        // MYR-184 — the SYSTEM share sheet carrying the minted code. This is how
        // an invite actually reaches its recipient: there is no email
        // infrastructure and no web surface to link to, so the code travels
        // through Messages/AirDrop/whatever the owner already uses.
        .sheet(item: $handout) { handout in
            ActivityShareSheet(activityItems: [handout.message])
        }
        // MYR-184 — read the owner's real grants on arrival. No-op in sim, so
        // every simulated + DEBUG capture is unchanged.
        .task { await shareService.load() }
    }

    /// The send toast. SIM keeps the prototype's "Invite sent to {email}"; LIVE
    /// names the person, because there is no address to name and the code has
    /// already gone out through the share sheet.
    private var sentToastMessage: String {
        let value = sentToastEmail ?? ""
        return shareService.sharesByCode ? "Invite ready for \(value)" : "Invite sent to \(value)"
    }

    // MARK: Header (screens.jsx:97-100)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Share Your Tesla")
                .mrtTextStyle(.screenTitle)
                .foregroundStyle(Color.mrtText)
            // MYR-184 — the live sub-line names the ARTEFACT. "Let friends and
            // family see…" describes the outcome but leaves the owner expecting
            // an email to be sent; §7.5 sends nothing — it mints a code the owner
            // hands over themselves, and the screen has to say so before the
            // share sheet appears out of nowhere. SIM keeps the prototype's line.
            Text(shareService.sharesByCode
                ? "Send a code so friends and family can see live location and trips."
                : "Let friends and family see live location and trips.")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.shareHeaderTop)
        .padding(.bottom, 18)
    }

    // MARK: Email + invite row (screens.jsx:103-111)

    /// Whether the recipient field holds something submittable.
    ///
    /// SIM keeps the prototype's email regex verbatim. LIVE validates the §7.5.1
    /// `label` rule instead — non-blank, at most 120 characters — because there
    /// is no email in this contract and rejecting "Mom" for not looking like an
    /// address would be the app enforcing a rule the server does not have.
    private var validRecipient: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shareService.sharesByCode else {
            return trimmed.range(of: #"^.+@.+\..+$"#, options: .regularExpression) != nil
        }
        return !trimmed.isEmpty && trimmed.count <= 120
    }

    /// The recipient's display name. SIM derives it from the email
    /// (`emailToName`, screens.jsx:1237-1240); LIVE uses the typed label as-is —
    /// it IS the name (§7.5.1: an owner-typed memo, never resolved to an account).
    private var recipientName: String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return shareService.sharesByCode ? trimmed : ShareFixtures.name(fromEmail: email)
    }

    private var emailRow: some View {
        HStack(spacing: 10) {
            TextField("", text: $email)
                .textFieldStyle(.plain)
                .keyboardType(shareService.sharesByCode ? .default : .emailAddress)
                .textInputAutocapitalization(shareService.sharesByCode ? .words : .never)
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
                        Text(verbatim: shareService.sharesByCode ? "Their name" : "friend@example.com")
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
        guard validRecipient, let firstVehicle = shareService.shareableVehicles.first else {
            emailError = true
            emailShakeTrigger += 1
            Task {
                try? await Task.sleep(for: .milliseconds(500)) // jsx:1256
                emailError = false
            }
            return
        }
        accessLevel = .live
        // MYR-228 fix (a) — the FIRST REAL vehicle, from the seam. This was
        // `VehicleFixtures.vehicles[0].id` unconditionally, so a live owner's
        // invite was pre-selected against a car that is not on their account.
        shareVehicleIDs = [firstVehicle.id]
        sendStep = .config
    }

    // MARK: Viewers (screens.jsx:113-125)

    private var viewersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Viewers \u{00B7} \(shareService.viewers.count)")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.bottom, 14)
            if shareService.viewers.isEmpty {
                Text("No one has access yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.bottom, 14)
            }
            ForEach(shareService.viewers) { viewer in
                ViewerRow(viewer: viewer) { confirmRevoke = viewer }
            }
        }
    }

    // MARK: Pending (screens.jsx:127-138)

    @ViewBuilder
    private var pendingSection: some View {
        if !shareService.pending.isEmpty {
            Text("Pending")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.top, 20)
                .padding(.bottom, 14)
            ForEach(shareService.pending) { invite in
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
                // MYR-228 fix (a) — the owner's REAL fleet on the live path.
                ForEach(shareService.shareableVehicles) { vehicle in
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
            Avatar(name: recipientName, size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(recipientName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                // SIM shows the address under the derived name. LIVE has no
                // second line to show — the label IS the name — so it says what
                // the recipient will actually receive.
                Text(shareService.sharesByCode ? "Gets a 6-character code" : email)
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
        let recipientFirst = recipientName.split(separator: " ").first.map(String.init)
            ?? recipientName
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
            Text(shareService.sharesByCode ? recipientName : email)
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
            Text("We emailed \(recipientName) a link to join.")
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
    ///
    /// MYR-184 — the middle of that sequence is now a REAL `POST /api/vehicles/
    /// {id}/invites`. Three deliberate choices about the timing:
    ///
    ///  • The 1150ms "Sending invite…" beat is the prototype's, and it now runs
    ///    CONCURRENTLY with the create rather than in front of it — a fast server
    ///    still gets the full beat, a slow one does not get beat-plus-latency.
    ///  • The 950ms "Invite sent" celebration is SIM-ONLY. On live the meaningful
    ///    next step is handing the code over, so the sheet closes straight into
    ///    the system share sheet instead of holding a check mark first.
    ///  • A FAILED create shows the honest pill and leaves the composer's values
    ///    alone, so the owner can retry without retyping.
    private func doSend() {
        sendStep = .sending
        let recipient = recipientName
        let tier = accessLevel
        let ids = Array(shareVehicleIDs)
        Task { @MainActor in
            async let beat: Void = Task.sleep(for: .milliseconds(1150))
            let result: Result<ShareHandout?, Error>
            do {
                result = .success(try await shareService.createInvite(
                    label: recipient, tier: tier, vehicleIDs: ids
                ))
            } catch {
                result = .failure(error)
            }
            _ = try? await beat
            guard sendStep == .sending else { return }

            switch result {
            case .failure:
                sendStep = nil
                failureToast = "Couldn\u{2019}t create that invite"
            case .success(let minted):
                if let minted {
                    // Live: straight to the share sheet with the code.
                    sendStep = nil
                    handout = minted
                } else {
                    // Sim: the prototype's gold-check celebration, unchanged.
                    sendStep = .done
                    try? await Task.sleep(for: .milliseconds(950))
                    sendStep = nil
                }
                sentToastEmail = shareService.sharesByCode
                    ? recipient
                    : email.trimmingCharacters(in: .whitespacesAndNewlines)
                email = ""
            }
        }
    }

    // MARK: Dialogs (screens.jsx:1362-1422)

    private var resendDialogConfig: MRTConfirmDialogConfig {
        let invite = confirmResend
        return ShareDialogs.resend(invite ?? PendingInvite(name: "", email: "", sent: "")) {
            guard let invite else { return }
            Task { @MainActor in
                do {
                    // §7.5.4 mints a NEW code across every sibling row. The owner
                    // MUST be handed it — the old one is dead the instant this
                    // returns, so a resend that did not re-present the share sheet
                    // would leave both parties holding nothing that works.
                    if let minted = try await shareService.resend(invite) {
                        handout = minted
                    }
                    resentToastName = invite.name
                } catch {
                    failureToast = "Couldn\u{2019}t resend that invite"
                }
            }
        }
    }

    private var revokeDialogConfig: MRTConfirmDialogConfig {
        let viewer = confirmRevoke
        return ShareDialogs.revoke(viewer ?? Viewer(name: "", email: "", online: false, perm: "")) {
            guard let viewer else { return }
            Task { @MainActor in
                do {
                    try await shareService.revoke(viewer)
                    revokedToastName = viewer.name
                } catch {
                    // Never claim a revoke that did not happen.
                    failureToast = "Couldn\u{2019}t revoke access"
                }
            }
        }
    }

    private var cancelInviteDialogConfig: MRTConfirmDialogConfig {
        let invite = confirmCancelInvite
        return ShareDialogs.cancelInvite(invite ?? PendingInvite(name: "", email: "", sent: "")) {
            guard let invite else { return }
            Task { @MainActor in
                do { try await shareService.cancelInvite(invite) }
                catch { failureToast = "Couldn\u{2019}t cancel that invite" }
            }
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
    InvitesScreen(shareService: SimulatedShareService(), ownerTab: .constant("invites"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
