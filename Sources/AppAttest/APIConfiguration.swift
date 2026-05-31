import Foundation

/// Base URL configuration for AppAttest.
///
/// The SDK base URL is hardcoded in checked-in source. There is no public
/// constructor argument, no Info.plist override, and no environment variable
/// read at SDK init — a host app cannot point the SDK at any other URL. The
/// absence of any URL-switching plumbing is part of the security model: a
/// shipped binary always talks to the production endpoint.
public struct APIConfiguration: Sendable, Equatable {
    public let baseURL: URL
    public let pathPrefix: String

    /// The single, hardcoded base URL the SDK calls — always production
    /// `https://edge.appattest.dev`. No runtime switch, no Info.plist
    /// override, no environment variable.
    static let hardcoded = APIConfiguration(
        baseURL: URL(string: "https://edge.appattest.dev")!,
        pathPrefix: "/v1"
    )

    /// Internal-only initializer. The SDK constructs exactly one
    /// `APIConfiguration` instance at module load via `.default`.
    /// Marked internal so a host app cannot construct an alternate
    /// configuration.
    init(baseURL: URL, pathPrefix: String = "/v1") {
        self.baseURL = baseURL
        self.pathPrefix = pathPrefix
    }

    func url(path: String) -> URL {
        baseURL.appendingPathComponent(pathPrefix + path)
    }
}
