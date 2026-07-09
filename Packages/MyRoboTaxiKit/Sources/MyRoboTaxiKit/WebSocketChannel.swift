import Foundation

/// The minimal duplex-socket capability the telemetry actor needs, abstracted so
/// the reconnect / backoff state machine can be exercised against a scripted
/// mock with no network (Rules: "No network calls in tests"). Conformers are
/// `Sendable` — actors satisfy this — and the production conformer wraps a
/// `URLSessionWebSocketTask`.
public protocol WebSocketChannel: Sendable {
    /// Send one text frame.
    func send(_ text: String) async throws
    /// Await the next inbound text frame. Throws on close / transport error,
    /// which the caller treats as a disconnect.
    func receive() async throws -> String
    /// RFC 6455 transport-level PING keepalive (websocket-protocol.md §3.4 / §7.4).
    func ping() async throws
    /// Close the socket. Idempotent; makes any pending ``receive()`` throw.
    func close() async
}

/// Creates a fresh channel per connection attempt. Injectable so tests hand the
/// socket a sequence of scripted channels.
public protocol WebSocketChannelFactory: Sendable {
    func makeChannel(url: URL) -> any WebSocketChannel
}

// MARK: - URLSession-backed production implementation

/// Factory that mints `URLSessionWebSocketTask`-backed channels on a shared,
/// lifecycle-tuned session (swift-lifecycle.md §4).
public final class URLSessionWebSocketChannelFactory: WebSocketChannelFactory {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = URLSessionWebSocketChannelFactory.defaultConfiguration()) {
        self.session = URLSession(configuration: configuration)
    }

    public func makeChannel(url: URL) -> any WebSocketChannel {
        URLSessionWebSocketChannel(task: session.webSocketTask(with: url))
    }

    /// `waitsForConnectivity` + `.handover` multipath so the socket survives a
    /// WiFi↔cellular switch (swift-lifecycle.md §4). No request timeout — WS
    /// liveness is governed by the §7.4.1 watchdog, not URLSession timeouts.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.multipathServiceType = .handover
        return configuration
    }
}

/// Actor wrapper isolating a single `URLSessionWebSocketTask`. Being an actor
/// makes it `Sendable` and serializes all access to the non-Sendable task.
actor URLSessionWebSocketChannel: WebSocketChannel {
    private let task: URLSessionWebSocketTask
    private var didResume = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        resumeIfNeeded()
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        resumeIfNeeded()
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func ping() async throws {
        resumeIfNeeded()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    private func resumeIfNeeded() {
        guard !didResume else { return }
        didResume = true
        task.resume()
    }
}
