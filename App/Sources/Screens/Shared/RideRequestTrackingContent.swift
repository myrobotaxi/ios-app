import SwiftUI
import DesignSystem

// MARK: - RideRequestTrackingContent (MYR-171, design/app/ride-request.jsx
// TrackingContent 746-905)
//
// Two legs (pickup then drop-off), split at `RideRequestRecord.pickupCut`.
// `SharedViewerScreen` transitions the phase to `.summary` once
// `trackProgress >= 0.999` (see `RiderSheetPhase`'s doc comment on why
// tracking/summary are split into two cases here vs. the jsx's single
// 'tracking' phase) — this view only ever renders the two live legs.
struct RideRequestTrackingContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: SimulatedRideRequestService
    var totalHeight: CGFloat?

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    private var fleetMember: FleetMember { request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var passenger: RidePassenger? { request?.input.passenger }
    private var destination: RidePlace { request?.input.destination ?? RideRequestFixtures.recentPlaces[0] }
    private var pickupLabel: String { request?.input.pickup.label ?? "Current location" }

    private var progress: Double { request?.trackProgress ?? 0 }
    private var pickupCut: Double { request?.pickupCut ?? 0.2 }
    private var atPickup: Bool { progress >= pickupCut }

    private var pickupLegMinutes: Double { RideRequestTiming.pickupLegMinutes }
    private var tripMinutes: Int { destination.minutes }
    private var totalMinutes: Double { pickupLegMinutes + Double(tripMinutes) }

    private var remainMinutes: Int { max(0, Int(((1 - progress) * totalMinutes).rounded())) }
    private var toPickupMinutes: Int {
        max(0, Int(((pickupCut - progress) / pickupCut * pickupLegMinutes).rounded()))
    }

    /// ride-request.jsx:565 `pickupMilesTotal = 2.2` — a hardcoded reference
    /// distance for the pickup leg (the jsx has no real geocoded distance
    /// for the pickup point either, ported verbatim rather than invented).
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

    private var arrivingPickup: Bool { !atPickup && toPickupMinutes <= 1 }
    private var arrivingDropoff: Bool { atPickup && remainMinutes <= 2 }

    private var statusWord: String {
        if !atPickup { return arrivingPickup ? "Your ride is arriving" : "Heading your way" }
        return arrivingDropoff ? "Arriving at drop-off" : "Heading to \(destination.label)"
    }

    var body: some View {
        // MYR-171 fix: no `ScrollView` — see `RideRequestPinDropContent`'s
        // identical fix comment (this phase also sizes to content, and the
        // bottom nav is hidden during tracking so there's no floating chrome
        // to clear either).
        VStack(alignment: .leading, spacing: 0) {
            if arrivingDropoff {
                arrivalHeader
            } else {
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
        .rideRequestSheetChrome()
    }

    // MARK: Live header (ride-request.jsx:820-838)

    private var liveHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(Color.mrtGold).frame(width: 6, height: 6).shadow(color: .mrtGoldGlow, radius: 4)
                    RideEyebrowText(text: statusWord, color: .mrtGold, size: 11)
                }
                HStack(spacing: 4) {
                    Text(atPickup ? "Dropping you off at" : "Picking you up at")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.mrtTextSec)
                    Text(atPickup ? destination.label : pickupLabel)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.mrtText)
                }
                .lineLimit(1)
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
        HStack(alignment: .top, spacing: 13) {
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
                    Rectangle().fill(atPickup ? Color.mrtGold : Color.mrtBorder).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    RideEyebrowText(text: isDropoff ? "Drop-off" : "Pickup", color: .mrtGold, size: 10)
                    Spacer(minLength: 8)
                    Text(clock).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Color.mrtTextSec)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(place).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(note).font(.system(size: 12)).foregroundStyle(Color.mrtTextMuted).lineLimit(1)
                }
            }
            .padding(.bottom, last ? 0 : 16)
        }
    }

    // MARK: Ride row — "Look for" (spotting, pickup leg) vs "Your ride"
    // (quiet reference, in-ride leg) — ride-request.jsx:683-695 `RideRow`.

    private func rideRow(emphasize: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                RideEyebrowText(text: emphasize ? "Look for" : "Your ride", color: emphasize ? .mrtGold : Color.mrtGold.opacity(0.6), size: 9.5)
                Text("\(fleetMember.model) \(fleetMember.name)")
                    .font(.system(size: emphasize ? 17 : 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                if let passenger, !passenger.name.isEmpty {
                    Text("for \(passenger.name)").font(.system(size: 12.5)).foregroundStyle(Color.mrtTextSec)
                }
            }
            Spacer(minLength: 0)
            if emphasize {
                emphasizedPlateChip
            } else {
                RidePlateChip(plate: fleetMember.plate)
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

    /// Big bright plate for the "spotting the car" pickup leg — the jsx
    /// additionally sweeps a shine gradient across the plate's own
    /// background (`mrt-plate-shine`); simplified here to a static bright
    /// gold chip (no new background-shimmer primitive for one plate) — see
    /// PR deviations note.
    private var emphasizedPlateChip: some View {
        Text(fleetMember.plate)
            .font(.system(size: 18, weight: .bold))
            .monospacedDigit()
            .tracking(1.5)
            .foregroundStyle(Color.mrtGoldButtonLabel)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.mrtGold, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .mrtGoldGlow, radius: 10)
    }

    // MARK: Arrival takeover (ride-request.jsx:756-774, remainMins <= 2)

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
