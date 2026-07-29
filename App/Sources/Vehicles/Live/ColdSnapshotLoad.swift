import Foundation
import MyRoboTaxiKit

// MARK: - Cold-snapshot load budget (MYR-326)
//
// How long owner Home is allowed to say "loading" before it has to say
// something honest instead.
//
// The cold `/snapshot` read is the slow half of a live boot, and MYR-319 made
// it a BOUNDED RETRY (`TelemetrySocket.defaultSnapshotRetryDelays`, 0 / 0.8 / 3
// / 9s) because a car that is asleep, offline or in service answers `503
// vehicle_asleep` at first ask and produces no `vehicle_update` frames to
// re-trigger a read. Bounded is right — but it left `LiveVehicleFleet` with no
// end state: when the last attempt failed, `state` stayed nil, `isConnecting`
// stayed true, and Home showed its connecting treatment for the rest of the
// session with nothing left in flight behind it.
//
// That was survivable as a spinner. It is NOT survivable as a skeleton: a
// shimmering placeholder is a promise that content is arriving, and MYR-326's
// rule is that loading is not the same as unavailable. So the fleet now watches
// the clock: once the Kit's whole schedule has had time to run and nothing
// arrived, the screen stops claiming to be loading and shows the honest line.
enum ColdSnapshotLoad {

    /// Wall time to allow before declaring the cold read failed.
    ///
    /// The Kit's schedule of DELAYS plus per-attempt slack for the request
    /// itself — the delays only describe the gaps between asks, so a budget of
    /// exactly `sum(delays)` would expire while the final attempt was still in
    /// flight and call a car unreachable that was about to answer. With the
    /// shipping schedule this is 12.8s of backoff + 8s of slack ≈ 20.8s, which
    /// is comfortably past the last attempt's START (12.8s) — i.e. by the time
    /// it fires, the Kit has genuinely stopped trying.
    static func budget(
        delays: [Double] = TelemetrySocket.defaultSnapshotRetryDelays,
        slackPerAttempt: Double = 2
    ) -> TimeInterval {
        let backoff = delays.reduce(0) { $0 + max(0, $1) }
        return backoff + slackPerAttempt * Double(max(delays.count, 1))
    }

    /// The honest line for a car whose cold read never landed. Names the car
    /// when the fleet list gave us a name (it usually did — the list is one fast
    /// REST call and the SNAPSHOT is what didn't answer), because "Can't reach
    /// Lunar" tells the owner which of their cars is the problem.
    ///
    /// Deliberately about REACHING the car, not about the network: the fleet
    /// list demonstrably succeeded, so blaming the connection would be wrong.
    static func unreachableMessage(vehicleName: String?) -> String {
        guard let name = vehicleName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return "Can\u{2019}t reach your vehicle right now" }
        return "Can\u{2019}t reach \(name) right now"
    }
}
