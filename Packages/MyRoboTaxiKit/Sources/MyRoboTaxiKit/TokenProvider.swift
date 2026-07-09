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
}

/// A fixed-token provider — useful for SwiftUI previews, tests, and bring-up
/// before the real `AuthSession` adapter (MYR-193) exists.
public struct StaticTokenProvider: TokenProvider {
    public let value: String
    public init(_ value: String) { self.value = value }
    public func token() async throws -> String { value }
}
