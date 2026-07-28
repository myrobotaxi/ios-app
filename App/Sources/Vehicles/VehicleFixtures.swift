import CoreLocation

// MARK: - Vehicle fixtures (MYR-167 — design/app/screens.jsx:9-12 `VEHICLES`)
//
// M1 ships on fixture data only (CLAUDE.md "M1 is simulated") — no network,
// no `MyRoboTaxiKit`. The jsx's `driving` flag is a single app-wide toggle
// (app.jsx `tweaks.vehicleState`) flipped by its Tweaks devtool, independent
// of which vehicle is selected. For a fixed, network-free M1 fixture that
// still has to demonstrate *both* the driving and parked hero states without
// a dev toggle, this port instead gives each vehicle its own fixed activity —
// Cybercab driving, Daily parked — so switching vehicles in the picker (§6)
// exercises both `HomeSheetContent` states. This is a fixture-data choice,
// not a visual/motion deviation: both states render pixel-for-pixel per
// screens.jsx `DrivingSheetContent`/`ParkedSheetContent`.

/// Tire pressures per wheel (vehicle-controls.jsx:398-409). Standard Tesla
/// fleet-telemetry fields (`TpmsPressureFl/Fr/Rl/Rr`) but NOT in the generated
/// `VehicleState` contract yet — so fixtures carry them and the LIVE path leaves
/// them `nil` → honest-unknown until they're contracted (MYR-255 gap list).
public struct TirePressures: Equatable, Sendable {
    public let fl: Int
    public let fr: Int
    public let rl: Int
    public let rr: Int

    public init(fl: Int, fr: Int, rl: Int, rr: Int) {
        self.fl = fl
        self.fr = fr
        self.rl = rl
        self.rr = rr
    }
}

/// One vehicle (screens.jsx:9-12 `VEHICLES`).
public struct Vehicle: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let model: String
    public let colorName: String
    public let plate: String
    public let seatHeat: Bool
    public let seatVent: Bool
    public let activity: VehicleActivity
    /// Full 17-char VIN. Now on the `VehicleState` snapshot (owner-masked,
    /// telemetry PR #325 / contracts v0.13.0 — MYR-279), mapped onto the live
    /// `Vehicle`; `nil` before the first snapshot → the detail row reads
    /// honest-unknown. The switcher/plate row shows the `VIN ····last4` from the
    /// summary. The fixture supplies a value so the SIMULATED sheet is unchanged.
    public let vin: String?
    /// Tesla software/firmware version. Now on the `VehicleState` snapshot
    /// (contracts v0.13.0 — MYR-279); `nil` before the first snapshot →
    /// honest-unknown. Fixture supplies a value for the SIMULATED path.
    public let softwareVersion: String?
    /// MYR-320 — the car's FSD software designation exactly as Tesla names it
    /// ("FSD (Supervised) v14.3.5"), from `VehicleState.fsdVersion` (contracts
    /// 0.18.0). DISTINCT from `softwareVersion`, which is the installed firmware
    /// build ("2026.14.3"): the two strings move independently and neither can be
    /// derived from the other, which is why they are two rows rather than one.
    ///
    /// `nil` means the row is OMITTED ENTIRELY — no "Unknown", no placeholder dash
    /// — because absence is common and normal (a server predating MYR-320, or a
    /// release-notes read that hasn't completed) and never means the car lacks FSD.
    /// The fixture leaves it nil, so the SIMULATED sheet is unchanged: this row is
    /// not in the prototype's details list and appears only on a real snapshot.
    public let fsdVersion: String?
    /// Per-wheel tire pressures. Not contracted → fixture-only; `nil` live →
    /// honest-unknown (MYR-255 gap list).
    public let tirePressures: TirePressures?

    public init(
        id: String,
        name: String,
        model: String,
        colorName: String,
        plate: String,
        seatHeat: Bool,
        seatVent: Bool,
        activity: VehicleActivity,
        vin: String? = nil,
        softwareVersion: String? = nil,
        fsdVersion: String? = nil,
        tirePressures: TirePressures? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.colorName = colorName
        self.plate = plate
        self.seatHeat = seatHeat
        self.seatVent = seatVent
        self.activity = activity
        self.vin = vin
        self.softwareVersion = softwareVersion
        self.fsdVersion = fsdVersion
        self.tirePressures = tirePressures
    }
}

/// A vehicle's fixed M1 activity — which `HomeSheetContent` hero it shows
/// and the fixture geometry/labels that go with it.
public enum VehicleActivity: Equatable, Sendable {
    case driving(DrivingTrip)
    case parked(ParkedLocation)

    /// Whether this activity is the driving case — used to seed
    /// `SimulatedVehicleCommandExecutor`'s `mediaPlaying` default
    /// (vehicle-controls.jsx:222 `useState(driving)`).
    public var isDriving: Bool {
        if case .driving = self { true } else { false }
    }

    /// The vehicle's parked location, when parked (nil while driving) — feeds
    /// `VehicleControls`' Status & location section.
    public var parkedLocation: ParkedLocation? {
        if case .parked(let location) = self { location } else { nil }
    }
}

/// screens.jsx `DrivingSheetContent` (lines 439-499) hardcodes its
/// destination/route strings locally rather than taking them as props —
/// ported here as fixture data so the Live Map screen has something to
/// render without a backend.
public struct DrivingTrip: Equatable, Sendable {
    /// screens.jsx:440 `destName`.
    public let destinationName: String
    /// screens.jsx:441 `destCity`.
    public let destinationCity: String
    /// screens.jsx:492 `RouteLeg` origin title.
    public let originLabel: String
    /// screens.jsx:492 `RouteLeg` origin subtitle.
    public let originAddress: String
    /// screens.jsx:493 `RouteLeg` destination subtitle.
    public let destinationAddress: String
    /// Real-world route coordinates standing in for the jsx's local SVG-space
    /// `buildSampleRoute()` (screens.jsx:45-49) — MapKit needs geo coordinates,
    /// not canvas points. Traces Highway 1 from San Francisco to Pescadero,
    /// matching the fixture addresses above (and `STOPS_SAMPLE`'s "Half Moon
    /// Bay", screens.jsx:22-25). Simulated only — never routed over network.
    public let route: [CLLocationCoordinate2D]

