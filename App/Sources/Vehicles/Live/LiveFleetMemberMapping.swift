import Foundation
import MyRobotaxiContracts

// MARK: - Live fleet-member mapping (MYR-212 deliverable 4)
//
// Folds the account's first owned `VehicleSummary` onto the fixture-shaped
// `FleetMember` the rider's Review + Booking cards already render — so a live
// ride shows the REAL vehicle instead of the fixture "Alex's Quicksilver Model
// Y · RBO-2046 · 68%" (client QA round 2, defect 4). Every field that has a
// telemetry source is real; the two that do not are called out below.
//
// DECISIONS (documented, no invented data):
//  • `plate`: Tesla telemetry has NO license-plate field. The design draws a
//    plate chip; the graceful degrade is the VIN last-4 in that chip
//    ("VIN ····2046", reusing `VehicleContractMapping.plateDisplay`). An empty
//    VIN yields an empty string → the caller hides the chip rather than showing
//    a blank box. We never fabricate a plate.
//  • `etaMin`: there is no live pickup-ETA yet (live routing is MYR-176/177), so
//    the pickup-leg minutes keep the fixture placeholder. Flagged here so it's
//    not mistaken for real data.
//  • `owner`: telemetry carries no owner *display name*. For the single owned
//    vehicle the rider is requesting, the honest headline is the vehicle's own
//    nickname (`summary.name`, e.g. "Lunar") — so the CTAs read "Request from
//    Lunar" / "Booking ride with Lunar". A real owner-name join is MYR-91/210
//    scope (the shared-viewer access set); this stays a single-vehicle join.
enum LiveFleetMemberMapping {

    static func fleetMember(from summary: VehicleSummary) -> FleetMember {
        let nickname = nonEmpty(summary.name) ?? nonEmpty(summary.model) ?? "Your Tesla"
        return FleetMember(
            id: summary.vehicleId,
            owner: nickname, // no owner display name in telemetry — nickname stands in
            relationship: "Your Tesla",
            name: nonEmpty(summary.model) ?? "Tesla",
            model: VehicleContractMapping.modelLabel(year: summary.year, model: "Tesla"),
            colorName: nonEmpty(summary.color) ?? "",
            battery: summary.chargeLevel,
            etaMin: RideRequestFixtures.fleet[0].etaMin, // no live pickup ETA yet (MYR-176/177)
            plate: VehicleContractMapping.plateDisplay(vinLast4: summary.vinLast4),
            isAvailable: isAvailable(summary.status),
            availabilityWord: availabilityWord(summary.status)
        )
    }

    /// Parked / charging read as bookable-now; driving / offline / in-service do
    /// not (drives the green dot + the "now" suffix in the Review vehicle row).
    static func isAvailable(_ status: VehicleSummary.Status) -> Bool {
        switch status {
        case .parked, .charging: return true
        case .driving, .offline, .inService, .unrecognized: return false
        }
    }

    /// The status word shown in the vehicle row — "Available" when bookable,
    /// otherwise the live status (real data, within the design's status-line
    /// slot; no new UI).
    static func availabilityWord(_ status: VehicleSummary.Status) -> String {
        switch status {
        case .parked, .charging: return "Available"
        case .driving: return "Driving"
        case .offline: return "Offline"
        case .inService: return "In service"
        case .unrecognized: return "Unavailable"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
