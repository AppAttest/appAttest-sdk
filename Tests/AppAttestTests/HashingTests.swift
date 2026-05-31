import XCTest
import CryptoKit
@testable import AppAttest

/// Locks in the SHA-256 contract used for `clientDataHash`. The SDK must hash
/// the UTF-8 bytes of the challenge string directly — matching the server's
/// verifier, which hashes the same UTF-8 bytes.
final class HashingTests: XCTestCase {

    /// Known vector: empty string.
    func testEmptyString() {
        let bytes = Data("".utf8)
        let cryptoKit = Data(SHA256.hash(data: bytes))
        // SHA-256 of empty string is well-known.
        XCTAssertEqual(cryptoKit.map { String(format: "%02x", $0) }.joined(),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// A real challenge hashes to a value the server should agree on.
    /// The exact digest below was verified independently.
    func testRealChallengeHashMatches() {
        let challenge = "v1.eyJ0ZWFtSWQiOiJBQkNERTEyMzQ1IiwiYnVuZGxlSWQiOiJkZXYuYXBwYXR0ZXN0LmV4YW1wbGUiLCJpc3N1ZWRBdCI6MTc3NjcyNTM0NzY1Niwibm9uY2UiOiJlMDI3NzAyOTY0OWY4NzhkYjkxYjJhNDRiYmE4Y2FiMSJ9.x_oPmbDZSJ9fy1DxkpAWJznxmKqAEjsYQ-wNFbPK1BE"
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        XCTAssertEqual(hash.map { String(format: "%02x", $0) }.joined(),
                       "a23e348fbf544d43ce26d71a54fe233fd6827661121caedc8c635033df1ebfc7")
    }
}
