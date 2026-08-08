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

/// MYR-233 — WHY a vehicle cannot take an INSTANT request right now. `nil`
/// (absent from `FleetMember`) is the only "requestable" value; each case
/// carries the word the rider sees, so the copy and the gate can never
/// disagree. Deliberately distinct from MYR-212's `isAvailable`/
/// `availabilityWord` pair, which also covers `driving` — a car mid-drive is
/// "not bookable now" but is NOT one of the three states MYR-233 gates the
/// instant CTA on (see `LiveFleetMemberMapping.unavailability`).
public enum FleetUnavailability: String, Sendable, Equatable, CaseIterable {
    /// `VehicleSummary.hasActiveRide == true` — the car is carrying SOMEONE
    /// ELSE's open instant ride (accepted / arrived / enroute).
    case busy
    /// Wire status `in_service`.
    case inService
    /// Wire status `offline`.
    case offline
    /// MYR-342 — `VehicleSummary.rideShareEnabled == false`: the OWNER has paused
    /// ride requests for this car.
    ///
    /// The odd one out, and every rule below turns on the difference. The other
    /// three are facts about the CAR (or about a ride it is already on) and every
    /// one of them ENDS on its own — a ride finishes, a service visit completes, a
    /// car comes back online. A pause is an OWNER INTENTION and is open-ended:
    /// nothing clears it but the owner reaching for the switch again.
    ///
    /// That is why the server refuses SCHEDULED rides against a paused car as well
    /// as instant ones (rest-api.md §7.18), a deliberate deviation from the
    /// reservation exemption MYR-313 grants the other three — and therefore why
    /// this case alone offers the rider no "Schedule instead" route.
    case paused

    /// The rider-facing word — the muted chip's label AND the vehicle row's
    /// status word. One source so they can never drift.
    public var word: String {
        switch self {
        case .busy: return "Busy"
        case .inService: return "In service"
        case .offline: return "Offline"
        // MYR-342 — "Paused", chosen over the more precise "Rides off" on a
        // MEASUREMENT, not a preference: at the MYR-335 four-column budget (49.75pt
        // on the narrowest supported device, 11pt semibold) "Rides off" overflows
        // and "Paused" clears it with room to spare. It is also the word the
        // OWNER's own row leads with, so both people see the same word for the same
        // state. See `RideSharePauseTests
        // .testChipWordFitsTheFourColumnBudgetAndRejectsTheAlternative`, which
        // records the rejected alternative alongside the chosen one.
        case .paused: return "Paused"
        }
    }

    /// MYR-352 — the rider-facing VERB CLAUSE for this reason: the middle of a
    /// sentence whose subject is the vehicle's name.
    ///
    /// The word ("Busy") is a chip label; this is what the app says when it has a
    /// whole line. It is factored out rather than written twice because MYR-233's
    /// Review helper line and MYR-352's idle banner are the same sentence about the
    /// same fact, and two copies of it are two places for the grammar to drift —
    /// which matters here more than usual, since `paused` is the case whose
    /// sentence is shaped differently from its three siblings ("has paused ride
    /// requests", not "is …"). Composing from a shared clause is what keeps that
    /// difference in ONE place.
    ///
    /// `RideRequestReviewContent.helperText` renders `"{owner} {clause} right now"`
    /// (+ " — schedule a pickup instead" when ``offersScheduling``), which is
    /// byte-identical to the four strings MYR-233/342 shipped —
    /// `RiderIdleAvailabilityTests.testTheReviewHelperCopyIsUnchangedByTheSharedClause`
    /// pins that.
    public var riderClause: String {
        switch self {
        case .busy: return "is on another ride"
        case .inService: return "is in service"
        case .offline: return "is offline"
        case .paused: return "has paused ride requests"
        }
    }

