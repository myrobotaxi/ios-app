import Foundation

/// Async bearer-token source injected into both the REST and WebSocket
/// transports.
///
/// MyRoboTaxi's real auth (MYR-193 — Sign in with Apple + backend token
/// exchange) slots in by conforming a thin adapter to this protocol; the Kit
/// never stores or refreshes credentials itself (FR-6.1: "SDK accepts a
/// `getToken()` callback; SDK never stores credentials").
///
/// `token()` is called on every REST request and on every WebSocket
/// (re)connect, and again after an auth failure so the provider can supply a
/// freshly-refreshed token (FR-6.2). Throwing surfaces as a transport-level auth
/// failure to the caller.
public protocol TokenProvider: Sendable {
    func token() async throws -> String

    /// Called by the transport after a Bearer request was rejected with `401`,
    /// handing back the exact token that failed. A stateful provider (e.g.
    /// ``SessionTokenProvider``) should discard that token so the transport's
    /// single retry — which asks for `token()` again — forces a refresh (FR-6.2,
    /// rest-api.md §7.10 "one refresh + retry"). The default is a no-op, so
    /// fixed-token providers are unaffected.
    func invalidate(rejectedToken: String) async
}

public extension TokenProvider {
    func invalidate(rejectedToken: String) async {}
}

/// A fixed-token provider — useful for SwiftUI previews, tests, and bring-up
/// before the real `AuthSession` adapter (MYR-193) exists.
public struct StaticTokenProvider: TokenProvider {
    public let value: String
    public init(_ value: String) { self.value = value }
    public func token() async throws -> String { value }
}
