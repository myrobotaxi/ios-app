import SwiftUI
import MapKit
import DesignSystem

// MARK: - ScheduledRideSheet (MYR-191, design/app/shared-screens.jsx
// ScheduledRideSheet 218-436, Handoff §5.10 intro)
//
// Slides up over `RideHistoryScreen`'s Scheduled list when a row is tapped.
// Four modes sharing one sheet container (jsx `mode` local state, reset
// whenever a new `ride` opens): `.details` (status, map preview, route
// block, people/vehicle + optional passenger, Cancel/Reschedule),
// `.reschedule` (day/time chip pickers → "Move to…"), `.requested` (pulse
// rings, "Reschedule requested"), `.confirmCancel` (destructive confirm).
// Mutations are real local state threaded back through `onReschedule`/
// `onCancel` — `RideHistoryScreen` owns the `ScheduledRide` array.
struct ScheduledRideSheet: View {
    let ride: ScheduledRide?
    let onClose: () -> Void
    /// (id, day, time, date) — shared-screens.jsx:309 `onReschedule(ride.id, day, time, SCHED_DATES[day])`.
    let onReschedule: (String, String, String, String) -> Void
    let onCancel: (String) -> Void
    /// Presenting screen's full height, for the 88% cap below — supplied by
    /// the caller (shared-screens.jsx:247 `maxHeight: '88%'`); `nil` leaves
    /// the sheet sized to its content (every mode comfortably fits within a
    /// standard device height, so the cap only matters on the very smallest
    /// screens).
    var screenHeight: CGFloat?

    private enum Mode: Equatable {
        case details
        case reschedule
        case requested
        case confirmCancel
    }

