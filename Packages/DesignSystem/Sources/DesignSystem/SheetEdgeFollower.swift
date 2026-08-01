import SwiftUI
import UIKit

// MARK: - SheetEdgeFollower (MYR-397 item 3 — chrome that rides the sheet edge)
//
// THE DEFECT. The rider tracking sheet re-anchored its recenter + expand buttons
// off `RiderTrackingSheet`'s SETTLED height, which the engine reports only AFTER
// a settle commits. So through the whole drag the buttons stood perfectly still
// over a moving sheet — and then jumped, in one un-animated SwiftUI layout pass,
// the instant the settle landed. Three client screenshots caught them mid-glitch:
// *"Ensure when dragging up and down the bottom sheet were not glitchy with the
// recenter and fill screen icons or map. Owner bottom sheet and rider bottom
// sheet do a good job of this."*
//
// WHY THE OWNER SHEET DOES NOT HAVE IT. `HomeScreen` anchors its button at a
// CONSTANT (`peekHeight + mapButtonBottomGap`) and stands it down once the sheet
// covers the map, so nothing about it ever moves. That works there because the
// owner sheet RESTS at peek. The tracking sheet rests at its tallest detent —
// pinning to peek would hide both controls at rest, which is the state the rider
// spends the whole ride in. The honest fix for a sheet that rests tall is the one
// the client's words already describe: the buttons RIDE the edge.
//
// WHY IT IS UIKIT. `PanSheet`'s whole design is that a drag frame does zero
// SwiftUI work — the surface is one `CALayer` translation and the only per-frame
// hook (`onDragProgress`) is documented UIKit-only. Driving a SwiftUI `@State`
// offset per finger frame would re-evaluate the rider screen's body — the hosted
// `MKMapView` included — 120 times a second, which is precisely the cost the
// engine exists to avoid. So a follower is a plain `UIView` the engine
// translates from the SAME two places it translates its own surface:
//
//   • `applyVisibleHeight` — every drag frame, inside a disabled-actions
//     `CATransaction`, so the follow is 1:1 with the finger and never lags
//     behind an implicit animation;
//   • the settle animator's own block — so the follower's transform is
//     interpolated by the SAME spring, over the same duration, as the sheet it
//     is following. This is the half a per-frame hook cannot deliver: at settle
//     there are no frames, there is one animator, and a follower outside it
//     would arrive by teleport.
//
// The follower is laid out ONCE by SwiftUI at `baseHeight` (the sheet's lowest
// detent) and only ever transformed from there, so its layout, its accessibility
// frame at rest and its hit region are exactly what they would be without this
// file. `UIView.transform` moves hit-testing with the view, so a button caught
// mid-drag is tappable where it is drawn.

/// The seam between a `PanSheet` and the chrome that follows its top edge.
///
/// Held by the SCREEN (a `@State` value), handed to the sheet as `edgeAnchor:`
/// and to each follower through ``SwiftUI/View/mrtFollowsSheetEdge(_:)``. One
/// anchor may drive several followers — the tracking map has two (the recenter
/// control and the expand chip).
@MainActor
public final class SheetEdgeAnchor {
    public init() {}

    /// The visible sheet height the followers were LAID OUT against — normally
    /// the sheet's lowest detent. Everything else is a translation from here.
    private var baseHeight: CGFloat = 0
    /// The last height the engine reported, replayed whenever `baseHeight` or the
    /// follower set changes so a late-registering follower is never left behind.
    private var currentHeight: CGFloat?
    private var followers: [Follower] = []

    private struct Follower {
        weak var view: UIView?
    }

    /// Declare the height the followers are positioned at in SwiftUI. Changing it
    /// re-derives the current translation rather than moving anything twice.
    public func setBaseHeight(_ height: CGFloat) {
        guard height.isFinite, abs(height - baseHeight) > 0.5 else { return }
        baseHeight = height
        if let currentHeight { applyTranslation(for: currentHeight, animated: false) }
    }

    /// Register a follower view. Held weakly and swept on every registration, so
    /// a follower whose host went away cannot keep the anchor alive or be
    /// transformed after teardown.
    func register(_ view: UIView) {
        followers.removeAll { $0.view == nil || $0.view === view }
        followers.append(Follower(view: view))
        if let currentHeight { applyTranslation(for: currentHeight, animated: false) }
    }

    /// The engine's report. `animated: true` means the caller is INSIDE a
    /// `UIViewPropertyAnimator` block (the settle) and the transform write must
    /// therefore be left animatable; `false` is a finger frame, where an implicit
    /// animation would make the follow lag the sheet.
    func apply(visibleHeight: CGFloat, animated: Bool) {
        guard visibleHeight.isFinite else { return }
        currentHeight = visibleHeight
        applyTranslation(for: visibleHeight, animated: animated)
    }

