import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// Verifies the field-delta fold onto `VehicleState`, including the atomic
/// nav-clear amplification (NFR-3.9 / Rule CG-SM-3).
final class VehicleStateMergerTests: XCTestCase {
    private func baseState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    func testChargeDeltaMergesAndIsolatesGroup() throws {
        var state = try baseState()
        state.latitude = 37.0
        state.longitude = -122.0

        let fields: [String: JSONValue] = [
            "chargeLevel": .number(55),
            "chargeState": .string("Charging"),
            "estimatedRange": .number(180),
        ]
        let result = VehicleStateMerger.apply(fields: fields, to: state)

        XCTAssertEqual(result.state.chargeLevel, 55)
        XCTAssertEqual(result.state.chargeState, .charging)
        XCTAssertEqual(result.state.estimatedRange, 180)
        XCTAssertEqual(result.changedGroups, [.charge])
        XCTAssertFalse(result.navigationCleared)
        // Other groups untouched.
        XCTAssertEqual(result.state.latitude, 37.0)
        XCTAssertEqual(result.state.longitude, -122.0)
    }

    func testControlFieldsFoldOnLiveDelta() throws {
        // MYR-272 — a LIVE vehicle_update toggling climate/lock/trunk/settings must
        // fold into state (previously dropped by `default`, so the owner enabled
        // climate in the car and the app kept showing "Off").
        var state = try baseState()
        state.isClimateOn = false
        state.locked = true
        let result = VehicleStateMerger.apply(fields: [
            "isClimateOn": .bool(true),
            "hvacPower": .string("On"),
            "locked": .bool(false),
            "frunkOpen": .bool(true),
            "trunkOpen": .bool(false),
            "chargePortDoorOpen": .bool(true),
            "fanSpeed": .number(4),
            "driverTempSetting": .number(70),
            "seatHeaterLeft": .number(3),
            "seatCoolerRight": .number(0),
            "mediaVolume": .number(5.5),
        ], to: state)
        XCTAssertEqual(result.state.isClimateOn, true, "climate on/off must fold live")
        XCTAssertEqual(result.state.hvacPower, .on)
        XCTAssertEqual(result.state.locked, false)
        XCTAssertEqual(result.state.frunkOpen, true)
        XCTAssertEqual(result.state.trunkOpen, false)
        XCTAssertEqual(result.state.chargePortDoorOpen, true)
        XCTAssertEqual(result.state.fanSpeed, 4)
        XCTAssertEqual(result.state.driverTempSetting, 70)
        XCTAssertEqual(result.state.seatHeaterLeft, 3)
        XCTAssertEqual(result.state.seatCoolerRight, 0)
        XCTAssertEqual(result.state.mediaVolume, 5.5)
    }

    func testControlFieldNullClears() throws {
        var state = try baseState()
        state.isClimateOn = true
        let result = VehicleStateMerger.apply(fields: ["isClimateOn": .null], to: state)
        XCTAssertNil(result.state.isClimateOn, "explicit null clears the control")
    }

    func testGpsDeltaRoundsHeading() throws {
        let state = try baseState()
        let result = VehicleStateMerger.apply(
            fields: ["latitude": .number(40.1), "longitude": .number(-74.2), "heading": .number(276)],
            to: state
        )
        XCTAssertEqual(result.state.latitude, 40.1)
        XCTAssertEqual(result.state.heading, 276)
        XCTAssertEqual(result.changedGroups, [.gps])
    }

    /// A PARTIAL nav clear (server sends only `destinationName: null`) must null
    /// the ENTIRE navigation group.
    func testPartialNavClearAmplifiesToWholeGroup() throws {
        var state = try baseState()
        state.destinationName = "Airport"
        state.destinationLatitude = 37.6
        state.destinationLongitude = -122.4
        state.etaMinutes = 22
        state.navRouteCoordinates = [[-122.4, 37.6], [-122.3, 37.7]]

        let result = VehicleStateMerger.apply(fields: ["destinationName": .null], to: state)

        XCTAssertTrue(result.navigationCleared)
        XCTAssertEqual(result.changedGroups, [.navigation])
        XCTAssertNil(result.state.destinationName)
        XCTAssertNil(result.state.destinationLatitude)
        XCTAssertNil(result.state.destinationLongitude)
        XCTAssertNil(result.state.etaMinutes)
        XCTAssertNil(result.state.navRouteCoordinates)
    }

