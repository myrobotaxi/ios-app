import CoreLocation

// MARK: - Drive fixtures (MYR-169 — design/app/screens.jsx:27-33 `DRIVES`,
// app.jsx:34-37 `ownerUpcoming`)
//
// M1 ships on fixture data only (CLAUDE.md "M1 is simulated") — no network.
// `DRIVES` has no geo route (the jsx renders every drive summary against the
// same fixed SVG-space `DS_HERO_ROUTE`, screens.jsx:804-807 — literally the
// same decorative squiggle regardless of which drive is open). Real MapKit
// needs real coordinates, so this port gives each drive its own plausible
// real-world route between its named endpoints instead — reusing the exact
// "Home" / "Embarcadero Center" / "Half Moon Bay" coordinates already
// established by `VehicleFixtures.cybercabTrip`/`dailyParkedLocation` where
// the place names match, and introducing new waypoints only for places that
// vehicle doesn't already visit (Mission · Tartine, Tahoe Donner). Simulated
// only, never routed over network — same disclaimer as VehicleFixtures.

/// One completed drive (screens.jsx:27-33 `DRIVES`).
public struct Drive: Identifiable, Sendable {
    public let id: String
    /// Raw group key from the jsx (`'today' | 'yesterday' | 'Mon, May 4'`) —
    /// `Drive.groupLabel(for:)` maps it to display text (screens.jsx:627).
    public let dateGroup: String
    public let start: String
    public let end: String
    public let from: String
    public let to: String
    public let miles: Double
    public let mins: Int
    public let fsdMiles: Double
    /// Negative percent-points of battery consumed on this drive (jsx `chg`).
    public let batteryDeltaPercent: Int
    /// Real-world route standing in for the jsx's shared decorative SVG path
    /// — see file header. Empty for a live drive: contracts v0.6.0 Drive detail
    /// carries no coordinates (the route polyline is the separate §7.4 endpoint,
    /// which has no generated type yet), so `DriveSummaryScreen` renders a
    /// routeless hero for these.
    public let route: [CLLocationCoordinate2D]

    // MARK: Real stats (MYR-203) — non-nil ONLY for a live drive mapped from a
    // `DriveSummary`/`Drive` contract. `DriveSummaryScreen` prefers these over
    // its seeded fixture derivations when present; the M1 fixtures leave them nil
    // so the simulated Drive Summary is byte-for-byte unchanged.

    /// Server `avgSpeedMph`, rounded — else nil (fixtures seed their own).
    public let avgSpeedMPH: Int?
    /// Server `maxSpeedMph`, rounded — else nil.
    public let maxSpeedMPH: Int?
    /// Server `startChargeLevel` (0–100) — else nil.
    public let startChargePercent: Int?
    /// Server `endChargeLevel` (0–100) — else nil.
    public let endChargePercent: Int?
    /// Server `fsdPercentage`, rounded — else nil (fixtures derive fsd% from
    /// `fsdMiles/miles`). Prefer the authoritative wire value when present.
    public let fsdPercentOverride: Int?

    public init(
        id: String,
        dateGroup: String,
        start: String,
        end: String,
        from: String,
        to: String,
        miles: Double,
        mins: Int,
        fsdMiles: Double,
        batteryDeltaPercent: Int,
        route: [CLLocationCoordinate2D],
        avgSpeedMPH: Int? = nil,
        maxSpeedMPH: Int? = nil,
        startChargePercent: Int? = nil,
        endChargePercent: Int? = nil,
        fsdPercentOverride: Int? = nil
    ) {
        self.id = id
        self.dateGroup = dateGroup
        self.start = start
        self.end = end
        self.from = from
        self.to = to
        self.miles = miles
        self.mins = mins
        self.fsdMiles = fsdMiles
        self.batteryDeltaPercent = batteryDeltaPercent
        self.route = route
        self.avgSpeedMPH = avgSpeedMPH
        self.maxSpeedMPH = maxSpeedMPH
        self.startChargePercent = startChargePercent
        self.endChargePercent = endChargePercent
        self.fsdPercentOverride = fsdPercentOverride
    }

    /// screens.jsx:773 `((d.fsd / d.miles) * 100).toFixed(0)`. Prefers the
    /// authoritative wire `fsdPercentage` (`fsdPercentOverride`) for a live drive;
    /// guards the fixture derivation against a zero-mile drive.
    public var fsdPercent: Int {
        if let fsdPercentOverride { return fsdPercentOverride }
        guard miles > 0 else { return 0 }
        return Int(((fsdMiles / miles) * 100).rounded())
    }

    /// screens.jsx:627 `groupLabel` — 'today'/'yesterday' get display copy,
    /// every other key (already a literal day string, e.g. "Mon, May 4")
    /// passes through unchanged.
    public static func groupLabel(for dateGroup: String) -> String {
        switch dateGroup {
        case "today": "Today"
        case "yesterday": "Yesterday"
        default: dateGroup
        }
    }
}

/// One confirmed upcoming reservation (app.jsx:34-37 `ownerUpcoming`).
public struct UpcomingRide: Identifiable, Equatable, Sendable {
    public struct Destination: Equatable, Sendable {
        public let label: String
        public let subtitle: String
        public let miles: Double
        public let mins: Int

