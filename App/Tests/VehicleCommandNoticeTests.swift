import XCTest
import UIKit
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-301 — command notices: readable, distinguishable, actionable
//
// The client's TestFlight report ("Charge port not opening") had an honest
// answer in the app that the owner could neither READ ("Reconnec…" in an ~80pt
// tile) nor ACT on (no route to the Tesla re-link). These tests pin all three
// halves of the fix:
//
//   1. the §7.9 error code → notice mapping, including the two outcomes that
//      used to be folded into one line (503 asleep vs 502 rejected);
//   2. the tile token MEASURABLY fits the tile — the truncation that started
//      this issue is a layout fact, so it is asserted with real font metrics
//      rather than by eyeballing a screenshot;
//   3. only the re-link notices carry an action, and that action's route lands
//      the owner on the EXISTING Tesla link flow.
@MainActor
final class VehicleCommandNoticeTests: XCTestCase {

    // MARK: 1 — error code → notice → copy

    /// The per-code table, asserted end to end: wire code + status → the Kit's
    /// typed `CommandFailureKind` → the notice case → the copy the owner reads.
    func testErrorCodeMapsToNoticeCaseAndCopy() {
        struct Case {
            let code: String
            let status: Int
            let key: VehicleControlKey
            let notice: VehicleCommandNotice
            let message: String
            let tileText: String
            let action: VehicleCommandNoticeAction?
            let line: UInt
            init(
                _ code: String, _ status: Int, key: VehicleControlKey = .lock,
                _ notice: VehicleCommandNotice, _ message: String, _ tileText: String,
                action: VehicleCommandNoticeAction? = nil, line: UInt = #line
            ) {
                self.code = code; self.status = status; self.key = key
                self.notice = notice; self.message = message; self.tileText = tileText
                self.action = action; self.line = line
            }
        }
        let cases: [Case] = [
            // The client's bug: the charge-port scope (`vehicle_charging_cmds`)
            // is missing → name the charging permission AND offer the re-link.
            Case("permission_denied", 403, key: .chargePort, .relinkCharging,
                 "Reconnect Tesla for charging access", "Re-link", action: .relinkTesla),
            // The same code on any other control is a plain re-link.
            Case("permission_denied", 403, key: .climate, .relink,
                 "Reconnect Tesla to allow this", "Re-link", action: .relinkTesla),
            Case("vehicle_not_owned", 403, .relink, "Reconnect Tesla to allow this", "Re-link", action: .relinkTesla),
            Case("auth_failed", 401, .relink, "Reconnect Tesla to allow this", "Re-link", action: .relinkTesla),
            Case("key_not_paired", 403, .pairKey, "Pair your key in Tesla", "Pair key"),
            // MYR-320 — the media card's 429 read as a stall ("Just a moment…"),
            // not as a back-off. The copy now confirms the send first.
            Case("rate_limited", 429, .cooldown, "Just sent \u{2014} one moment", "One sec"),
            // MYR-301 — 503 and 502 no longer share "Couldn't reach the car".
            Case("vehicle_asleep", 503, .asleep, "Car is asleep \u{2014} try again shortly", "Asleep"),
            Case("command_failed", 502, .rejected(nil), "The car didn\u{2019}t accept that", "Declined"),
            Case("invalid_request", 400, .failed, "Couldn\u{2019}t reach the car", "Failed"),
            Case("not_found", 404, .failed, "Couldn\u{2019}t reach the car", "Failed"),
        ]
        for c in cases {
            let error = RestError.http(status: c.status, code: ErrorPayload.Code(rawValue: c.code), message: nil, subCode: nil)
            let notice = LiveVehicleCommandExecutor.notice(for: error.commandFailureKind, key: c.key)
            XCTAssertEqual(notice, c.notice, "notice case for \(c.code) on \(c.key)", line: c.line)
            XCTAssertEqual(notice.message, c.message, "full copy for \(c.code)", line: c.line)
            XCTAssertEqual(notice.tileText, c.tileText, "tile copy for \(c.code)", line: c.line)
            XCTAssertEqual(notice.action, c.action, "action for \(c.code)", line: c.line)
        }
    }

