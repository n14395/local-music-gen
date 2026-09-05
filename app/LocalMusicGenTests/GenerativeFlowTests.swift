import XCTest
@testable import LocalMusicGen

@MainActor
final class GenerativeFlowTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func tearDown() {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles = []
        super.tearDown()
    }

    // MARK: model gating (data-driven, by declared params)

    private func model(id: String, installed: Bool = true,
                       params: [ParamSpec]) -> ModelInfo {
        ModelInfo(
            id: id, family: "acestep", featured: false, format: nil,
            variantOf: nil, tags: nil, displayName: id, description: "",
            hfRepos: [], sizeBytes: 0,
            installState: installed ? .installed : .notInstalled,
            installedBytes: 0, pinned: false,
            capabilities: Capabilities(
                supportsLyrics: true, instrumentalOnly: false,
                duration: DurationSpec(minS: 1, maxS: 300, defaultS: 60),
                sampleRate: 48000, outputsPerJobMax: 1,
                estSecondsPerAudioSecond: 1, lyricsTags: nil, lyricsHint: nil,
                tasks: nil, estRealtimeFactor: nil, params: params),
            requirements: Requirements(minRamBytes: 1, diskBytes: 0,
                                       speedTier: .fast),
            license: LicenseInfo(name: "MIT", commercialUse: true,
                             requiresHfToken: false, url: nil),
            notes: nil)
    }

    private func taskTypeSpec(_ values: [String]) -> ParamSpec {
        ParamSpec(key: "task_type", type: .enum, label: "Task", help: nil,
                  default: .string("text2music"), nullable: false, min: nil,
                  max: nil, step: nil, placeholder: nil,
                  choices: values.map { EnumChoice(value: $0, label: $0) },
                  isInternal: nil, resolveUploads: nil)
    }

    /// Re-pointed from the old `GenerativeModels` at the Style Transfer
    /// consolidation. Kept alongside `StyleTransferModeTests` because these
    /// fixtures are built from the Swift initialisers rather than decoded from
    /// contract JSON — two different construction paths onto the same rule.
    func testGenerativeModelGating() {
        let turbo = model(id: "turbo", params: [
            taskTypeSpec(["text2music", "cover", "repaint"])])
        let base = model(id: "base", params: [
            taskTypeSpec(["text2music", "cover", "repaint", "extract",
                          "lego", "complete"])])
        let sao = model(id: "sao", params: [
            ParamSpec(key: "init_audio", type: .audio, label: "Init",
                      help: nil, default: .null, nullable: true, min: nil,
                      max: nil, step: nil, placeholder: nil, choices: nil,
                      isInternal: nil, resolveUploads: nil)])
        let uninstalled = model(id: "base-uninstalled", installed: false,
                                params: [taskTypeSpec(["extract"])])
        let all = [turbo, base, sao, uninstalled]

        XCTAssertEqual(StyleTransferMode.cover.eligible(all).map(\.id),
                       ["turbo", "base"])
        XCTAssertEqual(StyleTransferMode.extract.eligible(all).map(\.id),
                       ["base"], "turbo and uninstalled must be excluded")
        XCTAssertEqual(StyleTransferMode.shape.eligible(all).map(\.id), ["sao"])
        XCTAssertTrue(StyleTransferMode.layer.eligible(all)
            .allSatisfy { $0.id == "base" })
    }

    func testKnobSpecsHideProgrammaticKeys() {
        let base = model(id: "base", params: [
            taskTypeSpec(["extract"]),
            ParamSpec(key: "steps", type: .int, label: "Steps", help: nil,
                      default: .int(32), nullable: false, min: 4, max: 200,
                      step: nil, placeholder: nil, choices: nil,
                      isInternal: nil, resolveUploads: nil),
            ParamSpec(key: "src_audio", type: .audio, label: "Source",
                      help: nil, default: .null, nullable: true, min: nil,
                      max: nil, step: nil, placeholder: nil, choices: nil,
                      isInternal: nil, resolveUploads: nil),
        ])
        XCTAssertEqual(StyleTransferMode.knobSpecs(for: base).map(\.key),
                       ["steps"])
    }

    // MARK: region math

    func testRegionMathPixelSecondsRoundTrip() {
        let math = RegionMath(durationS: 120, width: 600)
        XCTAssertEqual(math.seconds(atX: 300), 60, accuracy: 0.001)
        XCTAssertEqual(math.x(atSeconds: 30), 150, accuracy: 0.001)
        XCTAssertEqual(math.seconds(atX: -20), 0)
        XCTAssertEqual(math.seconds(atX: 9999), 120)
        XCTAssertEqual(math.x(atSeconds: 999), 600)
    }

    func testRegionMathClamping() {
        let math = RegionMath(durationS: 60, width: 600)
        // swapped handles get reordered
        let swapped = math.clamped(start: 20, end: 10)
        XCTAssertEqual(swapped.start, 10)
        XCTAssertEqual(swapped.end, 20)
        // too-short selections expand to the minimum length
        let tiny = math.clamped(start: 30, end: 30.1)
        XCTAssertEqual(tiny.end - tiny.start, 0.5, accuracy: 0.001)
        // out-of-range input stays in range
        let wide = math.clamped(start: -5, end: 500)
        XCTAssertEqual(wide.start, 0)
        XCTAssertEqual(wide.end, 60)
    }

    // MARK: generativePart ingest routing

    func testGenerateOutputRoutesToPartsLibrary() throws {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        let jobs = JobsStore(repo: library, partsRepo: parts)
        try library.insert(SongRecord(
            id: "song1", title: "Source", prompt: "p", lyrics: nil,
            modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
            durationS: 10, sampleRate: 48000, fileName: "song1.wav",
            seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
            favorite: false))

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let take = outDir.appendingPathComponent("take-0.wav")
        try Data(repeating: 3, count: 256).write(to: take)

        let result = JobResult(
            outputs: [JobOutput(path: take.path, format: "wav",
                                sampleRate: 48000, durationS: 50,
                                seedUsed: 7)],
            artifacts: nil, meta: nil, timings: [:])
        let info = JobInfo(
            jobId: "job_g", groupId: "grp", modelId: "acestep-15-dit-base",
            task: nil, status: .succeeded, queuePosition: nil,
            prompt: "AI Vocals: Source", lyrics: nil, durationS: 50, count: 1,
            params: ["task_type": .string("extract"),
                     "src_audio": .string("/resolved/src.wav"),
                     "track": .string("vocals")],
            createdAt: "2026-08-17T00:00:00Z", progress: nil, result: result,
            error: nil)

        jobs.pendingContext["job_g"] = .generativePart(
            songId: "song1", sourceTitle: "Source", kind: "stem.vocals",
            name: "AI Vocals")
        var ingestedParts: [PartRecord] = []
        var ingestedSongs: [SongRecord] = []
        jobs.onPartsIngested = { ingestedParts = $0 }
        jobs.onSongsIngested = { ingestedSongs = $0 }
        jobs.ingestGenerate(job: info, result: result)

        XCTAssertTrue(ingestedSongs.isEmpty,
                      "generativePart output must not become a library song")
        XCTAssertEqual(ingestedParts.count, 1)
        let part = try XCTUnwrap(ingestedParts.first)
        createdFiles.append(part.fileURL)
        XCTAssertEqual(part.kind, "stem.vocals")
        XCTAssertEqual(part.songId, "song1")
        // Named like every other part — after its source song and its kind.
        // "AI Vocals" is the queue card's title, written for a job that is
        // running; the part it leaves behind is a part of Source.
        XCTAssertEqual(part.name, "vocals-source")
        XCTAssertEqual(part.modelId, "acestep-15-dit-base")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.fileURL.path))
        XCTAssertFalse(part.splitParamsJSON.contains("/resolved"),
                       "resolved paths are stripped from provenance")
        XCTAssertTrue(part.splitParamsJSON.contains("extract"))
    }

    func testRenderArtifactRoutesToPartsLibrary() throws {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        let jobs = JobsStore(repo: library, partsRepo: parts)
        try library.insert(SongRecord(
            id: "song2", title: "Notes Source", prompt: "", lyrics: nil,
            modelId: "imported", modelName: "Imported", groupId: nil,
            paramsJSON: "{}", durationS: 10, sampleRate: 44100,
            fileName: "song2.wav", seedUsed: nil, createdAt: Date(),
            rating: 0, notes: "", favorite: false, origin: "imported"))

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let rendered = outDir.appendingPathComponent("render.wav")
        try Data(repeating: 5, count: 256).write(to: rendered)

        let result = JobResult(
            outputs: nil,
            artifacts: [JobArtifact(kind: "audio", label: "render",
                                    path: rendered.path, format: "wav",
                                    sampleRate: 44100, durationS: 8)],
            meta: nil, timings: [:])
        let info = JobInfo(
            jobId: "job_r", groupId: "grp", modelId: "render-soundfont",
            task: "render", status: .succeeded, queuePosition: nil,
            prompt: "", lyrics: nil, durationS: nil, count: 1,
            params: ["midi_file": .string("/resolved/notes.mid")],
            createdAt: "2026-08-17T00:00:00Z", progress: nil, result: result,
            error: nil)

        jobs.pendingContext["job_r"] = .generativePart(
            songId: "song2", sourceTitle: "Notes Source",
            kind: "layer.piano", name: "Render: Piano")
        var ingested: [PartRecord] = []
        jobs.onPartsIngested = { ingested = $0 }
        jobs.ingestArtifacts(job: info, result: result)

        XCTAssertEqual(ingested.count, 1)
        let part = try XCTUnwrap(ingested.first)
        createdFiles.append(part.fileURL)
        XCTAssertEqual(part.kind, "layer.piano")
        XCTAssertEqual(part.format, "wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.fileURL.path))
    }

    // MARK: layer.* interchangeability with stems (catalog convention)

    func testStemSlotsAlsoAcceptLayers() {
        for recipe in RecipeCatalog.all {
            for slot in recipe.slots
            where slot.accepts.contains(KindPattern(pattern: "stem.*")) {
                XCTAssertTrue(
                    slot.accepts.contains(KindPattern(pattern: "layer.*")),
                    "\(recipe.id)/\(slot.id) accepts stem.* but not layer.*")
            }
        }
    }

    func testProvenRecipesAreLive() {
        // These ids are wire values: they travel as `recipeId` on a recombine
        // submission, are written into the provenance of every mix, and key the
        // `actions.lastRuns` blob. The 2026-09 consolidation cut ten of the
        // per-mode doors — every mode stays reachable from the workspace's own
        // switcher — so this list is the three group doors plus the renderer.
        for id in ["restyle", "add-layer", "repaint", "notes-instrument"] {
            let recipe = RecipeCatalog.recipe(id: id)
            XCTAssertNotNil(recipe, id)
            XCTAssertTrue(recipe?.isAvailable == true, "\(id) must be live")
        }
        // Retired ids resolve to nothing — and must never be reused for a
        // card that does something else, or old provenance would lie.
        for retired in ["rewrite-lyrics", "back-vocal", "complete-band",
                        "loop-reimagine", "ai-extract", "melody-start",
                        "continue-song", "keep-stems", "sound-like",
                        "morph-style", "continue"] {
            XCTAssertNil(RecipeCatalog.recipe(id: retired), retired)
        }
    }
}
