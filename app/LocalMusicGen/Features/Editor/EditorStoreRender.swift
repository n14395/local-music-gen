import AVFoundation
import Foundation

// The Editor's engine round trips: Apply (replace the file in place), Export
// (save a copy), and the selection snippets the send-onward panel routes.
// All three are the same one-track mix job with a different destination for
// the artifact; `JobsStore.onEditorArtifact` calls back into here.
extension EditorStore {

    // MARK: apply

    /// The one destructive moment (Tier 1.9): stash the backup, upload the
    /// pristine source, render the program, replace the file. Everything
    /// before the replace is reversible by doing nothing.
    func applyEdits() async {
        guard let material, !document.isEmpty || appliedDocument != nil
        else { return }
        // Only one render at a time, and a refusal must never overwrite the
        // stage of a render that is still going.
        guard !applyStage.isBusy else { return }
        // Owned from here on, so every refusal below is attributed to the
        // track that asked for it rather than to whatever is open when it
        // is read.
        applyOwnerId = material.id
        // Everything that could refuse is checked BEFORE anything
        // irreversible happens — no backup is stashed and nothing is
        // uploaded for a render that cannot succeed.
        if let refusal = renderRefusal {
            applyStage = .failed(refusal)
            return
        }
        guard let model = mixdownModel else { return }
        flushPersist()
        stopPreview()
        let plan = EditMixPlan.plan(
            document: document, source: "PENDING",
            sourceDuration: sourceDurationS,
            sampleRate: material.sampleRate, sourceBpm: bpm)
        guard plan.isRenderable else {
            applyStage = .failed("There is nothing left to render — every "
                                 + "part of this track has been deleted or "
                                 + "silenced.")
            return
        }
        applyStage = .stashingBackup
        if !hasBackup {
            do {
                // Off the main actor: this is a byte-for-byte copy of the
                // whole track, which for a long WAV is hundreds of megabytes.
                // Run inline it froze the window for the duration — including
                // the "Backup stashed" spinner that is meant to be saying why
                // the app is busy.
                let from = material.fileURL
                let to = material.backupURL
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(
                        at: StoragePaths.libraryBackups,
                        withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: from, to: to)
                }.value
                refreshBackupState()
            } catch {
                applyStage = .failed("Could not stash the backup: "
                                     + error.localizedDescription)
                applyOwnerId = nil
                return
            }
            var updated = document
            updated.originalDurationS = material.fileDurationS
            updated.originalFileName = material.fileName
            document = updated
            // The backup's own name is recorded, because the live file is
            // about to be renamed: apply always renders WAV, so an imported
            // mp3 becomes `<id>.wav` and a path derived from the *current*
            // name would stop finding the original a moment from now.
            noteBackupFileName(material.backupURL.lastPathComponent,
                               ownerId: material.id,
                               ownerType: material.ownerType)
            persistPending()
        }
        // The document travels WITH the job, and is snapshotted BEFORE the
        // upload suspends: the user may open another track while this is in
        // flight, and what lands must be recorded against the program that
        // was actually submitted. The source's own bit depth is read here
        // for the same reason.
        let documentJSON = (try? JSONEncoder().encode(document))
            .map { String(decoding: $0, as: UTF8.self) }
        // Detached: opening an `AVAudioFile` to read its header is a disk
        // hit, and `bitDepth` is `nonisolated` precisely so it need not be a
        // main-thread one.
        let depthSource = sourceURL
        let sourceDepth = await Task.detached(priority: .userInitiated) {
            depthSource.flatMap(Self.bitDepth(of:))
        }.value
        applyStage = .uploading
        guard let sourceId = await uploadSource() else {
            applyStage = .failed(jobs.lastError ?? "Upload failed")
            applyOwnerId = nil
            return
        }
        var submitted = plan.spec
        for index in submitted.tracks.indices {
            submitted.tracks[index].source = sourceId
        }
        guard await resolveIRUploads(&submitted) else {
            applyStage = .failed(jobs.lastError ?? "IR upload failed")
            applyOwnerId = nil
            return
        }
        guard let created = await jobs.submitEditorRender(
            modelId: model.id, spec: submitted, normalize: plan.normalize,
            limiter: plan.limiter, targetLufs: plan.targetLufs,
            // Match the original's depth. Imports of wav/flac/aiff are
            // copied as they are, so a 24-bit master stays 24-bit — and
            // rendering it back at the default 16 would quietly flatten the
            // user's own file the first time they trimmed it.
            bitDepth: sourceDepth,
            purpose: .apply(ownerId: material.id,
                            ownerType: material.ownerType,
                            title: material.title,
                            documentJSON: documentJSON)),
            let jobId = created.jobs.first?.jobId else {
            applyStage = .failed(jobs.lastError ?? "Submit failed")
            applyOwnerId = nil
            return
        }
        applyStage = .queued(jobId: jobId)
        watchJob(jobId, kind: .apply)
    }

    func cancelApply() async {
        if case .queued(let jobId) = applyStage {
            await jobs.cancel(jobId)
        } else if case .rendering(let jobId, _, _, _) = applyStage {
            await jobs.cancel(jobId)
        }
        applyStage = .idle
        applyOwnerId = nil
    }

    /// Clear a finished-with stage that this material owns. The failure card
    /// stays attached to the track it belongs to until it is dismissed —
    /// clearing the owner at the moment of failure made it look like
    /// whatever was open had failed.
    func dismissApplyStage() {
        guard applyBelongsToCurrentMaterial else { return }
        applyStage = .idle
        applyOwnerId = nil
    }

    /// Restore the pristine file and clear the program (Tier 1.10). The
    /// backup is consumed: after this the file *is* the original.
    /// Revert a track the Editor is not necessarily showing — what the
    /// Library's row menu calls. It does NOT open the Editor: taking over a
    /// session the user is mid-edit in, to act on a different track, is a
    /// surprise nobody asked for.
    ///
    /// Returns false when a render is in flight, so the caller can say so
    /// rather than appearing to do nothing.
    @discardableResult
    func revert(songId: String) -> Bool {
        guard !applyStage.isBusy else { return false }
        if material?.id == songId {
            revertToOriginal()
            return true
        }
        guard let song = library.song(id: songId),
              FileManager.default.fileExists(atPath: song.backupURL.path)
        else { return false }
        restoreOriginal(ownerId: song.id, ownerType: "song",
                        backupURL: song.backupURL,
                        restoredName: (song.editsJSON.flatMap {
                            try? JSONDecoder().decode(
                                EditDocument.self, from: Data($0.utf8))
                        })?.originalFileName ?? song.fileName,
                        reopenWhenDone: false)
        return true
    }

    /// Revert whatever the Editor currently holds.
    func revertToOriginal() {
        guard let material, hasBackup else {
            // No apply ever happened — reverting is just clearing the list.
            perform("Revert to Original") { doc in
                doc.ops.removeAll()
                doc.effects.removeAll()
            }
            selection = nil
            flushPersist()
            return
        }
        // Never while a render is running — and never by writing into a
        // stage this path does not own.
        guard !applyStage.isBusy else { return }
        stopPreview()
        uploadedSourceId = nil
        // The rows below are the truth from here on; a write still queued
        // from the last keystroke would put the cleared program straight
        // back (the reopen at the end of this method flushes).
        discardPendingWrite()
        // The restore runs across an await now, and the reopen at the end of
        // it rebuilds the stack anyway. Dropping the actions here means a ⌘Z
        // arriving in that window cannot put the cleared program back — the
        // frozen surface makes that hard to reach, but undo is a menu command
        // and menus are not part of the surface.
        undoManager?.removeAllActions()
        let restoredName = document.originalFileName ?? material.fileName
        restoreOriginal(ownerId: material.id,
                        ownerType: material.ownerType,
                        backupURL: material.backupURL,
                        restoredName: restoredName,
                        reopenWhenDone: true)
    }

    /// Put the pristine file back and clear the program. Shared by both
    /// entry points, and deliberately id-based: it must work on a track the
    /// Editor is not showing.
    ///
    /// The file half is detached. It is a byte-for-byte copy of a whole track
    /// — the same copy the backup stash makes, which was measured freezing the
    /// window for its duration — plus an `AVAudioFile` header open, and both
    /// used to run inline on the main actor.
    ///
    /// What makes that safe is the busy stage held across the whole thing.
    /// `EditorScreen.isFrozen` is `currentApplyStage.isBusy`, so the editing
    /// surface, its key commands and the undo buttons are all closed while
    /// this runs; `applyEdits` and `revert` both refuse while `applyStage`
    /// is busy, so a second render or restore cannot start; and the callers
    /// have already dropped the pending write and the undo stack, so nothing
    /// can rewrite the row from underneath. `open` leaves a busy stage alone
    /// (it only idles one it owns), so switching tracks mid-restore does not
    /// release the gate.
    ///
    /// It no longer reports success: the only caller that read the result
    /// used it for a "blocked by another render" message, and that answer is
    /// settled by the pre-checks before any of this starts. A failure of the
    /// copy itself surfaces as `.failed` on the stage, as it always did.
    private func restoreOriginal(ownerId: String, ownerType: String,
                                 backupURL: URL, restoredName: String,
                                 reopenWhenDone: Bool) {
        let isPart = ownerType == "part"
        let currentURL: URL? = isPart
            ? ((try? partsRepo.part(id: ownerId)) ?? nil)?.fileURL
            : library.song(id: ownerId)?.fileURL
        let restoredURL = isPart
            ? StoragePaths.libraryParts.appendingPathComponent(restoredName)
            : StoragePaths.libraryAudio.appendingPathComponent(restoredName)
        applyOwnerId = ownerId
        applyStage = .restoring
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> (shape: (durationS: Double?, sampleRate: Int?)?,
                       failure: String?) in
                let fm = FileManager.default
                do {
                    if let currentURL { try? fm.removeItem(at: currentURL) }
                    try? fm.removeItem(at: restoredURL)
                    try fm.copyItem(at: backupURL, to: restoredURL)
                } catch {
                    return (nil, error.localizedDescription)
                }
                return (Self.audioShape(of: restoredURL), nil)
            }.value
            guard let self else { return }
            if let failure = outcome.failure {
                self.applyStage = .failed("Could not restore the original: "
                                          + failure)
                self.applyOwnerId = ownerId
            } else {
                self.finishRestore(ownerId: ownerId, isPart: isPart,
                                   restoredName: restoredName,
                                   shape: outcome.shape ?? (nil, nil),
                                   reopenWhenDone: reopenWhenDone)
            }
        }
    }

    /// The main-actor half of a restore: rewrite the row, sweep the backups
    /// and drop the stale peaks, then release the gate.
    private func finishRestore(ownerId: String, isPart: Bool,
                               restoredName: String,
                               shape: (durationS: Double?, sampleRate: Int?),
                               reopenWhenDone: Bool) {
        let fm = FileManager.default
        if isPart {
            if var part = ((try? partsRepo.part(id: ownerId)) ?? nil) {
                part.fileName = restoredName
                part.durationS = shape.durationS
                part.sampleRate = shape.sampleRate
                part.editsJSON = nil
                part.editedAt = nil
                part.backupFileName = nil
                try? partsRepo.update(part)
            }
        } else if var song = library.song(id: ownerId) {
            song.fileName = restoredName
            song.durationS = shape.durationS ?? song.durationS
            song.sampleRate = shape.sampleRate ?? song.sampleRate
            song.editsJSON = nil
            song.editedAt = nil
            song.backupFileName = nil
            library.update(song)
        }
        for backup in StoragePaths.backups(forId: ownerId) {
            try? fm.removeItem(at: backup)
        }
        refreshBackupState()
        WaveformExtractor.invalidateCache(
            StoragePaths.libraryWaveforms
                .appendingPathComponent(ownerId + ".peaks"))
        WaveformExtractor.invalidateCache(
            StoragePaths.libraryWaveforms
                .appendingPathComponent(ownerId + ".original.peaks"))
        applyStage = .idle
        applyOwnerId = nil
        // Reload from the records so every readout reflects the restore —
        // but only if this is still the track on screen. The user may have
        // opened another one while the copy ran.
        if reopenWhenDone, material?.id == ownerId {
            isPart ? open(partId: ownerId) : open(songId: ownerId)
        }
    }

    // MARK: export (Tier 2.8)

    struct ExportChoice: Equatable {
        var format = "wav"          // wav | aiff | flac | mp3
        var bitDepth = "pcm24"      // pcm16 | pcm24 | float32
        var sampleRateHz: Int?      // nil = same as source
        var applyEdits = true
    }

    /// Render the selection (or, with no selection, the whole program) into
    /// `destination`. Runs through the engine — there is no Swift-side
    /// renderer, deliberately.
    func exportSelection(choice: ExportChoice, destination: URL) async {
        guard let material, exportStage.isBusy == false else { return }
        guard let model = mixdownModel else {
            exportStage = .failed("The Mixdown & Align (DSP) model is not "
                                  + "installed — it renders exports.")
            return
        }
        var exportDoc: EditDocument
        if choice.applyEdits {
            exportDoc = document
            if let selection {
                exportDoc.ops.append(EditOp(kind: .trim(selection)))
            }
        } else {
            // The bare material under the selection: the same slices, with
            // every treatment stripped — what you selected, not what you
            // turned it into.
            exportDoc = EditDocument()
            let range = selection
                ?? EditRange(start: 0, end: timelineDurationS)
            var slices = EditProgram.extract(segments, range: range)
            for index in slices.indices { slices[index].gainDb = 0 }
            let length = slices.reduce(0) { $0 + $1.length }
            exportDoc.ops = [
                EditOp(kind: .paste(at: 0, slices: slices)),
                EditOp(kind: .trim(EditRange(start: 0, end: length))),
            ]
            exportDoc.joinCrossfadeMs = document.joinCrossfadeMs
        }
        if let hz = choice.sampleRateHz {
            exportDoc.ops.append(EditOp(kind: .resample(hz: hz)))
        }
        // Planned BEFORE the upload, so a render that cannot succeed is
        // refused without sending the file anywhere.
        var plan = EditMixPlan.plan(
            document: exportDoc, source: "PENDING",
            sourceDuration: sourceDurationS,
            sampleRate: material.sampleRate, sourceBpm: bpm)
        guard plan.isRenderable else {
            exportStage = .failed("There is nothing to export — the "
                                  + "selection is silent.")
            return
        }
        exportStage = .uploading
        guard let sourceId = await uploadSource() else {
            exportStage = .failed(jobs.lastError ?? "Upload failed")
            return
        }
        for index in plan.spec.tracks.indices {
            plan.spec.tracks[index].source = sourceId
        }
        guard await resolveIRUploads(&plan.spec) else {
            exportStage = .failed(jobs.lastError ?? "IR upload failed")
            return
        }
        guard let created = await jobs.submitEditorRender(
            modelId: model.id, spec: plan.spec,
            normalize: choice.applyEdits && plan.normalize,
            limiter: choice.applyEdits && plan.limiter,
            targetLufs: plan.targetLufs,
            outputFormat: choice.format, bitDepth: choice.bitDepth,
            purpose: .export(destination: destination,
                             title: material.title)),
            let jobId = created.jobs.first?.jobId else {
            exportStage = .failed(jobs.lastError ?? "Submit failed")
            return
        }
        exportStage = .queued(jobId: jobId)
        watchJob(jobId, kind: .export)
    }

    /// The name the save panel offers: `Drums — test01 (1_12–1_21).wav`.
    /// Colons are path separators to AppKit, so the clock's dots stay and
    /// its colon becomes an underscore.
    ///
    /// `nonisolated` because it is pure string work: the file-name rule is
    /// the sort of thing a test should reach without an actor hop.
    nonisolated static func exportName(title: String, songTitle: String?,
                           selection: EditRange?, format: String) -> String {
        var base = title.replacingOccurrences(of: "/", with: "-")
        if let songTitle {
            base += " — " + songTitle.replacingOccurrences(of: "/", with: "-")
        }
        if let selection {
            let clock = { (t: Double) in
                EditorClock.short(t).replacingOccurrences(of: ":", with: "_")
            }
            base += " (\(clock(selection.start))–\(clock(selection.end)))"
        }
        return base + "." + format
    }

    // MARK: send-onward snippets (Tier 3.1)

    /// Render the selection as it sounds under the program, land it in the
    /// library as its own row, and let the shell route it onward.
    func sendSelection(_ intent: SnippetIntent) async {
        guard let material, let selection, exportStage.isBusy == false
        else { return }
        guard let model = mixdownModel else {
            exportStage = .failed("The Mixdown & Align (DSP) model is not "
                                  + "installed — it renders selections.")
            return
        }
        var snippetDoc = document
        snippetDoc.ops.append(EditOp(kind: .trim(selection)))
        var plan = EditMixPlan.plan(
            document: snippetDoc, source: "PENDING",
            sourceDuration: sourceDurationS,
            sampleRate: material.sampleRate, sourceBpm: bpm)
        guard plan.isRenderable else {
            exportStage = .failed("There is nothing in that selection to "
                                  + "send — it is silent.")
            return
        }
        exportStage = .uploading
        guard let sourceId = await uploadSource() else {
            exportStage = .failed(jobs.lastError ?? "Upload failed")
            return
        }
        for index in plan.spec.tracks.indices {
            plan.spec.tracks[index].source = sourceId
        }
        guard await resolveIRUploads(&plan.spec) else {
            exportStage = .failed(jobs.lastError ?? "IR upload failed")
            return
        }
        let title = "\(material.title) "
            + "(\(EditorClock.short(selection.start))–"
            + "\(EditorClock.short(selection.end)))"
        guard let created = await jobs.submitEditorRender(
            modelId: model.id, spec: plan.spec, normalize: plan.normalize,
            limiter: plan.limiter, targetLufs: plan.targetLufs,
            purpose: .snippet(title: title)),
            let jobId = created.jobs.first?.jobId else {
            exportStage = .failed(jobs.lastError ?? "Submit failed")
            return
        }
        noteSnippetIntent(intent, jobId: jobId)
        exportStage = .queued(jobId: jobId)
        watchJob(jobId, kind: .export)
    }

    // MARK: artifact handling (wired from AppEnvironment)

    func handleArtifact(job: JobInfo, result: JobResult,
                        purpose: EditorRenderPurpose) {
        guard let artifact = (result.artifacts ?? [])
            .first(where: { $0.kind == "audio" }) else { return }
        switch purpose {
        case .apply(let ownerId, let ownerType, _, let documentJSON):
            finishApply(artifact: artifact, ownerId: ownerId,
                        ownerType: ownerType, documentJSON: documentJSON)
        case .export(let destination, _):
            // Off the main actor, unlike `finishApply`'s move: that one lands
            // inside Application Support and is a same-volume rename, but the
            // export destination comes from a save panel and is routinely an
            // external drive or a network share — where "move" is a
            // copy-and-delete of a whole rendered WAV, seconds of it, right
            // at the moment the render finishes.
            let source = URL(fileURLWithPath: artifact.path)
            Task { [weak self] in
                let failure: String? = await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: destination)
                    do {
                        try fm.moveItem(at: source, to: destination)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                guard let self else { return }
                self.exportStage = failure.map {
                    .failed("Could not save the export: " + $0)
                } ?? .idle
            }
        case .snippet(let title):
            finishSnippet(job: job, artifact: artifact, title: title)
        }
    }

    private func finishApply(artifact: JobArtifact, ownerId: String,
                             ownerType: String, documentJSON: String?) {
        let isCurrent = material?.id == ownerId
        if isCurrent || applyOwnerId == ownerId { applyStage = .replacing }
        let fm = FileManager.default
        let newFileName = "\(ownerId).\(artifact.format)"
        let directory = ownerType == "part" ? StoragePaths.libraryParts
                                            : StoragePaths.libraryAudio
        let newURL = directory.appendingPathComponent(newFileName)
        // The row is the authority on what the live file is called: the
        // apply may have finished while the user was looking at another
        // track, so this must not read the loaded material.
        let oldURL: URL? = ownerType == "part"
            ? ((try? partsRepo.part(id: ownerId)) ?? nil)?.fileURL
            : library.song(id: ownerId)?.fileURL
        do {
            // The old file may have a different extension (an imported mp3
            // becomes wav on first apply) — both names come off.
            if let oldURL, oldURL != newURL { try? fm.removeItem(at: oldURL) }
            try? fm.removeItem(at: newURL)
            try fm.moveItem(at: URL(fileURLWithPath: artifact.path),
                            to: newURL)
        } catch {
            if isCurrent || applyOwnerId == ownerId {
                applyStage = .failed("Could not replace the file: "
                                     + error.localizedDescription)
                applyOwnerId = ownerId   // the card belongs to THIS track
            }
            return
        }
        // The program that was SUBMITTED, not whatever is loaded now.
        // No fallback to the loaded document: if the submitted program
        // cannot be read back, the row keeps what it had rather than being
        // stamped with whatever happens to be open now.
        guard var appliedDoc = documentJSON.flatMap({
            try? JSONDecoder().decode(EditDocument.self, from: Data($0.utf8))
        }) else {
            if isCurrent || applyOwnerId == ownerId {
                applyStage = .failed("The rendered edit could not be "
                                     + "recorded — the file was replaced but "
                                     + "its edit list was not saved.")
                applyOwnerId = ownerId
            }
            return
        }
        appliedDoc.appliedAt = Date()
        let json = (try? JSONEncoder().encode(appliedDoc))
            .map { String(decoding: $0, as: UTF8.self) }
        if ownerType == "part" {
            if var part = ((try? partsRepo.part(id: ownerId)) ?? nil) {
                part.fileName = newFileName
                part.durationS = artifact.durationS ?? part.durationS
                part.sampleRate = artifact.sampleRate ?? part.sampleRate
                part.editsJSON = json
                part.editedAt = Date()
                try? partsRepo.update(part)
            }
        } else if var song = library.song(id: ownerId) {
            song.fileName = newFileName
            song.durationS = artifact.durationS ?? song.durationS
            song.sampleRate = artifact.sampleRate ?? song.sampleRate
            song.editsJSON = json
            song.editedAt = Date()
            library.update(song)
        }
        let peaksURL = StoragePaths.libraryWaveforms
            .appendingPathComponent(ownerId + ".peaks")
        WaveformExtractor.invalidateCache(peaksURL)
        if isCurrent {
            document = appliedDoc
            appliedDocument = appliedDoc
            // The live file moved, so the cached upload id names the wrong
            // audio; the next render must upload again. (It still renders
            // from the backup — but only after this is dropped.)
            uploadedSourceId = nil
            // Refresh the loaded material's facts without resetting the
            // session.
            if var current = material {
                current.fileURL = newURL
                current.fileName = newFileName
                current.fileDurationS = artifact.durationS
                    ?? current.fileDurationS
                current.sampleRate = artifact.sampleRate ?? current.sampleRate
                material = current
            }
        }
        if notifyWhenApplied {
            notifyApplied(titleOf(ownerId: ownerId, ownerType: ownerType))
            notifyWhenApplied = false
        }
        if isCurrent || applyOwnerId == ownerId {
            applyStage = .rebuildingPeaks
        }
        Task {
            _ = try? await WaveformExtractor.shared.peaks(for: newURL,
                                                          cacheURL: peaksURL)
            if case .rebuildingPeaks = self.applyStage {
                self.applyStage = .idle
            }
            if self.applyOwnerId == ownerId { self.applyOwnerId = nil }
        }
    }

    private func titleOf(ownerId: String, ownerType: String) -> String {
        if ownerType == "part" {
            return ((try? partsRepo.part(id: ownerId)) ?? nil)?.name
                ?? "Edited stem"
        }
        return library.song(id: ownerId)?.title ?? "Edited track"
    }

    private func finishSnippet(job: JobInfo, artifact: JobArtifact,
                               title: String) {
        let songId = UUID().uuidString.lowercased()
        let fileName = "\(songId).\(artifact.format)"
        let dest = StoragePaths.libraryAudio.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: StoragePaths.libraryAudio, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: artifact.path), to: dest)
        } catch {
            exportStage = .failed("Could not keep the selection: "
                                  + error.localizedDescription)
            return
        }
        let song = SongRecord(
            id: songId, title: library.uniqueTitle(title),
            prompt: "", lyrics: nil,
            modelId: job.modelId, modelName: "Editor selection",
            groupId: job.groupId, paramsJSON: "{}",
            durationS: artifact.durationS ?? 0,
            sampleRate: artifact.sampleRate ?? 44100,
            fileName: fileName, seedUsed: nil, createdAt: Date(), rating: 0,
            notes: "Cut in the Editor from “\(material?.title ?? "a track")”.",
            favorite: false, origin: SongOrigin.recombined.rawValue,
            recipeId: "editor-selection")
        library.insert(song)
        exportStage = .idle
        if let intent = takeSnippetIntent(jobId: job.jobId) {
            onSnippetReady(song, intent)
        }
    }

    // MARK: shared plumbing

    /// Record where the backup went, so the path survives the file being
    /// renamed by this very apply.
    func noteBackupFileName(_ name: String, ownerId: String,
                            ownerType: String) {
        if ownerType == "part" {
            if var part = ((try? partsRepo.part(id: ownerId)) ?? nil) {
                part.backupFileName = name
                try? partsRepo.update(part)
            }
        } else if var song = library.song(id: ownerId) {
            song.backupFileName = name
            library.update(song)
        }
        if var current = material, current.id == ownerId {
            current.backupURL = StoragePaths.libraryBackups
                .appendingPathComponent(name)
            material = current
        }
    }

    private func uploadSource() async -> String? {
        // The engine purges every upload at startup, so ids never outlive the
        // engine process that took them (api-contract §7). Nothing used to
        // invalidate this cache: after Render ▸ Restart Engine (or a crash, or
        // a model-library relocate) the next Apply failed 422 "unknown upload
        // id" and every retry short-circuited on the same dead id, so the
        // track stayed un-appliable until it was closed and reopened — with
        // the backup already stashed by then.
        let generation = engineGeneration()
        if uploadedSourceGeneration != generation { uploadedSourceId = nil }
        if let uploadedSourceId { return uploadedSourceId }
        guard let sourceURL else { return nil }
        let id = await jobs.uploadAudio(fileURL: sourceURL)
        uploadedSourceId = id
        uploadedSourceGeneration = generation
        return id
    }

    /// Swap each convolve effect's local IR path for an upload id — the
    /// spec is built with the path so planning stays synchronous, and no
    /// local path may ever reach the wire. False = an upload failed
    /// (jobs.lastError has the words).
    private func resolveIRUploads(_ spec: inout MixSpec) async -> Bool {
        var uploaded: [String: String] = [:]   // path → upload id, once each
        for t in spec.tracks.indices {
            guard var effects = spec.tracks[t].effects else { continue }
            for e in effects.indices where effects[e].type == "convolve" {
                guard let path = effects[e].ir else { continue }
                if uploaded[path] == nil {
                    guard let id = await jobs.uploadAudio(
                        fileURL: URL(fileURLWithPath: path)) else {
                        return false
                    }
                    uploaded[path] = id
                }
                effects[e].ir = uploaded[path]
            }
            spec.tracks[t].effects = effects
        }
        return true
    }

    enum WatchKind { case apply, export }

    /// Follows the queue for failure and progress. Success arrives through
    /// `handleArtifact`; this notices everything else (contract: the job can
    /// fail or be cancelled from anywhere, including another client).
    func watchJob(_ jobId: String, kind: WatchKind) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                guard let active = self.jobs.job(jobId) else {
                    // Dismissed after success — handleArtifact took over.
                    return
                }
                switch active.status {
                case .failed:
                    let message = active.error?.message ?? "The render failed"
                    if kind == .apply {
                        self.applyStage = .failed(message)
                        // Ownership is kept, not cleared: the failure card
                        // belongs to the track that was rendering, and
                        // clearing it would show the failure on whatever is
                        // open instead.
                    } else {
                        self.exportStage = .failed(message)
                    }
                    return
                case .canceled:
                    if kind == .apply {
                        self.applyStage = .idle
                        self.applyOwnerId = nil
                    } else {
                        self.exportStage = .idle
                    }
                    return
                case .succeeded:
                    return
                default:
                    // Through the gated setters. This loop runs three times a
                    // second for the length of a render and most ticks carry
                    // no new progress at all — the engine's own events are
                    // slower than the poll — so assigning unconditionally
                    // republished an identical stage and redrew the apply
                    // card, the toolbar and the row menus for nothing.
                    if kind == .apply {
                        if active.status == .queued {
                            self.setApplyStage(.queued(jobId: jobId))
                        } else {
                            self.setApplyStage(.rendering(
                                jobId: jobId,
                                fraction: active.progress?.fraction,
                                etaS: active.progress?.etaS,
                                message: active.progress?.message))
                        }
                    } else if self.exportStage.isBusy {
                        if active.status != .queued {
                            self.setExportStage(.rendering(
                                jobId: jobId,
                                fraction: active.progress?.fraction,
                                etaS: active.progress?.etaS,
                                message: active.progress?.message))
                        }
                    }
                }
            }
        }
    }

    /// The engine's `bit_depth` word for a file's own sample format, or nil
    /// when it is the default (16-bit) or cannot be read.
    nonisolated static func bitDepth(of url: URL) -> String? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.fileFormat.streamDescription.pointee
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            return "float32"
        }
        switch format.mBitsPerChannel {
        case 24, 32: return "pcm24"     // 32-bit int has no wire word; 24 is
                                        // the closest honest one
        default: return nil             // 16 and below: the default
        }
    }

    nonisolated private static func audioShape(of url: URL)
        -> (durationS: Double?, sampleRate: Int?) {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate > 0 else { return (nil, nil) }
        return (Double(file.length) / file.fileFormat.sampleRate,
                Int(file.fileFormat.sampleRate))
    }
}
