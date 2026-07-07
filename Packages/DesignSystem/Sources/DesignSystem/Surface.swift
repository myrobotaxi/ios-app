import SwiftUI

// MARK: - Two-look surface system (Flat ↔ Liquid Glass)
//
// Port of the prototype's `useSurfaces()` (design project `app/design.jsx`,
// Handoff §2). Two looks:
//
//   • .flat        — solid fill + 0.5pt hairline border.
//                    Baseline, and the automatic fallback below iOS 26.
//   • .liquidGlass — native glass on iOS 26+ (`.glassEffect`); on earlier
//                    OSes it renders exactly like .flat, radii included
//                    (resolve metrics through `effective`, never the raw case).
//
// The chosen look is persisted via AppStorage under `MRTSurfaceLook.storageKey`
// and distributed to views through the environment: set it once at the root
// with `.mrtSurfaceLook(look)`, consume it anywhere via
// `@Environment(\.mrtSurfaceLook)` or the `.mrtSurface(...)` modifier.

public enum MRTSurfaceLook: String, CaseIterable, Identifiable, Sendable {
    case flat
    case liquidGlass

    public var id: String { rawValue }

    /// AppStorage key for the persisted look, e.g.
    /// `@AppStorage(MRTSurfaceLook.storageKey) var lookRaw = MRTSurfaceLook.flat.rawValue`.
    public static let storageKey = "mrt.surfaceLook"

    public var displayName: String {
        switch self {
        case .flat: "Flat"
        case .liquidGlass: "Liquid Glass"
        }
    }

    /// The look that actually renders on this OS: `.liquidGlass` degrades to
    /// `.flat` below iOS 26 (chrome *and* metrics).
    public var effective: MRTSurfaceLook {
        rendersGlass || self == .flat ? self : .flat
    }

    /// Card corner radius for this look (liquid 16, flat 14), resolved
    /// against what actually renders on this OS.
    public var cardRadius: CGFloat {
        switch effective {
        case .flat: MRTMetrics.cardRadiusFlat
        case .liquidGlass: MRTMetrics.cardRadius
        }
    }

    /// Bottom-sheet top-corner radius for this look (flat 24, liquid 30),
    /// resolved against what actually renders on this OS.
    public var sheetRadius: CGFloat {
        switch effective {
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
    static let defaultValue: MRTSurfaceLook = .flat
}

public extension EnvironmentValues {
    var mrtSurfaceLook: MRTSurfaceLook {
        get { self[MRTSurfaceLookKey.self] }
        set { self[MRTSurfaceLookKey.self] = newValue }
    }
}

public extension View {
    /// Injects the current surface look into the environment (root-level).
    func mrtSurfaceLook(_ look: MRTSurfaceLook) -> some View {
        environment(\.mrtSurfaceLook, look)
    }
}

// MARK: - Surface kinds

public enum MRTSurfaceKind {
    /// A card resting on the page (uses the look's card radius).
    case card
    /// A bottom sheet (uses the look's sheet radius; top corners only).
    case sheet
    /// An input / button chrome (fixed 12pt radius in both looks).
    case control

    func radius(for look: MRTSurfaceLook) -> CGFloat {
        switch self {
        case .card: look.cardRadius
        case .sheet: look.sheetRadius
        case .control: MRTMetrics.controlRadius
        }
    }

    /// Sheets round only their top corners; cards and controls round all four.
    func shape(radius: CGFloat) -> AnyInsettableShape {
        switch self {
        case .sheet:
            AnyInsettableShape(UnevenRoundedRectangle(
                topLeadingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            ))
        case .card, .control:
            AnyInsettableShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

/// Type-erased `InsettableShape` — `AnyShape` drops insettability, which
/// `strokeBorder` needs.
public struct AnyInsettableShape: InsettableShape {
    private let _path: @Sendable (CGRect) -> Path
    private let _inset: @Sendable (CGFloat) -> AnyInsettableShape

    public init<S: InsettableShape>(_ shape: S) {
        _path = { shape.path(in: $0) }
        _inset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    public func path(in rect: CGRect) -> Path { _path(rect) }
    public func inset(by amount: CGFloat) -> AnyInsettableShape { _inset(amount) }
}

// MARK: - Modifier

public extension View {
    /// Renders the view on a MyRoboTaxi surface in the current look.
    /// - Parameters:
    ///   - kind: card (default), sheet, or control — decides the corner shape.
    ///   - fill: solid fill used by the Flat look / fallback (glass ignores it).
    ///   - radius: explicit override of the look-derived radius.
    func mrtSurface(
        _ kind: MRTSurfaceKind = .card,
        fill: Color = .mrtSurface,
        radius: CGFloat? = nil
    ) -> some View {
        modifier(MRTSurfaceModifier(kind: kind, fill: fill, radiusOverride: radius))
    }
}

struct MRTSurfaceModifier: ViewModifier {
    @Environment(\.mrtSurfaceLook) private var look
    let kind: MRTSurfaceKind
    let fill: Color
    let radiusOverride: CGFloat?

    func body(content: Content) -> some View {
        // Resolve against the effective look so the < iOS 26 Liquid Glass
        // fallback gets Flat metrics as well as Flat chrome.
        let radius = radiusOverride ?? kind.radius(for: look.effective)
        let shape = kind.shape(radius: radius)
        if look.rendersGlass {
            content.modifier(GlassBackground(shape: shape))
        } else {
            // Flat look, and the < iOS 26 fallback for Liquid Glass.
            content
                .background(fill)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
        }
    }
}

private struct GlassBackground: ViewModifier {
    let shape: AnyInsettableShape

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Clip content like the flat path does, so the two looks are
            // drop-in interchangeable for edge-to-edge content.
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            // Unreachable in practice (rendersGlass already gates on iOS 26),
            // but the compiler needs a concrete fallback.
            content
                .background(.ultraThinMaterial)
                .clipShape(shape)
        }
    }
}
