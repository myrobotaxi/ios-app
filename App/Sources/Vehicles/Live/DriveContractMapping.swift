import Foundation
import MyRobotaxiContracts

// MARK: - Drive contracts → view-model mapping (MYR-203)
//
// The single PURE translation from the Kit's generated drive contracts
// (`DriveSummary` from GET /vehicles/{id}/drives, `Drive` detail from
// GET /drives/{id}) onto the app's existing `Drive` view model (DriveFixtures.
// swift) — the shape `DrivesScreen`/`DriveSummaryScreen` already render. Static,
// no I/O, so it is unit-testable with contracts fixtures and no network
// (deliverable 3), the same way `VehicleContractMapping` is.
//
// Consumption facts from the schema author, honored here:
// - `startLocation/startAddress/endLocation/endAddress` are ABSENT (nil) when
//   ungeocoded — NEVER "" — so a missing label is `nil`, and we degrade to the
//   street address, then to a neutral "Location unavailable" (the same calm copy
//   `VehicleContractMapping` uses for a fix-less parked vehicle). No enums.
// - `durationSeconds` is seconds; the view model wants whole minutes.
// - `fsdPercentage` is authoritative — prefer it over the fixture's
//   `fsdMiles/miles` derivation (`fsdPercentOverride`).
// - contracts v0.6.0 carries NO route coordinates (the polyline is the separate
//   §7.4 endpoint, ungenerated), so `route` is empty for a live drive.
enum DriveContractMapping {

    /// Neutral label for an endpoint the server could not reverse-geocode.
    /// Matches `VehicleContractMapping`'s parked-vehicle fallback for one calm
    /// voice across the app.
    static let unnamedLocation = "Location unavailable"

    // MARK: DriveSummary (list row) → app Drive

    static func appDrive(from summary: DriveSummary, now: Date = Date()) -> Drive {
        Drive(
            id: summary.id,
            dateGroup: dateGroup(isoDate: summary.date, isoStart: summary.startTime, now: now),
            start: clockLabel(iso: summary.startTime),
            end: clockLabel(iso: summary.endTime),
            from: label(name: summary.startLocation, address: summary.startAddress),
            to: label(name: summary.endLocation, address: summary.endAddress),
            miles: summary.distanceMiles,
            mins: minutes(fromSeconds: summary.durationSeconds),
            fsdMiles: summary.fsdMiles,
            batteryDeltaPercent: summary.endChargeLevel - summary.startChargeLevel,
            route: [],
            avgSpeedMPH: rounded(summary.avgSpeedMph),
            maxSpeedMPH: rounded(summary.maxSpeedMph),
            startChargePercent: summary.startChargeLevel,
            endChargePercent: summary.endChargeLevel,
            fsdPercentOverride: rounded(summary.fsdPercentage)
        )
    }

    // MARK: Drive (detail) → app Drive
    //
    // Same projection; the detail-only `energyUsedKwh`/`interventions` have no
    // slot in the current Drive Summary layout, so they are intentionally
    // dropped here (available on the contract for a future stat).

    static func appDrive(from detail: MyRobotaxiContracts.Drive, now: Date = Date()) -> Drive {
        Drive(
            id: detail.id,
            dateGroup: dateGroup(isoDate: detail.date, isoStart: detail.startTime, now: now),
            start: clockLabel(iso: detail.startTime),
            end: clockLabel(iso: detail.endTime),
            from: label(name: detail.startLocation, address: detail.startAddress),
            to: label(name: detail.endLocation, address: detail.endAddress),
            miles: detail.distanceMiles,
            mins: minutes(fromSeconds: detail.durationSeconds),
            fsdMiles: detail.fsdMiles,
            batteryDeltaPercent: detail.endChargeLevel - detail.startChargeLevel,
            route: [],
            avgSpeedMPH: rounded(detail.avgSpeedMph),
            maxSpeedMPH: rounded(detail.maxSpeedMph),
            startChargePercent: detail.startChargeLevel,
            endChargePercent: detail.endChargeLevel,
            fsdPercentOverride: rounded(detail.fsdPercentage)
        )
    }

    // MARK: - Helpers

    /// Absent name → street address → neutral fallback. Trims whitespace and
    /// treats an all-blank value as absent (belt-and-suspenders — the wire omits
    /// the key entirely rather than sending "").
    static func label(name: String?, address: String?) -> String {
        nonEmpty(name) ?? nonEmpty(address) ?? unnamedLocation
    }

    static func minutes(fromSeconds seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded())
    }

    static func rounded(_ value: Double) -> Int { Int(value.rounded()) }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Date / time formatting

    /// A raw `dateGroup` key for `Drive.groupLabel(for:)`: "today"/"yesterday"
    /// pass through to display copy; any other day becomes a literal "Mon, May 4"
    /// string (the same shape the fixtures use), so grouping/formatting is
    /// identical to the M1 path.
    static func dateGroup(isoDate: String, isoStart: String, now: Date) -> String {
        let cal = Calendar.current
        // Prefer the instant timestamp (has a zone); fall back to the YYYY-MM-DD.
        let day = parseInstant(isoStart) ?? parseDay(isoDate)
        guard let day else { return isoDate }
        // Relative to the injected `now` (calendar-day difference), NOT the
        // device clock — so grouping is deterministic under test and correct at
        // runtime where `now == Date()`.
        let startOfDrive = cal.startOfDay(for: day)
        let startOfNow = cal.startOfDay(for: now)
        let dayDelta = cal.dateComponents([.day], from: startOfDrive, to: startOfNow).day ?? 0
        if dayDelta == 0 { return "today" }
        if dayDelta == 1 { return "yesterday" }
        return Self.dayGroupFormatter.string(from: day)
    }

    static func clockLabel(iso: String) -> String {
        guard let date = parseInstant(iso) else { return "" }
        return Self.clockFormatter.string(from: date)
    }

    private static func parseInstant(_ iso: String) -> Date? {
        Self.iso8601.date(from: iso) ?? Self.iso8601Fractional.date(from: iso)
    }

    private static func parseDay(_ isoDate: String) -> Date? {
        Self.dayParser.date(from: isoDate)
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// "YYYY-MM-DD" (the `date` field) as a local calendar day.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// "7:42 AM" — matches the fixtures' `start`/`end` copy.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()
    /// "Mon, May 4" — matches the fixtures' literal weekday `dateGroup` keys.
    private static let dayGroupFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d"
        return f
    }()
}
