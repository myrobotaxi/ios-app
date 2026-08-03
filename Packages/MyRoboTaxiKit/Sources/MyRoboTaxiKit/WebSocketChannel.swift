import Foundation
import os

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

    /// MYR-432 — the RFC 6455 close code the PEER closed with, readable once
    /// ``receive()`` has failed. `nil` when the socket did not close with a code
    /// at all (a transport error, a local cancel, or a channel that cannot
    /// report one).
    ///
    /// Separate from the `receive()` error rather than folded into it because a
    /// close code is a fact about the CONNECTION, not about the read that
    /// happened to notice — and because `URLSession` reports it on the task after
    /// the fact rather than as part of the thrown error.
    func closeCode() async -> Int?
}

public extension WebSocketChannel {
    /// Default for channels that cannot report one. A channel that says nothing
    /// is treated exactly as this client always treated every close: TRANSIENT.
    func closeCode() async -> Int? { nil }
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
        // MYR-227 — URLSession can invoke the pong handler TWICE when a pong
        // races a cancellation/teardown error (observed on-device: fatal
        // CheckedContinuation double-resume, crash report 2026-07-10-004939).
        // The lock guarantees the continuation resumes exactly once; a second
        // invocation is dropped.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                let isFirst = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard isFirst else { return }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    /// MYR-432 — the peer's close code, read off the task after the fact.
    ///
    /// `URLSessionWebSocketTask.CloseCode` is an imported `NS_ENUM`, so a
    /// server-defined 4xxx code has no Swift case; only its `rawValue` is read
    /// here, never a case match, which is what makes the private-use range
    /// (4000–4999 — where §6.2's `4002` lives) legible at all. `.invalid` (0) is
    /// "no close frame was received" and maps to `nil` rather than to `0`, so an
    /// ordinary transport failure is never mistaken for a coded close.
    func closeCode() -> Int? {
        let raw = task.closeCode.rawValue
        return raw == URLSessionWebSocketTask.CloseCode.invalid.rawValue ? nil : raw
    }

    private func resumeIfNeeded() {
        guard !didResume else { return }
        didResume = true
        task.resume()
    }
}
