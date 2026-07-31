import SwiftUI
import DesignSystem

// MARK: - Share tab roster components (MYR-347)
//
// The client-directed redesign of the owner Share tab's list. Native iOS list
// grammar — an inset grouped CARD per section, a header with a count badge above
// it, hairline separators inset past the avatar, one overflow control per row —
// wearing the app's own dark/gold tokens rather than `List`'s system chrome.
//
// **Deliberately NOT a `List`.** Swipe-to-revoke would come free with one, but so
// would `UITableView`'s background, separator, selection and inset behaviour,
// which the flat-only token system would then have to fight on every property
// (CLAUDE.md "Tokens only"). The row actions live in an OVERFLOW MENU instead —
// `Menu` is system-composed, so the destructive styling and the placement are
// iOS's own, and it is discoverable without a gesture. Both actions still land in
// the EXISTING `ShareDialogs` confirm dialogs and the EXISTING `ShareService`
// calls: this issue changed no service and no dialog copy.
//
// `ViewerRow` / `RevokePillButton` in `ShareRows.swift` are deliberately left
// alone — `SettingsScreen` consumes `ViewerRow` and is being restyled separately
// (MYR-354).

// MARK: Section header

/// "SHARED WITH" + a count badge. Rendered only from a `ShareRosterSection`,
/// which is non-empty by construction, so the badge can never read "0" — the
/// orphaned "Viewers · 0" the client photographed is unreachable rather than
/// merely avoided.
struct ShareSectionHeader: View {
    let title: String
    /// `nil` renders NO badge.
    ///
    /// MYR-369 — the relocated ride-sharing card is a section without a
    /// population: a "1" over a single car counts nothing the owner needs
    /// counted, and a number that is almost always 1 is exactly the decorative
    /// chrome MYR-347 was reported about ("weird text in the middle saying
    /// viewers 0"). The roster sections still pass their count, where it answers
    /// a real question — how many people can see this car.
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.mrtElevated, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, MRTMetrics.shareSectionHeaderGap)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Card + separator

/// The inset grouped card every section's rows sit in — solid `surface` + the
/// flat look's hairline, the same anatomy as every other card in the app.
struct ShareRosterCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(
                Color.mrtSurface,
                in: RoundedRectangle(cornerRadius: MRTMetrics.shareSectionRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.shareSectionRadius, style: .continuous)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .padding(.horizontal, MRTMetrics.pageGutter)
    }
}

/// The between-rows separator, inset to the text column exactly as iOS insets a
/// grouped-list separator past a leading image.
struct ShareRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.mrtBorder)
            .frame(height: MRTMetrics.hairline)
            .padding(.leading, MRTMetrics.shareRowSeparatorInset)
    }
}

// MARK: Roster row

/// One person in the roster: avatar, name, a muted detail line, an optional
/// footnote, and an overflow menu carrying the row's actions.
///
/// The two row kinds differ only in their strings and their menu, so they share
/// one implementation — a second copy of this anatomy is a second place for the
/// two lists to drift apart.
struct ShareRosterRow<MenuContent: View>: View {
    let name: String
    var online: Bool = false
    /// The line under the name — the access tier, plus (for an invite) when it
    /// went out.
    let detail: String
    /// A second, quieter line: the handle either party actually holds. LIVE puts
    /// the CODE here (§7.5 has no email anywhere); SIM puts the fixture address.
    /// `nil` renders nothing at all rather than an empty line.
    var footnote: String?
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: MRTMetrics.shareRowContentGap) {
            Avatar(name: name, size: MRTMetrics.shareRowAvatarSize, online: online)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
                if let footnote {
                    // `Text(verbatim:)` — an interpolated `Text` Markdown-parses
                    // and auto-links an email-shaped run in the accent color,
                    // silently overriding `.foregroundStyle` (the MYR-170 note in
                    // `ShareRows`).
                    Text(verbatim: footnote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mrtTextSec)
                    // The visual glyph is small; the hit area is the hard-rule
                    // 44pt, declared as a real frame so the system REPORTS 44
                    // (MYR-345: a `contentShape` inset is not a tap target).
                    .frame(width: MRTMetrics.minTapTarget, height: MRTMetrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(name) options")
        }
        .padding(.leading, MRTMetrics.shareRowGutter)
        // The overflow's own 44pt frame supplies the trailing gutter.
        .padding(.trailing, MRTMetrics.shareRowGutter - 10)
        .padding(.vertical, MRTMetrics.shareRowVerticalPadding)
        .frame(minHeight: MRTMetrics.shareRowMinHeight)
    }
}