    @State private var mode: Mode = .details
    @State private var day = "Today"
    @State private var time = "5:30 PM"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let schedDays = ["Today", "Tomorrow", "Thu", "Fri", "Sat", "Sun", "Mon"]
    private static let schedDates: [String: String] = [
        "Today": "Jun 16", "Tomorrow": "Jun 17", "Thu": "Jun 18",
        "Fri": "Jun 19", "Sat": "Jun 20", "Sun": "Jun 21", "Mon": "Jun 22",
    ]
    /// shared-screens.jsx:209-216 — every half hour from 6:00 AM to 10:30 PM.
    private static let schedTimes: [String] = {
        var out: [String] = []
        for hour in 6...22 {
            for minute in [0, 30] {
                let meridiem = hour >= 12 ? "PM" : "AM"
                let hour12 = hour % 12 == 0 ? 12 : hour % 12
                out.append("\(hour12):\(minute == 0 ? "00" : "30") \(meridiem)")
            }
        }
        return out
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            if let ride {
                Color.mrtScrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)
                sheet(for: ride)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), // mrt-sched-up
            value: ride != nil
        )
        .onChange(of: ride?.id) { _, _ in
            guard let ride else { return }
            mode = .details
            day = ride.day
            time = ride.time
            #if DEBUG
            switch DebugScene.current { // MYR-200 scheduled* scenes
            case .scheduledReschedule: mode = .reschedule
            case .scheduledRequested: mode = .requested
            case .scheduledConfirmCancel: mode = .confirmCancel
            default: break
            }
            #endif
        }
    }

    // MYR-198 fix 5 (client QA round 3 — the PR #17 fix for this DIDN'T
    // hold, verified empirically on device): a bare `ScrollView` always
    // claims its full PROPOSED height along the scroll axis regardless of
    // how tall its content actually is — it has no notion of "hug my
    // content up to a cap." `.frame(maxHeight: screenHeight * 0.88)` only
    // caps that proposal; every mode's content is comfortably shorter than
    // 88% of the screen (this file's own header comment), so the ScrollView
    // still rendered at the full 88% height with a large blank area of its
    // own `mrtRideSheetFill` background below the real content in all four
    // modes (details/reschedule/requested/confirmCancel) — the "huge dead
    // gap" the client screenshot shows below "Changes notify Mom to
    // re-confirm." `ViewThatFits(in: .vertical)` fixes this the idiomatic
    // way: it's proposed the same `88%`-capped height (via the `.frame`
    // below, which still wraps the whole `ViewThatFits`), and it picks the
    // FIRST candidate whose ideal height fits that proposal — the plain,
    // non-scrolling `sheetBody` hugs its own content and wins on every
    // normal device/mode; the `ScrollView` candidate only takes over (and
    // only then fills the 88% cap) on the rare case content actually
    // overflows it (huge Dynamic Type, the smallest devices).
    private func sheet(for ride: ScheduledRide) -> some View {
        ViewThatFits(in: .vertical) {
            sheetBody(for: ride)
            ScrollView { sheetBody(for: ride) }
        }
        // shared-screens.jsx:247 `maxHeight: '88%'`.
        .frame(maxHeight: screenHeight.map { $0 * 0.88 })
        .background(
            UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.modalRadius, topTrailingRadius: MRTMetrics.modalRadius, style: .continuous)
                .fill(Color.mrtRideSheetFill)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.modalRadius, topTrailingRadius: MRTMetrics.modalRadius, style: .continuous)
                        .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .topTrailing) { closeButton }
        .accessibilityAddTraits(.isModal)
    }

    /// The actual mode content, shared by both `ViewThatFits` candidates in
    /// `sheet(for:)` above — identical VStack either way, the only
    /// difference is whether a `ScrollView` wraps it.
    private func sheetBody(for ride: ScheduledRide) -> some View {
        VStack(spacing: 0) {
            grabHandle
            Group {
                switch mode {
                case .confirmCancel: confirmCancelContent(ride)
                case .reschedule: rescheduleContent(ride)
                case .requested: requestedContent(ride)
                case .details: detailsContent(ride)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }

    /// 36×4 rounded handle (shared-screens.jsx:251) — `DesignSystem`'s
    /// `MRTGrabHandle` is internal to that module, so sheets built in the
    /// App target (this one, distinct from `MRTDetentSheet`'s own) draw
    /// their own copy of the same 36×4 shape.
    private var grabHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.mrtElevated)
            .frame(width: 36, height: 4)
            .padding(.top, 14)
            .padding(.bottom, 16)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.mrtTextSec)
                .frame(width: 28, height: 28)
                .background(Color.mrtElevated, in: Circle())
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
        .padding(.trailing, 18)
        .accessibilityLabel("Close")
    }

    // MARK: Details (shared-screens.jsx:341-433)

    private func detailsContent(_ ride: ScheduledRide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow(ride)
                .padding(.bottom, 14)
            mapPreview(ride)
                .padding(.bottom, 14)
            routeBlock(ride)
                .padding(.bottom, 12)
            peopleCard(ride)
                .padding(.bottom, 16)
            HStack(spacing: 10) {
                cancelButton { mode = .confirmCancel }
                MRTButton("Reschedule", variant: .outlineDraw, fullWidth: true) { mode = .reschedule }
            }
            .padding(.bottom, 11)
            Text("Changes notify \(ride.driver) to re-confirm.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.mrtTextMuted)
                .tracking(0.1)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        // shared-screens.jsx:341 details `<div>` carries no top padding of
        // its own (only `confirmCancel`/`requested` do, jsx:262/317) — the
        // sheet's own 14px top inset is already spent on `grabHandle`'s
        // padding above. An extra `.padding(.top, 14)` here (MYR-197 audit
        // finding) added a stray 14pt gap before `statusRow` not present in
        // the design source.
    }

    private func statusRow(_ ride: ScheduledRide) -> some View {
        let confirmed = ride.status == .confirmed
        return HStack(spacing: 10) {
            Text("SCHEDULED RIDE")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.mrtGold)
            HStack(spacing: 5) {
                Circle().fill(confirmed ? Color.mrtDriving : Color.mrtTextMuted).frame(width: 5, height: 5)
                Text(confirmed ? "Confirmed" : "Pending confirmation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(confirmed ? Color.mrtDriving : Color.mrtTextSec)
            }
            Spacer(minLength: 0)
        }
    }

    private func mapPreview(_ ride: ScheduledRide) -> some View {
        ZStack(alignment: .bottomLeading) {
            RideRouteMap(route: ride.route)
            LinearGradient(
                stops: [.init(color: .clear, location: 0.32), .init(color: .mrtRideMapScrim, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 14)).foregroundStyle(Color.mrtGold)
                Text("\(ride.day) \u{00B7} \(ride.time)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtGoldRowText) // '#F4EFE2' (shared-screens.jsx:362)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
        }
        .frame(height: MRTMetrics.rideMapPreviewHeight)
        .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
    }

    /// shared-screens.jsx:368-373 lays the pickup/destination column and the
    /// dot+connector column out as `display: 'flex', alignItems: 'stretch'`
    /// siblings — CSS stretch sizes the connector to the (already-known)
    /// row-column height. SwiftUI's `HStack` has no equivalent: pairing a
    /// `.frame(maxHeight: .infinity)` connector with a content `VStack` as
    /// plain HStack siblings left the connector's "infinite" request
    /// unbounded, which propagated up through this view's parent `VStack`
    /// (no fixed-height frame anywhere above it) all the way to the
    /// `GeometryReader`-sized sheet — the whole `ScheduledRideSheet` stretched
    /// to fill the screen instead of hugging its content (MYR-197 QA
    /// screenshot: large blank dead zone below the sheet's real content).
    /// Fix: make the row column the foreground view and paint the dot+
    /// connector as its `.background(alignment: .leading)` — SwiftUI proposes
    /// a background exactly the foreground's *resolved* size, so the
    /// connector's `maxHeight: .infinity` now resolves against the row
    /// column's natural height instead of the ambient screen height.
    private func routeBlock(_ ride: ScheduledRide) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                routeRow(label: "PICKUP", value: ride.from)
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
                routeRow(label: "DESTINATION", value: ride.to)
            }
            .padding(.leading, 22)
            .background(alignment: .leading) {
                VStack(spacing: 4) {
                    Circle().fill(Color.mrtDriving).frame(width: 9, height: 9)
                        .shadow(color: .mrtDriving.opacity(0.67), radius: 4)
                    Rectangle().fill(Color.mrtBorder).frame(width: 2).frame(maxHeight: .infinity)
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.mrtGold).frame(width: 9, height: 9)
                        .shadow(color: .mrtGoldGlow, radius: 4)
                }
                .padding(.vertical, 18)
            }
            HStack(spacing: 18) {
                statPair(label: "DISTANCE", value: "\(String(format: "%.1f", ride.miles)) mi")
                statPair(label: "DRIVE", value: "\(ride.estimatedMinutes) min")
            }
            .padding(.leading, 22)
            .padding(.top, 11)
            .overlay(alignment: .top) { Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .mrtSurface(.control, fill: .mrtElevated, radius: MRTMetrics.cardRadius)
    }

    private func routeRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Color.mrtTextMuted)
            Text(value)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Color.mrtText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }

    private func statPair(label: String, value: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Color.mrtTextMuted)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.mrtText)
        }
    }

    private func peopleCard(_ ride: ScheduledRide) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Circle().fill(Color.mrtElevated).frame(width: 34, height: 34)
                    .overlay(Text(ride.driver.prefix(1)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.mrtText))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ride.driver)\u{2019}s \(ride.vehicle)")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                    Text("\(ride.relationship) \u{00B7} Shared with you")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "car.fill").font(.system(size: 15)).foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)

            if let passenger = ride.passenger {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
                HStack(spacing: 11) {
                    Circle().fill(Color.mrtGold.opacity(Double(0x22) / 255.0)).frame(width: 34, height: 34)
                        .overlay(Text(passenger.initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mrtGold))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(passenger.name)
                                .font(.system(size: 14, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundStyle(Color.mrtText)
                                .lineLimit(1)
                            Text("PASSENGER")
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Color.mrtGold)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.mrtGoldBadgeFill, in: Capsule())
                        }
                        Text("\(passenger.phone) \u{00B7} \(ride.status == .confirmed ? "has tracking link" : "gets link on confirm")")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Color.mrtTextSec)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(Color.mrtTextMuted)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
        }
        .mrtSurface(.control, fill: .mrtElevated, radius: 13)
    }

    private func cancelButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Cancel ride")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.mrtDialogRed)
                .frame(maxWidth: .infinity)
                .frame(height: MRTButtonSize.md.height)
                .background(Color.mrtDangerFillSoft, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                        .strokeBorder(Color.mrtRideCancelButtonBorder, lineWidth: MRTMetrics.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MRTPressScaleButtonStyle())
    }

    // MARK: Reschedule (shared-screens.jsx:276-314)

    private func rescheduleContent(_ ride: ScheduledRide) -> some View {
        let dirty = day != ride.day || time != ride.time
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                mode = .details
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("Back").font(.system(size: 13, weight: .semibold)).tracking(-0.1)
                }
                .foregroundStyle(Color.mrtGold)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            Text("Reschedule pickup")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 4)
            Text("\(ride.from) \u{2192} \(ride.to)")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
                .lineLimit(1)
                .padding(.bottom, 20)

            chipLabel("Day").padding(.bottom, 9)
            chipRow(Self.schedDays, selection: $day)
                .padding(.bottom, 20)

            chipLabel("Time").padding(.bottom, 9)
            chipRow(Self.schedTimes, selection: $time, monospaced: true)
                .padding(.bottom, 22)

            MRTButton(
                dirty ? "Move to \(day) \(time)" : "No changes",
                variant: dirty ? .gold : .outlineMuted
            ) {
                if dirty {
                    onReschedule(ride.id, day, time, Self.schedDates[day] ?? ride.date)
                    mode = .requested
                } else {
                    mode = .details
                }
            }
            .padding(.bottom, 12)
            Text("\(ride.driver) will be asked to re-confirm the new time.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.mrtTextMuted)
                .tracking(0.1)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        // shared-screens.jsx:276 reschedule `<div>` also carries no top
        // padding of its own — same stray-14pt finding as `detailsContent`
        // above (MYR-197 audit).
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Color.mrtTextMuted)
    }

    private func chipRow(_ items: [String], selection: Binding<String>, monospaced: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(items, id: \.self) { item in
                    let selected = selection.wrappedValue == item
                    Button {
                        selection.wrappedValue = item
                    } label: {
                        Text(item)
                            .font(.system(size: 13.5, weight: .semibold))
                            .tracking(-0.1)
                            .modifier(MonospacedIf(monospaced))
                            .foregroundStyle(selected ? Color.mrtGoldButtonLabel : Color.mrtTextSec)
                            .padding(.horizontal, monospaced ? 14 : 15)
                            .padding(.vertical, 9)
                            .background(selected ? Color.mrtGold : Color.mrtRideChipFill, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
                            .overlay(
                                selected ? nil : RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: MRTMetrics.minTapTarget - 18)
                }
            }
        }
    }

    // MARK: Requested (shared-screens.jsx:316-339)

    private func requestedContent(_ ride: ScheduledRide) -> some View {
        VStack(spacing: 0) {
            ZStack {
                ExpandingPulse(shape: Circle(), size: CGSize(width: 74, height: 74), color: .mrtGold, lineWidth: 2, duration: 1.4, delays: [0], scaleFrom: 0.9, scaleTo: 1.6, opacityFrom: 0.7)
                ExpandingPulse(shape: Circle(), size: CGSize(width: 54, height: 54), color: .mrtGold, lineWidth: 2, duration: 1.4, delays: [0.4], scaleFrom: 0.9, scaleTo: 1.6, opacityFrom: 0.7)
                Circle().fill(Color.mrtGold).frame(width: 30, height: 30)
                    .overlay(Image(systemName: "calendar").font(.system(size: 15)).foregroundStyle(Color.mrtGoldButtonLabel))
                    .shadow(color: .mrtGoldGlow, radius: 12)
            }
            .frame(width: 74, height: 74)
            .padding(.bottom, 20)

            Text("Reschedule requested")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 7)
            Text("Waiting for \(ride.driver) to confirm the new pickup time.")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 270)
                .padding(.bottom, 16)

            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                Text("\(ride.day) \u{00B7} \(ride.time)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtGold)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Color.mrtGoldTileFaint, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                    .strokeBorder(Color.mrtGold.opacity(Double(0x40) / 255.0), lineWidth: MRTMetrics.hairline)
            )
            .padding(.bottom, 22)

            MRTButton("Done", variant: .gold, action: onClose)
                .padding(.bottom, 12)

            Text(footerNote(ride))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.mrtTextMuted)
                .tracking(0.1)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }

    private func footerNote(_ ride: ScheduledRide) -> String {
        if let passenger = ride.passenger {
            return "You and \(passenger.firstName) get the updated time once \(ride.driver) responds."
        }
        return "You\u{2019}ll be notified once \(ride.driver) responds."
    }

    // MARK: Confirm cancel (shared-screens.jsx:261-274)

    private func confirmCancelContent(_ ride: ScheduledRide) -> some View {
        VStack(spacing: 0) {
            Circle().fill(Color.mrtDangerFillSoft).frame(width: MRTMetrics.dialogIconSize, height: MRTMetrics.dialogIconSize)
                .overlay(Image(systemName: "calendar").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.mrtDialogRed))
                .padding(.bottom, 14)
            Text("Cancel this ride?")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 6)
            (Text("Your reservation to ") + Text(ride.to).foregroundStyle(Color.mrtText).fontWeight(.semibold)
                + Text(" on \(ride.day) \(ride.time) with \(ride.driver)\u{2019}s \(ride.vehicle) will be released."))
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
                .padding(.bottom, 22)
            VStack(spacing: 9) {
                cancelButton { onCancel(ride.id) }
                MRTButton("Keep reservation", variant: .ghost) { mode = .details }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Static route preview map (shared-screens.jsx:352-358)

/// Non-interactive `Map` snapshot fitted to a ride's route — the
/// ScheduledRideSheet twin of `DriveSummaryScreen`'s `DriveHeroMap`, sized
/// for the sheet's 104pt preview panel instead of the full-screen hero.
private struct RideRouteMap: View {
    let route: [CLLocationCoordinate2D]

    var body: some View {
        Map(initialPosition: .region(VehicleRoute.fittedRegion(for: route, paddingFactor: 1.8)), interactionModes: []) {
            // Suppresses MapKit's own auto-drawn "Origin"/"Destination" title
            // labels next to the dots — see `VehicleMapView`'s identical call
            // + doc comment (MYR-167 review finding #3).
            mapContent.annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if route.count > 1 {
            MapPolyline(coordinates: route)
                .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: route)
                .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        if let origin = route.first {
            Annotation("Origin", coordinate: origin) { MRTEndpointDot(color: .mrtDriving, size: 11) }
        }
        if let destination = route.last {
            Annotation("Destination", coordinate: destination) { MRTEndpointDot(color: .mrtGold, size: 13) }
        }
    }
}

private struct MonospacedIf: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }
    func body(content: Content) -> some View {
        if active { content.monospacedDigit() } else { content }
    }
}

#Preview {
    ZStack {
        Color.mrtBg.ignoresSafeArea()
        ScheduledRideSheet(
            ride: RideHistoryFixtures.scheduledRides[0],
            onClose: {},
            onReschedule: { _, _, _, _ in },
            onCancel: { _ in }
        )
    }
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
