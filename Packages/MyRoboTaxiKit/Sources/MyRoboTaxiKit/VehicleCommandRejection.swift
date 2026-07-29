import Foundation

/// Why the car refused a §7.9 command, when the server was able to say (MYR-329).
///
/// A `502 command_failed` means we reached the vehicle and it said no. Until
/// MYR-329 that was all anyone downstream could know, so the owner app could
/// only offer "The car didn't accept that" — which on Jul 28 left a TestFlight
/// owner guessing that his battery was too low when the real cause was that his
/// car was sitting in service mode.
///
/// The server now names the cause when it recognizes one. It does NOT forward
/// Tesla's own words: the tesla-http-proxy relays the car's firmware prose
/// (`"car could not execute command: …"`), which is unstable and untranslated,
/// so the server matches it against a closed allow-list and emits one of these
/// canonical tokens inside the free-text `error.message` (rest-api.md §7.9
/// "Naming the rejection reason on `command_failed`"):
///
///     {"error": {"code": "command_failed",
///                "message": "vehicle command failed: vehicle_in_service"}}
///
/// **This is the one place a caller may read `error.message`** — and only to
/// look for a token from this closed set, never to display the sentence or
/// branch on its prose. The Kit's general rule stands everywhere else
/// (`RestError`, FR-7.1): the human message is not a contract.
///
/// The set is **append-only** and grows server-side ahead of any given app
/// build, so an unrecognized message parses to `nil` and the caller MUST fall
/// back to its generic copy. That is why this is an `Optional` everywhere
/// rather than an `unknown` case: "we don't know why" and "we know it was X"
/// are genuinely different, and only the first one is safe to guess from.
public enum VehicleCommandRejectionReason: String, Sendable, Equatable, CaseIterable {
    /// The car is in service mode; Tesla refuses most remote commands while a
    /// service visit is open. The client's own Jul 28 case.
    case vehicleInService = "vehicle_in_service"
    /// The car wants a confirmation on its own touchscreen first.
    case requiresUserAcknowledgement = "requires_user_acknowledgement"
    /// The command needs someone in the driver's seat.
    case userNotPresent = "user_not_present"
    /// Remote/mobile access is switched off in the car's own settings.
    case remoteAccessDisabled = "remote_access_disabled"
    /// The pack is too low for the requested action.
    case lowBattery = "low_battery"
    /// The car is mid-something and declined to queue. Genuinely transient.
    case vehicleBusy = "vehicle_busy"

    /// Recover the reason from a `command_failed` server message, or `nil` when
    /// the message names none this build knows.
    ///
    /// Matching is a substring scan for the token rather than a parse of the
    /// documented `"<sentence>: <token>"` layout, so a server-side reword of the
    /// leading sentence cannot silently drop every owner back to generic copy.
    /// The tokens are snake_case identifiers precisely so prose cannot contain
    /// one by accident, and no token is a substring of another — both properties
    /// are asserted in `VehicleCommandRejectionTests`.
    public init?(serverMessage: String) {
        let haystack = serverMessage.lowercased()
        guard let match = Self.allCases.first(where: { haystack.contains($0.rawValue) }) else {
            return nil
        }
        self = match
    }
}

public extension RestError {
    /// The car's stated reason for refusing a §7.9 command, when there is one.
    ///
    /// Non-`nil` only for a `command_failed` rejection carrying a token this
    /// build recognizes. Every other failure — a transport drop, an asleep car,
    /// a scope problem — is `nil`: those are not the car refusing, and each
    /// already has its own precise outcome on `commandFailureKind`, which this
    /// property deliberately does not duplicate or override.
    var commandRejectionReason: VehicleCommandRejectionReason? {
        guard case .http(_, _, let message?, _) = self else { return nil }
        guard commandFailureKind == .commandFailed else { return nil }
        return VehicleCommandRejectionReason(serverMessage: message)
    }
}
