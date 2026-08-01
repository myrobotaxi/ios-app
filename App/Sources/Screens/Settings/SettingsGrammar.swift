import SwiftUI
import DesignSystem

// MARK: - ONE Settings grammar for both roles (MYR-354)
//
// THE CLIENT'S REPORT (TestFlight, Jul 30, three items): owner and rider
// Settings are "inconsistent in terms of UI/UX" — reported from BOTH
// directions, i.e. each page looks wrong once you have seen the other.
//
// He is describing the PROTOTYPE, not a port defect. `screens.jsx`'s
// `SettingsScreen` (1562-1690) and `shared-screens.jsx`'s
// `SharedSettingsScreen` (444-530) are two different list idioms drawn by the
// same design kit:
//
//   OWNER (jsx)                          RIDER (jsx)
//   plain rows on the page ground        rows inside an inset CARD
//   full-bleed `<Divider>` per section   the card IS the section boundary
//   row content at the page gutter (24)  row content at card inset (16)
//   profile = a bare label + two lines   profile = avatar + name + role badge
//   gold text link under the list        gold ACTION ROW inside the card
//   sign out = bare red text, left       sign out = full-width outlined button
//
// The port is faithful to both, so it inherited the split whole.
//
// **The card grammar wins**, and not only because it is the more iOS-native of
// the two (it is the inset-grouped list Settings.app itself uses):
//
//  1. It is already this APP's dominant grammar. Owner Home's Status & location
//     card, the vehicle-details card, the drive-summary stat cards, every
//     confirm dialog and every share sheet are inset cards on the page ground.
//     The owner Settings divider list is the outlier in the whole product, not
//     merely against the rider page.
//  2. A full-bleed hairline on a near-black ground reads as a PAGE SEAM, not as
//     a group boundary — it says "a new region starts here" without saying which
//     rows belong to it. A card says both at once, which is the entire job of a
//     settings section.
//  3. It survives one more row. The owner page grew three sections the prototype
//     never had (MYR-224's mode switch, MYR-243's live vehicle list, MYR-186's
//     push notice) and each one had to invent its own separation.
//
// So this file is the grammar, ONCE, and both screens are assembled from it.
// Nothing here is decorative: every constant is one of the two prototypes'
// own numbers, taken from the rider page because that is the surface being
// converged on (shared-screens.jsx:469-513).

enum MRTSettingsGrammar {
    /// Horizontal inset of a row's content inside a settings card
    /// (shared-screens.jsx:480 `padding: '13px 16px'`).
    static let rowHorizontalPadding: CGFloat = 16
    /// Vertical padding of a settings card row (same rule).
    static let rowVerticalPadding: CGFloat = 13
    /// Gap below a section's card, before the next section's label
    /// (shared-screens.jsx:478 `margin: '0 24px 22px'`).
    static let sectionSpacing: CGFloat = 22
    /// Gap between a section label and its card (shared-screens.jsx:477
    /// `padding: '0 24px 8px'`).
    static let labelSpacing: CGFloat = 8
    /// Leading glyph circle diameter (shared-screens.jsx:481 `width/height: 32`).
    static let glyphSize: CGFloat = 32
    /// Gap between the leading glyph and the row's text column
    /// (shared-screens.jsx:480 `gap: 12`).
    static let rowGlyphSpacing: CGFloat = 12
    /// Screen-title bottom padding. The two prototypes differ by 6pt for no
    /// stated reason (owner `74px 24px 18px`, rider `74px 24px 12px`); the card
    /// grammar's own number is the rider's.
    static let headerBottomPadding: CGFloat = 12

    /// `ViewerRow` (`App/Sources/Screens/Invites/ShareRows.swift`) bakes the PAGE
    /// GUTTER into its own horizontal padding, because it was built for the
    /// prototype's full-bleed owner list (screens.jsx:1601) and is shared with
    /// the Share tab, which is still a full-bleed page.
    ///
    /// **MYR-347 owns that file and its restyle lands separately**, so this issue
    /// consumes the row EXACTLY as it is and corrects the difference at the call
    /// site instead: a negative inset of `pageGutter - rowHorizontalPadding`
    /// leaves the row's content at the card's own 16pt inset, in line with every
    /// other row on the page. The row draws nothing in its padding band, so the
    /// 8pt that lands outside the card is clipped harmlessly.
    ///
    /// **HANDOFF**: when `ViewerRow` stops baking a page gutter, this constant
    /// becomes 0 and nothing else on either Settings screen changes.
    static let viewerRowCardInset: CGFloat = MRTMetrics.pageGutter - rowHorizontalPadding
}

// MARK: - Section label

