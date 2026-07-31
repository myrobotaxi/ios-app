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
        //   • `SharePermission` — `live | live_history | rides`, STRICTLY CUMULATIVE
        //     (live < live_history < rides). Consumers MUST compare with `>=` over
        //     that order, never equality — see `SharePermission.grants(_:)` below.
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
        .package(url: "https://github.com/myrobotaxi/contracts.git", from: "0.22.0")
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
