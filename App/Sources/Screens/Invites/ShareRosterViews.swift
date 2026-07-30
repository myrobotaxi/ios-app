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
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.mrtTextSec)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.mrtElevated, in: Capsule())
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
