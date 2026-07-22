import SwiftUI

@main
struct HermesIOSApp: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
