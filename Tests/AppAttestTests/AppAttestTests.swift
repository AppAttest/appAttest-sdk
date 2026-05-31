import XCTest
@testable import AppAttest

final class AppAttestTests: XCTestCase {
    func testVersionString() {
        XCTAssertFalse(AppAttestSDK.version.isEmpty)
        XCTAssertEqual(AppAttestSDK.apiVersion, "v1")
    }
}
