import XCTest
@testable import LocalMusic

/// The Editor's end-to-end loop against the stub, in the same shape as
/// `RecombineFlowTests`: import a file, delete a middle region, fade out,
/// apply — then confirm the file was replaced, the backup kept, and Revert
/// puts the original back.
@MainActor
final class EditorFlowTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 90,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    private func makeWav(at url: URL, hz: Double, seconds: Double = 4.0,
                         rate: Int = 8000) throws {
        let n = Int(seconds * Double(rate))
        var samples = [Int16]()
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            samples.append(Int16(sin(2 * .pi * hz * t) * 20000))
        }
        var data = Data()
        func put(_ s: String) { data.append(Data(s.utf8)) }
        func put32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func put16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        put("RIFF"); put32(UInt32(36 + n * 2)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(n * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    func testApplyReplacesTheFileAndRevertRestoresIt() async throws {
        setenv("LOCALMUSIC_STUB_DOWNLOAD_S", "1", 1)
        setenv("LOCALMUSIC_STUB_PROVISION_S", "1", 1)
        setenv("LOCALMUSIC_STUB_JOB_SPEED", "4", 1)
        defer {
            unsetenv("LOCALMUSIC_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSIC_STUB_PROVISION_S")
            unsetenv("LOCALMUSIC_STUB_JOB_SPEED")
        }

        let script = Self.repoRoot
            .appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(
            modeOverride: .spawn(command: ["/bin/bash", "-lc",
                                           "exec \"\(script)\" \"$@\"",
                                           "local-music-engine"]),
            database: try DatabaseManager.inMemory())
        env.startBackend()
        try await waitFor("catalog") { !env.catalog.models.isEmpty }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("tone.wav")
        try makeWav(at: source, hz: 440)
        let imported = await env.library.importSongs(urls: [source])
        let song = try XCTUnwrap(imported.first)

        let model = try XCTUnwrap(
            env.catalog.models.first { $0.id == "dsp-stub" })
        await env.catalog.startDownload(model)
        try await waitFor("dsp-stub installed") {
            env.catalog.models.first { $0.id == "dsp-stub" }?
                .installState == .installed
        }

        let editor = env.editor!
        editor.open(songId: song.id)
        XCTAssertEqual(editor.material?.id, song.id)
        let originalDuration = editor.timelineDurationS
        XCTAssertGreaterThan(originalDuration, 3)
        XCTAssertFalse(editor.hasBackup)
        XCTAssertFalse(editor.isDirty)

        // Delete a middle second, then fade the tail.
        editor.selection = EditRange(start: 1, end: 2)
        editor.deleteSelection()
        editor.setFadeOut(seconds: 0.5, curve: .linear)
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(editor.document.ops.count, 2)
        XCTAssertEqual(editor.timelineDurationS, originalDuration - 1,
                       accuracy: 0.01)
        // The pending program is stored before any apply, so "continue
        // editing" survives a relaunch. The write trails the edit by a beat
        // — it is debounced, because a slider drag would otherwise re-query
        // the whole library per frame.
        try await waitFor("pending program stored", timeout: 5) {
            env.library.song(id: song.id)?.editsJSON != nil
        }
        XCTAssertNil(env.library.song(id: song.id)?.editedAt,
                     "stored, but not marked applied")

        await editor.applyEdits()
        try await waitFor("edits applied") {
            env.library.song(id: song.id)?.editedAt != nil
        }
        try await waitFor("apply settled") { !editor.applyStage.isBusy }

        let edited = try XCTUnwrap(env.library.song(id: song.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited.fileURL.path),
                      "the rendered file replaced the original in place")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: edited.backupURL.path), "the backup was stashed")
        XCTAssertTrue(editor.hasBackup)
        XCTAssertFalse(editor.isDirty, "the pending program is now applied")
        // Same row, same id, same title — one file with one name.
        XCTAssertEqual(edited.id, song.id)
        XCTAssertEqual(edited.title, song.title)
        // The Library's badge reads the applied document, not the pending one.
        XCTAssertEqual(LibrarySongRow.editCount(of: edited), 2)

        // Reopening picks the program back up rather than starting over.
        editor.close()
        editor.open(songId: song.id)
        XCTAssertEqual(editor.document.ops.count, 2)
        XCTAssertFalse(editor.isDirty)
        XCTAssertNotNil(editor.document.originalDurationS)

        editor.revertToOriginal()
        // Nothing queued may write the cleared program back afterwards.
        try await Task.sleep(for: .milliseconds(500))
        let reverted = try XCTUnwrap(env.library.song(id: song.id))
        XCTAssertNil(reverted.editsJSON)
        XCTAssertNil(reverted.editedAt)
        XCTAssertNil(reverted.backupFileName)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: reverted.backupURL.path),
            "the backup is consumed — the file IS the original now")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: reverted.fileURL.path))
        XCTAssertEqual(reverted.durationS, song.durationS, accuracy: 0.05)
        XCTAssertNil(LibrarySongRow.editCount(of: reverted))
    }

    /// Applying with no mixdown model installed says so rather than failing
    /// silently — and never touches the file.
    func testApplyWithoutTheMixdownModelIsRefusedCleanly() async throws {
        // No backend at all: the catalog is empty, so no model declares
        // mix_spec, which is exactly the state this refusal is about.
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-refuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("tone.wav")
        try makeWav(at: source, hz: 330)
        let imported = await env.library.importSongs(urls: [source])
        let song = try XCTUnwrap(imported.first)

        let editor = env.editor!
        editor.open(songId: song.id)
        editor.selection = EditRange(start: 0.5, end: 1.5)
        editor.deleteSelection()
        await editor.applyEdits()

        if case .failed(let message) = editor.applyStage {
            XCTAssertTrue(message.contains("Mixdown"), message)
        } else {
            XCTFail("expected a refusal, got \(editor.applyStage)")
        }
        XCTAssertFalse(editor.hasBackup, "nothing was stashed")
        XCTAssertNil(env.library.song(id: song.id)?.editedAt)
    }
}

