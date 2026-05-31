// DebugMode is nested as `AppAttestClient.DebugMode`.
// This file is intentionally small; the type lives next to the client so
// the public API surface is "one type, one file" for easy reading.
//
// Spec: `nil` debugMode means production. There is no `.production` case;
// production is the absence of an override.
//
// `.local(stubs:)` is the only case and is debug-only — the
// case, the property, the backing store, the type itself, and the static
// `AppAttest.debugMode` forwarder all live inside `#if DEBUG` in
// `AppAttestClient`. TestFlight compiles as Release, so none of this
// surface exists in a TestFlight or App Store binary.
