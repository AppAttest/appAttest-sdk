import XCTest
@testable import AppAttest

final class APIModelsTests: XCTestCase {

    func testAttestRequestEncodesSnakeCase() throws {
        // AttestRequest carries team_id + bundle_id + the attestation
        // material. NO env_bucket — edge derives the bucket from Apple's
        // AAGUID in authData server-side. NO project_id on the wire.
        let req = AttestRequest(
            teamId: "T",
            keyId: "k",
            bundleId: "com.acme.notes",
            attestation: "a",
            challenge: "c"
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["team_id"] as? String, "T")
        XCTAssertEqual(json["key_id"] as? String, "k")
        XCTAssertEqual(json["bundle_id"] as? String, "com.acme.notes")
        XCTAssertEqual(json["attestation"] as? String, "a")
        XCTAssertEqual(json["challenge"] as? String, "c")
        // Bucket is AAGUID-derived; never on the SDK wire.
        XCTAssertNil(json["env_bucket"])
        XCTAssertNil(json["envBucket"])
        // No project_id on the wire (regression guard).
        XCTAssertNil(json["project_id"])
        XCTAssertNil(json["projectId"])
        // Defensive: don't accidentally emit camelCase next to snake_case.
        XCTAssertNil(json["teamId"])
    }

    func testAttestResponseDecodesSnakeCase() throws {
        let payload = #"{"attest_token":"eyJhbGc..."}"#
        let decoded = try JSONDecoder().decode(AttestResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.attestToken, "eyJhbGc...")
    }

    func testSyncRequestBodyIsIdentityAndBucketFree() throws {
        // Identity (team_id, bundle_id) AND env_bucket all live in
        // the signed attestToken claims. Body carries only attest_token
        // (+ optional fingerprint). Assertion is in the
        // X-AppAttest-Assertion header.
        let req = SyncRequest(
            attestToken: "tok",
            fingerprint: "fp"
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["attest_token"] as? String, "tok")
        XCTAssertEqual(json["fingerprint"] as? String, "fp")
        // Bucket is in the signed token, not on the wire.
        XCTAssertNil(json["env_bucket"])
        XCTAssertNil(json["envBucket"])
        // Identity not on the wire.
        XCTAssertNil(json["team_id"])
        XCTAssertNil(json["project_id"])
        XCTAssertNil(json["bundle_id"])
        XCTAssertNil(json["assertion"])
    }

    func testEventsRequestBodyIsIdentityAndBucketFree() throws {
        // Same shape rules as sync — only attest_token + events.
        let req = EventsRequest(
            attestToken: "tok",
            events: [.object(["name": .string("login")])]
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["attest_token"] as? String, "tok")
        XCTAssertNotNil(json["events"])
        // Bucket is in the signed token, not on the wire.
        XCTAssertNil(json["env_bucket"])
        XCTAssertNil(json["envBucket"])
        // Identity not on the wire.
        XCTAssertNil(json["team_id"])
        XCTAssertNil(json["project_id"])
        XCTAssertNil(json["bundle_id"])
        XCTAssertNil(json["assertion"])
    }

    func testSyncResponseDecodes() throws {
        let payload = #"""
        {"fingerprint":"sha256:abc","secrets":[
          {"key":"A","value":"1"},
          {"key":"B","value":"2"}
        ],"attest_token":"eyJhbGc..."}
        """#
        let decoded = try JSONDecoder().decode(SyncResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.fingerprint, "sha256:abc")
        XCTAssertEqual(decoded.secrets.count, 2)
        XCTAssertEqual(decoded.secrets[0].key, "A")
        XCTAssertEqual(decoded.secrets[1].value, "2")
        XCTAssertEqual(decoded.attestToken, "eyJhbGc...")
    }

    func testSyncResponseDecodesWithoutRefreshedToken() throws {
        let payload = #"""
        {"fingerprint":"sha256:abc","secrets":[]}
        """#
        let decoded = try JSONDecoder().decode(SyncResponse.self, from: Data(payload.utf8))
        XCTAssertNil(decoded.attestToken)
    }

    func testSyncNotModifiedDecodes() throws {
        let payload = #"{"fingerprint":"sha256:abc","attest_token":"new"}"#
        let decoded = try JSONDecoder().decode(SyncNotModifiedResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.fingerprint, "sha256:abc")
        XCTAssertEqual(decoded.attestToken, "new")

        let stripped = #"{"fingerprint":"sha256:abc"}"#
        let bare = try JSONDecoder().decode(SyncNotModifiedResponse.self, from: Data(stripped.utf8))
        XCTAssertNil(bare.attestToken)
    }

    func testErrorEnvelopeDecodesV7Codes() throws {
        // Edge ships a FLAT envelope, not nested under `error`.
        // Earlier versions of this test had the nested shape — that test
        // was self-consistent with the SDK's (also-wrong) APIErrorEnvelope
        // schema, so a real cross-side bug shipped silently: real edge
        // 401/402 responses landing as .network with raw JSON instead of
        // typed states.
        let subscriptionPayload = #"""
        {"code":"subscription_required","message":"subscribe","subscribe_url":"https://app.appattest.dev/projects/proj_01HX/subscribe"}
        """#
        let sub = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(subscriptionPayload.utf8))
        XCTAssertEqual(sub.code, "subscription_required")
        XCTAssertEqual(sub.subscribeUrl, "https://app.appattest.dev/projects/proj_01HX/subscribe")
        XCTAssertNil(sub.topupUrl)

        let creditsPayload = #"""
        {"code":"credits_required","message":"top up","topup_url":"https://app.appattest.dev/projects/proj_01HX/billing"}
        """#
        let cred = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(creditsPayload.utf8))
        XCTAssertEqual(cred.code, "credits_required")
        XCTAssertEqual(cred.topupUrl, "https://app.appattest.dev/projects/proj_01HX/billing")
        XCTAssertNil(cred.subscribeUrl)
    }

    func testErrorEnvelopeDecodesAttestationFailureFromEdgeFaultInject() throws {
        // Real captured attestation-failure response from edge. Before
        // the schema fix, this body decoded as nil and the SDK fell
        // through to .network with raw JSON shown to the user.
        let payload = #"""
        {"code":"attestation_failed","message":"attestation failed: fault_injected"}
        """#
        let env = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(payload.utf8))
        XCTAssertEqual(env.code, "attestation_failed")
        XCTAssertEqual(env.message, "attestation failed: fault_injected")
        XCTAssertNil(env.subscribeUrl)
        XCTAssertNil(env.topupUrl)
    }
}
