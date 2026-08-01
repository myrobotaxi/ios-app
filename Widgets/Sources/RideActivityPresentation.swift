import DesignSystem
import MyRobotaxiContracts
import SwiftUI
import WidgetKit

// MARK: - The rider's ride, as the lock screen and Dynamic Island see it
//
// r16 REDESIGN (MYR-398, CLIENT-DIRECTED with an Uber lock-screen reference):
// *"We need to re-design the live activity bc it doesn't show eta or a line with
// car in relation to pick up or drop off. Looks terrible… use the gold arrow from
// our logo"*. What shipped in MYR-172 was a status kicker and a trip line —
// "MYROBOTAXI · ON THE WAY / Your Tesla → Galleria Dallas" — with no time and no
// picture of where the car was. Somebody standing on a sidewalk is looking for
// exactly those two things.
//
// The card is now three elements, in reading order:
//
//   1. THE HEADLINE — "Pick up in 4:12" on leg one, "Arriving in 9:30" on leg two,
//      counted down on the phone from the contract's absolute `eta`. With no `eta`
//      on the wire it degrades to a status sentence and NEVER to a fabricated
//      number.
//   2. THE SECOND LINE — "Meet at {pickup}" on leg one (off the Activity's STATIC
//      attributes; §7.21.3 deliberately does not push the pickup label), and on
//      leg two MYR-172's own trip line unchanged: the vehicle, a muted arrow, the
//      destination in gold (surfaces.jsx:268-270).
//   3. THE PROGRESS TRACK — the brand's two-tone gold facet arrow travelling a
//      rail from the leg's origin toward its end. Rendered ONLY when the server
//      sent a fraction.
//
// WHAT DECIDES WHAT: nothing in this file. `RideActivityCard.resolve` is the whole
// rule and is unit-tested; these views lay out what it returns. That split is why
// the honesty rules below are assertable at all — a presentation that cannot be
// instantiated in a test cannot be the thing that decides.
//
// THE GLYPH IS THE BRAND MARK, VERBATIM (`ArrowMark`, DesignSystem, ported from
// components.jsx). Not a car, which is what the client ruled out, and not a
// redrawn or re-tinted arrow, which is the MYR-348 hexagon lesson: the moment a
// surface draws its own version of the logo there are two logos. It is also NOT
// ROTATED to point along the rail — the mark has one orientation and giving it a
// second is inventing a variant by another name. It reads as the brand's own puck
// moving along the route, which is what it is.
//
// WHAT THE PORT STILL DROPS. The design's `LiveActivityCard` shows SPEED and
// BATTERY beside a `TripProgressBar` with intermediate stops. None is in the
// content state and none clears MYR-172's bar ("the rider would misread the screen
// without it"): a 4KB, budget-throttled push is not the place for the car's battery
// percentage. The design's flat 50% stale dim is kept for the chrome and
// deliberately NOT applied to the countdown, which is REPLACED — see `StaleNotice`.

// MARK: - Lock screen / banner

struct RideActivityLockScreenView: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            headline
            secondLine
            // NO TRACK AND NO EMPTY RAIL when the server sent no fraction. The
            // `VStack` simply has one fewer child, so the card composes to its own
            // shorter height rather than reserving a rule with nothing on it —
            // which is the difference between "we cannot say where the car is" and
            // "the car is at the start", and the second one is a lie.
            if let track = card.track {
                RideProgressTrack(progress: track, leg: card.leg, isStale: card.isStale)
                    .padding(.top, 2)
            }

            if card.isStale {
                StaleNotice(card: card)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.mrtBg.opacity(0.62))
        .activitySystemActionForegroundColor(Color.mrtGold)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HexLogo(size: 18)

            Text("MyRoboTaxi")
                .mrtTextStyle(.label(size: 10))
                .foregroundStyle(Color.mrtTextSec)
                .lineLimit(1)

            Spacer(minLength: 4)

            // The status word moves OFF the kicker and into a trailing chip. The
            // headline now says what the kicker used to ("Pick up in 4:12" is "on
            // the way" with the answer attached), so repeating it at the top of the
            // card is the stacked chrome MYR-347 was about — but the word still
            // earns a small slot, because it is the only thing that distinguishes
            // `arrived` from `accepted` at a glance once both show a full-ish track.
            // MUTED, NOT GOLD. Gold is the sacred accent and this card now spends
            // it on two things that earn it — the countdown and the track — so a
            // third gold element here would be decorative, which is the one thing
            // the token is never allowed to be.
            Text(RideActivityCopy.kicker(for: card.status))
                .mrtTextStyle(.label(size: 10))
                .foregroundStyle(Color.mrtTextMuted)
                .lineLimit(1)

            // The design's "live" marker (surfaces.jsx:187), gold because the ride
            // is the subject.
            Circle()
                .fill(card.isStale ? Color.mrtTextMuted : Color.mrtGold)
                .frame(width: 6, height: 6)
                .shadow(color: card.isStale ? .clear : Color.mrtGoldGlow, radius: 3)
        }
        .opacity(card.isStale ? 0.5 : 1)
    }

    private var headline: some View {
        RideActivityHeadlineView(
            headline: card.headline,
            countdownSize: 28,
            sentenceSize: 20
        )
    }

    @ViewBuilder
    private var secondLine: some View {
        if let meetAt = card.meetAt {
            Text(meetAt)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .lineLimit(1)
                .opacity(card.isStale ? 0.5 : 1)
        } else if let trip = card.trip {
            // MYR-172's trip line, UNCHANGED — arrow muted, destination gold.
            HStack(spacing: 6) {
                Text(trip.vehicle).foregroundStyle(Color.mrtText)
                Text("→").foregroundStyle(Color.mrtTextMuted)
                Text(trip.destination).foregroundStyle(Color.mrtGold)
            }
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .opacity(card.isStale ? 0.5 : 1)
        }
    }
}

