import SwiftUI

/// Ordinary owner spend to any address. Uses the owner (spend-anytime) branch.
struct SendView: View {
    @EnvironmentObject var manager: WalletManager
    @Environment(\.dismiss) private var dismiss

    enum Stage { case form, review, broadcasting, done(String), failed(String) }

    @State private var stage: Stage = .form
    @State private var address = ""
    @State private var amountText = ""
    @State private var feeRate: UInt64 = 2
    @State private var prepared: PreparedTransaction?
    @State private var formError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch stage {
                    case .form: form
                    case .review: review
                    case .broadcasting:
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Broadcasting…").font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 60)
                    case .done(let txid): done(txid)
                    case .failed(let message):
                        WarningBox(title: "Send failed", message: message, severity: .critical)
                        Button("Back") { stage = .form }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding()
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            WarningBox(
                title: "Leaving the inheritance wallet",
                message: "Coins sent to an outside address are no longer covered by your inheritance policy."
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Recipient address").font(.caption).foregroundStyle(.secondary)
                TextField("tb1q…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Amount (sats)").font(.caption).foregroundStyle(.secondary)
                TextField("10000", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                Text("Available: \(Format.sats(manager.balance?.trustedSpendable.toSat() ?? 0))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let formError {
                Text(formError).font(.footnote).foregroundStyle(Theme.danger)
            }
            Button("Preview") { prepare() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review").font(.title3.bold())
            if let prepared {
                LabeledContent("To", value: Format.shortTxid(address))
                LabeledContent("Amount", value: amountText + " sats")
                LabeledContent("Network fee", value: Format.sats(prepared.feeSats))
                Button("Confirm & broadcast") { broadcast() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Cancel") { stage = .form }
                    .font(.footnote).frame(maxWidth: .infinity)
            }
        }
    }

    private func done(_ txid: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.title3.bold()).foregroundStyle(Theme.ok)
            CopyableText(label: "Transaction ID", value: txid)
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func prepare() {
        guard let service = manager.service else { return }
        guard let amount = UInt64(amountText.trimmingCharacters(in: .whitespaces)), amount > 0 else {
            formError = "Enter a valid amount in sats."
            return
        }
        formError = nil
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let rate = feeRate
        Task {
            do {
                prepared = try await Task.detached(priority: .userInitiated) {
                    try service.prepareOwnerSpend(toAddress: addr, amountSats: amount, feeRate: rate)
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
