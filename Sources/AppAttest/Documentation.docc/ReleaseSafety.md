# Release Safety

Why ``DebugMode/local(stubs:)`` cannot reach your shipped binary.

## Overview

AppAttest's threat model treats the consumer app as untrusted. The
AppAttest service enforces that real attestation must succeed before
any production secret leaves the vault. The SDK does its part by
making non-production code paths physically absent from Release builds.

## The `#if DEBUG` boundary

The entire ``DebugMode`` type and its setter on
``AppAttestClient/debug`` are wrapped in `#if DEBUG`. The Swift
compiler strips those branches when `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
does not include `DEBUG` — which is the case for every standard Release
configuration, including TestFlight.

A consumer app that writes `AppAttestClient.shared.debug = .local(...)`
outside `#if DEBUG` will not compile for Release. If you wrap it in
`#if DEBUG` correctly, the statement vanishes from the shipped binary.

## Verifying the strip

After archiving your app for App Store distribution:

```bash
otool -L YourApp.app/YourApp | grep -i appattest
nm -g YourApp.app/YourApp | grep -i 'appattest.*DebugMode'
```

The `nm` output should show zero `DebugMode` symbols in the AppAttest
module namespace. If you see any, file an issue.

## TestFlight

TestFlight builds are Release builds. The `DEBUG` flag is not set. The
debug mode is stripped. You cannot accidentally ship a build to
TestFlight that reads stub secrets — the type literally does not exist
in the compiled binary.

## What about `AppAttest.release = .staging` in a Release build?

Unlike ``DebugMode/local(stubs:)``, ``AppAttest/release`` **is** compiled into
Release builds — deliberately. It is only a routing label choosing which
metered bucket to attest against (`.staging` or `.production`); it carries no
secrets and opens no offline path. Both buckets require a real attestation and
are **metered** — selecting `.staging` in a shipped binary does not make
anything free and cannot bypass billing. The one free path remains
``DebugMode/local(stubs:)``, which is stripped from Release. That is what keeps
billing un-hackable: every shipped app attests and meters, and which bucket it
declares changes only *which* secrets it reads, never *whether* it pays.

## What about the base URL?

The AppAttest API base URL is hardcoded to
`https://edge.appattest.dev` in checked-in source. There is no public
constructor argument, no Info.plist override, no environment variable
read at SDK init. A published binary cannot be redirected at any other
endpoint.

## Why this matters

The SDK's public contract is "one init, one mode, real attestation in
Release, hardcoded production endpoint." If a shipped build could enter
local-stubs mode or redirect to a custom URL at runtime, the threat model
collapses — an attacker with binary access could force-switch a Release
build into stub mode and read whatever fake secrets the host app set, or
redirect it to an attacker-controlled MITM endpoint. The compile-time
strip + the hardcoded URL close both doors. Keep them closed.
