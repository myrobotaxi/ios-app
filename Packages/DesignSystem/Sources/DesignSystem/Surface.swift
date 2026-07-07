import SwiftUI

// MARK: - Two-look surface system (Flat ↔ Liquid Glass)
//
// Port of the prototype's `useSurfaces()` (design project `app/design.jsx`,
// Handoff §2). Two looks:
//
//   • .flat        — solid `surface` fill + 0.5pt hairline border.
//                    Baseline, and the automatic fallback below iOS 26.
//   • .liquidGlass — native glass on iOS 26+ (`.glassEffect`); on earlier
//                    OSes it renders exactly like .flat.
//
// The chosen look is persisted via AppStorage under `SurfaceLook.storageKey`
// and distributed to views through the environment: set it once at the root
// with `.mrtSurfaceLook(look)`, consume it anywhere via
// `@Environment(\.mrtSurfaceLook)` or the `.mrtSurface(...)` modifier.

public enum SurfaceLook: String, CaseIterable, Identifiable, Sendable {
    case flat
    case liquidGlass

    public var id: String { rawValue }

    /// AppStorage key for the persisted look, e.g.
    /// `@AppStorage(SurfaceLook.storageKey) var lookRaw = SurfaceLook.flat.rawValue`.
    public static let storageKey = "mrt.surfaceLook"

    public var displayName: String {
        switch self {
        case .flat: "Flat"
        case .liquidGlass: "Liquid Glass"
        }
    }

    /// Card corner radius for this look (liquid 16, flat 14).
    public var cardRadius: CGFloat {
        switch self {
        case .flat: MRTMetrics.cardRadiusFlat
        case .liquidGlass: MRTMetrics.cardRadius
        }
    }

    /// Bottom-sheet top-corner radius for this look (flat 24, liquid 30).
    public var sheetRadius: CGFloat {
        switch self {
        case .flat: MRTMetrics.sheetRadius
        case .liquidGlass: MRTMetrics.sheetRadiusLiquid
        }
    }

    /// True when this look can actually render native glass on this OS.
    public var rendersGlass: Bool {
        guard self == .liquidGlass else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Environment

private struct MRTSurfaceLookKey: EnvironmentKey {
    static let defaultValue: SurfaceLook = .flat
}

public extension EnvironmentValues {
    var mrtSurfaceLook: SurfaceLook {
        get { self[MRTSurfaceLookKey.self] }
        set { self[MRTSurfaceLookKey.self] = newValue }
    }
}

public extension View {
    /// Injects the current surface look into the environment (root-level).
    func mrtSurfaceLook(_ look: SurfaceLook) -> some View {
        environment(\.mrtSurfaceLook, look)
    }
}

// MARK: - Surface kinds

public enum MRTSurfaceKind {
    /// A card resting on the page (uses the look's card radius).
    case card
    /// A bottom sheet (uses the look's sheet radius).
    case sheet
    /// An input / button chrome (fixed 12pt radius in both looks).
    case control

    func radius(for look: SurfaceLook) -> CGFloat {
        switch self {
        case .card: look.cardRadius
        case .sheet: look.sheetRadius
        case .control: MRTMetrics.controlRadius
        }
    }
}

// MARK: - Modifier

public extension View {
    /// Renders the view on a MyRoboTaxi surface in the current look.
    /// - Parameters:
    ///   - kind: card (default), sheet, or control — decides the corner radius.
    ///   - radius: explicit override of the look-derived radius.
    func mrtSurface(_ kind: MRTSurfaceKind = .card, radius: CGFloat? = nil) -> some View {
        modifier(MRTSurfaceModifier(kind: kind, radiusOverride: radius))
    }
}

struct MRTSurfaceModifier: ViewModifier {
    @Environment(\.mrtSurfaceLook) private var look
    let kind: MRTSurfaceKind
    let radiusOverride: CGFloat?

    func body(content: Content) -> some View {
        let radius = radiusOverride ?? kind.radius(for: look)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if look.rendersGlass {
            content.modifier(GlassBackground(shape: shape))
        } else {
            // Flat look, and the < iOS 26 fallback for Liquid Glass.
            content
                .background(Color.mrtSurface)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
        }
    }
}

private struct GlassBackground: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            // Unreachable in practice (rendersGlass already gates on iOS 26),
            // but the compiler needs a concrete fallback.
            content
                .background(.ultraThinMaterial)
                .clipShape(shape)
        }
    }
}