/// A section label above its card — `Label` in both prototypes
/// (screens.jsx:1587, shared-screens.jsx:477), with an optional trailing
/// accessory in the same baseline (the owner page's "3 people" count and its
/// "Linked · synced 14s ago" status both live there).
struct SettingsSectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, MRTSettingsGrammar.labelSpacing)
    }
}

extension SettingsSectionLabel where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Section card

/// The inset card that holds a section's rows. One `mrtSurface(.card)`, the page
/// gutter either side, and the section gap below.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, MRTSettingsGrammar.sectionSpacing)
    }
}

// MARK: - Row chrome

extension View {
    /// The padding + inter-row hairline every settings card row shares
    /// (shared-screens.jsx:480 `borderTop: i === 0 ? 'none' : …`).
    func mrtSettingsRow(isFirst: Bool) -> some View {
        self
            .padding(.horizontal, MRTSettingsGrammar.rowHorizontalPadding)
            .padding(.vertical, MRTSettingsGrammar.rowVerticalPadding)
            .frame(minHeight: MRTMetrics.minTapTarget)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
                }
            }
    }

    /// The hairline alone, for a row that brings its own padding — currently only
    /// `ViewerRow`, which MYR-347 owns (see `viewerRowCardInset`).
    func mrtSettingsRowSeparator(isFirst: Bool) -> some View {
        overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }
        }
    }
}

// MARK: - Leading glyph

/// The 32pt leading circle every settings row carries. Three fills, and the
/// choice is meaning, not decoration:
///   • `.neutral` — an ordinary object (a car shared with you, a linked Tesla).
///   • `.gold`    — an ACTION or the account's own car (the gold accent's two
///                  sanctioned uses on this page).
///   • `.danger`  — the one DESTRUCTIVE action a section may hold (MYR-355).
///                  `mrtDangerFillSoft` + `mrtDialogRed` is not a new colour
///                  pair: it is the confirm dialog's own destructive icon-circle
///                  (Tokens.swift:268), and `mrtGoldFillSoft` is documented
///                  there as its gold TWIN — so the danger glyph and the gold
///                  one are the same construction at the same two alphas.
struct SettingsRowGlyph: View {
    enum Tone { case neutral, gold, danger }

    var tone: Tone = .neutral
    var systemName: String?
    var initial: String?
    var size: CGFloat = 15

    private var fill: Color {
        switch tone {
        case .neutral: return .mrtElevated
        case .gold: return .mrtGoldBadgeFill
        case .danger: return .mrtDangerFillSoft
        }
    }

    private var ink: Color {
        switch tone {
        case .neutral: return .mrtTextMuted
        case .gold: return .mrtGold
        case .danger: return .mrtDialogRed
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: size, weight: tone == .neutral ? .regular : .bold))
                    .foregroundStyle(ink)
            } else if let initial {
                Text(initial)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
            }
        }
        .frame(width: MRTSettingsGrammar.glyphSize, height: MRTSettingsGrammar.glyphSize)
    }
}

// MARK: - Rows

/// A read/detail row: glyph + title (with an optional badge) + caption, and an
/// optional trailing accessory. Tappable when `action` is non-nil.
struct SettingsDetailRow<Badge: View, Trailing: View>: View {
    let glyph: SettingsRowGlyph
    let title: String
    let caption: String?
    var isFirst: Bool = true
    var action: (() -> Void)?
    @ViewBuilder var badge: Badge
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let action {
            Button(action: action) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: MRTSettingsGrammar.rowGlyphSpacing) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(Color.mrtText)
                    badge
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .mrtSettingsRow(isFirst: isFirst)
    }
}

extension SettingsDetailRow where Badge == EmptyView, Trailing == EmptyView {
    init(glyph: SettingsRowGlyph, title: String, caption: String?, isFirst: Bool = true, action: (() -> Void)? = nil) {
        self.init(glyph: glyph, title: title, caption: caption, isFirst: isFirst, action: action) {
            EmptyView()
        } trailing: {
            EmptyView()
        }
    }
}

extension SettingsDetailRow where Badge == EmptyView {
    init(
        glyph: SettingsRowGlyph,
        title: String,
        caption: String?,
        isFirst: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(glyph: glyph, title: title, caption: caption, isFirst: isFirst, action: action, badge: { EmptyView() }, trailing: trailing)
    }
}

/// The gold ACTION row that closes a section's card — "Add another Tesla",
/// "Invite someone", "Enter invite code", "Switch to Owner/Rider". The rider
/// prototype's own shape (shared-screens.jsx:489-495), now used by both roles;
/// the owner prototype spelled the same affordance as a bare gold text link
/// floating under the list, where it read as a caption rather than a control.
struct SettingsActionRow: View {
    let icon: String
    let title: String
    /// Gold label (an additive action) vs plain label (a navigation).
    var emphasizesTitle: Bool = true
    var showsChevron: Bool = true
    var isFirst: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MRTSettingsGrammar.rowGlyphSpacing) {
                SettingsRowGlyph(tone: .gold, systemName: icon)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(emphasizesTitle ? Color.mrtGold : Color.mrtText)
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mrtTextMuted)
                }
            }
            .mrtSettingsRow(isFirst: isFirst)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The DESTRUCTIVE row that closes a section's card — today only MYR-355's
