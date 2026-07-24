import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PanSheet — UIKit-layer draggable bottom-sheet foundation (MYR-236 round 4)
//
// WHY UIKIT. Three SwiftUI-gesture rounds (MYR-236 r1 state/physics, r2
// activation tuning, r3 transform-not-layout) each passed the M-series
// simulator and each shipped still-janky at 120 Hz on the client's iPhone 17
// Pro Max — "fights with me… glitches on the screen." The residual jank is
// SwiftUI doing ANY work per drag frame: even r3's pure `GeometryEffect`
// translation still routes every finger sample through SwiftUI's transaction /
// diff / commit pipeline. A `UIPanGestureRecognizer` writing a `CALayer`
// translation directly does ZERO SwiftUI work per frame — the same mechanism
// UIKit's own sheets and FloatingPanel use. This is that engine, built once and
// adopted by every draggable sheet (`MRTDetentSheet`, the rider idle↔search
// sheet) so there is one drag foundation, not a per-screen fork
// (CLAUDE.md "Reuse, don't fork").
//
// PRINCIPLES kept from round 3:
//   • Lay out the surface ONCE at the tallest detent + an overshoot pad,
//     bottom-anchored with the pad hanging off-screen; per-frame cost is a
//     transform, never a layout/shadow re-render.
//   • Rubber-band, velocity projection, and nearest-detent selection stay in
//     the pure `SheetPhysics` (table-tested) — the coordinator only calls it.
//   • Reduce Motion → a short easeOut instead of the settle spring.
//
// NEW in round 4 (only possible at the UIKit layer):
//   • Interruptible settle — a grab mid-spring reads `layer.presentation()` for
//     the true on-screen position and picks up 1:1 with no jump.
//   • Scroll handoff — the pan recognizes simultaneously with any descendant
//     `UIScrollView`'s pan and arbitrates per the FloatingPanel/UIKit-sheet
//     standard (below max detent → sheet owns the pan, scroll offset pinned; at
//     max detent → scroll owns it EXCEPT a downward pan while scrolled to the
//     top, which the sheet takes over mid-gesture). This is the "fighting" fix.
//   • Keyboard: `endEditing(true)` on drag start so a visible keyboard never
//     fights the sheet.

#if canImport(UIKit)

/// The Handoff §8 sheet-snap spring, expressed as its `UIViewPropertyAnimator`
/// timing so the settle matches `MRTDetentSheet`'s old SwiftUI
/// `.spring(response: 0.42, dampingFraction: 0.86)` frame-for-frame.
enum PanSheetSpring {
    static let response: CGFloat = 0.42
    static let dampingFraction: CGFloat = 0.86
    /// Reduce Motion settle — the same short easeOut the SwiftUI version used.
    static let reducedDuration: TimeInterval = 0.2

    /// A critically-tuned spring timing parameters object matching a SwiftUI
    /// `.spring(response:dampingFraction:)`. SwiftUI maps that to a
    /// mass-spring-damper with `stiffness = (2π/response)²` and
    /// `damping = 4π·dampingFraction/response`; `UISpringTimingParameters`
    /// exposes exactly that via its mass/stiffness/damping initializer.
    static func timing(initialVelocity: CGVector) -> UISpringTimingParameters {
        let mass: CGFloat = 1
        let stiffness = pow(2 * .pi / response, 2) * mass
        let damping = 4 * .pi * dampingFraction / response * mass
        return UISpringTimingParameters(
            mass: mass, stiffness: stiffness, damping: damping, initialVelocity: initialVelocity
        )
    }
}

/// Two SwiftUI layers hosted SIMULTANEOUSLY in the surface (MYR-236 round 5),
/// crossfaded by the drag PROGRESS at the UIKit layer — `low` visible at the
/// min detent, `high` at the max detent. The engine drives each layer's
/// `UIView.alpha` per finger frame (`low` 1→0, `high` 0→1, ramped so the
/// endpoints are clean); at rest the alphas are EXACTLY 0/1 so drift-gate
/// stills are pixel-identical. Both are erased to `AnyView` because they are
/// two different content types living side by side in one surface.
public struct PanSheetCrossfade {
    let low: AnyView
    let high: AnyView

