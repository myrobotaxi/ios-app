import SwiftUI
import DesignSystem

// MARK: - Status & location (vehicle-controls.jsx:385-396, parked only)
//
// While driving, live speed/heading/range already live at the top of the
// sheet (screens.jsx comment, vehicle-controls.jsx:383-384), so this section
// only renders when parked. The jsx hardcodes "Embarcadero Ctr" / "1h 42m"
// literals distinct from `ParkedSheetContent`'s own peek-row strings
// (screens.jsx:561-562 "Embarcadero Center · Lot B" + a computed duration) —
// two sources of truth for the same fact in the same screen. This port
// reuses the one real `ParkedLocation` fixture (already computed for the
// peek row, HomeSheetContent.swift `parkedDuration`) for both, instead of
// duplicating a shorter, driftable literal.

struct StatusLocationSection: View {
    let location: ParkedLocation
    let rangeMi: Int
    /// MYR-316 — the REAL badge state for this section's trailing chip. Defaults
    /// to `.parked`, which is exactly the hardcoded chip this section shipped
    /// with, so the simulated path and every drift-gate scene are pixel-identical.
    /// It has to be a parameter now: this section renders for any non-driving
    /// vehicle, so an IN SERVICE car was previously labelled "Parked" here — and
    /// the expected-back row below would then sit under a chip contradicting it.
    var status: MRTVehicleStatus = .parked
    /// MYR-316 — the owner's "expected back" entry. `nil` (the default) hides the
    /// row entirely, which is what keeps the simulated sheet unchanged: the row
    /// belongs to a service visit and has no meaning for a car that is simply
    /// parked. Non-nil means "this car is in service" — the value INSIDE may still
    /// be nil, which is the honest "no time set yet" state, not an error.
    var serviceWindow: ServiceWindowRowModel? = nil
    /// MYR-342 — the owner's ride-sharing switch. `nil` (the default) hides the row
    /// entirely, which is what keeps the simulated sheet and every drift-gate scene
    /// byte-identical: the host supplies a model only on the LIVE path, because a
    /// switch that cannot reach a server is a switch that lies.
    ///
    /// It belongs in THIS card and not in Vehicle details for the reason the
    /// service-window row is here: this section is where the AVAILABILITY facts
    /// live. "In Service", "Parked", "Expected back" and "can riders book this car"
    /// are answers to one question an owner asks in one glance; Vehicle details
    /// answers "what car is this" (plate, VIN, trim, software). Filing an
    /// availability switch under identity would separate it from the very badge it
    /// modifies.
    var rideShare: RideShareRowModel? = nil

    /// Elapsed-since-parked, or `nil` when the park-start is unknown (live — no
    /// contracted park-start; MYR-268) so the "Parked" row is omitted rather than
    /// showing a fabricated "0m".
    private var parkedDuration: String? {
        guard let parkedSince = location.parkedSince else { return nil }
        let seconds = max(0, Date().timeIntervalSince(parkedSince))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var body: some View {
        SectionCard(title: "Status & location", trailing: {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: status.color.opacity(2.0 / 3.0), radius: 3.5)
                Text(status.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.color)
            }
        }) {
            VStack(spacing: 0) {
                KV(label: "Location", value: location.label)
                if let parkedDuration {
                    KV(label: "Parked", value: parkedDuration)
                }
                KV(label: "Range", value: "\(rangeMi) mi")
                // MYR-316 — the owner's expected-back entry, in the STATUS section
                // because that is where the In Service fact already lives; putting
                // it in Vehicle details (beside the plate) would file a piece of
                // TIMING next to a piece of IDENTITY. Rendered only for a car
                // actually in service, so nothing changes anywhere else.
                if let serviceWindow {
                    ExpectedBackRow(model: serviceWindow)
                    // The write can fail (a time that passed while the sheet sat
                    // open, or a save that didn't land). Surface it in place, on
                    // the row's own full width, with the same notice machinery
                    // every other control uses.
                    if let notice = serviceWindow.state.notice {
                        VehicleCommandNoticeLine(notice: notice)
                    }
                }
                // MYR-342 — the owner's ride-sharing switch, LAST in the card. The
                // order is the card's own logic, not an afterthought: everything
                // above is the car REPORTING its situation (where it is, how long
                // it has been there, how far it can go, when it is back), and this
                // is the one row where the owner ANSWERS. Reading top to bottom
                // gives the facts, then the decision they inform.
                if let rideShare {
                    RideShareRow(model: rideShare)
                    // The write can fail (no network, a session that expired while
                    // the sheet sat open). Surface it in place, on the row's own
                    // full width, with the same notice machinery every other
                    // control uses — and note the row above has already SNAPPED
                    // BACK to the server's position by the time this renders, so
                    // the line explains a switch that visibly did not move rather
                    // than contradicting one that did.
                    if let notice = rideShare.state.notice {
                        VehicleCommandNoticeLine(notice: notice)
                    }
                }
            }
        }
    }
}

