import XCTest
@testable import MyRoboTaxi

// MARK: - MYR-243 — Settings "Tesla Account" live-path state mapping
//
// The read-only section reads the live fleet (`LinkedVehiclesReading`) and must
// render HONEST states only — loading, an honest notice (empty/auth/unreachable),
// or the account's real vehicles — never fixtures. These cover the pure
// precedence in `SettingsScreen.liveState`.

final class SettingsTeslaAccountLiveStateTests: XCTestCase {
    private let sample = VehicleFixtures.vehicles

    func testLoadedVehiclesWin() {
        let state = SettingsScreen.liveState(vehicles: sample, isConnecting: false, statusMessage: nil)
        XCTAssertEqual(state, .linked(sample))
    }

    func testLoadedVehiclesWinEvenWhileConnecting() {
        // Vehicles present + a first-snapshot still in flight: show the rows, not
        // a connecting placeholder (no blank flash over real data).
        let state = SettingsScreen.liveState(vehicles: sample, isConnecting: true, statusMessage: nil)
        XCTAssertEqual(state, .linked(sample))
    }

    func testLoadedVehiclesWinOverAStaleNotice() {
        let state = SettingsScreen.liveState(vehicles: sample, isConnecting: false, statusMessage: "Can't reach telemetry right now")
        XCTAssertEqual(state, .linked(sample))
    }

    func testEmptyAndConnectingShowsConnecting() {
        let state = SettingsScreen.liveState(vehicles: [], isConnecting: true, statusMessage: nil)
        XCTAssertEqual(state, .connecting)
    }

    func testEmptyAccountShowsFleetNotice() {
        // The live fleet sets this for a real account with zero linked vehicles.
        let state = SettingsScreen.liveState(vehicles: [], isConnecting: false, statusMessage: "No vehicles linked to this account")
        XCTAssertEqual(state, .notice("No vehicles linked to this account"))
    }

    func testFetchFailureShowsFleetNotice() {
        let state = SettingsScreen.liveState(vehicles: [], isConnecting: false, statusMessage: "Sign-in required to load vehicles")
        XCTAssertEqual(state, .notice("Sign-in required to load vehicles"))
    }

    func testEmptyWithNoSignalFallsBackToHonestEmptyCopy() {
        let state = SettingsScreen.liveState(vehicles: [], isConnecting: false, statusMessage: nil)
        XCTAssertEqual(state, .notice("No Tesla linked yet."))
    }

    func testBlankStatusMessageIsTreatedAsAbsent() {
        let state = SettingsScreen.liveState(vehicles: [], isConnecting: false, statusMessage: "   ")
        XCTAssertEqual(state, .notice("No Tesla linked yet."))
    }
}
