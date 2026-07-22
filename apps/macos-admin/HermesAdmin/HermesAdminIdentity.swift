import Foundation

enum HermesAdminIdentity {
    static let productID = "hermes-admin-macos"
    static let bundleIdentifier = "com.nousresearch.hermes.admin.macos"
    static let preferencesSuite = "com.nousresearch.hermes.admin.macos.preferences"
    static let keychainService = "com.nousresearch.hermes.admin.macos.keychain"
    static let urlScheme = "hermes-admin"
    static let configurationKey = "HermesAdmin.Configuration"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: preferencesSuite) ?? .standard
    }
}