    public init(
        destinationName: String,
        destinationCity: String,
        originLabel: String,
        originAddress: String,
        destinationAddress: String,
        route: [CLLocationCoordinate2D]
    ) {
        self.destinationName = destinationName
        self.destinationCity = destinationCity
        self.originLabel = originLabel
        self.originAddress = originAddress
        self.destinationAddress = destinationAddress
        self.route = route
    }

    public static func == (lhs: DrivingTrip, rhs: DrivingTrip) -> Bool {
        lhs.destinationName == rhs.destinationName
            && lhs.destinationCity == rhs.destinationCity
            && lhs.originLabel == rhs.originLabel
            && lhs.originAddress == rhs.originAddress
            && lhs.destinationAddress == rhs.destinationAddress
            && lhs.route.count == rhs.route.count
            && zip(lhs.route, rhs.route).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }
}

/// screens.jsx `ParkedSheetContent` 'floating' style (lines 543-565)
/// hardcodes "Embarcadero Center · Lot B" / a parked-duration — ported here
/// as fixture data.
public struct ParkedLocation: Equatable, Sendable {
    /// screens.jsx:561 peek row label.
    public let label: String
    /// Real-world coordinate for the map annotation (jsx has no geo
    /// coordinate — it places the marker at a fixed SVG point).
    public let coordinate: CLLocationCoordinate2D
    /// When the vehicle parked — screens.jsx:562 "1h 42m" is derived here
    /// from wall-clock elapsed time. `nil` = UNKNOWN: the live `VehicleState`
    /// contract carries no park-start timestamp, so on the live path we cannot
    /// know it (deriving it from the ~1Hz `lastUpdated` freshness stamp made it
    /// read a perpetual "0m" — MYR-268). Views hide the duration when nil rather
    /// than show a fabricated 0. The simulated fixture supplies a real date.
    public let parkedSince: Date?

    public init(label: String, coordinate: CLLocationCoordinate2D, parkedSince: Date?) {
        self.label = label
        self.coordinate = coordinate
        self.parkedSince = parkedSince
    }

    public static func == (lhs: ParkedLocation, rhs: ParkedLocation) -> Bool {
        lhs.label == rhs.label
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.parkedSince == rhs.parkedSince
    }
}

public enum VehicleFixtures {
    /// screens.jsx:9-12 `VEHICLES` — order matters (MapHeader picker + the
    /// default selected index).
    public static let vehicles: [Vehicle] = [
        Vehicle(
            id: "v1",
            name: "Cybercab",
            model: "2026 Tesla Cybercab",
            colorName: "Mercury Silver",
            plate: "RBO-2046",
            seatHeat: true,
            seatVent: true,
            activity: .driving(cybercabTrip),
            // vehicle-controls.jsx:398-425 fixture detail stats — carried on the
            // fixture so the SIMULATED sheet renders the exact VIN/Software/tires
            // it did in M1; the LIVE path leaves these nil → honest-unknown.
            vin: "7SAYGDEE9PA142184",
            softwareVersion: "2026.14.3",
            tirePressures: TirePressures(fl: 42, fr: 42, rl: 41, rr: 43)
        ),
        Vehicle(
            id: "v2",
            name: "Daily",
            model: "2024 Model 3 LR",
            colorName: "Pearl White",
            plate: "CTX-9417",
            seatHeat: true,
            seatVent: false,
            activity: .parked(dailyParkedLocation),
            vin: "7SAYGDEE9PA142184",
            softwareVersion: "2026.14.3",
            tirePressures: TirePressures(fl: 42, fr: 42, rl: 41, rr: 43)
        ),
    ]

    /// screens.jsx:440-441,492-493 — Home (221 Folsom St, San Francisco) →
    /// Pescadero · Duarte's Tavern (202 Stage Rd, Pescadero) down Highway 1.
    static let cybercabTrip = DrivingTrip(
        destinationName: "Duarte's Tavern",
        destinationCity: "Pescadero",
        originLabel: "Home",
        originAddress: "221 Folsom St, San Francisco",
        destinationAddress: "202 Stage Rd, Pescadero",
        route: [
            CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971), // Home — Folsom St, SF
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194), // SF
            CLLocationCoordinate2D(latitude: 37.6879, longitude: -122.4702), // Daly City coast
            CLLocationCoordinate2D(latitude: 37.6305, longitude: -122.4286), // Pacifica
            CLLocationCoordinate2D(latitude: 37.5299, longitude: -122.5089), // Montara
            CLLocationCoordinate2D(latitude: 37.4636, longitude: -122.4286), // Half Moon Bay (STOPS_SAMPLE)
            CLLocationCoordinate2D(latitude: 37.3861, longitude: -122.3925), // San Gregorio
            CLLocationCoordinate2D(latitude: 37.2554, longitude: -122.3800), // Pescadero — Duarte's Tavern
        ]
    )

    /// screens.jsx:561 "Embarcadero Center · Lot B".
    static let dailyParkedLocation = ParkedLocation(
        label: "Embarcadero Center · Lot B",
        coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937),
        parkedSince: Date().addingTimeInterval(-(1 * 3600 + 42 * 60)) // matches jsx's "1h 42m"
    )
}
