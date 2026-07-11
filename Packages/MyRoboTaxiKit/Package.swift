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
        .package(url: "https://github.com/myrobotaxi/contracts.git", from: "0.11.0")
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
