import Foundation
import Security

/// The one Keychain item every source's token lives in (S4-18): a generic
/// password in the login keychain, service `<bundle identifier>.sources`,
/// account `tokens`, labelled *uDeck: tokens for plugin sources*. A
/// file-based keychain item, with no data-protection access group: an
/// ad-hoc signed app has no entitlement for one.
///
/// The only file in uDeck that imports Security — a test reads the sources
/// to hold that. Its calls may block while macOS asks the person whether
/// uDeck may use the item, which it does once after every update of an
/// ad-hoc signed app; `CredentialVault` makes them off the main actor. No
/// test calls it: tests give the vault a fake `CredentialStore`.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public static let account = "tokens"
    public static let label = "uDeck: tokens for plugin sources"

    /// The item of the app whose bundle identifier is `bundleIdentifier` —
    /// a debug build's is its own.
    public init(bundleIdentifier: String) {
        self.service = "\(bundleIdentifier).sources"
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    public func read() throws(CredentialStoreError) -> Data? {
        var asked = query
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(asked as CFDictionary, &found)
        switch status {
        case errSecSuccess:
            guard let data = found as? Data else { throw CredentialStoreError("the item holds no data") }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status)
        }
    }

    public func write(_ data: Data, exists: Bool) throws(CredentialStoreError) {
        let status: OSStatus
        if exists {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = Self.label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    public func delete() throws(CredentialStoreError) {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    /// What the Keychain said, in its own words and its number.
    static func error(_ status: OSStatus) -> CredentialStoreError {
        let words = SecCopyErrorMessageString(status, nil) as String? ?? "an error"
        return CredentialStoreError("\(words) (\(status))")
    }
}
