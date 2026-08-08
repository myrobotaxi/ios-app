import SwiftUI
import DesignSystem

// MARK: - VehicleControls (MYR-168, design/app/vehicle-controls.jsx)
//
// The full tile stack revealed when the home sheet drags to half (Handoff
// §5.5): quick lock/climate/trunk/charge tiles, Climate, Media, Status &
// location (parked only), Tire pressure, Lifetime, and Vehicle details.
// M1 renders faithfully against `SimulatedVehicleCommandExecutor` — no
// network (CLAUDE.md "M1 is simulated"); P11 (MYR-180-183) swaps the
// executor, not this view (see VehicleCommandExecutor.swift header).
struct VehicleControls: View {
    let vehicle: Vehicle
    let driving: Bool
    let batteryPercent: Double
    let parkedLocation: ParkedLocation?
    let executor: any VehicleCommandExecutor
    @Binding var isEditingPlate: Bool

    /// Real cabin/ambient temps from the telemetry snapshot (MYR-251). Live: the
    /// wire `interiorTemp`/`exteriorTemp`; simulated: the fixture 66/58 (so M1 is
    /// pixel-identical); `nil` = unknown (no snapshot yet) → renders "—".
    let cabinTemp: Int?
    let extTemp: Int?
    /// Real Lifetime stats from the snapshot (MYR-255). Live: the wire
    /// `odometerMiles`/`fsdMilesSinceReset`; simulated: the fixtures 42,184/31,907;
    /// `nil` = not yet streamed → the Lifetime rows render "— Syncing".
    let odometerMiles: Int?
    let fsdMilesSinceReset: Double?
    /// MYR-260 — the live snapshot's server read time + whether the car is
    /// currently streaming, threaded from `VehicleTelemetrySnapshot`. They drive
    /// the honest unknown labeling (Syncing vs Unavailable) and the stale
    /// "X ago" qualifier. `nil`/`nil` on the simulated path, so M1 / drift-gate
    /// render pixel-identically.
    let lastUpdated: Date?
    let isStreaming: Bool?
    /// MYR-301 — routes a re-link notice ("Reconnect Tesla …") to the app's
    /// EXISTING Tesla link flow (Settings → Tesla Account → Add another Tesla →
    /// `AddTeslaFlow`), which is what re-runs consent and picks up a missing
    /// scope such as `vehicle_charging_cmds`. `nil` on hosts that can't route
    /// (previews) — the notice then still shows its full text, just without a
    /// tappable fix.
    var onRelinkTesla: (() -> Void)? = nil
    /// MYR-264 — the ONE resolved live flag. The now-playing media metadata
    /// (title/artist/cover) is a pure fixture (`VehicleMediaTrack`, not on the
    /// `VehicleState` contract), so it is honest-hidden on live; the transport +
    /// volume controls route REAL commands (MYR-249/251) and stay. `false` in SIM
    /// keeps the media section pixel-identical.
    var isLive: Bool = false
    /// MYR-303 — the REAL now-playing block off the wire (contracts 0.16.0),
    /// threaded from the telemetry snapshot like every other read-only live value
    /// in this sheet (temps, odometer, freshness). `nil` in SIM and on a live car
    /// that has never streamed a media field → the Media card renders exactly what
    /// MYR-264 left it as.
    var nowPlaying: VehicleNowPlaying? = nil
    /// MYR-316 — the real badge state, for the Status & location chip. `.parked`
    /// (the default) is the literal chip this view shipped with, so SIM is
    /// pixel-identical; a live in-service car now says so instead of "Parked".
    var badgeStatus: MRTVehicleStatus = .parked
    /// MYR-316 — opens the "Expected back" entry sheet (owned by `HomeScreen`'s
    /// root `mrtConfigSheet`, exactly like the plate editor). `nil` on hosts that
    /// don't present it (previews).
    var onEditServiceWindow: (() -> Void)? = nil
    /// MYR-316 — the resolved service window driving the expected-back row.
    /// Threaded from the telemetry snapshot like every other read-only live value
    /// in this sheet. `nil` on the simulated path → the row does not exist.
    var serviceEstimatedEndAt: Date? = nil
    /// MYR-333 — the car's live charge session, threaded from the telemetry
    /// snapshot like every other read-only live value here. `.idle` on the
    /// simulated path and before the first live frame, so the tile keeps its
    /// pre-MYR-333 port-door sub and M1 stays pixel-identical.
    var chargingState: VehicleChargingState = .idle
    // MYR-369 — `rideShareEnabled` / `onSetRideShareEnabled` are GONE from this
    // view. The owner's ride-share switch moved to the top of the Share tab,
    // where its consequences live; see `InvitesScreen.vehicleRideShareCard`. It
    // is the same field and the same §7.18 endpoint — only the surface moved.

