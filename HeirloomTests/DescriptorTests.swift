import XCTest
import BitcoinDevKit
@testable import Heirloom

/// Deterministic, checksum-valid test seeds derived from fixed entropy.
/// Test-only: never use these with real funds.
enum TestSeeds {
    static var ownerWords: String {
        (try! Mnemonic.fromEntropy(entropy: Data(repeating: 0x11, count: 16))).description
    }
    static var heirWords: String {
        (try! Mnemonic.fromEntropy(entropy: Data(repeating: 0x22, count: 16))).description
    }
}

/// Tests for the inheritance policy/descriptor construction — the security core.
final class DescriptorTests: XCTestCase {
    static var ownerWords: String { TestSeeds.ownerWords }
    static var heirWords: String { TestSeeds.heirWords }

    // MARK: Delay presets & CSV ceiling

    func testDelayPresetBlockValues() {
        XCTAssertEqual(DelayPreset.threeMonths.blocks, 13_140)
        XCTAssertEqual(DelayPreset.sixMonths.blocks, 26_280)
        XCTAssertEqual(DelayPreset.nineMonths.blocks, 39_420)
        XCTAssertEqual(DelayPreset.twelveMonths.blocks, 52_560)
        // The 15-month preset must sit exactly on the BIP-68 ceiling, not above it.
        XCTAssertEqual(DelayPreset.fifteenMonths.blocks, 65_535)
        XCTAssertEqual(DelayPreset.fifteenMonths.blocks, DelayPreset.csvCeiling)
    }

    func testCSVBoundsValidation() {
        XCTAssertFalse(DelayPreset.isValidCSV(0))
        XCTAssertTrue(DelayPreset.isValidCSV(1))
        XCTAssertTrue(DelayPreset.isValidCSV(65_535))
        XCTAssertFalse(DelayPreset.isValidCSV(65_536))
        XCTAssertFalse(DelayPreset.isValidCSV(UInt32.max))
    }

    func testDescriptorBuilderRejectsInvalidDelay() throws {
        let owner = try KeyService.parseMnemonic(Self.ownerWords)
        let key = try KeyService.accountSecretKey(mnemonic: owner, network: .signet)
        XCTAssertThrowsError(
            try InheritanceDescriptor.descriptorStrings(
                signerKey: key, otherKey: key.asPublic().description,
                signerIsOwner: true, delayBlocks: 0
            )
        )
        XCTAssertThrowsError(
            try InheritanceDescriptor.descriptorStrings(
                signerKey: key, otherKey: key.asPublic().description,
                signerIsOwner: true, delayBlocks: 65_536
            )
        )
    }

    // MARK: Descriptor construction

    func testDescriptorShapeAndSanity() throws {
        let owner = try KeyService.parseMnemonic(Self.ownerWords)
        let heir = try KeyService.parseMnemonic(Self.heirWords)
        let ownerKey = try KeyService.accountSecretKey(mnemonic: owner, network: .signet)
        let heirPub = try KeyService.accountPublicKeyString(mnemonic: heir, network: .signet)

        let pair = try InheritanceDescriptor.descriptorStrings(
            signerKey: ownerKey, otherKey: heirPub, signerIsOwner: true, delayBlocks: 4_320
        )
        for s in [pair.external, pair.change] {
            XCTAssertTrue(s.hasPrefix("wsh(or_d(pk("), "policy must be or_d with owner key first")
            XCTAssertTrue(s.contains("and_v(v:pk("), "heir branch must be and_v(v:pk(heir),older(N))")
            XCTAssertTrue(s.contains("older(4320)"), "CSV delay must appear in the descriptor")
            let d = try InheritanceDescriptor.parse(s, network: .signet)
            XCTAssertNoThrow(try d.sanityCheck())
            XCTAssertTrue(d.hasWildcard())
        }
        XCTAssertTrue(pair.external.contains("/0/*"))
        XCTAssertTrue(pair.change.contains("/1/*"))
        XCTAssertNotEqual(pair.external, pair.change,
                          "external and change descriptors must derive different scripts")
    }

