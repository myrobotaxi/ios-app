import CoreLocation
import DesignSystem
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Contracts → view-model mapping (MYR-201 deliverable 1)
//
// The single, PURE translation layer between the Kit's generated
// `MyRobotaxiContracts` types (`VehicleSummary`, `VehicleState`) and the app's
// existing view-facing models (`Vehicle`, `VehicleActivity`,
// `VehicleTelemetrySnapshot`, `MRTVehicleStatus`). Every function here is a
// static pure map with no I/O — that is what makes the adapter unit-testable
// with contracts fixtures and no network (MYR-201 deliverable 5).
//
// Design rules honored:
// - **Neutral fallbacks for open enums** — the generated `Status`/`GearPosition`/
//   `ChargeState` enums carry an `.unrecognized(String)` arm for forward-compat
//   wire values (MYR-195). Every switch here handles it with a calm, known
//   fallback rather than crashing or inventing a look.
// - **`offline` maps to the design's Offline badge** — `MRTVehicleStatus`
//   (DesignSystem `StatusIndicators`) is exactly the design's four badge states
//   (driving/parked/charging/offline); wire `status` folds onto it.
// - **No hand-written wire shapes** — this file only READS generated properties.
enum VehicleContractMapping {

    // MARK: Status → design badge

    /// Fold the full-snapshot `VehicleState.Status` onto the design's badge set.
    /// `inService` now surfaces its own `inService` badge (MYR-259 — the backend
    /// reliably reports and clears this status); `unrecognized` (a newer-contracts
    /// wire value) takes the neutral `offline` fallback rather than guessing a
    /// live state.
    static func badgeStatus(from wire: VehicleState.Status) -> MRTVehicleStatus {
        switch wire {
        case .driving: return .driving
        case .parked: return .parked
        case .charging: return .charging
        case .offline: return .offline
        case .inService: return .inService        // MYR-259 — own badge
        case .unrecognized: return .offline       // forward-compat wire value — neutral
        }
    }

    /// Same fold for the lean list-row `VehicleSummary.Status` (identical arms).
    static func badgeStatus(from wire: VehicleSummary.Status) -> MRTVehicleStatus {
        switch wire {
        case .driving: return .driving
        case .parked: return .parked
        case .charging: return .charging
        case .offline: return .offline
        case .inService: return .inService        // MYR-259 — own badge
        case .unrecognized: return .offline
        }
    }

    /// Whether the snapshot's hero should render the *driving* layout. Only the
    /// literal `driving` wire status drives motion; charging/parked/offline/
    /// in_service/unrecognized are all the stationary (parked) hero.
    static func isDriving(_ wire: VehicleState.Status) -> Bool {
        if case .driving = wire { return true }
        return false
    }

    /// MYR-260 — whether the car is currently STREAMING live telemetry. Online
    /// states (driving/parked/charging) stream ~1 Hz, so an unknown control value
    /// is genuinely in flight ("Syncing"); a car that is offline or in service
    /// (or a forward-compat unrecognized status, treated conservatively) is NOT
    /// streaming, so a value the one-shot REST read couldn't fill will not arrive
    /// ("Unavailable"). Feeds `VehicleTelemetrySnapshot.isStreaming`.
    static func isStreaming(_ wire: VehicleState.Status) -> Bool {
        switch wire {
        case .driving, .parked, .charging: return true
        case .offline, .inService, .unrecognized: return false
        }
    }

    // MARK: VehicleState → telemetry snapshot (the M1/M2 seam value)

