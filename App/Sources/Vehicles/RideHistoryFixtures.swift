import CoreLocation
import Foundation

// MARK: - Ride history fixtures (MYR-191 — design/app/shared-screens.jsx
// 8-20 `REQUESTED_RIDES`/`SCHEDULED_RIDES`)
//
// M1 ships on fixture data only (CLAUDE.md "M1 is simulated") — no network.
// Mirrors `DriveFixtures.swift`'s precedent: the jsx fixtures have no geo
// route (`RideHistoryScreen`'s rows never render a map), but
// `ScheduledRideSheet`'s detail-mode map preview (shared-screens.jsx:352-364)
// does, so each `ScheduledRide` gets a plausible real-world route between its
// named endpoints — reusing `DriveFixtures`' "Home"/"Mission · Tartine"
// coordinates where the place names match, and introducing new waypoints
// only for places that fixture set doesn't already visit (SFO Terminal 2,
// Caltrain 4th & King).
//
// MYR-197 — `RequestedRide` also gets a route now: app.jsx:127-129 routes a
// tapped completed ride into `DriveSummaryScreen` (the SAME component the
// owner's `DrivesScreen` pushes, `screen==='rideSummary'` vs. `'driveSummary'`
// — see `RequestedRide.asDrive` below), and that screen's Swift port renders
// a real MapKit hero (`DriveHeroMap`, MYR-169) instead of the jsx's shared
// decorative SVG squiggle, so it needs real coordinates same as `DRIVES`/
// `SCHEDULED_RIDES` already do. New waypoints below (Ferry Building, Marina
// Blvd, Dolores Park, Tartine Manufactory) follow this file's existing
// precedent; "Work" reuses `DriveFixtures.financialDistrict`.

/// A ride booked for someone else — the "For {name}" pill (shared-screens.jsx
/// `RideForTag`, jsx field `for: { name, phone }`).
public struct RidePassenger: Equatable, Sendable {
    public let name: String
    public let phone: String

    public init(name: String, phone: String) {
        self.name = name
        self.phone = phone
    }

    /// shared-screens.jsx:25 `(person?.name || '').trim().split(/\s+/)[0]`.
    public var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// shared-screens.jsx:412 two-letter initials for the passenger avatar.
    public var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

/// A completed ride the rider personally requested (shared-screens.jsx:8-13
/// `REQUESTED_RIDES`).
public struct RequestedRide: Identifiable, Equatable, Sendable {
    public let id: String
    /// Grouping key rendered as a `Label` header — "Today" / "Yesterday" / a
    /// literal date (shared-screens.jsx:9-13 `day`).
    public let day: String
    public let date: String
    public let from: String
    public let to: String
    public let driver: String
    public let relationship: String // jsx `rel`
    public let vehicle: String
    public let start: String
    public let miles: Double
    public let mins: Int
    public let passenger: RidePassenger? // jsx `for`
    /// Real-world route feeding `DriveSummaryScreen`'s hero map when this
    /// ride is tapped open (MYR-197) — see file header. Defaults to `[]` so
    /// `SimulatedRideRequestService.buildRequestedRide` (a dynamically
    /// completed ride, no fixed named endpoints to look up) keeps compiling;
    /// `VehicleRoute.fittedRegion` degrades an empty route to a neutral
    /// region rather than crashing.
    public let route: [CLLocationCoordinate2D]

    public init(
        id: String,
        day: String,
        date: String,
        from: String,
        to: String,
        driver: String,
        relationship: String,
        vehicle: String,
        start: String,
        miles: Double,
        mins: Int,
        passenger: RidePassenger? = nil,
        route: [CLLocationCoordinate2D] = []
    ) {
        self.id = id
        self.day = day
        self.date = date
        self.from = from
        self.to = to
        self.driver = driver
        self.relationship = relationship
        self.vehicle = vehicle
        self.start = start
        self.miles = miles
        self.mins = mins
        self.passenger = passenger
        self.route = route
    }

