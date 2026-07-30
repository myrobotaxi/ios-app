import SwiftUI
import DesignSystem
import MyRoboTaxiKit

// MARK: - SettingsScreen (MYR-170, design/app/screens.jsx 1562-1834, Handoff §5.8)
//
// Owner Settings tab: Profile, Tesla Account (linked vehicles + Primary
// badge, tap → detail sheet with Set-as-primary/Unlink, Add another Tesla),
// Shared with (viewer list + Revoke, Invite someone → Share tab),
// Notifications toggles, Sign out (confirm → back to Sign In). Renders its
// own `BottomNav` like every other owner screen — replaces the MYR-167
// `PlaceholderScreen` for the "settings" tab.
struct SettingsScreen: View {
    /// MYR-184 — the `ShareService` seam (was the concrete `OwnerShareState`).
    /// This screen reads the viewer list and revokes from it; the invite
    /// composer lives on `InvitesScreen`.
    let shareService: any ShareService
    @Bindable var vehiclesState: OwnerVehiclesState
    @Binding var ownerTab: String
    /// MYR-224 — the real signed-in identity on the LIVE path, else nil (SIM →
    /// the fixture "Alex Cole"). When non-nil, the Profile section shows real
    /// name/email and the "Switch to Rider" row appears.
    var liveProfile: UserProfile? = nil
    /// MYR-224 — flip to the rider shell. Only invoked from the switch row, which
    /// renders only when `liveProfile != nil`.
    var onSwitchMode: () -> Void = {}
    /// MYR-243 — the live fleet's read-only linked-vehicle source. Non-nil ONLY
    /// on the true live path; when present, the Tesla Account section renders the
    /// account's REAL vehicles (read-only) plus honest connecting/notice states,
    /// instead of the fixture `vehiclesState`. `nil` on sim / DEBUG keeps that
    /// fixture list pixel-identical (MYR-228).
    var linkedVehicles: (any LinkedVehiclesReading)? = nil
    let onSignOut: () -> Void
    /// MYR-246 — the live Tesla OAuth authenticator (nil on sim/DEBUG, which
    /// keeps the simulated pairing sheet pixel-identical). Wired from RootView
    /// like `linkedVehicles`; when present, "Add another Tesla" runs the REAL
    /// ASWebAuthenticationSession link flow instead of the fixture sheet.
    var teslaAuthenticator: TeslaAuthenticator? = nil
    /// Fired after a successful live link so the caller can refresh the fleet.
    var onTeslaLinked: (() -> Void)? = nil
    /// MYR-301 — armed by a vehicle-command re-link notice ("Reconnect Tesla for
    /// charging access") via `TeslaRelinkRoute`: Settings opens its EXISTING
    /// `AddTeslaFlow` immediately on arrival, so the notice's fix is one tap, not
    /// a scavenger hunt through the Tesla Account section. Read declaratively in
    /// `body` (no `onAppear` race) and cleared when the flow closes. Defaults to a
    /// constant `false`, so every other host is unchanged.
    var startTeslaLink: Binding<Bool> = .constant(false)
    /// MYR-258 — the live owner car-offboarding seam (§7.12): the real teardown
    /// call + fleet drop + consent-revoke browser session. Non-nil ONLY on the
    /// live path; when present, the vehicle detail sheet's destructive action runs
    /// the authoritative `removeVehicle` teardown (busy → drop → post-teardown
    /// sheet) instead of the local `vehiclesState.unlink`. `nil` on sim / DEBUG
    /// keeps that local unlink pixel-identical (MYR-228).
    var teardown: VehicleTeardownSeam? = nil
    /// MYR-186 — the system notification-authorization state. Drives the
    /// `PushDeniedNotice` under the toggles and nothing else; `.notDetermined`
    /// (the default, and what the simulated path always reports) renders nothing.
    var pushAuthorization: PushAuthorizationState = .notDetermined
    /// MYR-349 — the account's real per-category push preferences (rest-api.md
    /// §7.19). This REPLACES the `@State private var toggles = NotificationToggles()`
    /// struct these rows used to move: it persisted nowhere and gated nothing, so
    /// a switch turned off came back on at the next launch and the notification
    /// arrived either way. The default is the simulated service, which keeps the
    /// prototype's own positions and touches no network, so every simulated and
    /// DEBUG capture is unchanged.
    ///
    /// MYR-354 adds the owner's `ride_lifecycle` row on top of this seam. The
    /// category already gated the owner's "X wants a ride" pushes; the ROW simply
    /// did not exist, so there was nothing local to migrate — it reads and writes
    /// the same account value every other row here does.
    var pushPrefs: any PushPrefsService = SimulatedPushPrefsService()
    /// MYR-355 — the account-deletion seam (`DELETE /api/users/me`). Non-nil on the
    /// live path; `nil` on sim / DEBUG, where there is no server account and the
    /// confirmed delete resolves to the local wipe alone (see `AccountDeletionFlow`).
    var accountDeletion: (any AccountDeletionEndpoint)? = nil
    /// MYR-355 — run after a successful delete. `RootView` wires this to the SAME
    /// local sign-out helper the Sign out row's closure calls, so a deleted account
    /// and a signed-out one leave the app in exactly one state.
    var onAccountDeleted: () -> Void = {}

