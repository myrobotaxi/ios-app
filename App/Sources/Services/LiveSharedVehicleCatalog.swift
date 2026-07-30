import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - LiveSharedVehicleCatalog (MYR-184, rest-api.md §7.0 + §7.5.5)
//
// The rider's shared vehicles come from the SAME `GET /api/vehicles` the owner
// reads — MYR-184's viewer merge appends every redeemed grant as a `role: viewer`
// row carrying a `sharePermission`. There is no separate "shared with me"
// endpoint and there does not need to be; filtering the catalog on `role` is the
// contract's own design.
//
// Two rules this class exists to hold:
//
//  • VIEWER ROWS ONLY. A rider who also owns a car sees both in this list. The
//    owner rows are theirs outright and belong on the owner shell, not under
//    "Shared with me" — and they carry NO `sharePermission` (§7.0: the key is
//    emitted iff `role` is `viewer`), so treating them as grants would produce a
//    tier-less row the gates would then fail closed on.
//
//  • ABSENT TIER MEANS `live`, NOT full access. `effectiveSharePermission` in the
//    Kit applies the contract's never-fail-open rule; this class never
//    second-guesses it.
//
// The redeem call folds its failures through `RestError.shareRedemptionFailure`
// so the entry screen branches on four intelligible answers instead of on status
// codes — and, critically, so the 404 case stays ONE case: the server answers
// unknown / expired / already-consumed identically on purpose.
@Observable
@MainActor
final class LiveSharedVehicleCatalog: SharedVehicleCatalog {
    private(set) var grants: [SharedVehicleGrant] = []
    /// MYR-343 — the OWNER partition of the same list. See the protocol's
    /// declaration for why the rider shell needs it (an owner in rider mode
    /// self-rides their own car and holds zero viewer rows).
    private(set) var ownedVehicles: [Vehicle] = []
    private(set) var hasLoaded = false
    private(set) var loadFailed = false