    public init<Low: View, High: View>(@ViewBuilder low: () -> Low, @ViewBuilder high: () -> High) {
        self.low = AnyView(low())
        self.high = AnyView(high())
    }
}

/// A UIKit-backed draggable bottom sheet. Hosts arbitrary SwiftUI `content`
/// (laid out ONCE at the tallest detent + `overshootPad`, top-aligned so the
/// grab handle leads) and drives its on-screen position with a pan recognizer
/// writing a layer translation directly — no SwiftUI work per frame.
///
/// `detentHeights` are ascending on-screen visible heights (points from the
/// physical bottom edge). `selection` is the resting detent index; the engine
/// commits a NEW index to the binding (and calls `onSettle`) only AFTER a
/// settle, never mid-drag. A programmatic `selection` change animates via the
/// same spring.
///
/// ROUND 5 (MYR-236) — content rides the surface:
///   • `onDragProgress` — an OPTIONAL per-finger-frame hook, called from
///     `applyVisibleHeight` with progress = (height − minDetent)/(maxDetent −
///     minDetent) clamped 0…1. It runs on EVERY drag frame and MUST only mutate
///     UIKit properties (`UIView.alpha` / `CALayer`) — NEVER SwiftUI state: a
///     SwiftUI mutation per frame reintroduces exactly the per-frame SwiftUI
///     work this whole engine exists to avoid.
///   • `crossfade` — an OPTIONAL second/third hosted layer pair. The engine
///     hosts `content` as an always-opaque BASE (the rider's sheet-wash, which
///     covers the overshoot band so no map ever leaks through mid-drag) and
///     crossfades the two `PanSheetCrossfade` layers over it by the same drag
///     progress, at the UIKit layer. The settle animator drives the alphas to
///     their endpoint alongside the transform (same duration), so the fade
///     completes WITH the motion, not after it.
public struct PanSheet<Content: View>: UIViewControllerRepresentable {
    let detentHeights: [CGFloat]
    @Binding var selection: Int
    let reduceMotion: Bool
    let overshootPad: CGFloat
    let accessibilityIdentifier: String?
    let accessibilityLabel: String?
    /// Called AFTER a settle commits a detent (index into `detentHeights`). Fires
    /// for a drag-release settle and a flick; NOT for a programmatic `selection`
    /// set (the caller already knows). Runs on the main actor.
    let onSettle: ((Int) -> Void)?
    /// Per-frame drag-progress hook (0…1). UIKit-only mutations — see the type
    /// doc. `nil` for sheets that don't crossfade content (the owner detent
    /// sheet).
    let onDragProgress: ((CGFloat) -> Void)?
    /// Optional crossfade layer pair driven by the same progress (the rider
    /// idle↔search sheet). `nil` → single-layer behavior (the owner sheet).
    let crossfade: PanSheetCrossfade?
    let content: Content

    public init(
        detentHeights: [CGFloat],
        selection: Binding<Int>,
        reduceMotion: Bool,
        overshootPad: CGFloat = 48,
        accessibilityIdentifier: String? = nil,
        accessibilityLabel: String? = nil,
        onSettle: ((Int) -> Void)? = nil,
        onDragProgress: ((CGFloat) -> Void)? = nil,
        crossfade: PanSheetCrossfade? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.detentHeights = detentHeights
        _selection = selection
        self.reduceMotion = reduceMotion
        self.overshootPad = overshootPad
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.onSettle = onSettle
        self.onDragProgress = onDragProgress
        self.crossfade = crossfade
        self.content = content()
    }

    public func makeUIViewController(context: Context) -> PanSheetController<Content> {
        let controller = PanSheetController<Content>(rootView: content)
        controller.configure(
            detentHeights: sanitizedDetents,
            selection: selection,
            reduceMotion: reduceMotion,
            overshootPad: overshootPad,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityLabel: accessibilityLabel,
            onDragProgress: onDragProgress,
            onSettleCommit: { index in
                // Push the settled detent back into SwiftUI AND notify the caller,
                // both AFTER settle so no binding write happens mid-drag.
                if selection != index { self.selection = index }
                onSettle?(index)
            }
        )
        if let crossfade {
            controller.installCrossfade(low: crossfade.low, high: crossfade.high)
        }
        return controller
    }

