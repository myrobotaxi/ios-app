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
}
