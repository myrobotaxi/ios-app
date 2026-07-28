import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-201 deliverable 5 — adapter mapping tests
//
// Contracts fixture → view model, incl. the open-enum `unrecognized` arms and
// the `offline` badge. Pure Swift-value transforms — no network.
final class VehicleContractMappingTests: XCTestCase {

    // MARK: Status → design badge

    func testBadgeStatusCoversEveryKnownWireStatus() {
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.driving), .driving)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.parked), .parked)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.charging), .charging)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.offline), .offline)
    }

    func testBadgeStatusInServiceSurfacesOwnBadge() {
        // MYR-259 — in-service now has its own badge (backend reliably reports
        // and clears the status), no longer collapsed to the parked fallback.
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleState.Status.inService), .inService)
    }

    func testBadgeStatusUnrecognizedFallsBackToNeutralOffline() {
        // Forward-compat wire value from a newer contracts build (MYR-195).
        XCTAssertEqual(
            VehicleContractMapping.badgeStatus(from: VehicleState.Status.unrecognized("teleporting")),
            .offline
        )
    }

    func testSummaryBadgeStatusMatchesStateMapping() {
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.offline), .offline)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.charging), .charging)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.inService), .inService)
        XCTAssertEqual(
            VehicleContractMapping.badgeStatus(from: VehicleSummary.Status.unrecognized("x")),
            .offline
        )
    }

    // MARK: VehicleState → snapshot

    func testDrivingSnapshotMapsSpeedBatteryEta() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState(chargeLevel: 68, speed: 64, etaMinutes: 42))
        XCTAssertEqual(snapshot.status, .driving)
        XCTAssertEqual(snapshot.speedMPH, 64)
        XCTAssertEqual(snapshot.batteryPercent, 68)
        XCTAssertEqual(snapshot.etaMinutes, 42)
        XCTAssertGreaterThan(snapshot.progress, 0)
        XCTAssertLessThanOrEqual(snapshot.progress, 1)
    }

    func testSnapshotCarriesRealOdometerAndFsdFromContract() {
        // MYR-255 — odometer + FSD miles are contracted (`VehicleState`), so the
        // live snapshot must carry the REAL wire values, never a fixture number.
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState())
        XCTAssertEqual(snapshot.odometerMiles, 42184)
        XCTAssertEqual(snapshot.fsdMilesSinceReset, 128.4)
    }

    // MARK: MYR-260 — freshness/streaming for honest unknown labeling

    func testSnapshotCarriesParsedLastUpdatedReadTime() {
        // The controls need the read time to qualify a stale value ("X ago") and
        // to tell "connecting" (no snapshot) from "reachable".
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState())
        XCTAssertEqual(
            snapshot.lastUpdated,
            VehicleContractMapping.parseTimestamp("2026-07-08T17:30:00Z"),
            "lastUpdated must be the parsed VehicleState.lastUpdated read time"
        )
    }

    func testOnlineStatusesReportStreaming() {
        // Driving / parked / charging stream ~1 Hz → an unknown field is transient.
        XCTAssertEqual(VehicleContractMapping.snapshot(from: Contracts.drivingState()).isStreaming, true)
        XCTAssertEqual(VehicleContractMapping.snapshot(from: Contracts.parkedState()).isStreaming, true)
        XCTAssertEqual(
            VehicleContractMapping.snapshot(from: Contracts.parkedState(status: .charging)).isStreaming,
            true
        )
    }

    func testOfflineAndInServiceReportNotStreaming() {
        // Offline / in_service don't stream — an unknown field the REST read
        // couldn't fill is "Unavailable", not a hopeful "Syncing".
        XCTAssertEqual(VehicleContractMapping.snapshot(from: Contracts.parkedState(status: .offline)).isStreaming, false)
        XCTAssertEqual(VehicleContractMapping.snapshot(from: Contracts.parkedState(status: .inService)).isStreaming, false)
        XCTAssertEqual(
            VehicleContractMapping.snapshot(from: Contracts.parkedState(status: .unrecognized("hibernating"))).isStreaming,
            false,
            "a forward-compat unknown status is treated conservatively as not streaming"
        )
    }

    func testParkedSnapshotZeroesMotionFields() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.parkedState(chargeLevel: 82))
        XCTAssertEqual(snapshot.status, .parked)
        XCTAssertEqual(snapshot.speedMPH, 0)
        XCTAssertEqual(snapshot.progress, 0)
        XCTAssertEqual(snapshot.etaMinutes, 0)
        XCTAssertEqual(snapshot.batteryPercent, 82)
    }

    func testChargingIsStationaryHero() {
        // Charging is not "driving" — the hero renders the stationary/parked
        // layout even though the badge says Charging.
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.parkedState(status: .charging))
        XCTAssertEqual(snapshot.status, .parked)
        XCTAssertEqual(snapshot.progress, 0)
    }

    func testOfflineStateMapsToParkedSnapshotButOfflineBadge() {
        let state = Contracts.parkedState(status: .offline)
        XCTAssertEqual(VehicleContractMapping.snapshot(from: state).status, .parked)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: state.status), .offline)
    }

    func testInServiceStateMapsToParkedSnapshotButInServiceBadge() {
        // MYR-259 — the half-state contract: the badge distinguishes
        // "In Service" while the hero/motion stays the stationary (parked)
        // layout. If `isDriving` ever treats in_service as driving, this fails
        // even though the isolated badge-mapping tests still pass.
        let state = Contracts.parkedState(status: .inService)
        XCTAssertEqual(VehicleContractMapping.snapshot(from: state).status, .parked)
        XCTAssertEqual(VehicleContractMapping.badgeStatus(from: state.status), .inService)
    }

    func testSnapshotClampsOutOfRangeChargeAndSpeed() {
        var state = Contracts.drivingState()
        state.chargeLevel = 130
        state.speed = -5
        let high = VehicleContractMapping.snapshot(from: state)
        XCTAssertEqual(high.batteryPercent, 100)
        XCTAssertEqual(high.speedMPH, 0)

        state.chargeLevel = -20
        XCTAssertEqual(VehicleContractMapping.snapshot(from: state).batteryPercent, 0)
    }

    func testMissingEtaDefaultsToZero() {
        let snapshot = VehicleContractMapping.snapshot(from: Contracts.drivingState(etaMinutes: nil))
        XCTAssertEqual(snapshot.etaMinutes, 0)
    }

    // MARK: tripProgress

    func testTripProgressFromDistanceRemaining() {
        // ~48mi total route; ~6mi remaining → well past halfway.
        let nearEnd = VehicleContractMapping.tripProgress(from: Contracts.drivingState(tripDistanceRemaining: 3))
        let midway = VehicleContractMapping.tripProgress(from: Contracts.drivingState(tripDistanceRemaining: 30))
        XCTAssertGreaterThan(nearEnd, midway)
        XCTAssertTrue((0...1).contains(nearEnd))
        XCTAssertTrue((0...1).contains(midway))
    }

    func testTripProgressZeroWhenNoDistance() {
        XCTAssertEqual(VehicleContractMapping.tripProgress(from: Contracts.drivingState(tripDistanceRemaining: nil)), 0)
    }

    // MARK: VehicleState → activity

    func testDrivingActivityBuildsTripFromNavGroup() {
        guard case .driving(let trip) = VehicleContractMapping.activity(from: Contracts.drivingState()) else {
            return XCTFail("expected driving activity")
        }
        XCTAssertEqual(trip.destinationName, "Duarte's Tavern")
        XCTAssertEqual(trip.destinationCity, "Pescadero")   // city component of the address
        XCTAssertEqual(trip.originLabel, "Home")
        XCTAssertEqual(trip.route.count, 2)
        // GeoJSON [lon, lat] decoded to (lat, lon).
        XCTAssertEqual(trip.route.first?.latitude ?? 0, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(trip.route.first?.longitude ?? 0, -122.4194, accuracy: 0.0001)
    }

    func testParkedActivityBuildsLocationAtCurrentPosition() {
        guard case .parked(let loc) = VehicleContractMapping.activity(from: Contracts.parkedState()) else {
            return XCTFail("expected parked activity")
        }
        XCTAssertEqual(loc.label, "Embarcadero Center · Lot B")
        XCTAssertEqual(loc.coordinate.latitude, 37.7955, accuracy: 0.0001)
        XCTAssertEqual(loc.coordinate.longitude, -122.3937, accuracy: 0.0001)
    }

    func testDrivingActivityFallsBackToOriginDestinationWhenNoRoute() {
        var state = Contracts.drivingState()
        state.navRouteCoordinates = nil // Tesla hasn't decoded a RouteLine yet
        guard case .driving(let trip) = VehicleContractMapping.activity(from: state) else {
            return XCTFail("expected driving activity")
        }
        // current position + destination coordinate → a 2-point straight route.
        XCTAssertEqual(trip.route.count, 2)
    }

    func testParkedActivityLabelFallsBackWhenGeocodeMissing() {
        var state = Contracts.parkedState()
        state.locationName = ""
        state.locationAddress = ""
        guard case .parked(let loc) = VehicleContractMapping.activity(from: state) else {
            return XCTFail("expected parked activity")
        }
        XCTAssertEqual(loc.label, "Location unavailable")
    }

    // MARK: Summary + state → Vehicle row

    func testVehicleRowFromSummaryComposesModelPlateColor() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary())
        XCTAssertEqual(vehicle.id, "v2")
        XCTAssertEqual(vehicle.name, "Daily")
        XCTAssertEqual(vehicle.model, "2024 Model 3 LR")
        XCTAssertEqual(vehicle.colorName, "Pearl White")
        XCTAssertEqual(vehicle.plate, "VIN ····9417")
    }

    func testVehicleRowPlateEmptyWhenVinUnknown() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(vinLast4: ""))
        XCTAssertEqual(vehicle.plate, "")
    }

    func testVehicleRowSeatVentReflectsLiveState() {
        // MYR-252 — the seat Heat/Cool affordance follows the car's real read-back;
        // absent (no snapshot) stays heating-only. MYR-299 keeps `seatVentEnabled`
        // as an OR-signal, so this case is unchanged.
        var venting = Contracts.parkedState()
        venting.seatVentEnabled = true
        XCTAssertTrue(VehicleContractMapping.vehicle(summary: Contracts.summary(), state: venting).seatVent)
        XCTAssertFalse(VehicleContractMapping.vehicle(summary: Contracts.summary()).seatVent)
    }

    // MARK: MYR-299 — seat-cool capability from cooler-field presence

    /// `Vehicle.seatVent` is the ventilated-seat CAPABILITY, derived from the
    /// PRESENCE of `seatCoolerLeft`/`seatCoolerRight` on the snapshot. This is the
    /// mapping-layer half of the client's fix: a car that emits seat-cooler
    /// telemetry HAS cooled seats even when both read `0`.
    func testVehicleRowSeatVentIsDerivedFromCoolerFieldPresence() {
        func seatVent(left: Int?, right: Int?, vent: Bool?) -> Bool {
            var state = Contracts.parkedState()
            state.seatCoolerLeft = left
            state.seatCoolerRight = right
            state.seatVentEnabled = vent
            return VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state).seatVent
        }

        XCTAssertTrue(seatVent(left: 0, right: 0, vent: nil),
            "both coolers present-but-off — the client's car; must be treated as vented")
        XCTAssertTrue(seatVent(left: 0, right: 0, vent: false),
            "presence beats the runtime vent flag — exactly the shipped bug")
        XCTAssertTrue(seatVent(left: 2, right: nil, vent: nil),
            "one cooler reporting is enough")
        XCTAssertTrue(seatVent(left: nil, right: 0, vent: nil),
            "presence on the passenger side alone is enough")
        XCTAssertFalse(seatVent(left: nil, right: nil, vent: nil),
            "a heat-only car never emits protos 237/238 → honest heating-only UI")
        XCTAssertFalse(seatVent(left: nil, right: nil, vent: false),
            "vent=false with no cooler fields is not evidence of vented seats")
        XCTAssertTrue(seatVent(left: nil, right: nil, vent: true),
            "an explicit vent=true still qualifies (belt-and-braces OR-signal)")
    }

    /// Tolerant absence: before the first snapshot there is no state at all, so the
    /// row must read heat-only rather than guessing a capability.
    func testVehicleRowSeatVentIsFalseBeforeFirstSnapshot() {
        XCTAssertFalse(VehicleContractMapping.vehicle(summary: Contracts.summary()).seatVent)
    }

    // MARK: MYR-308 — the REST seat SPEC threads through the mapping

    /// The mapping-layer half of MYR-308: `Vehicle.seatVent` now prefers the
    /// contracts-0.16.0 `seatCoolingCapable`, and only falls back to the MYR-299
    /// presence heuristic when the field is absent. Asserted through the SHIPPING
    /// mapping, because that is what every surface reads.
    func testVehicleRowSeatVentPrefersTheSpecFieldOverThePresenceHeuristic() {
        func seatVent(capable: Bool?, left: Int?, right: Int?, vent: Bool? = nil) -> Bool {
            var state = Contracts.parkedState()
            state.seatCoolingCapable = capable
            state.seatCoolerLeft = left
            state.seatCoolerRight = right
            state.seatVentEnabled = vent
            return VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state).seatVent
        }

        XCTAssertFalse(
            seatVent(capable: false, left: 0, right: 0),
            "an explicit spec false hides the Heat/Cool affordance even though the presence heuristic would fire"
        )
        XCTAssertFalse(
            seatVent(capable: false, left: 3, right: 3, vent: true),
            "the spec outranks every telemetry signal — the car has no cooled seats"
        )
        XCTAssertTrue(
            seatVent(capable: true, left: nil, right: nil),
            "the spec says capable before any cooler telemetry has arrived"
        )
        XCTAssertTrue(
            seatVent(capable: nil, left: 0, right: 0, vent: false),
            "absent spec (pre-0.16.0 server) → the MYR-299 heuristic still carries the client's car"
        )
        XCTAssertFalse(
            seatVent(capable: nil, left: nil, right: nil),
            "absent spec and no telemetry → honest heat-only"
        )
    }

    // MARK: MYR-279 — vehicle-details fields from the live snapshot

    func testVehicleRowComposesFullModelFromLiveStateTrimLabel() {
        // The wrong-source display bug: the summary carries a partial model, the
        // snapshot the authoritative "{year} {model} {trimLabel}". A live state
        // wins. MYR-320 — the suffix is the DISPLAY-READY label, and the raw badge
        // riding alongside it must not appear.
        var state = Contracts.parkedState()
        state.model = "Model Y"
        state.year = 2026
        state.trimLabel = "Performance"
        state.trim = "p74d"
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(model: "Model", year: 0), state: state)
        XCTAssertEqual(vehicle.model, "2026 Model Y Performance")
    }

    func testVehicleRowModelFallsBackToSummaryBeforeSnapshot() {
        // No snapshot yet → the summary's model/year still label the row.
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(model: "Model 3 LR", year: 2024))
        XCTAssertEqual(vehicle.model, "2024 Model 3 LR")
    }

    func testVehicleRowPopulatesVinAndSoftwareFromLiveState() {
        var state = Contracts.parkedState()
        state.vin = "7SAYGDEE9RA123456"
        state.softwareVersion = "2026.14.3"
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state)
        XCTAssertEqual(vehicle.vin, "7SAYGDEE9RA123456")
        XCTAssertEqual(vehicle.softwareVersion, "2026.14.3")
    }

    func testVehicleRowVinAndSoftwareHonestUnknownBeforeSnapshot() {
        // No snapshot → nil, so the KV rows render the honest em-dash, not a
        // fabricated / fixture VIN or version on the live path.
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary())
        XCTAssertNil(vehicle.vin)
        XCTAssertNil(vehicle.softwareVersion)
    }

    func testVehicleRowBlankVinAndSoftwareMapToHonestUnknown() {
        // A present-but-blank wire value is treated as absent (honest-unknown),
        // never rendered as an empty row.
        var state = Contracts.parkedState()
        state.vin = "   "
        state.softwareVersion = ""
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state)
        XCTAssertNil(vehicle.vin)
        XCTAssertNil(vehicle.softwareVersion)
    }

    func testVehicleRowColorHonestEmptyWhenBlankEverywhere() {
        // Color isn't written by onboarding yet (MYR-283): blank on both summary
        // and snapshot → an empty colorName that renders the honest em-dash, never
        // a fabricated color.
        var state = Contracts.parkedState()
        state.color = ""
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(color: ""), state: state)
        XCTAssertTrue(vehicle.colorName.isEmpty)
    }

    func testVehicleRowPrefersSnapshotColorWhenPresent() {
        var state = Contracts.parkedState()
        state.color = "Quicksilver"
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(color: ""), state: state)
        XCTAssertEqual(vehicle.colorName, "Quicksilver")
    }

    func testVehicleRowLiveTirePressuresAbsentForHonestState() {
        // TPMS is uncontracted → a live-mapped row never carries fixture pressures,
        // so the Tire section renders the honest "Available after your next drive".
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(), state: Contracts.parkedState())
        XCTAssertNil(vehicle.tirePressures)
    }

    func testVehicleRowUsesPlaceholderActivityBeforeSnapshot() {
        // No live state yet → a parked "Locating…" placeholder for a parked row.
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(status: .parked))
        guard case .parked(let loc) = vehicle.activity else { return XCTFail("expected parked placeholder") }
        XCTAssertEqual(loc.label, "Locating…")
    }

    func testUnrecognizedSummaryStatusGetsParkedPlaceholderActivity() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(status: .unrecognized("cruising")))
        if case .driving = vehicle.activity { XCTFail("unrecognized should not render the driving hero") }
    }

    func testVehicleRowFoldsLiveStateActivityOverPlaceholder() {
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(status: .parked), state: Contracts.drivingState())
        guard case .driving(let trip) = vehicle.activity else {
            return XCTFail("live driving state should upgrade the row to a driving activity")
        }
        XCTAssertEqual(trip.destinationName, "Duarte's Tavern")
    }

    func testBadgeStatusForSummaryPrefersLiveState() {
        // Summary says parked, live snapshot says charging → badge tracks live.
        let badge = VehicleContractMapping.badgeStatus(
            forSummary: Contracts.summary(status: .parked),
            state: Contracts.parkedState(status: .charging)
        )
        XCTAssertEqual(badge, .charging)
    }

    // MARK: Helpers

    func testModelLabelOmitsYearWhenZero() {
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 0, model: "Cybercab"), "Cybercab")
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 2026, model: "Cybercab"), "2026 Cybercab")
    }

    // MARK: MYR-279/320 — model label composes year + model + TRIM LABEL

    /// The client's target: "2026 Model Y Performance", composed from the
    /// DISPLAY-READY `trimLabel`.
    func testModelLabelComposesYearModelTrimLabel() {
        XCTAssertEqual(
            VehicleContractMapping.modelLabel(year: 2026, model: "Model Y", trimLabel: "Performance"),
            "2026 Model Y Performance"
        )
    }

    func testModelLabelDropsTrimLabelGracefullyWhenAbsent() {
        // nil / blank label → "{year} {model}" (e.g. "2026 Model Y"), never a
        // trailing space or an empty component. Absence is COMMON AND NORMAL — a
        // server predating MYR-320, an incomplete vehicle-config read, or a car
        // with no performance designation at all.
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 2026, model: "Model Y", trimLabel: nil), "2026 Model Y")
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 2026, model: "Model Y", trimLabel: ""), "2026 Model Y")
        XCTAssertEqual(VehicleContractMapping.modelLabel(year: 2026, model: "Model Y", trimLabel: "   "), "2026 Model Y")
    }

    func testModelLabelDropsYearAndModelGracefully() {
        // A zero year drops just the year; a blank model drops just the model.
        XCTAssertEqual(
            VehicleContractMapping.modelLabel(year: 0, model: "Model Y", trimLabel: "Performance"),
            "Model Y Performance"
        )
        XCTAssertEqual(
            VehicleContractMapping.modelLabel(year: 2026, model: "", trimLabel: "Performance"),
            "2026 Performance"
        )
    }

    /// The value is rendered VERBATIM — no re-casing, no reformatting. It arrives
    /// display-ready from Tesla and the contract forbids rewriting it.
    func testModelLabelRendersTheTrimLabelVerbatim() {
        XCTAssertEqual(
            VehicleContractMapping.modelLabel(year: 2026, model: "Model S", trimLabel: "Plaid"),
            "2026 Model S Plaid"
        )
        XCTAssertEqual(
            VehicleContractMapping.modelLabel(year: 2026, model: "Model 3", trimLabel: "Long Range AWD"),
            "2026 Model 3 Long Range AWD"
        )
    }

    // MARK: MYR-320 — the raw `trim` badge is never displayed

    /// THE composition matrix, over the two wire fields that both describe trim.
    /// The row that matters most is the third: a car whose config carries a badge
    /// code but no display label falls back to "{year} {model}" — it must NOT
    /// substitute the code, which on the client's own car is the string "p74d".
    func testModelCompositionMatrixOverTrimLabelAndTrimBadge() {
        struct Case {
            let trimLabel: String?
            let trim: String?
            let expected: String
            let line: UInt
            init(trimLabel: String?, trim: String?, _ expected: String, line: UInt = #line) {
                self.trimLabel = trimLabel; self.trim = trim
                self.expected = expected; self.line = line
            }
        }
        let cases: [Case] = [
            // Both present — the client's real car. The label wins; the badge is
            // invisible.
            Case(trimLabel: "Performance", trim: "p74d", "2026 Model Y Performance"),
            // Label present, no badge — unchanged.
            Case(trimLabel: "Performance", trim: nil, "2026 Model Y Performance"),
            // NO label, badge present — the regression this guards. Fall back to
            // "{year} {model}"; never "2026 Model Y p74d".
            Case(trimLabel: nil, trim: "p74d", "2026 Model Y"),
            // Blank label with a badge behind it — same rule; blank == absent.
            Case(trimLabel: "", trim: "p74d", "2026 Model Y"),
            // Neither — the pre-MYR-279 shape.
            Case(trimLabel: nil, trim: nil, "2026 Model Y"),
        ]
        for c in cases {
            var state = Contracts.parkedState()
            state.year = 2026
            state.model = "Model Y"
            state.trimLabel = c.trimLabel
            state.trim = c.trim
            let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state)
            XCTAssertEqual(vehicle.model, c.expected, line: c.line)
            if let trim = c.trim {
                XCTAssertFalse(
                    vehicle.model.contains(trim),
                    "the raw trim badge \"\(trim)\" must never reach a display surface",
                    line: c.line
                )
            }
        }
    }

    /// The lean list row carries no trim of either kind (both are detail-sheet
    /// fields by contract), so the pre-snapshot fallback is "{year} {model}".
    func testModelFallsBackToTheSummaryBeforeTheFirstSnapshot() {
        let vehicle = VehicleContractMapping.vehicle(
            summary: Contracts.summary(model: "Model Y", year: 2026), state: nil
        )
        XCTAssertEqual(vehicle.model, "2026 Model Y")
    }

    // MARK: MYR-320 — color renders verbatim once the wire carries it

    /// Telemetry PR #340 populates the EXISTING `VehicleState.color`, so no
    /// mapping change was needed — this pins that the value survives untouched
    /// (no lowercasing, no title-casing) and that the honest-empty behaviour the
    /// row shipped with is intact for a server that still sends "".
    func testColorFlowsThroughVerbatimAndStaysHonestlyEmptyWhenBlank() {
        var state = Contracts.parkedState()
        state.color = "Quicksilver"
        XCTAssertEqual(
            VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state).colorName,
            "Quicksilver"
        )

        // The snapshot leads; the summary is the fallback before it arrives.
        state.color = ""
        var summary = Contracts.summary()
        summary.color = "Deep Blue Metallic"
        XCTAssertEqual(
            VehicleContractMapping.vehicle(summary: summary, state: state).colorName,
            "Deep Blue Metallic"
        )

        summary.color = ""
        XCTAssertEqual(
            VehicleContractMapping.vehicle(summary: summary, state: state).colorName, "",
            "both blank stays blank \u{2014} the row renders its honest empty state, never a fabricated color"
        )
    }

    // MARK: MYR-320 — the FSD designation

    /// Mapped verbatim off the snapshot and NEVER derived from `softwareVersion`:
    /// the firmware build and the FSD designation are independent strings, which
    /// is exactly why they are two rows.
    func testFsdVersionMapsVerbatimAndIsIndependentOfSoftwareVersion() {
        var state = Contracts.parkedState()
        state.softwareVersion = "2026.20.1 9a8b7c6"
        state.fsdVersion = "FSD (Supervised) v14.3.5"
        let vehicle = VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state)
        XCTAssertEqual(vehicle.fsdVersion, "FSD (Supervised) v14.3.5")
        XCTAssertEqual(vehicle.softwareVersion, "2026.20.1 9a8b7c6")
    }

    /// Absence is nil, not a placeholder — the row is omitted entirely. A blank
    /// string normalizes to nil for the same reason: a server that emits "" must
    /// produce no row rather than an empty value.
    func testFsdVersionIsNilWhenAbsentOrBlankSoTheRowIsOmitted() {
        var state = Contracts.parkedState()
        XCTAssertNil(state.fsdVersion, "the wire field is optional and absent by default")
        XCTAssertNil(VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state).fsdVersion)

        state.fsdVersion = "   "
        XCTAssertNil(VehicleContractMapping.vehicle(summary: Contracts.summary(), state: state).fsdVersion)

        XCTAssertNil(
            VehicleContractMapping.vehicle(summary: Contracts.summary(), state: nil).fsdVersion,
            "snapshot-only \u{2014} the list row never carries it"
        )
    }

    /// The FIXTURE fleet carries no FSD designation, which is what keeps the
    /// simulated sheet and every drift-gate scene pixel-identical: this row is not
    /// in the prototype's details list and appears only on a real snapshot.
    func testSimulatedFleetCarriesNoFsdVersion() {
        for vehicle in VehicleFixtures.vehicles {
            XCTAssertNil(vehicle.fsdVersion, "\(vehicle.name) must not carry a fixture FSD designation")
        }
    }

    func testRouteCoordinatesDropMalformedPairs() {
        let coords = VehicleContractMapping.routeCoordinates(from: [[-122.4, 37.7], [1.0], [-121.9, 37.3]])
        XCTAssertEqual(coords.count, 2)
    }

    func testCityComponentPicksSecondToLast() {
        XCTAssertEqual(VehicleContractMapping.cityComponent(from: "202 Stage Rd, Pescadero, CA"), "Pescadero")
        XCTAssertEqual(VehicleContractMapping.cityComponent(from: "Somewhere"), "Somewhere")
        XCTAssertNil(VehicleContractMapping.cityComponent(from: ""))
    }

    // MARK: LiveVehicleTelemetrySource placeholder

    func testLiveSourcePlaceholderIsCalmParkedZero() {
        let placeholder = LiveVehicleTelemetrySource.placeholder
        XCTAssertEqual(placeholder.status, .parked)
        XCTAssertEqual(placeholder.speedMPH, 0)
        XCTAssertEqual(placeholder.progress, 0)
        XCTAssertEqual(placeholder.batteryPercent, 0)
    }
}
