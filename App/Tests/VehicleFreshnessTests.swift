@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-315 — the freshness stamp's pure decision layer
//
// The stamp makes a CLAIM about how current the owner sheet is, so every branch
// of that claim is asserted here rather than inferred from a screenshot. The
// matrix is the four real conditions a snapshot can be in — streaming, freshly
// read, stale, never read — plus the simulated path, which has no honest claim to
// make at all.
final class VehicleFreshnessStampTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Recency matrix

    // A streaming car is current by definition — the read time is refreshed every
    // frame, so an "X ago" beside "Live" would be noise, not information.
    func testStreamingCarReadsLive() {
        let recency = VehicleFreshnessStamp.recency(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-2), now: now)
        XCTAssertEqual(recency, .streaming)
        XCTAssertEqual(recency?.label, "Live")
    }

    // Not streaming but read seconds ago: the sub-60s bucket reads "just now", the
    // same bounded vocabulary the MYR-260 tile qualifiers use.
    func testFreshNonStreamingCarReportsJustNow() {
        let recency = VehicleFreshnessStamp.recency(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-12), now: now)
        XCTAssertEqual(recency, .synced("just now"))
        XCTAssertEqual(recency?.label, "Synced just now")
    }

    // The case this issue exists for: a car asleep for hours presenting its old
    // battery/location. The stamp says exactly how old, in the coarse buckets the
    // shared `VehicleControlFreshness.agoLabel` defines.
    func testStaleCarReportsHowLongAgoInBoundedBuckets() {
        let cases: [(ago: TimeInterval, label: String)] = [
            (3 * 60, "Synced 3m ago"),
            (7 * 3600, "Synced 7h ago"),
            (3 * 86_400, "Synced 3d ago"),
        ]
        for c in cases {
            let recency = VehicleFreshnessStamp.recency(
                isStreaming: false, lastUpdated: now.addingTimeInterval(-c.ago), now: now)
            XCTAssertEqual(recency?.label, c.label, "for \(c.ago)s ago")
        }
    }

    // Never read: say so. The alternative ("Synced —", or hiding the stamp) either
    // implies a sync that never happened or leaves the owner with no signal at all
    // on the one surface where the data is most suspect.
    func testNeverReadCarSaysSoRatherThanImplyingASync() {
        let recency = VehicleFreshnessStamp.recency(isStreaming: false, lastUpdated: nil, now: now)
        XCTAssertEqual(recency, .never)
        XCTAssertEqual(recency?.label, "Not synced yet")
    }

    // The SIMULATED path carries no freshness signals (MYR-260 leaves both nil),
    // so there is no honest claim to make — the resolver returns nil and the stamp
    // renders nothing. This is the second of the two gates that keep the drift-gate
    // scenes byte-identical (the first is `HomeScreen`'s `isLive` check).
    func testSimulatedSnapshotYieldsNoClaimAtAll() {
        XCTAssertNil(VehicleFreshnessStamp.recency(isStreaming: nil, lastUpdated: nil, now: now))
        XCTAssertNil(VehicleFreshnessStamp.recency(
            isStreaming: nil, lastUpdated: now.addingTimeInterval(-9999), now: now))
    }

    // MARK: Wake decision

    // Tapping must not spend a wake when there is nothing to gain. A streaming car
    // is already current, and a car read within the shared staleness threshold
    // would only draw the server's own `fresh` no-op — or, inside the endpoint's
    // ~60s cooldown, a 429 the owner would read as a failure.
    func testTapDoesNotWakeAStreamingOrRecentlyReadCar() {
        XCTAssertFalse(VehicleFreshnessStamp.wakes(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-9 * 3600), now: now),
            "streaming is current regardless of how old the last REST read looks")
        XCTAssertFalse(VehicleFreshnessStamp.wakes(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(VehicleFreshnessStamp.wakes(
            isStreaming: nil, lastUpdated: nil, now: now),
            "the simulated path has no server to ask")
    }

    // Past the threshold — and for a car never read at all, which is precisely the
    // state a wake exists to resolve — the tap does spend the call.
    func testTapWakesAStaleOrNeverReadCar() {
        XCTAssertTrue(VehicleFreshnessStamp.wakes(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-7 * 3600), now: now))
        XCTAssertTrue(VehicleFreshnessStamp.wakes(isStreaming: false, lastUpdated: nil, now: now))
    }

    // The stamp and the MYR-260 tile qualifiers must never disagree about what
    // "stale" means, so the boundary is the SHARED threshold, not a second copy.
    func testStalenessBoundaryIsTheSharedThreshold() {
        let threshold = VehicleControlFreshness.staleThreshold
        XCTAssertFalse(VehicleFreshnessStamp.wakes(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-(threshold - 1)), now: now))
        XCTAssertTrue(VehicleFreshnessStamp.wakes(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-threshold), now: now))
    }
}

