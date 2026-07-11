import SwiftUI
import DesignSystem

// MARK: - Shared chrome for the ride-request sheet phases (MYR-171,
// design/app/ride-request.jsx ExpandingRequestSheet 1165-1218)
//
// Every phase past `.idle` (search/pinDrop/review/booking/tracking/summary)
// draws the same card recipe `SharedViewerScreen.idleSheet` already
// established for `.idle` (MYR-191) — background wash + rounded top corners +
// gold hairline + drop shadow, bottom-pinned and ignoring the bottom safe
// area. Factored out here so each phase's content file doesn't repeat it
// (CLAUDE.md "Reuse, don't fork").

struct RideRequestSheetChrome: ViewModifier {
    /// The Ride Summary sheet takes over the full screen edge-to-edge —
    /// drops the top rounding/hairline/border (ride-request.jsx:1166
    /// `borderTopLeftRadius: isSummary ? 0 : …`).
    var isSummary: Bool = false

    func body(content: Content) -> some View {
        content
            .background(RideRequestSheetBackground())
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: isSummary ? 0 : MRTMetrics.sheetRadius,
                    topTrailingRadius: isSummary ? 0 : MRTMetrics.sheetRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .top) {
                if !isSummary {
                    Rectangle().fill(Color.mrtGoldSheetHairline).frame(height: MRTMetrics.hairline)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 20, y: -8) // '0 -16px 40px rgba(0,0,0,0.5)' (ride-request.jsx:1180)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // MYR-198 fix 3: the Summary takeover (`isSummary: true`) is the
            // one phase that owns the FULL screen, not a partial bottom
            // sheet — its gold-tinted background must reach the physical
            // TOP edge too (`RideRequestSummaryContent`'s own `GeometryReader`
            // already sizes its content to whatever height this chrome
            // reports, so extending the reported proposal up here is what
            // lets that content's existing `padding(.top, 76)` land 76pt
            // from the true top instead of the status-bar-inset top —
            // "content keeping its current offset per the prototype," only
            // the surface moves). Every other phase stays bottom-only: they
            // deliberately leave the map visible above the sheet, and this
            // view's fixed/content-hugging sizing means a taller top-side
            // proposal has no visual effect on them anyway (they don't
            // stretch to fill it).
            .ignoresSafeArea(edges: isSummary ? .all : .bottom)
    }
}

/// `backgroundColor:'#0A0A0A'` + the same top gold wash
/// `SharedViewerScreen.idleSheetBackground` uses (ride-request.jsx:1176-1177)
/// — every request-flow phase shares it.
struct RideRequestSheetBackground: View {
    var body: some View {
        ZStack {
            Color.mrtBg
            EllipticalGradient(
                stops: [
                    .init(color: Color.mrtGold.opacity(0.14), location: 0),
                    .init(color: .clear, location: 0.58),
                ],
                center: UnitPoint(x: 0.5, y: -0.14),
                startRadiusFraction: 0,
                endRadiusFraction: 1.3
            )
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func rideRequestSheetChrome(isSummary: Bool = false) -> some View {
        modifier(RideRequestSheetChrome(isSummary: isSummary))
    }
}

// MARK: - Grab handle (ride-request.jsx:1189-1198 `onHandleDown` — every
// phase but idle/tracking)
//
// MYR-199 fix (client QA round 4): the handle was purely decorative — no
// drag gesture wired up anywhere, so none of the phases that render it
// (Search/PinDrop/Review/Booking) supported drag-to-dismiss at all. The jsx's
// `onHandleDown` (ride-request.jsx:1140-1163) tracks a pointer-down→move→up
// delta and, on release, only acts for two phases: `search` (drag down >36px
// → `closeToIdle()`, a full draft reset) and `tracking`/`pending` (drag down
// >36px → `setPhase('idle')`, no reset — the sheet minimizes to the map, the
// in-flight request keeps running). PinDrop/Review render the handle too but
// have no matching branch in `onHandleDown`, so dragging them does nothing
// in the jsx either — ported here as leaving `onDragDismiss` nil at those
// call sites rather than inventing a dismiss behavior the design doesn't
// have. (The jsx also drag-UP-reopens from `.idle`, but `.idle` never
// renders this handle — `phase !== 'idle' && phase !== 'tracking'` — so that
// branch is dead code in the source and isn't ported.)
struct RideGrabHandle: View {
    /// Nil = decorative only (PinDrop/Review). Non-nil = wired to the
    /// matching phase's dismiss action (Search's `resetDraftToIdle()` /
    /// Booking's `sheetPhase = .idle`) — see call sites.
    var onDragDismiss: (() -> Void)?

    /// ride-request.jsx:1150 `d > 36` — drag-down threshold before the
    /// handle commits to dismissing (a light touch/scroll bounce shouldn't
    /// trigger it).
    private static let dismissThreshold: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.mrtElevated)
            .frame(width: 36, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onEnded { value in
                        // Project the flick from release velocity (MYR-236,
                        // shared `SheetPhysics`) so a fast downward flick
                        // dismisses even on small displacement — the same
                        // velocity-aware release the detent sheet uses, no
                        // fork. Both terms are screen-space (down = positive).
                        let projected = value.translation.height
                            + SheetPhysics.projection(velocity: value.velocity.height)
                        guard projected > Self.dismissThreshold else { return }
                        onDragDismiss?()
                    }
            )
    }
}