// MARK: - The headline

/// "Pick up in 4:12" / "Arriving in 9:30", or the sentence that stands where a
/// countdown cannot.
///
/// The prefix and the timer are two `Text`s on one line rather than one
/// interpolated string, because `Text(timerInterval:)` is not a value — it is a
/// self-updating view the SYSTEM re-renders on the lock screen with no push and no
/// app process. That is the whole reason §7.21.3 sends an absolute instant instead
/// of "4 min", and interpolating it into a `String` would silently give back the
/// decaying duration the contract refuses.
///
/// It therefore reads "Pick up in 4:12" rather than the design's literal "Pick up
/// in 4 min": a whole-minute figure would be a snapshot that goes wrong the moment
/// it is drawn, and the phone can do better between pushes.
struct RideActivityHeadlineView: View {
    let headline: RideActivityHeadline
    let countdownSize: CGFloat
    let sentenceSize: CGFloat

    var body: some View {
        switch headline {
        case .countdown(let prefix, let until):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(prefix)
                    .font(.system(size: countdownSize * 0.62, weight: .regular))
                    .foregroundStyle(Color.mrtTextSec)
                Text(timerInterval: Date()...until, countsDown: true)
                    .font(.system(size: countdownSize, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtGold)
                    // A timer that has rolled past its instant must not grow the
                    // line and push the card's layout around.
                    .frame(maxWidth: countdownSize * 2.6, alignment: .leading)
            }
            .lineLimit(1)

        case .sentence(let text):
            Text(text)
                .font(.system(size: sentenceSize, weight: .regular))
                .foregroundStyle(Color.mrtText)
                .lineLimit(2)
        }
    }
}

// MARK: - The progress track

/// The rail, and the brand arrow travelling it.
///
/// THE GRAMMAR IS `TripProgressBar`'s (DesignSystem): an `mrtElevated` capsule
/// track, an `mrtGold` travelled portion, and a marker at the fraction. Two
/// deliberate differences, both of them the client's ask or the contract's rule:
///
///   • THE MARKER IS THE BRAND ARROW, not the design's glowing orb. That is what
///     MYR-398 asks for in as many words, and it is `ArrowMark` verbatim.
///   • IT DOES NOT CLAMP AWAY FROM THE ENDS. `TripProgressBar.clamped` floors at
///     0.05 and ceils at 0.95, which is right for an illustration and wrong here:
///     `arrived` and `completed` send exactly `1` on the ride record's authority,
///     and a track that stopped just short would contradict the card's own
///     headline.
///
/// The whole view is rendered ONLY when a fraction exists — the caller decides, so
/// there is no "absent" arm inside here to get backwards.
struct RideProgressTrack: View {
    let progress: Double
    let leg: RideActivityLeg?
    let isStale: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The arrow is drawn at this size and centred on the rail; the rail is inset
    /// by half of it at both ends so the glyph never hangs off the card at 0 or 1.
    private static let glyph: CGFloat = 18
    private static let rail: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let travel = max(0, geo.size.width - Self.glyph)
            let x = Self.glyph / 2 + travel * min(1, max(0, progress))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.mrtElevated)
                    .frame(height: Self.rail)

                Capsule()
                    .fill(Color.mrtGold)
                    .frame(width: x, height: Self.rail)

                ArrowMark(size: Self.glyph, glow: !isStale)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: Self.glyph)
        .opacity(isStale ? 0.5 : 1)
        // REDUCE MOTION → NO TRAVEL. The arrow and the fill are drawn at their new
        // positions with no interpolation; the card still tells the truth, it just
        // does not move to get there. With motion on, the fraction rides
        // `TripProgressBar`'s own curve rather than a second one invented here.
        .animation(reduceMotion ? nil : TripProgressBar.progressAnimation, value: progress)
        // THE LEG IS THE VIEW'S IDENTITY. Leg one ends at exactly 1 and leg two
        // opens near 0, so without this the flip animates a full track collapsing
        // backwards — the one thing a progress arrow must never appear to do. A new
        // identity replaces the view instead, and the new leg's track is simply the
        // new leg's track.
        .id(leg)
        .accessibilityLabel(Text(RideProgressTrack.accessibilityLabel(progress: progress, leg: leg)))
    }

    static func accessibilityLabel(progress: Double, leg: RideActivityLeg?) -> String {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        switch leg {
        case .pickup: return "\(percent)% of the way to your pickup"
        case .dropoff, .none: return "\(percent)% of the way there"
        }
    }
}

