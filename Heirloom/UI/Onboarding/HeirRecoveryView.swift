import SwiftUI
import BitcoinDevKit

/// Guided recovery flow for heirs. Written for someone who has never used
/// Bitcoin: paste the kit, type the 12 words, and the app does the rest.
struct HeirRecoveryView: View {
    @EnvironmentObject var manager: WalletManager

    enum Step { case intro, kit, seed, working }

    @State private var step: Step = .intro
    @State private var kitText = ""
    @State private var kit: RecoveryKit?
    @State private var kitError: String?
    @State private var seedText = ""
    @State private var seedError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch step {
                case .intro: intro
                case .kit: kitEntry
                case .seed: seedEntry
                case .working:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Rebuilding the wallet and checking the Bitcoin network…\nThis can take a minute.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
            }
            .padding()
        }
        .navigationTitle("Heir recovery")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claiming an inheritance").font(.title2.bold())
            Text("We're sorry for whatever brings you here. This process is designed to be simple and safe. You cannot break anything by trying.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                stepRow(1, "Find your two documents", "You need the “Heir Recovery Kit” (a printed page or file the owner left for you) and your own 12-word recovery phrase (usually on paper).")
                stepRow(2, "Paste the kit", "On the next screen, type or paste the kit code — the block of text between the dashed lines on the kit document.")
                stepRow(3, "Enter your 12 words", "Type your recovery phrase. It never leaves this phone.")
                stepRow(4, "Wait for the countdown (maybe)", "If the owner was recently active, a waiting period may still be running. The app will show you exactly when you can claim.")
                stepRow(5, "Claim", "When the countdown reaches zero, the app moves the funds to a wallet only you control.")
            }

            WarningBox(
                title: "No rush, no tricks",
                message: "Take your time. Never share your 12 words with anyone — not family, not “support staff”, nobody. Heirloom has no support team that would ever ask for them."
            )

            Button("Start") { step = .kit }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func stepRow(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.2), in: Circle())
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var kitEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste the recovery kit").font(.title2.bold())
            Text("Copy everything between the dashed lines on the kit document — it starts with a { and ends with a } — and paste it here.")
                .font(.callout).foregroundStyle(.secondary)

            TextEditor(text: $kitText)
                .font(.footnote.monospaced())
                .frame(minHeight: 180)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if let kitError {
                Text(kitError).font(.footnote).foregroundStyle(Theme.danger)
            }

            Button("Check the kit") {
                do {
                    let parsed = try RecoveryKit.decode(fromJSON: kitText.trimmingCharacters(in: .whitespacesAndNewlines))
                    kit = parsed
                    kitError = nil
                    step = .seed
                } catch {
                    kitError = "That doesn't look like a valid recovery kit. Make sure you copied the whole code, including the { and } braces."
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var seedEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your 12 words").font(.title2.bold())
            if let kit {
                Label("Kit accepted — waiting period: \(Format.blocksAsDuration(kit.delayBlocks))", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.ok)
            }
            Text("Type your recovery phrase in order, separated by spaces. Lowercase, no punctuation.")
                .font(.callout).foregroundStyle(.secondary)

            TextEditor(text: $seedText)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            WarningBox(
                title: "Your words stay here",
                message: "The phrase is stored only in this phone's secure keychain and is used only to sign your claim. It is never uploaded anywhere.",
                severity: .warning
            )

            if let seedError {
                Text(seedError).font(.footnote).foregroundStyle(Theme.danger)
            }

            Button("Recover wallet") { recover() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func recover() {
        guard let kit else { return }
        step = .working
        seedError = nil
        Task {
            do {
                let mnemonic = try KeyService.parseMnemonic(seedText)
                try await manager.recoverAsHeir(kit: kit, heirMnemonic: mnemonic)
                // RootView switches to HomeView via manager.phase.
            } catch HeirloomError.invalidMnemonic {
                seedError = "These words don't match the heir key in the kit (expected key fingerprint \(kit.heirFingerprint)). Check the word order and spelling — or this kit may belong to a different phrase."
                step = .seed
            } catch {
                seedError = error.localizedDescription
                step = .seed
            }
        }
    }
}