    /// Map a full `VehicleState` onto the hero's per-tick `VehicleTelemetrySnapshot`.
    /// `status` collapses to the seam's binary driving/parked (the richer badge
    /// state travels separately via ``badgeStatus(from:)``); `progress` is derived
    /// from how far along the nav route the trip has travelled.
    static func snapshot(from state: VehicleState) -> VehicleTelemetrySnapshot {
        let driving = isDriving(state.status)
        return VehicleTelemetrySnapshot(
            status: driving ? .driving : .parked,
            progress: driving ? tripProgress(from: state) : 0,
            speedMPH: max(0, state.speed),
            batteryPercent: Double(min(100, max(0, state.chargeLevel))),
            etaMinutes: driving ? max(0, state.etaMinutes ?? 0) : 0,
            // Real cabin/ambient temps (MYR-251) plus the Lifetime stats the
            // `VehicleState` contract carries: `odometerMiles` and
            // `fsdMilesSinceReset` (MYR-255 — both non-nullable in the contract,
            // so once a snapshot arrives they are always real, never a fixture).
            // "Driven autonomously %" is derived from these two in the view.
            // Tire pressures, full VIN, and software version are NOT contracted —
            // they render honest-unknown on the live path (backend-field gap).
            interiorTempF: state.interiorTemp,
            exteriorTempF: state.exteriorTemp,
            odometerMiles: state.odometerMiles,
            fsdMilesSinceReset: state.fsdMilesSinceReset,
            // MYR-260 — the read time + streaming state let the controls label an
            // unknown value honestly (Syncing vs Unavailable) and qualify a
            // stale last-known value ("· synced X ago").
            lastUpdated: parseTimestamp(state.lastUpdated),
            isStreaming: isStreaming(state.status),
            // MYR-303 — the car's now-playing block (contracts 0.16.0). `nil` until
            // the car has streamed at least one media field, which is what keeps
            // the block honest-hidden rather than showing MYR-264's fixture track.
            nowPlaying: nowPlaying(from: state),
            // MYR-316 — when the current service visit is estimated to end
            // (contracts 0.17.0). Parsed with the SAME tolerant RFC 3339 reader as
            // `lastUpdated`, so a server emitting fractional seconds and one that
            // doesn't both resolve. An unparseable string degrades to `nil` — "no
            // window known" — which is the honest answer and the one every
            // consumer already handles, rather than a crash or a fabricated date.
            serviceEstimatedEndAt: state.serviceEstimatedEndAt.flatMap(parseTimestamp)
        )
    }

    /// The live now-playing reading, or `nil` when the car has NEVER streamed any
    /// of the six now-playing fields (the media block then hides entirely — the
    /// MYR-264 rule: an unknown track is drawn as nothing, never as a placeholder).
    ///
    /// The `null` / `""` distinction survives this mapping intact and is resolved
    /// downstream by `VehicleNowPlaying`: all-`nil` here means "never observed"
    /// (hide), whereas a present-but-empty title means "nothing playing" (the
    /// honest idle line). Collapsing empties to `nil` here would erase that.
    ///
    /// `mediaVolumeMax` is deliberately NOT part of this value: it is a volume
    /// SCALE fact, not now-playing content, and it belongs to the executor's
    /// volume reconcile (`LiveVehicleCommandExecutor.volumeMax`).
    static func nowPlaying(from state: VehicleState) -> VehicleNowPlaying? {
        let reading = VehicleNowPlaying(
            title: state.mediaNowPlayingTitle,
            artist: state.mediaNowPlayingArtist,
            album: state.mediaNowPlayingAlbum,
            station: state.mediaNowPlayingStation,
            source: state.mediaPlaybackSource,
            durationMs: state.mediaNowPlayingDurationMs,
            elapsedMs: state.mediaNowPlayingElapsedMs
        )
        let everObserved = state.mediaNowPlayingTitle != nil
            || state.mediaNowPlayingArtist != nil
            || state.mediaNowPlayingAlbum != nil
            || state.mediaNowPlayingStation != nil
            || state.mediaPlaybackSource != nil
            || state.mediaNowPlayingDurationMs != nil
            || state.mediaNowPlayingElapsedMs != nil
        return everObserved ? reading : nil
    }

