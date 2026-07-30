import Foundation
import DesignSystem

// MARK: - Pausing ride sharing over a reservation (MYR-360)
//
// THE CLIENT-CONFIRMED DEFECT. An owner pauses ride sharing while an ACCEPTED
// FUTURE RESERVATION sits on that car. The server holds the reservation at due
// time and expires it 30 minutes later, so the rider finds out nobody is coming
// half an hour AFTER the pickup they planned around. Every party behaved
// correctly and the outcome is still the worst one available.
//
// The fix is on the common path and nowhere else: before the pause PUT goes out,
// ask what is booked; if anything is, say so and offer the owner the decline they
// would otherwise have to go find. NOTHING here changes the zero-reservation case
// (which is nearly every pause), the resume direction, or the simulated path.
//
// THE WHOLE FEATURE IS LIVE-ONLY, and that is correct rather than a limitation:
// `HomeScreen.resolvedRideShare` already returns `nil` off the live path, so the
// toggle itself does not exist there. There is no simulated variant, no seeded
// fixture, and no DEBUG-only branch inside the shipping decision.

// MARK: - The decision

/// What to do when an owner asks to pause, given what we could learn about the
/// car's reservations. A three-way answer, because "we could not find out" is
/// genuinely not "there are none" (MYR-326's loading ≠ unavailable, applied to a
/// write's precondition).
enum RideSharePauseDecision: Equatable {
    /// Nothing is booked — pause immediately, exactly as before this issue. No
    /// dialog, no extra step, no perceptible latency beyond the read itself.
    case pause
    /// One or more reservations — present the warning instead of pausing.
    case warn([UpcomingReservation])
    /// The read did not answer. Do NOT pause, and say so.
    ///
    /// THE DELIBERATE CHOICE, and the direction is not symmetric. Pausing on an
    /// unknown list risks the exact harm this issue exists to prevent — a stranded
    /// rider, discovered 30 minutes late, unrecoverable. Refusing to pause risks
    /// the owner tapping again in a moment. One of those is repairable by the
    /// person who hit it and the other is not, so the unknown resolves to the
    /// honest notice rather than to a guess. This also keeps the client's rule
    /// that a live surface with no answer states that plainly instead of
    /// borrowing another state's rendering.
    case blocked
}

enum RideSharePause {
    /// The rule above, as a pure function, so it is testable without a flow, a
    /// view or a clock.
    static func decide(_ read: Result<[UpcomingReservation], Error>) -> RideSharePauseDecision {
        switch read {
        case .success(let reservations): return reservations.isEmpty ? .pause : .warn(reservations)
        case .failure: return .blocked
        }
    }
}

// MARK: - The dialog copy
//
// A static factory returning a `MRTConfirmDialogConfig`, following the
// `ShareDialogs` pattern (`App/Sources/Screens/Invites/ShareFixtures.swift`) —
// copy lives next to copy and never inline in a view, so it can be read, reviewed
// and MEASURED on its own. It is NOT added to `ShareDialogs` itself: that type
// lives in a fixtures file, and MYR-228 keeps live-path copy out of fixture files.

enum RideSharePauseDialog {
    /// How many reservations are LISTED before the message rolls up into a count.
    ///
    /// TWO, measured rather than guessed (`RideSharePauseCopyTests`). The message is
    /// a `Text` inside a 300pt card with 20pt padding, so every line lays out against
    /// 260pt — and the longest honest line, a nameless reservation on a
    /// two-digit-date weekday ("Pickup Wed, Sep 24 · 11:45 AM — Shared viewer"),
    /// WRAPS at that width. So a listed reservation is worth up to two rendered
    /// lines, not one, and the card also has to carry a 46pt icon, a title, a
    /// consequence sentence and now THREE buttons on the shortest supported screen.
    /// Two named reservations plus a rollup is what fits with real headroom; the
    /// third name is not the difference between an informed decision and an
    /// uninformed one, and a confirm dialog that scrolls is one nobody finishes.
    static let displayCap = 2

    static let title = "Pause ride sharing?"
    /// The same SF Symbol family the other dialog factories draw from
    /// (`person.fill` / `envelope.fill` / `paperplane.fill`) — a calendar, because
    /// the subject of the sentence is a booking, and the badge because the point is
    /// that the booking is about to be affected.
    static let icon = "calendar.badge.exclamationmark"
    /// The way out. Names what STAYS true rather than "Cancel" — the same grammar
    /// as "Keep access" / "Keep invite".
    static let dismissLabel = "Keep sharing"
    /// The alternative the server's own hold-then-expire backstop still covers.
    /// Offered plainly, because an owner pausing for a reason of their own is
    /// entitled to, and the warning has already said what it costs.
    static let secondaryLabel = "Pause anyway"