    func testFullNavClearFixtureAmplifies() throws {
        var state = try baseState()
        state.destinationName = "Home"
        state.etaMinutes = 5

        let envelope = try WireCodec.decodeEnvelope(try Fixture.text("websocket/vehicle_update.nav_clear.json"))
        let payload = try WireCodec.decodePayload(VehicleUpdatePayload.self, from: envelope)
        let result = VehicleStateMerger.apply(fields: payload.fields, to: state)

        XCTAssertTrue(result.navigationCleared)
        XCTAssertNil(result.state.destinationName)
        XCTAssertNil(result.state.etaMinutes)
    }

    func testUnknownFieldIsIgnored() throws {
        let state = try baseState()
        let result = VehicleStateMerger.apply(
            fields: ["someFutureField": .number(9), "speed": .number(34)],
            to: state
        )
        XCTAssertEqual(result.state.speed, 34)          // known ungrouped field applied
        XCTAssertTrue(result.changedGroups.isEmpty)     // no atomic group touched
    }

    func testClassifyFlagsNavClear() {
        let (groups, navCleared) = VehicleStateMerger.classify(
            fields: ["etaMinutes": .null, "chargeLevel": .number(80)]
        )
        XCTAssertTrue(groups.contains(.navigation))
        XCTAssertTrue(groups.contains(.charge))
        XCTAssertTrue(navCleared)
    }

    // MARK: - Contract coverage (MYR-298)
    //
    // The targeted tests above hand-pick the fields they check, which is exactly
    // how MYR-272 shipped a fold covering 17 of the 21 contracted cabin fields
    // while 476 tests stayed green: `hvacAutoMode`, `hvacAcEnabled`,
    // `seatVentEnabled` and `mediaPlaybackStatus` silently hit the merger's
    // `default:` arm and no assertion existed to notice.
    //
    // The three tests below close that hole by deriving coverage from ONE
    // canonical table (`foldCases` + `snapshotOnlyFields`) that is itself checked
    // against the GENERATED `VehicleState` via `Mirror`. A field added to the
    // contracts package therefore fails `testCanonicalTableCoversEveryContractedField`
    // until someone either folds it (adding a row) or explicitly declares it
    // snapshot-only — the fold can no longer drift behind the wire in silence.

    /// One contracted `VehicleState` wire field, the delta value used to probe it,
    /// and the assertions that the fold landed / that an explicit null clears it.
    private struct FoldCase {
        let field: String
        let delta: JSONValue
        /// The field carries a value after the fold (the MYR-298 `default:`-drop check).
        let isPresent: (VehicleState) -> Bool
        /// The field carries the EXACT value the delta named (type/parse check).
        let isFolded: (VehicleState) -> Bool
        /// `nil` for wire fields whose contract type is non-optional — those have
        /// no null-clear arm by construction.
        let isCleared: ((VehicleState) -> Bool)?
    }

    /// Row builder for an OPTIONAL contract property (has a null-clear arm).
    private static func opt<T: Equatable>(
        _ field: String, _ delta: JSONValue, _ keyPath: KeyPath<VehicleState, T?>, _ expected: T
    ) -> FoldCase {
        FoldCase(
            field: field,
            delta: delta,
            isPresent: { $0[keyPath: keyPath] != nil },
            isFolded: { $0[keyPath: keyPath] == expected },
            isCleared: { $0[keyPath: keyPath] == nil }
        )
    }

    /// Row builder for a NON-OPTIONAL contract property (no null-clear semantics).
    private static func req<T: Equatable>(
        _ field: String, _ delta: JSONValue, _ keyPath: KeyPath<VehicleState, T>, _ expected: T
    ) -> FoldCase {
        FoldCase(
            field: field,
            delta: delta,
            isPresent: { _ in true },
            isFolded: { $0[keyPath: keyPath] == expected },
            isCleared: nil
        )
    }