// MARK: - Ride sharing (MYR-342)

/// What the ride-sharing row needs to render and act. Bundled rather than passed
/// as three parallel arguments for the same reason ``ServiceWindowRowModel`` is:
/// the row's meaningful distinction — "this surface can actually reach the server"
/// (non-nil model) vs. "the switch is ON" (`isEnabled`) — must be impossible to
/// collapse by accident at a call site.
struct RideShareRowModel: Equatable {
    /// The RESOLVED switch position — `true` when riders can request this car.
    /// Pre-resolved by `VehicleRideShare` from the executor + snapshot pair, so
    /// this view holds no precedence logic and no knowledge of what an absent wire
    /// value means.
    var isEnabled: Bool
    /// MYR-358 — whether the switch may be moved at all. `false` while the car is
    /// IN SERVICE, where the position is DERIVED (forced off) rather than stored.
    /// Carried as its own field rather than inferred from `isEnabled`, because
    /// "off" and "not yours to change right now" are different facts and a row that
    /// collapsed them could not render a paused-but-editable car.
    var isInteractive: Bool = true
    /// The write's pending/notice state (`VehicleControlUIState`).
    var state: VehicleControlUIState = .idle
    /// Flips the switch. Async because the write is; the row fires and forgets,
    /// because the executor owns the optimistic flip, the echo and the rollback.
    var onToggle: (Bool) -> Void

    /// The muted line under the label, from the single copy source so the owner's
    /// row and any future surface can never word this differently.
    var caption: String

    static func == (lhs: RideShareRowModel, rhs: RideShareRowModel) -> Bool {
        lhs.isEnabled == rhs.isEnabled
            && lhs.isInteractive == rhs.isInteractive
            && lhs.caption == rhs.caption
            && lhs.state == rhs.state
    }
}

