import Foundation

// MARK: - BatteryReadout (MYR-204, deliverable 4 — battery display guard)
//
// The Drive Summary Battery tile shows "start% → end%" and a "used" figure.
// A LIVE drive can arrive with `startChargeLevel = 0` (backend bug MYR-207),
// which the naive math turns into nonsense: "0% → 75% / -75% used". This value
// type is the single guard: when the start reading is not trustworthy, the
// start and "used" figures render as a design-neutral em dash ("—") while the
// real end reading is kept.
//
// A reading is trustworthy only when `start > 0` AND `start >= end` (a battery
// is consumed over a drive, so start should be at or above end). `start <= 0`
// (the MYR-207 zero) or `start < end` (charging/garbage) → the start & used
// figures are unknowable, so they degrade to "—". Pure + unit-tested.
//
// Sim fixtures always have a seeded start ≥ 76 and a NEGATIVE delta (end <
// start), so they are always trustworthy → the simulated tile is byte-for-byte
// unchanged.
struct BatteryReadout: Equatable {
    /// Placeholder shown for an untrustworthy start / used figure.
    static let dash = "—"

    let isStartKnown: Bool
    /// "76" — or "—" when the start is untrustworthy.
    let startText: String
    /// The end reading, always real (e.g. "75").
    let endText: String
    /// "18% used" — or "— used" when the start (hence the delta) is untrustworthy.
    let usedText: String
    /// The start fraction (0…1) for the meter fill + START marker; 0 (and the
    /// marker suppressed) when the start is untrustworthy.
    let startFraction: Double
    /// The end fraction (0…1) for the meter fill.
    let endFraction: Double

    init(usedPercent: Int, startPercent: Int, endPercent: Int) {
        let trustworthy = startPercent > 0 && startPercent >= endPercent
        self.isStartKnown = trustworthy
        self.endText = "\(endPercent)"
        self.endFraction = Double(max(0, min(100, endPercent))) / 100
        if trustworthy {
            self.startText = "\(startPercent)"
            self.usedText = "\(usedPercent)% used"
            self.startFraction = Double(max(0, min(100, startPercent))) / 100
        } else {
            self.startText = Self.dash
            self.usedText = "\(Self.dash) used"
            self.startFraction = 0
        }
    }
}
