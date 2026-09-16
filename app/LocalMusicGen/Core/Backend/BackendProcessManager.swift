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
    /// True from `start()`'s first line until its handshake wait ends, so a
    /// second caller in that window is turned away rather than spawning a
    /// second engine beside the first.
    private var starting = false
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
        // Idempotent. The engine used to be started from the main window's
        // `.task`, so closing that window and reopening it from the Dock ran
        // this again against a live engine: a second launch minted a new
        // token, found the first engine through its own pid file and
        // SIGKILLed it mid-render. Whatever asks, a manager runs one engine.
        guard !starting, process?.isRunning != true, client == nil else { return }
        starting = true
        defer { starting = false }
        guard let mode = modeOverride ?? BackendLaunchMode.resolve() else {
            await setPhase(.failed(reason: "No engine found. Set LOCALMUSICGEN_BACKEND_HANDSHAKE or LOCALMUSICGEN_BACKEND_CMD, or use a bundled build."))
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
            await awaitExit(of: process, gracePeriod: 5)
        }
        try? FileManager.default.removeItem(at: StoragePaths.enginePidFile)
        process = nil
        client = nil
        await setPhase(.stopped)
    }

    /// Bring the engine down and up again, cleanly.
    ///
    /// This used to SIGKILL the child and call `start()`. The child was `uv`,
    /// which forks the supervisor rather than exec'ing it, so the kill
    /// orphaned a live engine that kept the data-dir lock and its port; each
    /// of the four respawns that followed died on "another engine already
    /// serves this data dir", and the app sat in `.failed` until it was quit.
    /// The shim now execs the supervisor itself, and this goes the way
    /// `stop()` does — the shutdown verb, then SIGTERM, then SIGKILL, and a
    /// wait for the exit — so the lock is free before the next spawn asks.
    func restart() async {
        healthTask?.cancel()
        eventsTask?.cancel()
        if let process {
            // Not a crash: the handler would count it as one and spawn on
            // its own, racing the spawn below.
            process.terminationHandler = nil
            if process.isRunning {
                if let client { try? await client.shutdown() }
                await awaitExit(of: process, gracePeriod: 5)
            }
        }
        try? FileManager.default.removeItem(at: StoragePaths.enginePidFile)
        process = nil
        client = nil
        await start()
    }

    /// Wait for the child to leave, escalating: `gracePeriod` seconds for it
    /// to act on a shutdown already requested, then SIGTERM, then SIGKILL.
    /// Always waits out the exit itself — the next spawn takes the data-dir
    /// lock this process holds and reads the pid file it wrote, so returning
    /// before it is gone is what made a restart a crash loop.
    private func awaitExit(of p: Process, gracePeriod: TimeInterval) async {
        var deadline = Date().addingTimeInterval(gracePeriod)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if p.isRunning { p.terminate() }
        deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
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
        env["LOCALMUSICGEN_AUTH_TOKEN"] = token
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
        // Never our own live child. `start()` refuses to run twice, but the
        // pid file is the one thing here that outlives a manager, and the
        // stale-engine sweep must not be the thing that kills a good one.
        guard pid != process?.processIdentifier else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        ps.waitUntilExit()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        let markers = ["local-music-gen-engine", "stub_server.py", "run-stub.sh"]
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
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                // Three health checks have already gone unanswered, so the
                // shutdown verb would too: straight to the signals, but
                // still waiting for the exit — the respawn below needs the
                // data-dir lock this engine is holding.
                await awaitExit(of: process, gracePeriod: 0)
            }
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
