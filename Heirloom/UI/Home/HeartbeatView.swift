import SwiftUI

/// The heartbeat flow: build → review fee → broadcast → confirmation.
///
/// A heartbeat is a real on-chain transaction that spends every UTXO back to a
/// fresh address of the same wallet (same inheritance policy). When it confirms,
/// every coin's relative timelock restarts from that block.
struct HeartbeatView: View {
    @EnvironmentObject var manager: WalletManager
    @Environment(\.dismiss) private var dismiss

    enum Stage { case explain, review, broadcasting, done(String), failed(String) }

    @State private var stage: Stage = .explain
    @State private var prepared: PreparedTransaction?
    @State private var feeRate: UInt64 = 2

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch stage {
                    case .explain: explain
                    case .review: review
                    case .broadcasting:
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Broadcasting to the Bitcoin network…").font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 60)
                    case .done(let txid): done(txid)
                    case .failed(let message): failed(message)
                    }
                }
                .padding()
            }
            .navigationTitle("Heartbeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
    }

    private var explain: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Reset the inheritance clock", systemImage: "heart.fill")
                .font(.title3.bold())
                .foregroundStyle(Theme.accent)
            Text("A heartbeat moves your coins once around your own wallet — same keys, same inheritance policy, fresh timelock. When it confirms, your heir's waiting period restarts at \(Format.blocksAsDuration(manager.meta?.delayBlocks ?? 0)).")
                .font(.callout)
            Text("This is a real Bitcoin transaction, so it costs a network fee (shown before you confirm). Nothing leaves your wallet.")
                .font(.footnote).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Network fee priority").font(.subheadline.weight(.semibold))
                Picker("Fee", selection: $feeRate) {
                    Text("Economy (~1 sat/vB)").tag(UInt64(1))
                    Text("Normal (~\(manager.service?.estimatedFeeRate() ?? 2) sat/vB)").tag(manager.service?.estimatedFeeRate() ?? 2)
                    Text("Priority (~\(max(3, (manager.service?.estimatedFeeRate(targetBlocks: 1) ?? 3))) sat/vB)").tag(max(3, manager.service?.estimatedFeeRate(targetBlocks: 1) ?? 3))
                }
                .pickerStyle(.segmented)
            }

            Button("Prepare heartbeat") { prepare() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review").font(.title3.bold())
            if let prepared {
                LabeledContent("Moves", value: Format.sats(prepared.sentSats))
                LabeledContent("Back to your wallet", value: Format.sats(prepared.receivedSats))
                LabeledContent("Network fee", value: Format.sats(prepared.feeSats))
                LabeledContent("New lock period", value: Format.blocksAsDuration(manager.meta?.delayBlocks ?? 0))
                Divider()
                CopyableText(label: "Transaction ID", value: prepared.txid)

                Button("Broadcast heartbeat") { broadcast() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Cancel") { stage = .explain }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func done(_ txid: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Heartbeat sent", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(Theme.ok)
            Text("Your inheritance clock restarts as soon as this transaction confirms (usually within ~10 minutes).")
                .font(.callout)
            CopyableText(label: "Transaction ID", value: txid)
            if let base = manager.meta?.network.explorerTxURL, let url = URL(string: base + txid) {
                Link("View on explorer", destination: url)
                    .font(.footnote)
            }
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            WarningBox(title: "Heartbeat failed", message: message, severity: .critical)
            Button("Try again") { stage = .explain }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func prepare() {
        guard let service = manager.service else { return }
        let rate = feeRate
        Task {
            do {
                let tx = try await Task.detached(priority: .userInitiated) {
                    try service.prepareHeartbeat(feeRate: rate)
                }.value
                prepared = tx
                stage = .review
            } catch {
                stage = .failed(error.localizedDescription)
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
