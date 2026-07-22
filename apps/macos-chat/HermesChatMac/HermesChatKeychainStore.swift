import Foundation
import Security

final class HermesChatKeychainStore {
    private let service: String
    private let account: String

    init(
        service: String = HermesChatIdentity.keychainService,
        account: String = "gateway-token"
    ) {
        self.service = service
        self.account = account
    }

    func save(token: String) throws {
        let query = baseQuery
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HermesChatKeychainError(status: status)
        }
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct HermesChatKeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        "macOS Keychain 写入失败（\(status)）"
    }
}