/// Store-level behaviour that the audit found broken: amplify row matching,
/// undo coalescing across a drag, and the backup surviving a rename.
@MainActor
final class EditorStoreTests: XCTestCase {

    private func makeStore() throws -> (EditorStore, SongRecord, AppEnvironment) {
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        let song = SongRecord(
            id: "s1", title: "Tone", prompt: "", lyrics: nil,
            modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
            durationS: 100, sampleRate: 44100, fileName: "s1.wav",
            seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
            favorite: false)
        env.library.insert(song)
        env.editor.open(songId: song.id)
        return (env.editor, song, env)
    }

    /// Amplify matches the row that targets THIS selection, not whatever op
    /// happens to be last — otherwise a fade in between makes the next drag
    /// append a second amplify that the engine sums.
    func testAmplifyDoesNotStackBehindAnotherOp() throws {
        let (store, _, _) = try makeStore()
        store.selection = EditRange(start: 0, end: 10)
        store.setAmplify(db: 6)
        XCTAssertEqual(store.amplifyDbForSelection, 6, accuracy: 1e-9)

        store.setFadeIn(seconds: 1.5, curve: .linear)
        // The selection is still amplified, and the readout still says so.
        XCTAssertEqual(store.amplifyDbForSelection, 6, accuracy: 1e-9)

        store.setAmplify(db: 6)
        let amplifies = store.document.ops.filter { op in
            if case .amplify = op.kind { return true }
            return false
        }
        XCTAssertEqual(amplifies.count, 1, "no second amplify was appended")
        let segment = store.segments.first { $0.sourceStart < 10 }
        XCTAssertEqual(segment?.gainDb ?? 0, 6, accuracy: 1e-9,
                       "the wire gain matches what the slider reads")
    }

    func testAmplifyToZeroRemovesTheRow() throws {
        let (store, _, _) = try makeStore()
        store.selection = EditRange(start: 0, end: 10)
        store.setAmplify(db: 4)
        store.setAmplify(db: 0)
        XCTAssertTrue(store.document.ops.isEmpty)
    }