    /// THE canonical table — every `VehicleState` field the live `vehicle_update`
    /// fold must deliver. Every probe value is deliberately different from the
    /// `rest/snapshot.json` fixture so "it folded" can't be confused with "the
    /// fixture already said that".
    /// (Computed, not stored: the rows hold closures, so a `static let` would trip
    /// Swift 6's non-`Sendable` shared-mutable-state check.)
    private static var foldCases: [FoldCase] { [
        // GPS group
        req("latitude", .number(40.1), \.latitude, 40.1),
        req("longitude", .number(-74.2), \.longitude, -74.2),
        req("heading", .number(276), \.heading, 276),

        // Gear group
        req("status", .string("driving"), \.status, .driving),
        opt("gearPosition", .string("D"), \.gearPosition, .d),

        // Charge group
        req("chargeLevel", .number(55), \.chargeLevel, 55),
        req("estimatedRange", .number(180), \.estimatedRange, 180),
        opt("chargeState", .string("Charging"), \.chargeState, .charging),
        opt("timeToFull", .number(1.75), \.timeToFull, 1.75),

        // Navigation group (non-null here: a null would amplify to a group clear)
        opt("destinationName", .string("Pier 39"), \.destinationName, "Pier 39"),
        opt("destinationAddress", .string("Beach St, San Francisco, CA"), \.destinationAddress, "Beach St, San Francisco, CA"),
        opt("destinationLatitude", .number(37.8087), \.destinationLatitude, 37.8087),
        opt("destinationLongitude", .number(-122.4098), \.destinationLongitude, -122.4098),
        opt("originLatitude", .number(37.7749), \.originLatitude, 37.7749),
        opt("originLongitude", .number(-122.4194), \.originLongitude, -122.4194),
        opt("etaMinutes", .number(14), \.etaMinutes, 14),
        opt("tripDistanceRemaining", .number(3.4), \.tripDistanceRemaining, 3.4),
        opt(
            "navRouteCoordinates",
            .array([.array([.number(-122.4194), .number(37.7749)]), .array([.number(-122.4098), .number(37.8087)])]),
            \.navRouteCoordinates,
            [[-122.4194, 37.7749], [-122.4098, 37.8087]]
        ),

        // Ungrouped telemetry
        req("speed", .number(34), \.speed, 34),
        req("odometerMiles", .number(12500), \.odometerMiles, 12500),
        req("interiorTemp", .number(71), \.interiorTemp, 71),
        req("exteriorTemp", .number(61), \.exteriorTemp, 61),
        req("fsdMilesSinceReset", .number(500.5), \.fsdMilesSinceReset, 500.5),
        req("locationName", .string("Embarcadero"), \.locationName, "Embarcadero"),
        req("locationAddress", .string("1 Ferry Bldg, San Francisco, CA"), \.locationAddress, "1 Ferry Bldg, San Francisco, CA"),
        req("lastUpdated", .string("2026-07-26T12:00:00Z"), \.lastUpdated, "2026-07-26T12:00:00Z"),

        // Owner control / cabin fields (MYR-272 folded 17 of these; MYR-298 added
        // hvacAutoMode / hvacAcEnabled / seatVentEnabled / mediaPlaybackStatus)
        opt("locked", .bool(false), \.locked, false),
        opt("isClimateOn", .bool(true), \.isClimateOn, true),
        opt("hvacPower", .string("On"), \.hvacPower, .on),
        opt("hvacAutoMode", .string("Override"), \.hvacAutoMode, .override),
        opt("hvacAcEnabled", .bool(true), \.hvacAcEnabled, true),
        opt("fanSpeed", .number(4), \.fanSpeed, 4),
        opt("driverTempSetting", .number(70), \.driverTempSetting, 70),
        opt("passengerTempSetting", .number(72), \.passengerTempSetting, 72),
        opt("seatHeaterLeft", .number(3), \.seatHeaterLeft, 3),
        opt("seatHeaterRight", .number(2), \.seatHeaterRight, 2),
        opt("seatHeaterRearLeft", .number(1), \.seatHeaterRearLeft, 1),
        opt("seatHeaterRearCenter", .number(0), \.seatHeaterRearCenter, 0),
        opt("seatHeaterRearRight", .number(3), \.seatHeaterRearRight, 3),
        opt("seatCoolerLeft", .number(2), \.seatCoolerLeft, 2),
        opt("seatCoolerRight", .number(1), \.seatCoolerRight, 1),
        opt("seatVentEnabled", .bool(true), \.seatVentEnabled, true),
        opt("chargePortDoorOpen", .bool(true), \.chargePortDoorOpen, true),
        opt("frunkOpen", .bool(true), \.frunkOpen, true),
        opt("trunkOpen", .bool(false), \.trunkOpen, false),
        opt("mediaPlaybackStatus", .string("Playing"), \.mediaPlaybackStatus, .playing),
        opt("mediaVolume", .number(5.5), \.mediaVolume, 5.5),

        // Media now-playing (MYR-303, contracts 0.16.0). All eight stream live on
        // the Tesla fleet-telemetry **Media** group, so all eight are FOLD rows —
        // the schema says each is a "Live WS vehicle_update field", which is the
        // whole basis for the fold/snapshot-only split this table encodes.
        opt("mediaNowPlayingTitle", .string("Midnight City"), \.mediaNowPlayingTitle, "Midnight City"),
        opt("mediaNowPlayingArtist", .string("M83"), \.mediaNowPlayingArtist, "M83"),
        opt("mediaNowPlayingAlbum", .string("Hurry Up, We\u{2019}re Dreaming"), \.mediaNowPlayingAlbum, "Hurry Up, We\u{2019}re Dreaming"),
        opt("mediaNowPlayingStation", .string("KEXP 90.3"), \.mediaNowPlayingStation, "KEXP 90.3"),
        opt("mediaPlaybackSource", .string("Spotify"), \.mediaPlaybackSource, "Spotify"),
        opt("mediaNowPlayingDurationMs", .number(243_000), \.mediaNowPlayingDurationMs, 243_000),
        opt("mediaNowPlayingElapsedMs", .number(92_000), \.mediaNowPlayingElapsedMs, 92_000),
        opt("mediaVolumeMax", .number(11), \.mediaVolumeMax, 11),
    ] }

