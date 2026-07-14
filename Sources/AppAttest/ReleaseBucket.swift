import Foundation

/// Which metered server bucket a **Release** build attests against.
///
/// Compiled into **all** builds (Debug and Release). It is a plain routing
/// label — it carries no secrets and opens no offline path, so it is safe to
/// ship. Set ``AppAttest/release`` before ``AppAttest/start()``.
///
/// - ``production`` — the live, metered bucket. **Default.** Almost every
///   shipped app wants this.
/// - ``staging`` — a functionally-identical, separately-keyed, **metered**
///   bucket a team can point a pre-ship build at to verify end to end before
///   flipping to ``production``. It is still fully metered — not a free tier.
///
/// > Important: In a **Debug** build the SDK always declares ``staging``
/// > regardless of this value — a debug build is a development-environment
/// > build. This property therefore only takes effect in a **Release** build.
/// > The single offline / free path is `AppAttest.debug = .local(stubs:)`,
/// > which is Debug-only (compiled out of Release) and never reaches the
/// > network.
public enum ReleaseBucket: Sendable, Equatable {
    /// The staging bucket — a real, metered, separately-keyed server bucket.
    case staging
    /// The live, metered production bucket. The Release default.
    case production

    /// The wire string sent as the `bucket` field on `POST /v1/attest`.
    var wireValue: String {
        switch self {
        case .staging:    return "staging"
        case .production: return "production"
        }
    }
}
