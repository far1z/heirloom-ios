import Foundation
import SwiftUI
import BitcoinDevKit

/// Main-actor façade the UI talks to. Owns the `WalletService`, runs its blocking
/// BDK/network calls off the main thread, and publishes displayable state.
@MainActor
final class WalletManager: ObservableObject {
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var meta: WalletMeta?
    @Published private(set) var balance: Balance?
    @Published private(set) var lockStatus: LockStatus?
    @Published private(set) var transactions: [CanonicalTx] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastSyncDate: Date?

    private(set) var service: WalletService?

    // MARK: - Lifecycle

    func bootstrap() async {
        guard let meta = WalletMetaStore.load() else {
            phase = .onboarding
            return
        }
        do {
            let service = try await Task.detached(priority: .userInitiated) {
                try WalletService(meta: meta)
            }.value
            self.meta = meta
            self.service = service
            self.phase = .ready
            refreshLocalState()
            await syncNow(fullScanIfFirst: false)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Owner path: called by the creation wizard with everything it gathered.
    /// Stores the owner seed, persists metadata, builds the wallet.
    func createOwnerWallet(
        ownerMnemonic: Mnemonic,
        heirAccountKey: String,
        heirFingerprint: String,
        delayBlocks: UInt32,
        tier: ServiceTier,
        network: AppNetwork = .signet
    ) async throws {
        guard DelayPreset.isValidCSV(delayBlocks) else {
            throw HeirloomError.invalidDelay(delayBlocks)
        }
        try KeyService.storeMnemonic(ownerMnemonic, as: .ownerMnemonic)
        let meta = WalletMeta(
            role: .owner,
            network: network,
            delayBlocks: delayBlocks,
            counterpartyKey: heirAccountKey,
            localFingerprint: try KeyService.masterFingerprint(mnemonic: ownerMnemonic, network: network),
            localAccountKey: try KeyService.accountPublicKeyString(mnemonic: ownerMnemonic, network: network),
            esploraURL: network.defaultEsploraURL,
            tier: tier,
            createdAt: Date()
        )
        try WalletMetaStore.save(meta)
        let service = try await Task.detached(priority: .userInitiated) {
            try WalletService(meta: meta)
        }.value
        self.meta = meta
        self.service = service
        self.phase = .ready
        refreshLocalState()
        await syncNow(fullScanIfFirst: true)
    }

    /// Heir path: reconstruct the wallet from a Recovery Kit + the heir's seed.
    func recoverAsHeir(kit: RecoveryKit, heirMnemonic: Mnemonic) async throws {
        // Verify the typed seed matches the kit before storing anything.
        let typedKey = try KeyService.accountPublicKeyString(mnemonic: heirMnemonic, network: kit.network)
        guard typedKey == kit.heirAccountKey else {
            throw HeirloomError.invalidMnemonic
        }
        try KeyService.storeMnemonic(heirMnemonic, as: .heirMnemonic)
        let meta = WalletMeta(
            role: .heir,
            network: kit.network,
            delayBlocks: kit.delayBlocks,
            counterpartyKey: kit.ownerAccountKey,
            localFingerprint: try KeyService.masterFingerprint(mnemonic: heirMnemonic, network: kit.network),
            localAccountKey: typedKey,
            esploraURL: kit.network.defaultEsploraURL,
            tier: .free,
            createdAt: Date()
        )
        try WalletMetaStore.save(meta)
        let service = try await Task.detached(priority: .userInitiated) {
            try WalletService(meta: meta)
        }.value
        self.meta = meta
        self.service = service
        self.phase = .ready
        refreshLocalState()
        await syncNow(fullScanIfFirst: true)
    }

    /// Destructive: wipe seeds, metadata and chain databases from this device.
    func wipeWallet() {
        KeychainStore.deleteAll()
        WalletMetaStore.delete()
        WalletMetaStore.deleteWalletDBs()
        service = nil
        meta = nil
        balance = nil
        lockStatus = nil
        transactions = []
        phase = .onboarding
    }

    // MARK: - Sync

    func syncNow(fullScanIfFirst: Bool = false) async {
        guard let service, !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }
        do {
            try await Task.detached(priority: .utility) {
                if fullScanIfFirst {
                    try service.fullScan()
                } else {
                    try service.sync()
                }
            }.value
            lastSyncDate = Date()
            refreshLocalState()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func refreshLocalState() {
        guard let service else { return }
        balance = service.balance()
        lockStatus = service.lockStatus()
        transactions = service.transactionsList()
    }

    // MARK: - Settings

    func updateEsploraURL(_ url: String) throws {
        guard var meta, let service else { throw HeirloomError.walletNotInitialized }
        // https:// and ssl:// anywhere; plaintext http:///tcp:// only to loopback.
        guard ChainClient.isAcceptableEndpoint(url) else {
            throw HeirloomError.invalidEndpoint(url)
        }
        meta.esploraURL = url
        try WalletMetaStore.save(meta)
        self.meta = meta
        try service.updateEsploraURL(url)
    }
}
