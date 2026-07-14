import Foundation
import BitcoinDevKit

/// Snapshot of the inheritance timelock across all wallet UTXOs.
struct LockStatus: Equatable {
    /// Current chain tip height (last synced).
    var tipHeight: UInt32
    /// The height at which the *earliest* UTXO becomes heir-spendable.
    /// `nil` when the wallet holds no confirmed funds.
    var earliestExpiryHeight: UInt32?
    /// Blocks until the heir path unlocks (0 = already unlocked).
    var blocksRemaining: UInt32?
    /// Whether any UTXO is already heir-spendable.
    var heirCanClaim: Bool
    /// True when the wallet has unconfirmed funds whose clock hasn't started.
    var hasUnconfirmed: Bool

    var approxDaysRemaining: Double? {
        blocksRemaining.map { Double($0) / 144.0 }
    }

    var approxExpiryDate: Date? {
        blocksRemaining.map { Date().addingTimeInterval(Double($0) * 600) }
    }
}

/// Row model for the transaction list.
struct TxSummary: Identifiable, Equatable {
    let id: String
    let netSats: Int64
    let confirmedHeight: UInt32?
    let timestamp: UInt64?
    var isConfirmed: Bool { confirmedHeight != nil }
}

/// A prepared, signed-but-not-broadcast transaction with display info.
struct PreparedTransaction {
    let psbt: Psbt
    let transaction: Transaction
    let feeSats: UInt64
    let sentSats: UInt64
    let receivedSats: UInt64
    var txid: String { transaction.computeTxid().description }
}

/// Owns the BDK `Wallet`, its persistence and network client, and implements the
/// three product flows: fund/receive, heartbeat, and heir claim.
///
/// Thread-safety: BDK objects are internally synchronized; UI code accesses this
/// through `WalletManager` (main-actor) and runs the blocking calls on background
/// queues.
final class WalletService {
    let meta: WalletMeta
    private let wallet: Wallet
    private let persister: Persister
    private var chain: ChainClient

    // MARK: - Init

    /// Create or load the wallet for the stored configuration.
    ///
    /// The descriptor is rebuilt deterministically from the local seed (Keychain) +
    /// counterparty public key + delay. BDK persists chain data in SQLite; if the
    /// database already exists we `load`, otherwise `create`.
    ///
    /// - Parameter dbPath: test override for the SQLite path (defaults to the
    ///   app-standard per-role location).
    init(meta: WalletMeta, dbPath: String? = nil) throws {
        self.meta = meta

        let seedKey: KeychainStore.Key = meta.role == .owner ? .ownerMnemonic : .heirMnemonic
        let mnemonic = try KeyService.loadMnemonic(seedKey)
        let signerKey = try KeyService.accountSecretKey(mnemonic: mnemonic, network: meta.network)

        let pair = try InheritanceDescriptor.descriptorStrings(
            signerKey: signerKey,
            otherKey: meta.counterpartyKey,
            signerIsOwner: meta.role == .owner,
            delayBlocks: meta.delayBlocks
        )
        let external = try InheritanceDescriptor.parse(pair.external, network: meta.network)
        let change = try InheritanceDescriptor.parse(pair.change, network: meta.network)

        let dbPath = dbPath ?? WalletMetaStore.walletDBPath(role: meta.role)
        let dbExists = FileManager.default.fileExists(atPath: dbPath)
        self.persister = try Persister.newSqlite(path: dbPath)

        if dbExists {
            self.wallet = try Wallet.load(
                descriptor: external,
                changeDescriptor: change,
                persister: persister
            )
        } else {
            self.wallet = try Wallet(
                descriptor: external,
                changeDescriptor: change,
                network: meta.network.bdkNetwork,
                persister: persister
            )
        }
        self.chain = try ChainClient(endpoint: meta.esploraURL)

        // Cross-check: the CSV delay embedded in the loaded wallet's policy MUST
        // match the configured delay. A mismatch means corrupted or tampered state.
        let resolved = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        guard resolved.csvBlocks == meta.delayBlocks else {
            throw HeirloomError.policyPathNotFound(
                "CSV mismatch: policy=\(resolved.csvBlocks.map(String.init) ?? "none") config=\(meta.delayBlocks)"
            )
        }
    }