    // MARK: Tesla Account — live-path display state (MYR-243)

    /// What the read-only Tesla Account section shows on the LIVE path, derived
    /// from the live fleet. A value type so the honest-state precedence is unit
    /// tested without SwiftUI.
    enum TeslaAccountLiveState: Equatable {
        /// Fleet list still loading — a calm connecting line.
        case connecting
        /// An honest one-liner: empty account, auth required, or unreachable —
        /// the fleet's own copy (never a fixture).
        case notice(String)
        /// The account's real linked vehicles (read-only).
        case linked([Vehicle])
    }

    /// Map the live fleet's read model to the section state. Precedence: any
    /// loaded vehicles WIN (show them the moment they arrive, even if a stale
    /// notice lingers); else a still-loading fleet shows the connecting state;
    /// else the fleet's honest notice, falling back to the Settings empty copy.
    /// NEVER fixtures.
    static func liveState(
        vehicles: [Vehicle],
        isConnecting: Bool,
        statusMessage: String?
    ) -> TeslaAccountLiveState {
        if !vehicles.isEmpty { return .linked(vehicles) }
        if isConnecting { return .connecting }
        if let statusMessage, !statusMessage.trimmingCharacters(in: .whitespaces).isEmpty {
            return .notice(statusMessage)
        }
        return .notice("No Tesla linked yet.")
    }

    /// Scroll anchor for the DEBUG `ownerSettings` capture scene (see below).
    private static let bottomAnchorID = "mrt-settings-bottom"

    @State private var vehicleDetail: Vehicle?
    @State private var confirmUnlink: Vehicle?
    @State private var confirmSignOut = false
    @State private var isAddingTesla = false
    @State private var confirmRevoke: Viewer?
    @State private var revokedToastName: String?
    /// MYR-184 — a revoke that FAILED. Same quiet bottom pill as the success,
    /// because saying nothing would leave the owner believing access was cut.
    @State private var revokeFailed = false
    // MYR-258 — live car-offboarding (§7.12) transient state.
    /// The car whose teardown `DELETE` is in flight (drives the busy overlay).
    @State private var teardownInFlight: Vehicle?
    /// The successful teardown response — drives the post-teardown "Car removed"
    /// sheet with the two owner-only follow-ups.
    @State private var teardownResult: VehicleTeardownResponse?
    /// Honest failure copy for a teardown that couldn't complete (rare — atomic,
    /// retryable server-side).
    @State private var teardownError: String?
    /// MYR-355 — the account-deletion interaction (both dialogs, the in-flight
    /// write, the failure notice). ONE object rather than three `@State` flags —
    /// see `AccountDeletionFlow`.
    @State private var deletion = AccountDeletionFlow()

    var body: some View {
        Group {
            // MYR-301 — either the owner tapped "Add another Tesla" here, or a
            // command notice routed them in with the flow armed.
            if isAddingTesla || startTeslaLink.wrappedValue {
                // jsx:440 `onAddTesla` — replays the existing simulated
                // pairing celebration and returns to Settings. AddTeslaFlow's
                // fixture is hardcoded to the Cybercab vehicle (already
                // linked), so this demonstrates the flow without mutating
                // `vehiclesState` — see that type's header comment.
                AddTeslaFlow(
                    onComplete: { closeAddTesla() },
                    onCancel: { closeAddTesla() },
                    // MYR-246 — live path uses the real browser-sheet link
                    // flow; sim (nil) keeps the fixture sheet.
                    authenticate: teslaAuthenticator,
                    onLinked: onTeslaLinked
                )
            } else {
                settingsContent
            }
        }
    }

    /// Close the link flow whichever way it was opened (MYR-301) — the armed
    /// route must be disarmed too, or Settings would re-open it forever.
    private func closeAddTesla() {
        isAddingTesla = false
        startTeslaLink.wrappedValue = false
    }

