import XCTest
@testable import AppAttest

/// Locks the simulator / #Preview / unsupported-device guard matrix. The
/// decision is a pure function so the branching is unit-testable
/// **without** ever tripping the real `fatalError` (which would kill the test
/// process). This proves:
///   - the `fatalError` action is chosen ONLY for the simulator, never for a
///     real device and never for a #Preview,
///   - a #Preview never crashes even though it runs in a simulator
///     environment (preview precedence over simulator),
///   - a genuinely unsupported real device fails open, never crashes.
final class UnsupportedEnvironmentTests: XCTestCase {

    func testSimulatorWithoutLocalChoosesFatalError() {
        XCTAssertEqual(
            AppAttestClient.resolveUnsupportedEnvironment(isSimulator: true, isPreview: false),
            .simulatorFatalError,
            "simulator (no .local, not a preview) must resolve to the loud fatalError")
    }

    func testPreviewNeverCrashes_evenInSimulatorEnvironment() {
        // A #Preview runs in a simulator environment. Preview MUST win so the
        // canvas renders instead of crashing.
        XCTAssertEqual(
            AppAttestClient.resolveUnsupportedEnvironment(isSimulator: true, isPreview: true),
            .previewSafeEmpty,
            "a #Preview must never resolve to fatalError, even though it is a simulator env")
        XCTAssertEqual(
            AppAttestClient.resolveUnsupportedEnvironment(isSimulator: false, isPreview: true),
            .previewSafeEmpty)
    }

    func testRealDeviceUnsupportedFailsOpen() {
        // Rare unsupported hardware on a real device → never crash; fail-open.
        XCTAssertEqual(
            AppAttestClient.resolveUnsupportedEnvironment(isSimulator: false, isPreview: false),
            .realDeviceFailOpen,
            "an unsupported real device must fail open, never fatalError")
    }

    func testFatalErrorIsExclusivelySimulator() {
        // Exhaustive guard: the ONLY (isSimulator, isPreview) combination that
        // yields .simulatorFatalError is (true, false). Every other cell is a
        // non-crashing outcome.
        for isSimulator in [true, false] {
            for isPreview in [true, false] {
                let r = AppAttestClient.resolveUnsupportedEnvironment(
                    isSimulator: isSimulator, isPreview: isPreview)
                if isSimulator && !isPreview {
                    XCTAssertEqual(r, .simulatorFatalError, "(sim,\(isPreview))")
                } else {
                    XCTAssertNotEqual(r, .simulatorFatalError,
                                      "fatalError must NOT be chosen for (sim=\(isSimulator), preview=\(isPreview))")
                }
            }
        }
    }
}
