import Foundation

/// Server coordinates for one MyRoboTaxi backend environment. Bundles the REST
/// base URL and the WebSocket URL so a single value configures both transports
/// (rest-api.md §2.1 and websocket-protocol.md §1.1 — REST and WS share a host).
public struct BackendEnvironment: Sendable, Equatable {
    /// REST base, including the `/api` mount (rest-api.md §2.1). Endpoint path
    /// segments are appended to this (e.g. `vehicles`, `vehicles/{id}/snapshot`).
    public var restBaseURL: URL
    /// Full WebSocket URL, including the `/api/ws` path (websocket-protocol.md §1.1).
    public var webSocketURL: URL
    /// When false (production default) the REST client refuses any non-TLS,
    /// non-loopback host (rest-api.md §3.4 / §1.2). Plain `http://localhost` is
    /// permitted only when this is true (local dev).
    public var allowsInsecureLoopback: Bool

    public init(restBaseURL: URL, webSocketURL: URL, allowsInsecureLoopback: Bool = false) {
        self.restBaseURL = restBaseURL
        self.webSocketURL = webSocketURL
        self.allowsInsecureLoopback = allowsInsecureLoopback
    }

    /// Production: `https://api.myrobotaxi.com/api` + `wss://api.myrobotaxi.com/api/ws`
    /// (rest-api.md §2.1, websocket-protocol.md §1.1).
    public static let production = BackendEnvironment(
        restBaseURL: URL(string: "https://api.myrobotaxi.com/api")!,
        webSocketURL: URL(string: "wss://api.myrobotaxi.com/api/ws")!,
        allowsInsecureLoopback: false
    )

    /// Local dev: `http://localhost:8080/api` + `ws://localhost:8080/api/ws`
    /// (rest-api.md §2.1 dev row). Plain HTTP is allowed only against loopback.
    public static func localhost(port: Int = 8080) -> BackendEnvironment {
        BackendEnvironment(
            restBaseURL: URL(string: "http://localhost:\(port)/api")!,
            webSocketURL: URL(string: "ws://localhost:\(port)/api/ws")!,
            allowsInsecureLoopback: true
        )
    }
}
