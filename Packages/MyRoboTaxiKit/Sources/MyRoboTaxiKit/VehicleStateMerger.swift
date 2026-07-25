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

            // Owner control / cabin fields (MYR-272). These were dropped by the
            // `default` arm, so a LIVE `vehicle_update` toggling climate/lock/trunk
            // etc. never folded into `state` — the tiles reflected the field only
            // on a full snapshot (reconnect/sheet-open). The client enabled climate
            // in the car and the app never showed it "On" (only interiorTemp — which
            // IS folded above — dropped). Fold them so a live change reaches the
            // tiles via `onStateChanged` → `reconcile`. Each honors an explicit null
            // (clear); the reconcile layer guards against clobbering in-flight
            // optimistic commands, so no extra gating is needed here.
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
            case "mediaVolume":
                if value.isNull { state.mediaVolume = nil } else if let v = value.numberValue { state.mediaVolume = v }

            default:
                break // unknown / forward-compat field — ignore
            }
        }

        return Result(state: state, changedGroups: changed, navigationCleared: navCleared)
    }
}
