import SwiftUI
import DesignSystem

// MARK: - RideRequestTrackingContent (MYR-171 base, reworked MYR-270 dispatch v2)
//
// The rider's live tracking sheet. Two legs (car → pickup, then pickup → drop-off).
// MYR-270 drives the STAGE off the server status on the live path — the owner-driven
// dispatch v2 lifecycle (accepted → arrived → enroute → completed) — while the SIM /
// DEBUG tracking scenes (status `.accepted`, `trackProgress`-ticker-driven) keep
// deriving the leg from progress vs `pickupCut`, so `trackingLeg1/leg2/arriving`
// render exactly as before (drift gate). See `RiderTrackingStage.stage(...)`.
//
// The rider affordance out of `arrived` is the CIRCULAR PULSING "Start ride" CTA
// (`PulseStartButton`, DesignSystem), gated to EXACTLY `status == .arrived`: never
// during `accepted` (the owner has not confirmed pickup yet — the server would 409 a
// start). Tapping it calls `start()`, which flips `arrived → enroute` and makes the
// backend push the drop-off nav.
struct RideRequestTrackingContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: any RideRequestService
    var totalHeight: CGFloat?
    /// MYR-271: when hosted inside the `PanSheet` engine (`RiderTrackingSheet`), the
    /// engine's surface provides the sheet wash/corners/hairline, so the content
    /// drops its own `rideRequestSheetChrome()` (mirrors the search sheet's `hosted`
    /// path). `false` keeps the standalone bottom-pinned card for previews/fallback.
    var hosted: Bool = false
    /// MYR-270: the streamed nav ETA (minutes) of the ride's car during the in-ride
    /// leg, or `nil` when no live ETA stream is available yet (v1 rider gap — the
    /// arriving takeover then never fires on live, never a fabricated ETA, MYR-228).
    /// Drives the `enroute` "Arriving" takeover off the REAL wire ETA (≤ 2), not a timer.
    var navMinutesToArrival: Int? = nil

    /// MYR-270 — disables the "Start ride" CTA for the frame it is tapped. `start()`
    /// flips the status to `.enroute` synchronously (the button then vanishes), so
    /// this only guards a double-tap landing in the same frame. Reset on every status
    /// change so a re-shown button (a failed/reverted advance) is tappable again.
    @State private var starting = false

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    private var fleetMember: FleetMember { viewerState.liveFleetMember ?? request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var isLiveVehicle: Bool { viewerState.liveFleetMember != nil }
    private var passenger: RidePassenger? { request?.input.passenger }
    private var destination: RidePlace { request?.input.destination ?? RideRequestFixtures.recentPlaces[0] }
    private var pickupLabel: String { request?.input.pickup.label ?? "Current location" }

    private var progress: Double { request?.trackProgress ?? 0 }
    private var pickupCut: Double { request?.pickupCut ?? 0.2 }
    private var atPickupByProgress: Bool { progress >= pickupCut }

    private var pickupLegMinutes: Double { RideRequestTiming.pickupLegMinutes }
    private var tripMinutes: Int { destination.minutes }
    private var totalMinutes: Double { pickupLegMinutes + Double(tripMinutes) }

    private var remainMinutes: Int { max(0, Int(((1 - progress) * totalMinutes).rounded())) }
    private var toPickupMinutes: Int {
        max(0, Int(((pickupCut - progress) / pickupCut * pickupLegMinutes).rounded()))
    }

    /// ride-request.jsx:565 `pickupMilesTotal = 2.2`.
    private static let pickupLegMiles = 2.2

    private var pickupRemainMiles: Double {
        max(0.1, (1 - min(progress, pickupCut) / pickupCut) * Self.pickupLegMiles)
    }

    private var rideProgress: Double { max(0, (progress - pickupCut) / max(0.0001, 1 - pickupCut)) }
    private var dropRemainMiles: Double { max(0.1, (1 - rideProgress) * destination.miles) }

    private var pickupClock: String {
        RideRequestClock.fromNow(minutes: max(0, Int(((pickupCut - min(progress, pickupCut)) / pickupCut * pickupLegMinutes).rounded())))
    }

    private var arriveClock: String { RideRequestClock.fromNow(minutes: remainMinutes) }

    // MARK: MYR-270 — status-driven stage (live) / progress-derived (sim)

    /// Whether the drop-off "Arriving" takeover fires. On the live in-ride leg it is
    /// the REAL streamed nav ETA (≤ 2) — never a timer, never fabricated; on the
    /// sim/`.accepted` progress path it is the existing progress-derived `remain ≤ 2`
    /// so the `trackingArriving` sim scene is unchanged.
    private var arriving: Bool {
        switch request?.status {
        case .enroute, .completed:
            if let eta = navMinutesToArrival { return eta <= 2 }
            return false
        default:
            return atPickupByProgress && remainMinutes <= 2
        }
    }

    private var stage: RiderTrackingStage {
        RiderTrackingStage.stage(status: request?.status, atPickupByProgress: atPickupByProgress, arriving: arriving)
    }

    /// Whether the sheet renders the IN-RIDE leg framing (hero/itinerary/"Your ride"
    /// row). `arrivedAwaitingStart` renders its own card, so it reads as leg 1 here.
    private var atPickup: Bool {
        switch stage {
        case .inRide, .arrivingDropoff: return true
        case .toPickup, .arrivedAwaitingStart: return false
        }
    }

    private var arrivingPickup: Bool { !atPickup && toPickupMinutes <= 1 }

    private var statusWord: String {
        if !atPickup { return arrivingPickup ? "Your ride is arriving" : "Heading your way" }
        return stage == .arrivingDropoff ? "Arriving at drop-off" : "Heading to \(destination.label)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch stage {
            case .arrivingDropoff:
                arrivalHeader
            case .arrivedAwaitingStart:
                arrivedContent
            case .toPickup, .inRide:
                liveHeader
                if !atPickup {
                    rideRow(emphasize: true).padding(.bottom, 12)
                }
                itineraryStops.padding(.bottom, 12)
                if atPickup {
                    rideRow(emphasize: false)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 30)
        .modifier(TrackingChrome(hosted: hosted))
        .onChange(of: request?.status) {
            // The advance resolved — either it moved on (button gone) or a
            // failed/reverted advance came back (button re-shown). Clear the latch
            // so a re-shown "Start ride" is tappable again (MYR-265 review bug).
            starting = false
        }
    }

    // MARK: Live header (ride-request.jsx:820-838)

    private var liveHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(Color.mrtGold).frame(width: 6, height: 6).shadow(color: .mrtGoldGlow, radius: 4)
                    RideEyebrowText(text: statusWord, color: .mrtGold, size: 11)
                }
                (Text(atPickup ? "Dropping you off at " : "Picking you up at ")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mrtTextSec)
                 + Text(atPickup ? destination.label : pickupLabel)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(heroMinutesText)
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .tracking(-1)
                        .foregroundStyle(Color.mrtText)
                    Text("min")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mrtGold.opacity(0.8))
                }
                Text(heroMilesText)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtGold.opacity(0.6))
            }
        }
        .padding(.bottom, 16)
    }

    private var heroMinutesText: String {
        let minutes = atPickup ? remainMinutes : toPickupMinutes
        return minutes < 1 ? "<1" : "\(minutes)"
    }

    private var heroMilesText: String {
        let miles = atPickup ? dropRemainMiles : pickupRemainMiles
        return "\(String(format: "%.1f", miles)) mi away"
    }

    // MARK: Itinerary stops (ride-request.jsx:793-816 `Stop`)

    private var itineraryStops: some View {
        VStack(alignment: .leading, spacing: 0) {
            stopRow(
                isDropoff: false, place: pickupLabel, clock: pickupClock, filled: atPickup,
                note: atPickup ? "Picked up" : "\(String(format: "%.1f", pickupRemainMiles)) mi \u{00B7} \(toPickupMinutes) min",
                last: false
            )
            stopRow(
                isDropoff: true, place: destination.label, clock: arriveClock, filled: false,
                note: atPickup ? "\(String(format: "%.1f", dropRemainMiles)) mi \u{00B7} \(remainMinutes) min" : "\(String(format: "%.1f", destination.miles)) mi trip",
                last: true
            )
        }
        .padding(15)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    private func stopRow(isDropoff: Bool, place: String, clock: String, filled: Bool, note: String, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                RideEyebrowText(text: isDropoff ? "Drop-off" : "Pickup", color: .mrtGold, size: 10)
                Spacer(minLength: 8)
                Text(clock).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Color.mrtTextSec)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(place).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(note).font(.system(size: 12)).foregroundStyle(Color.mrtTextMuted).lineLimit(1)
            }
        }
        .padding(.leading, 25) // 12pt dot + 13pt gap
        .padding(.bottom, last ? 0 : 16)
        .background(alignment: .topLeading) {
            VStack(spacing: 4) {
                Group {
                    if isDropoff {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.mrtGold, lineWidth: 2)
                    } else {
                        Circle()
                            .strokeBorder(Color.mrtGoldTrace, lineWidth: 2)
                            .background(Circle().fill(filled ? Color.mrtGoldTrace : Color.clear))
                    }
                }
                .frame(width: 12, height: 12)
                if !last {
                    connector
                }
            }
            .padding(.top, 3)
        }
    }

    @ViewBuilder
    private var connector: some View {
        if atPickup {
            Rectangle().fill(Color.mrtGold).frame(width: 2).frame(maxHeight: .infinity)
        } else {
            RideConnectorDash()
                .stroke(Color.mrtBorder, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Ride row — "Look for" (spotting) vs "Your ride" (quiet reference)

    private func rideRow(emphasize: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                RideEyebrowText(text: emphasize ? "Look for" : "Your ride", color: emphasize ? .mrtGold : Color.mrtGold.opacity(0.6), size: 9.5)
                Text("\(fleetMember.colorName) \(fleetMember.name)")
                    .font(.system(size: emphasize ? 17 : 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                Text(fleetMember.model + (passenger?.name.isEmpty == false ? " \u{00B7} for \(passenger!.name)" : ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !fleetMember.plate.isEmpty {
                if emphasize && !isLiveVehicle {
                    emphasizedPlateChip
                } else {
                    RidePlateChip(plate: fleetMember.plate)
                }
            }
        }
        .padding(.horizontal, emphasize ? 14 : 13)
        .padding(.vertical, emphasize ? 13 : 11)
        .background(emphasize ? Color.mrtGold.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mrtGold.opacity(emphasize ? Double(0x66) / 255.0 : Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
        )
    }

    private var emphasizedPlateChip: some View {
        Text(fleetMember.plate)
            .font(.system(size: 18, weight: .bold))
            .monospacedDigit()
            .tracking(1.5)
            .foregroundStyle(Color.mrtGoldButtonLabel)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.mrtGold, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(MRTShimmerBand())
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .mrtGoldGlow, radius: 10)
    }

    // MARK: MYR-270 — arrived: "Your car is here" + circular pulsing Start CTA
    //
    // Gated to EXACTLY `status == .arrived` (owner has confirmed pickup). During
    // `accepted` the CTA never shows — the server would 409 a start before pickup is
    // confirmed. The button flips `arrived → enroute` (server pushes the dropoff nav)
    // the instant it is tapped, so it then disappears (leg 2).

    private var arrivedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color.mrtGold).frame(width: 6, height: 6).shadow(color: .mrtGoldGlow, radius: 4)
                RideEyebrowText(text: "Your car is here", color: .mrtGold, size: 11)
            }
            .padding(.bottom, 10)
            // Reuse the "Look for" spotting chip so the rider can identify the car.
            rideRow(emphasize: true)
                .padding(.bottom, 22)
            if request?.status == .arrived {
                HStack {
                    Spacer(minLength: 0)
                    PulseStartButton {
                        guard !starting else { return }
                        starting = true
                        rideRequestService.startRide()
                    }
                    .disabled(starting)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Arrival takeover (ride-request.jsx:756-774)

    private var arrivalHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arriving")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.6)
                    .mrtTextShimmer(duration: 2.6)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text(remainMinutes < 1 ? "< 1 min" : "\(remainMinutes) min")
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtText)
                    Text("\(String(format: "%.1f", dropRemainMiles)) mi")
                        .font(.system(size: 17))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            .padding(.bottom, 8)

            HStack(spacing: 4) {
                Text("at").font(.system(size: 15)).foregroundStyle(Color.mrtTextSec)
                Text(destination.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText)
            }
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "bag").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                Text("Grab all your belongings")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.mrtGold.opacity(0.9))
            }
            .padding(.top, 13)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtGold.opacity(Double(0x24) / 255.0)).frame(height: MRTMetrics.hairline)
            }
            .padding(.bottom, 14)

            rideRow(emphasize: false)
        }
    }
}

