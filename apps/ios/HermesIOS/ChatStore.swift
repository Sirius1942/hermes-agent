import Foundation

@MainActor
final class ChatStore: HermesChatStore {
    private let keychain: KeychainStore

    init() {
        let keychain = KeychainStore()
        self.keychain = keychain
        super.init(
            source: "ios",
            gateway: HermesGateway(clientID: "ios"),
            loadStoredToken: { keychain.load() },
            saveStoredToken: { try keychain.save(token: $0) }
        )
    }

    init(gateway: HermesGateway) {
        let keychain = KeychainStore()
        self.keychain = keychain
        super.init(
            source: "ios",
            gateway: gateway,
            loadStoredToken: { keychain.load() },
            saveStoredToken: { try keychain.save(token: $0) }
        )
    }
}
