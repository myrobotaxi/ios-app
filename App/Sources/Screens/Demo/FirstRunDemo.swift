import Foundation

// MARK: - MYR-428 — the first-run interactive demo, per role
//
// Client-directed (2026-08-02), external-beta launch set: *"I want an interactive
// demo for new users so they can learn the app. only on their first download."*
// and, asked what "new user" means when one person holds both roles: *"if I sign
// in as owner I go through the interactive demo and same thing if I switch to
// rider mode or sign in as rider."*
//
// So the unit is the ROLE, not the account and not the launch. This file is the
// state machine that decides whether a walkthrough plays, and the store that
// remembers the answer across launches. It is deliberately pure + persisted and
// knows nothing about coach marks, screens or fixtures.
//
// FOUR rules, each of which is a way this could have been built wrong:
//
//  • **THE FLAG'S LIFETIME IS THE INSTALL, WHICH IS WHAT "FIRST DOWNLOAD" NAMES.**
//    It is device-scoped and survives BOTH sign-out and account deletion — it is
//    not keyed by user id, and `clearOnSignOut` does not exist. Two reasons. The
//    client's own words are about a DOWNLOAD, which is a device event; and the
//    person signing back in is the same human who just watched the walkthrough,
//    so replaying it is the annoyance the "once each" in the ask exists to
//    prevent. Deleting the app clears `UserDefaults` with it, so a genuine
//    re-download genuinely replays — the semantics land exactly on the word the
//    client used. Note this points the OPPOSITE way from `AccountStorage`'s
//    view-mode choice, which IS keyed by user id and IS released on sign-out
//    (MYR-224): a mode choice is a statement about an account, and "I have seen
//    this walkthrough" is a statement about a person holding a phone.
//  • **COMPLETING AND SKIPPING ARE THE SAME WRITE.** A walkthrough someone
//    dismissed on step one must not reappear on the next mode switch; the whole
//    point of a Skip affordance is that it ends the thing. The prototype's own
//    `StoryDeck` already made this choice — its Skip button and its final CTA are
//    literally the same `onDone` callback (design/app/tutorials.jsx:296) — so
//    this is the ported grammar rather than a new decision. `markSeen` is the
//    only write, and both exits call it.
//  • **THE TWO ROLES ARE INDEPENDENT.** Seeing the owner walkthrough says nothing
//    about the rider one. That is the entire content of the client's
//    clarification, and it is why this is a two-field record rather than one
//    `hasSeenDemo` bool.
//  • **AN UNREADABLE RECORD MEANS "NOT SEEN".** The `try?` decode answers a blank
//    record rather than throwing at a tester, following `RecentDestinations`'
//    own rule. The failure mode is a walkthrough that plays a second time, which
//    is survivable; the alternative (fail closed, suppress it) would silently
//    withhold the feature from the account it was written for.

/// Which role's walkthrough. The two are tracked separately — see this file's
/// header, rule 3.
public enum FirstRunDemoRole: String, CaseIterable, Sendable, Hashable {
    case owner
    case rider
}

/// The persisted record, in its on-disk shape.
///
/// A `Codable` DTO carrying INSTANTS rather than two `Bool`s. Nothing renders the
/// dates — every read goes through `hasSeen(_:)` — but a support question of the
/// form "did this tester actually get the demo, and when" is answerable from the
/// record instead of unanswerable, and it costs nothing. `AccountStorage`'s
/// `UserProfile` precedent: the stored shape is its own type, never a view's.
public struct FirstRunDemoRecord: Codable, Sendable, Equatable {
    public var ownerSeenAt: Date?
    public var riderSeenAt: Date?

    public init(ownerSeenAt: Date? = nil, riderSeenAt: Date? = nil) {
        self.ownerSeenAt = ownerSeenAt
        self.riderSeenAt = riderSeenAt
    }

    /// Both walkthroughs already seen — the state a DEBUG scene boots into, and
    /// the state every returning tester is in.
    public static func allSeen(at date: Date = Date()) -> FirstRunDemoRecord {
        FirstRunDemoRecord(ownerSeenAt: date, riderSeenAt: date)
    }

    public func seenAt(_ role: FirstRunDemoRole) -> Date? {
        switch role {
        case .owner: return ownerSeenAt
        case .rider: return riderSeenAt
        }
    }

    public func hasSeen(_ role: FirstRunDemoRole) -> Bool {
        seenAt(role) != nil
    }

    /// Idempotent by construction: a role already stamped keeps its ORIGINAL
    /// instant. Re-stamping would make the record say the demo was seen at the
    /// moment of the most recent redundant write, and MYR-414's `RideTripSpan`
    /// found the same trap on a clock that mattered more.
    public func marking(_ role: FirstRunDemoRole, at date: Date) -> FirstRunDemoRecord {
        var next = self
        switch role {
        case .owner: if next.ownerSeenAt == nil { next.ownerSeenAt = date }
        case .rider: if next.riderSeenAt == nil { next.riderSeenAt = date }
        }
        return next
    }
}

// MARK: - The store seam

/// Read/write the record. A protocol so tests and DEBUG scenes can substitute an
/// in-memory twin — the `RecentDestinationsStoring` / `ProfileStore` precedent.
public protocol FirstRunDemoStoring: Sendable {
    func read() -> FirstRunDemoRecord
    func write(_ record: FirstRunDemoRecord)
}

