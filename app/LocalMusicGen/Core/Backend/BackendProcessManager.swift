// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
    /// Identifies the `start()` that owns `starting`, so an abandoned one
    /// cannot clear the flag out from under its replacement.
    private var startToken = 0
    /// Bumped once per engine we take charge of (every spawn, and the attach).
    /// One death must produce exactly one restart decision: the termination
    /// handler and the health poller could both reach `handleTermination()`
    /// for the same exit — cancelling the poller's in-flight request is
    /// itself the third health failure — which counted two crashes and ran
    /// two `spawn()`s. Whoever gets there first claims the generation; the
    /// loser sees a stale one and leaves.
    private var generation = 0
    private var stderrLog: FileHandle?
    /// The read end of the running child's stderr pipe, kept so the handler
    /// installed on it can be taken off again — at `stop()`, and before the
    /// next spawn installs its own.
    private var stderrReader: FileHandle?

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
        startToken += 1
        let myToken = startToken
        starting = true
        defer { if startToken == myToken { starting = false } }
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
            generation += 1
            await connect(handshakeFile: handshake)
        case .spawn(let command):
            token = Self.randomToken()
            await spawn(command: command)
        }
    }

    func stop() async {
        stopping = true
        abandonStartInProgress()
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
        // The child is gone, so the pipe is at EOF and its handler would
        // otherwise keep firing on nothing (see `clearStderrHandler`), and the
        // day's log would be held open by a manager with no engine.
        clearStderrHandler()
        closeStderrLog()
        // A handshake file left behind points at a port nothing answers on.
        // Only a spawned engine's file is ours to remove: in attach mode it
        // belongs to the dev's engine, which we did not start and are not
        // stopping.
        if case .spawn = mode {
            try? FileManager.default.removeItem(at: StoragePaths.engineHandshake)
        }
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
        abandonStartInProgress()
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

    /// Let go of a `start()` that is still waiting for a handshake.
    ///
    /// `starting` turns a second `start()` away, and that wait can now be
    /// minutes long on a first run — so `stop()` and `restart()` have to
    /// release it, or Restart Engine during provisioning would kill the child
    /// and then refuse to launch its replacement. The generation bump drops
    /// the abandoned `connect()` out of its loop without letting it write a
    /// phase; the token bump stops its `defer` clearing the *next* start's
    /// flag.
    private func abandonStartInProgress() {
        generation += 1
        startToken += 1
        starting = false
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
        // Whatever the last child left installed goes first: a restart or a
        // crash respawn replaces `process`, and the old pipe's handler kept
        // appending the dead (or orphaned) engine's output into the live
        // stderr tail and today's log, interleaved with this one's.
        clearStderrHandler()
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
        let reader = stderrPipe.fileHandleForReading
        stderrReader = reader
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            // An empty read is EOF, and a dispatch read source stays readable
            // at EOF for ever: without this the handler re-fired in a tight
            // loop from the moment the engine died until the `Pipe` was
            // released — the whole 1/4/15 s crash backoff, spinning a core.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? logHandle?.write(contentsOf: data)
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.split(separator: "\n").map(String.init)
                Task { @MainActor in
                    statusStore.appendStderr(lines)
                }
            }
        }
        generation += 1
        let gen = generation
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleTermination(generation: gen) }
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

    /// How long the handshake wait tolerates *silence*, and the outer bound on
    /// the whole wait.
    ///
    /// This used to be one flat 60 s from launch. A first run provisions
    /// CPython and the supervisor's venv over the network before there is an
    /// engine at all — the project's own harness budgets 900 s for it
    /// (`scripts/verify_packaged.py`) and the README says "a minute or two" —
    /// so a cold start on a slow line failed at 60 s while `uv` was still
    /// downloading, and nothing ever re-polled: the engine finished and wrote
    /// its handshake to a file no one was reading. The shim narrates that work
    /// on stderr (`engine-setup:` lines), so what means "wedged" is silence,
    /// not elapsed time.
    private static let handshakeIdleS: TimeInterval = 60
    private static let handshakeCapS: TimeInterval = 900

    private enum HandshakeStall { case idle, cap, childExited }

    /// The wire contract this app speaks (`docs/api-contract.md`).
    static let contract = 1

    /// What the sidebar says when the engine answers in a contract this app
    /// does not know — a future bump, or a stale app beside a newer engine in
    /// attach mode.
    static func contractMismatchReason(_ theirs: Int) -> String {
        "This engine speaks contract \(theirs); this app speaks \(contract). "
            + "Update the app (or run the engine that shipped with it)."
    }

    private func connect(handshakeFile: URL) async {
        let gen = generation
        let start = Date()
        let cap = start.addingTimeInterval(Self.handshakeCapS)
        var idleDeadline = start.addingTimeInterval(Self.handshakeIdleS)
        var lastSeenStderr = await MainActor.run { [status] in status.stderrLineCount }
        var handshake: Handshake?
        var stall = HandshakeStall.idle
        while !stopping {
            if let data = try? Data(contentsOf: handshakeFile),
               let hs = try? BackendClient.decoder.decode(Handshake.self,
                                                          from: data)
            {
                // A contract this app does not speak used to be folded into
                // the condition above, so the file was skipped in silence and
                // the wait reported it minutes later as a timeout. The field
                // exists precisely so we can say what is actually wrong.
                guard hs.contract == Self.contract else {
                    guard !stopping, generation == gen else { return }
                    await setPhase(.failed(
                        reason: Self.contractMismatchReason(hs.contract)))
                    return
                }
                // The handshake may be from a previous run; verify liveness below.
                let candidate = BackendClient(port: hs.port, token: token)
                if (try? await candidate.health()) != nil {
                    handshake = hs
                    break
                }
            }
            // Someone else took charge of this engine while we were suspended
            // (a crash restart, a `restart()`): that spawn owns the phase now.
            if generation != gen { return }
            if let process, !process.isRunning { stall = .childExited; break }
            let now = Date()
            if now >= cap { stall = .cap; break }
            if now >= idleDeadline { stall = .idle; break }
            // A warm engine writes its handshake in well under a second, and
            // every millisecond between it doing so and this loop noticing is
            // a millisecond of launch where the model catalog is unknown and
            // the screens that depend on it have to say so. Poll hard while
            // that is plausible, then back off — a genuinely cold first run
            // has uv fetching CPython and the supervisor's wheels, and there
            // is no point re-reading a missing file forty times a second for
            // the minutes of it. The idle deadline cannot expire inside that
            // first window, so only the slow path pays for the liveness read.
            let fast = Date().timeIntervalSince(start) < 2
            if !fast {
                let seen = await MainActor.run { [status] in status.stderrLineCount }
                if seen != lastSeenStderr {
                    lastSeenStderr = seen
                    idleDeadline = Date().addingTimeInterval(Self.handshakeIdleS)
                }
            }
            try? await Task.sleep(for: .milliseconds(fast ? 25 : 250))
        }
        guard let hs = handshake else {
            guard !stopping, generation == gen else { return }
            await reportHandshakeStall(stall, generation: gen)
            return
        }
        let client = BackendClient(port: hs.port, token: token)
        self.client = client
        await MainActor.run { [status] in
            status.port = hs.port
            status.engineVersion = hs.version
            // A different engine process, whatever brought it here. What is
            // cached against the old one — upload ids, above all — is gone.
            status.noteEngineReady()
        }
        await setPhase(.ready)
        startEventStream(port: hs.port)
        startHealthPolling(client: client)
    }

    /// Say why the handshake never came, naming the setup step it died on —
    /// "did not become ready within 60 s" told the user nothing about whether
    /// the engine was working or dead.
    private func reportHandshakeStall(_ stall: HandshakeStall,
                                      generation gen: Int) async {
        let step = await MainActor.run { [status] in status.setupLine }
        let during = step.map { " (last step: \($0))" } ?? ""
        switch stall {
        case .childExited:
            // A death belongs to the termination handler: it counts the crash,
            // backs off and respawns. Give it a beat to claim this one rather
            // than racing it to `.failed`, and only speak if it never came.
            for _ in 0..<20 {
                if stopping || generation != gen { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !stopping, generation == gen else { return }
            await setPhase(.failed(reason: "The engine exited before it was ready\(during)."))
        case .cap:
            let minutes = Int(Self.handshakeCapS / 60)
            await setPhase(.failed(reason: "The engine did not become ready within \(minutes) minutes\(during)."))
        case .idle:
            let seconds = Int(Self.handshakeIdleS)
            await setPhase(.failed(reason: "The engine stopped reporting progress for \(seconds) s before it was ready\(during)."))
        }
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
        let gen = generation
        healthTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                let healthy = (try? await client.health()) != nil
                // Cancelling this task cancels the URLSession request inside
                // `health()`, which throws — and that used to be counted as a
                // health failure. The cancel comes from the crash path, so the
                // engine's death arrived here as failure #3 and restarted it a
                // second time. A cancelled probe is not a verdict.
                if Task.isCancelled { break }
                if healthy {
                    failures = 0
                    await self?.recoveredIfDegraded()
                } else {
                    failures += 1
                    if failures == 1 { await self?.setPhase(.degraded) }
                    if failures >= 3 {
                        await self?.healthFailed(generation: gen)
                        break
                    }
                }
            }
        }
    }

    private func recoveredIfDegraded() async {
        if await currentPhase() == .degraded { await setPhase(.ready) }
    }

    private func healthFailed(generation gen: Int) async {
        guard !stopping, generation == gen else { return }
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
        await handleTermination(generation: gen)
    }

    // MARK: crash handling

    private func handleTermination(generation gen: Int) async {
        guard !stopping else { return }
        // One death, one decision. The termination handler and the health
        // poller both used to get here for a single exit (see `generation`),
        // which counted two crashes and spawned two engines — the second of
        // which died on the data-dir lock in a packaged build.
        guard gen == generation else { return }
        generation += 1
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

    /// Take the handler off the child's stderr pipe and let the pipe go.
    private func clearStderrHandler() {
        stderrReader?.readabilityHandler = nil
        stderrReader = nil
    }

    private func closeStderrLog() {
        try? stderrLog?.close()
        stderrLog = nil
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