// MARK: - Staleness

/// What stands in for the countdown once ActivityKit marks the content stale.
///
/// MYR-194's policy is honest staleness — "never a confident stale ETA". The
/// design's stale card DIMS its ETA (surfaces.jsx:240-241, `opacity: 0.5`), and a
/// dimmed number is still a number: a rider reads "4 min" and plans around it. So
/// the ETA is REPLACED, and the card says what it actually knows.
///
/// THE TRACK IS DIMMED RATHER THAN REMOVED, which is the opposite treatment and is
/// deliberate. A countdown is a claim about the FUTURE and goes wrong on its own as
/// the clock runs; a fraction is a claim about the PAST — the car really was that
/// far along when we last heard — and it does not rot into a different number while
/// nobody is looking. Taking it away would also make staleness look like the
/// server's honest "no fraction to give you" arm, which is a different situation.
struct StaleNotice: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(RideActivityCopy.staleTitle)
                .mrtTextStyle(.label(size: 10))
                .foregroundStyle(Color.mrtTextMuted)

            // The "as of" instant is the ETA's own timestamp when there is one —
            // the last thing the server actually told us — falling back to the
            // system's relative rendering of now. `Text(_:style: .relative)` keeps
            // counting on its own, so the line stays true while the screen is
            // asleep and nothing is repainting it.
            if let reference = card.staleReference {
                Text("As of ") + Text(reference, style: .relative) + Text(" ago")
            } else {
                Text(RideActivityCopy.staleFallbackSubtitle)
            }
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Color.mrtTextSec)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.mrtText.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Dynamic Island pieces

/// COMPACT LEADING — the gold facet arrow, and nothing else.
///
/// MYR-172 put a ring-around-a-dot here (phone-frame.jsx:37-39). The client's ask
/// replaces it with the brand arrow so the compact island reads as "arrow +
/// minutes" — the same two elements the track and the headline carry, at the
/// smallest size the system offers.
struct RideActivityIslandLeading: View {
    let card: RideActivityCard

    var body: some View {
        ArrowMark(size: 16, glow: !card.isStale)
            .accessibilityLabel(RideActivityCopy.kicker(for: card.status))
    }
}

/// COMPACT TRAILING — the minutes.
struct RideActivityIslandTrailing: View {
    let card: RideActivityCard

    var body: some View {
        switch card.headline {
        case .countdown(_, let until):
            // Just the figure. The prefix ("Pick up in") lives on the lock screen
            // and in the expanded island; the compact region is a few dozen points
            // wide and the arrow beside it already says which ride this is.
            Text(timerInterval: Date()...until, countsDown: true)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.mrtGold)
                .frame(maxWidth: 56)

        case .sentence:
            // No number to show. The STATUS WORD takes the slot rather than a dash:
            // in the compact island this is the only text the rider gets, so
            // "Arrived" earns its place where "—" would not.
            Text(RideActivityCopy.kicker(for: card.status))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(card.isStale ? Color.mrtTextMuted : Color.mrtText)
                .lineLimit(1)
        }
    }
}

/// EXPANDED — the lock-screen card's own three elements, at island proportions.
///
/// Deliberately the SAME composition rather than a second design: the expanded
/// island and the lock screen are the same card seen through two windows, and
/// MYR-398's headline + meet-at + track is what the client approved for both.
struct RideActivityIslandExpanded: View {
    let card: RideActivityCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if card.isStale {
                        Text(RideActivityCopy.staleTitle)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.mrtTextSec)
                    } else {
                        RideActivityHeadlineView(
                            headline: card.headline,
                            countdownSize: 26,
                            sentenceSize: 17
                        )
                    }

                    if let second = card.meetAt ?? card.trip.map({ "\($0.vehicle) → \($0.destination)" }) {
                        Text(second)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.mrtTextSec)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            if let track = card.track {
                RideProgressTrack(progress: track, leg: card.leg, isStale: card.isStale)
            }
        }
        .padding(.horizontal, 4)
    }
}