/// "Delete account". It is `SettingsActionRow`'s exact shape (32pt glyph, 14pt
/// semibold title, the shared row chrome and its 44pt floor) with the gold
/// swapped for `mrtDialogRed`, because a destructive row is an ACTION row and
/// the only thing that differs is what it means.
///
/// **It is a ROW and not a second `SettingsSignOutButton`.** The outlined
/// full-width button is PAGE furniture — the one way out of the product, sitting
/// on the page ground below every card (shared-screens.jsx:518-523). Repeating
/// that treatment inside a card would put two identically-weighted red controls
/// on one screen and say they are the same kind of thing; deleting the account
/// belongs to the Account section, which is why it carries the section's row
/// grammar and Sign out keeps the page's.
///
/// It also carries **no chevron**: `SettingsActionRow`'s chevron promises a
/// destination, and this row raises a dialog in place.
struct SettingsDestructiveRow: View {
    let icon: String
    let title: String
    var isFirst: Bool = false
    /// Applied to the `Button` ITSELF rather than at the call site, so the
    /// identifier lands on the element XCUITest reports as the button (the
    /// frame `AccountDeletionUITests` measures against the 44pt floor).
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MRTSettingsGrammar.rowGlyphSpacing) {
                SettingsRowGlyph(tone: .danger, systemName: icon)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtDialogRed)
                Spacer(minLength: 0)
            }
            .mrtSettingsRow(isFirst: isFirst)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }
}

/// A toggle row (shared-screens.jsx:504-509). The `caption` is optional and
/// exists for exactly one situation: a row that stands for MORE THAN ONE
/// notification and therefore has to name them (MYR-354's merged rider row).
struct SettingsToggleRow: View {
    let label: String
    var caption: String?
    @Binding var isOn: Bool
    var isFirst: Bool = false

    var body: some View {
        HStack(spacing: MRTSettingsGrammar.rowGlyphSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            Spacer(minLength: 0)
            MRTToggle(isOn: $isOn)
        }
        .mrtSettingsRow(isFirst: isFirst)
    }
}

// MARK: - Notification-section copy (MYR-354, with MYR-349)
//
// The row COPY lives here rather than inline in the two screens because two of
// these strings are the product of a backend fact, not a design choice, and the
// fact is invisible at the call site: **`ride_lifecycle` is ONE server
// category** (rest-api.md §7.19). MYR-349's prefs work found that no send site
// distinguishes "accepted / declined" from "pick-up & arrival" — they are one
// column — so the rider's two prototype switches were one preference wearing two
// masks: flipping either one silenced both, and whichever the rider touched
// second would appear to have moved on its own.
//
// MYR-349 (PR #137) owns the SERVICE behind these rows and landed
// `SettingsNotificationRows`, a row→category table. **That merge has happened**:
// these strings travelled unchanged and are now READ BY the table
// (`SettingsNotificationRows.owner[0].label`, `.rider[0].label` / `.caption`),
// which is the only place either page's rows are declared. Nothing consumes this
// enum at a call site any more — it stays as the one home for the reasoning
// above, which a bare string literal in a table cannot carry.
enum SettingsNotificationCopy {
    /// The rider's ONE ride-lifecycle row, replacing the prototype's two.
    /// The sub-line is not decoration: it is the receipt for the merge, naming
    /// the four notifications the single switch now governs.
    static let riderRideUpdates = "Ride updates"
    static let riderRideUpdatesCaption = "Accepted, declined, pick-up and arrival"

    /// The OWNER's missing row. `ride_lifecycle` gates the owner's "X wants a
    /// ride" pushes too, and the owner had no switch for them at all — the one
    /// notification in this product that a phone can wake you for, with nothing
    /// on this page acknowledging it exists.
    ///
    /// It leads the section deliberately. The prototype's four are all about the
    /// CAR (drives, charging, viewers); this one is about the ride-hailing loop,
    /// and it is the row an owner comes to this section to find.
    static let ownerRideRequests = "Ride requests"
}

/// The notices that belong to the notifications SECTION but cannot live inside
/// its card: full-width, wrapping copy that a 16pt-inset row would fight.
///
/// Both Settings screens render this slot at the page gutter directly under the
/// notifications card, in order. Today it holds MYR-186's `PushDeniedNotice`;
/// **MYR-349's live-path-only `PushPrefsNotice` lands here too** (PR #137), which
/// is why the slot is a named container rather than a loose view in each body —
/// so the rebase is an addition inside one type instead of two edits that can
/// disagree.
struct SettingsSectionNotices<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
    }
}

