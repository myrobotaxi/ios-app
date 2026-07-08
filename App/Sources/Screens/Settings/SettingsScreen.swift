import SwiftUI
import DesignSystem

// MARK: - SettingsScreen (MYR-170, design/app/screens.jsx 1562-1834, Handoff §5.8)
//
// Owner Settings tab: Profile, Tesla Account (linked vehicles + Primary
// badge, tap → detail sheet with Set-as-primary/Unlink, Add another Tesla),
// Shared with (viewer list + Revoke, Invite someone → Share tab),
// Notifications toggles, Sign out (confirm → back to Sign In). Renders its
// own `BottomNav` like every other owner screen — replaces the MYR-167
// `PlaceholderScreen` for the "settings" tab.
struct SettingsScreen: View {
    @Bindable var shareState: OwnerShareState
    @Bindable var vehiclesState: OwnerVehiclesState
    @Binding var ownerTab: String
    let onSignOut: () -> Void

    private struct NotificationToggles {
        var driveStarted = true
        var driveCompleted = true
        var chargingComplete = false
        var viewerJoined = true
    }

    @State private var toggles = NotificationToggles()
    @State private var vehicleDetail: Vehicle?
    @State private var confirmUnlink: Vehicle?
    @State private var confirmSignOut = false
    @State private var isAddingTesla = false
    @State private var confirmRevoke: Viewer?
    @State private var revokedToastName: String?

    var body: some View {
        Group {
            if isAddingTesla {
                // jsx:440 `onAddTesla` — replays the existing simulated
                // pairing celebration and returns to Settings. AddTeslaFlow's
                // fixture is hardcoded to the Cybercab vehicle (already
                // linked), so this demonstrates the flow without mutating
                // `vehiclesState` — see that type's header comment.
                AddTeslaFlow(
                    onComplete: { isAddingTesla = false },
                    onCancel: { isAddingTesla = false }
                )
            } else {
                settingsContent
            }
        }
    }

