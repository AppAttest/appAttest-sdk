import XCTest
@testable import AppAttest

final class AppAttestErrorTests: XCTestCase {

    private let subscribe = URL(string: "https://app.appattest.dev/projects/proj_01HX/subscribe")!
    private let topup = URL(string: "https://app.appattest.dev/projects/proj_01HX/billing")!

    func testV7ErrorCodes() {
        XCTAssertEqual(AppAttestError.subscriptionRequired(subscribeUrl: subscribe).code, "subscription_required")
        XCTAssertEqual(AppAttestError.creditsRequired(topupUrl: topup).code, "credits_required")
        XCTAssertEqual(AppAttestError.attestationRejected(reason: "x").code, "attestation_rejected")
        XCTAssertEqual(AppAttestError.serviceUnavailable(reason: "x").code, "service_unavailable")
        XCTAssertEqual(AppAttestError.network(underlying: NSError(domain: "x", code: 0)).code, "network")
    }

    func test402AccessorsCarryActionUrl() {
        // 402 cases carry only the deep-link URL — projectId is gone
        // (the URL already encodes any project routing in its path).
        let sub = AppAttestError.subscriptionRequired(subscribeUrl: subscribe)
        XCTAssertEqual(sub.actionUrl, subscribe)

        let cred = AppAttestError.creditsRequired(topupUrl: topup)
        XCTAssertEqual(cred.actionUrl, topup)

        // Non-402 cases carry no URL.
        XCTAssertNil(AppAttestError.attestationRejected(reason: "x").actionUrl)
        XCTAssertNil(AppAttestError.serviceUnavailable(reason: "x").actionUrl)
        XCTAssertNil(AppAttestError.network(underlying: NSError(domain: "x", code: 0)).actionUrl)
    }

    func testEquality() {
        XCTAssertEqual(
            AppAttestError.subscriptionRequired(subscribeUrl: subscribe),
            AppAttestError.subscriptionRequired(subscribeUrl: subscribe)
        )
        XCTAssertNotEqual(
            AppAttestError.subscriptionRequired(subscribeUrl: subscribe),
            AppAttestError.creditsRequired(topupUrl: topup)
        )
        XCTAssertEqual(
            AppAttestError.attestationRejected(reason: "x"),
            AppAttestError.attestationRejected(reason: "x")
        )
        XCTAssertNotEqual(
            AppAttestError.attestationRejected(reason: "a"),
            AppAttestError.attestationRejected(reason: "b")
        )
        XCTAssertEqual(
            AppAttestError.serviceUnavailable(reason: "detail-x"),
            AppAttestError.serviceUnavailable(reason: "detail-x")
        )
        XCTAssertNotEqual(
            AppAttestError.serviceUnavailable(reason: "detail-x"),
            AppAttestError.network(underlying: NSError(domain: "x", code: 0))
        )
    }

    func testDescriptionsAreTerseAndOnBrand() {
        let samples: [AppAttestError] = [
            .subscriptionRequired(subscribeUrl: subscribe),
            .creditsRequired(topupUrl: topup),
            .attestationRejected(reason: "test"),
            .serviceUnavailable(reason: "test"),
            .network(underlying: NSError(domain: "x", code: 0))
        ]
        let banned = ["seamlessly", "unlock", "empower", "elevate", "free"]
        for e in samples {
            let text = e.description.lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word), "banned word '\(word)' in: \(e.description)")
            }
            XCTAssertLessThan(e.description.count, 300, "too chatty: \(e.description)")
            XCTAssertTrue(text.contains("appattest"), "missing brand prefix: \(e.description)")
        }
    }

    func testStateMappingFromErrorCases() {
        // Error case → state routing.
        let sub = AppAttestError.subscriptionRequired(subscribeUrl: subscribe)
        let cred = AppAttestError.creditsRequired(topupUrl: topup)
        let att = AppAttestError.attestationRejected(reason: "test")
        let svc = AppAttestError.serviceUnavailable(reason: "edge 5xx")
        let net = AppAttestError.network(underlying: NSError(domain: "x", code: 0))

        XCTAssertEqual(AppAttestClient.State.subscriptionRequired(sub), .subscriptionRequired(sub))
        XCTAssertEqual(AppAttestClient.State.creditsRequired(cred), .creditsRequired(cred))
        XCTAssertEqual(AppAttestClient.State.unavailable(att), .unavailable(att))
        XCTAssertEqual(AppAttestClient.State.unavailable(svc), .unavailable(svc))
        XCTAssertEqual(AppAttestClient.State.unavailable(net), .unavailable(net))

        XCTAssertNotEqual(
            AppAttestClient.State.subscriptionRequired(sub),
            .creditsRequired(cred)
        )
    }
}
