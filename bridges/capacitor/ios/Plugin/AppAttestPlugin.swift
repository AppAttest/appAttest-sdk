// AppAttestPlugin.swift — iOS Capacitor plugin.
//
// Exposed to JS as `AppAttest`. Surface: start / waitForReady /
// retry / reset / getSecret / getAllSecrets / getState plus
// `stateChanged` listener events.
//
// 402 envelope: each code carries a single URL key matching the code.
//   subscription_required  → subscribeUrl
//   credits_required       → topupUrl
// Both are forwarded; the JS side picks whichever matches.

import Foundation
import Capacitor
import AppAttestObjC

@objc(AppAttestPlugin)
public class AppAttestPlugin: CAPPlugin, CAPBridgedPlugin {

    public var identifier = "AppAttestPlugin"
    public var jsName = "AppAttest"
    public var pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "waitForReady", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "retry", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reset", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "invalidateBundle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSecret", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAllSecrets", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDebugMode", returnType: CAPPluginReturnPromise),
    ]

    private let client = AppAttestObjCClient.shared
    private var stateToken: AppAttestObservationToken?

    public override func load() {
        super.load()
        // Wire state observation. notifyListeners is a no-op when there
        // are no JS subscribers, so the cost is one main-actor listener.
        stateToken?.invalidate()
        stateToken = client.addStateObserver { [weak self] state in
            guard let self else { return }
            self.notifyListeners("stateChanged", data: Self.encodeState(state))
        }
    }

    /// Build the JSON-safe state payload for `stateChanged` events and
    /// `getState` resolves. Forwards every 402 URL key (`subscribeUrl`,
    /// `topupUrl`) so JS can branch on whichever matches.
    private static func encodeState(_ state: AppAttestState) -> [String: Any] {
        var body: [String: Any] = ["name": state.name]
        if let err = state.error {
            var e: [String: Any] = [
                "code": (err.userInfo["code"] as? String) ?? "internal_error",
                "message": (err.userInfo["message"] as? String) ?? err.localizedDescription
            ]
            if let url = err.userInfo["subscribeUrl"] as? String { e["subscribeUrl"] = url }
            if let url = err.userInfo["topupUrl"] as? String { e["topupUrl"] = url }
            body["error"] = e
        }
        return body
    }

    deinit {
        stateToken?.invalidate()
    }

    // MARK: - Lifecycle

    @objc func start(_ call: CAPPluginCall) {
        client.start()
        call.resolve()
    }

    @objc func waitForReady(_ call: CAPPluginCall) {
        client.waitForReady { error in
            Self.complete(error: error, call: call)
        }
    }

    @objc func retry(_ call: CAPPluginCall) {
        client.retry()
        call.resolve()
    }

    @objc func reset(_ call: CAPPluginCall) {
        client.reset { error in
            Self.complete(error: error, call: call)
        }
    }

    @objc func invalidateBundle(_ call: CAPPluginCall) {
        client.invalidateBundle()
        call.resolve()
    }

    // MARK: - Reads

    @objc func getSecret(_ call: CAPPluginCall) {
        guard let name = call.getString("name") else {
            call.reject("name is required", "invalid_argument")
            return
        }
        DispatchQueue.main.async {
            let value = self.client.secret(forKey: name)
            if let value {
                call.resolve(["value": value])
            } else {
                call.resolve(["value": NSNull()])
            }
        }
    }

    @objc func getAllSecrets(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(["secrets": self.client.allSecrets()])
        }
    }

    @objc func getState(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(Self.encodeState(self.client.currentState()))
        }
    }

    // MARK: - Configuration

    @objc func setDebugMode(_ call: CAPPluginCall) {
        let name = call.getString("name") // nil OK -> production
        let stubs = call.getObject("stubs") as? [String: String]
        client.setDebugMode(name, stubs: stubs) { error in
            Self.complete(error: error, call: call)
        }
    }

    // setApiBaseUrl is not exposed — base URL is hardcoded in the Swift
    // SDK (https://edge.appattest.dev). No way to point this plugin at
    // any other endpoint from a published binary; that's the model.

    // MARK: - Promise plumbing

    private static func complete(error: NSError?, call: CAPPluginCall) {
        if let error {
            let code = (error.userInfo["code"] as? String) ?? "internal_error"
            let message = (error.userInfo["message"] as? String) ?? error.localizedDescription
            var data: [String: Any] = [:]
            if let url = error.userInfo["subscribeUrl"] as? String { data["subscribeUrl"] = url }
            if let url = error.userInfo["topupUrl"] as? String { data["topupUrl"] = url }
            if data.isEmpty {
                call.reject(message, code, error)
            } else {
                call.reject(message, code, error, data)
            }
        } else {
            call.resolve()
        }
    }
}