    @ObservationIgnored private let api: any VehicleSharingEndpoint
    @ObservationIgnored private let listVehicles: @Sendable () async throws -> [VehicleSummary]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        api: any VehicleSharingEndpoint,
        listVehicles: @escaping @Sendable () async throws -> [VehicleSummary]
    ) {
        self.api = api
        self.listVehicles = listVehicles
    }

    convenience init(rest: RestClient) {
        self.init(api: rest, listVehicles: { try await rest.vehicles() })
    }

    func load() async {
        loadTask?.cancel()
        let task = Task { @MainActor in
            guard let summaries = try? await self.listVehicles() else {
                // A failed list is NOT "nothing is shared with you". Leave the
                // last-known grants standing and leave `hasLoaded` alone, so the
                // Live Map does not swap a working map for an empty state
                // because one fetch timed out.
                //
                // MYR-343 — but DO record that the attempt failed, so a shell that
                // has never had an answer can stop claiming to be loading (MYR-326:
                // a skeleton that never resolves is worse than the spinner it
                // replaced). A catalog that already loaded once keeps rendering its
                // last-known set; `RiderVehicleSet.resolve` prefers `hasLoaded`.
                guard !Task.isCancelled else { return }
                self.loadFailed = true
                return
            }
            guard !Task.isCancelled else { return }
            self.grants = Self.grants(from: summaries)
            self.ownedVehicles = Self.ownedVehicles(from: summaries)
            self.hasLoaded = true
            self.loadFailed = false
        }
        loadTask = task
        await task.value
    }

    func redeem(code: String) async throws -> RedeemedShare {
        do {
            let response = try await api.redeemShareInvite(code: code)
            let redeemed = RedeemedShare(
                ownerFirstName: response.ownerFirstName,
                grants: Self.grants(from: response.vehicles)
            )
            // §7.5.5: the response rows ARE the viewer-masked catalog rows the
            // next `GET /api/vehicles` will return, so seed straight from it —
            // the rider's Live Map has a vehicle before the list round-trips.
            // Merge rather than replace: the rider may already hold other grants.
            var merged = grants.filter { existing in
                !redeemed.grants.contains { $0.id == existing.id }
            }
            merged.insert(contentsOf: redeemed.grants, at: 0)
            grants = merged
            hasLoaded = true
            // MYR-343 — a redeem answers with VIEWER rows only (§7.5.5), so it can
            // neither add to nor invalidate `ownedVehicles`; leave that partition
            // exactly as the last list left it. And a successful redeem clears a
            // prior list failure: the account demonstrably has a vehicle now.
            loadFailed = false
            return redeemed
        } catch let error as RestError {
            throw error.shareRedemptionFailure
        } catch {
            throw ShareRedemptionFailure.unavailable
        }
    }

    /// Fold `VehicleSummary` rows into grants — viewer rows only, in list order.
    ///
    /// Pure + static so the mapping is unit-testable off a canonical fixture with
    /// no service, network, or clock.
    static func grants(from summaries: [VehicleSummary]) -> [SharedVehicleGrant] {
        summaries.compactMap { summary in
            guard summary.role == .viewer else { return nil }
            // Never `summary.sharePermission` directly: absence on a viewer row
            // is the LOWEST tier by contract, not "unknown", and not full access.
            let wire = (summary.effectiveSharePermission ?? .live).rawValue
            return SharedVehicleGrant(
                id: summary.vehicleId,
                // No owner name on a §7.0 row — see `SharedVehicleGrant.ownerName`
                // for why this is nil rather than synthesized.
                ownerName: nil,
                relationship: nil,
                vehicleName: VehicleContractMapping.nonEmpty(summary.name)
                    ?? VehicleContractMapping.nonEmpty(summary.model)
                    ?? "Shared Tesla",
                accessLabel: ShareTierMapping.permLabel(forWire: wire),
                tier: ShareTierMapping.tier(forWire: wire),
                // The real vehicle the Live Map watches — mapped through the SAME
                // production `VehicleContractMapping.vehicle` the owner fleet uses,
                // so a shared car and an owned car are built by one code path.
                vehicle: VehicleContractMapping.vehicle(summary: summary)
            )
        }
    }

    /// MYR-343 — fold the OWNER partition of the same list into vehicles, in list
    /// order. The mirror image of `grants(from:)`: same source, same production
    /// `VehicleContractMapping.vehicle`, opposite `role` filter — so an owned car
    /// and a shared car reaching the rider's map are built by ONE code path.
    ///
    /// Any row that is not explicitly `viewer` counts as owned. §7.0 emits
    /// `role: owner` for the account's own cars, and a role this build cannot
    /// rank is far likelier to be a NEW ownership-shaped role than a share — and
    /// unlike a tier, guessing here fails SAFE: the rider watches a car that is on
    /// their own account either way, and every capability is server-enforced.
    ///
    /// Pure + static, for the same reason `grants(from:)` is.
    static func ownedVehicles(from summaries: [VehicleSummary]) -> [Vehicle] {
        summaries.compactMap { summary in
            guard summary.role != .viewer else { return nil }
            return VehicleContractMapping.vehicle(summary: summary)
        }
    }
}

// MARK: - ShareRedemptionFailure copy

extension ShareRedemptionFailure {
    /// The rider-facing line for each answer. Four short sentences, no blame, no
    /// speculation — in particular `.invalidOrExpired` does NOT guess between
    /// "wrong" and "expired", because the server deliberately does not say.
    var riderMessage: String {
        switch self {
        case .malformed, .invalidOrExpired:
            return "That code didn\u{2019}t work"
        case .alreadyHasAccess:
            return "You already have access to that Tesla"
        case .tooManyAttempts:
            return "Too many attempts \u{2014} wait a minute"
        case .unavailable:
            return "Can\u{2019}t check that code right now"
        }
    }

    /// Whether the entry field should CLEAR and re-focus for another try.
    ///
    /// A bad code clears (the rider is going to retype it anyway). "You already
    /// have access" does not: nothing is wrong with what they typed, and wiping
    /// it would read as a rejection. Neither does the rate limit — retyping the
    /// same code immediately just burns another attempt.
    var clearsEntry: Bool {
        switch self {
        case .malformed, .invalidOrExpired: return true
        case .alreadyHasAccess, .tooManyAttempts, .unavailable: return false
        }
    }
}

extension ShareRedemptionFailure: Error {}
