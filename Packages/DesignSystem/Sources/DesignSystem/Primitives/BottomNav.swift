import SwiftUI

// MARK: - BottomNav (components.jsx) — floating capsule tab bar

/// One tab — exact SF Symbol names from the jsx tab tables.
public struct MRTTab: Identifiable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let icon: String
    public let activeIcon: String

    public var id: String { key }

    public init(key: String, label: String, icon: String, activeIcon: String) {
        self.key = key
        self.label = label
        self.icon = icon
        self.activeIcon = activeIcon
    }

    /// OWNER_TABS — Vehicle · Drives · Share · Settings.
    public static let ownerTabs: [MRTTab] = [
        MRTTab(key: "home", label: "Vehicle", icon: "car", activeIcon: "car.fill"),
        MRTTab(key: "drives", label: "Drives", icon: "clock", activeIcon: "clock.fill"),
        MRTTab(key: "invites", label: "Share", icon: "person.2", activeIcon: "person.2.fill"),
        MRTTab(key: "settings", label: "Settings", icon: "gearshape", activeIcon: "gearshape.fill"),
    ]

    /// SHARED_TABS — Live Map · Ride History · Settings.
    public static let sharedTabs: [MRTTab] = [
        MRTTab(key: "shared", label: "Live Map", icon: "map", activeIcon: "map.fill"),
        MRTTab(key: "rideHistory", label: "Ride History", icon: "clock", activeIcon: "clock.fill"),
        MRTTab(key: "sharedSettings", label: "Settings", icon: "gearshape", activeIcon: "gearshape.fill"),
    ]
}

/// Floating capsule tab bar — 60pt tall, radius 24, inset 14pt sides /
/// 26pt bottom. Overlay it bottom-aligned on the screen; `hidden` slides it
/// off with the jsx's transform/opacity timing. Flat-only: the jsx backdrop
/// blur is dropped, the 0.92-alpha fill stays.
public struct BottomNav: View {
    @Binding private var selection: String
    private let tabs: [MRTTab]
    private let height: CGFloat
    private let hidden: Bool

    public init(
        selection: Binding<String>,
        tabs: [MRTTab] = MRTTab.ownerTabs,
        height: CGFloat = 60,
        hidden: Bool = false
    ) {
        _selection = selection
        self.tabs = tabs
        self.height = height
        self.hidden = hidden
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                item(tab)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.mrtNavBarFill))
        // 0.5px solid rgba(255,255,255,0.09)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.mrtNavHairline, lineWidth: MRTMetrics.hairline)
        )
        // 0 1px 0 rgba(255,255,255,0.06) inset — top inner highlight
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.mrtText.opacity(0.06), location: 0),
                            .init(color: .clear, location: 0.15),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        // 0 12px 34px rgba(0,0,0,0.5)
        .shadow(color: .black.opacity(0.5), radius: 17, y: 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 26)
        .opacity(hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.26), value: hidden) // opacity .26s ease
        .offset(y: hidden ? height * 1.2 : 0) // translateY(120%)
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.34), value: hidden)
        .allowsHitTesting(!hidden)
    }

    private func item(_ tab: MRTTab) -> some View {
        let active = selection == tab.key
        return Button {
            selection = tab.key
        } label: {
            VStack(spacing: 4) {
                Image(systemName: active ? tab.activeIcon : tab.icon)
                    .font(.system(size: 22))
                Text(tab.label)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
                    .tracking(0.1)
            }
            // Bright gold when active, muted warm gold when not.
            .foregroundStyle(active ? Color.mrtGold : Color.mrtNavInactive)
            .frame(maxWidth: .infinity, maxHeight: .infinity) // 60pt tall ≥ 44pt target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: active) // color .15s
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Shared placement (full-bleed geometry — CLAUDE.md "Hard rules")
//
// The prototype's `BottomNav` is `position: absolute, bottom: 26` measured
// from the PHYSICAL screen edge (components.jsx:566) — the 393×852 canvas
// has no notion of a SwiftUI safe area. Every owner screen renders its own
// `BottomNav` (see `HomeScreen`'s header comment), so without a shared
// placement rule each screen independently risks re-deriving `bottom: 26`
// against the *safe-area-inset* container instead — which stacks the
// device's ~34pt home-indicator inset on top of the 26pt padding already
// baked into `BottomNav` itself, floating the capsule ~60pt off the
// physical bottom instead of 26pt (the MYR-196 punch-list bug).
//
// `BottomNav` is intrinsically sized (a fitting capsule, no `maxWidth:
// .infinity` of its own), so `.ignoresSafeArea()` alone does nothing for
// it — that modifier only repositions a view when paired with a fill
// frame that *grows into* the reclaimed region (this is why it does work
// on `MapHeader`, which already carries `.frame(maxWidth: .infinity,
// maxHeight: .infinity, alignment: .top)`). So this helper gives
// `BottomNav` that same fill-frame before ignoring the bottom safe area:
// the frame expands to the now-reclaimed physical edge, and the nav's
// `.bottom` alignment (plus its own baked-in 26pt padding) resolves
// against that true edge instead of the safe-area-inset one.
public extension View {
    /// Layers `BottomNav` over this view, bottom-pinned 26pt from the
    /// PHYSICAL screen edge (not the safe area) — the one place the
    /// full-bleed nav-placement rule lives; every owner screen
    /// (`HomeScreen`, `DrivesScreen`, `PlaceholderScreen`) should call this
    /// instead of placing `BottomNav` itself.
    func mrtBottomNav(
        selection: Binding<String>,
        tabs: [MRTTab] = MRTTab.ownerTabs,
        hidden: Bool = false
    ) -> some View {
        overlay {
            BottomNav(selection: selection, tabs: tabs, hidden: hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