/// A quiet, non-interactive one-liner row — the honest empty/notice states
/// ("No one has access yet.", "No Tesla linked yet.").
struct SettingsNoticeRow: View {
    let text: String
    var isFirst: Bool = true

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.mrtTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mrtSettingsRow(isFirst: isFirst)
    }
}

// MARK: - Profile card

/// The account card that opens both pages: avatar, name, email (or a calm
/// absent line), and the ROLE badge. The rider prototype's own card
/// (shared-screens.jsx:469-476); the owner prototype opened with a bare "PROFILE"
/// label and two unadorned lines, which is the single biggest reason the two
/// pages did not read as the same product.
struct SettingsProfileCard: View {
    let initial: String
    let name: String
    /// `nil` → the calm "Email not shared" line (a live account Apple never
    /// gave an email for).
    let email: String?
    let roleBadge: String

    var body: some View {
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
                Text(initial)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.mrtGoldButtonLabel)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                if let email {
                    // `Text(verbatim:)`, not a literal — an email-shaped literal
                    // gets Markdown-parsed and auto-linked in the accent color,
                    // ignoring `.foregroundStyle` (see InvitesScreen's `emailRow`).
                    Text(verbatim: email)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                } else {
                    Text("Email not shared")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextMuted)
                }
            }
            Spacer(minLength: 0)
            Text(roleBadge)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mrtGold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.mrtGoldBadgeFill, in: Capsule())
        }
        .padding(16)
        .mrtSurface(.card)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, MRTSettingsGrammar.sectionSpacing)
    }
}

// MARK: - Page furniture

/// The full-width outlined red sign-out button (shared-screens.jsx:518-523).
/// The owner prototype spelled this as bare red text at the page gutter, which
/// on a page of cards reads as a stray caption rather than the one destructive
/// action on the screen.
struct SettingsSignOutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
}

/// The centred page footer (shared-screens.jsx:525).
///
/// **MYR-395 — the copy is NO LONGER role-specific.** r16, the client: *"How come
/// rider screen shows guest access at bottom and other shows version?"* MYR-354
/// unified everything else about these two pages and left this line alone on the
/// reasoning that each half "says something true about the account looking at
/// it" — which was true of both and still the wrong call, because the FOOTER is
/// page furniture and it was carrying two different kinds of fact. Whichever page
/// you were on, the other one looked like a different app at the bottom.
///
/// The version wins, for the reason the client implies: it is the only thing on
/// either page that a tester reading a bug report needs and cannot get anywhere
/// else. **Nothing is lost with "Guest access":** the rider's role is already the
/// gold **"Guest" badge in `SettingsProfileCard`** at the top of the same page
/// (the prototype's own shared-screens.jsx:473), and what that role can actually
/// DO per vehicle is MYR-354's vehicle section, which says it per row rather than
/// as one flat claim. Re-homing it as a third statement is exactly the repetition
/// MYR-366 deleted the Account-section name row for — and the flat claim is also
/// simply FALSE for the account MYR-343 fixed, an owner in rider mode, who is not
/// anybody's guest.
struct SettingsFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.mrtTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    /// The ONE footer both Settings pages render. A `static` on the type rather
    /// than the same literal typed on two screens, so a third page cannot invent
    /// a third wording and the pair cannot drift apart again.
    static var appVersion: SettingsFooter { SettingsFooter(text: AppVersionStamp.footerText) }
}

/// The build the tester is holding, as one string.
///
/// MYR-395 — the owner footer used to read a HARDCODED `"MyRoboTaxi v1.0 (24)"`.
/// `project.yml` ships `MARKETING_VERSION 1.0.0` and a `CURRENT_PROJECT_VERSION`
/// that RELEASING.md overrides per upload (r16 is `202607311641`), so build "24"
/// has never existed — the one line on either page whose whole job is to identify
/// the build was naming a build nobody could have installed. Now that BOTH roles
/// show it, a wrong stamp would be wrong twice, and the person most likely to read
/// it is the person filing the report.
enum AppVersionStamp {
    /// `CFBundleShortVersionString`, or a plain `"—"` rather than a guess.
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "\u{2014}"
    }
    /// `CFBundleVersion` — the value that is unique per TestFlight upload and the
    /// one that actually identifies a build.
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "\u{2014}"
    }
    /// `"MyRoboTaxi v1.0.0 (202607311641)"` — the owner footer's own shape,
    /// unchanged apart from being true.
    static var footerText: String { "MyRoboTaxi v\(shortVersion) (\(build))" }
}
