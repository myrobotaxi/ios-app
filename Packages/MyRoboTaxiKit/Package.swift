// swift-tools-version: 6.0
//
// MyRoboTaxiKit — thin, iOS-only REST + telemetry-WebSocket client for the
// MyRoboTaxi app (MYR-21, milestone M2).
//
// The Kit owns ZERO wire shapes of its own: every payload it decodes or
// encodes is a generated type from `MyRobotaxiContracts` (the Swift surface of
// the myrobotaxi/contracts package, resolved by git URL + semver tag). It adds
// only transport + state-machine behavior (auth handshake, per-vehicle
// demultiplexing, jittered-backoff reconnect, snapshot-resume, an @Observable
// view-facing bridge). No third-party dependencies.
//
// Built in the Swift 6 language mode so strict-concurrency checking is
// "complete" — the whole networking surface is data-race-free under actor
// isolation. The consuming app target may still build in Swift 5 mode; SPM
// composes per-target language modes.
import PackageDescription

let package = Package(
    name: "MyRoboTaxiKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "MyRoboTaxiKit", targets: ["MyRoboTaxiKit"])
    ],
    dependencies: [
        // MYR-320 — 0.18.0 adds two nullable DETAIL-SHEET strings to `VehicleState`
        // ONLY (deliberately not to the lean `VehicleSummary` list row):
        //   • `trimLabel` — the DISPLAY-READY trim designation ("Performance"),
        //     read from Tesla REST `vehicle_config.performance_package`. It is the
        //     only one of the trim pair a consumer may render; the sibling `trim`
        //     stays the raw badge CODE ("p74d") for classification.
        //   • `fsdVersion` — the FSD software designation as Tesla names it
        //     ("FSD (Supervised) v14.3.5"), from the newest release-notes title.
        //     Free-form: rendered verbatim, never parsed or compared.
        // Both are REST-derived and SNAPSHOT-ONLY (a `vehicle_update` frame never
        // carries either), so both are classified in the merger tripwire's
        // `snapshotOnlyFields` rather than folded — see `VehicleStateMerger`.
        // (0.17.0 added `serviceEstimatedEndAt`; 0.16.0 the eight media
        // now-playing fields + `seatCoolingCapable`.)
        // MYR-184 — 0.19.0 adds the whole VEHICLE-SHARING family (rest-api.md §7.5):
        //   • `SharePermission` — `live | live_history | rides`. This was a STRICTLY
        //     CUMULATIVE total order (live < live_history < rides) compared with
        //     `>=`. **MYR-369 RETIRED THAT** — see the 0.23.0 note below. The enum
        //     is now a derived projection of per-grant flags, compared by EQUALITY.
        //   • `ShareInvite` / `ShareInviteListResponse` — the OWNER-facing grant row
        //     in its two wire lives (`pending`, carrying the redeemable `code` +
        //     `expiresAt`; `accepted`, carrying `acceptedAt`). Never delivered to an
        //     invited party. The list envelope key is `invites`, NOT `items`.
        //   • `CreateShareInviteRequest` — `{ label, permission, vehicleIds? }`.
        //   • `RedeemShareInviteRequest` / `RedeemShareInviteResponse` — the RIDER's
        //     `{ code }` → `{ ownerFirstName, vehicles }` join, the only sharing
        //     payload an invited party ever sees.
        // It also appends `VehicleSummary.sharePermission` (OPTIONAL, emitted iff
        // `role` is `viewer`); an ABSENT value on a viewer row means the LOWEST tier,
        // never full access — never fail open.
        // (0.18.0 added `VehicleState.trimLabel` + `fsdVersion`; 0.17.0
        // `serviceEstimatedEndAt`; 0.16.0 the media now-playing fields.)
        // MYR-342 — 0.20.0 adds ONE boolean to BOTH read shapes:
        // `VehicleSummary.rideShareEnabled` and `VehicleState.rideShareEnabled`,
        // the owner's ride-share PAUSE switch. It is OPTIONAL on the wire and
        // **ABSENT MEANS ENABLED** — an older server, or any row a build predates,
        // must read as "riders can request this car", never as paused. Every
        // consumer therefore tests `== false` explicitly; `nil`/absent is never
        // paused. Unlike `serviceEstimatedEndAt` this one is an ORDINARY FOLDED
        // field: the server pushes it on `vehicle_update` when the owner flips it,
        // so `VehicleStateMerger` folds it with the standard null-clear semantics.
        // MYR-368 — 0.22.0 adds ONE optional string to `ShareInvite`: `shareUrl`,
        // the COMPLETE server-minted join link the owner hands out
        // (`/join/{CODE}?k={kid}.{exp}.{sig}&from={Owner}&to={Recipient}`). Three
        // things about it shape every consumer in this client:
        //   • It is PRESENT EXACTLY WHERE `code` IS — pending rows only — and it
        //     CONTAINS the code, so it inherits the code's whole handling rule:
        //     P1, a live bearer credential, never logged, never on a non-owner
        //     surface.
        //   • `k` is an Ed25519 signature over `join:{code}:{exp}:{from}:{to}`,
        //     verified STATICALLY by the web join shell against a compiled-in
        //     public key. BOTH display names are inside the signature, so the URL
        //     is not ours to rewrite: a client that re-composed the link from
        //     `code` + its own `?from=` would strip the signature and be bounced
        //     at the shell. The value is shared VERBATIM or not at all.
        //   • It is OPTIONAL for forward-compat, and the contract's own words are
        //     that a consumer finding `code` without `shareUrl` MUST fall back —
        //     which for this app is MYR-359's client-composed unsigned link. Absent
        //     therefore decodes to `nil` and is a supported state, not a defect.
        // MYR-369 — 0.23.0 REPLACES THE TIER WITH TWO PER-GRANT FLAGS, and this is
        // a semantic change to a value that already shipped, not an addition.
        //   • `ShareInvite.allowRides` + `ShareInvite.suspended` — OWNER-ONLY and
        //     ACCEPTED-ROWS-ONLY (both keys are OMITTED while `status` is `pending`,
        //     where there is no grant yet). Both are OPTIONAL for compat, with two
        //     DIFFERENT absence rules that must not be swapped: an absent
        //     `allowRides` on an accepted row falls back to `permission == .rides`,
        //     and an absent `suspended` reads as NOT suspended. Absence is never
        //     suspension. `SharePermission.allowsRides` / `ShareInvite.allowsRides`
        //     / `ShareInvite.isSuspended` are the ONLY places either is read.
        //   • `PatchShareInviteRequest` — `{ allowRides?, suspended? }` for
        //     `PATCH /api/invites/{inviteId}`. PARTIAL BY DESIGN: only the
        //     properties PRESENT are written, an absent property is NOT `false`,
        //     and an empty body is a 400 (`minProperties: 1`). ACCEPTED GRANTS
        //     ONLY — a pending invite answers 409.
        //   • `SharePermission` IS NO LONGER A TOTAL ORDER. On an accepted row it
        //     is DERIVED on every read (`allowRides` true → `rides`, else `live`),
        //     so the pre-MYR-369 `>=` comparison is WRONG and `rank`/`grants(_:)`
        //     are DELETED rather than deprecated — a cumulative comparator left in
        //     place is a foot-gun that still compiles. `live_history` IS RETIRED
        //     AND NEVER EMITTED; the enum member stays for wire compat so an
        //     installed decoder keeps working, and nothing may offer it.
        //   • SUSPENSION GATES EVERYTHING and is enforced by REMOVING the grant
        //     from the viewer's access set — so a suspended car is ABSENT from the
        //     viewer's `GET /api/vehicles` rather than present-and-marked. There is
        //     no "suspended" marker on the viewer side by construction. One caveat
        //     the contract records rather than closes: an ALREADY-OPEN WebSocket
        //     keeps streaming until it reconnects (websocket-protocol.md §10 DV-09,
        //     server-side fix tracked as MYR-373), so the client must tolerate the
        //     car simply being gone on the next list read.
        //
        // MYR-172 — 0.24.0 adds the Live Activity family (schemas/live-activity.
        // schema.json, rest-api.md §7.21): `RegisterLiveActivityRequest`,
        // `LiveActivityRegistrationResponse`, `EndLiveActivityResponse`,
        // `LiveActivityEvent`, `LiveActivityRideStatus` and — the one that is NOT
        // a REST body — `LiveActivityContentState`, the exact `aps.content-state`
        // an ActivityKit remote update carries.
        //
        //   • `LiveActivityContentState` NEVER APPEARS ON AN ENDPOINT. It reaches
        //     the device only over APNs, so no `RestClient` method returns it and
        //     no fixture exercises it through the HTTP pipeline. It is imported
        //     here for ONE purpose: to be the authority the app's own
        //     `RideActivityAttributes.ContentState` is pinned against
        //     (`RideActivityContentStateTests`). ActivityKit will not let the
        //     generated type BE the ContentState — that protocol requires
        //     `Hashable` and the generated type is only `Codable, Equatable,
        //     Sendable` — so the app declares a mirror, and a mirror is exactly
        //     the MYR-362 shape: two hand-kept-in-sync types that can drift while
        //     every decode test passes. The pin is what closes that.
        //   • `LiveActivityRideStatus` IS used directly (it is `Hashable`), so the
        //     app's ContentState carries the generated enum rather than a second
        //     copy — which also inherits its `unrecognized(String)` arm, and the
        //     schema REQUIRES a client to tolerate an unknown member rather than
        //     fail the decode. `reservation_expired` is the member with no
        //     `RideRequestStatus` twin: the reservation sweeper leaves the ride row
        //     at `accepted`, so without it a rider's lock screen would sit on "your
        //     car is on its way" forever.
        //   • `eta` is ABSOLUTE UNIX SECONDS and is OMITTED ENTIRELY when unknown —
        //     never null, never zero, never a guess. It is optional on the wire, so
        //     a MIS-KEYED mirror decodes it to `nil` silently and the lock screen
        //     simply shows no countdown, with no throw anywhere. That is MYR-362's
        //     defect in a new place, which is why the guard is a RAW-KEY assertion
        //     rather than a round-trip.
        //
        // MYR-385 — 0.26.0 adds the SCHEDULE-PICKER CONFLICT READ (schemas/
        // booked-windows.schema.json, rest-api.md §7.22): `VehicleBookedWindowsResponse`
        // and `BookedWindow`, the read side of the MYR-383 create-time booking gate.
        // Four properties of the shape decide how every consumer must treat it:
        //   • CONCRETE INSTANTS, NOT AN ANCHOR PLUS A RADIUS. The ±45min half-width is
        //     a PRODUCT GUESS living in exactly one place on the server, passed to SQL
        //     as a bind parameter and encoded in no schema, no enum and no client. The
        //     server resolves it and emits `start`/`end`, so widening it later changes
        //     every picker on the NEXT RESPONSE with no client release. Consumers MUST
        //     NOT re-derive, re-centre, pad, round, or infer the half-width from a
        //     window — a client that hard-codes 45 minutes is a client that silently
        //     disagrees with the gate the day the number moves.
        //   • THE INTERVAL IS OPEN AT BOTH ENDS. The gate compares strictly inside, so
        //     a reservation for exactly `start` or exactly `end` is ACCEPTED (two rides
        //     touching at a boundary are a legal back-to-back booking). A picker dims
        //     `start < slot < end` and nothing else; dimming the endpoints refuses a
        //     slot the server would have taken.
        //   • A SNAPSHOT, NOT A SUBSCRIPTION. Windows appear and vanish underneath the
        //     response, and the ACTIVE-INSTANT arm anchors on the server's clock so it
        //     SLIDES forward while the response does not. The create-time `409
        //     time_conflict` therefore remains the authority; this read reduces how
        //     often a rider meets it and does not replace it.
        //   • `items: []` MEANS "NO RESERVATIONS", NOT "WIDE OPEN". §7.22 deliberately
        //     does NOT consult the §7.18 pause or the §7.16 service window — both
        //     refuse a create, neither describes a window — so a paused or in-service
        //     car answers with its real (often empty) window list and the picker's
        //     existing gates stay responsible for those.
        // `pending` (a still-undecided `requested` claim) changes only the WORDS, never
        // the availability — the create path counts pending claims in full. `own`
        // tracks the RIDER, so an owner sees `own: false` for rides other people booked
        // in their car. (0.24.0 added the Live Activity family; 0.23.0 the per-grant
        // share flags; 0.22.0 `ShareInvite.shareUrl`.)
        //
        // MYR-398 — 0.27.0 adds `LiveActivityContentState.progress`, a 0..1 fraction
        // of the CURRENT leg and the only new key the r16 card redesign needed. The
        // Kit itself does not read it (the content state never travels a REST
        // surface — it arrives as `aps.content-state` over APNs), but the pin is the
        // AUTHORITY the app's hand-kept `RideActivityAttributes.ContentState` mirror
        // is cross-pinned against, and all three targets resolve one version.
        // `v` stays `1`: an additive optional key is not a meaning change, so an
        // installed pre-r16 build decodes the new payload exactly as it always did.
        //
        // MYR-398 v3 — 0.28.0 adds ONE more optional key to the same shape:
        // `LiveActivityContentState.asOf`, an ABSOLUTE unix-SECONDS instant naming
        // when the server last LEARNED something about this ride. It is the source
        // for the v3 board's stale subline, `Last updated 3:31 PM`.
        //
        // It is the mirror image of `eta` and that is the whole reason it had to be
        // its own key rather than being derived: `eta` is a FUTURE instant chosen
        // BEFORE the update that carried it, so dating a freshness notice from it
        // OVERSTATES freshness on the one card whose entire job is to admit it has
        // none (v1 shipped exactly that, rendering "in 4 minutes ago"). Nothing else
        // the widget process holds is an update instant — `ActivityViewContext`
        // exposes no `staleDate`, checked against the SDK interface on iOS 26.5.
        //
        // **ABSENT MEANS "THIS SERVER DOES NOT SAY"**, never "just now": an older
        // server omits the key entirely and the card falls back to the wordless
        // "Waiting for an update" rather than inventing an instant. Same tolerant
        // decode as `rideShareEnabled` and `hasActiveRide`, for the same reason.
        // `v` stays `1` again, on the same additive-optional reasoning.
        //
        // MYR-440 — 0.29.0 moves `VehicleState.interiorTemp` and `.exteriorTemp`
        // OUT of the schema's `required` list, so both generate as `Int?` instead
        // of `Int`. This is the one contracts bump so far that fixes a LIVE
        // client bug rather than adding a field.
        //
        // Telemetry MYR-435 narrows the shared-viewer mask: a viewer stops
        // receiving media, cabin state, and all vehicle-controls state — 34
        // fields. Thirty-two were already optional here. These two were the only
        // withheld fields still `required`, so on 0.28.0 a viewer's GET /snapshot
        // threw `keyNotFound` on the first missing temp and the WHOLE document
        // was discarded. `TelemetrySocket.attemptSnapshot` catches a
        // `DecodingError` in the same generic arm it uses for a network blip, so
        // it retried silently forever and the viewer's map sat on "Locating…"
        // with nothing naming a contract mismatch.
        //
        // The floor moves to 0.29.0 rather than riding `from: "0.28.0"`'s
        // automatic resolution because correctness now DEPENDS on the optional
        // shape — a resolve that landed on 0.28.0 would compile and then fail in
        // the field. WS frames were never affected (sparse by contract), and the
        // owner path is byte-identical: the owner always receives both temps.
        .package(url: "https://github.com/myrobotaxi/contracts.git", from: "0.29.0")
    ],
    targets: [
        .target(
            name: "MyRoboTaxiKit",
            dependencies: [
                .product(name: "MyRobotaxiContracts", package: "contracts")
            ]
        ),
        .testTarget(
            name: "MyRoboTaxiKitTests",
            dependencies: ["MyRoboTaxiKit"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
