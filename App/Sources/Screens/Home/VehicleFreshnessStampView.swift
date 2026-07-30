import SwiftUI
import DesignSystem

// MARK: - VehicleFreshnessStampView (MYR-315)
//
// The owner sheet's recency stamp, and the affordance that refreshes it. It sits
// at the FOOT of the summary hero — the last line of the sheet's status block —
// which is the same grammar the design already uses for freshness: the prototype's
// only freshness element (`vehicle-controls.jsx:428`, "Updated just now · Live") is
// likewise the last, muted, low-contrast line of its block. Nothing new is
// invented: muted text at the sheet's smallest size, with the standard
// `arrow.clockwise` glyph.
//
// WHY HERE and not in the controls footer that already exists: that footer lives
// below the whole controls stack, reachable only at the HALF detent after a scroll.
// At PEEK — the state the owner actually looks at — there is no freshness signal at
// ALL today, so a battery figure read yesterday presents as current. The stamp is
// rendered by the SAME summary view in both crossfade layers, so it reads
// identically at peek and half (MYR-236 round 5.3 requires the two summaries be
// pixel-identical or the crossfade tears).
//
// LIVE ONLY (see `HomeScreen`). The prototype has no such stamp anywhere, and the
// simulated snapshot carries no freshness signals to be honest with, so on the
// simulated path this view is never constructed and every drift-gate scene stays
// byte-identical.
//
// DRAG-SAFE: `PanSheet` sets `cancelsTouchesInView = false` on its pan recognizer
// and hands touches to whichever crossfade layer is at rest, so a plain `Button`
// here is tappable at both detents and a drag begun on it still drags the sheet.
struct VehicleFreshnessStampView: View {
    /// The resolved recency claim — the resting text.
    let recency: VehicleRecency
    /// The transient tap state (waking / acknowledged / notice).
    let phase: VehicleRefreshPhase
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    private var isWaking: Bool {
        if case .waking = phase { return true }
        return false
    }

    private var isNotice: Bool {
        if case .notice = phase { return true }
        return false
    }

    /// The transient copy wins over the resting stamp: an owner who just tapped
    /// needs to know what happened, and the recency they asked about is exactly
    /// what is in question until it resolves.
    private var text: String { phase.text ?? recency.label }

    /// A settled notice reads at the slightly stronger secondary weight, matching
    /// how `ControlTile` distinguishes a notice from a resting sub.
    private var color: Color { isNotice ? .mrtTextSec : .mrtTextMuted }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    // Reduce Motion (CLAUDE.md hard rule): the wake is still
                    // announced by the "Waking …" copy, so the spin is pure
                    // decoration and degrades to static.
                    .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
                    .animation(
                        isWaking && !reduceMotion
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: spin
                    )
                Text(text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            // ≥44pt hit area (CLAUDE.md hard rule) without a 44pt visual band: the
            // row is laid out at its text height and the touch region is grown
            // around it, the same trick `MapHeader`'s 40pt chip uses.
            //
            // MYR-345 — 16, not MYR-315's 15. The row lays out at 13⅓pt (an 11pt
            // line box), so −15 produced a 43⅓pt target: under the rule by ⅔ of a
            // point, and invisible to every test that asserted the INSET instead of
            // the delivered frame. `OwnerFreshnessStampUITests` now reads the frame
            // UIKit actually hit-tests and taps below the ink to prove it is live.
            // It costs the gap above the nav nothing: growing a `contentShape` does
            // not move layout, and the region still stops ~23pt short of the nav's
            // own top edge.
            .contentShape(Rectangle().inset(by: -16))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isWaking) { _, waking in
            spin = waking
        }
        .accessibilityLabel(text)
        .accessibilityHint("Double-tap to refresh, waking the car if needed.")
        .accessibilityAddTraits(.isButton)
        // MYR-345 — a STABLE handle for `OwnerFreshnessStampUITests`, which
        // synthesizes the real tap the client made. The a11y LABEL is the rendered
        // copy (it has to be — that copy is the whole message), so it is the thing
        // under test and cannot also be the selector.
        .accessibilityIdentifier("mrt.freshnessStamp")
    }
}

/// Everything the summary heroes need to render the stamp, bundled so they take
/// ONE optional parameter. `nil` — the simulated path, DEBUG capture fleets other
/// than the freshness scenes, and every preview — renders nothing at all, which is
/// what keeps those summaries byte-identical.
struct VehicleFreshnessStampModel {
    let recency: VehicleRecency
    let phase: VehicleRefreshPhase
    let action: () -> Void
}

extension View {
    /// Append the stamp beneath a summary hero. The wrapper is a zero-spacing
    /// `VStack`, so with no model the hero's layout is untouched; with one, the
    /// stamp sits a uniform 10pt below it in BOTH heroes regardless of their very
    /// different internal spacings (8 parked / 22 driving).
    @ViewBuilder
    func mrtFreshnessStamp(_ model: VehicleFreshnessStampModel?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self
            if let model {
                VehicleFreshnessStampView(
                    recency: model.recency,
                    phase: model.phase,
                    action: model.action
                )
                .padding(.top, 10)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        VehicleFreshnessStampView(recency: .streaming, phase: .idle) {}
        VehicleFreshnessStampView(recency: .synced("3m ago"), phase: .idle) {}
        VehicleFreshnessStampView(recency: .never, phase: .idle) {}
        VehicleFreshnessStampView(recency: .synced("7h ago"), phase: .waking("Lunar")) {}
        VehicleFreshnessStampView(recency: .synced("7h ago"), phase: .notice(.asleep)) {}
        VehicleFreshnessStampView(recency: .synced("7h ago"), phase: .notice(.cooldown)) {}
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.mrtBg)
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