    public func updateUIViewController(_ controller: PanSheetController<Content>, context: Context) {
        // Content can change out from under the engine (the rider's phase swap
        // at settle commit) — refresh the hosted view without touching position.
        controller.updateContent(content)
        if let crossfade {
            controller.updateCrossfade(low: crossfade.low, high: crossfade.high)
        }
        controller.update(
            detentHeights: sanitizedDetents,
            selection: selection,
            reduceMotion: reduceMotion
        )
    }

    /// Never let a NaN/∞ or an unsorted/empty detent list reach layout
    /// (MYR-227 standing rule). Finite, sorted ascending, at least one entry.
    private var sanitizedDetents: [CGFloat] {
        let finite = detentHeights.filter { $0.isFinite && $0 > 0 }.sorted()
        return finite.isEmpty ? [1] : finite
    }
}

// MARK: - The hosting controller

/// Owns the container, the bottom-anchored surface, the `UIHostingController`
/// child, and the pan recognizer + settle animator. All per-frame drag work
/// happens here in `UIKit` with zero SwiftUI involvement.
public final class PanSheetController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private let host: UIHostingController<Content>
    private let surface = PanSheetSurfaceView()

    // MARK: Crossfade layers (MYR-236 round 5)
    /// The two SwiftUI layers hosted OVER the always-opaque base `host`, their
    /// alphas crossfaded by drag progress at the UIKit layer. `nil` unless the
    /// caller installed a crossfade (only the rider idle↔search sheet does).
    private var lowHost: UIHostingController<AnyView>?
    private var highHost: UIHostingController<AnyView>?
    private var hasCrossfade: Bool { lowHost != nil && highHost != nil }
    /// Per-finger-frame progress hook — UIKit-only mutations (see `PanSheet`).
    private var onDragProgress: ((CGFloat) -> Void)?

    private var detentHeights: [CGFloat] = [1]
    private var selection = 0
    private var reduceMotion = false
    private var overshootPad: CGFloat = 48
    private var onSettleCommit: ((Int) -> Void)?

    /// The visible height the surface is currently RESTING at (the committed
    /// detent's height), the anchor programmatic changes animate from.
    private var restingHeight: CGFloat = 0
    /// Live visible height during a drag; mirrors the on-screen position so a
    /// mid-settle re-grab reads it (backed by `layer.presentation()`).
    private var liveHeight: CGFloat = 0

    private var settleAnimator: UIViewPropertyAnimator?
    private var pan: UIPanGestureRecognizer!

    // Drag session state.
    private var dragAnchorHeight: CGFloat = 0
    /// Which recognizer owns the current vertical pan — the sheet, or a
    /// descendant scroll view. Re-evaluated as the gesture crosses the scroll's
    /// top edge (the handoff).
    private enum DragOwner { case undecided, sheet, scroll }
    private var dragOwner: DragOwner = .undecided
    private weak var activeScrollView: UIScrollView?
    /// The scroll offset pinned while the SHEET owns the pan (so the inner list
    /// can't scroll under the finger while the sheet is moving).
    private var pinnedScrollOffsetY: CGFloat = 0
    /// The finger translation captured at the moment ownership flipped to the
    /// sheet, so the sheet picks up from that instant with no jump.
    private var sheetOwnershipTranslationY: CGFloat = 0

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        // A passthrough container: touches that miss the surface (the map area
        // above the sheet, and the off-screen pad) fall through to the SwiftUI
        // views layered behind this representable in the ZStack.
        view = PanSheetPassthroughView()
    }

    func configure(
        detentHeights: [CGFloat],
        selection: Int,
        reduceMotion: Bool,
        overshootPad: CGFloat,
        accessibilityIdentifier: String?,
        accessibilityLabel: String?,
        onDragProgress: ((CGFloat) -> Void)?,
        onSettleCommit: @escaping (Int) -> Void
    ) {
        self.detentHeights = detentHeights
        self.selection = min(max(selection, 0), detentHeights.count - 1)
        self.reduceMotion = reduceMotion
        self.overshootPad = overshootPad
        self.onDragProgress = onDragProgress
        self.onSettleCommit = onSettleCommit
        surface.accessibilityIdentifier = accessibilityIdentifier
        if let accessibilityLabel {
            surface.accessibilityLabel = accessibilityLabel
        }
    }

    // MARK: Crossfade install / update (MYR-236 round 5)

    /// Host the two crossfade layers ABOVE the base `host`, filling the surface
    /// envelope top-aligned exactly like the base. Called once, from
    /// `makeUIViewController`. The base `host` stays the always-opaque wash that
    /// covers the overshoot band; these two ride over it with driven alphas.
    func installCrossfade(low: AnyView, high: AnyView) {
        guard lowHost == nil, highHost == nil else {
            updateCrossfade(low: low, high: high)
            return
        }
        let lowVC = UIHostingController(rootView: low)
        let highVC = UIHostingController(rootView: high)
        for vc in [lowVC, highVC] {
            addChild(vc)
            vc.view.backgroundColor = .clear
            vc.view.translatesAutoresizingMaskIntoConstraints = true
            // Added AFTER the base host so they layer over the wash; `high`
            // (search) on top so at max detent its opaque fill hides `low`.
            surface.addSubview(vc.view)
            vc.didMove(toParent: self)
        }
        lowHost = lowVC
        highHost = highVC
        if isViewLoaded { view.setNeedsLayout() }
    }

    func updateCrossfade(low: AnyView, high: AnyView) {
        lowHost?.rootView = low
        highHost?.rootView = high
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // The container never intercepts touches meant for the map/chrome behind
        // the sheet: only the surface (and its content) is interactive.
        view.isUserInteractionEnabled = true

        surface.backgroundColor = .clear
        surface.isUserInteractionEnabled = true
        view.addSubview(surface)

        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        // Insert at the BACK: any crossfade layers installed in
        // `makeUIViewController` (before this runs) were already added to the
        // surface, and the base must sit beneath them (MYR-236 round 5).
        surface.insertSubview(host.view, at: 0)
        host.didMove(toParent: self)

        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // Recognize alongside a descendant scroll view's own pan so the handoff
        // can arbitrate frame-by-frame instead of one blocking the other.
        pan.cancelsTouchesInView = false
        surface.addGestureRecognizer(pan)

        restingHeight = detentHeights[selection]
        liveHeight = restingHeight
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSurface()
    }

    /// The fixed surface layout — recomputed only on a bounds change, NEVER per
    /// drag frame. Surface height = tallest detent + overshoot pad, bottom-
    /// anchored so the pad hangs below the physical bottom edge (an upward
    /// overshoot never reveals a gap under the lifted sheet).
    private var surfaceHeight: CGFloat { (detentHeights.max() ?? 1) + overshootPad }

    private func layoutSurface() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let h = surfaceHeight
        // Untransformed frame: bottom edge flush with the container bottom.
        surface.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        surface.center = CGPoint(x: bounds.width / 2, y: bounds.height - h / 2)
        host.view.frame = surface.bounds
        // Crossfade layers fill the same envelope, top-aligned over the base.
        lowHost?.view.frame = surface.bounds
        highHost?.view.frame = surface.bounds
        // Re-apply the current translation for the resting/live height.
        applyVisibleHeight(dragOwner == .sheet ? liveHeight : restingHeight)
    }

    // MARK: Position

    /// Translate the surface so `height` points of it show above the bottom edge.
    /// A pure layer transform — no layout, no shadow re-render.
    private func applyVisibleHeight(_ height: CGFloat) {
        guard height.isFinite else { return }
        liveHeight = height
        surface.mrtVisibleHeight = height
        let offsetY = surfaceHeight - height
        // Disable implicit CA animations so the drag stays 1:1 with the finger.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.transform = CGAffineTransform(translationX: 0, y: offsetY)
        CATransaction.commit()
        // MYR-236 round 5: content rides the surface. Drive the drag-progress
        // hook + the crossfade alphas from the SAME transform update — UIKit
        // only, zero SwiftUI work per frame.
        driveProgress(forHeight: height, animatingAlphas: false)
    }

    // MARK: Drag progress + crossfade (MYR-236 round 5)

    /// Progress of `height` between the min and max detents, clamped 0…1.
    private func progress(forHeight height: CGFloat) -> CGFloat {
        let lo = detentHeights.first ?? height
        let hi = detentHeights.last ?? height
        guard hi > lo, height.isFinite else { return 0 }
        return min(1, max(0, (height - lo) / (hi - lo)))
    }

    /// Ramp the raw progress so the crossfade endpoints are clean — `low` is
    /// fully opaque until 0.15 and `high` fully opaque past 0.85, so a resting
    /// detent lands the alphas at EXACTLY 0/1 (drift-gate pixel-identity).
    static func crossfadeRamp(_ p: CGFloat, low: CGFloat = 0.15, high: CGFloat = 0.85) -> CGFloat {
        guard high > low else { return p >= high ? 1 : 0 }
        return min(1, max(0, (p - low) / (high - low)))
    }

    /// Fire the progress hook and set the crossfade alphas for `height`. When
    /// `animatingAlphas` is true the caller is INSIDE a `UIViewPropertyAnimator`
    /// block (the settle) — only the animatable `alpha` writes belong there; the
    /// non-animatable interaction flip is applied at the settle's completion.
    private func driveProgress(forHeight height: CGFloat, animatingAlphas: Bool) {
        let p = progress(forHeight: height)
        onDragProgress?(p)
        guard hasCrossfade else { return }
        let r = Self.crossfadeRamp(p)
        highHost?.view.alpha = r
        lowHost?.view.alpha = 1 - r
        if !animatingAlphas { setCrossfadeInteraction(ramped: r) }
    }

    /// The higher-alpha layer owns touches at rest so its taps (the search
    /// field, the idle quick-places) land; flipped only at 0/1 endpoints in
    /// practice (mid-drag the pan owns the gesture, no content taps happen).
    private func setCrossfadeInteraction(ramped r: CGFloat) {
        highHost?.view.isUserInteractionEnabled = r >= 0.5
        lowHost?.view.isUserInteractionEnabled = r < 0.5
    }

    // MARK: SwiftUI-driven updates

    func updateContent(_ content: Content) {
        host.rootView = content
    }

    func update(detentHeights: [CGFloat], selection: Int, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let detentsChanged = detentHeights != self.detentHeights
        self.detentHeights = detentHeights
        let clamped = min(max(selection, 0), detentHeights.count - 1)

        // A programmatic detent change (selection differs from what we settled
        // to) animates to the new resting height with the same spring — unless a
        // drag is in flight (its own release will settle).
        let targetHeight = detentHeights[clamped]
        if detentsChanged {
            // Bounds/detent geometry moved — resize the surface, then re-seat.
            view.setNeedsLayout()
        }
        if clamped != self.selection {
            self.selection = clamped
        }
        // A FINGER DRAG in flight owns the surface — never fight it; its release
        // settles to the nearest detent.
        if dragOwner != .undecided { return }
        if settleAnimator != nil {
            // MYR-248: a settle in flight must be RE-TARGETED — not silently
            // dropped — when the DETENT GEOMETRY itself moved under it. The rider
            // search detent is a MEASURED height (the search content's natural
            // size), and the first preference pass can report a transient over-
            // measurement (`headerHeight` starts at 0), so the surface briefly
            // settles toward a stale, too-tall detent; one frame later the
            // corrected (shorter) detent arrives. The OLD engine bailed here
            // because a settle was mid-flight, dropping the correction — the
            // surface then rested at the stale tall height while `surfaceHeight`
            // shrank to the corrected detent, translating it far UP off the bottom
            // (stranded at the TOP — the client's back-from-pin-drop bug). Re-aim
            // the settle at the new detent height for the same index.
            //
            // GATED on `detentsChanged` (not a bare target≠resting test): mid-
            // settle, SwiftUI can call this with the PRE-COMMIT binding selection,
            // whose target height differs from the committed `restingHeight` even
            // though the detents are unchanged — re-settling on THAT would snap the
            // surface back to the old detent, killing every drag-release settle
            // (the owner peek↔half sheet drags to nowhere). The stranding is a
            // genuine detent-height change, so that is the only trigger.
            if detentsChanged, abs(restingHeight - targetHeight) > 0.5 {
                animateSettle(to: clamped, initialVelocityHeightPerSec: 0, commit: false)
            }
            return
        }
        healStrandedPositionIfNeeded()
        guard settleAnimator == nil else { return }
        if abs(restingHeight - targetHeight) > 0.5 {
            animateSettle(to: clamped, initialVelocityHeightPerSec: 0, commit: false)
        } else {
            restingHeight = targetHeight
            applyVisibleHeight(targetHeight)
        }
    }

    // MARK: Pan handling

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginDrag()
        case .changed:
            updateDrag(translationY: recognizer.translation(in: view).y)
        case .ended, .cancelled, .failed:
            endDrag(velocityY: recognizer.velocity(in: view).y)
        default:
            break
        }
    }

    private func beginDrag() {
        // Interruption: a grab mid-settle reads the TRUE on-screen position from
        // the presentation layer and picks up from there with zero jump.
        let presented = surface.layer.presentation()?.transform ?? surface.layer.transform
        let presentedOffsetY = CGFloat(presented.m42)
        let presentedHeight = surfaceHeight - presentedOffsetY
        let startHeight = presentedHeight.isFinite ? presentedHeight : restingHeight
        settleAnimator?.stopAnimation(true)
        settleAnimator = nil
        // Freeze at the live position.
        applyVisibleHeight(startHeight)
        dragAnchorHeight = startHeight

        // Keyboard must never fight the sheet (Handoff — endEditing on drag start).
        view.window?.endEditing(true)

        // Find the descendant scroll view lazily, on gesture begin.
        activeScrollView = surface.mrtFirstScrollView()
        dragOwner = .undecided
        sheetOwnershipTranslationY = 0
    }

    private func updateDrag(translationY: CGFloat) {
        // Decide/steer ownership between the sheet and a descendant scroll view.
        let atMaxDetent = abs(dragAnchorHeight - (detentHeights.max() ?? 0)) < 1

        if dragOwner == .undecided {
            resolveInitialOwner(atMaxDetent: atMaxDetent, translationY: translationY)
        }

        switch dragOwner {
        case .scroll:
            // Scroll owns the gesture (at max detent, not scrolled to the top, or
            // scrolling up). If a downward pan drives the scroll to its top, hand
            // over to the sheet from that instant.
            if let scroll = activeScrollView, translationY > 0, scroll.contentOffset.y <= topInset(of: scroll) {
                // Handoff: pin the offset at the top and let the sheet take over,
                // re-anchored so it starts moving from THIS instant (no jump).
                dragOwner = .sheet
                pinnedScrollOffsetY = topInset(of: scroll)
                sheetOwnershipTranslationY = translationY
                dragAnchorHeight = detentHeights.max() ?? dragAnchorHeight
                cancelScrollPan(scroll)
            }
            // Otherwise leave the scroll view to scroll itself (simultaneous
            // recognition means it already is).
        case .sheet:
            if let scroll = activeScrollView {
                // Pin the inner list while the sheet moves.
                scroll.contentOffset.y = pinnedScrollOffsetY
            }
            let delta = -(translationY - sheetOwnershipTranslationY)
            let raw = dragAnchorHeight + delta
            let lower = detentHeights.first ?? raw
            let upper = detentHeights.last ?? raw
            let banded = SheetPhysics.rubberBand(raw, lowerBound: lower, upperBound: upper)
            applyVisibleHeight(banded)
        case .undecided:
            break
        }
    }

    /// First-frame arbitration (the FloatingPanel/UIKit-sheet rule):
    ///  • Below max detent → the SHEET owns every vertical pan (offset pinned).
    ///  • At max detent → the SCROLL owns it, EXCEPT a downward pan while the
    ///    list is already at its top, which the sheet owns (drag-to-collapse).
    private func resolveInitialOwner(atMaxDetent: Bool, translationY: CGFloat) {
        guard let scroll = activeScrollView else {
            dragOwner = .sheet
            sheetOwnershipTranslationY = 0
            return
        }
        if !atMaxDetent {
            dragOwner = .sheet
            pinnedScrollOffsetY = scroll.contentOffset.y
            sheetOwnershipTranslationY = 0
            cancelScrollPan(scroll)
            return
        }
        let atTop = scroll.contentOffset.y <= topInset(of: scroll) + 0.5
        if atTop, translationY > 0 {
            dragOwner = .sheet
            pinnedScrollOffsetY = topInset(of: scroll)
            sheetOwnershipTranslationY = translationY
            cancelScrollPan(scroll)
        } else {
            dragOwner = .scroll
        }
    }

    private func topInset(of scroll: UIScrollView) -> CGFloat { -scroll.adjustedContentInset.top }

    /// Cancel the inner scroll view's own pan recognition for the current
    /// gesture (toggling isEnabled tears down its touch tracking). Without
    /// this the scroll recognizes simultaneously, builds fling momentum
    /// during a SHEET-owned drag, and coasts the content after our release
    /// (the post-settle content jump). The per-frame offset pin stays as a
    /// belt-and-braces guard.
    private func cancelScrollPan(_ scroll: UIScrollView) {
        let pan = scroll.panGestureRecognizer
        guard pan.isEnabled else { return }
        pan.isEnabled = false
        pan.isEnabled = true
    }

    /// If the surface is resting somewhere no committed detent put it (an
    /// interrupted settle whose commit was cancelled by a re-grab, then a
    /// scroll-owned release), settle-with-commit to the nearest detent.
    /// No-op mid-drag or mid-settle. Uses the engine's own `liveHeight` —
    /// authoritative at rest (a stranded freeze leaves it at the frozen
    /// position) and initialized to the resting height at load, so this can
    /// never misread a not-yet-laid-out transform (the launch-time
    /// false-positive that a raw presentation-layer read produced).
    private func healStrandedPositionIfNeeded() {
        guard dragOwner == .undecided || dragOwner == .scroll else { return }
        guard settleAnimator == nil else { return }
        guard view.window != nil, view.bounds.height > 0 else { return }
        guard liveHeight.isFinite, abs(liveHeight - restingHeight) > 2 else { return }
        animateSettle(to: nearestDetentIndex(toHeight: liveHeight), initialVelocityHeightPerSec: 0, commit: true)
    }

    private func endDrag(velocityY: CGFloat) {
        defer {
            dragOwner = .undecided
            activeScrollView = nil
            sheetOwnershipTranslationY = 0
        }
        guard dragOwner == .sheet else {
            // A prior interrupted settle (its animator stopped by a re-grab,
            // its commit therefore never fired) can leave the surface parked
            // off its committed detent while THIS gesture went to the scroll —
            // the sheet then sits at e.g. half with the binding still at peek
            // (stale chrome + un-collapsed reserve, client bug Jul 23). Heal:
            // settle-with-commit to the nearest detent.
            healStrandedPositionIfNeeded()
            return
        }
        let releaseHeight = liveHeight
        // Project the throw from release VELOCITY (height-space: up = positive),
        // then snap to the detent nearest the projected endpoint — a fast flick
        // crosses detents on small displacement (SheetPhysics, shared math).
        let projected = releaseHeight + SheetPhysics.projection(velocity: -velocityY)
        let targetIndex = nearestDetentIndex(toHeight: projected)
        // Settle spring's initial velocity = the finger's, so the throw is
        // continuous into the snap (no visible velocity discontinuity).
        animateSettle(to: targetIndex, initialVelocityHeightPerSec: -velocityY, commit: true)
    }

    private func nearestDetentIndex(toHeight height: CGFloat) -> Int {
        guard height.isFinite else { return selection }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, h) in detentHeights.enumerated() {
            let d = abs(h - height)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    // MARK: Settle

    private func animateSettle(to index: Int, initialVelocityHeightPerSec: CGFloat, commit: Bool) {
        let clamped = min(max(index, 0), detentHeights.count - 1)
        let targetHeight = detentHeights[clamped]
        let fromHeight = liveHeight
        let distance = targetHeight - fromHeight
        settleAnimator?.stopAnimation(true)

        // Commit the resting state up front so an interrupting re-grab and any
        // programmatic update reconcile against the destination.
        restingHeight = targetHeight
        selection = clamped

        let targetRamped = Self.crossfadeRamp(progress(forHeight: targetHeight))

        guard abs(distance) > 0.5 else {
            applyVisibleHeight(targetHeight)
            if commit { onSettleCommit?(clamped) }
            return
        }

        let animator: UIViewPropertyAnimator
        if reduceMotion {
            animator = UIViewPropertyAnimator(duration: PanSheetSpring.reducedDuration, curve: .easeOut)
        } else {
            // Convert the height-space velocity (pts/s) to the animator's
            // normalized initial velocity along the travel (dx over unit time).
            let normalized = distance != 0 ? initialVelocityHeightPerSec / distance : 0
            let timing = PanSheetSpring.timing(initialVelocity: CGVector(dx: normalized, dy: 0))
            animator = UIViewPropertyAnimator(duration: PanSheetSpring.response, timingParameters: timing)
        }
        animator.isInterruptible = true
        animator.addAnimations { [weak self] in
            guard let self else { return }
            // Model transform jumps to the destination (presentation layer
            // interpolates) — `mrtVisibleHeight`/`liveHeight` track the target so
            // an on-demand accessibility-frame read settles to the final detent.
            self.liveHeight = targetHeight
            self.surface.mrtVisibleHeight = targetHeight
            self.surface.transform = CGAffineTransform(translationX: 0, y: self.surfaceHeight - targetHeight)
            // MYR-236 round 5: crossfade the content alphas ALONGSIDE the settle
            // transform (same animator/duration) so the fade completes WITH the
            // motion, not after — `applyVisibleHeight` only fires during drags.
            self.highHost?.view.alpha = targetRamped
            self.lowHost?.view.alpha = 1 - targetRamped
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            if position == .end {
                self.applyVisibleHeight(targetHeight)
            }
            // Land the interaction ownership on the settled endpoint.
            self.setCrossfadeInteraction(ramped: targetRamped)
            self.settleAnimator = nil
            if commit { self.onSettleCommit?(clamped) }
        }
        settleAnimator = animator
        animator.startAnimation()
    }

    // MARK: UIGestureRecognizerDelegate

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Recognize alongside a descendant scroll view's pan so the handoff can
        // arbitrate every frame (the "fighting" fix). Never simultaneously with
        // unrelated recognizers.
        guard gestureRecognizer === pan else { return false }
        return other.view is UIScrollView || other is UIPanGestureRecognizer && other.view?.mrtIsInsideScrollView == true
    }
}

