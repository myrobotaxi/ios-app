import Foundation

// MARK: - VehicleServiceWindow (MYR-316)
//
// The PURE decision layer for the service window — the single nullable instant
// `serviceEstimatedEndAt` (contracts 0.17.0), which says when the car's current
// service visit is estimated to END. Three consumers, three rules, all here so
// each is unit-testable without a view, a network, or a wall clock:
//
//   1. THE OWNER'S DISPLAY — "Estimated completion · <time>", beneath the In
//      Service badge on the owner sheet.
//   2. THE OWNER'S ENTRY — is the instant they picked actually valid (future)?
//      The server owns this rule; we mirror it so the owner gets an immediate
//      local answer instead of a round trip to be told no.
//   3. THE RIDER'S SCHEDULING FLOOR — the earliest instant a ride may be booked
//      against a car that is in service, plus a small buffer, and the muted
//      caption that explains why the early slots are gone.
//
// THE HONESTY RULE THAT GOVERNS ALL THREE: `nil` means NO WINDOW IS KNOWN, and
// that is the COMMON case — Tesla returns an all-null `service_data` body for
// any visit with no appointment record. So `nil` NEVER produces a display line,
// NEVER blocks a schedule slot, and NEVER means "we couldn't read it". The
// contract states this as a consumer rule in as many words: "when the field is
// ABSENT or NULL there is NO BOUND and scheduling stays fully open — consumers
// MUST NEVER block or gate scheduling on missing data."
//
// Every function takes an injected `now`/`calendar` (the
// `DriveContractMapping.dateGroup(…, now:)` precedent) so the matrices are
// deterministic under test and correct at runtime, where the defaults are the
// device's own clock and time zone.

public enum VehicleServiceWindow {

    // MARK: - 1. Owner display

    /// The owner-facing completion time, or `nil` when nothing honest can be said.
    ///
    /// Two shapes, because a bare "7:09 PM" is ambiguous the moment the estimate
    /// isn't today — and a service visit routinely spans days:
    ///   • SAME calendar day  → `"7:09 PM"`
    ///   • ANY other day      → `"Sat, Aug 2 \u{00B7} 7:09 PM"`
    ///
    /// MYR-320, client-directed, two changes from the MYR-316 shape:
    ///
    /// 1. NO TILDE. The `~` was meant to mark this as an estimate rather than a
    ///    commitment, but in front of a wall-clock time it read as noise at best
    ///    and as a typo at worst — and the word "Estimated" in the label beside it
    ///    already carries that meaning, in language, where it is unambiguous. A
    ///    glyph the copy does not need is a glyph that makes the copy look broken.
    ///    ``containsApproximationGlyph(_:)`` is the tripwire that keeps it gone.
    /// 2. A REAL DATE, not a bare weekday. "Sat" alone is only unambiguous inside
    ///    a seven-day horizon and silently wraps outside one — a visit estimated
    ///    for the Saturday after next reads as this Saturday. "Sat, Aug 2" keeps
    ///    the weekday (which is what an owner actually plans around) and adds the
    ///    date that makes it verifiable.
    ///
    /// The two halves are joined by the SAME `\u{00B7}` separator the label uses,
    /// so the whole line reads as one consistently punctuated series rather than
    /// mixing separators at different levels.
    public static func completionLabel(
        for end: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let end else { return nil }
        let time = timeFormatter(calendar: calendar).string(from: end)
        guard !calendar.isDate(end, inSameDayAs: now) else { return time }
        return "\(dateFormatter(calendar: calendar).string(from: end)) \u{00B7} \(time)"
    }

    /// The label the owner's completion line leads with (MYR-320, client-directed).
    ///
    /// Says all three things the line needs to say before the value: that this is
    /// about SERVICE, that it is an ESTIMATE, and that it is a COMPLETION time.
    /// The MYR-316 line said only "Estimated completion", which left "estimated
    /// completion of WHAT" to be inferred from a badge sitting on the row above.
    public static let completionLabelPrefix = "Service Estimated Completion"

    /// The approved COMPACT variant of ``completionLabelPrefix``, kept here rather
    /// than in a view so the choice between the two is a stated decision with a
    /// measurable test behind it instead of a per-surface guess.
    ///
    /// NOT SHIPPED on the owner hero: the full prefix measures ~296pt at the hero's
    /// 12pt (~274pt at 11pt) against a 345pt peek content width — see
    /// `VehicleServiceWindowTests.testCompletionLineFitsThePeekWidthAtTheHeroTypeScale`,
    /// which measures the WORST-CASE date/time rather than a convenient example.
    /// It is retained because that headroom is a measurement, not a guarantee: a
    /// surface with a narrower content box (or a future longer prefix) has an
    /// approved shortening to reach for rather than an invented one.
    public static let compactCompletionLabelPrefix = "Est. Completion"

