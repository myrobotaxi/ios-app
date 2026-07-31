import DesignSystem
import MyRobotaxiContracts
import SwiftUI
import WidgetKit

// MARK: - The rider's ride, as the lock screen and Dynamic Island see it
//
// PORTED FROM THE DESIGN, NOT COMPOSED FROM SCRATCH. `design/app/surfaces.jsx`
// carries `LiveActivityCard` (full / stale / banner) and
// `design/app/phone-frame.jsx` carries `DynamicIsland` (minimal / compact /
// expanded) — this is the SwiftUI port of that grammar:
//
//   • the header row: `HexLogo` at 18, an uppercase muted "MYROBOTAXI · {when}"
//     kicker, and a status marker on the trailing edge;
//   • the trip line "{vehicle} → {destination}", with the arrow muted and the
//     DESTINATION in gold (surfaces.jsx:269);
//   • uppercase micro-labels over tabular numerals (surfaces.jsx:273-278);
//   • the Dynamic Island's compact leading ring-around-a-gold-dot and its gold
//     tabular trailing figure (phone-frame.jsx:37-43);
//   • the expanded layout's big light-weight gold hero number with its small
//     uppercase label beneath (phone-frame.jsx:59-62).
//
// WHAT THE PORT DROPS, AND WHY. The design's card shows SPEED, BATTERY and a
// `TripProgressBar` with intermediate stops. None of the three is in the v1
// content state, and the reason is in the schema: an ActivityKit push is capped at
// 4KB and throttled by budget, so the bar for a field is "the rider would misread
// the screen without it". A rider does not misread a lock screen for want of the
// car's battery percentage. Rather than render them from stale or invented values,
// the port removes them and lets the ETA take the hero slot alone — which is also
// what makes the card legible at the size a lock screen actually gives it.
//
// The design's `stale` treatment is a flat 50% dim over the whole card. That is
// KEPT for the chrome but deliberately NOT applied to the ETA, which is REPLACED
// instead — see `StaleNotice`.

// MARK: - Lock screen / banner

struct RideActivityLockScreenView: View {
    let state: RideActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            tripLine
            etaBlock
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.mrtBg.opacity(0.62))
        .activitySystemActionForegroundColor(Color.mrtGold)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HexLogo(size: 18)

            Text("MyRoboTaxi · \(RideActivityCopy.kicker(for: state.status))")
                .mrtTextStyle(.label(size: 10))
                .foregroundStyle(Color.mrtTextSec)
                .lineLimit(1)

            Spacer(minLength: 4)

            // The design puts a `StatusBadge` here. The Activity has no VEHICLE
            // status to show (the content state carries a RIDE status, which the
            // kicker already says), so this is the badge's dot alone — the "live"
            // marker from the widget family (surfaces.jsx:187), gold because the
            // ride is the subject.
            Circle()
                .fill(isStale ? Color.mrtTextMuted : Color.mrtGold)
                .frame(width: 6, height: 6)
                .shadow(color: isStale ? .clear : Color.mrtGoldGlow, radius: 3)
        }
        .opacity(isStale ? 0.5 : 1)
    }

    private var tripLine: some View {
        // surfaces.jsx:268-270 — "{vehicle} → {destination}", arrow muted,
        // destination gold. Kept verbatim for the in-flight statuses; the terminal
        // ones get their own sentence from `RideActivityCopy.headline`, because
        // "Cancelled" over "Blue Whale → Home" reads as a ride still in progress.
        Group {
            if RideActivityCopy.showsCountdown(for: state.status), !state.destination.isEmpty {
                HStack(spacing: 6) {
                    Text(RideActivityCopy.vehicleDisplayName(state.vehicleName))
                        .foregroundStyle(Color.mrtText)
                    Text("→")
                        .foregroundStyle(Color.mrtTextMuted)
                    Text(state.destination)
                        .foregroundStyle(Color.mrtGold)
                }
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            } else {
                Text(
                    RideActivityCopy.headline(
                        for: state.status,
                        vehicleName: state.vehicleName,
                        destination: state.destination
                    )
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mrtText)
                .lineLimit(2)
            }
        }
        .opacity(isStale ? 0.5 : 1)
    }

    @ViewBuilder
    private var etaBlock: some View {
        if isStale {
            StaleNotice(state: state)
        } else if let eta = state.etaDate, RideActivityCopy.showsCountdown(for: state.status) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RideActivityCopy.etaLabel(for: state.status))
                    .mrtTextStyle(.label(size: 10))
                    .foregroundStyle(Color.mrtTextMuted)

                // `Text(timerInterval:)` is the whole reason the contract sends an
                // ABSOLUTE instant rather than a duration: the countdown runs on the
                // phone, correct to the second, with no push in between. A duration
                // would have to be re-pushed to stay true and would silently rot
                // between the 60–90s ticks.
                Text(timerInterval: Date()...eta, countsDown: true)
                    .font(.system(size: 26, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtGold)
            }
        }
        // No ETA and not stale — a car with no active nav route yields no key at
        // all. The block is simply absent rather than showing a placeholder: the
        // schema's "never a guess" applies to the rendering as much as to the wire.
    }
}

