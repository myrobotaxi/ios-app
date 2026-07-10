import SwiftUI
import DesignSystem

// MARK: - SharedSettingsScreen (MYR-170, design/app/shared-screens.jsx
// 444-557, Handoff §5.9)
//
// Rider Settings: profile (Guest badge), "Shared with me" (whose Teslas this
// rider can ride, each with an access level) + "Enter invite code" row
// (`InviteCodeFlow`, `returning`), Notifications toggles, Sign out (confirm,
// guest copy) → SignInScreen. Renders its own `BottomNav` with
// `MRTTab.sharedTabs` — MYR-191 builds the rest of the rider tab shell (Live
// Map, Ride History); this screen is fully built + reachable now via
// `RootView`'s minimal rider shell (see that file).
struct SharedSettingsScreen: View {
    @Binding var sharedTab: String
    var riderName: String = "Sam" // shared-screens.jsx:451 `tweaks.riderName` devtool; M1 has no tweaks panel.
    /// MYR-224 — the real signed-in identity on the LIVE path, else nil (SIM →
    /// the fixture "Sam Rivera"). When non-nil, the profile card shows real
    /// name/email and the "Switch to Owner" row appears.
    var liveProfile: UserProfile? = nil
    /// MYR-224 — flip to the owner shell. Only invoked from the switch row, which
    /// renders only when `liveProfile != nil`.
    var onSwitchMode: () -> Void = {}
    let onAddCode: () -> Void
    let onSignOut: () -> Void

    private struct NotificationToggles {
        var requestUpdates = true
        var arrival = true
        var promos = false
    }

    @State private var toggles = NotificationToggles()
    @State private var confirmSignOut = false

    /// shared-screens.jsx:452-454 `firstName`/`fullName`/`email`.
    private var defaultedName: String {
        let trimmed = riderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sam" : trimmed
    }

    private var firstName: String {
        defaultedName.split(separator: " ").first.map(String.init) ?? defaultedName
    }

    private var fullName: String {
        let trimmedRaw = riderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedRaw.contains(" ") ? trimmedRaw : "\(firstName) Rivera"
    }

    private var email: String { "\(firstName.lowercased()).rivera@gmail.com" }

    // MYR-224 — the values actually rendered: real identity in LIVE mode, the
    // fixture "Sam Rivera" derivation in SIM (`liveProfile` nil → pixel-identical).
    private var displayFullName: String {
        liveProfile?.settingsDisplayName ?? fullName
    }

    /// The email line, or `nil` for a live account with no email on file → a
    /// calm absent state. SIM always has the fixture email.
    private var displayEmail: String? {
        liveProfile != nil ? liveProfile?.email : email
    }

    private var avatarInitial: String {
        liveProfile?.avatarInitial ?? String(firstName.prefix(1)).uppercased()
    }

    /// shared-screens.jsx:456-459 `sharedWith` — a local literal array in the
    /// prototype (not a hoisted fixture like `VIEWERS`), ported the same way.
    private struct SharedVehicleAccess: Identifiable {
        let owner: String
        let relationship: String
        let vehicle: String
        let access: String
        var id: String { owner }
    }

