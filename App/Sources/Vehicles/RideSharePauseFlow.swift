import Foundation
import SwiftUI
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
// the pre-flight needs a reservation source, and `RootView` composes one only on
// the live path — so off it `source` is `nil` and the pause commits exactly as it
// did before MYR-360. There is no simulated variant, no seeded fixture, and no
// DEBUG-only branch inside the shipping decision.
//
// MYR-369 — the switch this guards is on the SHARE TAB now, not the owner sheet.
// See the commit seam below for what that cost and why the flow itself did not
// have to change.

// MARK: - The commit seam (re-homed by MYR-369's follow-up)
//
// MYR-360 built this flow against `VehicleCommandExecutor`, because that is where
// the switch lived: the last row of the owner sheet's "Status & location" card,
// which commits through `executor.setRideShareEnabled` and reports through the
// executor's own MYR-301 notice lifecycle. MYR-369 MOVED that switch to the top of
// the Share tab, which has no executor at all — it writes §7.18 straight through
// `ShareService` — so the warning stopped firing entirely and the whole feature
// became unreachable.
//
// The fix is to name what the flow ACTUALLY needs, which was never an executor:
// somewhere to commit the flip, and somewhere to say a failure out loud. Both
// surfaces can supply those, in their own idiom — the sheet as an inline control
// notice, the Share tab as its quiet failure toast — and the DECISION, the read,
// the dialog and all three answers stay in exactly one place. The alternative
// (a second copy of this flow for the new call site) is how two surfaces come to
// disagree about whether a rider was stranded.

/// What `RideSharePauseFlow` needs from whichever surface owns the switch.
///
/// Deliberately TWO methods and no more. Anything else the executor happens to
/// offer — the optimistic flip, the echo adoption, the rollback, the pending
/// spinner — is the COMMITTER's business and is already implemented once per
/// surface (`LiveVehicleCommandExecutor.setRideShareEnabled` /
/// `LiveShareService.setVehicleRideShareEnabled`, which follow the same MYR-342
/// rules). Widening this seam to expose them would drag the flow back into being
/// about one surface's mechanics again.
@MainActor
protocol RideSharePauseTarget {
    /// Commit the flip. The committer owns the optimistic move, the echo adoption
    /// and the rollback; this flow only decides WHETHER and WHEN it is called.
    func commitRideShareEnabled(_ enabled: Bool) async throws
    /// Tell the owner something did not happen, in this surface's own grammar.
    func reportPauseFailure(_ failure: RideSharePauseFailure)
}