// MARK: Invite action row

/// "Invite someone" — the tab's primary action once the roster has content, in
/// the same card grammar as the sections above it (the iOS "add a thing" row).
/// The EMPTY state does not render it: there the hero owns the only CTA, which
/// is the whole point of one clear state model.
struct ShareInviteActionRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MRTMetrics.shareRowContentGap) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.mrtGoldFillFaint)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.mrtGold)
                }
                .frame(width: MRTMetrics.shareRowAvatarSize, height: MRTMetrics.shareRowAvatarSize)
                Text("Invite someone")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MRTMetrics.shareRowGutter)
            .padding(.vertical, MRTMetrics.shareRowVerticalPadding)
            .frame(minHeight: MRTMetrics.shareRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Empty hero

/// The ONE thing on screen when nothing is shared and nothing is pending.
///
/// It does not repeat the screen title ("Share Your Tesla" is already the header
/// six points above it) — a hero that restates the heading is the same kind of
/// stacked chrome the client objected to. It states the FACT, explains what the
/// feature does, and offers the single gold CTA.
struct ShareEmptyHero: View {
    /// LIVE names the artefact (a code the owner hands over); SIM keeps the
    /// prototype's fiction that an email is sent. Same split the header already
    /// makes — see `InvitesScreen.header`.
    let sharesByCode: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.mrtGoldFillFaint)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.mrtGold)
            }
            .frame(width: MRTMetrics.shareHeroIconSize, height: MRTMetrics.shareHeroIconSize)

            Text("No one has access yet")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.top, 18)

            Text(explainer)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: MRTMetrics.shareHeroTextWidth)
                .padding(.top, 7)

            MRTButton("Invite someone", fullWidth: false, action: action)
                .frame(width: MRTMetrics.shareHeroCTAWidth)
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.shareHeroTopGap)
    }

    private var explainer: String {
        sharesByCode
            ? "Send someone a link and they can follow your Tesla\u{2019}s live location and trips \u{2014} and, if you choose, request rides."
            : "Invite family or friends to follow your Tesla\u{2019}s live location and trips \u{2014} and, if you choose, request rides."
    }
}

// MARK: - Unreadable roster (MYR-386)

/// The list did not answer, and nothing is in hand.
///
/// **Deliberately NOT `ShareEmptyHero`**, which is the whole of MYR-386's second
/// half. "No one has access yet" is a CLAIM about the account and a failed fetch
/// does not support it — the same reasoning `SharedVehiclesUnreachableScreen`
/// applies on the rider's side, and the same reasoning that keeps
/// `LiveShareService` from emptying its lists on a failed re-read. Told the empty
/// hero's story, an owner whose network dropped would conclude that a share they
/// sent yesterday never landed, and would send it again.
///
/// **And deliberately not a skeleton** (MYR-326: loading ≠ unavailable). Nothing
/// is in flight behind this; a shimmer would promise content that is not coming.
///
/// **NO RETRY BUTTON**, by the standing MYR-326/343 ruling: recovery is the
/// low-friction one the app already has — a resume re-asks, and a successful read
/// clears this by itself. It also carries NO CTA of any kind: inviting someone
/// while the roster is unknown would mint a code onto a list the app cannot see.
struct ShareRosterUnavailable: View {
    /// The service's own sentence, passed through rather than restated here, so
    /// the phase and the pixels are provably the same string.
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.mrtElevated)
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .frame(width: MRTMetrics.shareHeroIconSize, height: MRTMetrics.shareHeroIconSize)

            Text(message)
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MRTMetrics.shareHeroTextWidth)
                .padding(.top, 18)

            // Byte-identical to `SharedVehiclesUnreachableScreen`'s second line —
            // one fact, said the same way wherever this app admits it.
            Text("We\u{2019}ll try again when you come back.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: MRTMetrics.shareHeroTextWidth)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.shareHeroTopGap)
    }
}

// MARK: - Vehicle ride-share card (MYR-369)

