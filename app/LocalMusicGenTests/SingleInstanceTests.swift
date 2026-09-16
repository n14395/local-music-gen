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

    /// The tie-break. Two copies started inside the same window each see the
    /// other, and a symmetric "is another instance running?" had both hand over
    /// and both exit — the app just did not start. The earlier `launchDate`
    /// wins, whatever the pids say.
    func testDefersOnlyToTheProcessThatStartedFirst() {
        let start = Date(timeIntervalSince1970: 1_000)
        let older = SingleInstance.Instance(launchDate: start, pid: 5_000)
        let newer = SingleInstance.Instance(
            launchDate: start.addingTimeInterval(0.4), pid: 400)
        XCTAssertTrue(SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                 environment: [:],
                                                 sibling: older, me: newer))
        XCTAssertFalse(SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                  environment: [:],
                                                  sibling: newer, me: older))
    }

    /// The property that matters: whichever way round the pair is asked,
    /// exactly one of the two defers.
    func testSimultaneousLaunchesLeaveExactlyOneSurvivor() {
        let together = Date(timeIntervalSince1970: 2_000)
        let a = SingleInstance.Instance(launchDate: together, pid: 811)
        let b = SingleInstance.Instance(launchDate: together, pid: 812)
        let aDefers = SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                 environment: [:],
                                                 sibling: b, me: a)
        let bDefers = SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                 environment: [:],
                                                 sibling: a, me: b)
        XCTAssertNotEqual(aDefers, bDefers, "both exiting is the bug")
        // Same instant: the lower pid is the arbitrary but agreed winner.
        XCTAssertTrue(bDefers)
    }

    /// `NSRunningApplication.launchDate` is optional, so the policy has to
    /// stay decidable without it.
    func testAMissingLaunchDateFallsBackToThePid() {
        let undated = SingleInstance.Instance(launchDate: nil, pid: 10)
        let dated = SingleInstance.Instance(launchDate: Date(), pid: 20)
        XCTAssertTrue(SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                 environment: [:],
                                                 sibling: undated, me: dated))
        XCTAssertFalse(SingleInstance.shouldDefer(otherInstanceRunning: true,
                                                  environment: [:],
                                                  sibling: dated, me: undated))
    }

    /// The exemptions come first: an older sibling must not drag the test host
    /// out of a run.
    func testExemptionsBeatTheTieBreak() {
        let older = SingleInstance.Instance(
            launchDate: Date(timeIntervalSince1970: 1), pid: 1)
        let me = SingleInstance.Instance(launchDate: Date(), pid: 900)
        XCTAssertFalse(SingleInstance.shouldDefer(
            otherInstanceRunning: true,
            environment: ["XCTestBundlePath": "/tmp/whatever"],
            sibling: older, me: me))
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