    /// The recommended action, pluralised. It says both halves of what it does, in
    /// the order it does them.
    static func actionLabel(count: Int) -> String {
        count > 1 ? "Decline them and pause" : "Decline it and pause"
    }

    /// One reservation's line: "Pickup Sat, Aug 2 · 5:30 PM — Alex".
    ///
    /// The date/time is `VehicleServiceWindow.completionLabel`, the app's ONE
    /// producer of the "EEE, MMM d · h:mm a" stamp (already pinned to
    /// `en_US_POSIX`). A second formatter for a second surface is how two owner
    /// surfaces start disagreeing about the same instant.
    ///
    /// Its same-calendar-day branch returns the TIME ALONE ("5:30 PM"), which is
    /// correct where it ships (a line already captioned "Service Estimated
    /// Completion") and ambiguous here, where a bare clock reads as a duration.
    /// A reservation later TODAY is a real and likely case — an owner pausing this
    /// afternoon over a ride booked this evening is the sharpest version of this
    /// whole defect — so the day word is supplied instead of a second formatter.
    static func line(
        for reservation: UpcomingReservation,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let stamp = VehicleServiceWindow.completionLabel(
            for: reservation.scheduledFor,
            now: now,
            calendar: calendar
        ) ?? ""
        let when = calendar.isDate(reservation.scheduledFor, inSameDayAs: now)
            ? "today \u{00B7} \(stamp)"
            : stamp
        return "Pickup \(when) \u{2014} \(reservation.riderLabel)"
    }

    /// The consequence sentence, in plural agreement with what was listed. It
    /// states the server's ACTUAL behaviour — hold, then expire 30 minutes after
    /// the pickup — rather than "the ride will be cancelled", which is not what
    /// happens and would make "Pause anyway" look harmless.
    ///
    /// "If you pause and leave it paused" is load-bearing: an owner who resumes
    /// before the pickup strands nobody, and the sentence must not claim otherwise.
    static func consequence(count: Int) -> String {
        count > 1
            ? "If you pause and leave it paused, these rides won\u{2019}t be dispatched. They expire 30 minutes after the pickup time."
            : "If you pause and leave it paused, this ride won\u{2019}t be dispatched. It expires 30 minutes after the pickup time."
    }

    /// The full message: the reservations, soonest first, capped, then the
    /// consequence. Beyond the cap a "+N more" line stands for the remainder — the
    /// owner is told the size of what they are deciding about even where the dialog
    /// has no room to name it.
    static func message(
        for reservations: [UpcomingReservation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var lines = reservations.prefix(displayCap).map { line(for: $0, now: now, calendar: calendar) }
        let hidden = reservations.count - min(reservations.count, displayCap)
        if hidden > 0 { lines.append("+\(hidden) more") }
        return lines.joined(separator: "\n") + "\n\n" + consequence(count: reservations.count)
    }

    /// The whole dialog. Destructive: the confirm button declines somebody's ride.
    static func warning(
        reservations: [UpcomingReservation],
        now: Date = Date(),
        calendar: Calendar = .current,
        onDeclineAndPause: @escaping () -> Void,
        onPauseAnyway: @escaping () -> Void
    ) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: icon,
            title: title,
            message: message(for: reservations, now: now, calendar: calendar),
            actionLabel: actionLabel(count: reservations.count),
            secondaryLabel: secondaryLabel,
            secondaryAction: onPauseAnyway,
            dismissLabel: dismissLabel,
            action: onDeclineAndPause
        )
    }
}

// MARK: - The flow

/// Owns the pause interaction end to end: the read, the decision, the presented
/// warning, and each of the three answers.
///
/// It is a small `@Observable` object rather than `HomeScreen` state because every
/// assertion worth making here is about the WIRE — which ids were declined, in what
/// order, and whether the pause PUT went out at all — and none of it should need a
/// view to run. `HomeScreen` keeps exactly one job: hand it the toggle's value and
/// render `warning`.
@MainActor
@Observable
final class RideSharePauseFlow {

    /// The presented warning, or `nil`. Carries the reservations it was built from,
    /// so the confirm path declines the LIST THE OWNER WAS SHOWN (including the
    /// rows past the display cap) rather than re-reading and racing itself.
    struct Warning: Equatable {
        let vehicleID: String
        let reservations: [UpcomingReservation]
    }