// MARK: - Surface view

/// The bottom-anchored draggable surface. Overrides `accessibilityFrame` to
/// report its LIVE transformed position in screen coordinates so the XCUITest
/// harness sees the element move as the drag/settle translates it — the round-3
/// requirement, kept at the UIKit layer. `mrtVisibleHeight` is the last applied
/// visible height (used for the a11y adjustable action bookkeeping).
final class PanSheetSurfaceView: UIView {
    var mrtVisibleHeight: CGFloat = 0

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(bounds, in: self) }
        set { /* derived from the live transform; ignore external sets */ }
    }

    // The surface claims EVERY in-bounds touch (default UIView hit-testing).
    // Round 5.1: it previously returned nil when the hosted SwiftUI tree had no
    // hit-testable content at the point (spacers, the reserved band) — those
    // touches fell through the passthrough container to the MAP, so panning on
    // an "empty" part of the sheet scrolled the map (client bug, Jul 23). The
    // surface's frame is exactly the sheet's visual band (the overshoot pad is
    // off-screen and unreachable; the map area above is outside the frame and
    // still falls through via `PanSheetPassthroughView`), so claiming in-bounds
    // touches is correct — and since the pan recognizer lives on the surface,
    // dragging an empty region now drags the SHEET, as it should.
}

/// The controller's root view: transparent to any touch that does not land on
/// the sheet surface or its content, so the map/chrome behind the representable
/// stay interactive.
final class PanSheetPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - Scroll-view discovery + helpers

extension UIView {
    /// Lazily walk the view tree for the first descendant `UIScrollView` (the
    /// inner list the handoff arbitrates against). Called on gesture begin, not
    /// per frame.
    func mrtFirstScrollView() -> UIScrollView? {
        if let scroll = self as? UIScrollView, scroll.isScrollEnabled { return scroll }
        for sub in subviews {
            if let found = sub.mrtFirstScrollView() { return found }
        }
        return nil
    }

    /// Whether this view sits inside a `UIScrollView` (used to recognize a
    /// scroll's pan simultaneously even when it's reported on an inner view).
    var mrtIsInsideScrollView: Bool {
        var node: UIView? = self
        while let current = node {
            if current is UIScrollView { return true }
            node = current.superview
        }
        return false
    }
}

#endif