    func updateEsploraURL(_ url: String) throws {
        chain = try ChainClient(endpoint: url)
    }

    // MARK: - Introspection

    var network: AppNetwork { meta.network }

    /// Public (watch-only) descriptor strings for export/backup.
    func publicDescriptors() -> (external: String, change: String) {
        (wallet.publicDescriptor(keychain: .external),
         wallet.publicDescriptor(keychain: .internal))
    }

    func balance() -> Balance { wallet.balance() }

    func transactionsList() -> [CanonicalTx] { wallet.transactions() }

    /// Display-friendly rows for the transaction list, newest first.
    func txSummaries() -> [TxSummary] {
        wallet.transactions().map { ctx in
            let values = wallet.sentAndReceived(tx: ctx.transaction)
            let net = Int64(values.received.toSat()) - Int64(values.sent.toSat())
            switch ctx.chainPosition {
            case let .confirmed(cbt, _):
                return TxSummary(
                    id: ctx.transaction.computeTxid().description,
                    netSats: net,
                    confirmedHeight: cbt.blockId.height,
                    timestamp: cbt.confirmationTime
                )
            case let .unconfirmed(ts):
                return TxSummary(
                    id: ctx.transaction.computeTxid().description,
                    netSats: net,
                    confirmedHeight: nil,
                    timestamp: ts
                )
            }
        }
        .sorted { ($0.confirmedHeight ?? .max) > ($1.confirmedHeight ?? .max) }
    }

    func nextReceiveAddress() throws -> AddressInfo {
        let info = wallet.revealNextAddress(keychain: .external)
        _ = try wallet.persist(persister: persister)
        return info
    }

    func tipHeight() -> UInt32 { wallet.latestCheckpoint().height }

    // MARK: - Sync

    /// Incremental sync of revealed scripts against the configured chain server.
    func sync() throws {
        let request = try wallet.startSyncWithRevealedSpks().build()
        let update = try chain.sync(request: request)
        try wallet.applyUpdate(update: update)
        _ = try wallet.persist(persister: persister)
    }

    /// Full scan (first run / after restore): walks the keychains with a stop-gap.
    func fullScan() throws {
        let request = try wallet.startFullScan().build()
        let update = try chain.fullScan(request: request, stopGap: 20)
        try wallet.applyUpdate(update: update)
        _ = try wallet.persist(persister: persister)
    }

    /// Fee-rate estimate for a given confirmation target, with a 1 sat/vB floor.
    func estimatedFeeRate(targetBlocks: UInt16 = 6) -> UInt64 {
        chain.feeRate(targetBlocks: targetBlocks)
    }

    // MARK: - Timelock status

    /// Compute when the heir path unlocks, from confirmed UTXO heights + CSV delay.
    ///
    /// BIP-68 arithmetic: a UTXO confirmed in block `h` with CSV value `N` can be
    /// spent in any block `>= h + N`; Bitcoin Core admits the spend to the mempool
    /// as soon as it would be valid in the *next* block, i.e. once the chain tip
    /// reaches `h + N - 1` (equivalently: the UTXO has exactly `N` confirmations).
    /// `earliestExpiryHeight` is therefore `h + N - 1` — the first tip height at
    /// which the heir's claim is broadcastable — matching `prepareHeirClaim`'s
    /// `confirmations >= N` gate exactly.
    ///
    /// Each UTXO's clock starts at its own confirmation height; the wallet-level
    /// countdown shows the earliest across all UTXOs (the first moment *any* part
    /// of the funds becomes heir-claimable).
    func lockStatus() -> LockStatus {
        let tip = wallet.latestCheckpoint().height
        var earliest: UInt32?
        var hasUnconfirmed = false

        for utxo in wallet.listUnspent() {
            switch utxo.chainPosition {
            case let .confirmed(cbt, _):
                let expiry = cbt.blockId.height + meta.delayBlocks - 1
                earliest = min(earliest ?? expiry, expiry)
            case .unconfirmed:
                hasUnconfirmed = true
            }
        }

        guard let expiryHeight = earliest else {
            return LockStatus(
                tipHeight: tip,
                earliestExpiryHeight: nil,
                blocksRemaining: nil,
                heirCanClaim: false,
                hasUnconfirmed: hasUnconfirmed
            )
        }
        let remaining = expiryHeight > tip ? expiryHeight - tip : 0
        return LockStatus(
            tipHeight: tip,
            earliestExpiryHeight: expiryHeight,
            blocksRemaining: remaining,
            heirCanClaim: remaining == 0,
            hasUnconfirmed: hasUnconfirmed
        )
    }

