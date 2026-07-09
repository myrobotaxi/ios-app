import Foundation
import MyRobotaxiContracts

/// Bridges the wire (JSON text frames) and the generated contracts types. Owns
/// no shapes of its own — every decode targets a `MyRobotaxiContracts` type and
/// every client→server frame is a generated payload wrapped in the generated
/// `WebSocketEnvelope`.
enum WireCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    enum WireError: Error, Sendable {
        case notUTF8
        case missingPayload
    }

    /// Decode a raw inbound text frame into the top-level envelope
    /// (websocket-protocol.md §3). Unknown top-level keys (e.g. fixtures' `_meta`)
    /// are tolerated per the open-object rule (§3.1).
    static func decodeEnvelope(_ text: String) throws -> WebSocketEnvelope {
        guard let data = text.data(using: .utf8) else { throw WireError.notUTF8 }
        return try decoder.decode(WebSocketEnvelope.self, from: data)
    }

    /// Re-decode an envelope's open `payload` (`JSONValue`) into the concrete
    /// contracts payload type selected by the `type` discriminator.
    static func decodePayload<T: Decodable>(_ type: T.Type, from envelope: WebSocketEnvelope) throws -> T {
        guard let payload = envelope.payload else { throw WireError.missingPayload }
        let data = try encoder.encode(payload)
        return try decoder.decode(T.self, from: data)
    }

    /// Encode a client→server frame (`auth` / `subscribe` / `unsubscribe` /
    /// `ping`) as a `WebSocketEnvelope` around a generated payload.
    static func encodeFrame(type: MessageType, payload: some Encodable) throws -> String {
        let payloadValue = try jsonValue(from: payload)
        let envelope = WebSocketEnvelope(type: type, payload: payloadValue)
        let data = try encoder.encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    /// Round-trip any `Encodable` through JSON into the open `JSONValue`
    /// representation so it can ride in the envelope's `payload` slot.
    private static func jsonValue(from encodable: some Encodable) throws -> JSONValue {
        let data = try encoder.encode(encodable)
        return try decoder.decode(JSONValue.self, from: data)
    }
}