    private func applyTranslation(for height: CGFloat, animated: Bool) {
        let transform = CGAffineTransform(translationX: 0, y: -(height - baseHeight))
        guard !animated else {
            for follower in followers { follower.view?.transform = transform }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for follower in followers { follower.view?.transform = transform }
        CATransaction.commit()
    }
}

// MARK: - The SwiftUI side

/// Hosts `content` in a `UIView` the anchor can translate.
///
/// **IT MUST REPORT ITS CONTENT'S SIZE, NOT FILL.** A representable that accepts
/// the whole proposal makes its parent's `.padding` and `.frame(alignment:)`
/// meaningless — the content then centres itself in a full-screen box and lands in
/// the same place whatever the caller asked for. That cost a round here: the
/// follower TRANSLATED perfectly (the mid-drag gap was already exact) while its
/// resting position ignored the detent it was supposed to be anchored to, so the
/// chrome sat at one fixed spot with the sheet moving relative to it. The symptom
/// is the opposite of the bug being fixed and looks identical in a still.
///
/// `sizeThatFits` forwards the proposal to the hosting controller's own measurement
/// and `sizingOptions` keeps its intrinsic size in step, so the follower occupies
/// exactly the space its content would have occupied unwrapped.
private struct SheetEdgeFollowerHost<Content: View>: UIViewControllerRepresentable {
    let anchor: SheetEdgeAnchor
    let content: Content

    func makeUIViewController(context: Context) -> SheetEdgeFollowerController<Content> {
        let controller = SheetEdgeFollowerController(rootView: content)
        anchor.register(controller.follower)
        return controller
    }

    func updateUIViewController(_ controller: SheetEdgeFollowerController<Content>, context: Context) {
        controller.host.rootView = content
        // Re-register is a no-op for a view already held (the sweep de-dupes by
        // identity) and repairs the one case that matters: a follower recreated
        // by SwiftUI while the anchor survived.
        anchor.register(controller.follower)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: SheetEdgeFollowerController<Content>,
        context: Context
    ) -> CGSize? {
        uiViewController.host.sizeThatFits(in: proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: UIView.layoutFittingCompressedSize.width, height: UIView.layoutFittingCompressedSize.height)
        ))
    }
}

/// **THE TRANSFORMED VIEW MUST BE ONE SWIFTUI DOES NOT LAY OUT**, which is the
/// whole reason this controller exists instead of a bare `UIHostingController`.
///
/// SwiftUI positions a representable's root view by writing its `frame` every
/// layout pass, and writing `frame` on a view with a non-identity `transform`
/// recomputes `bounds`/`center` from the transformed rect — i.e. it silently
/// discards the translation. The failure mode is precise and misleading: DURING a
/// drag there is no SwiftUI layout pass, so the follow is perfect; at rest, and on
/// the very first seating, the transform is wiped and the chrome sits wherever its
/// layout put it. That is the opposite of the bug being fixed and is invisible in
/// a still, which is exactly why the UI test samples both.
///
/// So the controller's own `view` is what SwiftUI lays out, and `follower` — a
/// child pinned to its bounds with `autoresizingMask`, never addressed by SwiftUI
/// — is what the anchor translates.
final class SheetEdgeFollowerController<Content: View>: UIViewController {
    let host: UIHostingController<Content>
    /// The layer the anchor translates.
    let follower = UIView()

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
        host.sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // A passthrough container: touches that miss the content fall through to
        // whatever is layered behind this representable (the map). Mirrors the
        // engine's own `PanSheetPassthroughView`.
        view = SheetEdgeFollowerPassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        follower.backgroundColor = .clear
        view.addSubview(follower)

        addChild(host)
        host.view.backgroundColor = .clear
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        follower.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// **NEITHER `frame` NOR AUTORESIZING MAY TOUCH THE FOLLOWER**, and this is the
    /// same trap as the one in this file's header, one level down: `autoresizingMask`
    /// resizes a subview by writing its `frame`, and writing `frame` on a
    /// transformed view recomputes `bounds`/`center` from the TRANSFORMED rect —
    /// silently discarding the translation on the next layout pass. It cost a second
    /// round, with the anchor logging a perfectly correct `dy=-316.33` while the
    /// chrome sat exactly where its layout had put it.
    ///
    /// `bounds` + `center` are the transform-safe pair (the transform is applied
    /// about the centre, so neither is derived from it), so the follower is sized
    /// here by hand and its `transform` is left to the anchor alone.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        guard follower.bounds.size != bounds.size || follower.center != CGPoint(x: bounds.midX, y: bounds.midY) else { return }
        follower.bounds = CGRect(origin: .zero, size: bounds.size)
        follower.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Claims only the points its content actually occupies, so a follower parked over
/// a map does not swallow pans that miss its buttons.
private final class SheetEdgeFollowerPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

public extension View {
    /// Ride a `PanSheet`'s top edge: this view is laid out where it would be at
    /// the sheet's base height and then TRANSLATED, per drag frame and through
    /// the settle, by however much taller the sheet currently is.
    ///
    /// Apply it to the smallest view that has to move — the transform is free,
    /// but the `UIHostingController` around it is a real view boundary.
    func mrtFollowsSheetEdge(_ anchor: SheetEdgeAnchor) -> some View {
        SheetEdgeFollowerHost(anchor: anchor, content: self)
    }
}