// MARK: - Staleness

/// What stands in for the countdown once ActivityKit marks the content stale.
///
/// MYR-194's policy is honest staleness — "never a confident stale ETA". The
/// design's stale card DIMS its ETA (surfaces.jsx:240-241, `opacity: 0.5`), and a
/// dimmed number is still a number: a rider reads "4 min" and plans around it.
/// So the ETA is REPLACED, and the card says what it actually knows — when it last
/// heard anything — in the same muted chip the design uses for its stale line
/// (surfaces.jsx:280-284).
struct StaleNotice: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(RideActivityCopy.staleTitle)
                .mrtTextStyle(.label(size: 10))
                .foregroundStyle(Color.mrtTextMuted)

            // The "as of" instant is the ETA's own timestamp when there is one —
            // the last thing the server actually told us — falling back to the
            // system's relative rendering of now. `Text(_:style: .relative)` keeps
            // counting on its own, so the line stays true while the screen is
            // asleep and nothing is repainting it.
            if let reference = state.etaDate {
                Text("As of ") + Text(reference, style: .relative) + Text(" ago")
            } else {
                Text(RideActivityCopy.staleFallbackSubtitle)
            }
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Color.mrtTextSec)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.mrtText.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Dynamic Island pieces

/// phone-frame.jsx:37-39 — an 18pt ring in the status colour around a gold 8pt
/// dot. The ring reads as "a ride is running" at a glance without any text.
struct RideActivityIslandLeading: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            Circle()
                .fill(Color.mrtGold)
                .frame(width: 8, height: 8)
                .shadow(color: Color.mrtGoldGlow, radius: 3)
        }
        .accessibilityLabel(RideActivityCopy.kicker(for: state.status))
    }

    private var ringColor: Color {
        switch state.status {
        case .enroute, .accepted: return .mrtDriving
        case .arrived: return .mrtParked
        case .completed: return .mrtDriving
        default: return .mrtOffline
        }
    }
}

/// phone-frame.jsx:41-43 — the trailing figure, gold and tabular while the ride is
/// running.
struct RideActivityIslandTrailing: View {
    let state: RideActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let eta = state.etaDate, RideActivityCopy.showsCountdown(for: state.status), !isStale {
            Text(timerInterval: Date()...eta, countsDown: true)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.mrtGold)
                // The compact region is a few dozen points wide; a timer that has
                // rolled past its instant must not push the island open.
                .frame(maxWidth: 56)
        } else {
            // No number to show. The STATUS WORD takes the slot rather than a dash:
            // in the compact island this is the only text the rider gets, so
            // "Arrived" earns its place where "—" would not.
            Text(RideActivityCopy.kicker(for: state.status))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isStale ? Color.mrtTextMuted : Color.mrtText)
                .lineLimit(1)
        }
    }
}

/// phone-frame.jsx:57-63 — the expanded hero: a large light-weight gold numeral
/// over a small uppercase label.
struct RideActivityIslandExpanded: View {
    let state: RideActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if isStale {
                    Text(RideActivityCopy.staleTitle)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.mrtTextSec)
                } else if let eta = state.etaDate, RideActivityCopy.showsCountdown(for: state.status) {
                    Text(timerInterval: Date()...eta, countsDown: true)
                        .font(.system(size: 30, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtGold)
                        .lineLimit(1)
                    Text(RideActivityCopy.etaLabel(for: state.status))
                        .mrtTextStyle(.label(size: 10))
                        .foregroundStyle(Color.mrtTextMuted)
                } else {
                    Text(RideActivityCopy.kicker(for: state.status))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.mrtText)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(RideActivityCopy.vehicleDisplayName(state.vehicleName))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                if !state.destination.isEmpty, RideActivityCopy.showsCountdown(for: state.status) {
                    Text(state.destination)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.mrtGold)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}
