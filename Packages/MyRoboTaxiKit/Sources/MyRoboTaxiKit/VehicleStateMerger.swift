import MyRobotaxiContracts

/// Folds a live `vehicle_update.fields` delta onto an accumulated `VehicleState`.
///
/// Every field name here is a documented `VehicleState` wire field
/// (vehicle-state-schema.md §1.1); the Kit hand-writes **no** wire shape — it
/// only routes decoded `JSONValue`s onto the generated `VehicleState`
/// properties. Unknown field names are ignored (open-object rule, §3.1).
///
/// Nav-clear amplification (NFR-3.9 / Rule CG-SM-3): if **any** navigation-group
/// field arrives as JSON `null`, the **whole** navigation group is nulled
/// atomically — regardless of which members the server actually sent.
public enum VehicleStateMerger {
    /// Wire field names of the navigation atomic group.
    static let navigationFields: Set<String> = [
        "destinationName", "destinationAddress", "destinationLatitude",
        "destinationLongitude", "originLatitude", "originLongitude",
        "etaMinutes", "tripDistanceRemaining", "navRouteCoordinates",
    ]

    public struct Result: Sendable, Equatable {
        public var state: VehicleState
        /// Atomic groups touched by this delta.
        public var changedGroups: Set<AtomicGroup>
        /// True when the delta triggered an atomic navigation clear.
        public var navigationCleared: Bool
    }

    /// Classify a raw `fields` map into the atomic groups it touches, and whether
    /// it carries a navigation clear — without needing a `VehicleState` to fold
    /// onto. Used by the socket to drive per-group `dataState` transitions.
    public static func classify(fields: [String: JSONValue]) -> (groups: Set<AtomicGroup>, navigationCleared: Bool) {
        var groups: Set<AtomicGroup> = []
        var navCleared = false
        for (key, value) in fields {
            switch key {
            case "latitude", "longitude", "heading":
                groups.insert(.gps)
            case "gearPosition", "status":
                groups.insert(.gear)
            case "chargeLevel", "chargeState", "estimatedRange", "timeToFull":
                groups.insert(.charge)
            case _ where navigationFields.contains(key):
                groups.insert(.navigation)
                if value.isNull { navCleared = true }
            default:
                break // ungrouped or unknown — no dataState dimension
            }
        }
        return (groups, navCleared)
    }

