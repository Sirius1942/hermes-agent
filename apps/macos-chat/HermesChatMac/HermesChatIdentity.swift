import Foundation

enum HermesChatIdentity {
    static let productID = "hermes-chat-macos"
    static let bundleIdentifier = "com.nousresearch.hermes.chat.macos"
    static let preferencesSuite = "com.nousresearch.hermes.chat.macos.preferences"
    static let keychainService = "com.nousresearch.hermes.chat.macos.keychain"
    static let urlScheme = "hermes-chat"
    static let autoStartLocalHermesKey = "autoStartLocalHermes"
    static let localHermesExecutablePathKey = "localHermesExecutablePath"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: preferencesSuite) ?? .standard
    }
}