    /// A slider drag is one undo step however many frames it spans: each
    /// frame carries the same coalescing key, so only the first registers.
    func testACoalescedDragIsOneUndoStep() throws {
        let (store, _, _) = try makeStore()
        store.selection = EditRange(start: 0, end: 10)

        for db in stride(from: 0.5, through: 6.0, by: 0.5) {
            store.setAmplify(db: db)
        }
        XCTAssertEqual(store.amplifyDbForSelection, 6, accuracy: 1e-9)
        XCTAssertEqual(store.undoStepsRegistered, 1,
                       "twelve frames, one step to undo")
    }

    /// Two separate drags are two undo steps — the gesture boundary is what
    /// ends the coalescing.
    func testTwoDragsAreTwoUndoSteps() throws {
        let (store, _, _) = try makeStore()
        store.selection = EditRange(start: 0, end: 10)

        store.setAmplify(db: 3)
        store.endInteraction()
        store.setAmplify(db: 6)
        XCTAssertEqual(store.undoStepsRegistered, 2)
    }

    /// Undo restores the document and the selection it was made against.
    func testUndoRestoresTheDocumentAndSelection() throws {
        let (store, _, _) = try makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        store.selection = EditRange(start: 10, end: 20)
        store.deleteSelection()
        undo.endUndoGrouping()
        XCTAssertEqual(store.timelineDurationS, 90, accuracy: 1e-9)

        undo.undo()
        XCTAssertEqual(store.timelineDurationS, 100, accuracy: 1e-9)
        XCTAssertEqual(store.selection?.start ?? -1, 10, accuracy: 1e-9)

        undo.redo()
        XCTAssertEqual(store.timelineDurationS, 90, accuracy: 1e-9)
    }

    /// The app must never open an undo group it does not close: an
    /// unbalanced level makes the next undo raise "too many nested undo
    /// groups" and terminate the process. Nothing in the Editor opens one.
    func testEditingOpensNoUndoGroupOfItsOwn() throws {
        let (store, _, _) = try makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false      // no implicit event group to hide in
        store.undoManager = undo
        store.selection = EditRange(start: 0, end: 10)
        undo.beginUndoGrouping()
        store.setAmplify(db: 3)
        store.endInteraction()
        undo.endUndoGrouping()
        XCTAssertEqual(undo.groupingLevel, 0,
                       "every group the Editor's edits sit in was opened "
                           + "and closed by the caller")
        XCTAssertTrue(undo.canUndo)
    }

    /// Everything left of the first sound is not faded: the engine attaches
    /// the ramp to the first track, and a gap produces no track.
    func testFadeAnchorsFollowTheAudibleEdges() throws {
        let (store, _, _) = try makeStore()
        store.selection = EditRange(start: 0, end: 0)
        store.seekPreview(to: 0)
        store.insertGap(seconds: 5)
        let anchors = store.fadeAnchors
        XCTAssertEqual(anchors.headS, 5, accuracy: 1e-9)
        XCTAssertEqual(anchors.tailS, 105, accuracy: 1e-9)
    }

