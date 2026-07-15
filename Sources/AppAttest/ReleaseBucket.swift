import Foundation

/// Which metered server bucket this build attests against.
///
/// Passed to ``AppAttest/start(release:)`` — a **required** argument with no
/// default. Compiled into **all** builds (Debug and Release). It is a plain
/// routing label — it carries no secrets and opens no offline path, so it is
/// safe to ship.
///
/// ```swift
/// AppAttest.start(release: .production)
/// ```
///
/// - ``production`` — the live, metered bucket. Almost every shipped app wants
///   this.
/// - ``staging`` — a functionally-identical, separately-keyed, **metered**
///   bucket a team can point a pre-ship build at to verify end to end before
///   flipping to ``production``. It is still fully metered — not a free tier.
///
/// > Important: The bucket is **exactly** what you pass — the SDK never infers
/// > it from `#if DEBUG` or any other build-flavor signal, and it means the
/// > same thing however the SDK itself was compiled. (It once did infer, and a
/// > distribution archive whose Xcode configuration built dependencies
/// > debug-flavored silently declared `staging` and was served STAGING secrets
/// > while the developer believed it was on production. That inference is
/// > retired.) Edge resolves your declaration against Apple's AAGUID: a
/// > development-signed build declaring ``production`` is rejected with a loud
/// > `403 bucket_not_permitted` rather than quietly re-routed.
/// >
/// > The single offline / free path is `AppAttest.debug = .local(stubs:)`,
/// > which is Debug-only (compiled out of Release) and never reaches the
/// > network.
public enum ReleaseBucket: Sendable, Equatable {
    /// The staging bucket — a real, metered, separately-keyed server bucket.
    case staging
    /// The live, metered production bucket. What a shipping build passes.
    case production

    /// The wire string sent as the `bucket` field on `POST /v1/attest`.
    var wireValue: String {
        switch self {
        case .staging:    return "staging"
        case .production: return "production"
        }
    }
}
