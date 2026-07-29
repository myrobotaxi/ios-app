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
// composes that existing grammar into the missing one: ``MRTSkeletonBar``, one
// placeholder block with that same sweep travelling across it.
//
// Screens compose their own skeletons from these blocks — the shape of a
// loading owner sheet is a Home concern, not a design-system one — so every
// skeleton in the app shimmers with the same period, the same 46%-wide -12°
// band, and the same Reduce Motion fallback.
//
// WHY THE SWEEP LIVES IN THE BLOCK, not in a group modifier around it. The
// obvious composition is one band across the whole group, `.mask`ed to the
// blocks so it lights the placeholders and not the gaps between them. That
// renders NOTHING: masking parks the band in an offscreen compositing pass
// whose contents stop being re-rendered per frame, so the skeleton sits
// perfectly still — visually identical to the Reduce Motion fallback, and
// invisible to any still screenshot. (It also fails a second, quieter way if
// the blocks are translucent: a mask multiplies by ALPHA, so a 6%-opaque block
// scales a 16% highlight down to 1%. Both traps are why the block fills are
// opaque tokens and why this issue's evidence is a frame DIFF, not a still.)
// Clipping each block to its own shape has neither problem, and because every
// band starts at the same instant they light up in phase — which reads as one
// sweep crossing the group, the effect the mask was reaching for.
//
// **Reduce Motion** (CLAUDE.md hard rule) — `MRTShimmerBand` renders nothing
// when Reduce Motion is on, so a skeleton degrades to STATIC placeholder
// blocks. That is the correct fallback rather than a fade or a pulse: the
// blocks already communicate "content is coming" by their shape and position;
// the sweep only adds liveliness.

/// One placeholder block — a rounded rectangle in the skeleton fill with the
/// app's shimmer sweeping across it, sized to stand in for the element that
/// hasn't loaded yet.
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
    private let period: Double

    /// - Parameters:
    ///   - width: fixed width, or `nil` to fill the available width.
    ///   - height: the height of the element being stood in for.
    ///   - radius: corner radius; defaults to a fully rounded bar, which is
    ///     what a text placeholder wants. Pass an explicit radius for card- or
    ///     tile-shaped placeholders.
    ///   - emphasis: `.strong` for headline-weight elements.
    ///   - period: the sweep's loop length. The `mrtShimmer` default (2.8s)
    ///     everywhere; a parameter only so a caller could slow a large surface
    ///     down, never to give two blocks in one group different rates.
    public init(
        width: CGFloat? = nil,
        height: CGFloat = 12,
        radius: CGFloat? = nil,
        emphasis: MRTSkeletonEmphasis = .regular,
        period: Double = 2.8
    ) {
        self.width = width
        self.height = height
        self.radius = radius ?? height / 2
        self.fill = emphasis.fill
        self.period = period
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    public var body: some View {
        shape
            .fill(fill)
            .frame(width: width, height: height)
            // CLIPPED, not masked — see this file's header for why the obvious
            // masked-group composition renders a motionless skeleton.
            .overlay { MRTShimmerBand(period: period) }
            .clipShape(shape)
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

public extension View {
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
