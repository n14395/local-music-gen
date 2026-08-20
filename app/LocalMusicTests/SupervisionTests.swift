import XCTest
@testable import LocalMusic

/// Headless integration tests: BackendProcessManager spawning and supervising the
/// real stub engine (stub-backend/run-stub.sh), located via #filePath.
@MainActor
final class SupervisionTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)           // …/app/LocalMusicTests/SupervisionTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeManager(status: BackendStatusStore) -> BackendProcessManager {
        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        return BackendProcessManager(
            status: status, onEvent: { _ in },
            modeOverride: .spawn(command: ["/bin/bash", "-lc", "exec \"\(script)\" \"$@\"",
                                           "local-music-engine"]))
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 60,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    func testSpawnReadyAndCleanStop() async throws {
        let status = BackendStatusStore()
        let manager = makeManager(status: status)
        await manager.start()
        try await waitFor("ready") { status.phase == .ready }
        XCTAssertNotNil(status.port)

        // engine pid from handshake; must be alive now, dead after stop()
        let data = try Data(contentsOf: StoragePaths.engineHandshake)
        let hs = try BackendClient.decoder.decode(Handshake.self, from: data)
        XCTAssertEqual(kill(hs.pid, 0), 0, "engine process should be alive")

        await manager.stop()
        XCTAssertEqual(status.phase, .stopped)
        try await waitFor("engine exit", timeout: 10) { kill(hs.pid, 0) != 0 }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StoragePaths.enginePidFile.path))
    }

    func testCrashTriggersRestart() async throws {
        let status = BackendStatusStore()
        let manager = makeManager(status: status)
        await manager.start()
        try await waitFor("ready") { status.phase == .ready }

        let data = try Data(contentsOf: StoragePaths.engineHandshake)
        let hs = try BackendClient.decoder.decode(Handshake.self, from: data)
        kill(hs.pid, SIGKILL)

        try await waitFor("restart") { status.restartCount >= 1 }
        try await waitFor("ready again") { status.phase == .ready }

        let data2 = try Data(contentsOf: StoragePaths.engineHandshake)
        let hs2 = try BackendClient.decoder.decode(Handshake.self, from: data2)
        XCTAssertNotEqual(hs.pid, hs2.pid, "a fresh engine process should be running")

        await manager.stop()
        try await waitFor("engine exit", timeout: 10) { kill(hs2.pid, 0) != 0 }
    }
}
