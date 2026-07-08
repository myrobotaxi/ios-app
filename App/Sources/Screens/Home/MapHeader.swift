import SwiftUI
import DesignSystem

// MARK: - MapHeader — the vehicle switcher (MYR-167, Handoff §6,
// design/app/screens.jsx:297-351)
//
// Top-center capsule chip (car icon + vehicle name + chevron, ≥44pt tall via
// its hit target) → tap opens a custom popover listing every vehicle (icon,
// name, plate, checkmark on the active one). Handoff §6 explicitly allows
// "Menu or a custom popover" and flags avoiding a gesture conflict with
// `MKMapView`'s pan; a native SwiftUI `Menu` renders system materials it
// can't be reskinned away from (the jsx picker is a specific dark translucent
// card with plate subtitles), so this is a custom popover — a Boolean
// `isOpen` toggle plus a screen-covering tap-catcher behind it, exactly
// mirroring the jsx's own `onClick={() => setOpen(false)}` full-screen layer
// (screens.jsx:322). Collapses to a plain (non-interactive) label when only
// one vehicle exists (screens.jsx:300,304,312 `single`).
struct MapHeader: View {
    let vehicles: [Vehicle]
    @Binding var selectedIndex: Int
    @State private var isOpen = false

    private var single: Bool { vehicles.count <= 1 }
    private var selected: Vehicle { vehicles[selectedIndex] }

    var body: some View {
        VStack(spacing: 0) {
            chip
            if isOpen, !single {
                picker
                    .padding(.top, 8) // screens.jsx:323 marginTop: 8
            }
        }
        .padding(.top, MRTMetrics.mapHeaderTop)
        // screens.jsx:302 `position: absolute, top: 60` — pin to the
        // screen's top edge, not just center horizontally within the
        // ZStack's intrinsic-height slot (that left it floating mid-screen,
        // review finding #2).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Full-screen tap-catcher behind the picker, above the map — closes
        // on outside tap (screens.jsx:322).
        .background {
            if isOpen, !single {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { isOpen = false }
            }
        }
    }

    private var chip: some View {
        Button {
            guard !single else { return }
            withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "car.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.mrtGold)
                Text(selected.name)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                if !single {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mrtTextSec)
                        .frame(width: 24, height: 24)
                        .background(Color.mrtMapChipChevronFill, in: Circle())
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .animation(.easeInOut(duration: 0.25), value: isOpen)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, single ? 14 : 8)
            .frame(height: MRTMetrics.mapChipHeight)
            // ≥44pt tap target even though the visual chip is 40pt tall
            // (screens.jsx:306 `height: 40`; Handoff hard rule "Min tap
            // target 44pt").
            .contentShape(Rectangle().inset(by: -2))
            .background(Color.mrtMapChipFill, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isOpen ? Color.mrtMapChipBorderActive : Color.mrtMapChipBorder,
                    lineWidth: MRTMetrics.hairline
                )
            )
            // 0 6px 20px rgba(0,0,0,0.4)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
        .accessibilityLabel(single ? "Vehicle: \(selected.name)" : "Vehicle: \(selected.name). Double-tap to switch vehicles.")
        .accessibilityAddTraits(single ? [] : .isButton)
    }

    private var picker: some View {
        VStack(spacing: 0) {
            ForEach(Array(vehicles.enumerated()), id: \.element.id) { index, vehicle in
                pickerRow(vehicle, index: index)
                if index != vehicles.count - 1 {
                    Divider().overlay(Color.mrtMapPickerDivider)
                }
            }
        }
        .frame(width: MRTMetrics.mapPickerWidth)
        .background(Color.mrtMapPickerFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline)
        )
        // 0 16px 44px rgba(0,0,0,0.55)
        .shadow(color: .black.opacity(0.55), radius: 22, y: 16)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func pickerRow(_ vehicle: Vehicle, index: Int) -> some View {
        let active = index == selectedIndex
        return Button {
            selectedIndex = index
            withAnimation(.easeOut(duration: 0.18)) { isOpen = false }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(active ? Color.mrtGold : Color.mrtTextSec)
                    .frame(width: 34, height: 34)
                    .background(
                        active ? Color.mrtMapPickerIconActive : Color.mrtMapPickerIconInactive,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(vehicle.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text(vehicle.plate)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.mrtGold)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(minHeight: MRTMetrics.minTapTarget)
            .background(active ? Color.mrtMapPickerRowActive : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityLabel("\(vehicle.name), \(vehicle.plate)")
    }
}
