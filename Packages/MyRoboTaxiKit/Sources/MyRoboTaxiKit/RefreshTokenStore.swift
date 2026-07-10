import Foundation
import Security

/// The narrow secure-storage capability ``SessionTokenProvider`` needs for the
/// refresh token: read / write / clear one opaque string. Abstracted behind a
/// protocol so the state-machine tests fake it in memory (Rule: "No Keychain in
/// unit tests") while production uses the real Keychain conformer below.
///
/// The **access** token is deliberately NOT stored here — it lives in memory
/// only (rest-api.md §7.10 session contract). Only the long-lived refresh token
/// is persisted, and only in the Keychain.
public protocol RefreshTokenStore: Sendable {
    /// The stored refresh token, or `nil` when none is present (signed out).
    func read() throws -> String?
    /// Persist (overwrite) the refresh token.
    func write(_ token: String) throws
    /// Remove the stored refresh token (sign-out).
    func clear() throws
}

/// Keychain-backed ``RefreshTokenStore`` — a single generic-password item
/// keyed by service + account. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// available after the first unlock following a boot (so a background proactive
/// refresh works), never migrated to a new device via encrypted backup (a
/// refresh token is a device-bound credential).
public struct KeychainRefreshTokenStore: RefreshTokenStore {
    private let service: String
    private let account: String

    /// - Parameters:
    ///   - service: Keychain service key. Defaults to the app's session service.
    ///   - account: Account within the service. Defaults to `refreshToken`.
    public init(service: String = "app.myrobotaxi.session", account: String = "refreshToken") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func write(_ token: String) throws {
        let data = Data(token.utf8)
        // Update-in-place if present, else add. Two-step keeps the accessibility
        // attribute authoritative and avoids a delete/add race.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        throw KeychainError(status: updateStatus)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// A Keychain OSStatus failure (read/write/clear). Carries the raw status so a
/// caller can log it; the value is a device-side code, never a credential.
public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}
