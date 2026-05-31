import XCTest
@testable import AppAttest

final class CredentialsTests: XCTestCase {

    func testIsExpiredTrueWhenPastExpiry() {
        let now = Date()
        let c = AttestCredentials(keyId: "k", token: "t", expiresIn: 10, now: now)
        XCTAssertFalse(c.isExpired(now: now))
        XCTAssertTrue(c.isExpired(now: now.addingTimeInterval(11)))
    }

    func testIsExpiringSoonRespectsLeeway() {
        let now = Date()
        let c = AttestCredentials(keyId: "k", token: "t", expiresIn: 30, now: now)
        XCTAssertFalse(c.isExpiringSoon(now: now, leeway: 10))
        XCTAssertTrue(c.isExpiringSoon(now: now, leeway: 60))
    }

    func testDefaultTTLIs24Hours() {
        // attestTokens are 24h. Default constructor uses that.
        let c = AttestCredentials(keyId: "k", token: "t")
        let lifetime = c.tokenExpiresAt.timeIntervalSinceNow
        XCTAssertGreaterThan(lifetime, 86_000)
        XCTAssertLessThan(lifetime, 86_500)
    }

    func testUpdateTokenRefreshesExpiry() {
        var c = AttestCredentials(keyId: "k", token: "old", expiresIn: 10)
        let before = c.tokenExpiresAt
        c.updateToken("new")
        XCTAssertEqual(c.token, "new")
        XCTAssertGreaterThan(c.tokenExpiresAt, before)
    }

    func testCodableRoundTrip() throws {
        let c = AttestCredentials(keyId: "k", token: "t", expiresIn: 10)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(AttestCredentials.self, from: data)
        XCTAssertEqual(c, decoded)
    }
}
