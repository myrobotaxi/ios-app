import CoreLocation

// MARK: - Ride request fixtures (MYR-171 — design/app/ride-request.jsx
// SAVED_PLACES/RECENT_PLACES/PIN_SPOTS 1-11,36-42; design/app/screens.jsx
// FLEET 15-19)
//
// M1 ships on fixture data only (CLAUDE.md "M1 is simulated") — no network,
// no real geocoding. Coordinates are plausible SF-area points (reusing
// `DriveFixtures.home`/`.missionTartine` where the named place matches, same
// precedent `RideHistoryFixtures` set for SFO Terminal 2/Caltrain) so the
// review/booking/tracking route line renders somewhere sensible on the real
// MapKit background.

/// A place the rider can pick as a destination or (via "Set on map") a
/// pickup — ride-request.jsx `DestRow`'s backing shape
/// `{ id, label, sub, miles, min }`.
public struct RidePlace: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let subtitle: String?
    public let miles: Double
    public let minutes: Int
    public let icon: String // SF Symbol name
    public let coordinate: CLLocationCoordinate2D

    public init(id: String, label: String, subtitle: String?, miles: Double, minutes: Int, icon: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.miles = miles
        self.minutes = minutes
        self.icon = icon
        self.coordinate = coordinate
    }

    /// `CLLocationCoordinate2D` isn't `Equatable` — same pattern as
    /// `ScheduledRide`/`VehicleFixtures.DrivingTrip`.
    public static func == (lhs: RidePlace, rhs: RidePlace) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label && lhs.subtitle == rhs.subtitle
            && lhs.miles == rhs.miles && lhs.minutes == rhs.minutes && lhs.icon == rhs.icon
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// Whose Tesla — the Review step's fleet picker (design/app/screens.jsx:15-19
/// `FLEET`).
public struct FleetMember: Identifiable, Sendable, Equatable {
    public let id: String
    public let owner: String
    public let relationship: String // jsx `rel`
    public let name: String // "Model Y"
    public let model: String // "2025 Tesla" style long name, ride-request.jsx PendingContent
    /// jsx `FLEET[].color` — the vehicle's paint color (e.g. "Quicksilver"),
    /// distinct from `owner`/`name`. `PendingContent`/`TrackingContent`'s
    /// "Your ride"/"Look for" card headlines on `{colorName} {name}` (e.g.
    /// "Quicksilver Model Y"), subline on `model` alone (ride-request.jsx
    /// 606-607,762-763 `vColor`/`carColor` + `vYearMake`/`carYearMake`) — see
    /// `RideRequestTrackingContent.rideRow`'s MYR-199 fix comment.
    public let colorName: String
    public let battery: Int
    public let etaMin: Int
    public let plate: String

    public init(id: String, owner: String, relationship: String, name: String, model: String, colorName: String, battery: Int, etaMin: Int, plate: String) {
        self.id = id
        self.owner = owner
        self.relationship = relationship
        self.name = name
        self.model = model
        self.colorName = colorName
        self.battery = battery
        self.etaMin = etaMin
        self.plate = plate
    }
}

/// Quick-pick "for someone else" contact (ride-request.jsx:36-39 `RECENT_PASSENGERS`).
public struct RecentPassengerOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let phone: String
    public init(name: String, phone: String) {
        self.id = name
        self.name = name
        self.phone = phone
    }
}

public enum RideRequestFixtures {
    /// design/app/ride-request.jsx `SAVED_PLACES` — Home/Work/Equinox SoMa,
    /// rendered in Search's "SAVED" section AND (Home/Work only) as the idle
    /// sheet's quick chips (MYR-191).
    public static let savedPlaces: [RidePlace] = [
        RidePlace(id: "home", label: "Home", subtitle: "221 Folsom St, San Francisco", miles: 4.2, minutes: 18, icon: "house.fill", coordinate: DriveFixtures.home),
        RidePlace(id: "work", label: "Work", subtitle: "88 Marina Blvd, San Francisco", miles: 5.1, minutes: 22, icon: "briefcase.fill", coordinate: DriveFixtures.embarcaderoCenter),
        RidePlace(id: "gym", label: "Equinox SoMa", subtitle: "301 Mission St", miles: 0.9, minutes: 7, icon: "figure.run", coordinate: DriveFixtures.financialDistrict),
    ]

