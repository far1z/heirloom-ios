import Foundation
import BitcoinDevKit
@testable import Heirloom

/// An in-memory `Persistence` that seeds the wallet with a pre-built `ChangeSet`.
/// This is the only offline way to hand a BDK wallet a *confirmed* UTXO (anchored
/// to a fake block) — `applyUnconfirmedTxs` can only create unconfirmed ones.
final class SeededPersistence: Persistence, @unchecked Sendable {
    private var initial: ChangeSet

    init(initial: ChangeSet) {
        self.initial = initial
    }

    func initialize() throws -> ChangeSet {
        initial
    }

    func persist(changeset: ChangeSet) throws {
        initial = ChangeSet.fromMerge(left: initial, right: changeset)
    }
}

enum TestFixtures {
    struct ConfirmedWallet {
        let wallet: Wallet
        let persister: Persister
        let fundingTxid: String
        let fundedSats: UInt64
        let confirmationHeight: UInt32
        let tipHeight: UInt32
    }

    /// Fake but structurally valid block hash for a given height.
    static func fakeBlockHash(_ seed: UInt8) throws -> BlockHash {
        try BlockHash.fromBytes(bytes: Data(repeating: seed, count: 32))
    }

    /// Hand-encode a funding transaction paying `sats` to `script`.
    static func fundingTx(to script: Script, sats: UInt64) throws -> Transaction {
        var data = Data()
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // version 2
        data.append(0x01)                                  // 1 input
        data.append(Data(repeating: 0x11, count: 32))      // fake prev txid
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // vout 0
        data.append(0x00)                                  // empty scriptSig
        data.append(contentsOf: [0xfd, 0xff, 0xff, 0xff])  // sequence
        data.append(0x01)                                  // 1 output
        withUnsafeBytes(of: sats.littleEndian) { data.append(contentsOf: $0) }
        let spk = script.toBytes()
        data.append(UInt8(spk.count))
        data.append(contentsOf: spk)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // locktime
        return try Transaction(transactionBytes: data)
    }

    /// Build an inheritance wallet whose external address 0 holds a UTXO
    /// *confirmed* at `confirmationHeight`, with the local chain tip at `tipHeight`.
    ///
    /// Implementation: derive the descriptors, pre-compute the funding tx to the
    /// index-0 external script, and seed the wallet's persistence with a ChangeSet
    /// containing the tx, its anchor block, and a local chain (genesis + anchor +
    /// tip blocks).
    static func makeConfirmedWallet(
        ownerSide: Bool,
        delay: UInt32,
        sats: UInt64 = 100_000,
        confirmationHeight: UInt32 = 100,
        tipHeight: UInt32 = 100,
        watchOnly: Bool = false
    ) throws -> ConfirmedWallet {
        precondition(tipHeight >= confirmationHeight)
        let network = AppNetwork.signet
        let owner = try KeyService.parseMnemonic(TestSeeds.ownerWords)
        let heir = try KeyService.parseMnemonic(TestSeeds.heirWords)
        let pair: InheritanceDescriptor.Pair
        if watchOnly {
            pair = try InheritanceDescriptor.publicDescriptorStrings(
                ownerKey: try KeyService.accountPublicKeyString(mnemonic: owner, network: network),
                heirKey: try KeyService.accountPublicKeyString(mnemonic: heir, network: network),
                delayBlocks: delay
            )
        } else {
            let signer = try KeyService.accountSecretKey(mnemonic: ownerSide ? owner : heir, network: network)
            let otherPub = try KeyService.accountPublicKeyString(mnemonic: ownerSide ? heir : owner, network: network)
            pair = try InheritanceDescriptor.descriptorStrings(
                signerKey: signer, otherKey: otherPub, signerIsOwner: ownerSide, delayBlocks: delay
            )
        }
        let external = try InheritanceDescriptor.parse(pair.external, network: network)
        let change = try InheritanceDescriptor.parse(pair.change, network: network)

        // Funding tx to external index 0.
        let address0 = try external.deriveAddress(index: 0, network: network.bdkNetwork)
        let tx = try fundingTx(to: address0.scriptPubkey(), sats: sats)
        let txid = tx.computeTxid()

        // Chain: genesis (height 0) → anchor block → tip block.
        var chainChanges = [
            ChainChange(height: 0, hash: try fakeBlockHash(0xAA)),
            ChainChange(height: confirmationHeight, hash: try fakeBlockHash(0xBB)),
        ]
        if tipHeight > confirmationHeight {
            chainChanges.append(ChainChange(height: tipHeight, hash: try fakeBlockHash(0xCC)))
        }

        let anchor = Anchor(
            confirmationBlockTime: ConfirmationBlockTime(
                blockId: BlockId(height: confirmationHeight, hash: try fakeBlockHash(0xBB)),
                confirmationTime: 1_700_000_000
            ),
            txid: txid
        )
        let graph = TxGraphChangeSet(
            txs: [tx],
            txouts: [:],
            anchors: [anchor],
            lastSeen: [:],
            firstSeen: [:],
            lastEvicted: [:]
        )
        // Mark external index 0 as revealed so the wallet indexes the funding output.
        let indexer = IndexerChangeSet(lastRevealed: [external.descriptorId(): 0])

        let changeSet = ChangeSet.fromAggregate(
            descriptor: external,
            changeDescriptor: change,
            network: network.bdkNetwork,
            localChain: LocalChainChangeSet(changes: chainChanges),
            txGraph: graph,
            indexer: indexer
        )
        let persister = Persister.custom(persistence: SeededPersistence(initial: changeSet))
        let wallet = try Wallet.load(descriptor: external, changeDescriptor: change, persister: persister)
        return ConfirmedWallet(
            wallet: wallet,
            persister: persister,
            fundingTxid: txid.description,
            fundedSats: sats,
            confirmationHeight: confirmationHeight,
            tipHeight: tipHeight
        )
    }
}