    /// `CLLocationCoordinate2D` isn't `Equatable`, so `route` can't be
    /// synthesized — same pattern as `ScheduledRide`/`VehicleFixtures
    /// .DrivingTrip`.
    public static func == (lhs: RequestedRide, rhs: RequestedRide) -> Bool {
        lhs.id == rhs.id
            && lhs.day == rhs.day
            && lhs.date == rhs.date
            && lhs.from == rhs.from
            && lhs.to == rhs.to
            && lhs.driver == rhs.driver
            && lhs.relationship == rhs.relationship
            && lhs.vehicle == rhs.vehicle
            && lhs.start == rhs.start
            && lhs.miles == rhs.miles
            && lhs.mins == rhs.mins
            && lhs.passenger == rhs.passenger
            && lhs.route.count == rhs.route.count
            && zip(lhs.route, rhs.route).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }
}

// MARK: - RequestedRide → Drive adapter (MYR-197)

extension RequestedRide {
    /// screens.jsx:819-829 `normalizeDrive` — adapts a completed shared ride
    /// into the same `Drive` shape `DriveSummaryScreen` (MYR-169) already
    /// renders for the owner's own drives. app.jsx:127-129 pushes the
    /// *identical* `DriveSummaryScreen` component for a tapped
    /// `REQUESTED_RIDES` row (`drive={sharedDrive}`) as it does for a
    /// `DRIVES` row (`driveId={drivingDriveId}`) — this is the Swift
    /// counterpart of that reuse, not a second summary screen.
    ///
    /// Shared rides are always fully autonomous (screens.jsx comment directly
    /// above `normalizeDrive`: "Shared rides are 100% autonomous robotaxi
    /// trips"), so — matching `base.fsd != null ? base.fsd : base.miles` —
    /// `fsdMiles` defaults to the full trip distance, and `batteryDeltaPercent`
    /// derives from mileage the same way `chg` does when a base object
    /// doesn't already carry it (`-Math.max(2, Math.round(base.miles * 0.45))`).
    public var asDrive: Drive {
        Drive(
            id: id,
            dateGroup: day,
            start: start,
            end: Self.addClockMinutes(start, mins),
            from: from,
            to: to,
            miles: miles,
            mins: mins,
            fsdMiles: miles,
            batteryDeltaPercent: -max(2, Int((miles * 0.45).rounded())),
            route: route
        )
    }

    /// screens.jsx:809-816 `addClockMinutes` — ported verbatim (same 12h
    /// parse + mod-1440 wrap) so a completed ride's derived "end" time
    /// matches the prototype's math exactly. `REQUESTED_RIDES` has no `end`
    /// field (unlike `DRIVES`), so `normalizeDrive` computes it on the fly.
    private static func addClockMinutes(_ timeStr: String, _ mins: Int) -> String {
        let parts = timeStr.split(separator: " ")
        guard parts.count == 2 else { return timeStr }
        let clock = parts[0].split(separator: ":")
        guard clock.count == 2,
              let hour12 = Int(clock[0]),
              let minute = Int(clock[1])
        else { return timeStr }
        let isPM = parts[1].uppercased() == "PM"
        var hour24 = hour12 % 12
        if isPM { hour24 += 12 }
        let total = (((hour24 * 60 + minute + mins) % 1440) + 1440) % 1440
        var hh = total / 60
        let mm = total % 60
        let ap = hh >= 12 ? "PM" : "AM"
        hh = hh % 12
        if hh == 0 { hh = 12 }
        return String(format: "%d:%02d %@", hh, mm, ap)
    }
}

/// shared-screens.jsx:16 "status: confirmed = driver accepted; pending = awaiting."
public enum ScheduledRideStatus: String, Sendable, Equatable {
    case confirmed
    case pending
}

/// A ride the rider has scheduled for later (shared-screens.jsx:17-20
/// `SCHEDULED_RIDES`). Reference-typeless value struct — `RideHistoryState`
/// (MYR-191) owns the mutable array; reschedule/cancel replace elements
/// rather than mutating in place, mirroring `OwnerDrivesState.cancelUpcoming`.
public struct ScheduledRide: Identifiable, Equatable, Sendable {
    public let id: String
    public var day: String
    public var date: String
    public var time: String
    public let from: String
    public let to: String
    public let driver: String
    public let relationship: String
    public let vehicle: String
    public let miles: Double
    public var status: ScheduledRideStatus
    public let passenger: RidePassenger?
    /// Real-world route for `ScheduledRideSheet`'s map preview — see file
    /// header (not part of the jsx fixture, which has no geo data).
    public let route: [CLLocationCoordinate2D]

    public init(
        id: String,
        day: String,
        date: String,
        time: String,
        from: String,
        to: String,
        driver: String,
        relationship: String,
        vehicle: String,
        miles: Double,
        status: ScheduledRideStatus,
        passenger: RidePassenger? = nil,
        route: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.day = day
        self.date = date
        self.time = time
        self.from = from
        self.to = to
        self.driver = driver
        self.relationship = relationship
        self.vehicle = vehicle
        self.miles = miles
        self.status = status
        self.passenger = passenger
        self.route = route
    }

    /// shared-screens.jsx:232 `Math.max(6, Math.round(ride.miles * 1.7))`.
    public var estimatedMinutes: Int {
        max(6, Int((miles * 1.7).rounded()))
    }

