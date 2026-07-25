import Foundation

// MARK: - IncomingRequestDisplay (MYR-264)
//
// Resolves what the owner's `IncomingRequestSheet` (and the accept toast in
// `HomeScreen`) renders for one request, gated on the ONE resolved `isLive` flag
// (CLAUDE.md "No fixtures on the live path", MYR-228).
//
//  • SIM: fixture persona ("Sam") + fixture fleet member ("Model Y", battery),
//    pixel-identical to M1 / the `ownerIncoming` drift-gate scene.
//  • LIVE: the REAL rider name off the wire record, and the REAL vehicle name
//    JOINED from the owner's loaded fleet by `vehicleId` — never
//    `RideRequestFixtures`. When the wire omitted the rider name, or the vehicle
//    isn't in the loaded fleet, the corresponding surface renders a neutral honest
//    label / hides rather than asserting fixture data.
//
// A plain value type with a pure factory so both the sheet and the accept toast
// resolve identically, and so the gating is unit-testable without SwiftUI.
struct IncomingRequestDisplay: Equatable {
    /// The rider's display name — the real wire `requesterName` (live) or the
    /// fixture "Sam" (sim). `nil` when a live request carried no name → a neutral
    /// role label + a generic avatar glyph (never a fabricated initial).
    let riderName: String?
    /// The target vehicle's real name — the fixture fleet member's name (sim) or
    /// the live fleet join by `vehicleId` (live). `nil` when a live request's
    /// vehicle isn't in the owner's loaded fleet → the vehicle name / status line
    /// and the "Sending to …" / "Destination sent to …" suffixes are hidden.
    let vehicleName: String?
    /// Whether to assert the "is parked · ready to dispatch" readiness line. Only
    /// the sim fixtures carry a known ready status; a live request never asserts
    /// one (the wire doesn't carry per-request vehicle status here).
    let showsReadyStatus: Bool
    /// The "battery after" %, or `nil` to hide the BATTERY AFTER stat cell. The
    /// wire carries no per-request battery, so a live request never asserts one.
    let batteryAfter: Int?

    /// The role a request comes from when no rider name is known — honest (that IS
    /// the rider's real relationship to the vehicle), not a persona.
    static let neutralRole = "Shared viewer"

    /// The fixture persona name for the SIM path (design/app/ride-request.jsx's
    /// Tweaks "Rider name: Sam"). Only ever rendered on the simulated path.
    static let simRiderName = "Sam"

    static func resolve(request: RideRequestRecord, isLive: Bool, liveVehicle: Vehicle?) -> IncomingRequestDisplay {
        guard isLive else {
            let member = request.input.fleetMember
            let batteryAfter = max(10, member.battery - Int((request.input.destination.miles * 0.7).rounded()))
            return IncomingRequestDisplay(
                riderName: simRiderName,
                vehicleName: member.name,
                showsReadyStatus: true,
                batteryAfter: batteryAfter
            )
        }
        return IncomingRequestDisplay(
            riderName: Self.cleanedName(request.input.requesterName),
            vehicleName: liveVehicle?.name,
            showsReadyStatus: false,
            batteryAfter: nil
        )
    }

    /// The avatar initial for the known name, or `nil` → a generic person glyph.
    var avatarInitial: String? {
        guard let riderName, let first = riderName.first else { return nil }
        return String(first).uppercased()
    }

    /// The sheet header title. "<Name> wants a ride" / "<Name> requested a ride"
    /// (for-someone-else), or the neutral role variant when there's no name.
    func title(hasPassenger: Bool) -> String {
        let subject = riderName ?? Self.neutralRole
        return hasPassenger ? "\(subject) requested a ride" : "\(subject) wants a ride"
    }

    /// The rider label for the accept toast / reserved Upcoming ride — the real
    /// name or the neutral role (never a persona).
    var riderLabel: String { riderName ?? Self.neutralRole }

    /// Trim whitespace; treat an empty wire string as absent (same rule as
    /// `UserProfile.normalized`).
    private static func cleanedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