    /// The full line the owner sheet renders beneath the In Service badge, or
    /// `nil` to render NOTHING (honest absence — no "unknown", no placeholder).
    ///
    /// "Service Estimated Completion \u{00B7} Sat, Aug 2 \u{00B7} 7:09 PM", or
    /// "Service Estimated Completion \u{00B7} 7:09 PM" when the estimate is today.
    /// LABEL + VALUE: the line names what it is before it states a number, which is
    /// what lets it stand alone if the badge above it ever scrolls away.
    ///
    /// Gated on the status as well as the value: the contract clears the field
    /// automatically when the car leaves `in_service`, but a client that had
    /// already read a value and then saw a parked status would otherwise keep a
    /// completion time on screen for a car that is demonstrably back. Requiring
    /// BOTH makes that unrepresentable rather than merely unlikely.
    public static func completionLine(
        for end: Date?,
        isInService: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        compact: Bool = false
    ) -> String? {
        guard isInService, let label = completionLabel(for: end, now: now, calendar: calendar) else { return nil }
        return "\(compact ? compactCompletionLabelPrefix : completionLabelPrefix) \u{00B7} \(label)"
    }

    /// Whether a string carries the approximation glyph this issue removed.
    ///
    /// Exists so "no tilde ANYWHERE" is an assertable property of every formatter
    /// output rather than a promise scattered across doc comments — the MYR-320
    /// tests run the whole date matrix through it. Both the ASCII `~` and the
    /// typographic `\u{2248}` count: reintroducing the idea in a prettier glyph
    /// would be the same regression.
    public static func containsApproximationGlyph(_ text: String) -> Bool {
        text.contains("~") || text.contains("\u{2248}")
    }

    // MARK: - 1b. THE resolver — one value, every owner read surface

    /// The service window the owner sheet displays, from the ONE source both of
    /// its read surfaces must share.
    ///
    /// WHY THIS EXISTS (the client's server-verified defect): the owner saved a
    /// manual completion date, the server persisted it — and the sheet went on
    /// showing the old state. The two surfaces were reading a DIFFERENT object
    /// from the one the save wrote:
    ///
    ///   • the hero completion line (`HomeScreen.serviceCompletionLine`) and the
    ///     "Service completion date" row (`VehicleControls.serviceWindowRow`) both
    ///     read `VehicleTelemetrySnapshot.serviceEstimatedEndAt`, which is derived
    ///     ONLY from the accumulated `VehicleState`
    ///     (`VehicleContractMapping.snapshot`);
    ///   • the save wrote the server's resolved echo to the EXECUTOR
    ///     (`LiveVehicleCommandExecutor.setServiceWindow`) and to the fleet's
    ///     summary row.
    ///
    /// And because this field is SNAPSHOT-ONLY by contract — no `vehicle_update`
    /// frame ever carries it — the snapshot cannot catch up until the next cold
    /// `/snapshot` read. So the display was correct-but-stale for an unbounded
    /// time, which reads exactly like a save that did not work.
    ///
    /// THE COMMITTED SIDE IS THE SOURCE, and it is a strict superset rather than a
    /// competing opinion: `LiveVehicleCommandExecutor.reconcile(from:)` adopts the
    /// window off EVERY snapshot (including a nil, which is how a car leaving
    /// service clears it), and `setServiceWindow` adopts the write echo. So once
    /// anything has been committed, the executor holds either the same instant the
    /// snapshot does or a newer one — never an older one.
    ///
    /// `isCommitted` is what makes a CLEAR work. "Prefer the non-nil value" would
    /// be the obvious rule and would be wrong: an owner who removes the window
    /// would keep seeing the stale snapshot's instant until a refetch. A committed
    /// nil is a real answer and outranks the snapshot.
    ///
    /// Nothing committed → the snapshot is all we know and is authoritative. That
    /// is the cold-launch path and the whole simulated path (where both sides are
    /// nil anyway, so every drift-gate scene is byte-identical).
    public static func resolvedEndAt(committed: Date?, isCommitted: Bool, snapshot: Date?) -> Date? {
        isCommitted ? committed : snapshot
    }

    // MARK: - 2. Owner entry validation

    /// Whether an owner-picked instant is one the server will accept. Mirrors the
    /// server's rule EXACTLY ("must be in the future") rather than inventing a
    /// stricter client-side one — a client that demanded, say, an hour of lead
    /// time would reject entries the server would happily take, and the owner
    /// would have no way to tell which rule they had hit.
    ///
    /// The mirror is a courtesy, not the authority: the server still validates,
    /// and the write path folds its `400 invalid_request` onto an honest notice.
    public static func isEnterable(_ candidate: Date, now: Date = Date()) -> Bool {
        candidate > now
    }

    // MARK: - 3. Rider scheduling floor