    private(set) var warning: Warning?

    /// The reservation seam. `nil` off the live path — see `setEnabled(_:vehicleID:executor:)` for what
    /// that case does and why it is not the `blocked` case.
    var source: (any UpcomingReservationSource)?

    /// The executor the presented warning belongs to. Held rather than re-derived
    /// so an answer cannot land on a different car than the question was asked
    /// about (the owner can switch vehicles while a dialog is up).
    private var target: (any VehicleCommandExecutor)?

    init(source: (any UpcomingReservationSource)? = nil) {
        self.source = source
    }

    // MARK: Entry

    /// The ONE entry point the toggle calls. Only the OFF direction is changed;
    /// everything else commits exactly as it did before this issue.
    func setEnabled(_ enabled: Bool, vehicleID: String, executor: any VehicleCommandExecutor) async {
        // RESUMING is never questioned. Turning ride sharing back ON cannot strand
        // anyone — it is the recovery from this whole situation — so it never
        // reads, never dialogs, and never waits.
        guard !enabled else {
            await commit(enabled: true, executor: executor)
            return
        }
        // No seam at all is NOT the same as a seam that failed. `source` is `nil`
        // only where the feature was never composed — the simulated path and the
        // MYR-342 capture scenes, neither of which has a rider, a reservation or a
        // server to strand one on. Pausing there is the pre-MYR-360 behaviour, and
        // keeping it is what leaves those scenes byte-identical.
        guard let source else {
            await commit(enabled: false, executor: executor)
            return
        }

        let read: Result<[UpcomingReservation], Error>
        do { read = .success(try await source.upcomingReservations(vehicleID: vehicleID)) }
        catch { read = .failure(error) }

        switch RideSharePause.decide(read) {
        case .pause:
            await commit(enabled: false, executor: executor)
        case .warn(let reservations):
            target = executor
            warning = Warning(vehicleID: vehicleID, reservations: reservations)
        case .blocked:
            // Nothing is committed and nothing is claimed: the switch never moved
            // (the optimistic flip lives inside `setRideShareEnabled`, which was
            // never called), so the row is still ON and the notice explains why.
            // `.rideShareNotSaved` is exactly right and needs no new case — its
            // sentence is "Couldn't change ride sharing", which is the true and
            // complete account of what just happened.
            executor.raiseNotice(.rideShareNotSaved, for: .rideShare)
        }
    }

    // MARK: The three answers

    /// "Decline it and pause" — decline EVERY reservation the owner was shown,
    /// including any past the display cap, then pause.
    ///
    /// ON ANY DECLINE FAILURE, DO NOT PAUSE. Pausing after a failed decline strands
    /// exactly the rider this flow exists to protect, and does it having already
    /// told the owner the opposite. The successful declines are irreversible, so
    /// the honest resting state is: ride sharing still ON, some reservations
    /// declined, a notice saying the rest did not go through. The owner can flip
    /// again — and the second attempt reads a shorter list, because the declines
    /// that did land are gone from it.
    func confirmDeclineAndPause() async {
        guard let warning, let executor = target, let source else { return }
        self.warning = nil

        for reservation in warning.reservations {
            do {
                try await source.decline(reservationID: reservation.id)
            } catch {
                target = nil
                executor.raiseNotice(.reservationNotDeclined, for: .rideShare)
                return
            }
        }
        target = nil
        await commit(enabled: false, executor: executor)
    }

    /// "Pause anyway" — the pause PUT exactly as it fires today. The reservations
    /// are left alone: the server's hold-then-expire backstop still covers them,
    /// and an owner who resumes before the pickup strands nobody at all.
    func pauseAnyway() async {
        guard warning != nil, let executor = target else { return }
        warning = nil
        target = nil
        await commit(enabled: false, executor: executor)
    }

    /// "Keep sharing" — no PUT, no declines, nothing written. The toggle returns to
    /// ON by itself and there is no position to restore: the optimistic flip lives
    /// inside `setRideShareEnabled`, which this path never calls, so the row has
    /// been rendering the committed ON value the entire time the dialog was up.
    func keepSharing() {
        warning = nil
        target = nil
    }

    // MARK: Commit

    /// The write, untouched: the executor still owns the optimistic flip, the echo
    /// adoption, the rollback and the `.rideShareNotSaved` notice (MYR-342).
    private func commit(enabled: Bool, executor: any VehicleCommandExecutor) async {
        try? await executor.setRideShareEnabled(enabled)
    }
}