    /// The most important invariant in the product: the owner's device, the heir's
    /// device, and a pure watch-only build of the descriptor must all derive the
    /// SAME addresses. Otherwise heir recovery would scan an empty wallet.
    func testOwnerHeirAndWatchOnlyDeriveIdenticalAddresses() throws {
        let network = AppNetwork.signet
        let delay: UInt32 = 144

        let owner = try KeyService.parseMnemonic(Self.ownerWords)
        let heir = try KeyService.parseMnemonic(Self.heirWords)
        let ownerSecret = try KeyService.accountSecretKey(mnemonic: owner, network: network)
        let heirSecret = try KeyService.accountSecretKey(mnemonic: heir, network: network)
        let ownerPub = try KeyService.accountPublicKeyString(mnemonic: owner, network: network)
        let heirPub = try KeyService.accountPublicKeyString(mnemonic: heir, network: network)

        let ownerSide = try InheritanceDescriptor.descriptorStrings(
            signerKey: ownerSecret, otherKey: heirPub, signerIsOwner: true, delayBlocks: delay
        )
        let heirSide = try InheritanceDescriptor.descriptorStrings(
            signerKey: heirSecret, otherKey: ownerPub, signerIsOwner: false, delayBlocks: delay
        )
        let watchOnly = try InheritanceDescriptor.publicDescriptorStrings(
            ownerKey: ownerPub, heirKey: heirPub, delayBlocks: delay
        )

        for (a, b, c) in [(ownerSide.external, heirSide.external, watchOnly.external),
                          (ownerSide.change, heirSide.change, watchOnly.change)] {
            for index: UInt32 in [0, 1, 7] {
                let da = try InheritanceDescriptor.parse(a, network: network)
                    .deriveAddress(index: index, network: network.bdkNetwork)
                let db = try InheritanceDescriptor.parse(b, network: network)
                    .deriveAddress(index: index, network: network.bdkNetwork)
                let dc = try InheritanceDescriptor.parse(c, network: network)
                    .deriveAddress(index: index, network: network.bdkNetwork)
                XCTAssertEqual(da.description, db.description, "owner vs heir derivation diverged at \(index)")
                XCTAssertEqual(da.description, dc.description, "watch-only derivation diverged at \(index)")
            }
        }
    }

    func testDescriptorIsDeterministic() throws {
        let owner = try KeyService.parseMnemonic(Self.ownerWords)
        let heir = try KeyService.parseMnemonic(Self.heirWords)
        let heirPub = try KeyService.accountPublicKeyString(mnemonic: heir, network: .signet)
        let k1 = try KeyService.accountSecretKey(mnemonic: owner, network: .signet)
        let k2 = try KeyService.accountSecretKey(mnemonic: owner, network: .signet)
        let s1 = try InheritanceDescriptor.descriptorStrings(signerKey: k1, otherKey: heirPub, signerIsOwner: true, delayBlocks: 144)
        let s2 = try InheritanceDescriptor.descriptorStrings(signerKey: k2, otherKey: heirPub, signerIsOwner: true, delayBlocks: 144)
        XCTAssertEqual(s1, s2)
    }

    func testMnemonicValidation() {
        XCTAssertThrowsError(try KeyService.parseMnemonic("not a real phrase at all"))
        XCTAssertThrowsError(try KeyService.parseMnemonic(""))
        XCTAssertNoThrow(try KeyService.parseMnemonic(Self.heirWords))
        // Whitespace/case normalization
        let mangled = "  " + Self.heirWords.uppercased().replacingOccurrences(of: " ", with: "   ") + " \n"
        XCTAssertNoThrow(try KeyService.parseMnemonic(mangled))
    }

    func testGeneratedMnemonicsAreUniqueAndValid() {
        let a = KeyService.generateMnemonic().description
        let b = KeyService.generateMnemonic().description
        XCTAssertNotEqual(a, b, "two generated seeds must never collide")
        XCTAssertEqual(a.split(separator: " ").count, 12)
        XCTAssertNoThrow(try KeyService.parseMnemonic(a))
    }

    // MARK: Recovery kit

    func testRecoveryKitRoundTrip() throws {
        let heir = try KeyService.parseMnemonic(Self.heirWords)
        let owner = try KeyService.parseMnemonic(Self.ownerWords)
        let kit = RecoveryKit(
            network: .signet,
            delayBlocks: 144,
            ownerAccountKey: try KeyService.accountPublicKeyString(mnemonic: owner, network: .signet),
            heirAccountKey: try KeyService.accountPublicKeyString(mnemonic: heir, network: .signet),
            heirFingerprint: try KeyService.masterFingerprint(mnemonic: heir, network: .signet),
            createdAt: Date()
        )
        let json = try kit.encodeToJSON()
        let decoded = try RecoveryKit.decode(fromJSON: json)
        XCTAssertEqual(decoded.ownerAccountKey, kit.ownerAccountKey)
        XCTAssertEqual(decoded.heirAccountKey, kit.heirAccountKey)
        XCTAssertEqual(decoded.delayBlocks, kit.delayBlocks)
        XCTAssertTrue(kit.humanReadableDocument().contains(json.prefix(20)))
    }

    func testRecoveryKitRejectsGarbage() {
        XCTAssertThrowsError(try RecoveryKit.decode(fromJSON: "hello"))
        XCTAssertThrowsError(try RecoveryKit.decode(fromJSON: "{\"type\":\"something-else\",\"v\":1}"))
        // Valid JSON shape but out-of-range delay must be rejected.
        let bad = """
        {"v":1,"type":"heirloom-recovery-kit","network":"signet","delayBlocks":70000,
         "ownerAccountKey":"x","heirAccountKey":"y","heirFingerprint":"z",
         "createdAt":"2026-01-01T00:00:00Z"}
        """
        XCTAssertThrowsError(try RecoveryKit.decode(fromJSON: bad))
    }
}