// MARK: - Refresh phase + notice copy

final class VehicleRefreshNoticeTests: XCTestCase {

    // The in-progress line NAMES the car: an owner with several vehicles needs to
    // know which one is being woken, and a wake takes long enough that a silent
    // stamp reads as a dead tap.
    func testWakingPhaseNamesTheVehicle() {
        XCTAssertEqual(VehicleRefreshPhase.waking("Lunar").text, "Waking Lunar\u{2026}")
    }

    // Idle and the no-op acknowledgement contribute NO copy — the resting recency
    // stamp shows through, which is exactly the acknowledgement: the owner asked
    // how current it was and the answer re-rendered.
    func testIdleAndAcknowledgedPhasesShowTheRestingStamp() {
        XCTAssertNil(VehicleRefreshPhase.idle.text)
        XCTAssertNil(VehicleRefreshPhase.acknowledged.text)
    }

    // `vehicle_asleep` is the SAME physical fact whether a lock command or a
    // refresh discovered it, so it reuses the MYR-301 copy verbatim rather than
    // forking a second sentence about the same situation.
    func testAsleepReusesTheExistingNoticeCopy() {
        XCTAssertEqual(VehicleRefreshNotice.asleep.message, VehicleCommandNotice.asleep.message)
        XCTAssertEqual(VehicleRefreshNotice.asleep.message, "Car is asleep \u{2014} try again shortly")
    }

    // The cooldown names the act the owner just performed. MYR-320 moved the
    // COMMAND cooldown onto the same grammar ("Just sent — one moment"), which is
    // right — it is the same back-off — but the two must still name different
    // acts, or a rate-limited refresh would claim a command was sent.
    func testCooldownCopyNamesTheRecentRefresh() {
        XCTAssertEqual(VehicleRefreshNotice.cooldown.message, "Just refreshed \u{2014} one moment")
        XCTAssertEqual(VehicleCommandNotice.cooldown.message, "Just sent \u{2014} one moment")
        XCTAssertNotEqual(VehicleRefreshNotice.cooldown.message, VehicleCommandNotice.cooldown.message)
    }

    // The typed §7.9 catalog is the ONLY thing consulted — never the server's
    // human message (FR-7.1).
    func testFailureKindsFoldOntoTheirNotices() {
        XCTAssertEqual(VehicleRefreshNotice.resolve(commandFailureKind: .vehicleAsleep), .asleep)
        XCTAssertEqual(VehicleRefreshNotice.resolve(commandFailureKind: .rateLimited), .cooldown)
        XCTAssertEqual(VehicleRefreshNotice.resolve(commandFailureKind: .other), .failed)
        XCTAssertEqual(VehicleRefreshNotice.failed.message, VehicleCommandNotice.failed.message)
    }
}

// MARK: - Foreground refetch policy

final class ForegroundRefetchPolicyTests: XCTestCase {

    // A glance at another app, Control Center, a notification — all produce a
    // background→active round trip within seconds. Refetching on each would spend
    // two requests to re-learn what the still-live socket already knows.
    func testBriefBackgroundSpellsDoNotRefetch() {
        XCTAssertFalse(ForegroundRefetchPolicy.shouldRefetch(backgroundedFor: 0))
        XCTAssertFalse(ForegroundRefetchPolicy.shouldRefetch(backgroundedFor: 9.5))
    }

    // Past the debounce the socket has had a real chance to die silently under
    // suspension, and the data has had a real chance to age.
    func testLongerBackgroundSpellsRefetch() {
        XCTAssertTrue(ForegroundRefetchPolicy.shouldRefetch(
            backgroundedFor: ForegroundRefetchPolicy.minimumBackgroundInterval))
        XCTAssertTrue(ForegroundRefetchPolicy.shouldRefetch(backgroundedFor: 3600))
    }

    // No recorded background transition means a cold launch (whose initial load is
    // the fleet's own `start()`) or an `.inactive` blip that never reached
    // `.background`. Neither is a resume, and refetching on either would fire an
    // extra pair of requests at launch.
    func testNoRecordedBackgroundTransitionDoesNotRefetch() {
        XCTAssertFalse(ForegroundRefetchPolicy.shouldRefetch(backgroundedFor: nil))
    }
}