    /// The buffer added to the estimated completion before the first bookable
    /// slot. A car does not become available the instant service "ends" — it has
    /// to be collected, and the estimate is an estimate.
    ///
    /// MYR-370 raises this from 15 to **30 minutes**, one full step of the
    /// picker's own grid. At 15 the floor landed mid-step and the `>=` rule then
    /// rounded it up to the next slot anyway, so on a window ending exactly on
    /// the half hour (11:30, the client's own case) the first offered slot was
    /// 12:00 — the buffer's effect was real but its NUMBER was not: it happened
    /// to be whatever rounding produced. A whole step makes the promise explicit
    /// and uniform: the first bookable slot is always at least 30 minutes after
    /// the estimate, whatever minute the estimate falls on.
    public static let schedulingBuffer: TimeInterval = 30 * 60

    /// The earliest instant a ride may be scheduled against this vehicle, or
    /// `nil` when there is NO bound.
    ///
    /// `nil` in → `nil` out, deliberately and non-negotiably: an unknown window
    /// leaves scheduling FULLY OPEN. This is the single most important line in
    /// the file — the failure mode it prevents is a car with no Tesla appointment
    /// record (the common case) becoming unbookable forever.
    public static func earliestSelectable(
        serviceEstimatedEndAt end: Date?,
        buffer: TimeInterval = schedulingBuffer
    ) -> Date? {
        end.map { $0.addingTimeInterval(buffer) }
    }

    /// Whether a candidate pickup instant clears the floor. A `nil` floor allows
    /// everything; the boundary instant itself is ALLOWED (`>=`), so the floor
    /// names the first bookable moment rather than the last blocked one.
    public static func allows(_ slot: Date, floor: Date?) -> Bool {
        guard let floor else { return true }
        return slot >= floor
    }

    /// The muted caption on the scheduling card: "Lunar is in service until
    /// Sat, Aug 2 \u{00B7} 7:09 PM". `nil` when there is no window — the card then
    /// renders exactly as it always has.
    ///
    /// MYR-320 — the instant is formatted by ``completionLabel(for:now:calendar:)``,
    /// the SAME resolver the owner's line uses, so the rider and the owner can
    /// never see the same window written two different ways. That replaces MYR-316's
    /// separate in-sentence form (`~Sat 2 PM`, with ":00" dropped on the hour),
    /// which was a second date grammar maintained in parallel for a stylistic
    /// reason the client's no-tilde direction has now overruled: one clean format
    /// everywhere beats a bespoke one per surface.
    ///
    /// Note the caption names the ESTIMATED END, not the floor: the buffer is an
    /// implementation detail of which slots we offer, and quoting "7:24 PM" would
    /// imply a precision the estimate does not carry. The picker's disabled slots
    /// are where the buffer becomes visible.
    public static func schedulingCaption(
        vehicleName: String,
        serviceEstimatedEndAt end: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let name = vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let when = completionLabel(for: end, now: now, calendar: calendar)
        else { return nil }
        return "\(name) is in service until \(when)"
    }

    // MARK: - Formatters
    //
    // Fixed `en_US_POSIX` locale, matching `RideRequestContractMapping`'s clock
    // parser: the schedule picker's own chips are English 12-hour strings, so a
    // 24-hour device locale would otherwise print a completion time in a format
    // that no longer lines up with the chips beside it.

    private static func timeFormatter(calendar: Calendar) -> DateFormatter {
        formatter(dateFormat: "h:mm a", calendar: calendar)
    }

    /// "Sat, Aug 2" — weekday AND date (MYR-320). The weekday alone is what an
    /// owner plans around, but it only disambiguates inside a seven-day horizon;
    /// the month/day is what keeps a Saturday two weeks out from reading as this
    /// Saturday. No year: an estimate that far out is not a case this line serves.
    private static func dateFormatter(calendar: Calendar) -> DateFormatter {
        formatter(dateFormat: "EEE, MMM d", calendar: calendar)
    }

    private static func formatter(dateFormat: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = dateFormat
        return f
    }
}

// MARK: - The resolver, bound to the two objects the owner sheet actually holds

@MainActor
public extension VehicleServiceWindow {
    /// ``resolvedEndAt(committed:isCommitted:snapshot:)`` applied to the executor +
    /// snapshot pair every owner surface already has in hand. Keeping the pure rule
    /// and this binding in one file is what stops a call site from re-deriving
    /// "which one wins" for itself — the split that caused the defect.
    ///
    /// `isKnown(.serviceWindow)` is the executor's own MYR-251 ledger of confirmed
    /// fields; `setServiceWindow` raises it on every successful write (a CLEAR
    /// included) and `reconcile` raises it whenever a snapshot carried a real
    /// window. The simulated executor answers `true` with a nil value, which agrees
    /// with its always-nil snapshot, so M1 renders exactly as before.
    static func resolvedEndAt(
        executor: any VehicleCommandExecutor,
        snapshot: VehicleTelemetrySnapshot
    ) -> Date? {
        resolvedEndAt(
            committed: executor.controls.serviceEstimatedEndAt,
            isCommitted: executor.isKnown(.serviceWindow),
            snapshot: snapshot.serviceEstimatedEndAt
        )
    }
}
