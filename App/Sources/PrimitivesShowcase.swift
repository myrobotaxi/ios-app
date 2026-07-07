import DesignSystem
import SwiftUI

/// Dev gallery for the MYR-163 primitives (not part of any shipping flow).
/// Pages are switchable in-app; `-showcasePage N` (launch argument) selects
/// the initial page so CI/agents can screenshot each page headlessly.
struct PrimitivesShowcase: View {
    @State private var page: Int
    @State private var ownerTab = "home"
    @State private var sharedTab = "shared"
    @State private var progress = 0.42
    @State private var navHidden = false

    init() {
        _page = State(initialValue: UserDefaults.standard.integer(forKey: "showcasePage"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                Text("Brand").tag(0)
                Text("Data").tag(1)
                Text("Map + Nav").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch page {
                    case 1: dataPage
                    case 2: mapNavPage
                    default: brandPage
                    }
                }
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
    }

    // MARK: Page 0 — brand + status + battery

    @ViewBuilder private var brandPage: some View {
        section("HexLogo — 32 / 48 / 64 + glow") {
            HStack(spacing: 20) {
                HexLogo(size: 32)
                HexLogo(size: 48)
                HexLogo(size: 64)
                HexLogo(size: 64, glow: true)
            }
        }
        section("ArrowMark — plain / glow") {
            HStack(spacing: 20) {
                ArrowMark(size: 32)
                ArrowMark(size: 48, glow: true)
            }
        }
        section("Wordmark") {
            VStack(alignment: .leading, spacing: 14) {
                Wordmark(size: 18)
                Wordmark(size: 22, withLogo: true)
            }
        }
        section("StatusBadge — all states") {
            HStack(spacing: 18) {
                ForEach(MRTVehicleStatus.allCases) { StatusBadge($0) }
            }
        }
        section("PulseDot") {
            HStack(spacing: 18) {
                PulseDot()
                PulseDot(color: .mrtGold, size: 10)
                PulseDot(color: .mrtParked, size: 8)
            }
            .frame(height: 30)
        }
        section("BatteryBar — 85 / 45 / 12 / charging") {
            VStack(spacing: 14) {
                BatteryBar(pct: 85, showLabel: true)
                BatteryBar(pct: 45, showLabel: true)
                BatteryBar(pct: 12, showLabel: true)
                BatteryBar(pct: 64, showLabel: true, charging: true)
                BatteryBar(pct: 1)
            }
        }
        section("MiniBattery — 90 / 15 / 8 / charging") {
            HStack(spacing: 16) {
                MiniBattery(pct: 90)
                MiniBattery(pct: 15)
                MiniBattery(pct: 8)
                MiniBattery(pct: 50, charging: true)
            }
        }
    }

    // MARK: Page 1 — trip progress + stats + kv + avatars

    @ViewBuilder private var dataPage: some View {
        section("TripProgressBar — tap to randomize") {
            VStack(spacing: 20) {
                TripProgressBar(progress: progress, origin: "Home", dest: "Bayview Elementary")
                TripProgressBar(progress: 0.15)
                TripProgressBar(progress: 0.8)
                TripProgressBar(progress: 0.42, compact: true)
            }
            .contentShape(Rectangle())
            .onTapGesture { progress = Double.random(in: 0...1) }
        }
        section("StatRow / StatCol") {
            StatRow {
                StatCol(label: "Battery", value: "82", unit: "%")
                StatCol(label: "Range", value: "247", unit: "mi", accent: true)
                StatCol(label: "Temp", value: "68", unit: "°F")
            }
        }
        section("KV + MRTDivider") {
            VStack(spacing: 0) {
                KV(label: "Plate", value: "7XKJ482")
                KV(label: "Battery", value: "82%", gold: true)
                MRTDivider()
                KV(label: "Firmware", value: "2026.20.3")
            }
        }
        section("Avatar — hash-stable hues, online dot") {
            HStack(spacing: 16) {
                Avatar(name: "Alex Chen", online: true)
                Avatar(name: "Jordan Lee")
                Avatar(name: "Sam Kowalski", size: 44, online: true)
                Avatar(name: "Maya Patel", size: 28)
                Avatar()
            }
        }
    }

    // MARK: Page 2 — vehicle marker + route line + bottom navs

    @ViewBuilder private var mapNavPage: some View {
        section("VehicleMarker — headings 45° / 200°, label chip") {
            ZStack {
                RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat)
                    .fill(Color.mrtBgSecondary)
                HStack(spacing: 90) {
                    VehicleMarker(heading: 45)
                    VehicleMarker(heading: 200, label: "Alex's Model Y")
                }
            }
            .frame(height: 130)
        }
        section("RouteLine — progress 0.55") {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat)
                    .fill(Color.mrtBgSecondary)
                RouteLine(
                    points: [
                        CGPoint(x: 24, y: 116),
                        CGPoint(x: 84, y: 96),
                        CGPoint(x: 122, y: 52),
                        CGPoint(x: 192, y: 64),
                        CGPoint(x: 258, y: 28),
                        CGPoint(x: 318, y: 46),
                    ],
                    progress: 0.55
                )
            }
            .frame(height: 140)
        }
        section("BottomNav — owner tabs (tap to switch, long-press to hide)") {
            BottomNav(selection: $ownerTab, hidden: navHidden)
                .onLongPressGesture { navHidden.toggle() }
        }
        section("BottomNav — shared tabs") {
            BottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            content()
        }
    }
}

#Preview {
    PrimitivesShowcase()
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