/// The ride-sharing toggle row — label + state caption on the left, `MRTToggle` on
/// the right.
///
/// REUSED, NOT FORKED (CLAUDE.md): the switch is the DesignSystem's existing
/// `MRTToggle` (components.jsx `Toggle`), gold-on, the same control the Settings
/// notification rows use — so the one interactive switch grammar in this app stays
/// one grammar. And gold is legitimate here rather than decorative: an ON switch is
/// the car being actively offered for rides, which is precisely the "actionable
/// moment" the accent is reserved for.
///
/// The row is NOT a `Button` wrapping the toggle, unlike its `ExpectedBackRow` /
/// `PlateRow` neighbours. Those open an editor, so the whole row is one tap target
/// leading somewhere. This one commits a change in place, and a whole-row tap
/// target for a destructive-ish, invisible-consequence action is how an owner
/// withdraws their car from ride-hailing by brushing the sheet while scrolling.
/// The 44pt target is the toggle's own (`MRTToggle` already insets its content
/// shape to it), which is the deliberate, aimed-at surface.
private struct RideShareRow: View {
    let model: RideShareRowModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `MRTToggle` takes a `Binding`, because at every other call site it owns its
    /// own `@State`. Here the position is NOT local state — it is resolved from the
    /// executor, which owns the optimistic flip and the rollback — so the setter
    /// forwards to the executor and the getter always re-reads the resolved truth.
    /// A local `@State` mirror is exactly how a rolled-back write would leave the
    /// switch showing a position the server does not hold.
    /// MYR-358 — the setter REFUSES while the row is non-interactive, as well as the
    /// switch being hit-test-disabled below. Belt AND braces on purpose: hit testing
    /// stops a finger, but a `Binding` is reachable from accessibility actions and
    /// from any future programmatic path, and the one thing this row must never do
    /// is fire a §7.18 write the owner did not ask for and cannot see the result of.
    private var isOn: Binding<Bool> {
        Binding(
            get: { model.isEnabled },
            set: { newValue in
                guard model.isInteractive else { return }
                model.onToggle(newValue)
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(VehicleRideShare.rowLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextSec)
                // The state caption, in the same muted 11pt this sheet gives every
                // other qualifier-on-a-value (the service-window source note is its
                // sibling). Allowed to WRAP rather than truncate: both strings fit
                // the card at this size (`VehicleRideShareTests
                // .testRowCopyFitsTheCardWithoutTruncating`), and if a future
                // localization did not, losing the half that says what is off would
                // be the half worth keeping.
                Text(model.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mrtTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 12)
            // In flight: the toggle is replaced by the same small gold spinner the
            // service-window row uses, so the two owner-write rows in this card
            // report progress identically. Replaced rather than overlaid, because a
            // switch that is still tappable while its own write is outstanding
            // invites the double-flip the executor's `isPending` guard then silently
            // swallows — better to show plainly that it is busy.
            if model.state.isPending, !reduceMotion {
                ProgressView()
                    .controlSize(.small)
                    .tint(.mrtGold)
                    .frame(width: MRTMetrics.toggleTrackWidth, height: MRTMetrics.toggleTrackHeight)
            } else {
                MRTToggle(isOn: isOn)
                    // Reduce Motion has no spinner to show, so the switch stays put
                    // and simply goes inert for the duration — no animation, no
                    // second write.
                    //
                    // MYR-358 — the IN-SERVICE state is inert for the same reason and
                    // wears the same muting, so the sheet has one visual grammar for
                    // "this switch is not yours to move right now" rather than two.
                    .allowsHitTesting(model.isInteractive && !model.state.isPending)
                    .opacity(model.isInteractive && !model.state.isPending ? 1 : 0.5)
                    .accessibilityLabel(VehicleRideShare.rowLabel)
                    .accessibilityValue(model.caption)
                    .accessibilityAddTraits(model.isInteractive ? [] : .isStaticText)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Expected back (MYR-316)

/// What the "Expected back" row needs to render and act. Bundled rather than
/// passed as four parallel arguments so the row's ONE meaningful distinction —
/// "there is a service visit" (non-nil model) vs. "there is a known time within
/// it" (non-nil `value`) — is impossible to collapse by accident at a call site.
struct ServiceWindowRowModel: Equatable {
    /// The server's RESOLVED estimate, or `nil` when none is known yet. Nil is a
    /// legitimate, common state — Tesla holds no appointment record for most
    /// visits — so the row invites an entry rather than reporting a problem.
    var value: Date?
    /// The formatted display for `value` ("Sat, Aug 2 · 7:09 PM"), pre-resolved by
    /// `VehicleServiceWindow` so this view holds no date logic of its own.
    var label: String?
    /// The write's pending/notice state (`VehicleControlUIState`).
    var state: VehicleControlUIState = .idle
    /// MYR-320 — what the app can honestly say about where `value` came from.
    /// `.unknown` (the default and the cold-launch state) renders no note.
    var source: ServiceWindowSource = .unknown
    /// Opens the entry sheet.
    var onEdit: () -> Void

    /// MYR-320 — the muted line under the row, or `nil` for none.
    ///
    /// Client-directed copy, rendered ONLY where it is provably true (see
    /// ``ServiceWindowSource``): the app never asserts a source it merely suspects.
    ///
    ///   • `.manual` — the server took the owner's instant verbatim, which is proof
    ///     Tesla had none to outrank it. Say both halves: that this was set by hand,
    ///     and WHY that was necessary, so the owner doesn't read a hand-set time as
    ///     the app failing to fetch a real one.
    ///   • `.tesla`  — Tesla's estimate outranked the entry. Name the source so the
    ///     value reads as reported rather than authored. The row stays editable
    ///     regardless: the owner can still record what they expect, and the server
    ///     keeps applying precedence to it.
    ///   • `.unknown` — nothing provable, so nothing claimed.
    var sourceCaption: String? {
        switch source {
        case .manual: "Set manually \u{2014} Tesla hasn\u{2019}t provided an estimate for this visit"
        case .tesla: "From Tesla"
        case .unknown: nil
        }
    }

    static func == (lhs: ServiceWindowRowModel, rhs: ServiceWindowRowModel) -> Bool {
        lhs.value == rhs.value && lhs.label == rhs.label
            && lhs.state == rhs.state && lhs.source == rhs.source
    }
}

/// The editable service-completion-date row — deliberately the same shape as
/// `PlateRow` (label, value-or-affordance, gold pencil in a disc, 44pt tap
/// target), because it is the same KIND of thing: an owner-entered fact the car
/// cannot report.
///
/// MYR-320 — the label was "Expected back". The client's objection was that it
/// read like a question about the OWNER's plans ("when are you expecting it
/// back?") rather than the name of a field that moves what riders can book;
/// "Service completion date" names the fact instead of the feeling, and matches
/// the "Service Estimated Completion" line in the hero above so the two are
/// visibly the same quantity.
///
/// Tesla's own `service_etc` OUTRANKS the owner's entry server-side. The row
/// always offers the edit anyway — an owner whose entry is currently being
/// outranked can still record what they expect, and the server keeps applying
/// precedence; locking the row would be worse than saying nothing. What it does
/// NOT do is guess: the source caption renders only where the app has PROOF (a
/// write echo it observed — see `ServiceWindowSource`), so a cold-launched sheet
/// shows the value with no claim about where it came from.
private struct ExpectedBackRow: View {
    let model: ServiceWindowRowModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: model.onEdit) {
            // STACKED, not the inline label/value of `PlateRow` and `KV`. Both
            // halves of this row grew in MYR-320 — the label to "Service completion
            // date" (146pt at 13pt) and the value to a full date + time ("Wed,
            // Sep 30 · 12:30 PM", 150pt semibold) — and inline they need ~341pt
            // against 313pt of card width, so the value truncated to
            // "Sat, Aug 1 · 2:00…". Losing the AM/PM off a completion time is not
            // a cosmetic truncation: it is the difference between a morning and an
            // evening pickup. `VehicleServiceWindowTests
            // .testServiceCompletionRowFitsTheCardWithoutTruncating` measures both
            // layouts so this stays a measured decision rather than a guess.
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Service completion date")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mrtTextSec)
                    Spacer(minLength: 12)
                    if model.state.isPending, !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.mrtGold)
                            .frame(width: 24, height: 24)
                            .background(Color.mrtStepButtonFill, in: Circle())
                    } else {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mrtGold)
                            .opacity(model.state.isPending ? 0.5 : 1)
                            .frame(width: 24, height: 24)
                            .background(Color.mrtStepButtonFill, in: Circle())
                    }
                }
                Text(model.label ?? "Set a time")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(model.label == nil ? Color.mrtTextMuted : .mrtText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The source note. Muted 11pt — the same weight the sheet gives
                // every other qualifier-on-a-value — and allowed to WRAP: the
                // manual caption is a sentence, and truncating it to one line
                // would cut exactly the half that explains why the entry was
                // needed. Nothing renders when the source is unprovable, which is
                // both the cold-launch state and the entire simulated path.
                if let caption = model.sourceCaption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mrtTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Service-window edit sheet (MYR-316)

/// The owner's "expected back" editor — the `PlateEditSheet` recipe with a
/// date-time picker in place of the text field, presented through the same
/// `mrtConfigSheet` modifier at `HomeScreen`'s root (grab handle, slide-up,
/// scrim, no ✕: backdrop-tap and an explicit Cancel).
///
/// Validation mirrors the server EXACTLY — "must be in the future" — and nothing
/// more (`VehicleServiceWindow.isEnterable`). The picker's own `in:` range makes
/// a past selection largely unreachable, and the explicit check catches the case
/// a range cannot: a sheet left open until the chosen time passed. Save is
/// disabled rather than failing, so the owner is told before the round trip.
struct ServiceWindowEditSheet: View {
    /// The currently resolved window, or `nil` when none is set.
    let initialValue: Date?
    let vehicleName: String
    let onCancel: () -> Void
    /// `nil` CLEARS the owner's entry. Note that clearing does not necessarily
    /// null the displayed value: if Tesla holds an estimate it keeps winning under
    /// the server's precedence, and the echo will carry Tesla's instant back.
    let onSave: (Date?) -> Void

    @State private var picked: Date
    /// Re-evaluated on save rather than continuously: a per-second timer to grey
    /// out a button would be motion the design does not want, and the check is
    /// cheap at exactly the moment it matters.
    @State private var now = Date()

    init(
        initialValue: Date?,
        vehicleName: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Date?) -> Void
    ) {
        self.initialValue = initialValue
        self.vehicleName = vehicleName
        self.onCancel = onCancel
        self.onSave = onSave
        // Seed at the existing value when there is one, else a sensible near
        // future (an hour out, rounded) — never "now", which is the one instant
        // guaranteed to be invalid by the time it is submitted.
        _picked = State(initialValue: initialValue ?? Self.defaultSuggestion())
    }

    private var isValid: Bool { VehicleServiceWindow.isEnterable(picked, now: now) }
    private var isChanged: Bool { picked != initialValue }
    private var canSave: Bool { isValid && isChanged }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MYR-320 — the sheet's title tracks the row that opens it. Leaving
            // "Expected back" here would have made the renamed row hand off to a
            // sheet about something else.
            Text("Service completion date")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 6)
            // Says WHY this matters (it is not a note-to-self: it moves what
            // riders can book) and is honest that Tesla may override it, without
            // pretending we can tell the owner which source is currently winning.
            Text("When do you expect \(vehicleName) back from service? Riders can't schedule a pickup before then. If Tesla reports its own estimate, that one is used.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 20)

            Text("EXPECTED COMPLETION")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 9)

            DatePicker(
                "Expected completion",
                selection: $picked,
                // The server's rule, expressed in the control itself so the
                // common mistake is unreachable rather than merely rejected.
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(.mrtGold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.mrtControlSegmentTrack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isValid ? Color.mrtBorder : Color.mrtDialogRed.opacity(0.4), lineWidth: 1)
            )

            Text(isValid ? "Riders can book from about 15 minutes after this." : "Pick a time in the future.")
                .font(.system(size: 11))
                .foregroundStyle(isValid ? Color.mrtTextMuted : Color.mrtDialogRed)
                .padding(.top, 9)
                .padding(.horizontal, 2)

            VStack(spacing: 9) {
                MRTButton("Save", variant: .gold) {
                    now = Date() // re-check against the clock AT the tap
                    if canSave { onSave(picked) }
                }
                .opacity(canSave ? 1 : 0.4)
                .allowsHitTesting(canSave)
                // The clear affordance, shown only when there is something to
                // clear. Ghost, not destructive-red: removing an estimate is an
                // ordinary correction, not a dangerous act.
                if initialValue != nil {
                    MRTButton("Clear", variant: .ghost) { onSave(nil) }
                }
                MRTButton("Cancel", variant: .ghost, action: onCancel)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// An hour from now, rounded down to the half hour — a plausible starting
    /// point that is unambiguously in the future and lines up with the rider
    /// picker's own 30-minute slots.
    private static func defaultSuggestion(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let hourOut = now.addingTimeInterval(3600)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: hourOut)
        components.minute = (components.minute ?? 0) < 30 ? 0 : 30
        components.second = 0
        return calendar.date(from: components) ?? hourOut
    }
}

// MARK: - Tire pressure (vehicle-controls.jsx:398-409)

struct TirePressureSection: View {
    /// Real per-wheel pressures, or `nil` on the live path — TPMS is not on the
    /// `VehicleState` contract yet (MYR-255 gap list), so live renders honest-
    /// unknown rather than a fixture. Simulated passes the fixture values.
    let pressures: TirePressures?

