import Foundation

/// A non-fatal Keychain persistence failure. The associated sync/attest
/// operation still succeeded in memory — this reports only that the SDK
/// could not *cache* the result, so it will repeat the work on next launch.
/// Carries no secret material; only the artifact, the operation, and the
/// underlying Security-framework OSStatus.
public struct PersistenceError: Error, Sendable, Equatable, CustomStringConvertible {

    public enum Artifact: String, Sendable, Equatable {
        case secrets       // the synced SecretBundle (fingerprint + values)
        case credentials   // the attestToken + keyId
    }

    public enum Operation: String, Sendable, Equatable {
        case save
        case delete
        case load
    }

    public let artifact: Artifact
    public let operation: Operation
    /// Underlying `SecItem*` return code (Security framework OSStatus).
    /// A sentinel (`errSecInternalError`) is used for non-Keychain throws.
    public let osStatus: Int32

    public init(artifact: Artifact, operation: Operation, osStatus: Int32) {
        self.artifact = artifact
        self.operation = operation
        self.osStatus = osStatus
    }

    /// True when this failure causes avoidable re-work — and possibly a
    /// re-sync credit charge — on next launch (the secrets bundle or a live
    /// credential could not be cached, or the cache could not be read).
    /// `delete` failures are never credit-impacting.
    public var isCreditImpacting: Bool { operation != .delete }

    public var description: String {
        "AppAttest: Keychain \(operation.rawValue) of \(artifact.rawValue) "
        + "failed (OSStatus \(osStatus)). The operation succeeded in memory but "
        + "could not be persisted; the SDK will repeat it on next launch"
        + (isCreditImpacting ? " (a re-sync consumes one credit)." : ".")
    }
}