    /// A transport failure (no response formed) is the one case that genuinely IS
    /// "couldn't reach the car" — it must not be confused with a rejection.
    func testTransportFailureIsTheUnreachableNotice() {
        let transport = RestError.transport(underlying: URLError(.notConnectedToInternet))
        let notice = LiveVehicleCommandExecutor.notice(for: transport.commandFailureKind, key: .lock)
        XCTAssertEqual(notice, .failed)
        XCTAssertEqual(notice.message, "Couldn\u{2019}t reach the car")
    }

    /// 503 and 502 must never read the same — that equivalence is exactly what
    /// hid "the car is asleep" behind "couldn't reach the car".
    func testAsleepAndRejectedAreDistinct() {
        XCTAssertNotEqual(VehicleCommandNotice.asleep, .rejected(nil))
        XCTAssertNotEqual(VehicleCommandNotice.asleep.message, VehicleCommandNotice.rejected(nil).message)
        XCTAssertNotEqual(VehicleCommandNotice.asleep.message, VehicleCommandNotice.failed.message)
        XCTAssertNotEqual(VehicleCommandNotice.rejected(nil).message, VehicleCommandNotice.failed.message)
        // …and the settled asleep notice must not claim an ongoing wake.
        XCTAssertNotEqual(VehicleCommandNotice.asleep.message, VehicleCommandNotice.waking.message)
    }

    // MARK: 2 — the tile token actually fits the tile

    /// The four quick tiles split the sheet's content width evenly
    /// (`VehicleControls.quickTiles`, 8pt gaps) inside the 24pt page gutter, and
    /// each tile pads its content 13pt on both sides.
    private static var tileInnerWidth: CGFloat {
        let screen: CGFloat = 393        // the prototype's full-bleed canvas (CLAUDE.md)
        let gutter: CGFloat = 24 * 2     // MRTMetrics.pageGutter, both sides
        let gaps: CGFloat = 8 * 3        // HStack(spacing: 8) between four tiles
        let tile = (screen - gutter - gaps) / 4
        return tile - 13 * 2             // ControlTile's horizontal padding
    }

