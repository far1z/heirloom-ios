import SwiftUI
import BitcoinDevKit

struct HomeView: View {
    @EnvironmentObject var manager: WalletManager
    @State private var showReceive = false
    @State private var showHeartbeat = false
    @State private var showSend = false
    @State private var showClaim = false
    @State private var showSettings = false

    private var isOwner: Bool { manager.meta?.role == .owner }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard
                    countdownCard
                    actionRow
                    if let error = manager.lastSyncError {
                        WarningBox(title: "Network problem", message: "Couldn't reach the Bitcoin server: \(error). Balances may be stale — check Settings → Server.")
                    }
                    txList
                }
                .padding()
            }
            .navigationTitle(isOwner ? "Heirloom" : "Inheritance")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if manager.isSyncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await manager.syncNow() }
                        } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .refreshable { await manager.syncNow() }
            .sheet(isPresented: $showReceive) { ReceiveView() }
            .sheet(isPresented: $showHeartbeat) { HeartbeatView() }
            .sheet(isPresented: $showSend) { SendView() }
            .sheet(isPresented: $showClaim) { ClaimView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            Text(Format.sats(manager.balance?.total.toSat() ?? 0))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(Format.btc(manager.balance?.total.toSat() ?? 0))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let balance = manager.balance, balance.untrustedPending.toSat() + balance.trustedPending.toSat() > 0 {
                Text("incl. \(Format.sats(balance.untrustedPending.toSat() + balance.trustedPending.toSat())) pending")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
            if let date = manager.lastSyncDate {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var countdownCard: some View {
        if let status = manager.lockStatus {
            InheritanceCountdownCard(status: status, isOwner: isOwner, delayBlocks: manager.meta?.delayBlocks ?? 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if isOwner {
                actionButton("Receive", icon: "qrcode") { showReceive = true }
                actionButton("Heartbeat", icon: "heart.fill", prominent: true) { showHeartbeat = true }
                actionButton("Send", icon: "arrow.up.right") { showSend = true }
            } else {
                actionButton("Claim inheritance", icon: "key.horizontal.fill", prominent: true) { showClaim = true }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(prominent ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
        }
    }

    private var txList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            let summaries = manager.service?.txSummaries() ?? []
            if summaries.isEmpty {
                Text(isOwner
                     ? "No transactions yet. Tap Receive to fund this wallet with signet coins."
                     : "No transactions found for this inheritance wallet yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(summaries) { tx in
                HStack {
                    Image(systemName: tx.netSats >= 0 ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                        .foregroundStyle(tx.netSats >= 0 ? Theme.ok : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.shortTxid(tx.id)).font(.footnote.monospaced())
                        Text(tx.isConfirmed ? "Confirmed at block \(tx.confirmedHeight ?? 0)" : "Pending confirmation")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text((tx.netSats >= 0 ? "+" : "") + Format.sats(tx.netSats))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(tx.netSats >= 0 ? Theme.ok : .primary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// The countdown card: "Your inheritance lock expires in X days."
struct InheritanceCountdownCard: View {
    let status: LockStatus
    let isOwner: Bool
    let delayBlocks: UInt32

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remaining = status.blocksRemaining {
                if remaining > 0 {
                    Label(isOwner ? "Inheritance lock active" : "Waiting period running",
                          systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.ok)
                    Text(isOwner
                         ? "Your inheritance lock expires in \(Format.blocksAsDuration(remaining))."
                         : "You can claim in \(Format.blocksAsDuration(remaining)).")
                        .font(.title3.bold())
                    if let date = status.approxExpiryDate {
                        Text("≈ \(date.formatted(date: .abbreviated, time: .omitted)) · \(remaining) blocks left of \(delayBlocks)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(delayBlocks - min(remaining, delayBlocks)), total: Double(delayBlocks))
                        .tint(isOwner ? Theme.ok : Theme.accent)
                    if isOwner {
                        Text("Send a heartbeat to restart the clock at \(Format.blocksAsDuration(delayBlocks)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label(isOwner ? "LOCK EXPIRED — heir can spend" : "Ready to claim",
                          systemImage: isOwner ? "lock.open.fill" : "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(isOwner ? Theme.danger : Theme.ok)
                    Text(isOwner
                         ? "The waiting period has fully elapsed. Your heir's key can move these funds RIGHT NOW. Send a heartbeat immediately to re-lock them."
                         : "The waiting period has elapsed. You can now move the funds to your own wallet.")
                        .font(.footnote)
                }
            } else if status.hasUnconfirmed {
                Label("Waiting for confirmation", systemImage: "clock")
                    .font(.headline)
                Text("Funds are on their way. The inheritance clock starts once they confirm in a block.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("No funds yet", systemImage: "tray")
                    .font(.headline)
                Text(isOwner
                     ? "Once you receive bitcoin, the inheritance clock starts automatically."
                     : "This inheritance wallet currently holds no funds.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }
}
