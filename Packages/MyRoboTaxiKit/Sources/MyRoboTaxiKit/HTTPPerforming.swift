import Foundation

/// The single URLSession capability the REST client needs, abstracted so tests
/// can inject a deterministic transport with no network (Rules: "No network
/// calls in tests"). `URLSession` conforms out of the box.
public protocol HTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPPerforming {}
