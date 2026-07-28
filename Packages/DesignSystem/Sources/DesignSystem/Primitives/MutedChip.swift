import SwiftUI

// MARK: - Muted status chip (MYR-233 recipe, extracted MYR-317)
//
// The app's ONE deliberately-quiet capsule chip: a trailing marker on a row
// that states a fact the user cannot act on (a vehicle is Busy / In service /
// Offline — MYR-233; more incoming requests are queued behind the current card
// — MYR-317).
//
// Recipe fixed by MYR-233 (`RideHistoryScreen`'s "Pending" status chip):
// `mrtRidePendingChipFill` = rgba(255,255,255,0.07) capsule, secondary label,
// optional muted 5pt dot. Explicitly NO gold — gold is the sacred "actionable
// moment" accent (CLAUDE.md), and every consumer of this chip is precisely the
// ABSENCE of an action. Built once here rather than re-typed per screen so the
// two consumers can never drift into two chip languages.
public struct MRTMutedChip: View {
    private let text: String
    private let showsDot: Bool

    /// - Parameters:
    ///   - text: the chip label, already in its display casing (this chip does
    ///     not uppercase — the MYR-233 chip reads "Busy", not "BUSY").
    ///   - showsDot: leading 5pt muted dot (MYR-233's availability chip). Count
    ///     chips (MYR-317) omit it — there is no state to indicate, only a number.
    public init(_ text: String, showsDot: Bool = false) {
        self.text = text
        self.showsDot = showsDot
    }

    public var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(Color.mrtTextMuted).frame(width: 5, height: 5)
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.mrtTextSec)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(Color.mrtRidePendingChipFill, in: Capsule())
    }
}

#Preview {
    VStack(spacing: 12) {
        MRTMutedChip("Busy", showsDot: true)
        MRTMutedChip("In service", showsDot: true)
        MRTMutedChip("+2 more waiting")
    }
    .padding()
    .background(Color.mrtBg)
    .preferredColorScheme(.dark)
}
