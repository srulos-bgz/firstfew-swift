import Foundation
import Security

/// End-user identity.
///
/// The user id lives in the Keychain, so it survives an uninstall/reinstall —
/// a reinstall does NOT count as a new user. It is not synchronized to iCloud
/// Keychain: each device counts as its own user. A separate install marker lives
/// in UserDefaults, which is wiped on uninstall — "Keychain has an id but the
/// marker is gone" therefore means the app was reinstalled.
final class Identity {
    let userID: String
    let isReinstall: Bool

    private static let service = "com.firstfew.sdk"
    private static let account = "user_id"
    private static let installMarkerKey = "com.firstfew.sdk.installed"

    init() {
        let defaults = UserDefaults.standard
        let markerPresent = defaults.bool(forKey: Self.installMarkerKey)
        if let existing = Self.keychainRead() {
            userID = existing
            isReinstall = !markerPresent
        } else {
            let fresh = UUID().uuidString.lowercased()
            Self.keychainWrite(fresh)
            userID = fresh
            isReinstall = false
        }
        if !markerPresent {
            defaults.set(true, forKey: Self.installMarkerKey)
        }
    }

    /// Read-only lookup of the stored user id. Unlike `init`, this never creates an
    /// id and never touches the install marker, so calling it at any time (even
    /// before `configure`) cannot break reinstall detection.
    static func existingUserID() -> String? { keychainRead() }

    private static func keychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func keychainWrite(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock: readable during background launches once the device has
        // been unlocked. Not marked synchronizable — never enters iCloud Keychain.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
