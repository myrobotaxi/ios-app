import Foundation
import MyRobotaxiContracts

/// Typed error surface for the REST client. Lean by design — no port of the
/// server's full error catalog. Consumers branch on the case; when the server
/// returned a structured `{ "error": { … } }` envelope (rest-api.md §4.1),
/// `.http` carries the typed `ErrorPayload.Code` so callers never string-match
/// the human `message` (FR-7.1).
public enum RestError: Error, Sendable {
    /// The environment forbids this URL (e.g. plaintext HTTP against a
    /// non-loopback host — rest-api.md §3.4).
    case insecureTransport(URL)
    /// The response was not an `HTTPURLResponse`, or carried no status line.
    case invalidResponse
    /// A non-2xx HTTP response. `code` / `message` / `subCode` are populated from
    /// the error envelope (rest-api.md §4.1) when the body parsed.
    case http(status: Int, code: ErrorPayload.Code?, message: String?, subCode: ErrorPayload.SubCode?)
    /// `POST /api/ride-requests` was refused `409 ride_active` (rest-api.md §7.8,
    /// MYR-230): the rider already holds an OPEN instant ride, so the create was
    /// rejected. Unlike every other error, this 409 body augments the standard
    /// envelope with a sibling `activeRideRequest` — the rider's existing open
    /// ride — so the client ADOPTS it into the pending/tracking UI rather than
    /// surfacing a decline. `active` is that ride, or `nil` in the rare
    /// terminal-race case where the server omits the sibling (or a contracts build
    /// without the field) — the client then refetches its own open list (§7.8).
    case rideActive(active: RideRequest?)
    /// The 2xx body failed to decode into the expected contracts type.
    case decoding(underlying: any Error)
    /// URLSession / connectivity failure before a response was formed.
    case transport(underlying: any Error)

    /// True when the failure is a typed auth rejection the consumer's auth layer
    /// should act on (trigger a fresh sign-in) rather than silently retry.
    public var isAuthFailure: Bool {
        if case .http(_, let code, _, _) = self { return code == .authFailed || code == .authTimeout }
        return false
    }

    /// The HTTP status, when the error is an `.http` response.
    public var httpStatus: Int? {
        if case .http(let status, _, _, _) = self { return status }
        return nil
    }

    /// MYR-233 — `409 vehicle_unavailable` (MYR-277): the target vehicle can't
    /// take this ride right now (it already carries an open instant ride, or it
    /// is in service / offline), so the server refused the create or accept.
    /// Semantically distinct from the generic `conflict` (an illegal STATUS
    /// TRANSITION) and from `rideActive` (the RIDER already holds an open ride):
    /// this one is about the VEHICLE, and the honest response is to point the
    /// rider at scheduling — never a silent retry, which would just 409 again.
    ///
    /// The shared contracts `ErrorPayload.Code` enum does not carry
    /// `vehicle_unavailable` as of 0.14.0, so it decodes to
    /// `.unrecognized("vehicle_unavailable")`. Matching the typed code's RAW
    /// WIRE VALUE (never the human `message` — FR-7.1) is exactly the
    /// forward-compat contract `.unrecognized` exists for, and follows the
    /// precedent `RestClient.mapError` set for `ride_active`. A later additive
    /// contracts entry promotes it to a real case and this keeps working
    /// unchanged, because the promoted case's `rawValue` is the same string.
    public var isVehicleUnavailable: Bool {
        guard case .http(let status, let code, _, _) = self else { return false }
        return status == 409 && code?.rawValue == "vehicle_unavailable"
    }
}
