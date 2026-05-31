// AppAttestPlugin.swift — iOS plugin for the appattest_flutter package.
//
// Implements the Pigeon-generated `AppAttestHostApi` (in Messages.g.swift)
// over the AppAttest SDK. State transitions are streamed to Dart on a
// separate Flutter EventChannel ('dev.appattest.sdk/state').
//
// 402 envelope: each code carries a single URL key matching the code.
//   subscription_required  → subscribeUrl
//   credits_required       → topupUrl
// Both are forwarded as separate optionals; the Dart side picks whichever
// matches the current state.

import Flutter
import UIKit
import AppAttest

public class AppAttestPlugin: NSObject, FlutterPlugin, AppAttestHostApi {

    private var stateSink: FlutterEventSink?
    private var stateTask: Task<Void, Never>?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AppAttestPlugin()
        AppAttestHostApiSetup.setUp(
            binaryMessenger: registrar.messenger(),
            api: instance
        )
        let stateChannel = FlutterEventChannel(
            name: "dev.appattest.sdk/state",
            binaryMessenger: registrar.messenger()
        )
        stateChannel.setStreamHandler(StateStreamHandler(plugin: instance))
    }

    // MARK: - AppAttestHostApi

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            AppAttestClient.shared.start()
            completion(.success(()))
        }
    }

    func waitForReady(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            do {
                try await AppAttestClient.shared.waitForReady()
                completion(.success(()))
            } catch {
                completion(.failure(translate(error)))
            }
        }
    }

    func retry(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            AppAttestClient.shared.retry()
            completion(.success(()))
        }
    }

    func reset(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            AppAttestClient.shared.reset()
            completion(.success(()))
        }
    }

    func invalidateBundle(completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            AppAttestClient.shared.invalidateBundle()
            completion(.success(()))
        }
    }

    func getSecret(
        name: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        Task { @MainActor in
            completion(.success(AppAttestClient.shared.secrets[name]))
        }
    }

    func getAllSecrets(completion: @escaping (Result<[String: String], Error>) -> Void) {
        Task { @MainActor in
            completion(.success(AppAttestClient.shared.secrets))
        }
    }

    func getState(completion: @escaping (Result<AppAttestStatePayload, Error>) -> Void) {
        Task { @MainActor in
            completion(.success(Self.snapshot(AppAttestClient.shared.state)))
        }
    }

    func setDebugMode(
        name: String?,
        stubs: [String: String]?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task { @MainActor in
            switch name {
            case nil, "production":
                // `debugMode` is #if DEBUG-only in the SDK; in Release there is
                // nothing to clear (production is the only mode), so guard the
                // write or the plugin fails to compile for Release.
                #if DEBUG
                AppAttestClient.shared.debugMode = nil
                #endif
                completion(.success(()))
            #if DEBUG
            case "local":
                AppAttestClient.shared.debugMode = .local(stubs: stubs ?? [:])
                completion(.success(()))
            #else
            case "local":
                completion(.failure(asFlutterError(
                    code: "debug_mode_release_blocked",
                    message: "\"local\" is debug-only and not available in Release builds.",
                    details: nil
                )))
            #endif
            default:
                completion(.failure(asFlutterError(
                    code: "invalid_argument",
                    message: "unknown debug mode: \(name ?? "<nil>")",
                    details: nil
                )))
            }
        }
    }

    // setApiBaseUrl is not exposed — base URL hardcoded in Swift SDK.

    // MARK: - State stream

    fileprivate func startStateStream(sink: @escaping FlutterEventSink) {
        stateSink = sink
        stateTask?.cancel()
        var lastSent: AppAttestClient.State = .initializing
        stateTask = Task { @MainActor [weak self] in
            // Emit current state immediately, then poll for transitions.
            guard let self else { return }
            self.stateSink?(Self.encodeForChannel(AppAttestClient.shared.state))
            lastSent = AppAttestClient.shared.state
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                let now = AppAttestClient.shared.state
                if now != lastSent {
                    lastSent = now
                    self.stateSink?(Self.encodeForChannel(now))
                }
            }
        }
    }

    fileprivate func stopStateStream() {
        stateTask?.cancel()
        stateTask = nil
        stateSink = nil
    }

    // MARK: - Helpers

    private static func snapshot(_ s: AppAttestClient.State) -> AppAttestStatePayload {
        let (name, err) = describe(s)
        return AppAttestStatePayload(
            name: name,
            errorCode: err?.code,
            errorMessage: err?.description,
            errorSubscribeUrl: urlField(err, .subscribe),
            errorTopupUrl: urlField(err, .topup)
        )
    }

    private static func encodeForChannel(_ s: AppAttestClient.State) -> [String: Any] {
        let (name, err) = describe(s)
        var body: [String: Any] = ["name": name]
        if let err {
            var e: [String: Any] = ["code": err.code, "message": err.description]
            if let url = urlField(err, .subscribe) { e["subscribeUrl"] = url }
            if let url = urlField(err, .topup) { e["topupUrl"] = url }
            body["error"] = e
        }
        return body
    }

    private static func describe(_ s: AppAttestClient.State) -> (String, AppAttestError?) {
        switch s {
        case .initializing: return ("initializing", nil)
        case .attesting: return ("attesting", nil)
        case .syncing: return ("syncing", nil)
        case .ready: return ("ready", nil)
        case .subscriptionRequired(let e): return ("subscription_required", e)
        case .creditsRequired(let e): return ("credits_required", e)
        case .unavailable(let e): return ("unavailable", e)
        }
    }

    private enum URLField { case subscribe, topup }

    /// Returns the URL string only if `err` is the matching 402 case for
    /// `field`. Keeps each Dart-side optional populated independently.
    private static func urlField(_ err: AppAttestError?, _ field: URLField) -> String? {
        guard let err else { return nil }
        switch (err, field) {
        case (.subscriptionRequired(let u), .subscribe): return u.absoluteString
        case (.creditsRequired(let u), .topup): return u.absoluteString
        default: return nil
        }
    }

    private func translate(_ error: Error) -> Error {
        if let app = error as? AppAttestError {
            var details: [String: Any] = [:]
            if let url = Self.urlField(app, .subscribe) { details["subscribeUrl"] = url }
            if let url = Self.urlField(app, .topup) { details["topupUrl"] = url }
            return asFlutterError(
                code: app.code,
                message: app.description,
                details: details.isEmpty ? nil : details
            )
        }
        return asFlutterError(code: "internal_error", message: String(describing: error), details: nil)
    }

    private func asFlutterError(code: String, message: String, details: Any?) -> AppAttestFlutterError {
        AppAttestFlutterError(code: code, message: message, details: details)
    }
}

private class StateStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: AppAttestPlugin?
    init(plugin: AppAttestPlugin) { self.plugin = plugin }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        plugin?.startStateStream(sink: events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.stopStateStream()
        return nil
    }
}
