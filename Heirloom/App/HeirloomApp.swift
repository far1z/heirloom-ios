import SwiftUI

@main
struct HeirloomApp: App {
    @StateObject private var manager = WalletManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        }
    }
}