    /// A program that silences everything is refused in plain language
    /// rather than reaching the engine, which fails such a job outright.
    func testAllSilentProgramIsRefusedBeforeAnythingIrreversible() throws {
        let (store, song, env) = try makeStore()
        store.selectAll()
        store.silenceSelection()
        XCTAssertEqual(store.renderRefusal,
                       "There is nothing left to render — every part of this "
                           + "track has been deleted or silenced.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: song.backupURL.path), "no backup was stashed")
        XCTAssertNil(env.library.song(id: song.id)?.editedAt)
    }

    /// The backup path must not be derived from the live file name: an
    /// apply renames an imported mp3 to wav, and the original would become
    /// unreachable the moment it did.
    func testBackupPathSurvivesTheFileBeingRenamed() throws {
        var song = SongRecord(
            id: "s2", title: "Import", prompt: "", lyrics: nil,
            modelId: "imported", modelName: "Imported", groupId: nil,
            paramsJSON: "{}", durationS: 10, sampleRate: 44100,
            fileName: "s2.mp3", seedUsed: nil, createdAt: Date(), rating: 0,
            notes: "", favorite: false,
            origin: SongOrigin.imported.rawValue)
        XCTAssertEqual(song.backupURL.lastPathComponent, "s2.mp3",
                       "before an apply, derived from the current name")
        song.backupFileName = "s2.mp3"
        song.fileName = "s2.wav"          // what the first apply does
        XCTAssertEqual(song.backupURL.lastPathComponent, "s2.mp3",
                       "after it, the recorded name still finds the original")
    }
}

/// The levelling pair, the design's "pick one": amplifying a selection and
/// normalising the whole track are one decision, so the radios can never
/// both be lit.
@MainActor
final class EditorLevellingTests: XCTestCase {

    private func makeStore() throws -> EditorStore {
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        env.library.insert(SongRecord(
            id: "s1", title: "Tone", prompt: "", lyrics: nil, modelId: "m",
            modelName: "M", groupId: nil, paramsJSON: "{}", durationS: 100,
            sampleRate: 44100, fileName: "s1.wav", seedUsed: nil,
            createdAt: Date(), rating: 0, notes: "", favorite: false))
        env.editor.open(songId: "s1")
        return env.editor
    }

    func testNormaliseDropsTheSelectionAmplify() throws {
        let store = try makeStore()
        store.selection = EditRange(start: 0, end: 10)
        store.setAmplify(db: 2.5)
        store.setNormalize(lufs: -14)
        XCTAssertEqual(store.amplifyDbForSelection, 0, accuracy: 1e-9)
        XCTAssertEqual(store.document.normalizeLufs, -14)
    }

    func testAmplifyDropsNormalise() throws {
        let store = try makeStore()
        store.setNormalize(lufs: -14)
        store.selection = EditRange(start: 0, end: 10)
        store.setAmplify(db: 2.5)
        XCTAssertNil(store.document.normalizeLufs)
        XCTAssertEqual(store.amplifyDbForSelection, 2.5, accuracy: 1e-9)
    }

    /// Normalise only clears the amplify on the region the control is
    /// pointing at — a level set on some other region is not its business.
    func testNormaliseLeavesOtherRegionsAlone() throws {
        let store = try makeStore()
        store.selection = EditRange(start: 50, end: 60)
        store.setAmplify(db: 4)
        store.selection = EditRange(start: 0, end: 10)
        store.setNormalize(lufs: -14)
        store.selection = EditRange(start: 50, end: 60)
        XCTAssertEqual(store.amplifyDbForSelection, 4, accuracy: 1e-9)
        XCTAssertEqual(store.document.normalizeLufs, -14)
    }

    /// The exchange is one undo step, so nothing is lost for good.
    func testSwappingLevellingModesIsUndoable() throws {
        let store = try makeStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        store.selection = EditRange(start: 0, end: 10)
        undo.beginUndoGrouping(); store.setAmplify(db: 2.5); undo.endUndoGrouping()
        undo.beginUndoGrouping(); store.setNormalize(lufs: -14); undo.endUndoGrouping()

        undo.undo()
        XCTAssertNil(store.document.normalizeLufs)
        XCTAssertEqual(store.amplifyDbForSelection, 2.5, accuracy: 1e-9)
    }
}

/// Amplify sets a region's level, so the control has to be able to put a
/// region back to flat even when the level came from somewhere else.
@MainActor
final class EditorAmplifyTests: XCTestCase {

    private func makeStore() throws -> EditorStore {
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        env.library.insert(SongRecord(
            id: "s1", title: "Tone", prompt: "", lyrics: nil, modelId: "m",
            modelName: "M", groupId: nil, paramsJSON: "{}", durationS: 100,
            sampleRate: 44100, fileName: "s1.wav", seedUsed: nil,
            createdAt: Date(), rating: 0, notes: "", favorite: false))
        env.editor.open(songId: "s1")
        return env.editor
    }

