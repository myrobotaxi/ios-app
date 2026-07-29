import SwiftUI

// MARK: - Skeleton loading placeholders (MYR-326)
//
// THE CLIENT'S REPORT (TestFlight, Jul 28): "Can we have skeleton loading or a
// nicer loading icon? This looks bad." — attached to owner Home mid cold-load:
// an entirely black screen with a system `ProgressView` and "Connecting to your
// vehicles…" floating in the middle of it.
//
// The prototype has no loading state to port (`app/*.jsx` renders mock data at
// t=0, so nothing there is ever pending), which is exactly why this app grew
// system spinners instead: there was no design vocabulary for "not yet". There
// IS one for "a highlight sweeping across a surface" — `MRTShimmerBand`, the
// `mrtShimmer` diagonal sweep built for the Add-Tesla virtual-key card
// (onboarding.jsx:222,282) and reused by the tracking plate chip. This file
// composes that existing grammar into the missing one:
//
//   • ``MRTSkeletonBar`` — one placeholder block, sized to the element it
//     stands in for.
//   • ``SwiftUI/View/mrtSkeletonShimmer(period:)`` — ONE `MRTShimmerBand`
//     swept across a whole group of blocks, masked to the blocks themselves so
//     the highlight lights the placeholders and not the gaps between them.
//
// Screens compose their own skeletons from these two (the shape of a loading
// owner sheet is a Home concern, not a design-system one); this package owns
// only the block and the sweep, so every skeleton in the app shimmers with the
// same period, the same 46%-wide -12° band, and the same Reduce Motion
// fallback.
//
// **Reduce Motion** (CLAUDE.md hard rule) — `MRTShimmerBand` renders nothing
// when Reduce Motion is on, so a skeleton degrades to STATIC placeholder
// blocks. That is the correct fallback rather than a fade or a pulse: the
// blocks already communicate "content is coming" by their shape and position;
// the sweep only adds liveliness.

/// One placeholder block — a rounded rectangle in the skeleton fill, sized to
/// stand in for the element that hasn't loaded yet.
///
/// Sizes are given by the CALLER, in the real element's own metrics, because a
/// skeleton is only convincing when it occupies the space its content will:
/// a block the wrong height makes the real content jump when it lands.
public struct MRTSkeletonBar: View {
    private let width: CGFloat?
    private let height: CGFloat
    /// Internal (not private) so `SkeletonTests` can assert the resolved
    /// default without a rendered snapshot.
    let radius: CGFloat
    private let fill: Color

    /// - Parameters:
    ///   - width: fixed width, or `nil` to fill the available width.
    ///   - height: the height of the element being stood in for.
    ///   - radius: corner radius; defaults to a fully rounded bar, which is
    ///     what a text placeholder wants. Pass an explicit radius for card- or
    ///     tile-shaped placeholders.
    ///   - emphasis: `.strong` for headline-weight elements.
    public init(
        width: CGFloat? = nil,
        height: CGFloat = 12,
        radius: CGFloat? = nil,
        emphasis: MRTSkeletonEmphasis = .regular
    ) {
        self.width = width
        self.height = height
        self.radius = radius ?? height / 2
        self.fill = emphasis.fill
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
    }
}

/// How much presence a placeholder block should have — matching the visual
/// weight of the element it stands in for, so the skeleton reads as the same
/// hierarchy the loaded content will.
public enum MRTSkeletonEmphasis: Sendable {
    /// Body-weight text, chips, rows.
    case regular
    /// A headline, a hero figure, a vehicle name.
    case strong

    var fill: Color {
        switch self {
        case .regular: return .mrtSkeletonFill
        case .strong: return .mrtSkeletonFillStrong
        }
    }
}

/// Sweeps ONE `MRTShimmerBand` across the whole modified group, masked to the
/// group's own shapes.
///
/// Applied per-block, the band would restart per block and travel at a
/// different rate in each (its geometry is relative to its container's width),
/// which reads as several unrelated animations rather than one surface catching
/// the light. Applied to the group and masked, the highlight crosses the blocks
/// in sequence exactly as it crosses one card.
public struct MRTSkeletonShimmer: ViewModifier {
    private let period: Double

    public init(period: Double = 2.8) {
        self.period = period
    }

    public func body(content: Content) -> some View {
        content.overlay {
            // Reduce Motion → `MRTShimmerBand` renders nothing, so this whole
            // overlay is empty and the blocks stay static (CLAUDE.md).
            MRTShimmerBand(period: period).mask(content)
        }
    }
}

public extension View {
    /// Sweep one shared shimmer highlight across a group of ``MRTSkeletonBar``
    /// blocks. See ``MRTSkeletonShimmer``.
    func mrtSkeletonShimmer(period: Double = 2.8) -> some View {
        modifier(MRTSkeletonShimmer(period: period))
    }

    /// Announce a skeleton as ONE loading element to VoiceOver.
    ///
    /// The blocks carry no text, so without this a skeleton is silent — worse
    /// than the spinner it replaces, which at least sat beside a sentence. This
    /// collapses the group into a single labelled element and marks it as
    /// updating, so assistive tech says what is happening and re-reads when the
    /// real content lands.
    func mrtSkeletonAccessibility(_ label: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