    /// design/app/ride-request.jsx `RECENT_PLACES`.
    public static let recentPlaces: [RidePlace] = [
        RidePlace(id: "tartine", label: "Tartine Bakery", subtitle: "600 Guerrero St \u{00B7} Mission", miles: 3.1, minutes: 14, icon: "mappin", coordinate: DriveFixtures.missionTartine),
        RidePlace(id: "sfo", label: "SFO \u{00B7} Terminal 2", subtitle: "San Francisco International", miles: 18.4, minutes: 32, icon: "mappin", coordinate: RideHistoryFixtures.sfoTerminal2),
        RidePlace(id: "ferry", label: "Ferry Building", subtitle: "1 Ferry Building \u{00B7} Embarcadero", miles: 0.6, minutes: 6, icon: "mappin", coordinate: DriveFixtures.embarcaderoCenter),
        RidePlace(id: "duartes", label: "Duarte\u{2019}s Tavern", subtitle: "202 Stage Rd \u{00B7} Pescadero", miles: 41.2, minutes: 87, icon: "mappin", coordinate: DriveFixtures.pacifica),
    ]

    /// design/app/ride-request.jsx `NEARBY_PLACES`-equivalent (nearby section).
    public static let nearbyPlaces: [RidePlace] = [
        RidePlace(id: "oceanbeach", label: "Ocean Beach", subtitle: nil, miles: 8.4, minutes: 24, icon: "beach.umbrella.fill", coordinate: CLLocationCoordinate2D(latitude: 37.7594, longitude: -122.5107)),
        RidePlace(id: "crissyfield", label: "Crissy Field", subtitle: nil, miles: 4.6, minutes: 16, icon: "leaf.fill", coordinate: CLLocationCoordinate2D(latitude: 37.8036, longitude: -122.4660)),
        RidePlace(id: "sfmoma", label: "SFMOMA", subtitle: nil, miles: 1.2, minutes: 8, icon: "building.columns.fill", coordinate: DriveFixtures.sixthAndMarket),
    ]

    /// design/app/ride-request.jsx `PIN_SPOTS` — six fake reverse-geocoded
    /// strings for the drop-a-pin flow, selected deterministically by drag
    /// distance (not real geocoding — see `PinDropContent`'s doc comment).
    public static let pinSpots: [String] = [
        "Folsom & 2nd St", "Embarcadero Plaza", "Howard & Spear St",
        "Mission & Main St", "Beale St \u{00B7} Rincon Hill", "Steuart St \u{00B7} Ferry",
    ]

    /// design/app/screens.jsx:15-19 `FLEET` — the Teslas shared with the
    /// rider. `fleet[0]` is the default selection in Review.
    public static let fleet: [FleetMember] = [
        FleetMember(id: "alex", owner: "Alex", relationship: "Roommate", name: "Model Y", model: "2025 Tesla", colorName: "Quicksilver", battery: 68, etaMin: 3, plate: "RBO-2046"),
        FleetMember(id: "mom", owner: "Mom", relationship: "Family", name: "Model Y", model: "2024 Tesla", colorName: "Pearl White", battery: 91, etaMin: 8, plate: "RBO-7731"),
        FleetMember(id: "jordan", owner: "Jordan", relationship: "Friend", name: "Model 3", model: "2023 Tesla", colorName: "Midnight Silver", battery: 54, etaMin: 12, plate: "RBO-4419"),
    ]

    /// design/app/ride-request.jsx:36-39 `RECENT_PASSENGERS`.
    public static let recentPassengers: [RecentPassengerOption] = [
        RecentPassengerOption(name: "Maya Chen", phone: "(415) 555-0142"),
        RecentPassengerOption(name: "Dad", phone: "(415) 555-0193"),
    ]

    /// ScheduledRideSheet's exact day/time chip sets — reused verbatim for
    /// the ride-request Schedule sheet (ride-request.jsx uses the same
    /// `['Today','Tomorrow','Thu','Fri','Sat','Sun','Mon']` + half-hour grid,
    /// just with a different CTA copy).
    public static let scheduleDays = ["Today", "Tomorrow", "Thu", "Fri", "Sat", "Sun", "Mon"]
    public static let scheduleTimes: [String] = {
        var out: [String] = []
        for hour in 7...22 {
            for minute in [0, 30] {
                let meridiem = hour >= 12 ? "PM" : "AM"
                let hour12 = hour % 12 == 0 ? 12 : hour % 12
                out.append("\(hour12):\(minute == 0 ? "00" : "30") \(meridiem)")
            }
        }
        return out
    }()
}