    /// The readout reads the audio, so it follows a level set by a wider row.
    func testTheReadoutFollowsAWiderRowsLevel() throws {
        let store = try makeStore()
        store.selection = EditRange(start: 0, end: 40)
        store.setAmplify(db: 5)
        store.endInteraction()
        store.selection = EditRange(start: 10, end: 20)
        XCTAssertEqual(store.amplifyDbForSelection, 5, accuracy: 1e-9)
    }

    /// …and dialling that sub-region back to 0 actually flattens it.
    func testZeroingASubRegionOfAWiderAmplifyWorks() throws {
        let store = try makeStore()
        store.selection = EditRange(start: 0, end: 40)
        store.setAmplify(db: 5)
        store.endInteraction()
        store.selection = EditRange(start: 10, end: 20)
        store.setAmplify(db: 0)
        store.endInteraction()
        XCTAssertEqual(store.amplifyDbForSelection, 0, accuracy: 1e-9)
        // The rest of the wider region keeps its level.
        store.selection = EditRange(start: 25, end: 35)
        XCTAssertEqual(store.amplifyDbForSelection, 5, accuracy: 1e-9)
    }

    /// A selection spanning two different levels reports neither, rather
    /// than picking one and misdescribing the rest.
    func testMixedLevelsReportNothing() throws {
        let store = try makeStore()
        store.selection = EditRange(start: 0, end: 20)
        store.setAmplify(db: 5)
        store.endInteraction()
        store.selection = EditRange(start: 10, end: 40)
        XCTAssertEqual(store.amplifyDbForSelection, 0, accuracy: 1e-9)
    }

    /// Amplifying a flat region with 0 dB is not an edit at all.
    func testZeroOnAFlatRegionAddsNothing() throws {
        let store = try makeStore()
        store.selection = EditRange(start: 0, end: 10)
        store.setAmplify(db: 0)
        XCTAssertTrue(store.document.ops.isEmpty)
    }
}

/// The clipboard belongs to the track it was cut from, and auto-trim says
/// what it did.
@MainActor
final class EditorClipboardAndTrimTests: XCTestCase {

    private func makeEnv() throws -> AppEnvironment {
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        for (id, title) in [("s1", "One"), ("s2", "Two")] {
            env.library.insert(SongRecord(
                id: id, title: title, prompt: "", lyrics: nil, modelId: "m",
                modelName: "M", groupId: nil, paramsJSON: "{}",
                durationS: 100, sampleRate: 44100, fileName: "\(id).wav",
                seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                favorite: false))
        }
        return env
    }

    func testPasteIsOfferedOnlyInTheTrackTheCopyCameFrom() throws {
        let env = try makeEnv()
        let store = env.editor!
        store.open(songId: "s1")
        store.selection = EditRange(start: 10, end: 20)
        store.copySelection()
        XCTAssertTrue(store.canPaste)
        XCTAssertEqual(store.clipboardSourceTitle, "One")

        store.open(songId: "s2")
        XCTAssertFalse(store.canPaste, "a slice points into the file it "
                       + "was cut from")
        // Kept, not discarded, so the menu can explain itself.
        XCTAssertFalse(store.clipboard.isEmpty)
        XCTAssertEqual(store.clipboardSourceTitle, "One")

        let before = store.document.ops.count
        store.paste()
        XCTAssertEqual(store.document.ops.count, before, "and it refuses")

        store.open(songId: "s1")
        XCTAssertTrue(store.canPaste, "back where it came from")
        store.paste()
        XCTAssertEqual(store.document.ops.count, 1)
    }

    /// Auto-trim on material with no edge silence used to do nothing at all,
    /// with nothing on screen to say so.
    func testAutoTrimSaysWhenItFoundNothing() async throws {
        let env = try makeEnv()
        let store = env.editor!
        store.open(songId: "s1")
        // No file on disk, so detection finds nothing — the point is that
        // the silence is reported rather than swallowed.
        await store.autoTrimSilence(thresholdDb: -48)
        XCTAssertNotNil(store.actionNote)
        XCTAssertTrue(store.actionNote?.contains("Nothing to trim") ?? false,
                      store.actionNote ?? "no note")
        XCTAssertTrue(store.document.ops.isEmpty)
    }

