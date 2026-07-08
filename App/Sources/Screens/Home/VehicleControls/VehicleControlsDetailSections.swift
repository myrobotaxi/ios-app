import SwiftUI
import DesignSystem

// MARK: - Status & location (vehicle-controls.jsx:385-396, parked only)
//
// While driving, live speed/heading/range already live at the top of the
// sheet (screens.jsx comment, vehicle-controls.jsx:383-384), so this section
// only renders when parked. The jsx hardcodes "Embarcadero Ctr" / "1h 42m"
// literals distinct from `ParkedSheetContent`'s own peek-row strings
// (screens.jsx:561-562 "Embarcadero Center · Lot B" + a computed duration) —
// two sources of truth for the same fact in the same screen. This port
// reuses the one real `ParkedLocation` fixture (already computed for the
// peek row, HomeSheetContent.swift `parkedDuration`) for both, instead of
// duplicating a shorter, driftable literal.

struct StatusLocationSection: View {
    let location: ParkedLocation
    let rangeMi: Int

    private var parkedDuration: String {
        let seconds = max(0, Date().timeIntervalSince(location.parkedSince))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var body: some View {
        SectionCard(title: "Status & location", trailing: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.mrtParked)
                    .frame(width: 7, height: 7)
                    .shadow(color: .mrtParked.opacity(2.0 / 3.0), radius: 3.5)
                Text("Parked")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mrtParked)
            }
        }) {
            VStack(spacing: 0) {
                KV(label: "Location", value: location.label)
                KV(label: "Parked", value: parkedDuration)
                KV(label: "Range", value: "\(rangeMi) mi")
            }
        }
    }
}

// MARK: - Tire pressure (vehicle-controls.jsx:398-409)

struct TirePressureSection: View {
    private struct Tire: Identifiable {
        let position: String
        let psi: Int
        var id: String { position }
    }

    /// vehicle-controls.jsx:231 `tires`.
    private let tires: [Tire] = [
        Tire(position: "FL", psi: 42),
        Tire(position: "FR", psi: 42),
        Tire(position: "RL", psi: 41),
        Tire(position: "RR", psi: 43),
    ]

    var body: some View {
        SectionCard(title: "Tire pressure", trailing: {
            Text("All nominal")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.mrtDriving)
        }) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(tires) { tire in
                    HStack(spacing: 10) {
                        if tire.position.hasSuffix("L") {
                            Text(tire.position)
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(Color.mrtTextMuted)
                        }
                        (Text("\(tire.psi)")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.mrtText)
                            + Text(" psi")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.mrtTextMuted))
                            .tracking(-0.3)
                            .monospacedDigit()
                        if tire.position.hasSuffix("R") {
                            Text(tire.position)
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(Color.mrtTextMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: tire.position.hasSuffix("L") ? .leading : .trailing)
                }
            }
        }
    }
}

// MARK: - Lifetime (vehicle-controls.jsx:412-416)

struct LifetimeSection: View {
    var body: some View {
        SectionCard(title: "Lifetime") {
            VStack(spacing: 0) {
                KV(label: "Odometer", value: "42,184 mi")
                KV(label: "Total FSD miles", value: "31,907 mi", gold: true)
                KV(label: "Driven autonomously", value: "76%")
            }
        }
    }
}

// MARK: - Vehicle details (vehicle-controls.jsx:419-425)

struct VehicleDetailsSection: View {
    let vehicle: Vehicle
    let plate: String
    let onEditPlate: () -> Void

    var body: some View {
        SectionCard(title: "Vehicle details") {
            VStack(spacing: 0) {
                KV(label: "Model", value: vehicle.model)
                KV(label: "Color", value: vehicle.colorName)
                PlateRow(value: plate, onEdit: onEditPlate)
                // vehicle-controls.jsx:423-424 — hardcoded regardless of
                // vehicle, matching the jsx's own fixture choice.
                KV(label: "VIN", value: "7SAYGDEE9PA142184")
                KV(label: "Software", value: "2026.14.3")
            }
        }
    }
}

/// Editable license plate — Tesla's data doesn't include the plate, so the
/// owner sets it manually (vehicle-controls.jsx:124-125). Tapping opens
/// `PlateEditSheet` via `HomeScreen`'s `.mrtConfigSheet`.
private struct PlateRow: View {
    let value: String
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Text("Plate")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextSec)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(value.isEmpty ? "Add plate" : value)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.6)
                        .monospacedDigit()
                        .foregroundStyle(value.isEmpty ? Color.mrtTextMuted : .mrtText)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtGold)
                        .frame(width: 24, height: 24)
                        .background(Color.mrtStepButtonFill, in: Circle())
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plate edit sheet (vehicle-controls.jsx:146-197 `PlateEditModal`)
//
// The jsx portals a custom bottom sheet out of the controls scroll view.
// This port presents through the existing `mrtConfigSheet` modifier
// (BottomSheet.swift, Handoff §7 "vehicle detail" bottom-sheet pattern)
// applied at `HomeScreen`'s root instead of a bespoke portal — SwiftUI has
// no portal primitive, and `mrtConfigSheet` already reproduces the same
// chrome (grab handle, slide-up, scrim). It's the "no close ✕" variant: the
// jsx has no ✕, only backdrop-tap and an explicit Cancel button.
struct PlateEditSheet: View {
    let initialPlate: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(initialPlate: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.initialPlate = initialPlate
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: initialPlate)
    }

    private var cleaned: String { text.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { cleaned.count >= 2 }
    private var isChanged: Bool { cleaned != initialPlate.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { isValid && isChanged }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit license plate")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 6)
            Text("Your Tesla doesn't report its plate, so enter it manually. It appears on shared rides so passengers can spot the car.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 20)
            Text("PLATE NUMBER")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 9)
            TextField("e.g. RBO-2046", text: $text)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.system(size: 21, weight: .semibold))
                .tracking(3)
                .foregroundStyle(Color.mrtText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: text) { _, newValue in
                    let filtered = newValue.uppercased().filter {
                        $0.isLetter || $0.isNumber || $0 == " " || $0 == "-"
                    }
                    text = String(filtered.prefix(8))
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
                .background(Color.mrtControlSegmentTrack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            cleaned.isEmpty || isValid ? Color.mrtBorder : Color.mrtDialogRed.opacity(0.4),
                            lineWidth: 1
                        )
                )
            HStack {
                Text(cleaned.isEmpty || isValid ? "Letters, numbers, spaces or dashes" : "Enter at least 2 characters")
                    .foregroundStyle(cleaned.isEmpty || isValid ? Color.mrtTextMuted : Color.mrtDialogRed)
                Spacer()
                Text("\(cleaned.count)/8")
                    .foregroundStyle(Color.mrtTextMuted)
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .padding(.top, 9)
            .padding(.horizontal, 2)

            VStack(spacing: 9) {
                MRTButton("Save plate", variant: .gold) {
                    if canSave { onSave(cleaned) }
                }
                .opacity(canSave ? 1 : 0.4)
                .allowsHitTesting(canSave)
                MRTButton("Cancel", variant: .ghost, action: onCancel)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .task {
            // vehicle-controls.jsx:151 `setTimeout(..., 80)` — focus + select
            // shortly after the sheet is mounted.
            try? await Task.sleep(nanoseconds: 80_000_000)
            focused = true
        }
    }
}
