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

    /// Real cabin/ambient temps from the telemetry snapshot (MYR-251). Live: the
    /// wire `interiorTemp`/`exteriorTemp`; simulated: the fixture 66/58 (so M1 is
    /// pixel-identical); `nil` = unknown (no snapshot yet) → renders "—".
    let cabinTemp: Int?
    let extTemp: Int?

    private var controls: VehicleControlsSnapshot { executor.controls }

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
    //
    // MYR-251 — each tile's STATE (locked/on/open) is only asserted when the
    // executor confirms it (`isKnown`); on the live path it is unknown until the
    // owner commands the tile, so it renders a neutral icon + "—" instead of a
    // fixture value (MYR-228). When unknown the tap performs the SAFE default
    // (lock / start climate / open) rather than toggling an unknown seed.

    /// The em-dash the design uses for an unavailable value.
    private static let dash = "\u{2014}"

    private var quickTiles: some View {
        HStack(spacing: 8) {
            lockTile
            climateTile
            trunkTile
            chargeTile
        }
    }

    private var lockTile: some View {
        let known = executor.isKnown(.locked)
        return ControlTile(
            icon: known ? (controls.locked ? "lock.fill" : "lock.open.fill") : "lock",
            label: known ? (controls.locked ? "Locked" : "Unlocked") : "Lock",
            sub: known ? (controls.locked ? "Tap to unlock" : "Tap to lock") : Self.dash,
            active: known && !controls.locked,
            activeColor: .mrtDriving,
            uiState: executor.uiState(for: .lock)
        ) {
            // Unknown → lock (the safe default); known → toggle.
            let target = known ? !controls.locked : true
            Task { try? await executor.setLocked(target) }
        }
    }

    private var climateTile: some View {
        let known = executor.isKnown(.climateOn)
        let tempKnown = executor.isKnown(.targetTemp)
        let onSub = tempKnown ? "On · \(controls.targetTemp)°" : "On"
        return ControlTile(
            icon: "fan",
            label: "Climate",
            sub: known ? (controls.climateOn ? onSub : "Off") : Self.dash,
            active: known && controls.climateOn,
            activeColor: .mrtGold,
            uiState: executor.uiState(for: .climate)
        ) {
            let target = known ? !controls.climateOn : true
            Task { try? await executor.setClimateOn(target) }
        }
    }

    private var trunkTile: some View {
        let known = executor.isKnown(.trunkOpen)
        return ControlTile(
            icon: "car.fill",
            label: "Trunk",
            sub: known ? (controls.trunkOpen ? "Open" : "Closed") : Self.dash,
            active: known && controls.trunkOpen,
            activeColor: .mrtParked,
            uiState: executor.uiState(for: .trunk)
        ) {
            let target = known ? !controls.trunkOpen : true
            Task { try? await executor.setTrunkOpen(target) }
        }
    }

    // Charge port joined the §7.9 catalog in v186 (charge_port_door_open /
    // close, MYR-249) — the tile toggles the port per its state and shows the
    // pending/notice UX (a token lacking the charging scope surfaces the
    // charging-specific re-link line). Its OPEN/CLOSED state is not on the wire,
    // so it too renders unknown until commanded (MYR-251).
    private var chargeTile: some View {
        let known = executor.isKnown(.chargePortOpen)
        return ControlTile(
            icon: "bolt.fill",
            label: "Charge",
            sub: known ? (controls.chargePortOpen ? "Port open" : "Port closed") : Self.dash,
            active: known && controls.chargePortOpen,
            activeColor: .mrtCharging,
            uiState: executor.uiState(for: .chargePort)
        ) {
            let target = known ? !controls.chargePortOpen : true
            Task { try? await executor.setChargePortOpen(target) }
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