// MARK: - Rider tracking stage (MYR-270, pure + testable)

/// The rider tracking sheet's stage. On the LIVE path it follows the server status
/// (owner-driven dispatch v2); on the SIM/`.accepted` progress path it derives from
/// the `trackProgress` ticker so the existing tracking drift-gate scenes render
/// unchanged.
enum RiderTrackingStage: Equatable {
    /// Leg 1 — car heading to the pickup ("Heading your way").
    case toPickup
    /// The car has arrived and the rider was picked up; awaiting the rider's Start
    /// ("Your car is here" + the pulsing Start CTA). LIVE-only (`status == .arrived`).
    case arrivedAwaitingStart
    /// Leg 2 — the ride has started, heading to the drop-off.
    case inRide
    /// The drop-off "Arriving" takeover (last stretch).
    case arrivingDropoff

    /// Pure decision, unit-testable without mounting the view.
    ///  • `.arrived` → `arrivedAwaitingStart` (the Start CTA state);
    ///  • `.enroute`/`.completed` → `arrivingDropoff` when the wire ETA says so, else `inRide`;
    ///  • otherwise (`.accepted` live leg 1, or the sim progress ticker) → progress-derived:
    ///    before `pickupCut` → `toPickup`; past it → `arrivingDropoff` (ETA≤2) or `inRide`.
    static func stage(status: RideRequestStatus?, atPickupByProgress: Bool, arriving: Bool) -> RiderTrackingStage {
        switch status {
        case .arrived:
            return .arrivedAwaitingStart
        case .enroute, .completed:
            return arriving ? .arrivingDropoff : .inRide
        default:
            if atPickupByProgress { return arriving ? .arrivingDropoff : .inRide }
            return .toPickup
        }
    }
}

/// Applies the ride-request sheet chrome UNLESS the content is hosted inside the
/// `PanSheet` engine (MYR-271), where the engine surface provides the wash.
private struct TrackingChrome: ViewModifier {
    let hosted: Bool
    func body(content: Content) -> some View {
        if hosted {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.rideRequestSheetChrome()
        }
    }
}

/// A plain vertical line filling its proposed rect — stroked dashed by
/// `RideRequestTrackingContent.connector` for the pre-pickup itinerary segment.
private struct RideConnectorDash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