    private static let sharedWith: [SharedVehicleAccess] = [
        SharedVehicleAccess(owner: "Alex", relationship: "Roommate", vehicle: "Cybercab", access: "Request rides"),
        SharedVehicleAccess(owner: "Mom", relationship: "Family", vehicle: "Model Y", access: "Request rides"),
        SharedVehicleAccess(owner: "Jordan", relationship: "Friend", vehicle: "Model 3", access: "Request rides"),
    ]

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        profileCard
                        sharedWithLabel
                        sharedWithCard
                        notificationsLabel
                        notificationsCard
                        if liveProfile != nil {
                            switchModeCard
                        }
                        signOutButton
                        footer
                    }
                    .padding(.bottom, MRTMetrics.shareContentBottomPadding)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
        .mrtConfirmDialog(
            isPresented: $confirmSignOut,
            config: ShareDialogs.signOutGuest(action: onSignOut)
        )
    }

    // MARK: Header (shared-screens.jsx:694-696 `'74px 24px 12px'`)

    private var header: some View {
        Text("Settings")
            .mrtTextStyle(.screenTitle)
            .foregroundStyle(Color.mrtText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.top, MRTMetrics.shareHeaderTop)
            .padding(.bottom, 12)
    }

    // MARK: Profile (shared-screens.jsx:700-707)

    private var profileCard: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(
                    RadialGradient(
                        colors: [.mrtGold, .mrtRiderAvatarGradientEnd],
                        center: UnitPoint(x: 0.3, y: 0.3),
                        startRadius: 0,
                        endRadius: 24
                    )
                )
                Text(avatarInitial)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.mrtGoldButtonLabel)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayFullName)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                if let displayEmail {
                    Text(displayEmail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                } else {
                    Text("Email not shared")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextMuted)
                }
            }
            Spacer(minLength: 0)
            Text("Guest")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mrtGold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.mrtGoldBadgeFill, in: Capsule())
        }
        .padding(16)
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    // MARK: Shared with me (shared-screens.jsx:709-730)

    private var sharedWithLabel: some View {
        Text("Shared with me")
            .mrtTextStyle(.label())
            .foregroundStyle(Color.mrtTextMuted)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.bottom, 8)
    }

    private var sharedWithCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.sharedWith.enumerated()), id: \.element.id) { index, entry in
                sharedWithRow(entry, isFirst: index == 0)
            }
            addCodeRow
        }
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    private func sharedWithRow(_ entry: SharedVehicleAccess, isFirst: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.mrtElevated)
                Text(entry.owner.prefix(1))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.owner)\u{2019}s \(entry.vehicle)")
                    .font(.system(size: 14, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                Text("\(entry.relationship) \u{00B7} \(entry.access)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
            Image(systemName: "car.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.mrtTextMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }
        }
    }

    private var addCodeRow: some View {
        Button(action: onAddCode) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.mrtGoldBadgeFill)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.mrtGold)
                }
                .frame(width: 32, height: 32)
                Text("Enter invite code")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtGold)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Notifications (shared-screens.jsx:732-745)

    private var notificationsLabel: some View {
        Text("Notifications")
            .mrtTextStyle(.label())
            .foregroundStyle(Color.mrtTextMuted)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.bottom, 8)
    }

    private var notificationsCard: some View {
        VStack(spacing: 0) {
            notificationRow("Request accepted / declined", isOn: $toggles.requestUpdates, isFirst: true)
            notificationRow("Pick-up & arrival alerts", isOn: $toggles.arrival, isFirst: false)
            notificationRow("Tips & product news", isOn: $toggles.promos, isFirst: false)
        }
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    private func notificationRow(_ label: String, isOn: Binding<Bool>, isFirst: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .tracking(-0.1)
                .foregroundStyle(Color.mrtText)
            Spacer(minLength: 0)
            MRTToggle(isOn: isOn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }
        }
    }

    // MARK: Switch view mode (MYR-224 — client-approved chooser companion)
    //
    // Flips the rider shell to the owner shell. Reuses the rider Settings card
    // row anatomy verbatim (the `addCodeRow` / `sharedWithRow` shape,
    // shared-screens.jsx:709-730): a gold badge-fill icon circle + label +
    // trailing chevron inside a `mrtSurface(.card)`. Only present on the live
    // signed-in path; absent in SIM.
    private var switchModeCard: some View {
        Button(action: onSwitchMode) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.mrtGoldBadgeFill)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.mrtGold)
                }
                .frame(width: 32, height: 32)
                Text("Switch to Owner")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    // MARK: Sign out + footer (shared-screens.jsx:748-756)

    private var signOutButton: some View {
        Button {
            confirmSignOut = true
        } label: {
            Text("Sign out")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.mrtDialogRed)
                .frame(maxWidth: .infinity)
                .frame(height: MRTButtonSize.md.height)
                .overlay(
                    RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous)
                        .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MRTPressScaleButtonStyle())
        .padding(.horizontal, MRTMetrics.pageGutter)
    }

    private var footer: some View {
        Text("MyRoboTaxi \u{00B7} Guest access")
            .font(.system(size: 11))
            .foregroundStyle(Color.mrtTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

#Preview {
    SharedSettingsScreen(
        sharedTab: .constant("sharedSettings"),
        onAddCode: {},
        onSignOut: {}
    )
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