    // MARK: - Owner flows

    /// True when the wallet holds at least one confirmed UTXO.
    private var hasConfirmedUTXO: Bool {
        wallet.listUnspent().contains { utxo in
            if case .confirmed = utxo.chainPosition { return true }
            return false
        }
    }

    /// Build + sign the heartbeat: spend every UTXO back to our own next external
    /// address, through the owner branch. Confirmation restarts every UTXO's CSV
    /// clock — the on-chain equivalent of "I'm still here."
    ///
    /// Unconfirmed UTXOs are excluded from every owner-side build: their CSV clock
    /// hasn't started (so a heartbeat of them is meaningless) and, defensively,
    /// spending an unconfirmed output of a CSV descriptor triggers an unchecked
    /// height addition inside bdk_wallet 3.0 (`utils.rs` `Older::check_older`) that
    /// aborts the process. See SECURITY_REVIEW.md.
    func prepareHeartbeat(feeRate satPerVb: UInt64) throws -> PreparedTransaction {
        guard meta.role == .owner else { throw HeirloomError.policyPathNotFound("owner key") }
        guard !wallet.listUnspent().isEmpty else { throw HeirloomError.nothingToSpend }
        guard hasConfirmedUTXO else { throw HeirloomError.waitingForConfirmation }

        let destination = wallet.revealNextAddress(keychain: .external)
        let paths = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: wallet, keychain: .internal)

        let psbt = try TxBuilder()
            .drainWallet()
            .drainTo(script: destination.address.scriptPubkey())
            .excludeUnconfirmed()
            .policyPath(policyPath: paths.owner, keychain: .external)
            .policyPath(policyPath: changePaths.owner, keychain: .internal)
            .version(version: 2)
            .feeRate(feeRate: FeeRate.fromSatPerKwu(satKwu: satPerVb * 250))
            .finish(wallet: wallet)

