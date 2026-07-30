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

    /// The ROLE a request comes from, used as a subtitle label REGARDLESS of
    /// whether a name is known (`IncomingRequestSheet.headerSubtitle`, the
    /// prototype's own "Shared viewer · just now"). It describes the requester's
    /// relationship to the vehicle and is true of every incoming request.
    ///
    /// It is deliberately NO LONGER the name-absent stand-in — see `formerRider`.
    static let neutralRole = "Shared viewer"

    /// What stands in for a MISSING NAME on the live path (MYR-355).
    ///
    /// The backend fact this rests on: `requesterName` is omitted from the wire
    /// **if and only if** the rider has no identity row in ANY of the three
    /// sources. A rider who exists but has no name or email on file resolves to
    /// the literal `"Rider"` instead — so the server never sends `nil` for a
    /// person who is still there. On the LIVE path, absent `requesterName` now
    /// means exactly one thing: **that account was deleted.**
    ///
    /// It used to render `neutralRole` ("Shared viewer"), which asserts a role in
    /// the PRESENT TENSE about someone who no longer holds it — the vehicle is not
    /// shared with them any more, because they are gone. "Former rider" is the one
    /// claim the wire actually supports, and it is still not a fabricated name and
    /// still not an initial.
    ///
    /// Scoped to the two name-absent surfaces (`title` and `riderLabel`) and
    /// nowhere else. It is UNREACHABLE from the simulated path by construction:
    /// `resolve`'s sim arm always returns the fixture persona, so `riderName` is
    /// never nil there and every simulated capture is byte-identical.
    static let formerRider = "Former rider"

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
    /// (for-someone-else), or — with no name — the MYR-355 `formerRider` stand-in,
    /// because on the live path an absent `requesterName` means the account is
    /// gone.
    func title(hasPassenger: Bool) -> String {
        let subject = riderName ?? Self.formerRider
        return hasPassenger ? "\(subject) requested a ride" : "\(subject) wants a ride"
    }

    /// The rider label for the accept toast / reserved Upcoming ride — the real
    /// name, or the same MYR-355 stand-in (never a persona).
    var riderLabel: String { riderName ?? Self.formerRider }

    /// MYR-312 — the requester name to stamp on a draft this device's OWN rider
    /// submits, so the owner card is honest from the first frame instead of
    /// waiting for the server round trip to name the requester.
    ///
    /// The bug this closes: `RideRequestInput` gets its `requesterName` off the
    /// WIRE (`RideRequestContractMapping.record(from:)`), or — for a draft
    /// submitted right here — from the `integrate` fold once a
    /// `ride_request_created` frame triggers a refetch (MYR-277 A1). In the
    /// single-account demo the rider's own optimistic draft therefore carries NO
    /// name until that round trip completes, and the create POST is DEFERRED by
    /// the 10s booking grace window (MYR-218). For an INSTANT request the rider
    /// sits on the Booking card for that window, so the owner surface is only
    /// reachable after the name has landed. A SCHEDULED request drops straight
    /// back to idle (`RideRequestReviewContent.confirm`), so the owner tab is one
    /// tap away with no server ride in existence yet — and the card rendered
    /// "Shared viewer wants a ride · Scheduled · …", the client's exact report.
    ///
    /// The signed-in profile IS the requester on this device, so naming it is the
    /// honest answer, not a fixture: `nil` profile (SIM / no live identity) keeps
    /// `resolve`'s fixture-persona branch pixel-identical (MYR-228). The FIRST
    /// name matches what the server resolves for the same account (MYR-229's
    /// `firstNameToken` chain), so the later authoritative fold is a no-op
    /// instead of a visible "Thomas Nandola" → "Thomas" flicker.
    static func localRequesterName(profile: UserProfile?) -> String? {
        cleanedName(profile?.firstName)
    }

    /// Trim whitespace; treat an empty wire string as absent (same rule as
    /// `UserProfile.normalized`).
    private static func cleanedName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
