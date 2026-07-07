import SwiftUI
import DesignSystem

/// The sign-in "glimpse" line — a port of `ParticleLine` + `SIGNIN_GLIMPSES`
/// from design/app/screens.jsx. Each line of the live experience assembles
/// behind a left→right reveal edge that sheds gold particles, holds, then
/// dissolves into the next line.
///
/// The particle field is deterministic: instead of a mutable particle store
/// (the jsx `ps` array fed every frame), each frame re-derives the particles
/// spawned at 16 ms ticks along the edge's path from a seeded PRNG, so the
/// render is a pure function of time.
struct SignInGlimpseLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// screens.jsx `SIGNIN_GLIMPSES` — live lines render gold, greetings cream.
    private static let glimpses: [(text: String, live: Bool)] = [
        ("Good evening", false),
        ("A ride is 3 min away", true),
        ("Booking ride with Thomas", true),
        ("Heading your way", true),
        ("Arriving", true),
        ("Arrived, enjoy your evening", true),
    ]

    // Canvas geometry + clock (screens.jsx ParticleLine: W=320, H=46,
    // MY=H/2+1, HOLD=1050, SWAP=1450, pad=10, font 500 16px).
    private static let canvasWidth: CGFloat = 320
    private static let canvasHeight: CGFloat = 46
    private static let midY: Double = Double(canvasHeight) / 2 + 1
    private static let holdMs = 1050.0
    private static let swapMs = 1450.0
    private static let pad = 10.0
    private static let particleLifeMaxMs = 420.0 + 320.0 // spawn(): 420 + rnd*320

    private let start = Date()

    var body: some View {
        Group {
            if reduceMotion {
                // Static fallback (CLAUDE.md: pulses/shimmers fall back to
                // static): the first glimpse, no cycling, no particles.
                Text(Self.glimpses[0].text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.mrtGlimpseCream)
                    // ctx.shadowBlur = 7 at rgba(color, 0.5); CSS blur halved
                    // for SwiftUI's Gaussian sigma (BrandMarks convention).
                    .shadow(color: Color.mrtGlimpseCream.opacity(0.5), radius: 3.5)
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        draw(
                            in: context,
                            elapsedMs: timeline.date.timeIntervalSince(start) * 1000
                        )
                    }
                }
            }
        }
        .frame(width: Self.canvasWidth, height: Self.canvasHeight)
        .accessibilityHidden(true) // decorative marketing line
    }

    // MARK: Frame

    private struct Line {
        let text: GraphicsContext.ResolvedText
        let color: Color
        let x0: Double
        let x1: Double
    }

    private func draw(in context: GraphicsContext, elapsedMs: Double) {
        // One cycle = swap (reveal) then hold. Cycle c swaps glimpse c-1 → c
        // (c==0 swaps in from empty, matching the jsx's initial mode='swap').
        let cycleMs = Self.swapMs + Self.holdMs
        let cycle = Int(elapsedMs / cycleMs)
        let within = elapsedMs - Double(cycle) * cycleMs
        let to = resolvedLine(cycle % Self.glimpses.count, in: context)
        let from = cycle == 0
            ? nil
            : resolvedLine((cycle - 1) % Self.glimpses.count, in: context)

        if within < Self.swapMs {
            let edge = edgeX(atMs: within)
            // New line revealed LEFT of the edge, old line kept to the RIGHT.
            drawText(to, in: context, clipFrom: 0, to: edge)
            if let from {
                drawText(from, in: context, clipFrom: edge, to: Double(Self.canvasWidth))
            }
        } else {
            drawText(to, in: context, clipFrom: 0, to: Double(Self.canvasWidth))
        }
        // Particles persist past the swap (life ≤ 740 ms), so draw them in
        // the hold phase too until the tail dies out.
        drawParticles(in: context, cycle: cycle, withinMs: within, from: from, to: to)
    }

    private func resolvedLine(_ index: Int, in context: GraphicsContext) -> Line {
        let glimpse = Self.glimpses[index]
        let color: Color = glimpse.live ? .mrtGold : .mrtGlimpseCream
        let text = context.resolve(
            Text(glimpse.text)
                .font(.system(size: 16, weight: .medium)) // FONT = '500 16px'
                .foregroundColor(color)
        )
        let width = text.measure(in: CGSize(width: 10_000, height: 100)).width
        return Line(
            text: text,
            color: color,
            x0: (Self.canvasWidth - width) / 2,
            x1: (Self.canvasWidth + width) / 2
        )
    }

    // ease(): cubic in-out from screens.jsx.
    private func ease(_ u: Double) -> Double {
        u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    /// The reveal edge: -pad → W+pad over the swap window.
    private func edgeX(atMs t: Double) -> Double {
        -Self.pad + (Double(Self.canvasWidth) + Self.pad * 2) * ease(min(t / Self.swapMs, 1))
    }

    private func drawText(_ line: Line, in context: GraphicsContext, clipFrom: Double, to clipTo: Double) {
        guard clipTo > clipFrom else { return }
        var clipped = context
        clipped.clip(to: Path(CGRect(
            x: clipFrom, y: 0,
            width: clipTo - clipFrom, height: Self.canvasHeight
        )))
        let at = CGPoint(x: Self.canvasWidth / 2, y: Self.midY)
        // jsx draws twice: once with shadowBlur 7 @ rgba(color, 0.5) for the
        // glow, once crisp on top. CSS blur halved for SwiftUI sigma.
        clipped.drawLayer { layer in
            layer.addFilter(.shadow(color: line.color.opacity(0.5), radius: 3.5))
            layer.draw(line.text, at: at, anchor: .center)
        }
        clipped.draw(line.text, at: at, anchor: .center)
    }

    // MARK: Particles

    private func drawParticles(
        in context: GraphicsContext,
        cycle: Int,
        withinMs: Double,
        from: Line?,
        to: Line
    ) {
        // spawn window: while the edge crosses the union of both text bounds
        // (±2), 7 particles per ~16 ms frame (screens.jsx frame()/spawn()).
        let lo = min(from?.x0 ?? to.x0, to.x0) - 2
        let hi = max(from?.x1 ?? to.x1, to.x1) + 2
        let firstTick = max(0, Int((withinMs - Self.particleLifeMaxMs) / 16))
        let lastTick = Int(min(withinMs, Self.swapMs) / 16)
        guard lastTick >= firstTick else { return }

        for tick in firstTick...lastTick {
            let spawnMs = Double(tick) * 16
            let age = withinMs - spawnMs
            guard age > 0 else { continue }
            let edge = edgeX(atMs: spawnMs)
            guard edge > lo, edge < hi else { continue }

            var seed = UInt64(bitPattern: Int64(cycle)) &* 0x9E3779B97F4A7C15 &+ UInt64(tick)
            for _ in 0..<7 {
                let jx = (random(&seed) - 0.5) * 4
                let jy = (random(&seed) - 0.5) * 21
                let vx = 0.25 + random(&seed) * 0.8
                let vy = (random(&seed) - 0.5) * 0.6
                let maxLife = 420 + random(&seed) * 320
                guard age < maxLife else { continue }
                // p.x += vx * (fdt/16) per frame ⇒ displacement = v * age/16.
                let x = edge + jx + vx * age / 16
                let y = Self.midY + jy + vy * age / 16
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                    with: .color(to.color.opacity(1 - age / maxLife))
                )
            }
        }
    }

    /// Tiny deterministic PRNG (splitmix-style) → [0, 1).
    private func random(_ seed: inout UInt64) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFF_FFFF) / Double(0x100_0000)
    }
}

#Preview {
    SignInGlimpseLine()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mrtBg)
        .preferredColorScheme(.dark)
}
