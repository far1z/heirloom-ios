import XCTest
import BitcoinDevKit

final class SmokeTests: XCTestCase {
    func testBDKLinks() throws {
        let m = Mnemonic(wordCount: .words12)
        XCTAssertFalse(m.description.isEmpty)
    }
}