/// The two ways this flow can fail to do what the owner asked.
///
/// A named pair rather than the raw `VehicleCommandNotice`, because that type is
/// the OWNER SHEET's inline-control vocabulary (it carries a tile sub-label and a
/// bounded 6s display) and the Share tab has neither tiles nor a notice lifecycle.
/// Each surface maps these two to whatever it uses to say so; the copy is
/// asserted to agree on both.
enum RideSharePauseFailure: Equatable {
    /// The pause did not go out — either the pre-flight read did not answer (so
    /// pausing would risk stranding a rider we could not see), or the write
    /// itself refused. Ride sharing is still ON, which the surface must say.
    case rideShareNotSaved
    /// A decline refused part-way, so the pause was abandoned rather than
    /// stranding exactly the rider this flow exists to protect. Some declines
    /// already landed and are irreversible.
    case reservationNotDeclined
}

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
    /// How many reservations get a ROW of their own before the list rolls up into a
    /// count.
    ///
    /// THREE, measured rather than guessed (`RideSharePauseCopyTests`). Each row is
    /// a two-line block — "Sat, Aug 1 · 5:30 PM" over the rider's first name — laid
    /// out against the 260pt the 300pt card leaves inside its 20pt padding, and
    /// neither line wraps at that width for any date, time or first name the server
    /// emits. Three rows plus a rollup still leaves the card comfortably inside the
    /// shortest supported screen with a 46pt icon, a title, the consequence
    /// sentence and THREE buttons under it. A fourth name is not the difference
    /// between an informed decision and an uninformed one, and a confirm dialog
    /// that scrolls is one nobody finishes.
    static let displayCap = 3

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

    /// What a reservation the server could not name is called.
    ///
    /// NOT `IncomingRequestDisplay.neutralRole` ("Shared viewer"), which is an
    /// INTERNAL role term — it names the person's relationship to the vehicle, which
    /// is not what an owner reading a list of pickups is trying to learn, and it
    /// reads as jargon on a surface that is otherwise plain English. "A rider" is
    /// the honest fallback and keeps the no-fabricated-name rule intact: it is never
    /// an invented name and never an initial.
    ///
    /// MYR-355 — and NOT the new "Former rider" either. That stand-in is
    /// load-bearing on the incoming card, where an absent live `requesterName`
    /// means the account was deleted; here it would tell the owner this pickup no
    /// longer has a passenger, which if true means the row should be gone rather
    /// than relabelled. See `UpcomingReservations.reservation(from:)`.
    static let unnamedRider = "A rider"

    /// The recommended action, pluralised. It says both halves of what it does, in
    /// the order it does them.
    static func actionLabel(count: Int) -> String {
        count > 1 ? "Decline them and pause" : "Decline it and pause"
    }

    /// A row's PRIMARY line: "Sat, Aug 1 · 5:30 PM".
    ///
    /// The stamp is `VehicleServiceWindow.completionLabel`, the app's ONE producer
    /// of the "EEE, MMM d · h:mm a" form (already pinned to `en_US_POSIX`). A second
    /// formatter for a second surface is how two owner surfaces start disagreeing
    /// about the same instant.
    ///
    /// Its same-calendar-day branch returns the TIME ALONE ("5:30 PM"), which is
    /// correct where it ships (a line already captioned "Service Estimated
    /// Completion") and ambiguous here, where a bare clock in a list of dates reads
    /// as an omission. A reservation later TODAY is a real and likely case — an
    /// owner pausing this afternoon over a ride booked this evening is the sharpest
    /// version of this whole defect — so the day word is supplied around the shared
    /// stamp instead of forking the formatter.
    static func rowTime(
        for reservation: UpcomingReservation,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let stamp = VehicleServiceWindow.completionLabel(
            for: reservation.scheduledFor,
            now: now,
            calendar: calendar
        ) ?? ""
        return calendar.isDate(reservation.scheduledFor, inSameDayAs: now)
            ? "Today \u{00B7} \(stamp)"
            : stamp
    }

    /// A row's SECONDARY line: the rider's first name, or the honest fallback.
    static func rowRider(for reservation: UpcomingReservation) -> String {
        reservation.riderFirstName ?? unnamedRider
    }

    /// The rollup row for everything past the cap, or `nil` when nothing is hidden.
    /// The owner is told the SIZE of what they are deciding about even where the
    /// dialog has no room to name it.
    static func overflowLabel(for reservations: [UpcomingReservation]) -> String? {
        let hidden = reservations.count - min(reservations.count, displayCap)
        return hidden > 0 ? "+\(hidden) more" : nil
    }

    /// The message body — one sentence now that the reservations have their own
    /// rows.
    ///
    /// It states the server's ACTUAL behaviour (hold, then expire 30 minutes after
    /// the pickup) rather than "the ride will be cancelled", which is not what
    /// happens and would make "Pause anyway" look harmless. "Paused rides" is what
    /// keeps it true in both directions: an owner who resumes before the pickup
    /// strands nobody, and the sentence does not claim otherwise.
    static let message = "Paused rides won\u{2019}t be dispatched \u{2014} they expire 30 minutes after pickup time."

    /// The whole dialog. Destructive: the confirm button declines somebody's ride.
    ///
    /// The reservations do NOT appear here — they are rows in the dialog's content
    /// slot (`RideSharePauseReservationList`), because a list flattened into a
    /// centred body sentence stops being a list. The count still reaches this
    /// factory, for the one thing the copy needs it for: pluralising the confirm
    /// label.
    static func warning(
        count: Int,
        onDeclineAndPause: @escaping () -> Void,
        onPauseAnyway: @escaping () -> Void
    ) -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: icon,
            title: title,
            message: message,
            actionLabel: actionLabel(count: count),
            secondaryLabel: secondaryLabel,
            secondaryAction: onPauseAnyway,
            dismissLabel: dismissLabel,
            action: onDeclineAndPause
        )
    }
}