// MARK: - Close (X) button (ride-request.jsx:1198-1207 — review/booking only)

struct RideSheetCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.mrtTextSec)
                .frame(width: 28, height: 28)
                .background(Color.mrtElevated, in: Circle())
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

// MARK: - Small shared row pieces

/// Small-caps eyebrow label — the `PICKUP`/`DESTINATION`/`YOUR RIDE`/etc.
/// recipe repeated across every phase (ride-request.jsx e.g. 210-211).
struct RideEyebrowText: View {
    let text: String
    var color: Color = .mrtTextMuted
    var size: CGFloat = 9.5

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(color)
    }
}

/// Plate chip — `RBO-2046` styled hairline pill, reused by Booking/Tracking/
/// Summary's "your ride" rows (ride-request.jsx e.g. 597).
struct RidePlateChip: View {
    let plate: String

    var body: some View {
        Text(plate)
            .font(.system(size: 14, weight: .semibold))
            .monospacedDigit()
            .tracking(1)
            .foregroundStyle(Color.mrtGold.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.mrtGold.opacity(Double(0x3A) / 255.0), lineWidth: MRTMetrics.hairline)
            )
    }
}

/// Compact capsule filter chip — `Now`/`Schedule`/`Me`/`Someone else`, day/
/// time pickers, tip amounts. One recipe reused across every phase
/// (ride-request.jsx's repeated inline `Chip` components).
struct RideChip: View {
    let title: String
    let selected: Bool
    var monospaced: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .modifier(MonospacedIfNeeded(monospaced))
                .foregroundStyle(selected ? Color.mrtGoldButtonLabel : Color.mrtTextSec)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.mrtGold : Color.mrtRideChipFill, in: Capsule())
                .overlay(selected ? nil : Capsule().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget - 18)
    }
}

struct MonospacedIfNeeded: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }
    func body(content: Content) -> some View {
        if active { content.monospacedDigit() } else { content }
    }
}

