import SwiftUI
import LocalAuthentication

struct SettingsView: View {
    @EnvironmentObject var manager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var esploraURL = ""
    @State private var endpointMessage: String?
    @State private var endpointOK = false

    @State private var showSeed = false
    @State private var revealedWords: [String] = []
    @State private var seedError: String?

    @State private var confirmWipe = false
    @State private var wipeText = ""

    var body: some View {
        NavigationStack {
            Form {
                walletSection
                serverSection
                backupSection
                aboutSection
                dangerSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { esploraURL = manager.meta?.esploraURL ?? "" }
        }
    }

    private var walletSection: some View {
        Section("Wallet") {
            LabeledContent("Role", value: manager.meta?.role == .owner ? "Owner" : "Heir")
            LabeledContent("Network", value: manager.meta?.network.displayName ?? "—")
            LabeledContent("Inheritance delay", value: "\(manager.meta?.delayBlocks ?? 0) blocks (~\(Format.blocksAsDuration(manager.meta?.delayBlocks ?? 0)))")
            LabeledContent("Plan", value: manager.meta?.tier == .pro ? "Pro" : "Free")
            LabeledContent("Key fingerprint", value: manager.meta?.localFingerprint ?? "—")
            if let descriptors = manager.service?.publicDescriptors() {
                NavigationLink("Watch-only descriptors") {
                    ScrollView {
                        VStack(spacing: 12) {
                            CopyableText(label: "External (receive)", value: descriptors.external)
                            CopyableText(label: "Internal (change)", value: descriptors.change)
                            Text("These descriptors let auditing tools (Sparrow, Bitcoin Core) watch this wallet without any spending power.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .navigationTitle("Descriptors")
                }
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("https://mempool.space/signet/api", text: $esploraURL)
                .font(.footnote.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Save server") {
                do {
                    try manager.updateEsploraURL(esploraURL.trimmingCharacters(in: .whitespaces))
                    endpointMessage = "Saved. Future syncs use this server."
                    endpointOK = true
                } catch {
                    endpointMessage = error.localizedDescription
                    endpointOK = false
                }
            }
            if let endpointMessage {
                Text(endpointMessage)
                    .font(.caption)
                    .foregroundStyle(endpointOK ? Theme.ok : Theme.danger)
            }
        } header: {
            Text("Esplora server")
        } footer: {
            Text("The server is only asked about addresses and transactions — it never sees your keys. It CAN see which addresses you're interested in (a privacy, not security, consideration). Any Esplora-compatible endpoint works, including your own.")
        }
    }

    private var backupSection: some View {
        Section {
            Button(showSeed ? "Hide recovery phrase" : "Reveal recovery phrase…") {
                if showSeed {
                    showSeed = false
                    revealedWords = []
                } else {
                    revealSeed()
                }
            }
            if let seedError {
                Text(seedError).font(.caption).foregroundStyle(Theme.danger)
            }
            if showSeed {
                WarningBox(
                    title: "You are showing your master secret",
                    message: "Make sure nobody can see the screen and no screen recording or mirroring is active. Anyone who copies these words controls the funds.",
                    severity: .critical
                )
                SeedPhraseGrid(words: revealedWords)
                    .privacySensitive()
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("The phrase is protected by \(LAContext().biometryType == .faceID ? "Face ID" : "device authentication") and never leaves the secure keychain.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            Link("Source code (GitHub)", destination: URL(string: "https://github.com/far1z/heirloom-ios")!)
            Link("Security policy", destination: URL(string: "https://github.com/far1z/heirloom-ios/blob/main/SECURITY.md")!)
            LabeledContent("Audit status", value: "Internal review only")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Delete wallet from this device", role: .destructive) {
                confirmWipe = true
            }
            .confirmationDialog(
                "This removes the keys and wallet data from THIS DEVICE ONLY. The coins stay on the Bitcoin network — without your paper backup they will be UNRECOVERABLE by you (your heir's claim still works).",
                isPresented: $confirmWipe,
                titleVisibility: .visible
            ) {
                Button("I have my paper backup — delete", role: .destructive) {
                    manager.wipeWallet()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        } header: {
            Text("Danger zone")
        }
    }

    private func revealSeed() {
        seedError = nil
        let context = LAContext()
        var authError: NSError?
        let reason = "Authenticate to reveal your recovery phrase."
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // Simulator or devices with no passcode: fail closed with an explanation.
            seedError = "Set a device passcode to protect and reveal the phrase."
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                guard success else {
                    seedError = "Authentication failed."
                    return
                }
                do {
                    let key: KeychainStore.Key = manager.meta?.role == .owner ? .ownerMnemonic : .heirMnemonic
                    let mnemonic = try KeyService.loadMnemonic(key)
                    revealedWords = mnemonic.description.split(separator: " ").map(String.init)
                    showSeed = true
                } catch {
                    seedError = error.localizedDescription
                }
            }
        }
    }
}