    /// Identity / catalog fields delivered ONLY on the cold `/snapshot` — they
    /// describe the car, not its live state, and are intentionally not folded from
    /// a `vehicle_update` delta.
    ///
    /// MYR-286 — `licensePlate` joins this set rather than `foldCases`, and the
    /// classification is a CONTRACT statement, not a convenience: rest-api.md §7.14
    /// is explicit that v1 carries NO WebSocket delta for the field — "a
    /// `vehicle_update` frame NEVER contains `licensePlate`, and a plate edit fires
    /// no push". It is an owner-typed identity-row value alongside `name`/`color`
    /// (not telemetry, and not from Tesla — the Fleet API has no plate anywhere),
    /// so it reaches clients on the next §7.0 / §7.1 read or by adopting the §7.14
    /// PUT's own normalized echo. Folding it here would invent a delivery path the
    /// server does not have. If the server ever DOES start pushing it, move this
    /// entry to a `foldCases` row and add the merger `case` — this tripwire is
    /// exactly where that decision belongs.
    ///
    /// MYR-308 — `seatCoolingCapable` (contracts 0.16.0) joins the set on the same
    /// contract grounds. It is a SPEC/CAPABILITY fact ("is this car EQUIPPED with
    /// ventilated seats"), read by the server from Tesla's REST
    /// `vehicle_data.vehicle_config.has_seat_cooling`. Tesla does NOT stream it —
    /// there is no proto field for it at all — and the schema is explicit that "a
    /// `vehicle_update` frame NEVER contains seatCoolingCapable"; it arrives on
    /// REST reads only, exactly like the sibling `trim` that is plucked from the
    /// same `vehicle_config` blob and already sits in this set. Note the contrast
    /// with its RUNTIME sibling `seatVentEnabled` (proto 254), which IS streamed
    /// and therefore IS a `foldCases` row: capability vs. current state is exactly
    /// the distinction MYR-299/308 turn on.
    /// MYR-316 — `serviceEstimatedEndAt` (contracts 0.17.0) joins the set on the
    /// same contract grounds. It is SERVER-COMPUTED from two REST sources — Tesla's
    /// `service_data.service_etc`, polled on connectivity edges, or the owner's
    /// "expected back" entry — and the schema is explicit that "a `vehicle_update`
    /// frame NEVER contains serviceEstimatedEndAt". There is no proto for it;
    /// folding it would invent a delivery path the server does not have. It also
    /// needs no client-side expiry: the server clears it when the car leaves
    /// `in_service`, so a driving/parked row never carries a stale window.
    private static let snapshotOnlyFields: Set<String> = [
        "vehicleId", "name", "model", "year", "color", "vin", "softwareVersion", "trim",
        "licensePlate",
        "seatCoolingCapable",
        "serviceEstimatedEndAt",
    ]