    private var controls: VehicleControlsSnapshot { executor.controls }

    private var rangeMi: Int { Int(((batteryPercent / 100) * 272).rounded()) } // vehicle-controls.jsx:228

    /// MYR-316 — the expected-back row's model, or `nil` when there is no service
    /// visit to talk about. Two independent conditions, both required: the car is
    /// IN SERVICE (the badge state, off the wire) and the host supplied an edit
    /// route. The simulated path satisfies neither, so M1 / drift-gate scenes are
    /// untouched.
    private var serviceWindowRow: ServiceWindowRowModel? {
        guard badgeStatus == .inService, let onEditServiceWindow else { return nil }
        return ServiceWindowRowModel(
            value: serviceEstimatedEndAt,
            // The row shows the SAME formatted label the summary hero shows, from
            // the same resolver, so the two can never disagree about the time.
            label: VehicleServiceWindow.completionLabel(for: serviceEstimatedEndAt),
            state: executor.uiState(for: .serviceWindow),
            // MYR-320 — provenance the executor PROVED from a write echo, or
            // `.unknown` (no caption) when nothing has been proved. Never guessed
            // here: the view has strictly less information than the executor does.
            source: controls.serviceWindowSource,
            onEdit: onEditServiceWindow
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MRTDivider(pad: 6) // vehicle-controls.jsx:241 `<Divider pad={6}/>`

            quickTiles

            // MYR-301 — the FULL text of any quick-tile notice, on a surface wide
            // enough to hold it, with the fix attached. Nothing renders when every
            // tile is idle (always, on the simulated path), so M1 / drift-gate
            // scenes are pixel-identical.
            tileNoticeRows

            ClimateSection(
                controls: controls,
                seatClimate: vehicle.seatClimate,
                executor: executor,
                cabinTemp: cabinTemp,
                extTemp: extTemp,
                // MYR-280 — the seat honest-unknown (Syncing vs Unavailable) reuses
                // the quick-tile freshness signal; `nil` on the simulated path.
                isStreaming: isStreaming,
                onRelinkTesla: onRelinkTesla
            )

            MediaSection(
                controls: controls,
                executor: executor,
                // MYR-264 — no fixture track on the live path (media metadata isn't
                // contracted → honest-hidden); SIM passes the fixture unchanged.
                track: isLive ? nil : VehicleMediaTrack.all[controls.trackIndex],
                // MYR-303 — the live now-playing block. Non-nil ONLY when a real
                // `VehicleState` carried media fields, so it can never displace
                // the SIM fixture above.
                nowPlaying: nowPlaying,
                onRelinkTesla: onRelinkTesla
            )

            // vehicle-controls.jsx:385 `{!driving && …}` — while driving, live
            // speed/heading/range already live at the top of the sheet.
            if !driving, let parkedLocation {
                StatusLocationSection(
                    location: parkedLocation,
                    rangeMi: rangeMi,
                    status: badgeStatus,
                    // MYR-316 — the row exists ONLY for a car actually in service.
                    // Everything inside it (including a nil time) is then honest;
                    // outside that state it would be a row about nothing.
                    serviceWindow: serviceWindowRow,
                )
            }

            TirePressureSection(pressures: vehicle.tirePressures)

            LifetimeSection(odometerMiles: odometerMiles, fsdMilesSinceReset: fsdMilesSinceReset)

            VehicleDetailsSection(
                vehicle: vehicle,
                plate: controls.plate,
                onEditPlate: { isEditingPlate = true },
                // MYR-286 — the §7.14 write's pending/notice state. `.idle` on the
                // simulated path, so M1 / drift-gate scenes are pixel-identical.
                plateState: executor.uiState(for: .plate)
            )

            // Honest freshness footer (MYR-260): "· Live" only when the car is
            // actually streaming — an offline/in-service car with stale tiles above
            // must NOT claim "Updated just now · Live".
            Text(footerText)
                .font(.system(size: 10))
                .tracking(0.3)
                .foregroundStyle(Color.mrtTextMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }

    // MARK: Quick tiles (vehicle-controls.jsx:244-254)
    //
    // MYR-251 — each tile's STATE (locked/on/open) is only asserted when the
    // executor confirms it (`isKnown`); on the live path it is unknown until the
    // owner commands the tile, so it renders a neutral icon + "—" instead of a
    // fixture value (MYR-228). When unknown the tap performs the SAFE default
    // (lock / start climate / open) rather than toggling an unknown seed.

    // MYR-260 — the quick tiles' honest-unknown sub now resolves through
    // `VehicleControlFreshness`: "— Syncing" only while connecting or while a
    // streaming car is still delivering the value, an honest "— Unavailable"
    // once a reachable NON-streaming snapshot proves the value is not coming, and
    // (for the safety-relevant Trunk/Lock) a bounded "X ago" qualifier on a
    // known-but-stale value. Auto-fills the moment MYR-252's contracted control
    // states arrive (the executor flips isKnown).

    /// A live `VehicleState` has arrived — tells the connecting state from a
    /// reachable-but-unknown one (MYR-260). Keyed off `isStreaming`, which the
    /// live mapper sets whenever a state exists, NOT off `lastUpdated`: an empty
    /// or non-standard server timestamp parses to nil, and keying on that would
    /// wrongly fall back to "Syncing" on the exact offline path this fixes. `nil`
    /// on the simulated path (all fields known, so this is never consulted).
    private var hasSnapshot: Bool { isStreaming != nil }

    /// The honest freshness footer. The simulated path (no `isStreaming` signal)
    /// keeps the original "Updated just now · Live" copy so M1 stays pixel-identical;
    /// a streaming car is genuinely live; a non-streaming car never claims "Live"
    /// and reports how long ago it was last heard from (MYR-260).
    private var footerText: String {
        guard let isStreaming else { return "Updated just now · Live" }
        if isStreaming { return "Updated just now · Live" }
        // Not streaming: never claim "Live". Report last contact when we have it.
        if let lastUpdated {
            return "Last contact \(VehicleControlFreshness.agoLabel(since: lastUpdated, now: Date())) · Not live"
        }
        return "Not live"
    }

    private var quickTiles: some View {
        // `.top` alignment + each tile filling the row height (maxHeight:.infinity
        // on the tile) makes all four EQUAL height regardless of sub-line length —
        // otherwise a scaled-down longer sub ("Closed · just now") yields a shorter
        // line than a full-size short one ("Off"), mismatching tile heights (client,
        // MYR-260 read-back surfaced real subs of varying length).
        HStack(alignment: .top, spacing: 8) {
            lockTile
            climateTile
            trunkTile
            chargeTile
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The quick tiles that can carry a notice, in the order they are laid out —
    /// so a notice row appears under the row in the same left-to-right order.
    private static let tileKeys: [VehicleControlKey] = [.lock, .climate, .trunk, .chargePort]

    /// MYR-301 — one full-text notice row per failing tile. Empty (no view, no
    /// spacing) whenever every tile is idle, which is ALWAYS on the simulated
    /// path: `SimulatedVehicleCommandExecutor` returns `.idle` for every key.
    @ViewBuilder
    private var tileNoticeRows: some View {
        ForEach(Self.tileKeys, id: \.self) { key in
            if let notice = executor.uiState(for: key).notice {
                VehicleCommandNoticeRow(key: key, notice: notice, onAction: onRelinkTesla)
            }
        }
    }

    private var lockTile: some View {
        let known = executor.isKnown(.locked)
        // MYR-335 — the sub is the ACTION the tap performs. The prototype spells
        // it "Tap to unlock" (vehicle-controls.jsx:245), which does not fit its
        // OWN tile: measured in the running prototype at 402pt it ellipsizes to
        // "Tap to u…" (scrollWidth 65 vs clientWidth 56), and on iOS SF Pro it is
        // 71.9pt against 49.75pt on the narrowest supported device — the client's
        // "Tap to unl…". The verb alone says the same thing (the tile IS a button;
        // "Tap to" was never carrying meaning) and the STATE is already the label
        // right above it. Unknown → the tile-form Syncing / No data (MYR-260 copy,
        // MYR-335 widths).
        let sub: String
        if known {
            sub = controls.locked ? "Unlock" : "Lock"
        } else {
            sub = VehicleControlFreshness.tileUnknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming)
        }
        return ControlTile(
            icon: known ? (controls.locked ? "lock.fill" : "lock.open.fill") : "lock",
            label: known ? (controls.locked ? "Locked" : "Unlocked") : "Lock",
            sub: sub,
            active: known && !controls.locked,
            activeColor: .mrtDriving,
            uiState: executor.uiState(for: .lock),
            // The screen reader has no width limit, so it keeps the full sentence.
            spokenLabel: known
                ? (controls.locked ? "Locked, tap to unlock" : "Unlocked, tap to lock")
                : nil
        ) {
            // Unknown → lock (the safe default); known → toggle.
            let target = known ? !controls.locked : true
            Task { try? await executor.setLocked(target) }
        }
    }

    private var climateTile: some View {
        let known = executor.isKnown(.climateOn)
        let tempKnown = executor.isKnown(.targetTemp)
        let onSub = tempKnown ? "On · \(controls.targetTemp)°" : "On"
        return ControlTile(
            icon: "fan",
            label: "Climate",
            sub: known ? (controls.climateOn ? onSub : "Off")
                : VehicleControlFreshness.tileUnknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming),
            active: known && controls.climateOn,
            activeColor: .mrtGold,
            uiState: executor.uiState(for: .climate)
        ) {
            let target = known ? !controls.climateOn : true
            Task { try? await executor.setClimateOn(target) }
        }
    }

    private var trunkTile: some View {
        let known = executor.isKnown(.trunkOpen)
        // Trunk's label is generic, so the STATE (safety-critical) lives in the
        // sub — and, as of MYR-335, ONLY the state. MYR-260 appended "· 13m ago"
        // when the read was stale; at 4-column width that sub measures 92pt
        // against 49.75pt and ellipsized to "Closed · 1…", which loses the recency
        // it was added for AND puts the state one character from being cut. The
        // recency is now stated once by the sheet's freshness stamp (MYR-315) —
        // see `VehicleControlFreshness`'s header.
        let sub: String
        if known {
            sub = controls.trunkOpen ? "Open" : "Closed"
        } else {
            sub = VehicleControlFreshness.tileUnknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming)
        }
        return ControlTile(
            icon: "car.fill",
            label: "Trunk",
            sub: sub,
            active: known && controls.trunkOpen,
            activeColor: .mrtParked,
            uiState: executor.uiState(for: .trunk)
        ) {
            let target = known ? !controls.trunkOpen : true
            Task { try? await executor.setTrunkOpen(target) }
        }
    }

    // Charge port joined the §7.9 catalog in v186 (charge_port_door_open /
    // close, MYR-249) — the tile toggles the port per its state and shows the
    // pending/notice UX (a token lacking the charging scope surfaces the
    // charging-specific re-link line). Its OPEN/CLOSED state is not on the wire,
    // so it too renders unknown until commanded (MYR-251).
    private var chargeTile: some View {
        let known = executor.isKnown(.chargePortOpen)
        // MYR-333 — a live charge SESSION outranks the port-door position in
        // this one line. "Port open" is a fact about a door; "Charging" is the
        // fact the owner came to the sheet for, and the client's screenshot is
        // the proof: it read "Port open" throughout a charging session and told
        // him nothing about it. The port state is still exactly what the tile
        // TOGGLES and what its `active` highlight tracks — only the sub-caption
        // yields, and only while there is a session to report.
        //
        // Both strings are deliberately one word (MYR-335 tile truncation): the
        // hero carries the full "Charge complete", the tile carries the state.
        // MYR-335 measured them: "Complete" is 51.7pt against 49.75pt of tile on
        // the narrowest supported device — it fit the 393 canvas and nothing
        // narrower — so the completed state is named as a STATE ("Charged",
        // 45.9pt) rather than as an event. Same fact, and it reads as the answer
        // to "what is my car doing" like "Charging" beside it does.
        let sessionSub: String? = {
            switch chargingState {
            case .charging: return "Charging"
            case .complete: return "Charged"
            case .idle: return nil
            }
        }()
        return ControlTile(
            icon: "bolt.fill",
            label: "Charge",
            // MYR-335 — the port-door fallback loses the word "Port": it was
            // 61.1pt against 49.75pt of tile on the narrowest supported device
            // (and 54.25 on the design's own 393 canvas), so it survived only on
            // a Pro Max. "Port" is the label's job — the tile says "Charge"
            // under a bolt — so the sub carries the door state alone, exactly as
            // the Trunk tile's does. MYR-333's session strings, already written
            // one word for this reason, keep their precedence unchanged.
            sub: sessionSub
                ?? (known ? (controls.chargePortOpen ? "Open" : "Closed")
                    : VehicleControlFreshness.tileUnknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming)),
            active: known && controls.chargePortOpen,
            activeColor: .mrtCharging,
            uiState: executor.uiState(for: .chargePort),
            // The screen reader has no width limit, so it keeps the full
            // sentence — including the session, which is what the owner came for.
            spokenLabel: sessionSub.map { "Charge, \($0.lowercased())" }
                ?? (known ? "Charge, charge port \(controls.chargePortOpen ? "open" : "closed")" : nil)
        ) {
            let target = known ? !controls.chargePortOpen : true
            Task { try? await executor.setChargePortOpen(target) }
        }
    }
}