    /// MYR-342 — whether this reason leaves SCHEDULING open as an alternative.
    ///
    /// MYR-233's rule was "never a dead end": an unavailable car replaces the gold
    /// instant CTA with a muted route into the scheduling flow. That rule survives
    /// intact for the three reasons that END on their own — the car will be back,
    /// and the server accepts a reservation against it (MYR-313).
    ///
    /// A pause is the exception, and offering scheduling would be a WORSE dead end
    /// than offering nothing: the server refuses scheduled rides against a paused
    /// car on all three enforcement layers, so the rider would pick a pickup, a
    /// time and a passenger and be `409 vehicle_unavailable`'d at the very end. The
    /// CTA area shows the helper line alone instead — one honest sentence, at the
    /// start, costing nothing.
    public var offersScheduling: Bool {
        switch self {
        case .busy, .inService, .offline: return true
        case .paused: return false
        }
    }

    /// MYR-342 — whether a draft that ALREADY carries a schedule is exempt from
    /// this reason.
    ///
    /// The other side of the same coin as ``offersScheduling``, and it must be
    /// stated separately because the two answer different questions: this one is
    /// about a request the rider has already made scheduled, not about what to
    /// offer them next. MYR-233 exempts scheduled drafts wholesale, on the
    /// contract's own guidance that a reservation is outside the availability
    /// index. §7.18 removes a paused car from that exemption in as many words —
    /// "the pause does NOT inherit that exemption, on any layer" — so a scheduled
    /// draft against a paused car is gated exactly like an instant one.
    public var exemptWhenScheduled: Bool { offersScheduling }
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
    /// MYR-212: whether the vehicle is bookable now — drives the green dot +
    /// the "now" suffix in the Review vehicle row. Fixtures are always
    /// available (the design's resting state); a live join folds in the real
    /// telemetry status (`LiveFleetMemberMapping`).
    public let isAvailable: Bool
    /// MYR-212: the status word shown in the vehicle row ("Available" normally,
    /// a live status like "Driving"/"Offline" for an unavailable live vehicle).
    /// Defaults to "Available" so every fixture row renders identically.
    public let availabilityWord: String
    /// MYR-233: why this vehicle can't take an INSTANT request right now, or
    /// `nil` when it can. Drives the Review row's muted Busy/unavailable chip
    /// and the instant-CTA gate. Defaults to `nil` so every fixture row — and
    /// therefore every simulated / DEBUG scene — renders exactly as before.
    public let unavailability: FleetUnavailability?
    /// MYR-316 — when this vehicle's CURRENT service visit is estimated to end
    /// (contracts 0.17.0 `VehicleSummary.serviceEstimatedEndAt`). Non-nil only for
    /// a car whose status is in_service AND whose visit has a known estimate —
    /// Tesla's, or the owner's own entry. Drives the rider scheduling picker's
    /// FLOOR and the muted caption on the scheduling card.
    ///
    /// `nil` — the default, and therefore every fixture, and therefore every
    /// simulated / DEBUG scene — means NO BOUND: scheduling stays fully open. The
    /// contract states this as a consumer rule in as many words; a client that
    /// blocked on missing data would make the common case (a service visit with no
    /// Tesla appointment record) unbookable.
    public let serviceEstimatedEndAt: Date?

    /// MYR-233 — the single gate the instant-request CTA reads. True when the
    /// rider may submit an on-demand request against this vehicle.
    public var isRequestable: Bool { unavailability == nil }

    /// MYR-233 own-ride exception: the same member with any unavailability
    /// cleared, for the ONE rider who owns the open ride (they see the vehicle
    /// as their active ride, never as Busy). Also restores the MYR-212
    /// dot/word pair so the row reads exactly as it did before this issue.
    public func clearingUnavailability() -> FleetMember {
        guard let unavailability else { return self }
        return FleetMember(
            id: id, owner: owner, relationship: relationship, name: name, model: model,
            colorName: colorName, battery: battery, etaMin: etaMin, plate: plate,
            // `busy` rides on top of an otherwise-bookable status (parked /
            // charging), so clearing it returns the row to "Available"; an
            // in_service / offline car is still genuinely not bookable, so it
            // keeps MYR-212's muted dot + live status word.
            isAvailable: unavailability == .busy,
            availabilityWord: unavailability == .busy ? "Available" : unavailability.word,
            unavailability: nil,
            // MYR-316 — the own-ride exception is about BUSY, never about a
            // service visit. The window is a fact about the car and survives it
            // untouched: a rider mid-ride still cannot schedule a pickup before
            // the car is out of service.
            serviceEstimatedEndAt: serviceEstimatedEndAt
        )
    }

