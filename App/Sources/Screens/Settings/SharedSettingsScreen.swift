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
    /// MYR-349 — see `SettingsScreen.pushPrefs`. The rider's card is ONE row over
    /// the ONE `ride_lifecycle` category (MYR-354 merged the prototype's pair);
    /// see `notificationsCard`.
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

    /// MYR-354 — the whole vehicle section, resolved by the ONE rule that also
    /// answers the shell (`RiderVehicleSet`), so the tab and the map can never
    /// disagree about whether this account has a car.
    private var vehicleSection: RiderSettingsVehicleSection {
        RiderSettingsVehicleSection.resolve(
            hasLoaded: catalog.hasLoaded,
            loadFailed: catalog.loadFailed,
            owned: catalog.ownedVehicles,
            shared: sharedList
        )
    }

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        profileCard
                        vehicleSectionLabel
                        vehicleSectionCard
                        notificationsLabel
                        notificationsCard
                        SettingsSectionNotices {
                            // MYR-349 — a write that did not land, or a read that
                            // did not answer. Never present on the simulated path
                            // (`statusMessage` is always nil there), so no DEBUG
                            // capture can reach it.
                            PushPrefsNotice(message: pushPrefs.statusMessage)
                            // MYR-186 — renders only when the system authorization
                            // was DENIED; absent (and pixel-identical) in every
                            // other state, including the whole simulated path.
                            PushDeniedNotice(state: pushAuthorization)
                        }
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
        // MYR-355 — the account-deletion confirm; MYR-366 — the visual offboarding
        // flow that replaced the second dialog. Identical to the owner screen's
        // (one flow object, one copy factory, one screen), and the ROLE is the
        // only difference: this shell narrates the rider's four steps and ends on
        // the check-hero, since a rider has no manual Tesla steps to perform.
        .mrtConfirmDialog(
            isPresented: $deletion.isPresentingFirstConfirm,
            config: deletion.firstConfirmConfig
        )
        .fullScreenCover(isPresented: $deletion.isPresentingOffboarding) {
            AccountOffboardingScreen(flow: deletion)
        }
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
            .padding(.bottom, MRTSettingsGrammar.headerBottomPadding)
    }

    // MARK: Profile (shared-screens.jsx:700-707 — now `SettingsProfileCard`,
    // shared with the owner page, MYR-354)

    private var profileCard: some View {
        SettingsProfileCard(
            initial: avatarInitial,
            name: displayFullName,
            email: displayEmail,
            roleBadge: "Guest"
        )
    }

    // MARK: Vehicles / Shared with me (shared-screens.jsx:709-730)

    private var vehicleSectionLabel: some View {
        SettingsSectionLabel(vehicleSection.label)
    }

    private var vehicleSectionCard: some View {
        SettingsCard {
            ForEach(Array(vehicleSection.rows.enumerated()), id: \.offset) { index, row in
                vehicleRow(row, isFirst: index == 0)
            }
        }
    }

    @ViewBuilder
    private func vehicleRow(_ row: RiderSettingsVehicleSection.Row, isFirst: Bool) -> some View {
        switch row {
        case .owned(_, let name):
            // MYR-354 — the client's own question, answered in the one place he
            // went looking for it. Gold `car.fill` rather than a name initial:
            // the gold accent's job on this page is "yours / actionable", and
            // this is the only vehicle row on the account that is both. No
            // trailing glyph — a shared row's muted trailing `car.fill` says
            // "this is a vehicle", which the leading glyph has already said here.
            SettingsDetailRow(
                glyph: SettingsRowGlyph(tone: .gold, systemName: "car.fill"),
                title: name,
                caption: RiderSettingsVehicleSection.ownedCaption,
                isFirst: isFirst
            )
        case .shared(_, let title, let caption):
            SettingsDetailRow(
                glyph: SettingsRowGlyph(
                    // The initial of whatever the row is titled — the persona's
                    // name in SIM, the vehicle's nickname on live (which has no
                    // owner name to take an initial from; see
                    // `SharedVehicleGrant.ownerName`).
                    initial: String(title.prefix(1))
                ),
                title: title,
                caption: caption,
                isFirst: isFirst
            ) {
                Image(systemName: "car.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.mrtTextMuted)
            }
        case .empty:
            // The account has NOTHING — neither owned nor shared (MYR-354). A
            // calm, intentional empty state that points at the invite-code row
            // below (MYR-255); before this issue it also rendered for an OWNER,
            // which is the confusion the client reported.
            SettingsDetailRow(
                glyph: SettingsRowGlyph(systemName: "car.fill", size: 13),
                title: "No vehicles shared with you yet",
                caption: "Enter an invite code to ride someone\u{2019}s Tesla.",
                isFirst: isFirst
            )
        case .unavailable:
            SettingsNoticeRow(text: RiderSettingsVehicleSection.unavailableText, isFirst: isFirst)
        case .enterCode:
            SettingsActionRow(icon: "plus", title: "Enter invite code", isFirst: isFirst, action: onAddCode)
        }
    }

    // MARK: Notifications (shared-screens.jsx:732-745)

    private var notificationsLabel: some View {
        SettingsSectionLabel("Notifications")
    }

    /// TWO SWITCHES, ONE PREFERENCE (MYR-354, from MYR-349's prefs work).
    ///
    /// The prototype offered "Request accepted / declined" and "Pick-up &
    /// arrival alerts" as separate rows. They are not separate: §7.19 has ONE
    /// `ride_lifecycle` category and no send site distinguishes them, so the two
    /// switches were one preference wearing two masks — flip either and both
    /// move, and the one the rider did not touch appears to change by itself.
    /// A control that cannot deliver what it offers is worse than an absent one,
    /// so they are ONE row now, with a sub-line naming everything it governs.
    /// That was MYR-349's own stated OPEN QUESTION (it shipped both rows over one
    /// value and left the STRUCTURE to this issue); the merge is the answer, and
    /// it lands in `SettingsNotificationRows.rider` so the table stays the one
    /// place either page's rows are declared.
    ///
    /// The "Tips & product news" row is GONE (MYR-349, the client: "the tips
    /// notification seems useless"). It was the one row with no send site behind
    /// it at all, and §7.19 deliberately has no column for it — so the rider card
    /// is exactly one row, and it is the merged one.
    private var notificationsCard: some View {
        SettingsCard {
            ForEach(Array(SettingsNotificationRows.rider.enumerated()), id: \.element.id) { index, row in
                SettingsToggleRow(
                    label: row.label,
                    caption: row.caption,
                    // MYR-349 — the row RENDERS the service's value and WRITES
                    // through it; the optimistic / echo / rollback pattern lives
                    // in `PushPrefsService` alone. See `SettingsScreen
                    // .pushPrefsBinding` for why the setter is fire-and-forget.
                    isOn: Binding(
                        get: { pushPrefs.prefs[row.category] },
                        set: { newValue in Task { await pushPrefs.setEnabled(row.category, newValue) } }
                    ),
                    isFirst: index == 0
                )
            }
        }
    }

    // MARK: Switch view mode (MYR-224 — client-approved chooser companion)
    //
    // Flips the rider shell to the owner shell. The shared `SettingsActionRow`
    // in its own card. Only present on the live signed-in path; absent in SIM.
    private var switchModeCard: some View {
        SettingsCard {
            SettingsActionRow(
                icon: "arrow.left.arrow.right",
                title: "Switch to Owner",
                emphasizesTitle: false,
                isFirst: true,
                action: onSwitchMode
            )
        }
    }

    // MARK: Account (MYR-355 — App Store Guideline 5.1.1(v))
    //
    // Self-contained and appended at the END of the list, assembled from the ONE
    // shared grammar (MYR-354 / #139) exactly as the owner page's copy is — same
    // `SettingsSectionLabel`, same `SettingsCard`, same two row types. This page
    // had hand-rolled the card's own numbers (16 / 13 / 22 inline) because the
    // grammar file did not exist when it was written; those literals ARE
    // `MRTSettingsGrammar.rowHorizontalPadding` / `.rowVerticalPadding` /
    // `.sectionSpacing`, so the pixels are the same and the fork is gone.
    //
    // **MYR-366 removed the identity row this section opened with** — the
    // client's "it shows the email again". See `SettingsScreen`'s copy of this
    // comment for the cause (`settingsDisplayName` falls through to the email for
    // any account Apple never named). The section is now exactly one thing: the
    // way out of the product.

    private var accountLabel: some View {
        SettingsSectionLabel(AccountDeletionDialog.sectionTitle)
    }

    private var accountCard: some View {
        SettingsCard {
            deleteAccountRow
        }
    }

    /// The destructive row, in the shared danger grammar — see
    /// `SettingsDestructiveRow`. Byte-identical to the owner page's, which is the
    /// point of both pages taking it from one place.
    private var deleteAccountRow: some View {
        SettingsDestructiveRow(
            icon: "trash",
            title: AccountDeletionDialog.deleteRowLabel,
            isFirst: true,
            accessibilityID: "mrt.deleteAccountRow"
        ) {
            deletion.begin(role: .shared)
        }
    }

    // MARK: Sign out + footer (shared-screens.jsx:748-756)

    private var signOutButton: some View {
        SettingsSignOutButton { confirmSignOut = true }
    }

    private var footer: some View {
        // MYR-395 — r16: "How come rider screen shows guest access at bottom and
        // other shows version?" One footer, both roles. The access level the old
        // line carried is not lost: the "Guest" badge sits in `profileCard` at the
        // top of this same page, and the per-vehicle answer is `vehicleSection`.
        SettingsFooter.appVersion
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
