// AppAttestModule.swift — iOS native module for @appattest/react-native.
//
// Adapter between React Native's module system and the AppAttest SDK's
// @objc facade (AppAttestObjC). Every method matches the TurboModule spec
// in ../src/NativeAppAttest.ts.
//
// Errors: rejection bodies carry { code, message,
// subscribeUrl? | topupUrl? }. The 402 envelope key matches the code:
// `subscription_required` → subscribeUrl; `credits_required` → topupUrl.
//
// State events: emitted on `stateChanged` whenever the SDK's state
// transitions. JS hooks subscribe via the `addStateListener` wrapper.

import Foundation
import AppAttestObjC
import React

@objc(AppAttestModule)
final class AppAttestModule: RCTEventEmitter {

    private let client = AppAttestObjCClient.shared
    private var stateToken: AppAttestObservationToken?
    private var hasJSListeners = false

    override static func requiresMainQueueSetup() -> Bool { false }

    // MARK: - Event emitter

    override func supportedEvents() -> [String]! { ["stateChanged"] }

    override func startObserving() {
        hasJSListeners = true
        stateToken?.invalidate()
        stateToken = client.addStateObserver { [weak self] state in
            guard let self else { return }
            self.sendEvent(withName: "stateChanged", body: Self.encodeState(state))
        }
    }

    /// Encode an `AppAttestState` for the JS bridge — flattens the nested
    /// NSError userInfo into a JSON-safe dict. Forwards every 402 URL key
    /// (`subscribeUrl`, `topupUrl`); JS picks whichever matches its current
    /// state.
    private static func encodeState(_ state: AppAttestState) -> [String: Any] {
        var body: [String: Any] = ["name": state.name]
        if let err = state.error {
            var errBody: [String: Any] = [
                "code": (err.userInfo["code"] as? String) ?? "internal_error",
                "message": (err.userInfo["message"] as? String) ?? err.localizedDescription
            ]
            if let url = err.userInfo["subscribeUrl"] as? String { errBody["subscribeUrl"] = url }
            if let url = err.userInfo["topupUrl"] as? String { errBody["topupUrl"] = url }
            body["error"] = errBody
        }
        return body
    }

    override func stopObserving() {
        hasJSListeners = false
        stateToken?.invalidate()
        stateToken = nil
    }

    // MARK: - Lifecycle

    @objc func start(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        client.start()
        resolve(NSNull())
    }

    @objc func waitForReady(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        client.waitForReady { error in
            Self.complete((), error: error, resolve: resolve, reject: reject)
        }
    }

    @objc func retry(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        client.retry()
        resolve(NSNull())
    }

    @objc func reset(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        client.reset { error in
            Self.complete((), error: error, resolve: resolve, reject: reject)
        }
    }

    @objc func invalidateBundle(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        client.invalidateBundle()
        resolve(NSNull())
    }

    // MARK: - Reads

    @objc func getSecret(
        _ name: NSString,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            let value = self.client.secret(forKey: name as String)
            resolve(value as Any? ?? NSNull())
        }
    }

    @objc func getAllSecrets(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            resolve(self.client.allSecrets())
        }
    }

    @objc func getState(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        DispatchQueue.main.async {
            resolve(Self.encodeState(self.client.currentState()))
        }
    }

    // MARK: - Configuration

    @objc func setDebugMode(
        _ name: NSString?,
        stubs: NSDictionary?,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let dict = (stubs as? [String: String]) ?? [:]
        client.setDebugMode(name as String?, stubs: dict.isEmpty ? nil : dict) { error in
            Self.complete((), error: error, resolve: resolve, reject: reject)
        }
    }

    // setApiBaseUrl is not exposed — the base URL is hardcoded in the
    // Swift SDK (https://edge.appattest.dev). No way to point at any
    // other URL from a published binary; that's the security model.

    // MARK: - Promise plumbing

    private static func complete<T>(
        _ value: T,
        error: NSError?,
        resolve: RCTPromiseResolveBlock,
        reject: RCTPromiseRejectBlock
    ) {
        if let error {
            let code = (error.userInfo["code"] as? String) ?? "internal_error"
            let message = (error.userInfo["message"] as? String) ?? error.localizedDescription
            reject(code, message, error)
        } else {
            resolve(value)
        }
    }
}
