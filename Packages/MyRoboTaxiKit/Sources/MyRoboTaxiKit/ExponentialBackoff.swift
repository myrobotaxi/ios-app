import Foundation

/// Jittered exponential backoff for WebSocket reconnects (state-machine.md §1.4,
/// websocket-protocol.md §7.1, Rule CG-SM-7): initial **1s**, **2×** multiplier,
/// **30s** cap, **±25%** jitter, unlimited retries by default.
///
/// The jitter source is injectable so the schedule is deterministic in tests.
public struct ExponentialBackoff: Sendable, Equatable {
    public var initialDelay: Double
    public var multiplier: Double
    public var maxDelay: Double
    public var jitterFraction: Double

    public init(
        initialDelay: Double = 1,
        multiplier: Double = 2,
        maxDelay: Double = 30,
        jitterFraction: Double = 0.25
    ) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }

    /// The canonical contract backoff (1s / 2× / 30s / ±25%).
    public static let standard = ExponentialBackoff()

    /// The un-jittered, capped base delay for a 1-based attempt number:
    /// `min(initialDelay × multiplier^(attempt-1), maxDelay)`.
    public func baseDelay(attempt: Int) -> Double {
        precondition(attempt >= 1, "attempt is 1-based")
        let raw = initialDelay * pow(multiplier, Double(attempt - 1))
        return min(raw, maxDelay)
    }

    /// The effective delay including ±jitter, using a supplied unit-random value
    /// in `[0, 1)`. `unit` maps linearly onto `[-jitterFraction, +jitterFraction)`.
    public func delay(attempt: Int, random unit: Double) -> Double {
        let base = baseDelay(attempt: attempt)
        let jitter = base * jitterFraction * (unit * 2 - 1)
        return max(0, base + jitter)
    }

    /// The effective delay with system randomness.
    public func delay(attempt: Int) -> Double {
        delay(attempt: attempt, random: Double.random(in: 0..<1))
    }
}