    /// Fraction 0…1 of the active navigation route already travelled, derived
    /// from `tripDistanceRemaining` against the full route's planar length. The
    /// wire carries the vehicle's real GPS, but the app's `VehicleMapView` places
    /// the marker as `position(along: route, progress:)`; deriving `progress`
    /// from distance-remaining keeps that marker on the route near the real
    /// position without a projection. Returns 0 when navigation isn't active or
    /// the route/distance is unknown.
    static func tripProgress(from state: VehicleState) -> Double {
        guard let remaining = state.tripDistanceRemaining else { return 0 }
        let route = routeCoordinates(from: state.navRouteCoordinates)
        let total = VehicleRoute.totalDistanceMiles(along: route)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    // MARK: VehicleState → activity (hero + map geometry)

    /// Derive the hero/map `VehicleActivity` from a live snapshot. Driving builds
    /// a `DrivingTrip` from the navigation atomic group + geocoded origin; every
    /// other status builds a `ParkedLocation` at the vehicle's current position.
    static func activity(from state: VehicleState) -> VehicleActivity {
        if isDriving(state.status) {
            return .driving(drivingTrip(from: state))
        }
        return .parked(parkedLocation(from: state))
    }

    static func drivingTrip(from state: VehicleState) -> DrivingTrip {
        let route = routeCoordinates(from: state.navRouteCoordinates)
        let currentPosition = position(from: state)
        // Prefer the wire nav route; fall back to a straight origin→destination
        // pair when Tesla hasn't decoded a RouteLine yet, and finally to a
        // single current-position point so the marker still has geometry.
        let resolvedRoute: [CLLocationCoordinate2D]
        if route.count > 1 {
            resolvedRoute = route
        } else if let dest = destinationCoordinate(from: state) {
            resolvedRoute = [currentPosition, dest]
        } else {
            resolvedRoute = [currentPosition]
        }
        return DrivingTrip(
            destinationName: nonEmpty(state.destinationName) ?? "Navigating",
            destinationCity: cityComponent(from: state.destinationAddress) ?? "",
            originLabel: nonEmpty(state.locationName) ?? "Start",
            originAddress: state.locationAddress,
            destinationAddress: state.destinationAddress ?? "",
            route: resolvedRoute
        )
    }

    static func parkedLocation(from state: VehicleState) -> ParkedLocation {
        ParkedLocation(
            label: nonEmpty(state.locationName)
                ?? nonEmpty(state.locationAddress)
                ?? "Location unavailable",
            coordinate: position(from: state),
            // No park-start in the contract — UNKNOWN on live (MYR-268). Do NOT
            // derive it from `lastUpdated` (a ~1Hz freshness stamp → perpetual 0m).
            parkedSince: nil
        )
    }

    // MARK: Summary + state → fleet row (`Vehicle`)

    /// Build a `Vehicle` fleet row from a list-endpoint `VehicleSummary`, folding
    /// in the live full `VehicleState` when one has arrived (its GPS/nav upgrade
    /// the placeholder activity). `plate` is the owner-entered `licensePlate`
    /// (contracts 0.15.0) when set, else the VIN last-4 stand-in — see
    /// ``plateDisplay(licensePlate:vinLast4:)``; seat heat/vent aren't in the read
    /// contract, so they take neutral `false` (VehicleControls degrade gracefully).
    static func vehicle(summary: VehicleSummary, state: VehicleState? = nil) -> Vehicle {
        let activity: VehicleActivity = state.map(activity(from:))
            ?? placeholderActivity(for: summary)
        // MYR-279 — make/model, color, full VIN, and software version are sourced
        // from the full `VehicleState` snapshot once it has arrived: telemetry
        // PR #325 populates `year`/`model`/`trim`/`color`/`vin`/`softwareVersion`
        // authoritatively there, while the lean list `VehicleSummary` was showing
        // a partial model (the client's bare "Model" — a wrong-source display bug).
        // The snapshot composes the full "{year} {model} {trimLabel}". Fall back to
        // the summary before the first snapshot streams in — the lean list row has
        // no trim of either kind (deliberately: both are detail-sheet fields).
        //
        // MYR-320 — the suffix is `trimLabel` ("Performance"), not the raw `trim`
        // badge code ("p74d"). See `modelLabel` for why the two are not
        // interchangeable and why a nil label falls back rather than substituting.
        let model = state.map { modelLabel(year: $0.year, model: $0.model, trimLabel: $0.trimLabel) }
            ?? modelLabel(year: summary.year, model: summary.model)
        // Prefer the snapshot's color, else the summary's; both may be blank today
        // (react-frontend onboarding doesn't write color yet — MYR-283) → the
        // detail row renders an honest empty state rather than a fabricated color.
        let colorName = nonEmpty(state?.color) ?? summary.color
        return Vehicle(
            id: summary.vehicleId,
            name: nonEmpty(summary.name) ?? summary.model,
            model: model,
            colorName: colorName,
            // MYR-286 — BOTH read surfaces carry the plate. The snapshot wins when
            // it has one (it is the fresher read and the one a WS reconnect
            // refetches); the list row is the fallback before the first snapshot
            // arrives, so the switcher/Settings rows show the real plate on the
            // very first paint instead of a VIN that flips a second later.
            plate: plateDisplay(
                licensePlate: nonEmpty(state?.licensePlate) ?? summary.licensePlate,
                vinLast4: summary.vinLast4
            ),
            seatHeat: false,
            // MYR-299 — `seatVent` is the ventilated-seat CAPABILITY (does this car
            // HAVE cooled seats), which is what the Heat/Cool affordance must gate
            // on. It is derived from the PRESENCE of the seat-cooler read-backs,
            // because no capability field exists anywhere in the stack. MYR-252's
            // `seatVentEnabled` is a runtime on/off — a vent spinning right now —
            // so reading it as the capability (the shipped bug) left a vented car
            // with both seats off looking heat-only and Cool unreachable. Before
            // the first snapshot every input is nil → honest heating-only UI.
            // MYR-308 — contracts 0.16.0 adds the REAL spec field
            // (`seatCoolingCapable`, from Tesla REST `vehicle_config`). It leads:
            // `true`/`false` are authoritative (an explicit false hides the Heat↔Cool
            // affordance outright, per the schema's "MUST NOT offer seat-cooling
            // controls"), and only `nil` — a server predating MYR-308, or one that
            // hasn't finished a vehicle-config read — falls back to the MYR-299
            // presence heuristic below. Snapshot-only by contract, so it arrives with
            // the cold read and never on a delta.
            seatVent: SeatClimatePresentation.hasVentilatedSeats(
                seatCoolingCapable: state?.seatCoolingCapable,
                seatCoolerLeft: state?.seatCoolerLeft,
                seatCoolerRight: state?.seatCoolerRight,
                seatVentEnabled: state?.seatVentEnabled
            ),
            activity: activity,
            // MYR-279 — the owner's full (owner-masked) VIN + the Tesla software
            // version now ride on the snapshot; nil before the first snapshot →
            // the detail rows render honest-unknown. Never logged (owner P0 data).
            vin: nonEmpty(state?.vin),
            softwareVersion: nonEmpty(state?.softwareVersion),
            // MYR-320 — the FSD designation, snapshot-only (contracts 0.18.0) and
            // passed through VERBATIM: the shape of this string is Tesla's own and
            // may change, so the contract forbids parsing, re-casing or comparing
            // it. Blank is normalized to nil so a server that emits "" omits the
            // row rather than rendering an empty value.
            fsdVersion: nonEmpty(state?.fsdVersion)
        )
    }

    /// Before the socket delivers a full snapshot, the row still needs an
    /// activity for the hero. `driving` summaries get a minimal driving trip
    /// (empty route → marker sits still); everything else parks at an unknown
    /// location. Replaced the moment the real `VehicleState` arrives.
    static func placeholderActivity(for summary: VehicleSummary) -> VehicleActivity {
        switch summary.status {
        case .driving:
            return .driving(DrivingTrip(
                destinationName: "Navigating",
                destinationCity: "",
                originLabel: "Start",
                originAddress: "",
                destinationAddress: "",
                route: []
            ))
        default:
            return .parked(ParkedLocation(
                label: "Locating…",
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                parkedSince: nil // unknown on live (MYR-268)
            ))
        }
    }

    /// The badge status for a fleet row: the live snapshot's status when present,
    /// else the summary's last-known status.
    static func badgeStatus(forSummary summary: VehicleSummary, state: VehicleState?) -> MRTVehicleStatus {
        if let state { return badgeStatus(from: state.status) }
        return badgeStatus(from: summary.status)
    }

    // MARK: - Helpers

    /// `"2026 Model Y Performance"`-style label from the year + model + TRIM LABEL
    /// wire fields (MYR-279, MYR-320), matching the fixture `Vehicle.model` shape.
    /// Each part is dropped gracefully when absent: a zero year is omitted, and a
    /// nil/blank `trimLabel` falls back to "{year} {model}" (e.g. "2026 Model Y")
    /// with NO dangling separator or trailing space.
    ///
    /// MYR-320 — the suffix is `VehicleState.trimLabel` (contracts 0.18.0), NOT the
    /// sibling `trim`, and the parameter is named so that the wrong one cannot be
    /// passed by accident. The two fields are not interchangeable:
    ///
    ///   • `trim` is the RAW BADGE CODE off `vehicle_config.trim_badging` — the
    ///     client's own car reports `"p74d"`. It is a wire-level identifier for
    ///     downstream classification and is NOT display-safe.
    ///   • `trimLabel` is `vehicle_config.performance_package` — `"Performance"`,
    ///     already display-ready, and per the contract "the ONLY one of the two a
    ///     consumer may render".
    ///
    /// The schema's consumer rule is explicit that when `trimLabel` is absent a
    /// client "MUST NOT substitute `trim` in its place" and must fall back to
    /// "{year} {model}". Absence is COMMON AND NORMAL — a server predating MYR-320,
    /// a vehicle-config read that hasn't completed, or a car whose configuration
    /// simply carries no performance designation — so it is never an error state.
    /// The value is rendered verbatim: it arrives display-ready and re-casing it
    /// would silently rewrite Tesla's own label.
    static func modelLabel(year: Int, model: String, trimLabel: String? = nil) -> String {
        var parts: [String] = []
        if year > 0 { parts.append("\(year)") }
        if let model = nonEmpty(model) { parts.append(model) }
        if let trimLabel = nonEmpty(trimLabel) { parts.append(trimLabel) }
        return parts.joined(separator: " ")
    }

    /// THE plate display resolver (MYR-286). Precedence, in one place so every
    /// surface agrees:
    ///
    ///   1. a non-empty `licensePlate` — the owner-entered plate (contracts
    ///      0.15.0), already server-normalized (trimmed, uppercased, ≤ 10,
    ///      `[A-Z0-9 -]`). It is rendered VERBATIM: re-normalizing here would
    ///      silently rewrite the owner's answer, and rest-api.md §7.1/§7.14 tell
    ///      consumers not to.
    ///   2. else the `VIN ····xxxx` fallback built from the VIN last-4 — Tesla
    ///      telemetry has no plate field anywhere, so this is the honest stand-in
    ///      for human disambiguation in the switcher / rider chip.
    ///   3. else `""` — and every caller HIDES the chip on empty rather than
    ///      rendering a blank box. We never fabricate a plate.
    ///
    /// `nil` and `""` mean the SAME thing for `licensePlate` and both take the
    /// fallback: absent = a pre-MYR-286 server, empty = the always-emitted "not
    /// set" value. Neither ever means "this car has a plate we couldn't read".
    static func plateDisplay(licensePlate: String?, vinLast4: String) -> String {
        if let plate = nonEmpty(licensePlate) { return plate }
        let trimmed = vinLast4.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : "VIN ····\(trimmed)"
    }

    /// The owner-entered plate ALONE (no VIN fallback), for the editable owner
    /// surface: `VehicleControlsSnapshot.plate` holds the RAW value so the edit
    /// sheet prefills what the owner typed and an unset plate renders the
    /// designed "Add plate" affordance rather than a VIN the owner can't edit.
    /// Display surfaces use ``plateDisplay(licensePlate:vinLast4:)`` instead.
    static func editablePlate(licensePlate: String?) -> String {
        nonEmpty(licensePlate) ?? ""
    }

    /// `[[lon, lat]]` (GeoJSON/Mapbox order, contracts `navRouteCoordinates`) →
    /// `CLLocationCoordinate2D`. Drops malformed pairs.
    static func routeCoordinates(from wire: [[Double]]?) -> [CLLocationCoordinate2D] {
        guard let wire else { return [] }
        return wire.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    /// The vehicle's current coordinate, honoring the contract's "0,0 = no fix"
    /// convention (§2.3) by leaving it at the origin — callers treat it as
    /// last-known geometry, never a valid Gulf-of-Guinea location.
    static func position(from state: VehicleState) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude)
    }

    static func destinationCoordinate(from state: VehicleState) -> CLLocationCoordinate2D? {
        guard let lat = state.destinationLatitude, let lon = state.destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Best-effort "city" line for the route timeline — the last-but-one
    /// comma-separated component of the destination address
    /// (e.g. "202 Stage Rd, Pescadero, CA" → "Pescadero").
    static func cityComponent(from address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 2 ? parts[parts.count - 2] : parts.last
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseTimestamp(_ value: String) -> Date? {
        iso8601.date(from: value) ?? iso8601WithFractional.date(from: value)
    }
}
