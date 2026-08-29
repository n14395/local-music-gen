import Foundation

/// Spawns and supervises the engine sidecar (or attaches to a dev instance).
///
/// State machine: stopped → launching → ready ⇄ degraded → restarting → failed.
/// Crash policy: exponential backoff 1/4/15 s; 3 crashes within 5 minutes → failed.
/// Jobs are never auto-resubmitted (a mid-generation crash is usually OOM).
actor BackendProcessManager {
    private let status: BackendStatusStore
    private let onEvent: @Sendable (EventStreamClient.StreamItem) -> Void

    private var mode: BackendLaunchMode?
    private var process: Process?
    private var token = ""
    private(set) var client: BackendClient?
    private var eventsTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var crashTimes: [Date] = []
    private var stopping = false
    private var stderrLog: FileHandle?

    private let modeOverride: BackendLaunchMode?
    /// Settings' engine knobs, read fresh at every spawn so a restart picks
    /// up the values as they are now. nil (the default, and every test's)
    /// launches with the engine's own defaults, exactly as before.
    private let launchConfig: @Sendable () async -> EngineLaunchConfig?

    init(status: BackendStatusStore,
         onEvent: @escaping @Sendable (EventStreamClient.StreamItem) -> Void,
         modeOverride: BackendLaunchMode? = nil,
         launchConfig: @escaping @Sendable () async -> EngineLaunchConfig? =
            { nil }) {
        self.status = status
        self.onEvent = onEvent
        self.modeOverride = modeOverride
        self.launchConfig = launchConfig
    }

    // MARK: lifecycle

    func start() async {
        guard let mode = modeOverride ?? BackendLaunchMode.resolve() else {
            await setPhase(.failed(reason: "No engine found. Set LOCALMUSIC_BACKEND_HANDSHAKE or LOCALMUSIC_BACKEND_CMD, or use a bundled build."))
            return
        }
        self.mode = mode
        stopping = false
        await setPhase(.launching)
        switch mode {
        case .attach(let handshake, let attachToken):
            token = attachToken
            await connect(handshakeFile: handshake)
        case .spawn(let command):
            token = Self.randomToken()
            await spawn(command: command)
        }
    }

    func stop() async {
        stopping = true
        healthTask?.cancel()
        eventsTask?.cancel()
        if let client {
            try? await client.shutdown()
        }
        if let process, process.isRunning {
            // graceful: /v1/shutdown above → SIGTERM → SIGKILL
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning { process.terminate() }
            let killDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < killDeadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: StoragePaths.enginePidFile)
        process = nil
        client = nil
        await setPhase(.stopped)
    }

    func restart() async {
        if let process, process.isRunning {
            process.terminationHandler = nil
            kill(process.processIdentifier, SIGKILL)
        }
        process = nil
        await start()
    }

    // MARK: spawn path

    private func spawn(command: [String]) async {
        cleanStaleProcess()
        try? FileManager.default.removeItem(at: StoragePaths.engineHandshake)
        try? StoragePaths.ensureDirectories()

        let config = await launchConfig()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst()) + [
            "--handshake-file", StoragePaths.engineHandshake.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--data-dir", StoragePaths.engineData.path,
            "--output-dir", StoragePaths.engineOutputs.path,
        ] + (config?.arguments ?? [])
        var env = ProcessInfo.processInfo.environment
        env["LOCALMUSIC_AUTH_TOKEN"] = token
        if let config {
            env.merge(config.environment) { _, new in new }
        }
        p.environment = env

        let stderrPipe = Pipe()
        p.standardError = stderrPipe
        p.standardOutput = FileHandle.nullDevice
        openStderrLog()
        let logHandle = stderrLog
        let statusStore = status
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? logHandle?.write(contentsOf: data)
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.split(separator: "\n").map(String.init)
                Task { @MainActor in
                    statusStore.appendStderr(lines)
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleTermination() }
        }

        do {
            try p.run()
        } catch {
            await setPhase(.failed(reason: "Could not launch engine: \(error.localizedDescription)"))
            return
        }
        process = p
        try? String(p.processIdentifier).write(to: StoragePaths.enginePidFile,
                                               atomically: true, encoding: .utf8)
        // Published so Settings can compare what the engine is running with
        // against what it would launch with now — the pending-restart banner.
        await MainActor.run { [status] in status.launchedEngineConfig = config }
        await connect(handshakeFile: StoragePaths.engineHandshake)
    }

    /// Kill an orphaned engine from a previous app run that crashed. The pid must
    /// still belong to OUR engine: macOS recycles pids, and blindly killing the
    /// number in a stale file can hit an unrelated process.
    private func cleanStaleProcess() {
        defer { try? FileManager.default.removeItem(at: StoragePaths.enginePidFile) }
        guard let text = try? String(contentsOf: StoragePaths.enginePidFile,
                                     encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        ps.waitUntilExit()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        let markers = ["local-music-engine", "stub_server.py", "run-stub.sh"]
        guard markers.contains(where: command.contains) else { return }
        kill(pid, SIGKILL)
    }

    // MARK: connect (shared by spawn and attach)

    private func connect(handshakeFile: URL) async {
        let start = Date()
        let deadline = start.addingTimeInterval(60)
        var handshake: Handshake?
        while Date() < deadline && !stopping {
            if let data = try? Data(contentsOf: handshakeFile),
               let hs = try? BackendClient.decoder.decode(Handshake.self, from: data),
               hs.contract == 1
            {
                // The handshake may be from a previous run; verify liveness below.
                let candidate = BackendClient(port: hs.port, token: token)
                if (try? await candidate.health()) != nil {
                    handshake = hs
                    break
                }
            }
            // A warm engine writes its handshake in well under a second, and
            // every millisecond between it doing so and this loop noticing is
            // a millisecond of launch where the model catalog is unknown and
            // the screens that depend on it have to say so. Poll hard while
            // that is plausible, then back off — a genuinely cold first run
            // has uv fetching CPython and the supervisor's wheels, and there
            // is no point re-reading a missing file forty times a second for
            // the remaining minute of it.
            let fast = Date().timeIntervalSince(start) < 2
            try? await Task.sleep(for: .milliseconds(fast ? 25 : 250))
        }
        guard let hs = handshake else {
            if !stopping {
                await setPhase(.failed(reason: "Engine did not become ready within 60 s."))
            }
            return
        }
        let client = BackendClient(port: hs.port, token: token)
        self.client = client
        await MainActor.run { [status] in
            status.port = hs.port
            status.engineVersion = hs.version
        }
        await setPhase(.ready)
        startEventStream(port: hs.port)
        startHealthPolling(client: client)
    }

    private func startEventStream(port: Int) {
        eventsTask?.cancel()
        let stream = EventStreamClient(port: port, token: token)
        let statusStore = status
        let onEvent = onEvent
        eventsTask = Task {
            for await item in stream.items() {
                switch item {
                case .connected:
                    await MainActor.run { statusStore.eventStreamConnected = true }
                case .disconnected:
                    await MainActor.run { statusStore.eventStreamConnected = false }
                case .event:
                    break
                }
                onEvent(item)
            }
        }
    }

    private func startHealthPolling(client: BackendClient) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                if (try? await client.health()) != nil {
                    failures = 0
                    await self?.recoveredIfDegraded()
                } else {
                    failures += 1
                    if failures == 1 { await self?.setPhase(.degraded) }
                    if failures >= 3 {
                        await self?.healthFailed()
                        break
                    }
                }
            }
        }
    }

    private func recoveredIfDegraded() async {
        if await currentPhase() == .degraded { await setPhase(.ready) }
    }

    private func healthFailed() async {
        guard !stopping else { return }
        if case .attach = mode {
            // Attach mode: nothing to restart; keep polling until the dev restarts it.
            await setPhase(.degraded)
            if let client { startHealthPolling(client: client) }
            return
        }
        if let process, process.isRunning {
            process.terminationHandler = nil
            kill(process.processIdentifier, SIGKILL)
        }
        await handleTermination()
    }

    // MARK: crash handling

    private func handleTermination() async {
        guard !stopping else { return }
        healthTask?.cancel()
        eventsTask?.cancel()
        client = nil
        crashTimes.append(Date())
        crashTimes.removeAll { $0 < Date().addingTimeInterval(-300) }
        let lastLine = await MainActor.run { [status] () -> String? in
            status.eventStreamConnected = false
            status.restartCount += 1
            return status.stderrTail.last
        }
        if crashTimes.count > 3 {
            await setPhase(.failed(reason: Self.repeatedCrashReason(lastLine: lastLine)))
            return
        }
        await setPhase(.restarting)
        let backoff: [Double] = [1, 4, 15]
        let delay = backoff[min(crashTimes.count - 1, backoff.count - 1)]
        try? await Task.sleep(for: .seconds(delay))
        guard !stopping else { return }
        if case .spawn(let command) = mode {
            await setPhase(.launching)
            await spawn(command: command)
        }
    }

    // MARK: helpers

    private func currentPhase() async -> BackendPhase {
        await MainActor.run { [status] in status.phase }
    }

    private func setPhase(_ phase: BackendPhase) async {
        await MainActor.run { [status] in status.phase = phase }
    }

    private func openStderrLog() {
        guard stderrLog == nil else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = StoragePaths.engineLogs
            .appendingPathComponent("backend-\(df.string(from: Date())).log")
        // Create it only when it is not there. `createFile` *replaces* an
        // existing file, so pairing it with the seekToEnd below always landed
        // at zero: every engine launch wiped the day's log, and the launch
        // that follows a crash is a restart — which erased the record of the
        // crash that caused it. "Check the logs" then pointed at an empty
        // file. The day's file is the unit here, so runs append to it and the
        // marker below says where each one begins.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        stderrLog = try? FileHandle(forWritingTo: url)
        try? stderrLog?.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stderrLog?.write(contentsOf: Data("\n=== engine start \(stamp) ===\n".utf8))
    }

    /// What the sidebar says when the engine will not stay up.
    ///
    /// Carries the engine's own last words when it left any. "Check the logs"
    /// is only useful advice if the logs say something, and the line that
    /// killed the engine is almost always the last one it wrote — a dyld
    /// failure, a missing model file, a traceback's final line. Trimmed
    /// because this lands in a sidebar, not a terminal.
    static func repeatedCrashReason(lastLine: String?) -> String {
        let head = "The engine crashed repeatedly."
        let line = (lastLine ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "\(head) Check the logs." }
        let clipped = line.count > 160 ? String(line.prefix(159)) + "\u{2026}" : line
        return "\(head) Last output: \(clipped)"
    }

    private static func randomToken() -> String {
        (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }
            .joined()
    }
}
