import SwiftUI

struct RootView: View {
    @EnvironmentObject var manager: WalletManager

    var body: some View {
        Group {
            switch manager.phase {
            case .loading:
                ProgressView("Loading wallet…")
            case .onboarding:
                WelcomeView()
            case .ready:
                HomeView()
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.danger)
                    Text("Could not open the wallet")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await manager.bootstrap() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 40)
                }
                .padding()
            }
        }
        .tint(Theme.accent)
        .task { await manager.bootstrap() }
    }
}
