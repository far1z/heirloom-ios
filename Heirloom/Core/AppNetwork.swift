import Foundation
import BitcoinDevKit

/// The networks Heirloom can run on.
///
/// Signet is the default and the only network compiled into release builds.
/// Mainnet exists strictly behind the `MAINNET_ENABLED` compilation condition,
/// which is OFF in every checked-in configuration.
///
/// NOT AUDITED — DO NOT USE WITH REAL FUNDS.
enum AppNetwork: String, Codable, CaseIterable, Identifiable {
    case signet
    #if MAINNET_ENABLED
    case mainnet
    #endif

    var id: String { rawValue }

    var bdkNetwork: Network {
        switch self {
        case .signet: return .signet
        #if MAINNET_ENABLED
        case .mainnet: return .bitcoin
        #endif
        }
    }

    var bdkNetworkKind: NetworkKind {
        switch self {
        case .signet: return .test
        #if MAINNET_ENABLED
        case .mainnet: return .main
        #endif
        }
    }

    /// BIP-44 coin type used in derivation paths.
    var coinType: UInt32 {
        switch self {
        case .signet: return 1
        #if MAINNET_ENABLED
        case .mainnet: return 0
        #endif
        }
    }

    var defaultEsploraURL: String {
        switch self {
        case .signet: return "https://mempool.space/signet/api"
        #if MAINNET_ENABLED
        case .mainnet: return "https://mempool.space/api"
        #endif
        }
    }

    var displayName: String {
        switch self {
        case .signet: return "Signet (test network)"
        #if MAINNET_ENABLED
        case .mainnet: return "Mainnet — NOT AUDITED, DO NOT USE WITH REAL FUNDS"
        #endif
        }
    }

    /// Explorer base URL for viewing transactions in a browser.
    var explorerTxURL: String {
        switch self {
        case .signet: return "https://mempool.space/signet/tx/"
        #if MAINNET_ENABLED
        case .mainnet: return "https://mempool.space/tx/"
        #endif
        }
    }
}