/// One owned vehicle's ride-share master switch, as the card at the TOP of the
/// Share tab renders it.
///
/// The anatomy is deliberately the roster row's, minus the avatar: same gutter,
/// same 15pt medium name, same 12pt muted caption, same card and hairline. The
/// two regions have to read as one page, and this control governs the ones below
/// it — a differently-shaped card would suggest it belongs to a different system.
struct ShareVehicleToggleRow: View {
    let name: String
    let isEnabled: Bool
    /// Whether the switch may be moved (MYR-358). `false` while the car is IN
    /// SERVICE, where the position is DERIVED and there is nothing to commit.
    ///
    /// It renders the switch dimmed and inert AND blocks the write, because a
    /// disabled control that still fires is worse than an enabled one — nothing on
    /// screen predicts what it did.
    var isInteractive: Bool = true
    /// The muted line beneath the name, supplied by the caller rather than
    /// re-derived here so the row cannot disagree with the model about why it is
    /// in the position it is in.
    let caption: String
    /// False while this row's own write is in flight, so a second tap cannot
    /// queue a contradictory write behind the first.
    var isBusy: Bool = false
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: MRTMetrics.shareRowContentGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            MRTToggle(
                isOn: Binding(
                    get: { isEnabled },
                    // Guarded in the SETTER, not by removing the control: a
                    // toggle that vanishes mid-write is worse than one that
                    // ignores a second tap. The in-service guard rides here too,
                    // so the derived-off position can never fire a write.
                    set: { if !isBusy && isInteractive { onToggle($0) } }
                )
            )
            .allowsHitTesting(!isBusy && isInteractive)
            .opacity(isBusy || !isInteractive ? 0.5 : 1)
        }
        .padding(.horizontal, MRTMetrics.shareRowGutter)
        .padding(.vertical, MRTMetrics.shareRowVerticalPadding)
        .frame(minHeight: MRTMetrics.shareRowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ride sharing for \(name)")
    }
}

// MARK: - Per-viewer control row (MYR-369)

/// One accepted grant: who it is, what they can do, and the two switches that
/// change it.
///
/// **WHY THIS IS NOT `ShareRosterRow` WITH SWITCHES BOLTED ON.** That row is one
/// horizontal band ending in an overflow menu, sized for a name and two lines of
/// text. Two labelled switches do not fit beside them at 393pt, and stacking them
/// on the trailing edge would give the owner two unlabelled toggles whose meaning
/// is positional. The switches get their own sub-rows, indented to the text
/// column exactly as the separator is, so the row reads as a small settings
/// group about one person. The PENDING row keeps the plain `ShareRosterRow`,
/// which is what makes "no switches until accepted" visible at a glance.
struct ShareViewerControlRow<MenuContent: View>: View {
    let name: String
    var online: Bool = false
    let controls: ShareViewerControls
    let onLocationToggle: (Bool) -> Void
    let onRidesToggle: (Bool) -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MRTMetrics.shareRowContentGap) {
                Avatar(name: name, size: MRTMetrics.shareRowAvatarSize, online: online)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                    Text(controls.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(
                            // The paused line is the one subtitle that is a
                            // WARNING rather than a description, so it carries
                            // the muted tone the rest of the app uses for "this
                            // is not currently true".
                            controls.locationOn ? Color.mrtTextSec : Color.mrtTextMuted
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mrtTextSec)
                        .frame(width: MRTMetrics.minTapTarget, height: MRTMetrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(name) options")
            }
            .padding(.leading, MRTMetrics.shareRowGutter)
            .padding(.trailing, MRTMetrics.shareRowGutter - 10)
            .padding(.top, MRTMetrics.shareRowVerticalPadding)

            switchRow(
                label: "Location",
                isOn: controls.locationOn,
                isInteractive: true,
                caption: nil,
                accessibility: "Location access for \(name)",
                action: onLocationToggle
            )
            switchRow(
                label: "Rides",
                isOn: controls.ridesOn,
                isInteractive: controls.ridesInteractive,
                caption: controls.ridesCaption,
                accessibility: "Ride requests for \(name)",
                action: onRidesToggle
            )
            .padding(.bottom, MRTMetrics.shareRowVerticalPadding)
        }
    }

    /// One labelled switch, indented to the row's text column.
    ///
    /// A disabled switch is DIMMED AND INERT, never hidden: it is showing the
    /// STORED position of a flag the owner still owns, and hiding it would erase
    /// the answer to "what comes back if I turn this person's access on again".
    @ViewBuilder
    private func switchRow(
        label: String,
        isOn: Bool,
        isInteractive: Bool,
        caption: String?,
        accessibility: String,
        action: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isInteractive ? Color.mrtTextSec : Color.mrtTextMuted)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mrtTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            MRTToggle(
                isOn: Binding(
                    get: { isOn },
                    set: { if isInteractive { action($0) } }
                )
            )
            .allowsHitTesting(isInteractive)
            .opacity(isInteractive ? 1 : 0.5)
        }
        .padding(.leading, MRTMetrics.shareRowSeparatorInset)
        .padding(.trailing, MRTMetrics.shareRowGutter)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }
}