extension FirstRunDemoStoring {
    /// The one write. Both exits from a walkthrough — finishing the last step and
    /// tapping Skip on any step — call this and nothing else.
    public func markSeen(_ role: FirstRunDemoRole, now: Date = Date()) {
        write(read().marking(role, at: now))
    }

    public func hasSeen(_ role: FirstRunDemoRole) -> Bool {
        read().hasSeen(role)
    }
}

/// The shipping store. Reverse-DNS key, JSON `Codable` payload, `init(defaults:)`
/// for tests — `AccountStorage` (MYR-224) exactly, as `RecentDestinations`,
/// `LastKnownVehiclePosition` and `OwnerDispatchPointer` each did in turn.
///
/// Deliberately NOT keyed by user id (unlike `UserDefaultsModeChoiceStore`) and
/// deliberately not cleared anywhere — see this file's header, rule 1.
public struct UserDefaultsFirstRunDemoStore: FirstRunDemoStoring {
    static let defaultsKey = "app.myrobotaxi.ios.firstRunDemo"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read() -> FirstRunDemoRecord {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return FirstRunDemoRecord()
        }
        // A blank record rather than a throw — see this file's header, rule 4.
        return (try? JSONDecoder().decode(FirstRunDemoRecord.self, from: data))
            ?? FirstRunDemoRecord()
    }

    public func write(_ record: FirstRunDemoRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// The test/DEBUG twin. A reference box so a `write` is observable by whoever
/// handed it over — the same shape `InMemoryRecentDestinationsStore` takes.
public final class InMemoryFirstRunDemoStore: FirstRunDemoStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: FirstRunDemoRecord

    public init(_ record: FirstRunDemoRecord = FirstRunDemoRecord()) {
        self.record = record
    }

    public func read() -> FirstRunDemoRecord {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    public func write(_ record: FirstRunDemoRecord) {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }
}

// MARK: - MYR-444 — the kill switch

/// The feature's ONE switch.
///
/// Client-directed (2026-08-03, on build 202608022357): *"I don't like the new
/// demo mode, can we disable it for now. I want to go back and refine it."*
/// DISABLE rather than delete — the walkthrough, its script, its coach marks,
/// its tests and its two DEBUG scenes all survive untouched for the refinement
/// round; only the TRIGGER is off.
///
/// Three rules about where this lives, each of which is a way it could have been
/// put somewhere useless:
///
///  • **IT IS CONSULTED IN THE GATE, WHICH IS THE ONE PLACE THE TRIGGER DECISION
///    IS MADE.** `FirstRunDemoGate.playsWalkthrough` is a pure function over the
///    record and it is the only thing `RootView` asks. A switch on the HOST, or
///    on the script, would disable the walkthrough *and* the DEBUG scenes with
///    it; a switch at one of the four routing call sites would disable one door.
///  • **THE DEBUG SCENES DO NOT PASS THROUGH THIS GATE AT ALL** — `ownerDemo` /
///    `riderDemo` seed `DebugScene.initialScreen` directly, so the walkthrough is
///    still bootable, still capturable and still driven by `FirstRunDemoUITests`
///    exactly as it was. That is why the switch belongs on the *trigger* and not
///    on the feature.
///  • **RE-ENABLING IS THIS ONE CONSTANT.** Flip it to `true` and every door —
///    first owner entry, first rider entry, a mode switch, the post-pairing
///    hand-off and the invite-link arrival — resumes the MYR-428 behaviour, with
///    no other edit anywhere.
public enum FirstRunDemo {
    /// Whether a first entry may trigger the walkthrough. **OFF** — MYR-444.
    public static let enabled = false
}

// MARK: - The gate

/// Should entering `role` play its walkthrough?
///
/// One pure function over the two facts, so the answer is the same whichever door
/// the user came through — the mode chooser, the Settings switch row, a
/// stored-mode resume, or the onboarding hand-off that used to show a story deck.
/// `RootView.applyViewMode` is the single funnel the first three share (MYR-224),
/// which is why this needs no per-door reasoning: it is asked once, there.
///
/// **A demo is never played on a path that cannot support it.** `isSimulatedOnly`
/// is not a mode check on the app — it is the question "does this build have a
/// walkthrough to play at all", and it is `false` only where the walkthrough's own
/// fixtures are unavailable. See `FirstRunDemoHost`: the walkthrough composes its
/// OWN simulated seams, so the answer is unconditionally yes in the shipping app,
/// and this parameter exists so a DEBUG scene can say no without a second rule.
///
/// **MYR-444 — `enabled` is the kill switch and it is checked FIRST.** It
/// defaults to `FirstRunDemo.enabled`, so every shipping caller gets the client's
/// answer by saying nothing, and the parameter exists only so the MYR-428 rules
/// underneath it stay assertable from a test rather than becoming unreachable
/// code nobody can check. Its being first is deliberate: a switch placed below
/// the record question would still be correct here, and would be one refactor
/// away from a caller that reads the record before asking whether the feature is
/// on at all.
public enum FirstRunDemoGate {
    public static func playsWalkthrough(
        for role: FirstRunDemoRole,
        record: FirstRunDemoRecord,
        isAvailable: Bool = true,
        enabled: Bool = FirstRunDemo.enabled
    ) -> Bool {
        guard enabled else { return false }
        guard isAvailable else { return false }
        return !record.hasSeen(role)
    }
}
