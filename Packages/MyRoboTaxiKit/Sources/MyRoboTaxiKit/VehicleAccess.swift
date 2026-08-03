import Foundation

/// MYR-432 — the WebSocket close codes this client gives MEANING to.
///
/// Everything not named here is TRANSIENT by definition and keeps
/// ``TelemetrySocket``'s ordinary supervise/backoff behaviour byte-identical.
/// That default is deliberate: the server may add codes at any time, and a
/// client that guessed at an unknown one would stop reconnecting for a reason
/// nobody wrote down.
public enum TelemetryCloseCode {
    /// §6.2 — the owner revoked or suspended this viewer's grant, and the server
    /// closed the socket rather than leaving a stream running over an access set
    /// the connection no longer has (websocket-protocol.md §10 DV-09, closed
    /// server-side in telemetry PR #369).
    ///
    /// **IT IS AN ACCESS SIGNAL, NOT A FAILURE.** The JWT is still valid, the
    /// network is fine, and the very next handshake succeeds — with a REDUCED
    /// vehicle set. A client that reads it as transport churn re-handshakes, has
    /// its `attempt` counter reset by `auth_ok` so backoff never escalates, and
    /// re-subscribes the vehicle that caused the close: a permanent ~1s loop plus
    /// one `403` snapshot read per cycle, for as long as the app is open.
    public static let permissionRevoked = 4002

    /// Whether a close code is the access signal above.
    ///
    /// A free function rather than an `Int` comparison at each call site so the
    /// set of ACCESS codes is one list. `nil` — a transport error with no close
    /// frame at all — is never an access signal.
    public static func isAccessSignal(_ code: Int?) -> Bool {
        code == permissionRevoked
    }
}

/// MYR-432 — the authoritative answer to "which vehicles may this account see
/// right now", as one set of ids.
///
/// **THE `auth_ok` FRAME CANNOT ANSWER THIS AND IS NOT MEANT TO.** Its
/// `vehicleCount` is documented as an "informational integrity check", and the
/// contract says in as many words that "the authoritative ownership set is
/// populated via the REST snapshot fetch on reconnect (NFR-3.11)". So the access
/// set a post-4002 handshake resolves is `GET /api/vehicles` read AT that
/// handshake — the same list every other surface in the app treats as the truth
/// about access (MYR-369: a suspended grant is enforced by the car simply
/// LEAVING that list).
///
/// A separate seam rather than a method on ``SnapshotFetching`` because the two
/// answer different questions — one is a vehicle's STATE, this is the account's
/// ACCESS — and because a consumer that only streams telemetry should not be
/// obliged to supply a fleet list. It is optional on ``TelemetrySocket``: with no
/// listing the socket still stands down (it stops resetting its backoff on a
/// repeated access close), it simply cannot name which vehicle to prune.
public protocol VehicleAccessListing: Sendable {
    /// `GET /api/vehicles`, reduced to the ids. Throws exactly as the list read
    /// throws — a read that FAILED is never evidence that access was lost.
    func accessibleVehicleIDs() async throws -> Set<String>
}

/// MYR-432 — one pruning event: the vehicles this connection lost, and the ones
/// it kept.
///
/// `remaining` is carried alongside `revoked` deliberately. A viewer revoked from
/// one of two cars must keep the other streaming seamlessly, so the consumer's
/// question is almost never "what went" on its own — it is "what is left", which
/// is what decides whether the surface releases or simply narrows.
public struct VehicleAccessRevocation: Sendable, Equatable {
    /// Vehicles that were subscribed and are absent from the new access set.
    /// Never empty — a revocation with nothing in it is not published.
    public let revoked: Set<String>
    /// The subscriptions that survived the prune.
    public let remaining: Set<String>

    public init(revoked: Set<String>, remaining: Set<String>) {
        self.revoked = revoked
        self.remaining = remaining
    }
}
