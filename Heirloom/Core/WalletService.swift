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
    private var esplora: EsploraClient

    // MARK: - Init

    /// Create or load the wallet for the stored configuration.
    ///
    /// The descriptor is rebuilt deterministically from the local seed (Keychain) +
    /// counterparty public key + delay. BDK persists chain data in SQLite; if the
    /// database already exists we `load`, otherwise `create`.
    init(meta: WalletMeta) throws {
        self.meta = meta

        let seedKey: KeychainStore.Key = meta.role == .owner ? .ownerMnemonic : .heirMnemonic
        let mnemonic = try KeyService.loadMnemonic(seedKey)
        let signerKey = try KeyService.accountSecretKey(mnemonic: mnemonic, network: meta.network)

        let descriptorString = try InheritanceDescriptor.descriptorString(
            signerKey: signerKey,
            otherKey: meta.counterpartyKey,
            signerIsOwner: meta.role == .owner,
            delayBlocks: meta.delayBlocks
        )
        let twoPath = try InheritanceDescriptor.parse(descriptorString, network: meta.network)

        let dbPath = WalletMetaStore.walletDBPath(role: meta.role)
        let dbExists = FileManager.default.fileExists(atPath: dbPath)
        self.persister = try Persister.newSqlite(path: dbPath)

        let singles = try twoPath.toSingleDescriptors()
        guard singles.count == 2 else {
            throw HeirloomError.walletNotInitialized
        }
        if dbExists {
            self.wallet = try Wallet.load(
                descriptor: singles[0],
                changeDescriptor: singles[1],
                persister: persister
            )
        } else {
            self.wallet = try Wallet(
                descriptor: singles[0],
                changeDescriptor: singles[1],
                network: meta.network.bdkNetwork,
                persister: persister
            )
        }
        self.esplora = EsploraClient(url: meta.esploraURL)

        // Cross-check: the CSV delay embedded in the loaded wallet's policy MUST
        // match the configured delay. A mismatch means corrupted or tampered state.
        let resolved = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        guard resolved.csvBlocks == meta.delayBlocks else {
            throw HeirloomError.policyPathNotFound(
                "CSV mismatch: policy=\(resolved.csvBlocks.map(String.init) ?? "none") config=\(meta.delayBlocks)"
            )
        }
    }

    func updateEsploraURL(_ url: String) {
        esplora = EsploraClient(url: url)
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

    func nextReceiveAddress() throws -> AddressInfo {
        let info = wallet.revealNextAddress(keychain: .external)
        _ = try wallet.persist(persister: persister)
        return info
    }

    func tipHeight() -> UInt32 { wallet.latestCheckpoint().height }

    // MARK: - Sync

    /// Incremental sync of revealed scripts against the configured Esplora server.
    func sync() throws {
        let request = try wallet.startSyncWithRevealedSpks().build()
        let update = try esplora.sync(request: request, parallelRequests: 4)
        try wallet.applyUpdate(update: update)
        _ = try wallet.persist(persister: persister)
    }

    /// Full scan (first run / after restore): walks the keychains with a stop-gap.
    func fullScan() throws {
        let request = try wallet.startFullScan().build()
        let update = try esplora.fullScan(request: request, stopGap: 20, parallelRequests: 4)
        try wallet.applyUpdate(update: update)
        _ = try wallet.persist(persister: persister)
    }

    /// Fee-rate estimate for a given confirmation target, with a 1 sat/vB floor.
    func estimatedFeeRate(targetBlocks: UInt16 = 6) -> UInt64 {
        guard let estimates = try? esplora.getFeeEstimates() else { return 1 }
        let satVb = estimates[targetBlocks] ?? estimates.values.min() ?? 1
        return max(1, UInt64(satVb.rounded()))
    }

    // MARK: - Timelock status

    /// Compute when the heir path unlocks, from confirmed UTXO heights + CSV delay.
    ///
    /// Each UTXO's clock starts at its own confirmation height; the heir can claim a
    /// UTXO once it has `delayBlocks` confirmations. The wallet-level "inheritance
    /// unlocks" moment is the earliest such height across all UTXOs — after that, at
    /// least part of the funds is heir-claimable, so the countdown shows the minimum.
    func lockStatus() -> LockStatus {
        let tip = wallet.latestCheckpoint().height
        var earliest: UInt32?
        var hasUnconfirmed = false

        for utxo in wallet.listUnspent() {
            switch utxo.chainPosition {
            case let .confirmed(cbt, _):
                let expiry = cbt.blockId.height + meta.delayBlocks
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

    /// Build + sign the heartbeat: spend every UTXO back to our own next external
    /// address, through the owner branch. Confirmation restarts every UTXO's CSV
    /// clock — the on-chain equivalent of "I'm still here."
    func prepareHeartbeat(feeRate satPerVb: UInt64) throws -> PreparedTransaction {
        guard meta.role == .owner else { throw HeirloomError.policyPathNotFound("owner key") }
        guard !wallet.listUnspent().isEmpty else { throw HeirloomError.nothingToSpend }

        let destination = wallet.revealNextAddress(keychain: .external)
        let paths = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: wallet, keychain: .internal)

        let psbt = try TxBuilder()
            .drainWallet()
            .drainTo(script: destination.address.scriptPubkey())
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
        let paths = try PolicyPaths.resolve(wallet: wallet, keychain: .external)
        let changePaths = try PolicyPaths.resolve(wallet: wallet, keychain: .internal)

        let psbt = try TxBuilder()
            .addRecipient(script: dest.scriptPubkey(), amount: Amount.fromSat(satoshi: amountSats))
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
            try esplora.broadcast(transaction: prepared.transaction)
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
