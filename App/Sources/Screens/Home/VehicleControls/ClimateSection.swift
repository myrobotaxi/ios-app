import SwiftUI
import DesignSystem

// MARK: - Climate section (vehicle-controls.jsx:257-345)
//
// On: temp stepper, Auto/Cool/Heat segmented control, Tesla-style fan bar,
// driver/passenger seat heat (+ ventilation toggle when the vehicle supports
// it). Off: idle summary + Interior/Exterior split row (temps stay visible).

struct ClimateSection: View {
    let controls: VehicleControlsSnapshot
    let seatVent: Bool
    let executor: any VehicleCommandExecutor
    let cabinTemp: Int
    let extTemp: Int

    var body: some View {
        SectionCard(title: "Climate") {
            if controls.climateOn {
                onContent
            } else {
                offContent
            }
        }
    }

    // MARK: On (vehicle-controls.jsx:258-308)

    private var onContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                stepButton("−") {
                    Task { try? await executor.setTargetTemp(controls.targetTemp - 1) }
                }
                VStack(spacing: 4) {
                    Text("\(controls.targetTemp)°")
                        .font(.system(size: 40, weight: .light))
                        .tracking(-1)
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtText)
                    Text("SET TEMP")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.mrtTextMuted)
                    Text("Interior \(cabinTemp)° · Outside \(extTemp)°")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextMuted)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                stepButton("+") {
                    Task { try? await executor.setTargetTemp(controls.targetTemp + 1) }
                }
            }
            .padding(.bottom, 16)

            HStack(spacing: 4) {
                modeSeg(.auto, "Auto")
                modeSeg(.cool, "Cool")
                modeSeg(.heat, "Heat")
            }
            .padding(3)
            .background(Color.mrtControlSegmentTrack, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "wind").font(.system(size: 15)).foregroundStyle(Color.mrtTextSec)
                        Text("Fan speed").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.mrtTextSec)
                    }
                    Spacer()
                    (Text("\(controls.fanSpeed) ").foregroundStyle(Color.mrtText)
                        + Text("/ 10").foregroundStyle(Color.mrtTextMuted))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                }
                FanBar(value: controls.fanSpeed) { newValue in
                    Task { try? await executor.setFanSpeed(newValue) }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(seatVent ? "SEAT CLIMATE" : "SEAT HEATING")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.mrtTextMuted)
                        Spacer()
                        if seatVent {
                            Text("Heat & ventilation")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.mrtTextMuted)
                        }
                    }
                    SeatRow(
                        label: "Driver",
                        vent: seatVent,
                        mode: controls.driverSeatMode,
                        level: controls.driverSeatHeatLevel,
                        setMode: { mode in Task { try? await executor.setSeatClimateMode(.driver, mode: mode) } },
                        setLevel: { level in Task { try? await executor.setSeatHeatLevel(.driver, level: level) } }
                    )
                    SeatRow(
                        label: "Passenger",
                        vent: seatVent,
                        mode: controls.passengerSeatMode,
                        level: controls.passengerSeatHeatLevel,
                        setMode: { mode in Task { try? await executor.setSeatClimateMode(.passenger, mode: mode) } },
                        setLevel: { level in Task { try? await executor.setSeatHeatLevel(.passenger, level: level) } }
                    )
                }
                .padding(.top, 14)
            }
            .padding(.top, 16)
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.mrtText)
                .frame(width: 46, height: 46)
                .background(Color.mrtStepButtonFill, in: Circle())
                .overlay(Circle().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
        }
        .buttonStyle(.plain)
    }

    private func modeSeg(_ mode: VehicleClimateMode, _ label: String) -> some View {
        let isActive = controls.climateMode == mode
        return Button {
            Task { try? await executor.setClimateMode(mode) }
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.mrtGoldButtonLabel : .mrtTextSec)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isActive ? Color.mrtGold : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Off (vehicle-controls.jsx:310-343)

    private var offContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "fan")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.mrtTextMuted)
                    .frame(width: 44, height: 44)
                    .background(Color.mrtControlSegmentTrack, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Climate off")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text("Cabin idle · last set to \(controls.targetTemp)°")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                Spacer(minLength: 8)
                Button {
                    Task { try? await executor.setClimateOn(true) }
                } label: {
                    Text("Turn on")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.mrtGoldButtonLabel)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.mrtGold, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }

            HStack(spacing: 0) {
                tempColumn(icon: "car.fill", label: "INTERIOR", value: cabinTemp)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline)
                tempColumn(icon: "sun.max.fill", label: "EXTERIOR", value: extTemp)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
            }
            .padding(.top, 14)
        }
    }

    private func tempColumn(icon: String, label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Color.mrtTextMuted)
                Text(label).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(Color.mrtTextMuted)
            }
            Text("\(value)°")
                .font(.system(size: 26, weight: .light))
                .tracking(-0.6)
                .monospacedDigit()
                .foregroundStyle(Color.mrtText)
        }
    }
}

// MARK: - HeatLevel (vehicle-controls.jsx:56-70)

private struct HeatLevel: View {
    let value: Int
    let color: Color
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...3, id: \.self) { level in
                Button {
                    onChange(value == level ? 0 : level)
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(value >= level ? color : Color.mrtControlSegmentOff)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - SeatRow (vehicle-controls.jsx:77-103)

private struct SeatRow: View {
    let label: String
    let vent: Bool
    let mode: VehicleSeatClimateMode
    let level: Int
    let setMode: (VehicleSeatClimateMode) -> Void
    let setLevel: (Int) -> Void

    private var active: Bool { level > 0 }
    private var accent: Color { mode == .cool ? .mrtSeatCool : .mrtCharging }

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: mode == .cool ? "snowflake" : "sun.max.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(active ? accent : .mrtTextMuted)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // `.fixedSize()` keeps the vent toggle + heat-level squares at
            // their natural width so the left label compresses first if the
            // row is tight — without it, SwiftUI wraps the "Heat"/"Cool"
            // button labels onto multiple lines under compression (seen on
            // the longer "Passenger" row, which leaves less room here than
            // "Driver").
            HStack(spacing: 10) {
                if vent {
                    HStack(spacing: 3) {
                        modeButton(.heat, "Heat", .mrtCharging)
                        modeButton(.cool, "Cool", .mrtSeatCool)
                    }
                    .padding(3)
                    .background(Color.mrtControlSegmentTrack, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                HeatLevel(value: level, color: accent, onChange: setLevel)
            }
            .fixedSize()
        }
        .padding(.top, 13)
    }

    /// Both Heat and Cool pills use the same near-black `#1a1408` label when
    /// active (vehicle-controls.jsx:93) — reusing `mrtGoldButtonLabel` even
    /// though the Cool fill isn't gold; the hex is identical.
    private func modeButton(_ target: VehicleSeatClimateMode, _ label: String, _ color: Color) -> some View {
        let isActive = mode == target
        return Button {
            setMode(target)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.mrtGoldButtonLabel : .mrtTextSec)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isActive ? color : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FanBar (vehicle-controls.jsx:106-122)

private struct FanBar: View {
    let value: Int
    let onChange: (Int) -> Void

    private static let containerHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...10, id: \.self) { level in
                Button {
                    onChange(value == level ? level - 1 : level)
                } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(value >= level ? Color.mrtGold : Color.mrtControlSegmentOff)
                        .frame(maxWidth: .infinity)
                        // `${42 + i*6.4}%` of a 26pt container (vehicle-controls.jsx:114).
                        .frame(height: Self.containerHeight * (0.42 + Double(level - 1) * 0.064))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: Self.containerHeight, alignment: .bottom)
    }
}