// MARK: - ControlTile (vehicle-controls.jsx:24-41)

private struct ControlTile: View {
    let icon: String
    let label: String
    let sub: String
    let active: Bool
    let activeColor: Color
    /// Live command state (MYR-249). `.idle` on the simulated path, so the M1 /
    /// drift-gate rendering is pixel-identical.
    var uiState: VehicleControlUIState = .idle
    /// MYR-335 — what VoiceOver reads instead of the two visible strings, when
    /// the visible copy had to be compressed to fit the 4-column tile. Nothing
    /// on screen is a lie without it, but "Locked, Unlock" is a worse sentence
    /// than "Locked, tap to unlock", and the screen reader has no width limit.
    /// `nil` → the composed label + sub, exactly as before.
    var spokenLabel: String? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `${activeColor}1f` — 0x1F / 255 alpha tint (vehicle-controls.jsx:30).
    private var activeFill: Color { activeColor.opacity(Double(0x1F) / 255) }
    /// `${activeColor}66` — 0x66 / 255 alpha border (vehicle-controls.jsx:29).
    private var activeBorder: Color { activeColor.opacity(Double(0x66) / 255) }

    /// The sub line: a settled notice (pairing / re-link / waking / …) takes
    /// precedence over the resting copy so an error is surfaced honestly in place.
    /// MYR-301 — the tile shows the notice's SHORT `tileText`, which fits the
    /// tile's ~54pt of inner width at the uniform 11pt sub size (MYR-281); the
    /// full sentence is carried by `VehicleCommandNoticeRow` below the tiles, so
    /// shortening hides nothing. Before this, the 35-character
    /// "Reconnect Tesla for charging access" tail-truncated to "Reconnec…".
    private var subLine: String { uiState.notice?.tileText ?? sub }
    private var subColor: Color { uiState.notice != nil ? .mrtTextSec : (active ? activeColor : .mrtTextMuted) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Pending → a spinner in the icon slot (Reduce Motion falls back
                // to the static icon dimmed, no spin, per CLAUDE.md). The idle
                // path renders the bare `Image` exactly as before, so the M1 /
                // drift-gate scenes are pixel-identical.
                if uiState.isPending, !reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                        .tint(active ? activeColor : .mrtTextSec)
                        .frame(width: 20, height: 20, alignment: .leading)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(active ? activeColor : .mrtTextSec)
                        .opacity(uiState.isPending ? 0.5 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // jsx sets `whiteSpace:nowrap / overflow:hidden /
                        // textOverflow:ellipsis` (vehicle-controls.jsx:36-37)
                        // — ellipsis is the designed fallback, but native SF
                        // Pro renders a few of these strings slightly wider
                        // than the browser's font substitution at the same
                        // nominal size, so scale down slightly before
                        // truncating rather than clipping mid-word.
                        //
                        // MYR-335 — 0.85 was one hair too high for the widest
                        // label on the narrowest supported device: "Unlocked" is
                        // 59.3pt at 13pt semibold, and 59.3 × 0.85 = 50.4pt
                        // against 49.75pt of tile, so it ellipsized on a 375pt
                        // screen. 0.8 clears it. Nothing changes at 393/402,
                        // where the label fits by scaling to ~0.92 and never
                        // reaches the floor — the drift-gate captures are
                        // untouched by this line.
                        .minimumScaleFactor(0.8)
                    Text(subLine)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(subColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // MYR-281 — NO per-tile scaling. `minimumScaleFactor` let
                        // each sub pick its own point size (a long sub shrank while
                        // a short one stayed full), so adjacent tiles rendered the
                        // sub at visibly different sizes ("looks cheap", client).
                        // Every sub now renders at the one 11pt size (matching the
                        // prototype, which is uniform 11px + ellipsis) and
                        // tail-truncates on overflow like the prototype.
                        //
                        // MYR-335 makes that fallback unreachable instead of
                        // relied upon: every sub this tile can render is now
                        // measured against the 4-column width on the narrowest
                        // supported device (`VehicleControlTileCaptionTests`), so
                        // nothing ellipsizes and the one uniform size holds.
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 13)
            .padding(.top, 13)
            .padding(.bottom, 12)
            .background(
                active ? activeFill : Color.mrtControlTileFill,
                in: RoundedRectangle(cornerRadius: MRTMetrics.vehicleControlTileRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.vehicleControlTileRadius, style: .continuous)
                    .strokeBorder(active ? activeBorder : Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel ?? "\(label), \(subLine)")
    }
}

// MARK: - SectionCard (vehicle-controls.jsx:43-54)

struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        self.title = title
        trailing = EmptyView()
        self.content = content()
    }

    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).mrtTextStyle(.label()).foregroundStyle(Color.mrtTextMuted)
                Spacer()
                trailing
            }
            .padding(.bottom, 10)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .mrtSurface(.card, fill: .mrtElevated, radius: MRTMetrics.vehicleControlsSectionRadius)
        }
        .padding(.top, MRTMetrics.vehicleControlsSectionGap)
    }
}