    /// MYR-341 — the same member carrying a REAL pickup ETA. The live mapping
    /// emits `etaMin: 0` ("no estimate"); `SharedViewerState.liveFleetMember`
    /// calls this once the rider + vehicle anchors exist, so Review's "N min
    /// away" and Booking's pickup clock quote the same number the idle
    /// placeholder does. Nothing else about the member changes.
    public func withPickupETA(_ minutes: Int) -> FleetMember {
        FleetMember(
            id: id, owner: owner, relationship: relationship, name: name, model: model,
            colorName: colorName, battery: battery, etaMin: minutes, plate: plate,
            isAvailable: isAvailable, availabilityWord: availabilityWord,
            unavailability: unavailability, serviceEstimatedEndAt: serviceEstimatedEndAt
        )
    }

    public init(id: String, owner: String, relationship: String, name: String, model: String, colorName: String, battery: Int, etaMin: Int, plate: String, isAvailable: Bool = true, availabilityWord: String = "Available", unavailability: FleetUnavailability? = nil, serviceEstimatedEndAt: Date? = nil) {
        self.id = id
        self.owner = owner
        self.relationship = relationship
        self.name = name
        self.model = model
        self.colorName = colorName
        self.battery = battery
        self.etaMin = etaMin
        self.plate = plate
        self.isAvailable = isAvailable
        self.availabilityWord = availabilityWord
        self.unavailability = unavailability
        self.serviceEstimatedEndAt = serviceEstimatedEndAt
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


    /// **LEGACY — DO NOT WIRE THIS BACK INTO THE PICKER (MYR-370).**
    ///
    /// The prototype's literal day row, transcribed from `ride-request.jsx`. It
    /// is a snapshot of ONE week: `ScheduledRideSheet.schedDates` maps these same
    /// seven tokens to "Jun 16" … "Jun 22", and 2026-06-16 was a **Tuesday**. So
    /// the row is chronological on a Tuesday and wrong on the other six days —
    /// on a Thursday it repeats Today's and Tomorrow's weekdays, and resolves
    /// non-monotonically (Jul 30 → Jul 31 → Aug 6 → Jul 31 → …). That was the
    /// client's report; see `RideScheduleDays`, which GENERATES the row from the
    /// device clock and is what the schedule card renders now.
    ///
    /// It survives for exactly one reason: these bare-weekday tokens can still
    /// arrive from a schedule an older build committed, so
    /// `RideRequestContractMapping.scheduledDate` must keep resolving them, and
    /// the suites sweep this list to prove it does. It is no longer read by any
    /// production surface.
    public static let scheduleDays = ["Today", "Tomorrow", "Thu", "Fri", "Sat", "Sun", "Mon"]

    // MYR-464 — `scheduleTimes` LIVED HERE AND IS NOW `RideScheduleTimes.grid`.
    //
    // It was never a fixture: the picker renders it on the LIVE path and
    // `RideRequestContractMapping.scheduledFor` encodes the chosen slot into the
    // create body. It sat in this file only because the prototype's row was
    // transcribed here alongside the day list — and, like the day list before it
    // (MYR-370), it stopped being a transcription the moment it became a rule.
    // No legacy copy is kept: every slot the half-hour grid minted is still in
    // the fifteen-minute one, so an older build's committed schedule selects,
    // renders and encodes unchanged.
}
