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
    /// Local regtest — never offered in the UI; exists for the integration test
    /// suite, which runs the full inheritance lifecycle against a local node.
    case regtest
    #if MAINNET_ENABLED
    case mainnet
    #endif

    var id: String { rawValue }

    var bdkNetwork: Network {
        switch self {
        case .signet: return .signet
        case .regtest: return .regtest
        #if MAINNET_ENABLED
        case .mainnet: return .bitcoin
        #endif
        }
    }

    var bdkNetworkKind: NetworkKind {
        switch self {
        case .signet, .regtest: return .test
        #if MAINNET_ENABLED
        case .mainnet: return .main
        #endif
        }
    }

    /// BIP-44 coin type used in derivation paths.
    var coinType: UInt32 {
        switch self {
        case .signet, .regtest: return 1
        #if MAINNET_ENABLED
        case .mainnet: return 0
        #endif
        }
    }

    var defaultEsploraURL: String {
        switch self {
        case .signet: return "https://mempool.space/signet/api"
        case .regtest: return "tcp://127.0.0.1:60401"
        #if MAINNET_ENABLED
        case .mainnet: return "https://mempool.space/api"
        #endif
        }
    }

    var displayName: String {
        switch self {
        case .signet: return "Signet (test network)"
        case .regtest: return "Regtest (local development)"
        #if MAINNET_ENABLED
        case .mainnet: return "Mainnet — NOT AUDITED, DO NOT USE WITH REAL FUNDS"
        #endif
        }
    }

    /// Explorer base URL for viewing transactions in a browser.
    var explorerTxURL: String {
        switch self {
        case .signet: return "https://mempool.space/signet/tx/"
        case .regtest: return "http://127.0.0.1/tx/"
        #if MAINNET_ENABLED
        case .mainnet: return "https://mempool.space/tx/"
        #endif
        }
    }
}