    private var settingsContent: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        profileSection
                        divider
                        teslaAccountHeader
                        vehiclesList
                        addTeslaRow
                        divider
                        sharedWithHeader
                        viewersList
                        inviteSomeoneRow
                        divider
                        notificationsSection
                        divider
                        signOutRow
                        footer
                    }
                    .padding(.bottom, MRTMetrics.shareContentBottomPadding)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .mrtBottomNav(selection: $ownerTab)
        .mrtConfigSheet(
            isPresented: Binding(get: { vehicleDetail != nil }, set: { if !$0 { vehicleDetail = nil } })
        ) {
            if let vehicle = vehicleDetail {
                vehicleDetailContent(vehicle)
            }
        }
        .mrtConfirmDialog(
            isPresented: $confirmSignOut,
            config: ShareDialogs.signOutOwner(action: onSignOut)
        )
        .mrtConfirmDialog(
            isPresented: Binding(get: { confirmUnlink != nil }, set: { if !$0 { confirmUnlink = nil } }),
            config: unlinkDialogConfig
        )
        .mrtConfirmDialog(
            isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
            config: revokeDialogConfig
        )
        .mrtSuccessToast(
            isPresented: Binding(get: { revokedToastName != nil }, set: { if !$0 { revokedToastName = nil } }),
            message: "Access revoked for \(revokedToastName ?? "")"
        )
    }

    // MARK: Header (screens.jsx:398-400)

    private var header: some View {
        Text("Settings")
            .mrtTextStyle(.screenTitle)
            .foregroundStyle(Color.mrtText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.top, MRTMetrics.shareHeaderTop)
            .padding(.bottom, 18)
    }

    private var divider: some View {
        Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
    }

    // MARK: Profile (screens.jsx:402-406)

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Profile")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 10)
            Text("Alex Cole")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.mrtText)
            // `Text(verbatim:)`, not a string literal — a literal here gets
            // Markdown-parsed and auto-linked (email-shaped text renders in
            // the accent color, ignoring `.foregroundStyle`) — see
            // InvitesScreen's `emailRow` comment for the full story.
            Text(verbatim: "alex@cole.run")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 24)
    }

    // MARK: Tesla Account (screens.jsx:409-444)

    private var teslaAccountHeader: some View {
        HStack {
            Text("Tesla Account")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                PulseDot(color: .mrtDriving, size: 6)
                Text("Linked \u{00B7} synced 14s ago")
                    .font(.system(size: 11))
                    .tracking(0.2)
                    .foregroundStyle(Color.mrtTextSec)
            }
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var vehiclesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(vehiclesState.vehicles.enumerated()), id: \.element.id) { index, vehicle in
                vehicleRow(vehicle, isFirst: index == 0)
            }
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 8)
    }

    private func vehicleRow(_ vehicle: Vehicle, isFirst: Bool) -> some View {
        let isPrimary = vehicle.id == vehiclesState.primaryID
        return Button {
            vehicleDetail = vehicle
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.mrtSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                        )
                    Image(systemName: "car.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(isPrimary ? Color.mrtGold : Color.mrtTextSec)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(vehicle.name)
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(Color.mrtText)
                        if isPrimary { PrimaryBadge() }
                    }
                    Text("\(vehicle.model) \u{00B7} \(vehicle.plate)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addTeslaRow: some View {
        plusRow("Add another Tesla") { isAddingTesla = true }
            .padding(.bottom, 20)
    }

    private var inviteSomeoneRow: some View {
        plusRow("Invite someone") { ownerTab = "invites" }
            .padding(.bottom, 20)
    }

    private func plusRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.mrtGold)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
            }
            .frame(minHeight: MRTMetrics.minTapTarget - 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MRTMetrics.pageGutter)
    }

    // MARK: Shared with (screens.jsx:447-470)

    private var sharedWithHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Shared with")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            Spacer(minLength: 0)
            Text("\(shareState.viewers.count) \(shareState.viewers.count == 1 ? "person" : "people")")
                .font(.system(size: 11))
                .foregroundStyle(Color.mrtTextMuted)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var viewersList: some View {
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

    // MARK: Notifications (screens.jsx:473-486)

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 14)
            notificationRow("Drive started", isOn: $toggles.driveStarted)
            notificationRow("Drive completed", isOn: $toggles.driveCompleted)
            notificationRow("Charging complete", isOn: $toggles.chargingComplete)
            notificationRow("Viewer joined", isOn: $toggles.viewerJoined)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.vertical, 20)
    }

    private func notificationRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.mrtText)
            Spacer(minLength: 0)
            MRTToggle(isOn: isOn)
        }
        .padding(.vertical, 12)
    }

    // MARK: Sign out + footer (screens.jsx:488-493)

    private var signOutRow: some View {
        HStack {
            Button {
                confirmSignOut = true
            } label: {
                Text("Sign out")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtDialogRed)
                    .frame(minHeight: MRTMetrics.minTapTarget)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        Text("MyRoboTaxi v1.0 (24)")
            .font(.system(size: 11))
            .tracking(0.4)
            .foregroundStyle(Color.mrtTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 40)
    }

    // MARK: Vehicle detail sheet (screens.jsx:1585-1642)

    private func vehicleDetailContent(_ vehicle: Vehicle) -> some View {
        let isPrimary = vehicle.id == vehiclesState.primaryID
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.mrtSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                        )
                    Image(systemName: "car.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(isPrimary ? Color.mrtGold : Color.mrtTextSec)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(vehicle.name)
                            .font(.system(size: 19, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Color.mrtText)
                        if isPrimary { PrimaryBadge() }
                    }
                    Text("\(vehicle.model) \u{00B7} \(vehicle.plate)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.mrtGold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isPrimary ? "This is your primary Tesla" : "About primary")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mrtText)
                    Text("Your primary Tesla is the one shown by default on the map and used for new ride requests and sharing.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineSpacing(3)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .padding(.bottom, 18)

            VStack(spacing: 9) {
                if !isPrimary {
                    Button {
                        vehiclesState.setPrimary(vehicle.id)
                        vehicleDetail = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                            Text("Set as primary").font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Color.mrtGold)
                        .frame(maxWidth: .infinity)
                        .frame(height: MRTButtonSize.md.height)
                        .background(
                            Color.mrtInviteAccessTintLight,
                            in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                                .strokeBorder(Color.mrtPrimaryButtonBorder, lineWidth: MRTMetrics.hairline)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MRTPressScaleButtonStyle())
                }
                Button {
                    vehicleDetail = nil
                    confirmUnlink = vehicle
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        Text("Unlink this Tesla").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color.mrtDialogRed)
                    .frame(maxWidth: .infinity)
                    .frame(height: MRTButtonSize.md.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                            .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(MRTPressScaleButtonStyle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    // MARK: Dialogs

    private var unlinkDialogConfig: MRTConfirmDialogConfig {
        let vehicle = confirmUnlink
        return MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "car.fill",
            title: "Unlink \(vehicle?.name ?? "")?",
            message: "MyRoboTaxi will lose access to this Tesla and everyone you've shared it with will be removed. You can re-add it anytime.",
            actionLabel: "Unlink Tesla",
            dismissLabel: "Keep linked"
        ) {
            guard let vehicle else { return }
            vehiclesState.unlink(vehicle.id)
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
}

// MARK: - "Primary" badge (screens.jsx:430,547 — identical in the vehicle
// row and the vehicle-detail sheet header).
private struct PrimaryBadge: View {
    var body: some View {
        Text("Primary")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(Color.mrtGold)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.mrtGoldBadgeFill, in: Capsule())
    }
}

#Preview {
    SettingsScreen(
        shareState: OwnerShareState(),
        vehiclesState: OwnerVehiclesState(),
        ownerTab: .constant("settings"),
        onSignOut: {}
    )
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