    private struct Tire: Identifiable {
        let position: String
        let psi: Int
        var id: String { position }
    }

    private var tires: [Tire] {
        guard let pressures else { return [] }
        return [
            Tire(position: "FL", psi: pressures.fl),
            Tire(position: "FR", psi: pressures.fr),
            Tire(position: "RL", psi: pressures.rl),
            Tire(position: "RR", psi: pressures.rr),
        ]
    }

    var body: some View {
        SectionCard(title: "Tire pressure", trailing: {
            if pressures != nil {
                Text("All nominal")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.mrtDriving)
            }
        }) {
            if pressures == nil {
                // TPMS is genuinely uncontracted (not on the snapshot/stream on a
                // cold parked read) — a calm, intentional honest state instead of
                // fabricated psi numbers (MYR-228 / MYR-255). MYR-279: guide the
                // owner ("Available after your next drive") rather than the bare,
                // confusing "Unavailable".
                HStack {
                    Text("Tire pressure")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mrtTextSec)
                    Spacer(minLength: 12)
                    MRTUnavailableValue(.afterDrive)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(tires) { tire in
                        HStack(spacing: 10) {
                            if tire.position.hasSuffix("L") {
                                Text(tire.position)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(Color.mrtTextMuted)
                            }
                            (Text("\(tire.psi)")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color.mrtText)
                                + Text(" psi")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.mrtTextMuted))
                                .tracking(-0.3)
                                .monospacedDigit()
                            if tire.position.hasSuffix("R") {
                                Text(tire.position)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(Color.mrtTextMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: tire.position.hasSuffix("L") ? .leading : .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Lifetime (vehicle-controls.jsx:412-416)

struct LifetimeSection: View {
    /// Whole-mile odometer (`VehicleState.odometerMiles`) — real live, fixture
    /// 42,184 simulated, `nil` until the first live snapshot → "— Syncing".
    let odometerMiles: Int?
    /// FSD miles since reset (`VehicleState.fsdMilesSinceReset`) — real live,
    /// fixture 31,907 simulated, `nil` → "— Syncing".
    let fsdMilesSinceReset: Double?

    /// "42,184 mi" grouped, or nil to trigger the honest-unknown row.
    private var odometerText: String? {
        odometerMiles.map { "\(MRTNumber.grouped($0)) mi" }
    }

    private var fsdText: String? {
        fsdMilesSinceReset.map { "\(MRTNumber.grouped(Int($0.rounded()))) mi" }
    }

    /// Driven-autonomously % is DERIVED (FSD miles ÷ odometer) — there is no
    /// separate wire field. Available only when both stats are present and the
    /// odometer is non-zero; otherwise honest-unknown.
    private var autonomyText: String? {
        guard let odometerMiles, odometerMiles > 0, let fsdMilesSinceReset else { return nil }
        let pct = Int((fsdMilesSinceReset / Double(odometerMiles) * 100).rounded())
        return "\(min(100, max(0, pct)))%"
    }

    var body: some View {
        SectionCard(title: "Lifetime") {
            VStack(spacing: 0) {
                KV(label: "Odometer", value: odometerText, absence: .syncing)
                KV(label: "Total FSD miles", value: fsdText, absence: .syncing, gold: true)
                KV(label: "Driven autonomously", value: autonomyText, absence: .syncing)
            }
        }
    }
}

// MARK: - Vehicle details (vehicle-controls.jsx:419-425)

struct VehicleDetailsSection: View {
    let vehicle: Vehicle
    let plate: String
    let onEditPlate: () -> Void
    /// MYR-286 — the live state of the §7.14 plate write. `.idle` on the simulated
    /// path (the default), so the M1 / drift-gate scenes stay pixel-identical.
    var plateState: VehicleControlUIState = .idle

    var body: some View {
        SectionCard(title: "Vehicle details") {
            VStack(spacing: 0) {
                // MYR-279/320 — "{year} {model} {trimLabel}" composed from the
                // snapshot (e.g. "2026 Model Y Performance"), not the partial list
                // model. The suffix is the DISPLAY-READY `trimLabel`, never the raw
                // `trim` badge code ("p74d") — see `VehicleContractMapping
                // .modelLabel`. Composed once there, so this row, the switcher and
                // the Settings vehicle rows can never disagree.
                KV(label: "Model", value: vehicle.model, absence: .unavailable)
                // Color is contracted (`VehicleState.color`). It was blank for every
                // onboarded car until telemetry PR #340 began populating it, so the
                // row has always rendered the honest empty state rather than a
                // fabricated color (MYR-279/283); now that the wire carries one it
                // renders VERBATIM — "Quicksilver", exactly as the server spells it,
                // with no re-casing (MYR-320). No mapping change was needed for
                // this: the existing `color` field simply started arriving full.
                KV(label: "Color", value: vehicle.colorName, absence: .unavailable)
                PlateRow(value: plate, isSaving: plateState.isPending, onEdit: onEditPlate)
                // MYR-286 — the §7.14 write can fail (an invalid plate, or a save
                // that didn't land). Surface it in place, on the row's own full
                // width, using the same notice machinery every other control uses.
                // Nothing renders when idle → simulated path unchanged.
                if let notice = plateState.notice {
                    VehicleCommandNoticeLine(notice: notice)
                }
                // MYR-279 — full (owner-masked) VIN + Tesla software version now
                // ride on the snapshot (telemetry PR #325); nil before the first
                // snapshot streams in → honest-unknown. VIN is owner-only P0 data
                // shown in the owner's own details screen and is never logged.
                KV(label: "VIN", value: vehicle.vin, absence: .unavailable)
                KV(label: "Software", value: vehicle.softwareVersion, absence: .unavailable)
                // MYR-320 — the FSD designation, directly after the firmware build
                // it is most often confused with. Two rows, not one: `softwareVersion`
                // is the installed firmware ("2026.14.3") and `fsdVersion` is what
                // Tesla calls the FSD stack ("FSD (Supervised) v14.3.5"); the two
                // move independently and neither can be derived from the other.
                //
                // Rendered VERBATIM and OMITTED ENTIRELY when nil — an `if let`, not
                // the `absence:` treatment the rows above use. That asymmetry is the
                // contract's own consumer rule, and it is the right one: an absent
                // value here does NOT mean "we failed to read it" and above all does
                // not mean the car lacks FSD, so an "— Unavailable" placeholder would
                // manufacture a problem out of the common case (a server predating
                // MYR-320, or a release-notes read that hasn't completed yet).
                if let fsdVersion = vehicle.fsdVersion {
                    KV(label: "FSD", value: fsdVersion)
                }
            }
        }
    }
}

/// Editable license plate — Tesla's data doesn't include the plate anywhere (no
/// endpoint, no telemetry field, no proto), so the owner sets it manually
/// (vehicle-controls.jsx:124-125). Tapping opens `PlateEditSheet` via
/// `HomeScreen`'s `.mrtConfigSheet`; saving persists through §7.14 (MYR-286).
///
/// The value shown here is the RAW owner-entered plate, so an unset plate renders
/// the designed "Add plate" affordance. The `VIN ····xxxx` fallback belongs to the
/// read-only DISPLAY surfaces (switcher, Settings rows, the rider's chip) — it
/// would be wrong here, where the value is editable and a VIN is not the answer.
private struct PlateRow: View {
    let value: String
    /// MYR-286 — a §7.14 write is in flight; the pencil becomes a spinner so the
    /// row shows the same in-flight discipline as the commanded controls. Reduce
    /// Motion falls back to the static pencil (CLAUDE.md).
    var isSaving: Bool = false
    let onEdit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Text("Plate")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextSec)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text(value.isEmpty ? "Add plate" : value)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.6)
                        .monospacedDigit()
                        .foregroundStyle(value.isEmpty ? Color.mrtTextMuted : .mrtText)
                    if isSaving, !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.mrtGold)
                            .frame(width: 24, height: 24)
                            .background(Color.mrtStepButtonFill, in: Circle())
                    } else {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mrtGold)
                            .opacity(isSaving ? 0.5 : 1)
                            .frame(width: 24, height: 24)
                            .background(Color.mrtStepButtonFill, in: Circle())
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plate edit sheet (vehicle-controls.jsx:146-197 `PlateEditModal`)
//
// The jsx portals a custom bottom sheet out of the controls scroll view.
// This port presents through the existing `mrtConfigSheet` modifier
// (BottomSheet.swift, Handoff §7 "vehicle detail" bottom-sheet pattern)
// applied at `HomeScreen`'s root instead of a bespoke portal — SwiftUI has
// no portal primitive, and `mrtConfigSheet` already reproduces the same
// chrome (grab handle, slide-up, scrim). It's the "no close ✕" variant: the
// jsx has no ✕, only backdrop-tap and an explicit Cancel button.
struct PlateEditSheet: View {
    let initialPlate: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(initialPlate: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.initialPlate = initialPlate
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: initialPlate)
    }

    private var cleaned: String { text.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { cleaned.count >= 2 }
    private var isChanged: Bool { cleaned != initialPlate.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { isValid && isChanged }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit license plate")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 6)
            Text("Your Tesla doesn't report its plate, so enter it manually. It appears on shared rides so passengers can spot the car.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 20)
            Text("PLATE NUMBER")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Color.mrtTextMuted)
                .padding(.bottom, 9)
            TextField("e.g. RBO-2046", text: $text)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(.system(size: 21, weight: .semibold))
                .tracking(3)
                .foregroundStyle(Color.mrtText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: text) { _, newValue in
                    let filtered = newValue.uppercased().filter {
                        $0.isLetter || $0.isNumber || $0 == " " || $0 == "-"
                    }
                    text = String(filtered.prefix(8))
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
                .background(Color.mrtControlSegmentTrack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            cleaned.isEmpty || isValid ? Color.mrtBorder : Color.mrtDialogRed.opacity(0.4),
                            lineWidth: 1
                        )
                )
            HStack {
                Text(cleaned.isEmpty || isValid ? "Letters, numbers, spaces or dashes" : "Enter at least 2 characters")
                    .foregroundStyle(cleaned.isEmpty || isValid ? Color.mrtTextMuted : Color.mrtDialogRed)
                Spacer()
                Text("\(cleaned.count)/8")
                    .foregroundStyle(Color.mrtTextMuted)
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .padding(.top, 9)
            .padding(.horizontal, 2)

            VStack(spacing: 9) {
                MRTButton("Save plate", variant: .gold) {
                    if canSave { onSave(cleaned) }
                }
                .opacity(canSave ? 1 : 0.4)
                .allowsHitTesting(canSave)
                MRTButton("Cancel", variant: .ghost, action: onCancel)
            }
            .padding(.top, 22)
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .task {
            // vehicle-controls.jsx:151 `setTimeout(..., 80)` — focus + select
            // shortly after the sheet is mounted.
            try? await Task.sleep(nanoseconds: 80_000_000)
            focused = true
        }
    }
}
