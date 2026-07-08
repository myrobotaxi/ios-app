import SwiftUI
import DesignSystem

// MARK: - RideRequestSummaryContent (MYR-171, design/app/ride-request.jsx
// RideSummaryContent 909-1005)
//
// Takes over the full screen (`RideRequestSheetChrome(isSummary: true)`) —
// "the ride's done, a full page feels like a destination" per the jsx's own
// comment (ride-request.jsx:1119).
struct RideRequestSummaryContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: SimulatedRideRequestService
    var historyStore: RideHistoryStore
    var riderName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tip: String?

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    private var fleetMember: FleetMember { request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var destination: RidePlace { request?.input.destination ?? RideRequestFixtures.recentPlaces[0] }
    private var pickup: RidePlace? { request?.input.pickup }
    private var passenger: RidePassenger? { request?.input.passenger }

    private var partOfDay: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case ..<12: "morning"
        case ..<18: "afternoon"
        default: "evening"
        }
    }

    private var firstName: String {
        let name = riderName.isEmpty ? (passenger?.name ?? "Sam") : riderName
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private var tripMinutes: Int { destination.minutes }
    private var tripMiles: Double { destination.miles }

    private var endedClock: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: Date())
    }

    private static let tipQuips: [String: String] = [
        "$3": "Your robotaxi beeped happily, then remembered it runs on electrons, not gratitude.",
        "$5": "The steering wheel would thank you \u{2014} if it had one.",
        "$8": "$8?! It\u{2019}s blushing in binary: 01110100 01111000.",
        "Custom": "There\u{2019}s no driver back there. Just vibes and 4,000 TOPS of compute.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RideEyebrowText(text: "Arrived \u{00B7} \(endedClock)", color: Color.mrtGold.opacity(0.6), size: 10)
                    .padding(.bottom, 12)

                Text("Have a wonderful \(partOfDay),\n\(firstName).")
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.5)
                    .lineSpacing(4)
                    .mrtTextShimmer(duration: 3.6)
                    .padding(.bottom, 24)

                mapCard
                    .padding(.bottom, 20)

                statsStrip
                    .padding(.bottom, 18)

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        RideEyebrowText(text: "You rode in", size: 9.5)
                        Text("\(fleetMember.model) \(fleetMember.name)")
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Color.mrtText)
                    }
                    Spacer(minLength: 0)
                    RidePlateChip(plate: fleetMember.plate)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.mrtGold.opacity(Double(0x1F) / 255.0)).frame(height: MRTMetrics.hairline)
                }
                .padding(.bottom, 22)

                tipSection
                    .padding(.bottom, 22)

                MRTButton("See you soon", variant: .outlineDraw, action: finish)
            }
            .padding(.horizontal, 22)
            .padding(.top, 76)
            .padding(.bottom, 30)
        }
        .rideRequestSheetChrome(isSummary: true)
        .overlay {
            if let tip {
                tipSlideUpCard(tip)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), value: tip)
    }

    // MARK: Map card (ride-request.jsx:950-963)

    private var mapCard: some View {
        ZStack(alignment: .bottomLeading) {
            RideRequestRouteMap(
                route: [pickup?.coordinate ?? DriveFixtures.financialDistrict, destination.coordinate],
                progress: 1
            )
            LinearGradient(
                stops: [.init(color: .clear, location: 0.32), .init(color: Color.mrtBg.opacity(0.94), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 4) {
                RideEyebrowText(text: "You arrived at", color: Color.mrtGold.opacity(0.67), size: 9.5)
                Text(destination.label)
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtGold)
                    .lineLimit(1)
                Text("from \(pickup?.label ?? "Current location")")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtText.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous)
                .strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
        )
    }

    // MARK: Stats strip (ride-request.jsx:966-978)

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statTile(value: "\(tripMinutes)", unit: "min", label: "Trip", gold: false)
            divider
            statTile(value: String(format: "%.1f", tripMiles), unit: "mi", label: "FSD miles", gold: true)
            divider
            statTile(value: "100", unit: "%", label: "Autonomous", gold: false)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.mrtGold.opacity(Double(0x24) / 255.0)).frame(width: 1, height: 30).padding(.horizontal, 18)
    }

    private func statTile(value: String, unit: String, label: String, gold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 21, weight: .bold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(gold ? Color.mrtGold : Color.mrtText)
                Text(unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(gold ? Color.mrtGold.opacity(0.67) : Color.mrtTextMuted)
            }
            RideEyebrowText(text: label, size: 9.5)
        }
    }

    // MARK: Tip (ride-request.jsx:981-1004)

    private var tipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RideEyebrowText(text: "Tip your driver", size: 10)
            HStack(spacing: 8) {
                ForEach(["$3", "$5", "$8", "Custom"], id: \.self) { amount in
                    let on = tip == amount
                    Button { tip = amount } label: {
                        Text(amount)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(on ? Color.mrtGold : Color.mrtText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(on ? Color.mrtGoldTileFaint : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.mrtGold.opacity(on ? Double(0x88) / 255.0 : Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: MRTMetrics.minTapTarget)
                }
            }
        }
    }

    private func tipSlideUpCard(_ amount: String) -> some View {
        RideSlideUpCard(onDismiss: { tip = nil }) {
            VStack(spacing: 0) {
                Circle()
                    .fill(RadialGradient(colors: [Color.mrtGold, Color.mrtRiderAvatarGradientEnd], center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 23))
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "face.smiling").font(.system(size: 22)).foregroundStyle(Color.mrtGoldButtonLabel))
                    .shadow(color: .mrtGoldGlow, radius: 14)
                    .padding(.bottom, 16)
                Text("Haha, no need!")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtGold)
                    .padding(.bottom, 8)
                Text(Self.tipQuips[amount] ?? "")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 280)
                    .padding(.bottom, 22)
                MRTButton("Of course", variant: .outlineDraw) { tip = nil }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Finish (ride-request.jsx:1000 `onDone` → `closeToIdle`)

    private func finish() {
        if let ride = rideRequestService.completeAndReset() {
            historyStore.record(ride)
        }
        viewerState.resetDraftToIdle()
    }
}
