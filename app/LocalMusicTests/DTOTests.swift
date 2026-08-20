import XCTest
@testable import LocalMusic

final class DTOTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BackendClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    func testModelInfoFixture() throws {
        let json = """
        {
          "id": "acestep-base", "family": "acestep",
          "display_name": "ACE-Step 1.5", "description": "Full songs",
          "hf_repos": [{"repo_id": "ACE-Step/ACE-Step-v1.5", "gated": false}],
          "size_bytes": 7300000000,
          "install_state": "not_installed", "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": true, "instrumental_only": false,
            "duration": {"min_s": 10, "max_s": 240, "default_s": 60},
            "sample_rate": 44100, "outputs_per_job_max": 2,
            "est_seconds_per_audio_second": 0.6,
            "params": [
              {"key": "steps", "type": "int", "label": "Steps", "default": 60,
               "nullable": false, "min": 10, "max": 200},
              {"key": "seed", "type": "int", "label": "Seed", "default": null,
               "nullable": true},
              {"key": "variant", "type": "enum", "label": "Variant",
               "default": "turbo", "nullable": false,
               "choices": [{"value": "turbo", "label": "Turbo"}]},
              {"key": "style_tags", "type": "string", "label": "Style tags",
               "default": "", "nullable": false, "placeholder": "synthwave"}
            ]
          },
          "requirements": {"min_ram_bytes": 17179869184,
                            "disk_bytes": 7300000000, "speed_tier": "medium"},
          "license": {"name": "Apache-2.0", "commercial_use": true,
                       "requires_hf_token": false,
                       "url": "https://example.com"},
          "notes": "Vocals + lyrics."
        }
        """
        let model = try decode(ModelInfo.self, json)
        XCTAssertEqual(model.installState, .notInstalled)
        // tags are optional on the wire: an engine that predates them decodes
        XCTAssertEqual(model.modelTags, [])
        XCTAssertTrue(model.capabilities.supportsLyrics)
        XCTAssertEqual(model.capabilities.params.count, 4)
        XCTAssertEqual(model.capabilities.params[0].default, .int(60))
        XCTAssertEqual(model.capabilities.params[1].default, .null)
        XCTAssertTrue(model.capabilities.params[1].nullable)
        XCTAssertEqual(model.capabilities.params[2].choices?.first?.value, "turbo")
        XCTAssertEqual(model.requirements.speedTier, .medium)
    }

    func testModelInfoDecodesTags() throws {
        let json = """
        {
          "id": "separation-htdemucs", "family": "separation",
          "tags": ["Stem separation"],
          "display_name": "Demucs", "description": "Splits a song into stems",
          "hf_repos": [], "size_bytes": 84000000,
          "install_state": "installed", "installed_bytes": 84000000,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 0,
            "tasks": ["separate"], "params": []
          },
          "requirements": {"min_ram_bytes": 8589934592, "disk_bytes": 84000000,
                            "speed_tier": "fast"},
          "license": {"name": "MIT", "commercial_use": true,
                       "requires_hf_token": false, "url": null},
          "notes": null
        }
        """
        let model = try decode(ModelInfo.self, json)
        XCTAssertEqual(model.modelTags, ["Stem separation"])
        XCTAssertEqual(model.capabilities.supportedTasks, ["separate"])
    }

    func testJobInfoFixture() throws {
        let json = """
        {
          "job_id": "job_1", "group_id": "grp_1", "model_id": "musicgen-small",
          "status": "generating", "queue_position": 0,
          "prompt": "warm lo-fi", "lyrics": null, "duration_s": 20, "count": 1,
          "params": {"guidance_scale": 3.5, "seed": null},
          "created_at": "2026-08-16T20:00:00Z",
          "progress": {"stage": "generating", "fraction": 0.42,
                        "eta_s": 95, "message": "step 25/60"},
          "result": null, "error": null
        }
        """
        let job = try decode(JobInfo.self, json)
        XCTAssertEqual(job.status, .generating)
        XCTAssertFalse(job.status.isTerminal)
        XCTAssertEqual(job.progress?.fraction, 0.42)
        XCTAssertEqual(job.params["guidance_scale"], .double(3.5))
        XCTAssertEqual(job.params["seed"], .null)
        XCTAssertNil(job.preview, "an engine that predates previews decodes")
    }

    /// contract 5.6: the model's capability and the job's flag are different
    /// questions — a model that CAN preview was not necessarily asked to.
    func testPreviewCapabilityAndJobFlagAreSeparate() throws {
        let caps = try decode(Capabilities.self, #"""
        {"supports_lyrics": false, "instrumental_only": true,
         "duration": {"min_s": 1, "max_s": 11, "default_s": 5},
         "sample_rate": 44100, "outputs_per_job_max": 4,
         "est_seconds_per_audio_second": 0.8, "supports_preview": true,
         "params": []}
        """#)
        XCTAssertTrue(caps.canPreview)
        let job = try decode(JobInfo.self, #"""
        {"job_id": "job_1", "group_id": "grp_1", "model_id": "stableaudio-small",
         "task": "generate", "preview": false, "status": "generating",
         "queue_position": 0, "prompt": "p", "lyrics": null, "duration_s": 5,
         "count": 1, "params": {}, "created_at": "2026-08-16T20:00:00Z",
         "progress": null, "result": null, "error": null}
        """#)
        XCTAssertEqual(job.preview, false)
        // absent ⇒ no, so an older engine never makes the app offer controls
        // for something it cannot do
        let plain = try decode(Capabilities.self, #"""
        {"supports_lyrics": false, "instrumental_only": true,
         "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
         "sample_rate": 32000, "outputs_per_job_max": 4,
         "est_seconds_per_audio_second": 1.5, "params": []}
        """#)
        XCTAssertFalse(plain.canPreview)
    }

    func testJobResultFixture() throws {
        let json = """
        {
          "outputs": [{"path": "/tmp/x/take-0.wav", "format": "wav",
                        "sample_rate": 32000, "duration_s": 20.0,
                        "seed_used": 1234}],
          "timings": {"total_s": 31.2, "load_s": 8.1}
        }
        """
        let result = try decode(JobResult.self, json)
        XCTAssertEqual(result.outputs?.count, 1)
        XCTAssertEqual(result.outputs?[0].sampleRate, 32000)
        XCTAssertEqual(result.timings["total_s"], 31.2)
        XCTAssertNil(result.artifacts)
    }

    func testTaskJobInfoFixture() throws {
        let json = """
        {
          "job_id": "job_9", "group_id": "grp_9", "model_id": "separation-htdemucs",
          "task": "separate", "status": "succeeded", "queue_position": null,
          "prompt": "", "lyrics": null, "duration_s": null, "count": 1,
          "params": {"source_audio": "/abs/in.wav"},
          "created_at": "2026-08-17T00:00:00Z", "progress": null,
          "result": {
            "artifacts": [
              {"kind": "stem", "label": "vocals",
               "path": "/abs/Outputs/job_9/vocals.wav", "format": "wav",
               "sample_rate": 44100, "duration_s": 213.4},
              {"kind": "analysis", "label": "analysis",
               "path": "/abs/Outputs/job_9/analysis.json", "format": "json",
               "sample_rate": null, "duration_s": null}
            ],
            "meta": {"tempo_bpm": 127.5, "camelot": "11A"},
            "timings": {"total_s": 41.2}
          },
          "error": null
        }
        """
        let job = try decode(JobInfo.self, json)
        XCTAssertEqual(job.task, "separate")
        XCTAssertNil(job.durationS)
        XCTAssertNil(job.result?.outputs)
        XCTAssertEqual(job.result?.artifacts?.count, 2)
        XCTAssertEqual(job.result?.artifacts?[0].kind, "stem")
        XCTAssertEqual(job.result?.artifacts?[0].label, "vocals")
        XCTAssertEqual(job.result?.artifacts?[0].sampleRate, 44100)
        XCTAssertEqual(job.result?.artifacts?[1].format, "json")
        XCTAssertEqual(job.result?.meta?["tempo_bpm"], .double(127.5))
    }

    func testTaskCapabilitiesAndParamSpecs() throws {
        let json = """
        {
          "supports_lyrics": false, "instrumental_only": true,
          "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
          "sample_rate": 44100, "outputs_per_job_max": 1,
          "est_seconds_per_audio_second": 0,
          "tasks": ["separate"], "est_realtime_factor": 0.3,
          "params": [
            {"key": "source_audio", "type": "audio", "label": "Source",
             "default": null, "nullable": false},
            {"key": "notes_file", "type": "midi", "label": "Notes",
             "default": null, "nullable": true},
            {"key": "mix_spec", "type": "json", "label": "Mix",
             "default": null, "nullable": false, "internal": true,
             "resolve_uploads": true}
          ]
        }
        """
        let caps = try decode(Capabilities.self, json)
        XCTAssertEqual(caps.supportedTasks, ["separate"])
        XCTAssertEqual(caps.estRealtimeFactor, 0.3)
        XCTAssertEqual(caps.params[1].type, .midi)
        XCTAssertEqual(caps.params[2].type, .json)
        XCTAssertEqual(caps.params[2].isInternal, true)
        XCTAssertEqual(caps.params[2].resolveUploads, true)
        XCTAssertNil(caps.params[0].isInternal)

        // Generation models without tasks default to ["generate"].
        let plain = try decode(Capabilities.self, """
        {
          "supports_lyrics": false, "instrumental_only": true,
          "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
          "sample_rate": 32000, "outputs_per_job_max": 4,
          "est_seconds_per_audio_second": 1.5, "params": []
        }
        """)
        XCTAssertEqual(plain.supportedTasks, ["generate"])
    }

    func testErrorEnvelope() throws {
        let json = #"{"error": {"code": "INSUFFICIENT_RAM", "message": "nope"}}"#
        let env = try decode(APIErrorEnvelope.self, json)
        XCTAssertEqual(env.error.code, "INSUFFICIENT_RAM")
    }

    func testHandshake() throws {
        let json = #"{"port": 4242, "pid": 99, "version": "0.1.0", "contract": 1}"#
        let hs = try decode(Handshake.self, json)
        XCTAssertEqual(hs.port, 4242)
        XCTAssertEqual(hs.contract, 1)
    }

    func testEventParsing() throws {
        func parse(_ name: String, _ json: String) -> EngineEvent? {
            EngineEvent.parse(name: name, data: Data(json.utf8),
                              decoder: BackendClient.decoder)
        }
        if case .jobProgress(let id, let p)? = parse("job.progress",
            #"{"job_id": "job_1", "stage": "generating", "fraction": 0.5, "eta_s": 3, "message": "m"}"#) {
            XCTAssertEqual(id, "job_1")
            XCTAssertEqual(p.fraction, 0.5)
        } else { XCTFail("job.progress") }

        if case .downloadProgress(let d)? = parse("download.progress",
            #"{"download_id": "dl_1", "model_id": "m", "state": "downloading", "bytes_done": 5, "bytes_total": 10, "speed_bps": 1, "stage": "weights", "message": null}"#) {
            XCTAssertEqual(d.bytesDone, 5)
        } else { XCTFail("download.progress") }

        if case .jobPreview(let id, let p)? = parse("job.preview",
            #"{"job_id": "job_1", "take": 0, "path": "/tmp/x/preview-2.wav", "sample_rate": 44100, "duration_s": 11.0, "step": 6}"#) {
            XCTAssertEqual(id, "job_1")
            XCTAssertEqual(p.durationS, 11.0)
            XCTAssertEqual(p.step, 6)
            XCTAssertEqual(p.fileURL.lastPathComponent, "preview-2.wav")
        } else { XCTFail("job.preview") }

        if case .modelsChanged? = parse("models.changed", "{}") {} else {
            XCTFail("models.changed")
        }
        XCTAssertNil(parse("future.unknown", "{}"), "unknown events must be ignored")
    }

    /// contract 5.6: a preview from a phase that counts no steps carries no
    /// step number rather than a made-up one.
    func testJobPreviewWithoutAStepCount() throws {
        let preview = try decode(JobPreview.self, #"""
        {"take": 1, "path": "/tmp/x/preview-0.wav", "sample_rate": 32000,
         "duration_s": 2.5, "step": null}
        """#)
        XCTAssertNil(preview.step)
        XCTAssertEqual(preview.take, 1)
    }

    func testJobSubmissionEncoding() throws {
        let sub = JobSubmission(modelIds: ["a"], prompt: "p", lyrics: nil,
                                durationS: 5, count: 1,
                                params: ["seed": .int(7), "x": .null], force: false)
        let data = try BackendClient.encoder.encode(sub)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["model_ids"] as? [String], ["a"])
        XCTAssertEqual(obj["duration_s"] as? Double, 5)
        XCTAssertEqual(obj["task"] as? String, "generate",
                       "task is always encoded; engine defaults it anyway")
        XCTAssertEqual(obj["preview"] as? Bool, false,
                       "previews cost a decode per frame: never on by default")
        let params = obj["params"] as! [String: Any]
        XCTAssertEqual(params["seed"] as? Int, 7)
    }

    func testTaskSubmissionEncoding() throws {
        let sub = JobSubmission(modelIds: ["separation-htdemucs"],
                                task: "separate", prompt: "", lyrics: nil,
                                durationS: 0, count: 1,
                                params: ["source_audio": .string("up_1")],
                                force: false)
        let data = try BackendClient.encoder.encode(sub)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["task"] as? String, "separate")
        XCTAssertEqual((obj["params"] as! [String: Any])["source_audio"] as? String,
                       "up_1")
    }
}