    /// The table must account for EVERY property on the generated `VehicleState`.
    /// This is the tripwire: a new contracts field lands here as a failure until it
    /// is folded (a `foldCases` row) or explicitly declared snapshot-only.
    func testCanonicalTableCoversEveryContractedField() throws {
        let contracted = Set(Mirror(reflecting: try baseState()).children.compactMap(\.label))
        XCTAssertFalse(contracted.isEmpty, "Mirror produced no VehicleState properties — the table check would vacuously pass")

        let accounted = Set(Self.foldCases.map(\.field)).union(Self.snapshotOnlyFields)

        XCTAssertEqual(
            contracted.subtracting(accounted).sorted(), [],
            """
            New VehicleState field(s) are neither folded by VehicleStateMerger nor \
            declared snapshot-only. Add a `case` to the merger plus a `foldCases` row, \
            or list the field in `snapshotOnlyFields` with a reason. (This is the \
            MYR-298 regression class: MYR-272's hand-list silently dropped four \
            contracted cabin fields into `default:`.)
            """
        )
        XCTAssertEqual(
            accounted.subtracting(contracted).sorted(), [],
            "The canonical table names field(s) that no longer exist on VehicleState — the contracts package changed under it."
        )
    }

    /// Every contracted field folds from one fully-populated live delta.
    func testEveryContractedFieldRoundTripsThroughTheMerger() throws {
        // Precondition that makes the assertions below load-bearing: no probe value
        // may already equal what the fixture says, or "it folded" and "the fixture
        // already said that" would be indistinguishable.
        let state = try baseState()
        for row in Self.foldCases {
            XCTAssertFalse(
                row.isFolded(state),
                "probe value for `\(row.field)` matches the snapshot fixture — pick a different one or the fold assertion proves nothing"
            )
        }

        let fields = Dictionary(uniqueKeysWithValues: Self.foldCases.map { ($0.field, $0.delta) })
        let result = VehicleStateMerger.apply(fields: fields, to: state)

        XCTAssertFalse(result.navigationCleared, "no delta value is null — nothing should amplify to a nav clear")
        for row in Self.foldCases {
            XCTAssertTrue(
                row.isPresent(result.state),
                "`\(row.field)` is still nil after a vehicle_update carrying it — the merger dropped it into `default:`"
            )
            XCTAssertTrue(
                row.isFolded(result.state),
                "`\(row.field)` folded to the wrong value (wrong JSONValue accessor or enum parse?)"
            )
        }
    }

    /// Every OPTIONAL contracted field honors an explicit JSON null as a clear —
    /// for navigation members that clear amplifies to the whole group (NFR-3.9).
    func testEveryOptionalContractedFieldHonorsAnExplicitNullClear() throws {
        let fields = Dictionary(uniqueKeysWithValues: Self.foldCases.map { ($0.field, $0.delta) })
        let seeded = VehicleStateMerger.apply(fields: fields, to: try baseState()).state

        for row in Self.foldCases {
            guard let isCleared = row.isCleared else { continue }
            XCTAssertTrue(row.isPresent(seeded), "precondition: \(row.field) must be seeded before the clear probe")
            let cleared = VehicleStateMerger.apply(fields: [row.field: .null], to: seeded).state
            XCTAssertTrue(isCleared(cleared), "`\(row.field)`: an explicit JSON null must clear the field")
        }
    }