// MARK: - Slide-up card (Schedule / Fleet / Tip pickers)
//
// Every "pick from a short list" moment in the ride-request flow (Search's
// Schedule sheet, Review's fleet picker, Summary's tip quip) is the same
// recipe: scrim + a rounded-top card sliding up from the sheet's own bottom
// edge (ride-request.jsx's `mrt-sched-up`, e.g. 296-346, 442-490) — same
// curve `ScheduledRideSheet` already uses for its own presentation. Callers
// drive the transition with `.animation(_, value: isShowing)` on the
// conditional at the call site (mirrors `ScheduledRideSheet`'s own root
// `.animation(_, value: ride != nil)`), matching Reduce Motion → easeOut.
struct RideSlideUpCard<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.mrtScrim
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                        .fill(Color.mrtRideSheetFill)
                        .overlay(
                            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                        )
                )
                // MYR-198 fix 1: every ride-flow sheet shown while the nav is
                // hidden must be bottom-flush to the PHYSICAL screen edge —
                // this card (Search's Schedule picker, Review's "Available
                // rides" fleet picker, Summary's tip quip) previously had no
                // `.ignoresSafeArea`, so its 26pt bottom content padding
                // landed on top of the ~34pt home-indicator inset instead of
                // the true edge, leaving a dead gap below the rounded card.
                // Same `.frame(maxWidth:.infinity, maxHeight:.infinity,
                // alignment:.bottom).ignoresSafeArea(edges:.bottom)` technique
                // `RideRequestSheetChrome`/`mrtBottomNav` already use — see
                // `RideRequestSheetChrome`'s header comment: it only
                // repositions this already content-sized card within a
                // larger invisible frame, it does not stretch the content.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom))
        }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }
}

/// Slide-up card title row — "Schedule pickup" / "Available rides" + a small
/// circular close button (ride-request.jsx e.g. 305-311).
struct RideSlideUpCardTitle: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.mrtTextSec)
                    .frame(width: 26, height: 26)
                    .background(Color.mrtElevated, in: Circle())
                    .contentShape(Circle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Wall-clock helpers (ride-request.jsx's repeated `fmtFromNow`/
// `addToClock`, e.g. 355-360, 555, 866-870)
//
// Every phase past Search needs "clock N minutes from now" and Review's stat
// pair additionally needs "add N minutes to an already-picked clock string"
// (the scheduled-pickup path). Centralized here since Review/Booking/
// Tracking/Summary all need the same math.
enum RideRequestClock {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    static func fromNow(minutes: Int) -> String {
        formatter.string(from: Date().addingTimeInterval(TimeInterval(minutes) * 60))
    }

    /// Adds `minutes` to a "5:30 PM"-style clock string, wrapping across
    /// midnight — ride-request.jsx `ReviewContent`'s `addToClock`.
    static func adding(_ minutes: Int, to clock: String) -> String {
        guard let date = formatter.date(from: clock) else { return clock }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let total = (((comps.hour ?? 0) * 60 + (comps.minute ?? 0) + minutes) % 1440 + 1440) % 1440
        var result = DateComponents()
        result.hour = total / 60
        result.minute = total % 60
        guard let resultDate = calendar.date(from: result) else { return clock }
        return formatter.string(from: resultDate)
    }
}

// MARK: - Declined notice (ride-request.jsx:1042-1066 `DeclinedNotice`)
//
// A compact bottom card overlaid on `.search` (not its own `RiderSheetPhase`
// — see `SharedViewerState.showDeclinedNotice`'s doc comment) after
// `RideRequestService.decline()`. Deliberately its own small card rather than
// `mrtConfirmDialog` (not a full-screen dialog in the source).
//
// MYR-197 briefly replaced this with a resurrected `OutcomeContent`
// (ride-request.jsx:670-717), reasoning it was the "one canonical" surface.
// That was wrong: `OutcomeContent` is defined in the design source but is
// **never mounted** anywhere in ride-request.jsx (`grep -c "<OutcomeContent"`
// is 0) — dead code, same category as the sparkline this codebase already
// declined to port. `DeclinedNotice` *is* mounted (ride-request.jsx:1254-1258,
// `requestState === 'rejected' && phase === 'search'`), so it's restored here
// verbatim as the canonical declined surface.
struct DeclinedNoticeCard: View {
    let requesterName: String
    let onDismiss: () -> Void
    let onRebook: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.mrtDangerFillSoft)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.mrtDialogRed)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ride declined")
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text("\(requesterName) can\u{2019}t take this ride right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 13)
            HStack(spacing: 9) {
                MRTButton("Dismiss", variant: .outlineMuted, size: .sm, action: onDismiss)
                MRTButton("Rebook", variant: .gold, size: .sm, action: onRebook)
            }
        }
        .padding(15)
        .background(Color.mrtDialogCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .shadow(color: .black.opacity(0.4), radius: 20, y: -6)
    }
}
