import SwiftUI

/// The heir's claim flow. Sweeps every matured UTXO through the timelocked
/// branch to an address the heir controls.
struct ClaimView: View {
    @EnvironmentObject var manager: WalletManager
    @Environment(\.dismiss) private var dismiss

    enum Stage { case explain, form, review, broadcasting, done(String), failed(String) }

    @State private var stage: Stage = .explain
    @State private var address = ""
    @State private var formError: String?
    @State private var prepared: PreparedTransaction?

    private var canClaim: Bool { manager.lockStatus?.heirCanClaim == true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch stage {
                    case .explain: explain
                    case .form: form
                    case .review: review
                    case .broadcasting:
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Claiming your inheritance…").font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 60)
                    case .done(let txid): done(txid)
                    case .failed(let message):
                        WarningBox(title: "Claim failed", message: message, severity: .critical)
                        Button("Back") { stage = .explain }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding()
            }
            .navigationTitle("Claim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
    }

    private var explain: some View {
        VStack(alignment: .leading, spacing: 16) {
            if canClaim {
                Label("You can claim now", systemImage: "checkmark.seal.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.ok)
                Text("The waiting period has fully elapsed. The Bitcoin network will now accept a transaction signed with your key.")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What happens next").font(.subheadline.weight(.semibold))
                    Text("1. You tell us where to send the funds — ideally a wallet whose recovery phrase only YOU hold (this app, or any Bitcoin wallet).\n2. We build and sign the claim with your key, on this phone.\n3. The network confirms it, usually within the hour.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Start claim") { stage = .form }
                    .buttonStyle(PrimaryButtonStyle())
            } else if let remaining = manager.lockStatus?.blocksRemaining {
                Label("Not yet", systemImage: "clock.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.accent)
                Text("The waiting period is still running: \(Format.blocksAsDuration(remaining)) to go. This countdown restarts if the owner uses the wallet — that's how the design protects them while they're alive and active.")
                    .font(.callout)
                Text("Keep this app installed and check back. Nothing is lost by waiting; the funds cannot go anywhere except back to the owner.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("No claimable funds", systemImage: "tray")
                    .font(.title3.bold())
                Text("This inheritance wallet doesn't hold confirmed funds right now. Pull to refresh on the home screen, or check that the recovery kit is the right one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where should the funds go?").font(.title3.bold())
            Text("Paste a Bitcoin address from a wallet that belongs to you. If you don't have one yet, create a wallet in any reputable Bitcoin app and tap its “Receive” button to get an address.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("tb1q…", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.footnote.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            WarningBox(
                title: "Double-check the address",
                message: "Bitcoin transactions cannot be reversed. Make sure the address is from YOUR wallet — read the first and last six characters out loud and compare."
            )
            if let formError {
                Text(formError).font(.footnote).foregroundStyle(Theme.danger)
            }
            Button("Preview claim") { prepare() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review your claim").font(.title3.bold())
            if let prepared {
                LabeledContent("You receive", value: Format.sats(prepared.sentSats - prepared.feeSats))
                LabeledContent("Network fee", value: Format.sats(prepared.feeSats))
                LabeledContent("To address", value: Format.shortTxid(address))
                Divider()
                Button("Claim my inheritance") { broadcast() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Back") { stage = .form }
                    .font(.footnote).frame(maxWidth: .infinity)
            }
        }
    }

    private func done(_ txid: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Claim broadcast", systemImage: "checkmark.circle.fill")
                .font(.title3.bold()).foregroundStyle(Theme.ok)
            Text("The Bitcoin network is processing your claim. Once confirmed (usually under an hour), the funds are in your wallet and fully under your control.")
                .font(.callout)
            CopyableText(label: "Transaction ID", value: txid)
            if let base = manager.meta?.network.explorerTxURL, let url = URL(string: base + txid) {
                Link("Track confirmation on explorer", destination: url).font(.footnote)
            }
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func prepare() {
        guard let service = manager.service else { return }
        formError = nil
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let rate = service.estimatedFeeRate()
                prepared = try await Task.detached(priority: .userInitiated) {
                    try service.prepareHeirClaim(toAddress: addr, feeRate: rate)
                }.value
                stage = .review
            } catch {
                formError = error.localizedDescription
            }
        }
    }

    private func broadcast() {
        guard let service = manager.service, let prepared else { return }
        stage = .broadcasting
        Task {
            do {
                let txid = try await Task.detached(priority: .userInitiated) {
                    try service.broadcast(prepared)
                }.value
                manager.refreshLocalState()
                stage = .done(txid)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