    /// MYR-298 — the four cabin fields MYR-272's hand-list missed, called out by
    /// name so a regression reads as itself and not as a table-coverage failure.
    func testMyr298CabinFieldsFoldOnLiveDelta() throws {
        let result = VehicleStateMerger.apply(fields: [
            "hvacAutoMode": .string("On"),
            "hvacAcEnabled": .bool(true),
            "seatVentEnabled": .bool(true),
            "mediaPlaybackStatus": .string("Playing"),
        ], to: try baseState())

        XCTAssertEqual(result.state.hvacAutoMode, .on, "climate mode must not go stale after the connect snapshot")
        XCTAssertEqual(result.state.hvacAcEnabled, true)
        XCTAssertEqual(result.state.seatVentEnabled, true, "seat-vent capability must arrive on the live path")
        XCTAssertEqual(result.state.mediaPlaybackStatus, .playing, "play/pause must reflect the car, not just local taps")
        XCTAssertTrue(result.changedGroups.isEmpty, "cabin fields carry no dataState dimension")
    }

    // MARK: - Media now-playing (MYR-303 / MYR-308, contracts 0.16.0)

    /// The eight now-playing fields fold from ONE live delta, called out by name so
    /// a regression reads as itself rather than as a table-coverage failure (the
    /// MYR-298 lesson). Without the fold the sheet would show the title from the
    /// last cold snapshot while the car played something else.
    func testMyr303MediaNowPlayingFieldsFoldOnLiveDelta() throws {
        let result = VehicleStateMerger.apply(fields: [
            "mediaNowPlayingTitle": .string("Nightcall"),
            "mediaNowPlayingArtist": .string("Kavinsky"),
            "mediaNowPlayingAlbum": .string("OutRun"),
            "mediaNowPlayingStation": .string("KEXP 90.3"),
            "mediaPlaybackSource": .string("Spotify"),
            "mediaNowPlayingDurationMs": .number(263_000),
            "mediaNowPlayingElapsedMs": .number(41_000),
            "mediaVolumeMax": .number(11),
        ], to: try baseState())

        XCTAssertEqual(result.state.mediaNowPlayingTitle, "Nightcall")
        XCTAssertEqual(result.state.mediaNowPlayingArtist, "Kavinsky")
        XCTAssertEqual(result.state.mediaNowPlayingAlbum, "OutRun")
        XCTAssertEqual(result.state.mediaNowPlayingStation, "KEXP 90.3")
        XCTAssertEqual(result.state.mediaPlaybackSource, "Spotify")
        XCTAssertEqual(result.state.mediaNowPlayingDurationMs, 263_000)
        XCTAssertEqual(result.state.mediaNowPlayingElapsedMs, 41_000)
        XCTAssertEqual(result.state.mediaVolumeMax, 11)
        XCTAssertTrue(result.changedGroups.isEmpty, "media fields carry no dataState dimension")
    }

    /// The `""` vs `null` distinction the five TEXT fields turn on: an EMPTY STRING
    /// is a VALUE ("nothing is playing" — the track ended, clear the display), while
    /// only a JSON null means "never observed" and nils the property. Collapsing the
    /// two would leave a finished track's title on screen forever.
    func testMyr303EmptyMediaTextIsAValueAndOnlyNullClears() throws {
        var seeded = try baseState()
        seeded.mediaNowPlayingTitle = "Midnight City"
        seeded.mediaNowPlayingArtist = "M83"
        seeded.mediaNowPlayingStation = "KEXP 90.3"
        seeded.mediaPlaybackSource = "Spotify"

        let ended = VehicleStateMerger.apply(fields: [
            "mediaNowPlayingTitle": .string(""),
            "mediaNowPlayingArtist": .string(""),
        ], to: seeded).state
        XCTAssertEqual(ended.mediaNowPlayingTitle, "", "an empty title is 'nothing playing', not 'never observed'")
        XCTAssertEqual(ended.mediaNowPlayingArtist, "")
        XCTAssertNotNil(ended.mediaNowPlayingTitle, "`\"\"` must NOT collapse to nil — the two states drive different UI")

        let cleared = VehicleStateMerger.apply(fields: [
            "mediaNowPlayingTitle": .null,
            "mediaNowPlayingStation": .null,
            "mediaPlaybackSource": .null,
        ], to: ended).state
        XCTAssertNil(cleared.mediaNowPlayingTitle, "an explicit JSON null clears to 'never observed'")
        XCTAssertNil(cleared.mediaNowPlayingStation)
        XCTAssertNil(cleared.mediaPlaybackSource)
    }

