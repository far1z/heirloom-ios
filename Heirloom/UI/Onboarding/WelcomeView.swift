import SwiftUI

struct WelcomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Theme.accent)
                Text("Heirloom")
                    .font(.largeTitle.bold())
                Text("Bitcoin inheritance without custodians.\nYour keys. Your heir's future. Enforced by the Bitcoin network itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

                WarningBox(
                    title: "Test network build",
                    message: "This build runs on Bitcoin signet — coins have no value. Heirloom has not been independently audited. Do not use it for real funds."
                )
                .padding(.horizontal)

                VStack(spacing: 12) {
                    NavigationLink {
                        OwnerWizardView()
                    } label: {
                        Text("Set up an inheritance wallet")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    NavigationLink {
                        HeirRecoveryView()
                    } label: {
                        Text("I am an heir")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
    }
}