        public init(label: String, subtitle: String, miles: Double, mins: Int) {
            self.label = label
            self.subtitle = subtitle
            self.miles = miles
            self.mins = mins
        }
    }

    public let id: String
    public let rider: String
    public let destination: Destination
    /// screens.jsx `schedule.day` — a `DrivesScreen.dayOrder` key ("Today",
    /// "Tomorrow", "Thu"…) or a literal weekday.
    public let scheduleDay: String
    /// e.g. "6:40 AM".
    public let scheduleTime: String
    public let vehicleName: String

    public init(
        id: String,
        rider: String,
        destination: Destination,
        scheduleDay: String,
        scheduleTime: String,
        vehicleName: String
    ) {
        self.id = id
        self.rider = rider
        self.destination = destination
        self.scheduleDay = scheduleDay
        self.scheduleTime = scheduleTime
        self.vehicleName = vehicleName
    }
}

public enum DriveFixtures {
    /// screens.jsx:27-33 `DRIVES`, same order (History's default "date" sort
    /// is stable, so the on-screen order matches this array for same-day
    /// groups).
    public static let drives: [Drive] = [
        Drive(
            id: "d9", dateGroup: "today", start: "7:42 AM", end: "8:11 AM",
            from: "Home", to: "Embarcadero Center", miles: 14.6, mins: 29,
            fsdMiles: 14.2, batteryDeltaPercent: -6,
            route: [home, financialDistrict, embarcaderoCenter]
        ),
        Drive(
            id: "d8", dateGroup: "today", start: "5:18 PM", end: "5:54 PM",
            from: "Embarcadero Center", to: "Mission · Tartine", miles: 3.8, mins: 36,
            fsdMiles: 3.8, batteryDeltaPercent: -2,
            route: [embarcaderoCenter, sixthAndMarket, missionTartine]
        ),
        Drive(
            id: "d7", dateGroup: "yesterday", start: "9:02 AM", end: "10:34 AM",
            from: "Home", to: "Half Moon Bay · Sam's", miles: 28.4, mins: 92,
            fsdMiles: 27.9, batteryDeltaPercent: -12,
            route: [home, sanFrancisco, dalyCity, pacifica, montara, halfMoonBay]
        ),
        Drive(
            id: "d6", dateGroup: "yesterday", start: "2:21 PM", end: "4:08 PM",
            from: "Half Moon Bay · Sam's", to: "Home", miles: 29.1, mins: 107,
            fsdMiles: 28.6, batteryDeltaPercent: -13,
            route: [halfMoonBay, montara, pacifica, dalyCity, sanFrancisco, home]
        ),
        Drive(
            id: "d5", dateGroup: "Mon, May 4", start: "6:48 AM", end: "7:55 AM",
            from: "Home", to: "Tahoe Donner", miles: 184, mins: 215,
            fsdMiles: 178, batteryDeltaPercent: -52,
            route: [home, sacramento, auburn, tahoeDonner]
        ),
    ]

    public static func drive(id: String) -> Drive? {
        drives.first { $0.id == id }
    }

    /// app.jsx:34-37 `ownerUpcoming` initial seed.
    public static let upcomingRides: [UpcomingRide] = [
        UpcomingRide(
            id: "ou1",
            rider: "Mira",
            destination: .init(label: "SFO · Terminal 2", subtitle: "San Francisco International", miles: 18.4, mins: 32),
            scheduleDay: "Tomorrow",
            scheduleTime: "6:40 AM",
            vehicleName: "Cybercab"
        ),
        UpcomingRide(
            id: "ou2",
            rider: "Jonas",
            destination: .init(label: "Tahoe Donner", subtitle: "Truckee", miles: 184, mins: 215),
            scheduleDay: "Sat",
            scheduleTime: "7:00 AM",
            vehicleName: "Cybercab"
        ),
    ]

    // MARK: Route waypoints
    //
    // "Home" and "Embarcadero Center" reuse `VehicleFixtures`' exact
    // coordinates so the same named place renders at the same map point
    // everywhere in the app.

    static let home = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
    static let embarcaderoCenter = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    static let financialDistrict = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    static let sixthAndMarket = CLLocationCoordinate2D(latitude: 37.7790, longitude: -122.4090)
    static let missionTartine = CLLocationCoordinate2D(latitude: 37.7614, longitude: -122.4241)
    static let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    static let dalyCity = CLLocationCoordinate2D(latitude: 37.6879, longitude: -122.4702)
    static let pacifica = CLLocationCoordinate2D(latitude: 37.6305, longitude: -122.4286)
    static let montara = CLLocationCoordinate2D(latitude: 37.5299, longitude: -122.5089)
    static let halfMoonBay = CLLocationCoordinate2D(latitude: 37.4636, longitude: -122.4286)
    static let sacramento = CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944)
    static let auburn = CLLocationCoordinate2D(latitude: 38.8966, longitude: -121.0768)
    static let tahoeDonner = CLLocationCoordinate2D(latitude: 39.3407, longitude: -120.2288)
}
