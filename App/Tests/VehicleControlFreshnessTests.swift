import Foundation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-260 — honest unknown / stale labeling for the quick-tile subs
//
// Splits the old perpetual "— Syncing" into three bounded states: transient
// Syncing (connecting or a streaming car still delivering), honest Unavailable
// (a reachable NON-streaming snapshot proves the value isn't coming), and a
// stale "X ago" qualifier on a KNOWN safety value. Pure logic — a fixed `now`
// keeps the age buckets deterministic.
final class VehicleControlFreshnessTests: XCTestCase {

    // MARK: State 1 — connecting / first snapshot not yet arrived → "Syncing"

    func testUnknownWhileConnectingIsSyncing() {
        // No snapshot yet (no read time). Streaming state is not even known —
        // the value is genuinely transient, so "Syncing" is honest.
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: false, isStreaming: nil),
            VehicleControlFreshness.syncingSub
        )
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: false, isStreaming: false),
            VehicleControlFreshness.syncingSub,
            "no snapshot means connecting regardless of a stale streaming flag"
        )
    }

    func testSimulatedPathIsAlwaysSyncingNeverUnavailable() {
        // Simulated: lastUpdated nil (→ hasSnapshot false), isStreaming nil. Every
        // field is isKnown there so this branch never actually renders, but it must
        // NOT resolve to "Unavailable" (which would be a regression risk).
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: false, isStreaming: nil),
            VehicleControlFreshness.syncingSub
        )
    }

    // MARK: State 2 — reachable snapshot, car NOT streaming → "Unavailable"

    func testUnknownWithSnapshotButNotStreamingIsUnavailable() {
        // We have a frame (read time exists) but the car is offline/in_service and
        // the one-shot REST read couldn't fill the field: it is NOT coming.
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: true, isStreaming: false),
            VehicleControlFreshness.unavailableSub
        )
    }

    func testUnknownWhileStreamingStaysSyncing() {
        // Online car: the value really is in flight and will land → still Syncing,
        // NOT Unavailable.
        XCTAssertEqual(
            VehicleControlFreshness.unknownSub(hasSnapshot: true, isStreaming: true),
            VehicleControlFreshness.syncingSub
        )
    }

    func testSyncingAndUnavailableAreDistinctAndDashPrefixed() {
        XCTAssertNotEqual(VehicleControlFreshness.syncingSub, VehicleControlFreshness.unavailableSub)
        XCTAssertTrue(VehicleControlFreshness.syncingSub.hasPrefix(VehicleControlFreshness.dash))
        XCTAssertTrue(VehicleControlFreshness.unavailableSub.hasPrefix(VehicleControlFreshness.dash))
        XCTAssertTrue(VehicleControlFreshness.unavailableSub.contains("Unavailable"))
    }

    // MARK: showsQualifier — a non-streaming car's known value is never "live"

    func testNonStreamingKnownValueAlwaysQualifiesEvenWhenRecent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Car just went offline 5s ago: NOT streaming → still qualifies, so a
        // stale trunk never renders as bare "Open" (the trunk-open incident).
        XCTAssertTrue(VehicleControlFreshness.showsQualifier(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-5), now: now))
    }

    func testStreamingKnownValueQualifiesOnlyWhenStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(VehicleControlFreshness.showsQualifier(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-30), now: now), "fresh stream")
        XCTAssertTrue(VehicleControlFreshness.showsQualifier(
            isStreaming: true, lastUpdated: now.addingTimeInterval(-120), now: now), "stalled stream")
    }

    func testSimulatedPathNeverQualifies() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // nil isStreaming (M1) and/or nil lastUpdated → never a qualifier.
        XCTAssertFalse(VehicleControlFreshness.showsQualifier(
            isStreaming: nil, lastUpdated: now.addingTimeInterval(-9999), now: now))
        XCTAssertFalse(VehicleControlFreshness.showsQualifier(
            isStreaming: false, lastUpdated: nil, now: now))
    }

    // MARK: State 3 — known but stale → value + "X ago"

    func testFreshKnownValueHasNoStaleQualifier() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Read 30s ago — inside the freshness threshold → not stale.
        XCTAssertFalse(VehicleControlFreshness.isStale(lastUpdated: now.addingTimeInterval(-30), now: now))
    }

    func testNilLastUpdatedIsNeverStale() {
        // Simulated / pre-first-frame: no read time → never a qualifier (keeps M1
        // pixel-identical).
        XCTAssertFalse(VehicleControlFreshness.isStale(lastUpdated: nil, now: Date()))
    }

    func testOldKnownValueIsStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(VehicleControlFreshness.isStale(lastUpdated: now.addingTimeInterval(-120), now: now))
    }

    func testAgoLabelBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-5 * 60), now: now), "5m ago")
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-2 * 3600), now: now), "2h ago")
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
    }

    func testAgoLabelClampsFutureReadToJustNow() {
        // Clock skew (read time slightly in the future) must not produce a negative
        // or nonsensical label.
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(VehicleControlFreshness.agoLabel(since: now.addingTimeInterval(10), now: now), "just now")
    }
}