    /// Apply `fields` onto `original`, returning the merged state plus which
    /// groups changed.
    public static func apply(fields: [String: JSONValue], to original: VehicleState) -> Result {
        var state = original
        var changed: Set<AtomicGroup> = []

        // Detect and amplify a navigation clear first (NFR-3.9).
        let navCleared = fields.contains { navigationFields.contains($0.key) && $0.value.isNull }
        if navCleared {
            state.destinationName = nil
            state.destinationAddress = nil
            state.destinationLatitude = nil
            state.destinationLongitude = nil
            state.originLatitude = nil
            state.originLongitude = nil
            state.etaMinutes = nil
            state.tripDistanceRemaining = nil
            state.navRouteCoordinates = nil
            changed.insert(.navigation)
        }

        for (key, value) in fields {
            switch key {
            // GPS group
            case "latitude": if let v = value.numberValue { state.latitude = v; changed.insert(.gps) }
            case "longitude": if let v = value.numberValue { state.longitude = v; changed.insert(.gps) }
            case "heading": if let v = value.numberValue { state.heading = Int(v); changed.insert(.gps) }

            // Gear group
            case "gearPosition":
                if value.isNull { state.gearPosition = nil }
                else if let v = value.stringValue { state.gearPosition = VehicleState.GearPosition(rawValue: v) }
                changed.insert(.gear)
            case "status":
                if let v = value.stringValue { state.status = VehicleState.Status(rawValue: v); changed.insert(.gear) }

            // Charge group
            case "chargeLevel": if let v = value.numberValue { state.chargeLevel = Int(v); changed.insert(.charge) }
            case "chargeState":
                if value.isNull { state.chargeState = nil }
                else if let v = value.stringValue { state.chargeState = VehicleState.ChargeState(rawValue: v) }
                changed.insert(.charge)
            case "estimatedRange": if let v = value.numberValue { state.estimatedRange = Int(v); changed.insert(.charge) }
            case "timeToFull":
                if value.isNull { state.timeToFull = nil }
                else if let v = value.numberValue { state.timeToFull = v }
                changed.insert(.charge)

            // Navigation group (skipped when a clear already nulled the group)
            case "destinationName" where !navCleared:
                if let v = value.stringValue { state.destinationName = v; changed.insert(.navigation) }
            case "destinationAddress" where !navCleared:
                if let v = value.stringValue { state.destinationAddress = v; changed.insert(.navigation) }
            case "destinationLatitude" where !navCleared:
                if let v = value.numberValue { state.destinationLatitude = v; changed.insert(.navigation) }
            case "destinationLongitude" where !navCleared:
                if let v = value.numberValue { state.destinationLongitude = v; changed.insert(.navigation) }
            case "originLatitude" where !navCleared:
                if let v = value.numberValue { state.originLatitude = v; changed.insert(.navigation) }
            case "originLongitude" where !navCleared:
                if let v = value.numberValue { state.originLongitude = v; changed.insert(.navigation) }
            case "etaMinutes" where !navCleared:
                if let v = value.numberValue { state.etaMinutes = Int(v); changed.insert(.navigation) }
            case "tripDistanceRemaining" where !navCleared:
                if let v = value.numberValue { state.tripDistanceRemaining = v; changed.insert(.navigation) }
            case "navRouteCoordinates" where !navCleared:
                if let array = value.arrayValue {
                    state.navRouteCoordinates = array.map { $0.arrayValue?.compactMap(\.numberValue) ?? [] }
                }
                changed.insert(.navigation)

            // Ungrouped fields (no dataState dimension)
            case "speed": if let v = value.numberValue { state.speed = Int(v) }
            case "odometerMiles": if let v = value.numberValue { state.odometerMiles = Int(v) }
            case "interiorTemp": if let v = value.numberValue { state.interiorTemp = Int(v) }
            case "exteriorTemp": if let v = value.numberValue { state.exteriorTemp = Int(v) }
            case "fsdMilesSinceReset": if let v = value.numberValue { state.fsdMilesSinceReset = v }
            case "locationName": if let v = value.stringValue { state.locationName = v }
            case "locationAddress": if let v = value.stringValue { state.locationAddress = v }
            case "lastUpdated": if let v = value.stringValue { state.lastUpdated = v }

            // Owner control / cabin fields (MYR-272, completed by MYR-298). These
            // were dropped by the `default` arm, so a LIVE `vehicle_update`
            // toggling climate/lock/trunk
            // etc. never folded into `state` — the tiles reflected the field only
            // on a full snapshot (reconnect/sheet-open). The client enabled climate
            // in the car and the app never showed it "On" (only interiorTemp — which
            // IS folded above — dropped). Fold them so a live change reaches the
            // tiles via `onStateChanged` → `reconcile`. Each honors an explicit null
            // (clear); the reconcile layer guards against clobbering in-flight
            // optimistic commands, so no extra gating is needed here.
            //
            // MYR-298 — MYR-272 hand-enumerated 17 of the 21 contracted cabin
            // fields and the remaining four (`hvacAutoMode`, `hvacAcEnabled`,
            // `seatVentEnabled`, `mediaPlaybackStatus`) kept falling into
            // `default:`: climate mode went stale after the connect snapshot, the
            // seat-vent capability never arrived, and the media play/pause icon
            // reflected only local taps. `VehicleStateMergerTests` now derives its
            // coverage from a canonical table checked against `Mirror`-reflected
            // `VehicleState` properties, so the next contracts field cannot repeat
            // this silently.
            case "isClimateOn":
                if value.isNull { state.isClimateOn = nil } else if let v = value.boolValue { state.isClimateOn = v }
            case "hvacPower":
                if value.isNull { state.hvacPower = nil }
                else if let v = value.stringValue { state.hvacPower = VehicleState.HvacPower(rawValue: v) }
            case "locked":
                if value.isNull { state.locked = nil } else if let v = value.boolValue { state.locked = v }
            case "frunkOpen":
                if value.isNull { state.frunkOpen = nil } else if let v = value.boolValue { state.frunkOpen = v }
            case "trunkOpen":
                if value.isNull { state.trunkOpen = nil } else if let v = value.boolValue { state.trunkOpen = v }
            case "chargePortDoorOpen":
                if value.isNull { state.chargePortDoorOpen = nil } else if let v = value.boolValue { state.chargePortDoorOpen = v }
            case "fanSpeed":
                if value.isNull { state.fanSpeed = nil } else if let v = value.numberValue { state.fanSpeed = Int(v) }
            case "driverTempSetting":
                if value.isNull { state.driverTempSetting = nil } else if let v = value.numberValue { state.driverTempSetting = Int(v) }
            case "passengerTempSetting":
                if value.isNull { state.passengerTempSetting = nil } else if let v = value.numberValue { state.passengerTempSetting = Int(v) }
            case "hvacAutoMode":
                if value.isNull { state.hvacAutoMode = nil }
                else if let v = value.stringValue { state.hvacAutoMode = VehicleState.HvacAutoMode(rawValue: v) }
            case "hvacAcEnabled":
                if value.isNull { state.hvacAcEnabled = nil } else if let v = value.boolValue { state.hvacAcEnabled = v }
            case "seatHeaterLeft":
                if value.isNull { state.seatHeaterLeft = nil } else if let v = value.numberValue { state.seatHeaterLeft = Int(v) }
            case "seatHeaterRight":
                if value.isNull { state.seatHeaterRight = nil } else if let v = value.numberValue { state.seatHeaterRight = Int(v) }
            case "seatHeaterRearLeft":
                if value.isNull { state.seatHeaterRearLeft = nil } else if let v = value.numberValue { state.seatHeaterRearLeft = Int(v) }
            case "seatHeaterRearCenter":
                if value.isNull { state.seatHeaterRearCenter = nil } else if let v = value.numberValue { state.seatHeaterRearCenter = Int(v) }
            case "seatHeaterRearRight":
                if value.isNull { state.seatHeaterRearRight = nil } else if let v = value.numberValue { state.seatHeaterRearRight = Int(v) }
            case "seatCoolerLeft":
                if value.isNull { state.seatCoolerLeft = nil } else if let v = value.numberValue { state.seatCoolerLeft = Int(v) }
            case "seatCoolerRight":
                if value.isNull { state.seatCoolerRight = nil } else if let v = value.numberValue { state.seatCoolerRight = Int(v) }
            case "seatVentEnabled":
                if value.isNull { state.seatVentEnabled = nil } else if let v = value.boolValue { state.seatVentEnabled = v }
            case "mediaPlaybackStatus":
                if value.isNull { state.mediaPlaybackStatus = nil }
                else if let v = value.stringValue { state.mediaPlaybackStatus = VehicleState.MediaPlaybackStatus(rawValue: v) }
            case "mediaVolume":
                if value.isNull { state.mediaVolume = nil } else if let v = value.numberValue { state.mediaVolume = v }

            // MARK: Media now-playing (MYR-303 — contracts 0.16.0)
            //
            // All eight fields STREAM LIVE on `vehicle_update` (Tesla
            // fleet-telemetry **Media** group, pushed ON CHANGE), so they FOLD
            // here with the standard null-clear semantics — exactly like the
            // MYR-298 siblings `mediaPlaybackStatus`/`mediaVolume` they arrive
            // alongside. Leaving them in `default:` is the MYR-272/298 regression
            // class: the track would change in the car and the sheet would keep
            // the title from the last cold snapshot.
            //
            // For the five TEXT fields an explicit `""` is a VALUE, not a clear.
            // The wire distinguishes two different facts:
            //   • JSON `null`  → NEVER OBSERVED  → nil (the display hides).
            //   • `""`         → NOTHING PLAYING → an empty string the UI must
            //                     adopt (the track ended; the display CLEARS to
            //                     its honest idle state rather than keeping the
            //                     last title on screen).
            // Collapsing `""` to nil here would erase that distinction and leave
            // a finished track showing forever, so only `isNull` nils the
            // property and every other string — empty included — is assigned.
            case "mediaNowPlayingTitle":
                if value.isNull { state.mediaNowPlayingTitle = nil }
                else if let v = value.stringValue { state.mediaNowPlayingTitle = v }
            case "mediaNowPlayingArtist":
                if value.isNull { state.mediaNowPlayingArtist = nil }
                else if let v = value.stringValue { state.mediaNowPlayingArtist = v }
            case "mediaNowPlayingAlbum":
                if value.isNull { state.mediaNowPlayingAlbum = nil }
                else if let v = value.stringValue { state.mediaNowPlayingAlbum = v }
            case "mediaNowPlayingStation":
                if value.isNull { state.mediaNowPlayingStation = nil }
                else if let v = value.stringValue { state.mediaNowPlayingStation = v }
            case "mediaPlaybackSource":
                if value.isNull { state.mediaPlaybackSource = nil }
                else if let v = value.stringValue { state.mediaPlaybackSource = v }
            // Numeric members: folded VERBATIM. The 18000000 ms radio sentinel is
            // a real wire value that must survive the fold intact — the merger
            // routes, it does not interpret; suppressing the scrubber against the
            // sentinel is the CONSUMER's job (`VehicleNowPlaying.progress`).
            case "mediaNowPlayingDurationMs":
                if value.isNull { state.mediaNowPlayingDurationMs = nil }
                else if let v = value.numberValue { state.mediaNowPlayingDurationMs = Int(v) }
            case "mediaNowPlayingElapsedMs":
                if value.isNull { state.mediaNowPlayingElapsedMs = nil }
                else if let v = value.numberValue { state.mediaNowPlayingElapsedMs = Int(v) }
            case "mediaVolumeMax":
                if value.isNull { state.mediaVolumeMax = nil }
                else if let v = value.numberValue { state.mediaVolumeMax = v }

            // NOT FOLDED, deliberately: `seatCoolingCapable` (contracts 0.16.0).
            // It is a SPEC fact read from Tesla's REST `vehicle_config`
            // (`has_seat_cooling`), not telemetry — Tesla has no proto for it and
            // never streams it, so "a `vehicle_update` frame NEVER contains
            // seatCoolingCapable" (vehicle-state-schema.md). Folding it would
            // invent a delivery path the server does not have. It reaches clients
            // on REST reads only, like the sibling `trim`, and is declared in the
            // MYR-298 tripwire's `snapshotOnlyFields` for exactly that reason.
            //
            // NOT FOLDED, deliberately: `serviceEstimatedEndAt` (contracts 0.17.0,
            // MYR-316). Same class as `seatCoolingCapable` above and `licensePlate`
            // — it is REST-DERIVED, not telemetry. The server computes it from
            // Tesla's `service_data.service_etc` (a REST poll on connectivity
            // edges) or the owner's entry, and the schema states plainly that "a
            // `vehicle_update` frame NEVER contains serviceEstimatedEndAt". Folding
            // it would invent a delivery path the server does not have. It reaches
            // clients on the REST `/snapshot` and `GET /api/vehicles` only, and is
            // declared in the MYR-298 tripwire's `snapshotOnlyFields` for exactly
            // that reason. (It also needs no client-side ageing out: the server
            // clears it automatically the moment the car leaves `in_service`.)
            //
            // NOT FOLDED, deliberately: `trimLabel` and `fsdVersion` (contracts
            // 0.18.0, MYR-320). Both are REST-derived detail-sheet facts read on
            // the SAME non-waking connectivity-edge / periodic read family as the
            // sibling `trim` that already sits in `snapshotOnlyFields`:
            // `trimLabel` comes from `vehicle_config.performance_package`, and
            // `fsdVersion` from the TITLE of the newest `GET
            // /api/1/vehicles/{vin}/release_notes` entry — a surface with no
            // `vehicle_data` field and no proto behind it at all. The schema says
            // plainly that a `vehicle_update` frame NEVER contains either, so
            // folding them would invent a delivery path the server does not have.
            //
            // NOT FOLDED, deliberately: `rideShareEnabled` (contracts 0.20.0,
            // MYR-342). This one LOOKS foldable — a plain optional Bool, the exact
            // shape of every MYR-272/298 cabin field above — and that is precisely
            // why the reason is written out rather than left to the type. It is not
            // TELEMETRY at all: it is the OWNER'S INTENTION about the car, written
            // only by `PUT /api/tesla/vehicles/{id}/ride-share` (rest-api.md
            // §7.18). Tesla has no proto for "this owner is lending their car out",
            // no fleet-config change was involved, and both the contract and the
            // endpoint spec state plainly that a `vehicle_update` frame NEVER
            // carries it and that a ride-share edit fires NO push at all.
            //
            // Here folding would be worse than merely inventing a delivery path the
            // server lacks — it would re-open on the client the exact hole the
            // SERVER went out of its way to close. §7.18 keeps this column off the
            // shared telemetry-fed control-state upsert specifically so that "any
            // routine frame from the car [cannot] silently re-enable ride sharing on
            // a vehicle its owner had paused", and asserts the property rather than
            // commenting it (`TestVehicleRepo_RideShareIsNotReachableFromTelemetry`).
            // A merger arm here would hand that path straight back: a frame carrying
            // the key — from a server bug, a replayed envelope, a future field
            // collision — would lift an owner's pause with nobody having touched the
            // switch. The pause is liftable by exactly one actor, and the merger is
            // not it. The value reaches clients on the REST `/snapshot` and `GET
            // /api/vehicles` only, or from the PUT's own echo, and is declared in
            // the MYR-298 tripwire's `snapshotOnlyFields` for those reasons.

            default:
                break // unknown / forward-compat field — ignore
            }
        }

        return Result(state: state, changedGroups: changed, navigationCleared: navCleared)
    }
}
