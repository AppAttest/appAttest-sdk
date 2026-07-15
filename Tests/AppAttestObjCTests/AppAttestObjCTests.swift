import XCTest
import AppAttest
@testable import AppAttestObjC

/// `AppAttestObjC` is a thin wrapper. These tests cover the boundary —
/// completion-handler shape, NSError envelope, debug-mode string parsing,
/// state observer dispatch, sync secret lookup.
@MainActor
final class AppAttestObjCTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        AppAttestClient.shared.reset()
    }

    func testSingletonIsStable() {
        XCTAssertTrue(AppAttestObjCClient.shared === AppAttestObjCClient.shared)
    }

    func testDebugModeRejectsUnknownName() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            AppAttestObjCClient.shared.setDebug("nope", stubs: nil) { error in
                if let error {
                    XCTAssertEqual(error.domain, AppAttestErrorDomain)
                    XCTAssertEqual(error.userInfo["code"] as? String, "invalid_argument")
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(domain: "test", code: 0))
                }
            }
        }
    }

    func testLocalModeServesStubsViaSecretForKey() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            AppAttestObjCClient.shared.setDebug("local", stubs: ["A": "1", "B": "2"]) { error in
                if let e = error { cont.resume(throwing: e) } else { cont.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            AppAttestObjCClient.shared.start(release: "production") { error in
                if let e = error { cont.resume(throwing: e) } else { cont.resume() }
            }
        }

        // waitForReady completes once the local stubs hydrate.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            AppAttestObjCClient.shared.waitForReady { error in
                if let e = error { cont.resume(throwing: e) } else { cont.resume() }
            }
        }

        XCTAssertEqual(AppAttestObjCClient.shared.secret(forKey: "A") as String?, "1")
        XCTAssertNil(AppAttestObjCClient.shared.secret(forKey: "missing"))
        XCTAssertEqual(AppAttestObjCClient.shared.allSecrets(), ["A": "1", "B": "2"])

        XCTAssertEqual(AppAttestObjCClient.shared.currentState().name, "ready")
    }

    func testStateObserverFiresOnTransitions() async throws {
        var observed: [String] = []
        let exp = expectation(description: "ready observed")
        let token = AppAttestObjCClient.shared.addStateObserver { state in
            observed.append(state.name)
            if state.name == "ready" { exp.fulfill() }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            AppAttestObjCClient.shared.setDebug("local", stubs: ["A": "1"]) { error in
                if let e = error { cont.resume(throwing: e) } else { cont.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            AppAttestObjCClient.shared.start(release: "production") { error in
                if let e = error { cont.resume(throwing: e) } else { cont.resume() }
            }
        }

        await fulfillment(of: [exp], timeout: 5)
        XCTAssertTrue(observed.contains("ready"))

        token.invalidate()
    }
}