    /// The 18000000 ms radio sentinel folds VERBATIM. The merger routes wire values;
    /// interpreting the sentinel (suppressing the scrubber) is the consumer's job,
    /// and rewriting it here would hide the fact from every consumer at once.
    func testMyr303RadioDurationSentinelFoldsVerbatim() throws {
        let result = VehicleStateMerger.apply(
            fields: ["mediaNowPlayingDurationMs": .number(18_000_000)], to: try baseState()
        )
        XCTAssertEqual(result.state.mediaNowPlayingDurationMs, 18_000_000)
    }

    /// MYR-308 — `seatCoolingCapable` is REST-sourced and must NOT fold from a
    /// `vehicle_update`, even when the server (wrongly) includes it: Tesla has no
    /// proto for the field and the schema states a delta NEVER carries it, so
    /// honoring one would invent a delivery path and let a stray frame flip a
    /// hardware fact. It reaches the app on the cold `/snapshot` only.
    func testMyr308SeatCoolingCapableIsNotFoldedFromALiveDelta() throws {
        var state = try baseState()
        state.seatCoolingCapable = true
        let result = VehicleStateMerger.apply(fields: ["seatCoolingCapable": .bool(false)], to: state)
        XCTAssertEqual(
            result.state.seatCoolingCapable, true,
            "a vehicle_update must not change a REST-only spec field (schema: a delta NEVER contains it)"
        )
        XCTAssertTrue(Self.snapshotOnlyFields.contains("seatCoolingCapable"))
    }

    /// MYR-316 — `serviceEstimatedEndAt` is REST-derived, so a live delta claiming
    /// to carry it must be IGNORED, not folded. The failure this guards against is
    /// subtle and consequential: a folded delta could silently move the rider's
    /// scheduling floor (or clear it) off a frame the server never sends.
    func testMyr316ServiceEstimatedEndAtIsNotFoldedFromALiveDelta() throws {
        var state = try baseState()
        state.serviceEstimatedEndAt = "2026-07-28T21:00:00.000Z"
        let result = VehicleStateMerger.apply(
            fields: ["serviceEstimatedEndAt": .string("2026-07-29T09:00:00.000Z")], to: state
        )
        XCTAssertEqual(
            result.state.serviceEstimatedEndAt, "2026-07-28T21:00:00.000Z",
            "a vehicle_update must not change a REST-only field (schema: a delta NEVER contains it)"
        )
        XCTAssertTrue(Self.snapshotOnlyFields.contains("serviceEstimatedEndAt"))

        // A delta carrying an explicit NULL must not clear it either — the server
        // clears the field itself on the in_service→parked transition, and a
        // client that honored a phantom null would drop a live floor early.
        let cleared = VehicleStateMerger.apply(fields: ["serviceEstimatedEndAt": .null], to: state)
        XCTAssertEqual(cleared.state.serviceEstimatedEndAt, "2026-07-28T21:00:00.000Z")
    }

    /// Unknown wire values on the two MYR-298 string enums survive as
    /// `.unrecognized` rather than being dropped (forward-compat, MYR-195).
    func testMyr298EnumFieldsPreserveUnrecognizedWireValues() throws {
        let result = VehicleStateMerger.apply(fields: [
            "hvacAutoMode": .string("FutureMode"),
            "mediaPlaybackStatus": .string("Buffering"),
        ], to: try baseState())

        XCTAssertEqual(result.state.hvacAutoMode?.rawValue, "FutureMode")
        XCTAssertEqual(result.state.mediaPlaybackStatus?.rawValue, "Buffering")
    }
}