    /// `CLLocationCoordinate2D` isn't `Equatable`, so `route` can't be
    /// synthesized — same pattern as `VehicleFixtures.DrivingTrip`.
    public static func == (lhs: ScheduledRide, rhs: ScheduledRide) -> Bool {
        lhs.id == rhs.id
            && lhs.day == rhs.day
            && lhs.date == rhs.date
            && lhs.time == rhs.time
            && lhs.from == rhs.from
            && lhs.to == rhs.to
            && lhs.driver == rhs.driver
            && lhs.relationship == rhs.relationship
            && lhs.vehicle == rhs.vehicle
            && lhs.miles == rhs.miles
            && lhs.status == rhs.status
            && lhs.passenger == rhs.passenger
            && lhs.route.count == rhs.route.count
            && zip(lhs.route, rhs.route).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }
}

public enum RideHistoryFixtures {
    /// shared-screens.jsx:8-13 `REQUESTED_RIDES`, same order (grouped by
    /// `day` on display — `RideHistoryScreen` preserves this array's order
    /// within each group, matching the jsx's `forEach` accumulation).
    public static let requestedRides: [RequestedRide] = [
        RequestedRide(
            id: "r1", day: "Today", date: "Jun 15",
            from: "Home", to: "Ferry Building",
            driver: "Alex", relationship: "Roommate", vehicle: "Cybercab",
            start: "9:12 AM", miles: 3.4, mins: 14,
            route: [home, ferryBuilding]
        ),
        RequestedRide(
            id: "r2", day: "Yesterday", date: "Jun 14",
            from: "Marina Blvd", to: "SFO · Terminal 2",
            driver: "Mom", relationship: "Family", vehicle: "Model Y",
            start: "6:40 AM", miles: 18.2, mins: 28,
            passenger: RidePassenger(name: "Maya Chen", phone: "(415) 555-0142"),
            route: [marinaBlvd, sfoTerminal2]
        ),
        RequestedRide(
            id: "r3", day: "Yesterday", date: "Jun 14",
            from: "SFO · Terminal 2", to: "Home",
            driver: "Jordan", relationship: "Friend", vehicle: "Model 3",
            start: "7:55 PM", miles: 17.9, mins: 31,
            route: [sfoTerminal2, home]
        ),
        RequestedRide(
            id: "r4", day: "Jun 11", date: "Jun 11",
            from: "Home", to: "Dolores Park",
            driver: "Alex", relationship: "Roommate", vehicle: "Cybercab",
            start: "2:05 PM", miles: 2.1, mins: 11,
            route: [home, doloresPark]
        ),
        RequestedRide(
            id: "r5", day: "Jun 9", date: "Jun 9",
            from: "Work", to: "Tartine Manufactory",
            driver: "Jordan", relationship: "Friend", vehicle: "Model 3",
            start: "12:30 PM", miles: 4.6, mins: 19,
            passenger: RidePassenger(name: "Dad", phone: "(415) 555-0193"),
            route: [DriveFixtures.financialDistrict, tartineManufactory]
        ),
    ]

    /// shared-screens.jsx:17-20 `SCHEDULED_RIDES` initial seed.
    public static let scheduledRides: [ScheduledRide] = [
        ScheduledRide(
            id: "s1", day: "Tomorrow", date: "Jun 17", time: "6:30 AM",
            from: "Home", to: "SFO · Terminal 2",
            driver: "Mom", relationship: "Family", vehicle: "Model Y",
            miles: 18.4, status: .confirmed,
            route: [home, sfoTerminal2]
        ),
        ScheduledRide(
            id: "s2", day: "Thu", date: "Jun 18", time: "9:00 AM",
            from: "Home", to: "Caltrain · 4th & King",
            driver: "Jordan", relationship: "Friend", vehicle: "Model 3",
            miles: 5.2, status: .pending,
            passenger: RidePassenger(name: "Maya Chen", phone: "(415) 555-0142"),
            route: [home, caltrainFourthAndKing]
        ),
        ScheduledRide(
            id: "s3", day: "Sat", date: "Jun 20", time: "7:15 PM",
            from: "Mission · Tartine", to: "Home",
            driver: "Alex", relationship: "Roommate", vehicle: "Cybercab",
            miles: 3.9, status: .confirmed,
            route: [missionTartine, home]
        ),
    ]

    // MARK: Route waypoints
    //
    // "Home" and "Mission · Tartine" reuse `DriveFixtures`' exact
    // coordinates so the same named place renders at the same map point
    // everywhere in the app.

    static let home = DriveFixtures.home
    static let missionTartine = DriveFixtures.missionTartine
    static let sfoTerminal2 = CLLocationCoordinate2D(latitude: 37.6156, longitude: -122.3900)
    static let caltrainFourthAndKing = CLLocationCoordinate2D(latitude: 37.7766, longitude: -122.3945)

    // MYR-197 — `REQUESTED_RIDES`' own named endpoints; "Work" reuses
    // `DriveFixtures.financialDistrict` (a plausible SF office district)
    // rather than inventing a coordinate for a placeholder name.
    static let ferryBuilding = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    static let marinaBlvd = CLLocationCoordinate2D(latitude: 37.8055, longitude: -122.4380)
    static let doloresPark = CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269)
    static let tartineManufactory = CLLocationCoordinate2D(latitude: 37.7669, longitude: -122.4108)
}