// MARK: - The reservation rows
//
// The client's verdict on the first build, which listed the reservations as
// centred prose lines inside the dialog's message: *"list in plain text is not
// helpful."* He is right — a list is a list because its parts line up, and centred
// sentences do not.
//
// So the reservations render as ROWS in the dialog's content slot, in the app's
// EXISTING row grammar rather than a new one invented for this surface: the
// `ViewerRow`/`PendingRow` shape (a leading glyph, a 14/medium primary line over an
// 11pt muted secondary, `Spacer` to the trailing edge) separated by the standard
// `Color.mrtBorder` hairline. Only the horizontal padding differs, because these
// sit inside a 300pt dialog card rather than against the 24pt page gutter.

struct RideSharePauseReservationList: View {
    let reservations: [UpcomingReservation]
    var now: Date = Date()
    var calendar: Calendar = .current

    private var visible: [UpcomingReservation] {
        Array(reservations.prefix(RideSharePauseDialog.displayCap))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, reservation in
                if index > 0 { hairline }
                row(
                    glyph: "calendar",
                    primary: RideSharePauseDialog.rowTime(for: reservation, now: now, calendar: calendar),
                    secondary: RideSharePauseDialog.rowRider(for: reservation)
                )
            }
            if let overflow = RideSharePauseDialog.overflowLabel(for: reservations) {
                hairline
                // The rollup is a ROW too, not a caption: it is one more thing in the
                // list, and giving it a different shape would read as a footnote
                // about the list rather than a part of it. Muted throughout, because
                // it names a quantity rather than a pickup.
                HStack(spacing: 12) {
                    Text(overflow)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextMuted)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.mrtBorder)
            .frame(height: MRTMetrics.hairline)
    }

    private func row(glyph: String, primary: String, secondary: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mrtTextMuted)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                Text(secondary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
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

    /// The committer the presented warning belongs to. Held rather than re-derived
    /// so an answer cannot land on a different car than the question was asked
    /// about — on the owner sheet the owner can switch vehicles while a dialog is
    /// up, and on the Share tab the card renders ONE ROW PER OWNED VEHICLE, so a
    /// re-derived target could commit against the wrong row outright.
    private var target: (any RideSharePauseTarget)?

    init(source: (any UpcomingReservationSource)? = nil) {
        self.source = source
    }

    // MARK: Entry

    /// The ONE entry point the toggle calls. Only the OFF direction is changed;
    /// everything else commits exactly as it did before this issue.
    func setEnabled(_ enabled: Bool, vehicleID: String, target: any RideSharePauseTarget) async {
        // RESUMING is never questioned. Turning ride sharing back ON cannot strand
        // anyone — it is the recovery from this whole situation — so it never
        // reads, never dialogs, and never waits.
        guard !enabled else {
            await commit(enabled: true, target: target)
            return
        }
        // No seam at all is NOT the same as a seam that failed. `source` is `nil`
        // only where the feature was never composed — the simulated path and the
        // capture scenes, neither of which has a rider, a reservation or a server
        // to strand one on. Pausing there is the pre-MYR-360 behaviour, and keeping
        // it is what leaves every simulated Share-tab scene byte-identical.
        guard let source else {
            await commit(enabled: false, target: target)
            return
        }

        let read: Result<[UpcomingReservation], Error>
        do { read = .success(try await source.upcomingReservations(vehicleID: vehicleID)) }
        catch { read = .failure(error) }

        switch RideSharePause.decide(read) {
        case .pause:
            await commit(enabled: false, target: target)
        case .warn(let reservations):
            self.target = target
            warning = Warning(vehicleID: vehicleID, reservations: reservations)
        case .blocked:
            // Nothing is committed and nothing is claimed: the switch never moved
            // (the optimistic flip lives inside the committer's own write, which
            // was never called), so the row is still ON and the message explains
            // why. `.rideShareNotSaved` is exactly right and needs no new case —
            // its sentence is "Couldn't change ride sharing", which is the true
            // and complete account of what just happened.
            target.reportPauseFailure(.rideShareNotSaved)
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
        guard let warning, let committer = target, let source else { return }
        self.warning = nil

        for reservation in warning.reservations {
            do {
                try await source.decline(reservationID: reservation.id)
            } catch {
                target = nil
                committer.reportPauseFailure(.reservationNotDeclined)
                return
            }
        }
        target = nil
        await commit(enabled: false, target: committer)
    }

    /// "Pause anyway" — the pause PUT exactly as it fires today. The reservations
    /// are left alone: the server's hold-then-expire backstop still covers them,
    /// and an owner who resumes before the pickup strands nobody at all.
    func pauseAnyway() async {
        guard warning != nil, let committer = target else { return }
        warning = nil
        target = nil
        await commit(enabled: false, target: committer)
    }

    /// "Keep sharing" — no PUT, no declines, nothing written. The toggle returns to
    /// ON by itself and there is no position to restore: the optimistic flip lives
    /// inside the committer's own write, which this path never calls, so the row
    /// has been rendering the committed ON value the entire time the dialog was up.
    func keepSharing() {
        warning = nil
        target = nil
    }

    // MARK: Commit

    /// The write, untouched: the COMMITTER still owns the optimistic flip, the echo
    /// adoption, the rollback and the failure message (MYR-342). Swallowing the
    /// error here is not a shrug — the committer has already surfaced it in its own
    /// surface's grammar, and re-raising it from the flow would say it twice.
    private func commit(enabled: Bool, target: any RideSharePauseTarget) async {
        try? await target.commitRideShareEnabled(enabled)
    }
}

// MARK: - The Share tab's binding (MYR-369)

/// Commits a §7.18 flip through `ShareService` and reports failures as the Share
/// tab's own quiet toast.
///
/// It is bound to ONE vehicle id, which is the whole reason it exists as a value
/// rather than as two closures on the screen: the relocated card renders one row
/// per owned vehicle, so "which car is this dialog about" has to travel WITH the
/// commit target. `RideSharePauseFlow` holds it for the life of the warning, so an
/// owner who opens the dialog on one car cannot have the answer land on another.
///
/// **A TOAST, NOT A DIALOG.** That is how this screen already surfaces every other
/// mutation failure (`InvitesScreen.mutate`), and a second grammar for this one
/// write would make the failure look like a different kind of event than the
/// per-viewer switch failures sitting inches above it.
@MainActor
struct ShareServiceRideSharePauseTarget: RideSharePauseTarget {
    let service: any ShareService
    let vehicleID: String
    /// Where a failure sentence goes — `InvitesScreen`'s `failureToast`.
    let onFailure: (String) -> Void

    /// The write, with the SERVICE owning the optimistic flip, the echo adoption
    /// and the rollback exactly as it does for a flip that never went near this
    /// flow. The failure is surfaced here rather than rethrown to the flow, which
    /// deliberately swallows it — see `RideSharePauseFlow.commit`.
    func commitRideShareEnabled(_ enabled: Bool) async throws {
        do {
            try await service.setVehicleRideShareEnabled(enabled, vehicleID: vehicleID)
        } catch {
            onFailure(RideSharePauseFailure.rideShareNotSaved.shareTabMessage)
        }
    }

    func reportPauseFailure(_ failure: RideSharePauseFailure) {
        onFailure(failure.shareTabMessage)
    }
}

extension RideSharePauseFailure {
    /// The Share tab's sentence for each failure.
    ///
    /// Held to `VehicleCommandNotice`'s own copy for the same two cases, so the
    /// owner reads the SAME sentence whichever surface the switch was on — pinned
    /// by test rather than left to a comment, because two independent copies of one
    /// sentence is exactly how a relocated control starts saying something new.
    var shareTabMessage: String {
        switch self {
        case .rideShareNotSaved: VehicleCommandNotice.rideShareNotSaved.message
        case .reservationNotDeclined: VehicleCommandNotice.reservationNotDeclined.message
        }
    }
}