    private var settingsContent: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            profileSection
                            teslaAccountHeader
                            teslaAccountCard
                            sharedWithHeader
                            sharedWithCard
                            notificationsLabel
                            notificationsCard
                            SettingsSectionNotices {
                                // MYR-349 — a write that did not land, or a read
                                // that did not answer. Never present on the
                                // simulated path (`statusMessage` is always nil
                                // there), so no DEBUG capture can reach it.
                                PushPrefsNotice(message: pushPrefs.statusMessage)
                                // MYR-186 — renders only when the system
                                // authorization was DENIED; absent (and therefore
                                // pixel-identical) in every other state, including
                                // the whole simulated path.
                                PushDeniedNotice(state: pushAuthorization)
                            }
                            if liveProfile != nil {
                                switchModeCard
                            }
                            // MYR-355 — appended at the END of the list, so Sign out
                            // stays terminal. Post-#139 there is no divider to place:
                            // the card IS the section boundary, and `SettingsCard`
                            // already carries the section gap below itself.
                            accountLabel
                            accountCard
                            signOutRow
                            footer
                                .id(Self.bottomAnchorID)
                        }
                        .padding(.bottom, MRTMetrics.shareContentBottomPadding)
                    }
                    #if DEBUG
                    // Capture-only: the MYR-224 owner "Switch to Rider" row sits at
                    // the bottom of this long scroll. The `ownerSettings` drift-gate
                    // scene starts scrolled to it so it is captured full-frame
                    // (headless simctl has no scroll gesture). No effect otherwise.
                    .onAppear {
                        // MYR-355 — the deletion scenes are captured at the same
                        // anchor: the Account section this issue appends is the
                        // LAST thing above Sign out, so a top-of-list capture would
                        // frame everything except the subject.
                        if DebugScene.current == .ownerSettings
                            || DebugScene.current?.accountDeletionStage != nil {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                    }
                    #endif
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .mrtBottomNav(selection: $ownerTab)
        .mrtConfigSheet(
            isPresented: Binding(get: { vehicleDetail != nil }, set: { if !$0 { vehicleDetail = nil } })
        ) {
            if let vehicle = vehicleDetail {
                // MYR-258 — the live path shows the teardown detail (no primary
                // concept, destructive "Remove this car"); sim keeps the fixture
                // set-primary / unlink sheet pixel-identical.
                if teardown != nil {
                    liveVehicleDetailContent(vehicle)
                } else {
                    vehicleDetailContent(vehicle)
                }
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
        .mrtSuccessToast(
            isPresented: $revokeFailed,
            message: "Couldn\u{2019}t revoke access"
        )
        // MYR-258 — post-teardown "Car removed" sheet with the two owner-only
        // follow-ups (live path only; teardownResult is set only by the live flow).
        .mrtConfigSheet(
            isPresented: Binding(get: { teardownResult != nil }, set: { if !$0 { teardownResult = nil } })
        ) {
            if let result = teardownResult {
                carRemovedContent(result)
            }
        }
        // MYR-258 — a calm, honest failure surface for the rare teardown error
        // (atomic + retryable server-side); never a fake success.
        .alert(
            "Couldn't remove this car",
            isPresented: Binding(get: { teardownError != nil }, set: { if !$0 { teardownError = nil } })
        ) {
            SwiftUI.Button("OK", role: .cancel) { teardownError = nil }
        } message: {
            Text(teardownError ?? "")
        }
        // MYR-258 — busy overlay while the teardown DELETE is in flight.
        .overlay { teardownBusyOverlay }
        // MYR-349 — hydrate the notification rows from §7.19 on arrival, so they
        // show what the ACCOUNT holds rather than a compiled-in default. No-op in
        // sim. A failed read is an honest state, not a silent fall-through — see
        // `LivePushPrefsService.load()`.
        .task { await pushPrefs.load() }
        // MYR-355 — the two-step account-deletion dialogs + its notice + its busy
        // overlay. All four read ONE flow object (see `AccountDeletionFlow`).
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
        .task { await prepareAccountDeletion() }
    }

    /// MYR-355 — hand the flow its seams once the screen is on. Kept out of `body`
    /// (an `@Observable` must not be mutated during a render pass).
    @MainActor
    private func prepareAccountDeletion() async {
        deletion.endpoint = accountDeletion
        deletion.onDeleted = onAccountDeleted
        #if DEBUG
        // Capture-only: headless tooling cannot tap "Delete account" and then a
        // dialog button, so the scene drives the SHIPPING flow to the state it
        // wants — the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`
        // / `ownerServiceWindowEditor`. Everything downstream of the taps (the
        // copy, the endpoint call, the failure notice) is the production path.
        if let stage = DebugScene.current?.accountDeletionStage {
            await deletion.debugDrive(to: stage, role: .owner)
        }
        #endif
    }

    // MARK: Header (screens.jsx:398-400)

    private var header: some View {
        Text("Settings")
            .mrtTextStyle(.screenTitle)
            .foregroundStyle(Color.mrtText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.top, MRTMetrics.shareHeaderTop)
            // MYR-354 — the two prototypes differ by 6pt here for no stated
            // reason; the card grammar's own number is the rider page's 12.
            .padding(.bottom, MRTSettingsGrammar.headerBottomPadding)
    }

    // MARK: Profile (screens.jsx:402-406)

    // MYR-224 — real identity in LIVE mode. `nil` liveProfile (SIM) keeps the
    // fixture "Alex Cole" / "alex@cole.run" so the sim scene is pixel-identical.
    // Live: real name (or a calm generic when the account has no name) + real
    // email (or a muted "email absent" line — Apple only returns email on first
    // sign-in, and a pre-native row may carry none).
    private var profileName: String {
        liveProfile?.settingsDisplayName ?? "Alex Cole"
    }

    private var profileEmail: String? {
        guard liveProfile != nil else { return "alex@cole.run" }
        return liveProfile?.email
    }

    /// MYR-354 — the owner opens on the SAME account card the rider does. The
    /// prototype gave this role a bare "PROFILE" label and two unadorned lines
    /// (screens.jsx:402-406), which was the single biggest reason the two pages
    /// did not read as one product.
    private var profileSection: some View {
        SettingsProfileCard(
            initial: liveProfile?.avatarInitial ?? String(profileName.prefix(1)).uppercased(),
            name: profileName,
            email: profileEmail,
            roleBadge: "Owner"
        )
    }

    // MARK: Tesla Account (screens.jsx:409-444)

    private var teslaAccountHeader: some View {
        SettingsSectionLabel(title: "Tesla Account") {
            // MYR-228 — the "Linked · synced 14s ago" status is a fixture claim;
            // show it only when there ARE linked vehicles. In live mode with no
            // linked-vehicle backend the list is empty, so the honest header
            // carries no false "synced" line.
            if !vehiclesState.vehicles.isEmpty {
                HStack(spacing: 6) {
                    PulseDot(color: .mrtDriving, size: 6)
                    Text("Linked \u{00B7} synced 14s ago")
                        .font(.system(size: 11))
                        .tracking(0.2)
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
        }
    }

    /// The Tesla Account card: the linked-vehicle rows (fixture or live) with the
    /// "Add another Tesla" ACTION ROW as their last row. The prototype floated
    /// that affordance under the list as bare gold text, where it read as a
    /// caption rather than a control (MYR-354).
    private var teslaAccountCard: some View {
        SettingsCard {
            teslaVehiclesList
            SettingsActionRow(icon: "plus", title: "Add another Tesla") {
                isAddingTesla = true
            }
        }
    }

    @ViewBuilder
    private var vehiclesList: some View {
        if vehiclesState.vehicles.isEmpty {
            // MYR-228 — honest empty state (live, no linked-vehicle backend):
            // never the fixture Teslas. "Add a Tesla" row still follows.
            SettingsNoticeRow(text: "No Tesla linked yet.")
        } else {
            ForEach(Array(vehiclesState.vehicles.enumerated()), id: \.element.id) { index, vehicle in
                vehicleRow(vehicle, isFirst: index == 0)
            }
        }
    }

    private func vehicleRow(_ vehicle: Vehicle, isFirst: Bool) -> some View {
        let isPrimary = vehicle.id == vehiclesState.primaryID
        return SettingsDetailRow(
            glyph: SettingsRowGlyph(
                tone: isPrimary ? .gold : .neutral,
                systemName: "car.fill"
            ),
            title: vehicle.name,
            caption: "\(vehicle.model) \u{00B7} \(vehicle.plate)",
            isFirst: isFirst,
            action: { vehicleDetail = vehicle }
        ) {
            if isPrimary { PrimaryBadge() }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextMuted)
        }
    }

    // MARK: Tesla Account — live read-only list (MYR-243)

    /// Picks the source for the linked-vehicle rows: the live fleet (read-only)
    /// when `linkedVehicles` is wired, else the fixture `vehiclesState` list
    /// (sim / DEBUG).
    @ViewBuilder
    private var teslaVehiclesList: some View {
        if let linkedVehicles {
            liveVehiclesList(Self.liveState(
                vehicles: linkedVehicles.vehicles,
                isConnecting: linkedVehicles.isConnecting,
                statusMessage: linkedVehicles.statusMessage
            ))
        } else {
            vehiclesList
        }
    }

    /// The read-only live list. Honest states only — row-shaped placeholders
    /// while the fleet loads, the fleet's honest notice (empty account / auth /
    /// unreachable) otherwise, and read-only rows once vehicles arrive. No
    /// set-primary / unlink affordance (no backend contract, MYR-228); rows are
    /// non-interactive (no detail sheet, no Primary badge — the live path has no
    /// primary designation).
    @ViewBuilder
    private func liveVehiclesList(_ state: TeslaAccountLiveState) -> some View {
        switch state {
        case .connecting:
            // MYR-326 — the fleet list is genuinely in flight: two row-shaped
            // placeholders instead of a "Connecting…" line, so the section holds
            // the shape it is about to have. The `.notice` branch below stays as
            // it is — it is the honest end state (empty account / auth /
            // unreachable), never a skeleton.
            ForEach(0..<Self.connectingRowCount, id: \.self) { index in
                // `isFirst: true` suppresses the skeleton's OWN hairline so the
                // separator can be drawn outside the card inset — every other
                // hairline on this page spans the card's full width, and an
                // inset one would be the only exception.
                TeslaAccountRowSkeleton(isFirst: true)
                    .padding(.horizontal, MRTSettingsGrammar.rowHorizontalPadding)
                    .mrtSettingsRowSeparator(isFirst: index == 0)
            }
        case .notice(let message):
            SettingsNoticeRow(text: message)
        case .linked(let vehicles):
            ForEach(Array(vehicles.enumerated()), id: \.element.id) { index, vehicle in
                liveVehicleRow(vehicle, isFirst: index == 0)
            }
        }
    }

    /// MYR-326 — how many placeholder rows the loading Tesla Account section
    /// shows. Two: enough to read as a list, few enough that it makes no claim
    /// about a fleet size the server hasn't stated yet (most accounts have one
    /// or two cars, and an over-long skeleton that collapses to one row is its
    /// own small lie).
    private static let connectingRowCount = 2

    /// A live linked-vehicle row: the same glyph + name + "model · plate" as the
    /// fixture row, with no Primary badge (the live path has no primary
    /// designation). On the live path the row taps through to the teardown detail
    /// sheet (MYR-258 — "Remove this car"); with no teardown seam it is a
    /// non-interactive read-only row (MYR-243).
    private func liveVehicleRow(_ vehicle: Vehicle, isFirst: Bool) -> some View {
        SettingsDetailRow(
            glyph: SettingsRowGlyph(systemName: "car.fill"),
            title: vehicle.name,
            caption: vehicle.plate.isEmpty ? vehicle.model : "\(vehicle.model) \u{00B7} \(vehicle.plate)",
            isFirst: isFirst,
            action: teardown != nil ? { vehicleDetail = vehicle } : nil
        ) {
            if teardown != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
            }
        }
    }

    // MARK: Shared with (screens.jsx:447-470)

    private var sharedWithHeader: some View {
        SettingsSectionLabel(title: "Shared with") {
            Text("\(shareService.viewers.count) \(shareService.viewers.count == 1 ? "person" : "people")")
                .font(.system(size: 11))
                .foregroundStyle(Color.mrtTextMuted)
        }
    }

    /// The "Shared with" card: the viewer rows with "Invite someone" as their
    /// last row.
    ///
    /// `ViewerRow` belongs to `ShareRows.swift`, which **MYR-347 owns**, so it is
    /// consumed here EXACTLY as it is and its baked-in page gutter is corrected
    /// at this call site — see `MRTSettingsGrammar.viewerRowCardInset` for the
    /// arithmetic and the handoff note.
    private var sharedWithCard: some View {
        SettingsCard {
            if shareService.viewers.isEmpty {
                SettingsNoticeRow(text: "No one has access yet.")
            } else {
                ForEach(Array(shareService.viewers.enumerated()), id: \.element.id) { index, viewer in
                    ViewerRow(viewer: viewer) { confirmRevoke = viewer }
                        .padding(.horizontal, -MRTSettingsGrammar.viewerRowCardInset)
                        .mrtSettingsRowSeparator(isFirst: index == 0)
                }
            }
            SettingsActionRow(icon: "plus", title: "Invite someone") {
                ownerTab = "invites"
            }
        }
    }

    // MARK: Notifications (screens.jsx:473-486)
    //
    // `PushDeniedNotice` moved OUT of the section's own stack and into the
    // shared `SettingsSectionNotices` slot directly under the card — a card
    // cannot hold full-width wrapping copy — which is exactly where the rider
    // page has always put it.

    private var notificationsLabel: some View {
        SettingsSectionLabel("Notifications")
    }

    /// The prototype's four, LED BY the row it was missing (MYR-354, from
    /// MYR-349's prefs work): `ride_lifecycle` gates the owner's "X wants a
    /// ride" pushes — the one notification in this product that wakes a phone
    /// for money — and this page offered no switch for it at all.
    ///
    /// MYR-349 — the rows, their copy AND their §7.19 categories all come from
    /// the ONE shared table (`SettingsNotificationRows.owner`), so the mapping a
    /// test asserts is the mapping that renders and neither Settings page can
    /// grow a row the other does not know about. Each row RENDERS the service's
    /// value and WRITES through it, so this screen holds no notification state of
    /// its own.
    private var notificationsCard: some View {
        SettingsCard {
            ForEach(Array(SettingsNotificationRows.owner.enumerated()), id: \.element.id) { index, row in
                SettingsToggleRow(
                    label: row.label,
                    caption: row.caption,
                    isOn: pushPrefsBinding(row.category),
                    isFirst: index == 0
                )
            }
        }
    }

    /// The binding a row's switch drives. The setter is fire-and-forget on
    /// purpose: `setEnabled` flips the value synchronously before it suspends, so
    /// the switch moves under the finger, and there is nothing for this view to do
    /// with a failure that the rolled-back row and its notice are not already
    /// showing (the same reasoning as `HomeScreen.setRideShareEnabled`).
    private func pushPrefsBinding(_ category: PushPrefCategory) -> Binding<Bool> {
        Binding(
            get: { pushPrefs.prefs[category] },
            set: { newValue in Task { await pushPrefs.setEnabled(category, newValue) } }
        )
    }

    // MARK: Switch view mode (MYR-224 — client-approved chooser companion)
    //
    // Flips the owner shell to the rider shell. The shared `SettingsActionRow`
    // in its own card, identical to the rider page's "Switch to Owner". Only
    // present on the live signed-in path; absent in SIM.
    private var switchModeCard: some View {
        SettingsCard {
            SettingsActionRow(
                icon: "arrow.left.arrow.right",
                title: "Switch to Rider",
                emphasizesTitle: false,
                isFirst: true,
                action: onSwitchMode
            )
        }
    }

    // MARK: Account (MYR-355 — App Store Guideline 5.1.1(v))
    //
    // Self-contained and appended at the END of the list, and — since MYR-354
    // (#139) — in the SHARED card grammar every other section on this page now
    // wears: a `SettingsSectionLabel` over a `SettingsCard` holding two rows at
    // the converged row style (32pt leading circle, 14pt title, the inter-row
    // hairline, a 44pt floor). It was written against the pre-#139 owner page —
    // a `.label()` header over bare rows on the page ground — which is exactly
    // the divider-list idiom that issue converged AWAY from, so keeping it would
    // have re-forked the page at its last section.
    //
    // Exactly two things: who is signed in, and the way out of the product.
    // Sign out stays terminal BELOW it — that button is page furniture, not a
    // section row (see `SettingsDestructiveRow`).

    private var accountLabel: some View {
        SettingsSectionLabel(AccountDeletionDialog.sectionTitle)
    }

    private var accountCard: some View {
        SettingsCard {
            accountNameRow
            deleteAccountRow
        }
    }

    /// The signed-in person's name, DISPLAY-ONLY.
    ///
    /// There is deliberately NO rename affordance and no edit chevron: the backend
    /// has no profile-update endpoint at all (nothing in `RestClient` or the
    /// contracts the Kit consumes writes to `/api/users`), and an affordance that
    /// cannot reach a server is the MYR-342 gate lesson in miniature — it would
    /// appear to change the owner's name and do nothing. The caption says where
    /// the name came from instead, which is the honest answer to the question a
    /// rename button would have been asked.
    ///
    /// A `SettingsDetailRow` with **no `action`** is the grammar's own way to say
    /// display-only: it renders the content bare rather than in a `Button`, so the
    /// row has no press state and no tap target of its own to promise anything.
    ///
    /// Reads the SAME `profileName` the Profile section at the top does — the real
    /// `settingsDisplayName` on live, the fixture persona in SIM — so the two can
    /// never disagree and the simulated capture is unchanged by this row's
    /// existence.
    private var accountNameRow: some View {
        SettingsDetailRow(
            glyph: SettingsRowGlyph(systemName: "person"),
            title: profileName,
            caption: AccountDeletionDialog.nameProvenanceCaption,
            isFirst: true
        )
        // ONE combined element: a name and its provenance are one fact, not two
        // stops for a screen reader (asserted in `AccountDeletionUITests`).
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mrt.accountNameRow")
    }

    /// The destructive row, in the shared danger grammar — `SettingsActionRow`'s
    /// shape with `mrtDialogRed` where the gold goes, and the confirm dialog's own
    /// destructive icon-circle for the glyph.
    private var deleteAccountRow: some View {
        SettingsDestructiveRow(
            icon: "trash",
            title: AccountDeletionDialog.deleteRowLabel,
            accessibilityID: "mrt.deleteAccountRow"
        ) {
            deletion.begin(role: .owner)
        }
    }

    // MARK: Sign out + footer (screens.jsx:488-493)

    private var signOutRow: some View {
        SettingsSignOutButton { confirmSignOut = true }
    }

    private var footer: some View {
        SettingsFooter(text: "MyRoboTaxi v1.0 (24)")
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

    // MARK: Live vehicle detail sheet (MYR-258 — teardown entry)

    /// The live-path detail sheet: the car header (no primary concept on the live
    /// path) + an honest note + the destructive "Remove this car" action that opens
    /// the teardown confirm dialog. Deliberately simpler than the fixture sheet —
    /// there is no set-as-primary on the live path (MYR-243).
    private func liveVehicleDetailContent(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        .foregroundStyle(Color.mrtTextSec)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vehicle.name)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.mrtText)
                    Text(vehicle.plate.isEmpty ? vehicle.model : "\(vehicle.model) \u{00B7} \(vehicle.plate)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mrtTextSec)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Removing this car")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mrtText)
                    Text("Takes it out of MyRoboTaxi right away and stops it streaming to us. Revoking Tesla access and removing the car's key are owner-only steps we'll guide you through afterward.")
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

            Button {
                vehicleDetail = nil
                confirmUnlink = vehicle
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 14, weight: .semibold))
                    Text("Remove this car").font(.system(size: 15, weight: .semibold))
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
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    // MARK: Post-teardown "Car removed" sheet (MYR-258, §7.12)

    /// Confirms the car is gone from the app and offers the TWO owner-only,
    /// clearly-optional follow-ups Tesla's model leaves to the owner: (a) revoke
    /// MyRoboTaxi's access on Tesla (only when this cleared the whole Tesla link —
    /// `teslaTokensCleared && wasLastVehicle` — and a `revokeUrl` is present), and
    /// (b) remove the car's virtual key (instructions verbatim, no automation).
    private func carRemovedContent(_ result: VehicleTeardownResponse) -> some View {
        let revokeURL = result.revokeUrl.flatMap { URL(string: $0) }
        let showsRevoke = result.teslaTokensCleared && result.wasLastVehicle && revokeURL != nil
        let showsKey = result.virtualKeyRemoval.required && !result.virtualKeyRemoval.steps.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.mrtGoldBadgeFill)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.mrtGold)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Car removed")
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.mrtText)
                    Text(result.wasLastVehicle
                        ? "Your Tesla connection to MyRoboTaxi is cleared."
                        : "This car is no longer connected to MyRoboTaxi.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, showsRevoke || showsKey ? 18 : 22)

            if showsRevoke || showsKey {
                Text("Optional next steps")
                    .mrtTextStyle(.label())
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.bottom, 12)
            }

            // (a) Owner revokes MyRoboTaxi's access on Tesla — opens Tesla's
            // consent-revoke page (owner-confirmed; only Tesla can revoke the grant).
            if showsRevoke, let revokeURL, let teardown {
                Button {
                    Task { _ = await teardown.revoke(revokeURL) }
                } label: {
                    followUpCard(
                        icon: "person.crop.circle.badge.xmark",
                        title: "Remove MyRoboTaxi from your Tesla account",
                        body: "We deleted our stored access, but only you can revoke the connection on Tesla. Opens Tesla to finish.",
                        showsChevron: true
                    )
                }
                .buttonStyle(MRTPressScaleButtonStyle())
                .padding(.bottom, showsKey ? 12 : 18)
            }

            // (b) Owner removes the enrolled virtual key — instructions verbatim,
            // no button (no Fleet API / deep link exists — §7.12 `automatable=false`).
            if showsKey {
                VStack(alignment: .leading, spacing: 0) {
                    followUpHeader(
                        icon: "key.horizontal",
                        title: "Remove the key from your car",
                        body: "The MyRoboTaxi key stays on the car until you remove it yourself:"
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(result.virtualKeyRemoval.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1).")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.mrtTextMuted)
                                    .frame(width: 16, alignment: .trailing)
                                Text(step)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color.mrtTextSec)
                                    .lineSpacing(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
                .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                )
                .padding(.bottom, 18)
            }

            Button {
                teardownResult = nil
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
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
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    /// A tappable optional-follow-up card (icon + title + body + chevron).
    private func followUpCard(icon: String, title: String, body: String, showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mrtGold)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsChevron {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mrtTextMuted)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
        .contentShape(Rectangle())
    }

    /// The header row for the (non-tappable) virtual-key instructions card.
    private func followUpHeader(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mrtTextSec)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// Busy overlay shown while the teardown `DELETE` is in flight.
    @ViewBuilder
    private var teardownBusyOverlay: some View {
        if teardownInFlight != nil {
            ZStack {
                Color.mrtScrim.ignoresSafeArea()
                VStack(spacing: 14) {
                    SpinnerRing(diameter: 34, lineWidth: 3, trackColor: .mrtBorder, color: .mrtGold, period: 0.8)
                    Text("Removing car\u{2026}")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Dialogs

    private var unlinkDialogConfig: MRTConfirmDialogConfig {
        let vehicle = confirmUnlink
        // MYR-258 — on the LIVE path the destructive action runs the authoritative
        // §7.12 teardown (not the local unlink), with honest copy: when this is the
        // owner's LAST linked car, the whole Tesla link clears (tokens + settings).
        if let teardown {
            let isLastVehicle = (linkedVehicles?.vehicles.count ?? 0) <= 1
            let message = isLastVehicle
                ? "This removes \(vehicle?.name ?? "your Tesla") from MyRoboTaxi and clears your whole Tesla connection — our access and everyone you've shared it with. Two owner-only steps (revoking access on Tesla and removing the car's key) come next. You can re-link anytime."
                : "This removes \(vehicle?.name ?? "this Tesla") from MyRoboTaxi and everyone you've shared it with. You can re-link it anytime."
            return MRTConfirmDialogConfig(
                kind: .destructive,
                icon: "car.fill",
                title: "Remove \(vehicle?.name ?? "this car")?",
                message: message,
                actionLabel: "Remove car",
                dismissLabel: "Keep linked"
            ) {
                guard let vehicle else { return }
                Task { await performTeardown(vehicle, teardown: teardown) }
            }
        }
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

    // MARK: - Live teardown (MYR-258, §7.12)

    /// Run the authoritative teardown: busy → `DELETE` → drop the car from the
    /// fleet immediately (both Home + this list read the same fleet) → present the
    /// post-teardown sheet. A `404` is the idempotent already-gone case: still drop
    /// it, and note it calmly. Any other failure is honest + retryable.
    @MainActor
    private func performTeardown(_ vehicle: Vehicle, teardown: VehicleTeardownSeam) async {
        teardownInFlight = vehicle
        defer { teardownInFlight = nil }
        do {
            let response = try await teardown.remove(vehicle.id)
            teardown.onRemoved(vehicle.id)
            teardownResult = response
        } catch let error as RestError {
            if case .http(let status, _, _, _) = error, status == 404 {
                // Idempotent: the car is already gone server-side (a retry, a
                // double-tap, or a removal that succeeded before the UI caught up).
                // That is a SUCCESS, not a failure — drop it and show the normal
                // "Car removed" confirmation, never the "Couldn't remove" error
                // dialog (MYR-261: the false-error the client hit). No follow-up
                // steps: the first successful removal already surfaced them.
                teardown.onRemoved(vehicle.id)
                teardownResult = Self.alreadyRemovedResult
            } else {
                teardownError = Self.teardownErrorMessage(error)
            }
        } catch {
            teardownError = "Something went wrong removing the car. Please try again."
        }
    }

    /// The synthesized success response for the idempotent already-gone (404)
    /// case: the car is confirmed removed, with no follow-up next steps (the
    /// original successful removal already presented any revoke / virtual-key
    /// instructions). Drives the same "Car removed" confirmation sheet.
    static let alreadyRemovedResult = VehicleTeardownResponse(
        removed: true,
        wasLastVehicle: false,
        teslaTokensCleared: false,
        streamConfigDeleted: false,
        revokeUrl: nil,
        virtualKeyRemoval: VirtualKeyRemoval(required: false, automatable: false, steps: [])
    )

    /// Honest, non-technical copy for a teardown failure. The teardown is atomic
    /// server-side (nothing deleted on failure), so "try again" is always safe.
    static func teardownErrorMessage(_ error: RestError) -> String {
        if case .http(let status, _, _, _) = error {
            switch status {
            case 403: return "You don't have access to remove this car."
            case 401: return "Please sign in again to remove this car."
            default: break
            }
        }
        return "We couldn't reach MyRoboTaxi to remove the car. Check your connection and try again."
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
                    // MYR-184 — never claim a revoke that did not happen. The
                    // list re-reads from the server either way, so the row simply
                    // stays put, which is the truth.
                    revokeFailed = true
                }
            }
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
        shareService: SimulatedShareService(),
        vehiclesState: OwnerVehiclesState(),
        ownerTab: .constant("settings"),
        onSignOut: {}
    )
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
