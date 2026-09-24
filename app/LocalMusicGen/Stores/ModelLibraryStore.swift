// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The model library folder — where weights live, what they cost, and the two
/// operations that rearrange them (contract §4.4).
///
/// Every figure and every action here is scoped to models in our own catalog.
/// The default folder is the shared `~/.cache/huggingface`, so it routinely
/// holds repos other Hugging Face tools put there; this app neither counts
/// those as its own nor removes them, and the UI says so where it matters.
@MainActor @Observable
final class ModelLibraryStore {
    var client: BackendClient?

    private(set) var info: LibraryInfo?
    private(set) var operation: LibraryOperation?
    private(set) var verifyReport: LibraryVerifyReport?
    private(set) var isRefreshing = false
    private(set) var isVerifying = false
    var lastError: String?

    /// Set when a finished relocate needs the engine restarted before the new
    /// folder is the one in use — the engine reads HF_HOME at launch and
    /// nowhere else. Cleared once the caller has done it.
    private(set) var pendingRestartPath: String?

    /// The volume the library sits on, as macOS describes it. Only interesting
    /// when the answer is "removable" or "network": models on a disk that can
    /// be unplugged mid-session fail in a way nothing else in the app explains.
    struct VolumeKind: Equatable, Sendable {
        var isRemovable = false
        var isNetwork = false
        var name: String?

        var caution: String? {
            if isNetwork {
                return "This folder is on a network volume. Models load slowly "
                    + "from one, and a dropped connection mid-render looks like "
                    + "an engine crash."
            }
            if isRemovable {
                return "This folder is on a removable volume"
                    + (name.map { " (\($0))" } ?? "")
                    + ". Ejecting it while the app is running leaves every "
                    + "model unreadable until it is plugged back in."
            }
            return nil
        }
    }

    private(set) var volume = VolumeKind()

    // MARK: - Reading

    func refresh() async {
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await client.library()
            info = fresh
            operation = fresh.operation
            volume = Self.volumeKind(of: fresh.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func verify() async {
        guard let client else { return }
        isVerifying = true
        defer { isVerifying = false }
        do { verifyReport = try await client.verifyLibrary() }
        catch { lastError = error.localizedDescription }
    }

    /// True when the disk could not hold the largest thing the catalog offers.
    /// Deliberately a warning rather than a block: it is their disk, and the
    /// number that matters is the model they actually pick.
    func isTightOnSpace(largestModelBytes: Int64?) -> Bool {
        guard let free = info?.diskFreeBytes, let largest = largestModelBytes,
              largest > 0 else { return false }
        return free < largest
    }

    // MARK: - Operations

    /// Remove models of ours from the current folder — everything, or just the
    /// interrupted downloads.
    func clear(scope: String = "all") async {
        await start { try await $0.clearLibrary(scope: scope) }
    }

    /// Move the library to `path`, doing `disposition` with what is in the old
    /// folder. Once it finishes the caller must restart the engine — see
    /// `pendingRestartPath`.
    func relocate(to path: String, disposition: String) async {
        // Armed when the engine *accepts* the request, not when the first
        // progress event lands: those arrive over SSE and there is no
        // guarantee one has by the time this returns, which left the restart
        // banner missing for exactly the operation that needs it.
        if await start({ try await $0.relocateLibrary(to: path,
                                                      disposition: disposition) }) {
            pendingRestartPath = path
        }
    }

    /// True when the engine accepted the request. A refusal (nothing to clear,
    /// engine busy, bad destination) emits no events at all, so this return is
    /// the only signal that the operation exists.
    @discardableResult
    private func start(_ call: (BackendClient) async throws -> String) async -> Bool {
        guard let client else { return false }
        lastError = nil
        do {
            _ = try await call(client)
            // No refresh here: the engine emits the first `library.progress`
            // as it starts, and re-reading now would race a slower answer over
            // the top of it.
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func cancelOperation() async {
        guard let client else { return }
        try? await client.cancelLibraryOperation()
    }

    func consumePendingRestart() -> String? {
        defer { pendingRestartPath = nil }
        return pendingRestartPath
    }

    // MARK: - Events

    func apply(_ event: EngineEvent) {
        switch event {
        case .libraryProgress(let op):
            operation = op
        case .libraryFinished(let op):
            operation = op
            if op.state == "failed" {
                lastError = op.error?.message ?? "The library operation failed."
            }
            // `pendingRestartPath` deliberately survives a failure: the engine
            // stamps `restart_required` on a relocate whatever became of it,
            // and a run that fell over halfway needs the restart *more* — some
            // repositories are already at the destination, and only an engine
            // pointed there can see them.

            // The report describes a library that has just changed underneath
            // it, and a stale verdict is worse than none.
            verifyReport = nil
            Task { await refresh() }
        default:
            break
        }
    }

    // MARK: - Volume

    nonisolated static func volumeKind(of url: URL) -> VolumeKind {
        // The nearest existing ancestor: a folder chosen but not yet created
        // is an ordinary state, and the volume is the same either way.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path),
              probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
            .volumeIsInternalKey, .volumeNameKey,
        ]
        guard let values = try? probe.resourceValues(forKeys: keys) else {
            return VolumeKind()
        }
        return VolumeKind(
            isRemovable: (values.volumeIsRemovable ?? false)
                || (values.volumeIsEjectable ?? false)
                || (values.volumeIsInternal == false),
            isNetwork: values.volumeIsLocal == false,
            name: values.volumeName)
    }
}