    /// THE regression this issue exists for: every notice's tile token must
    /// render inside the tile at the ONE uniform 11pt sub size MYR-281
    /// established (no `minimumScaleFactor` rescue), so nothing ellipsizes.
    /// "Reconnect Tesla for charging access" is ~197pt wide — nearly 4× the room
    /// there is — which is why the owner saw "Reconnec…".
    func testTileTextFitsTheControlTile() {
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        for notice in Self.allNotices {
            let width = (notice.tileText as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(
                width, Self.tileInnerWidth,
                "\(notice) tile text \"\(notice.tileText)\" is \(width)pt — it would ellipsize in a \(Self.tileInnerWidth)pt tile"
            )
        }
    }

    /// The premise of the shortening: the FULL message could never have fit, so
    /// it has to live somewhere else (the notice row). If this ever stops being
    /// true the tile could carry the message directly.
    func testFullMessagesDoNotFitTheTile() {
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        let width = (VehicleCommandNotice.relinkCharging.message as NSString)
            .size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(width, Self.tileInnerWidth * 2, "the charging re-link sentence is far wider than a tile")
    }

    /// The tile token must never be the whole message (that is the truncation
    /// bug), and must never be empty.
    func testEveryNoticeHasBothAShortAndAFullForm() {
        for notice in Self.allNotices {
            XCTAssertFalse(notice.tileText.isEmpty, "\(notice) needs a tile token")
            XCTAssertFalse(notice.message.isEmpty, "\(notice) needs a full message")
            XCTAssertLessThanOrEqual(
                notice.tileText.count, notice.message.count,
                "\(notice)'s tile token must be a SHORTENING of its message"
            )
        }
    }

    // MARK: 3 — actionable notices + the route

    /// Only the notices that name a broken Tesla connection route anywhere; the
    /// rest resolve themselves or are retried by tapping the control again, so
    /// offering a "fix" would be noise.
    func testOnlyRelinkNoticesAreActionable() {
        XCTAssertEqual(VehicleCommandNotice.relink.action, .relinkTesla)
        XCTAssertEqual(VehicleCommandNotice.relinkCharging.action, .relinkTesla)
        for notice in [VehicleCommandNotice.waking, .asleep, .pairKey, .cooldown, .rejected(nil), .failed] {
            XCTAssertNil(notice.action, "\(notice) has no in-app fix to route to")
        }
        XCTAssertEqual(VehicleCommandNoticeAction.relinkTesla.label, "Reconnect")
    }

    /// The transient/persistent split is unchanged by the new cases: a settled
    /// asleep/rejected notice persists until the next tap (the owner has to act),
    /// while waking/cooldown clear themselves.
    func testTransienceIsUnchangedByTheNewCases() {
        XCTAssertTrue(VehicleCommandNotice.waking.isTransient)
        XCTAssertTrue(VehicleCommandNotice.cooldown.isTransient)
        for notice in [VehicleCommandNotice.asleep, .rejected(nil), .failed, .relink, .relinkCharging, .pairKey] {
            XCTAssertFalse(notice.isTransient, "\(notice) persists until the owner acts")
        }
    }

    /// The route trigger: tapping the fix must BOTH switch to the Settings tab
    /// and arm the link flow — arming without switching (or switching without
    /// arming) silently does nothing, which is the failure mode this value type
    /// exists to prevent.
    func testRelinkRouteOpensSettingsWithTheLinkFlowArmed() {
        var selectedTab: String?
        var startedLink = false
        let route = TeslaRelinkRoute(
            selectTab: { selectedTab = $0 },
            startLink: { startedLink = true }
        )

        route()

        XCTAssertEqual(selectedTab, "settings", "the Tesla Account section lives on the owner Settings tab")
        XCTAssertEqual(selectedTab, TeslaRelinkRoute.settingsTab)
        XCTAssertTrue(startedLink, "Settings must arrive with AddTeslaFlow armed, not just be opened")
    }

    /// The route is not fired on construction — only when the owner taps.
    func testRelinkRouteDoesNothingUntilInvoked() {
        var touched = false
        _ = TeslaRelinkRoute(selectTab: { _ in touched = true }, startLink: { touched = true })
        XCTAssertFalse(touched)
    }

    // MARK: 4 — the simulated path is untouched

    /// Notices are a live-path concept: the simulated executor reports `.idle`
    /// for every key, so no notice row, no shortened sub, and no tappable line
    /// can ever render on the M1 / drift-gate scenes (CLAUDE.md pixel-identity).
    func testSimulatedExecutorNeverProducesANotice() async {
        let exec = SimulatedVehicleCommandExecutor(driving: false, plate: "VIN ····0001")
        try? await exec.setChargePortOpen(true)
        try? await exec.setLocked(false)
        try? await exec.setSeatHeatLevel(.driver, level: 2)
        try? await exec.setMediaPlaying(true)
        for key in [VehicleControlKey.lock, .climate, .temp, .trunk, .chargePort, .driverSeat, .passengerSeat, .media] {
            XCTAssertEqual(exec.uiState(for: key), .idle, "\(key) must stay idle on the simulated path")
            XCTAssertNil(exec.uiState(for: key).notice)
        }
    }

    private static let allNotices: [VehicleCommandNotice] = [
        .waking, .asleep, .pairKey, .relink, .relinkCharging, .cooldown, .rejected(nil), .failed,
    ]
}
