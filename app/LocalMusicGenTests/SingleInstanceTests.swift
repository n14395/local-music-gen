import XCTest
@testable import LocalMusicGen

/// The duplicate-launch guard. The dangerous mistake here is a false positive:
/// XCTest hosts this very binary, so a guard that fired under test would kill
/// the suite whenever the user had LocalMusicGen open.
final class SingleInstanceTests: XCTestCase {
    func testDefersWhenAnotherInstanceIsRunning() {
        XCTAssertTrue(SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                 environment: [:]))
    }

    func testFirstInstanceLaunchesNormally() {
        XCTAssertFalse(SingleInstance.shouldDefer(otherInstanceRunning: false,
                                                  environment: [:]))
    }

    func testNeverDefersUnderXCTest() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath",
                    "XCTestSessionIdentifier"] {
            XCTAssertFalse(
                SingleInstance.shouldDefer(otherInstanceRunning: true,
                                           environment: [key: "/tmp/whatever"]),
                "\(key) must exempt the test host")
        }
    }

    /// This suite runs inside the app binary, so the live environment must also
    /// be recognised as a test run — a regression in the key names would only
    /// show up here.
    func testLiveTestEnvironmentIsExempt() {
        XCTAssertFalse(
            SingleInstance.shouldDefer(
                otherInstanceRunning: true,
                environment: ProcessInfo.processInfo.environment))
    }

    func testOptOutEnvVar() {
        XCTAssertFalse(SingleInstance.shouldDefer(
            otherInstanceRunning: true,
            environment: ["LOCALMUSICGEN_ALLOW_MULTIPLE_INSTANCES": "1"]))
        XCTAssertTrue(SingleInstance.shouldDefer(
            otherInstanceRunning: true,
            environment: ["LOCALMUSICGEN_ALLOW_MULTIPLE_INSTANCES": "0"]))
    }
}
