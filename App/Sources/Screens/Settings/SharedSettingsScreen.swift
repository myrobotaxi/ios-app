import SwiftUI
import DesignSystem
import MyRoboTaxiKit

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
    /// MYR-184 — the rider's shared-vehicle catalog, the ONE source for the
    /// "Shared with me" list in BOTH modes.
    ///
    /// This supersedes MYR-255's `isLive` gate, which existed because there was
    /// no shared-with-me endpoint at all and the live path therefore had to render
    /// an honest empty state rather than the fixture personas (Alex/Mom/Jordan).
    /// MYR-184's viewer merge lands those rows on `GET /api/vehicles` with
    /// `role: viewer`, so the live list is now REAL. The simulated catalog
    /// publishes the prototype's three personas verbatim, so SIM is unchanged.
    var catalog: any SharedVehicleCatalog = SimulatedSharedVehicleCatalog()
    /// MYR-186 — see `SettingsScreen.pushAuthorization`.
    var pushAuthorization: PushAuthorizationState = .notDetermined
    /// MYR-349 — see `SettingsScreen.pushPrefs`. The rider's two rows share ONE
    /// category; see `notificationsCard`.
    var pushPrefs: any PushPrefsService = SimulatedPushPrefsService()
    /// MYR-224 — flip to the owner shell. Only invoked from the switch row, which
    /// renders only when `liveProfile != nil`.
    var onSwitchMode: () -> Void = {}
    let onAddCode: () -> Void
    let onSignOut: () -> Void
    /// MYR-355 — see `SettingsScreen.accountDeletion`.
    var accountDeletion: (any AccountDeletionEndpoint)? = nil
    /// MYR-355 — see `SettingsScreen.onAccountDeleted`.
    var onAccountDeleted: () -> Void = {}

    /// MYR-355 — scroll anchor for the DEBUG deletion capture scenes (see below).
    private static let bottomAnchorID = "mrt-shared-settings-bottom"

    @State private var confirmSignOut = false
    /// MYR-355 — the account-deletion interaction; see `AccountDeletionFlow`.
    @State private var deletion = AccountDeletionFlow()

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

    /// The rows actually rendered. shared-screens.jsx:456-459 `sharedWith` was a
    /// local literal array in the prototype (not a hoisted fixture like `VIEWERS`);
    /// it now lives on `SimulatedSharedVehicleCatalog`, so this screen reads ONE
    /// seam in both modes and the live rows arrive by the same path.
    private var sharedList: [SharedVehicleGrant] { catalog.grants }

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        profileCard
                        sharedWithLabel
                        sharedWithCard
                        notificationsLabel
                        notificationsCard
                        // MYR-349 — a write that did not land, or a read that did
                        // not answer. Never present on the simulated path.
                        PushPrefsNotice(message: pushPrefs.statusMessage)
                            .padding(.horizontal, MRTMetrics.pageGutter)
                        // MYR-186 — renders only when the system authorization was
                        // DENIED; absent (and pixel-identical) in every other
                        // state, including the whole simulated path.
                        PushDeniedNotice(state: pushAuthorization)
                            .padding(.horizontal, MRTMetrics.pageGutter)
                        if liveProfile != nil {
                            switchModeCard
                        }
                        // MYR-355 — appended at the END of the list, so Sign out
                        // stays the terminal action.
                        accountLabel
                        accountCard
                        signOutButton
                        footer
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.bottom, MRTMetrics.shareContentBottomPadding)
                }
                #if DEBUG
                // Capture-only, MYR-355: the Account section this issue appends is
                // below this screen's fold, and headless simctl has no scroll
                // gesture. Scoped to the deletion scenes ALONE — `riderSettings`
                // itself is deliberately NOT included, so it stays framed exactly
                // where the drift gate has always framed it (at the top).
                .onAppear {
                    if DebugScene.current?.accountDeletionStage != nil {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                #endif
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
        .mrtConfirmDialog(
            isPresented: $confirmSignOut,
            config: ShareDialogs.signOutGuest(action: onSignOut)
        )
        // MYR-355 — the two-step account-deletion dialogs + its notice + its busy
        // overlay, identical to the owner screen's (one flow, one copy factory).
        .mrtConfirmDialog(
            isPresented: $deletion.isPresentingFirstConfirm,
            config: deletion.firstConfirmConfig
        )
        .mrtConfirmDialog(
            isPresented: $deletion.isPresentingSecondConfirm,
            config: deletion.secondConfirmConfig
        )
        // The SAME alert grammar the §7.12 teardown failure uses — Settings'
        // existing destructive-failure surface. A calm, honest end state; never a
        // fake success, and never a sign-out (the account may still exist).
        .alert(
            AccountDeletionDialog.failureNoticeTitle,
            isPresented: $deletion.isPresentingErrorNotice
        ) {
            SwiftUI.Button("OK", role: .cancel) { deletion.errorNotice = nil }
        } message: {
            // The second half of the ONE locked notice string — see
            // `AccountDeletionDialog.failureNoticeBody`. `deletion.errorNotice`
            // carries that string whole and is what raises this alert.
            Text(AccountDeletionDialog.failureNoticeBody)
        }
        .overlay { AccountDeletionBusyOverlay(isDeleting: deletion.isDeleting) }
        // MYR-184 — refresh on arrival so a grant revoked by its owner stops
        // being listed here. No-op in sim.
        .task { await catalog.load() }
        // MYR-349 — hydrate the notification rows from §7.19. No-op in sim.
        .task { await pushPrefs.load() }
        .task { await prepareAccountDeletion() }
    }

    /// MYR-355 — hand the flow its seams once the screen is on; see
    /// `SettingsScreen.prepareAccountDeletion`.
    @MainActor
    private func prepareAccountDeletion() async {
        deletion.endpoint = accountDeletion
        deletion.onDeleted = onAccountDeleted
        #if DEBUG
        if let stage = DebugScene.current?.accountDeletionStage {
            await deletion.debugDrive(to: stage, role: .shared)
        }
        #endif
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
            if sharedList.isEmpty {
                // Honest empty state on the live path — never fixture personas.
                emptySharedRow
            } else {
                ForEach(Array(sharedList.enumerated()), id: \.element.id) { index, entry in
                    sharedWithRow(entry, isFirst: index == 0)
                }
            }
            addCodeRow
        }
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    /// Live path, no shared vehicles yet — a calm, intentional empty state that
    /// points the rider at the invite-code row below (MYR-255).
    private var emptySharedRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.mrtElevated)
                Image(systemName: "car.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("No vehicles shared with you yet")
                    .font(.system(size: 14, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                Text("Enter an invite code to ride someone\u{2019}s Tesla.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func sharedWithRow(_ entry: SharedVehicleGrant, isFirst: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.mrtElevated)
                // The initial of whatever the row is titled — the persona's name
                // in SIM, the vehicle's nickname on live (which has no owner name
                // to take an initial from; see `SharedVehicleGrant.ownerName`).
                Text(entry.title.prefix(1))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                Text(entry.caption)
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

    // MYR-349 — BOTH rider rows bind to the SAME §7.19 category, `rideLifecycle`,
    // and therefore always agree and always move together.
    //
    // That is the backend schema, not a shortcut: `ride_lifecycle` covers the whole
    // requested / accepted / declined / en route / arrived / completed / expired
    // status class, and EVERY rider-facing send site sits inside it. There is no
    // column that could switch "Request accepted / declined" off while leaving
    // "Pick-up & arrival alerts" on. Faking that independence with a second local
    // flag would rebuild the exact defect this issue is closing — a switch that
    // moves and means nothing — so the honest render is two rows over one value.
    //
    // THE OPEN DESIGN QUESTION, called out in the PR: either the server splits the
    // column in two, or MYR-354's Settings restructure merges these into one row.
    // Row STRUCTURE belongs to MYR-354, which is restructuring both Settings pages
    // in parallel, so neither row is merged or removed here.
    //
    // The "Tips & product news" row is GONE (the client: "the tips notification
    // seems useless"). It was the one row with no send site behind it at all, and
    // §7.19 deliberately has no column for it.
    private var notificationsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(SettingsNotificationRows.rider.enumerated()), id: \.element.id) { index, row in
                notificationRow(row.label, category: row.category, isFirst: index == 0)
            }
        }
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    /// See `SettingsScreen.notificationRow` — same seam, same binding, same
    /// fire-and-forget setter. Layout is untouched.
    private func notificationRow(_ label: String, category: PushPrefCategory, isFirst: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .tracking(-0.1)
                .foregroundStyle(Color.mrtText)
            Spacer(minLength: 0)
            MRTToggle(isOn: Binding(
                get: { pushPrefs.prefs[category] },
                set: { newValue in Task { await pushPrefs.setEnabled(category, newValue) } }
            ))
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

    // MARK: Account (MYR-355 — App Store Guideline 5.1.1(v))
    //
    // Self-contained and appended at the END of the list, in THIS screen's own
    // grammar: a `.label()` header over a `mrtSurface(.card)` holding two rows
    // separated by the standard hairline (the `sharedWithCard` shape). Exactly two
    // things: who is signed in, and the way out of the product.

    private var accountLabel: some View {
        Text("Account")
            .mrtTextStyle(.label())
            .foregroundStyle(Color.mrtTextMuted)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.bottom, 8)
    }

    private var accountCard: some View {
        VStack(spacing: 0) {
            accountNameRow
            deleteAccountRow
        }
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 22)
    }

    /// DISPLAY-ONLY, with no rename affordance — see
    /// `SettingsScreen.accountNameRow` for why (there is no profile-update
    /// endpoint to reach). Reads the same `displayFullName` the profile card at
    /// the top does: the real identity on live, the fixture persona in SIM.
    private var accountNameRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayFullName)
                .font(.system(size: 14, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(Color.mrtText)
            Text("Set by Apple when you signed in")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.mrtTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    /// The destructive row, in the danger grammar this app already uses for
    /// "Unlink this Tesla" / "Remove this car" (the `trash` glyph + a
    /// `mrtDialogRed` label), at the 44pt tap target.
    private var deleteAccountRow: some View {
        Button { deletion.begin(role: .shared) } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                Text("Delete account")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.mrtDialogRed)
            .padding(.horizontal, 16)
            .frame(minHeight: MRTMetrics.minTapTarget)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