    func testTheThresholdMenuOffersARange() {
        XCTAssertEqual(EditorStore.autoTrimThresholdsDb,
                       [-36, -42, -48, -54, -60])
    }
}

// MARK: - Closing the open track

@MainActor
final class EditorCloseTests: XCTestCase {
    private func makeEnv() throws -> AppEnvironment {
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        for (id, title) in [("s1", "Tone"), ("s2", "Other")] {
            env.library.insert(SongRecord(
                id: id, title: title, prompt: "", lyrics: nil, modelId: "m",
                modelName: "M", groupId: nil, paramsJSON: "{}", durationS: 100,
                sampleRate: 44100, fileName: "\(id).wav", seedUsed: nil,
                createdAt: Date(), rating: 0, notes: "", favorite: false))
        }
        return env
    }

    /// The button's whole job: the track goes away and the welcome screen is
    /// what `material == nil` draws.
    func testCloseReturnsToTheWelcomeScreen() throws {
        let env = try makeEnv()
        env.editor.open(songId: "s1")
        XCTAssertNotNil(env.editor.material)

        env.editor.close()
        XCTAssertNil(env.editor.material, "the screen falls back to its empty state")
        XCTAssertTrue(env.editor.document.isEmpty)
        XCTAssertNil(env.editor.selection)
        XCTAssertFalse(env.editor.isPlaying)
    }

    /// Why the button needs no confirmation: closing flushes the edit list to
    /// the row, so reopening brings back every unapplied edit.
    func testUnappliedEditsSurviveACloseAndReopen() throws {
        let env = try makeEnv()
        env.editor.open(songId: "s1")
        env.editor.selection = EditRange(start: 10, end: 30)
        env.editor.deleteSelection()
        let editsBefore = env.editor.document.editCount
        XCTAssertGreaterThan(editsBefore, 0)
        XCTAssertTrue(env.editor.isDirty)

        env.editor.close()
        XCTAssertTrue(env.editor.document.isEmpty, "closed means nothing open")

        env.editor.open(songId: "s1")
        XCTAssertEqual(env.editor.document.editCount, editsBefore,
                       "the edit list came back with the track")
        XCTAssertTrue(env.editor.isDirty)
    }

    /// Closing must not forget what you cut. `canPaste` still refuses a slice
    /// from another recording, but the clipboard is kept so the menu can
    /// explain itself instead of greying out in silence.
    func testCloseKeepsTheClipboardSoPasteCanExplainItself() throws {
        let env = try makeEnv()
        env.editor.open(songId: "s1")
        env.editor.selection = EditRange(start: 10, end: 20)
        env.editor.copySelection()
        XCTAssertTrue(env.editor.canPaste)

        env.editor.close()
        XCTAssertFalse(env.editor.clipboard.isEmpty,
                       "a close is not a reason to forget the clipboard")
        XCTAssertEqual(env.editor.clipboardSourceTitle, "Tone")

        // Reopening the source it came from makes it usable again.
        env.editor.open(songId: "s1")
        XCTAssertTrue(env.editor.canPaste)

        // A different track refuses it, but can still say where it came from.
        env.editor.open(songId: "s2")
        XCTAssertFalse(env.editor.canPaste)
        XCTAssertEqual(env.editor.clipboardSourceTitle, "Tone")
    }

    /// Undo must not reach back into a track that is no longer open.
    func testCloseClearsUndoForTheClosedTrack() throws {
        let env = try makeEnv()
        env.editor.open(songId: "s1")
        env.editor.selection = EditRange(start: 10, end: 30)
        env.editor.deleteSelection()
        env.editor.close()
        XCTAssertTrue(env.editor.document.isEmpty)
    }
}