        return try signOwner(psbt: psbt)
    }

    /// Build + sign an ordinary owner spend to an external address.
    func prepareOwnerSpend(
        toAddress address: String,
        amountSats: UInt64,
        feeRate satPerVb: UInt64
    ) throws -> PreparedTransaction {
        guard meta.role == .owner else { throw HeirloomError.policyPathNotFound("owner key") }
        guard let dest = try? Address(address: address, network: meta.network.bdkNetwork) else {
            throw HeirloomError.invalidAddress(address)
        }
        guard hasConfirmedUTXO else { throw HeirloomError.waitingForConfirmation }
        let paths = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: wallet, keychain: .internal)

        let psbt = try TxBuilder()
            .addRecipient(script: dest.scriptPubkey(), amount: Amount.fromSat(satoshi: amountSats))
            .excludeUnconfirmed()
            .policyPath(policyPath: paths.owner, keychain: .external)
            .policyPath(policyPath: changePaths.owner, keychain: .internal)
            .version(version: 2)
            .feeRate(feeRate: FeeRate.fromSatPerKwu(satKwu: satPerVb * 250))
            .finish(wallet: wallet)

        return try signOwner(psbt: psbt)
    }

    private func signOwner(psbt: Psbt) throws -> PreparedTransaction {
        let finalized = try wallet.sign(psbt: psbt, signOptions: nil)
        guard finalized else {
            throw HeirloomError.broadcastFailed("Could not finalize transaction (missing signatures).")
        }
        let tx = try psbt.extractTx()
        let values = wallet.sentAndReceived(tx: tx)
        return PreparedTransaction(
            psbt: psbt,
            transaction: tx,
            feeSats: try psbt.fee(),
            sentSats: values.sent.toSat(),
            receivedSats: values.received.toSat()
        )
    }

    // MARK: - Heir flow

    /// Build + sign the heir's claim: sweep every *matured* UTXO through the
    /// timelocked branch to the heir's chosen address.
    ///
    /// BDK sets each input's nSequence to the CSV value because the policy path
    /// selects the `older(N)` branch; the transaction is consensus-valid only once
    /// every spent UTXO has N confirmations. We hard-refuse to build when nothing
    /// has matured, and exclude immature UTXOs otherwise.
    func prepareHeirClaim(
        toAddress address: String,
        feeRate satPerVb: UInt64
    ) throws -> PreparedTransaction {
        guard meta.role == .heir else { throw HeirloomError.policyPathNotFound("heir key") }
        guard let dest = try? Address(address: address, network: meta.network.bdkNetwork) else {
            throw HeirloomError.invalidAddress(address)
        }

        let tip = wallet.latestCheckpoint().height
        var matured: [OutPoint] = []
        var earliestRemaining: UInt32?

        for utxo in wallet.listUnspent() {
            switch utxo.chainPosition {
            case let .confirmed(cbt, _):
                let confirmations = tip >= cbt.blockId.height ? tip - cbt.blockId.height + 1 : 0
                if confirmations >= meta.delayBlocks {
                    matured.append(utxo.outpoint)
                } else {
                    let remaining = meta.delayBlocks - confirmations
                    earliestRemaining = min(earliestRemaining ?? remaining, remaining)
                }
            case .unconfirmed:
                continue
            }
        }

        guard !matured.isEmpty else {
            if let remaining = earliestRemaining {
                throw HeirloomError.timelockNotExpired(blocksRemaining: remaining)
            }
            throw HeirloomError.nothingToSpend
        }

        let paths = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: wallet, keychain: .internal)

        let psbt = try TxBuilder()
            .addUtxos(outpoints: matured)
            .manuallySelectedOnly()
            .drainTo(script: dest.scriptPubkey())
            .policyPath(policyPath: paths.heir, keychain: .external)
            .policyPath(policyPath: changePaths.heir, keychain: .internal)
            .version(version: 2)
            .feeRate(feeRate: FeeRate.fromSatPerKwu(satKwu: satPerVb * 250))
            .finish(wallet: wallet)

        let finalized = try wallet.sign(psbt: psbt, signOptions: nil)
        guard finalized else {
            throw HeirloomError.broadcastFailed("Could not finalize claim (timelock not met or missing key).")
        }
        let tx = try psbt.extractTx()
        let values = wallet.sentAndReceived(tx: tx)
        return PreparedTransaction(
            psbt: psbt,
            transaction: tx,
            feeSats: try psbt.fee(),
            sentSats: values.sent.toSat(),
            receivedSats: values.received.toSat()
        )
    }

    // MARK: - Broadcast

    func broadcast(_ prepared: PreparedTransaction) throws -> String {
        do {
            try chain.broadcast(prepared.transaction)
        } catch {
            throw HeirloomError.broadcastFailed(error.localizedDescription)
        }
        // Make the wallet aware immediately so balances/UI update pre-confirmation.
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [
            UnconfirmedTx(
                tx: prepared.transaction,
                lastSeen: UInt64(Date().timeIntervalSince1970)
            )
        ])
        _ = try? wallet.persist(persister: persister)
        return prepared.txid
    }
}
