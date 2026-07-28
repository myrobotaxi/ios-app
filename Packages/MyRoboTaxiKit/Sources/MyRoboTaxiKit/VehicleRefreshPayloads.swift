import Foundation

// MARK: - Owner on-demand vehicle refresh (rest-api.md §7.15, MYR-315)
//
// Same EXCEPTION as `VehiclePlatePayloads.swift` / `VehicleTeardownPayloads.swift`
// / `TeslaLinkPayloads.swift`: contracts codegen covers the READ models + the WS
// envelope only, so there is no generated type for this endpoint's response yet.
// The DTO below is authored here, verbatim from the locked §7.15 contract, and
// MUST be replaced by a generated type the moment `contracts` grows one.
// Codable/Equatable/Sendable to match the generated-type conventions so the swap
// is drop-in.
//
// WHY THIS ENDPOINT EXISTS: telemetry only STREAMS while the car is awake. A car
// that has been asleep for hours has a last-known snapshot and nothing else — the
// app can honestly say "Synced 7h ago", but it has no way to ASK for something
// newer. §7.15 is that ask: the server decides whether a wake is even warranted
// (`fresh` — it streamed recently, nothing to do) or spends part of the vehicle's
// wake budget and performs a one-shot read (`refreshed`). Both outcomes are 200
// and both carry the authoritative read time, so the caller never has to infer
// freshness from the fact that a call succeeded.

/// `200 OK` body of `POST /api/tesla/vehicles/{vehicleId}/refresh` (§7.15).
///
/// Both success statuses are ordinary 200s — the distinction is *what the server
/// did*, not whether it worked:
///   • `fresh`     — the car streamed recently enough that a wake would be waste.
///                   No Tesla call was made; `lastUpdated` is the existing read.
///   • `refreshed` — the server woke the car and performed a one-shot read;
///                   `lastUpdated` is that new read.
///
/// The failure half of the contract is carried by typed `RestError`s, not by this
/// type: `503 vehicle_asleep` (the wake budget is exhausted — the car did NOT come
/// up), `429 rate_limited` (per-vehicle ~60s cooldown), plus the standard
/// 401/403/404. All of them fold through the existing
/// ``RestError/commandFailureKind`` catalog, so callers reuse the §7.9 vocabulary
/// rather than string-matching a message (FR-7.1).
public struct VehicleRefreshResponse: Decodable, Equatable, Sendable {
    /// What the server did. TOLERANT by construction: an unrecognized value is
    /// preserved verbatim in ``Status/unrecognized(_:)`` rather than failing the
    /// decode, so a server that later grows a third outcome (say `queued`) does
    /// not break a shipped client — the same forward-compat contract the
    /// contracts enums' `.unrecognized` case provides.
    public enum Status: Equatable, Sendable {
        /// The car streamed recently; the server did nothing (no wake spent).
        case fresh
        /// The server woke the car and read it; `lastUpdated` is the new read.
        case refreshed
        /// A status this client build does not know. Never treated as a failure —
        /// the call still returned 200 with an authoritative `lastUpdated`.
        case unrecognized(String)

        public init(rawValue: String) {
            switch rawValue {
            case "fresh": self = .fresh
            case "refreshed": self = .refreshed
            default: self = .unrecognized(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .fresh: "fresh"
            case .refreshed: "refreshed"
            case .unrecognized(let value): value
            }
        }

        /// Whether the server actually spent a wake + read for this call. `false`
        /// for `fresh` (a deliberate no-op) and for anything unrecognized — we
        /// only ever CLAIM a wake we can prove happened.
        public var didWake: Bool { self == .refreshed }
    }

    public var status: Status
    /// The authoritative server read time for the vehicle after this call, parsed
    /// from the contract's RFC3339 string. This is the SAME clock as
    /// `VehicleState.lastUpdated`, so a caller can compare the two directly.
    public var lastUpdated: Date

    public init(status: Status, lastUpdated: Date) {
        self.status = status
        self.lastUpdated = lastUpdated
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case lastUpdated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = Status(rawValue: try container.decode(String.self, forKey: .status))
        let raw = try container.decode(String.self, forKey: .lastUpdated)
        guard let date = RFC3339.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastUpdated,
                in: container,
                debugDescription: "lastUpdated is not an RFC3339 timestamp: \(raw)"
            )
        }
        lastUpdated = date
    }
}

// MARK: - RFC3339 parsing

/// The two RFC3339 shapes the telemetry backend emits — with and without
/// fractional seconds. `ISO8601DateFormatter` will NOT parse a fractional
/// timestamp unless `.withFractionalSeconds` is set, and will not parse a
/// non-fractional one when it IS set, so both are kept and tried in order (the
/// same pair `VehicleContractMapping.parseTimestamp` uses on the app side).
/// The formatters are built PER CALL rather than cached in `static let`s:
/// `ISO8601DateFormatter` is not `Sendable`, so a shared instance would need
/// `nonisolated(unsafe)` to compile in the Kit's Swift 6 language mode — buying a
/// data-race hazard to save an allocation on a path that runs at most once per
/// refresh (a ~60s-cooldown, owner-initiated action).
enum RFC3339 {
    static func date(from value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

// MARK: - Refresh seam

/// The owner on-demand refresh surface (§7.15), factored into its own protocol so
/// callers depend only on "ask the server for something newer" and can be tested
/// with a stub — the same narrowing pattern as ``VehiclePlateEndpoint`` /
/// ``VehicleTeardownEndpoint`` / ``VehicleCommandSending``. `RestClient` is the
/// production conformer.
///
/// Deliberately NOT folded into ``VehicleCommandSending``: a §7.9 command
/// ACTUATES the car (and can be refused by it), while this only asks the server
/// to READ it. Sharing the seam would invite `key_not_paired` / `command_failed`
/// into a surface that cannot produce them.
public protocol VehicleRefreshing: Sendable {
    /// `POST /api/tesla/vehicles/{vehicleId}/refresh` (§7.15) — ask the server for
    /// a newer read of one owned vehicle, waking it if the budget allows.
    /// Owner-authenticated; `{vehicleId}` is the Prisma cuid (NOT a VIN), the same
    /// key as §7.12/§7.14.
    ///
    /// Throws a typed `RestError.http` on any non-2xx: `503 vehicle_asleep` (the
    /// wake budget is spent and the car did not come up), `429 rate_limited` (the
    /// per-vehicle ~60s cooldown), `401 auth_failed`, `403 vehicle_not_owned`,
    /// `404 not_found`. Callers fold these through ``RestError/commandFailureKind``.
    func refreshVehicle(id: String) async throws -> VehicleRefreshResponse
}
