import SwiftUI
import DesignSystem

// MARK: - VehicleControls (MYR-168, design/app/vehicle-controls.jsx)
//
// The full tile stack revealed when the home sheet drags to half (Handoff
// §5.5): quick lock/climate/trunk/charge tiles, Climate, Media, Status &
// location (parked only), Tire pressure, Lifetime, and Vehicle details.
// M1 renders faithfully against `SimulatedVehicleCommandExecutor` — no
// network (CLAUDE.md "M1 is simulated"); P11 (MYR-180-183) swaps the
// executor, not this view (see VehicleCommandExecutor.swift header).
struct VehicleControls: View {
    let vehicle: Vehicle
    let driving: Bool
    let batteryPercent: Double
    let parkedLocation: ParkedLocation?
    let executor: any VehicleCommandExecutor
    @Binding var isEditingPlate: Bool

    private var controls: VehicleControlsSnapshot { executor.controls }

    /// vehicle-controls.jsx:229-230 — hardcoded regardless of vehicle; there
    /// is no interior/exterior temp field on `VehicleTelemetrySnapshot`
    /// (M1 fixture data, see `VehicleTelemetry.swift`).
    private let cabinTemp = 66
    private let extTemp = 58

    private var rangeMi: Int { Int(((batteryPercent / 100) * 272).rounded()) } // vehicle-controls.jsx:228

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MRTDivider(pad: 6) // vehicle-controls.jsx:241 `<Divider pad={6}/>`

            quickTiles

            ClimateSection(
                controls: controls,
                seatVent: vehicle.seatVent,
                executor: executor,
                cabinTemp: cabinTemp,
                extTemp: extTemp
            )

            MediaSection(
                controls: controls,
                executor: executor,
                track: VehicleMediaTrack.all[controls.trackIndex]
            )

            // vehicle-controls.jsx:385 `{!driving && …}` — while driving, live
            // speed/heading/range already live at the top of the sheet.
            if !driving, let parkedLocation {
                StatusLocationSection(location: parkedLocation, rangeMi: rangeMi)
            }

            TirePressureSection()

            LifetimeSection()

            VehicleDetailsSection(vehicle: vehicle, plate: controls.plate) {
                isEditingPlate = true
            }

            Text("Updated just now · Live")
                .font(.system(size: 10))
                .tracking(0.3)
                .foregroundStyle(Color.mrtTextMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }

    // MARK: Quick tiles (vehicle-controls.jsx:244-254)

    private var quickTiles: some View {
        // Charge PORT has no §7.9 command (MYR-249): on the live path the executor
        // reports it unsupported, so the tile is honestly disabled rather than
        // faking a toggle. On the simulated path everything is supported → the
        // M1 / drift-gate scenes render identically.
        let chargePortSupported = executor.isSupported(.chargePort)
        return HStack(spacing: 8) {
            ControlTile(
                icon: controls.locked ? "lock.fill" : "lock.open.fill",
                label: controls.locked ? "Locked" : "Unlocked",
                sub: controls.locked ? "Tap to unlock" : "Tap to lock",
                active: !controls.locked,
                activeColor: .mrtDriving,
                uiState: executor.uiState(for: .lock)
            ) {
                Task { try? await executor.setLocked(!controls.locked) }
            }
            ControlTile(
                icon: "fan",
                label: "Climate",
                sub: controls.climateOn ? "On · \(controls.targetTemp)°" : "Off",
                active: controls.climateOn,
                activeColor: .mrtGold,
                uiState: executor.uiState(for: .climate)
            ) {
                Task { try? await executor.setClimateOn(!controls.climateOn) }
            }
            ControlTile(
                icon: "car.fill",
                label: "Trunk",
                sub: controls.trunkOpen ? "Open" : "Closed",
                active: controls.trunkOpen,
                activeColor: .mrtParked,
                uiState: executor.uiState(for: .trunk)
            ) {
                Task { try? await executor.setTrunkOpen(!controls.trunkOpen) }
            }
            ControlTile(
                icon: "bolt.fill",
                label: "Charge",
                sub: chargePortSupported ? (controls.chargePortOpen ? "Port open" : "Port closed") : "Not available yet",
                active: chargePortSupported && controls.chargePortOpen,
                activeColor: .mrtCharging,
                enabled: chargePortSupported
            ) {
                Task { try? await executor.setChargePortOpen(!controls.chargePortOpen) }
            }
        }
    }
}

// MARK: - ControlTile (vehicle-controls.jsx:24-41)

private struct ControlTile: View {
    let icon: String
    let label: String
    let sub: String
    let active: Bool
    let activeColor: Color
    /// Live command state (MYR-249). `.idle` on the simulated path, so the M1 /
    /// drift-gate rendering is pixel-identical.
    var uiState: VehicleControlUIState = .idle
    /// `false` when the control has no backend command on the live executor
    /// (charge port) — the tile dims + stops responding rather than faking it.
    var enabled: Bool = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `${activeColor}1f` — 0x1F / 255 alpha tint (vehicle-controls.jsx:30).
    private var activeFill: Color { activeColor.opacity(Double(0x1F) / 255) }
    /// `${activeColor}66` — 0x66 / 255 alpha border (vehicle-controls.jsx:29).
    private var activeBorder: Color { activeColor.opacity(Double(0x66) / 255) }

    /// The sub line: a settled notice (pairing / re-link / waking / …) takes
    /// precedence over the resting copy so an error is surfaced honestly in place.
    private var subLine: String { uiState.notice?.message ?? sub }
    private var subColor: Color { uiState.notice != nil ? .mrtTextSec : (active ? activeColor : .mrtTextMuted) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Pending → a spinner in the icon slot (Reduce Motion falls back
                // to the static icon dimmed, no spin, per CLAUDE.md). The idle
                // path renders the bare `Image` exactly as before, so the M1 /
                // drift-gate scenes are pixel-identical.
                if uiState.isPending, !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                        .tint(active ? activeColor : .mrtTextSec)
                        .frame(width: 20, height: 20, alignment: .leading)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(active ? activeColor : .mrtTextSec)
                        .opacity(uiState.isPending ? 0.5 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // jsx sets `whiteSpace:nowrap / overflow:hidden /
                        // textOverflow:ellipsis` (vehicle-controls.jsx:36-37)
                        // — ellipsis is the designed fallback, but native SF
                        // Pro renders a few of these strings slightly wider
                        // than the browser's font substitution at the same
                        // nominal size, so scale down slightly before
                        // truncating rather than clipping mid-word.
                        .minimumScaleFactor(0.85)
                    Text(subLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(subColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.top, 13)
            .padding(.bottom, 12)
            .background(
                active ? activeFill : Color.mrtControlTileFill,
                in: RoundedRectangle(cornerRadius: MRTMetrics.vehicleControlTileRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.vehicleControlTileRadius, style: .continuous)
                    .strokeBorder(active ? activeBorder : Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - SectionCard (vehicle-controls.jsx:43-54)

struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        self.title = title
        trailing = EmptyView()
        self.content = content()
    }

    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).mrtTextStyle(.label()).foregroundStyle(Color.mrtTextMuted)
                Spacer()
                trailing
            }
            .padding(.bottom, 10)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .mrtSurface(.card, fill: .mrtElevated, radius: MRTMetrics.vehicleControlsSectionRadius)
        }
        .padding(.top, MRTMetrics.vehicleControlsSectionGap)
    }
}
