# LocalMusic engine API contract

Version: `1` (breaking changes bump this; the app checks `contract` in the handshake file).

This document is the single source of truth for the interface between the SwiftUI app
("app") and the Python inference sidecar ("engine"). `stub-backend/stub_server.py`
implements this contract exactly and is the fixture the app is developed against.

Conventions: all bodies are JSON; timestamps ISO-8601 UTC; sizes in bytes; durations in
seconds; ids are strings (`job_<uuid>`, `dl_<uuid>`, `grp_<uuid>`). Errors are non-2xx with

```json
{"error": {"code": "MODEL_NOT_INSTALLED", "message": "human-readable", "detail": {}}}
```

Error codes used in this document: `UNAUTHORIZED`, `NOT_FOUND`, `VALIDATION`,
`MODEL_NOT_INSTALLED`, `INSUFFICIENT_DISK`, `INSUFFICIENT_RAM`, `MODEL_IN_USE`,
`DOWNLOAD_ACTIVE`, `JOB_NOT_CANCELABLE`, `ENGINE_BUSY`, `OOM`, `WORKER_CRASHED`,
`UNSUPPORTED_MODEL`, `INTERNAL`.

Memory warning: workers report their Metal/accelerator memory every 2 s. When
usage crosses the warning level (default 90% of physical RAM;
`LOCALMUSIC_MEM_GUARD_BYTES` in the engine's environment overrides, `0`
disables), the engine emits `engine.warning` plus a `job.log` line for the
running job — it never stops the job (transient allocator spikes can cross the
level during legitimate generations). The warning re-arms after usage falls
below 85% of the level.

## 1. Process bootstrap

The app spawns:

```
<engine> --handshake-file <path> --parent-pid <pid> --data-dir <dir> --output-dir <dir> [--log-level info]
```

Environment: `LOCALMUSIC_AUTH_TOKEN=<random hex>` — generated fresh by the app each
launch; never written to disk by either side.

Engine behavior:

- Binds `127.0.0.1` on an ephemeral port (`:0`). Never any other interface.
- When the HTTP server is accepting connections, atomically writes (write temp +
  `rename`) the handshake file:

  ```json
  {"port": 49321, "pid": 4242, "version": "0.1.0", "contract": 1}
  ```

- All logging goes to **stderr** (the app captures it to a rotated log file). stdout is
  unused and may not be parsed.
- Watchdog: the engine polls `--parent-pid` (2 s); if the parent dies, it SIGKILLs its
  workers and exits. Workers likewise watch the supervisor PID.
- `SIGTERM`: cancel the active job, flush, exit 0 within 10 s. Worker subprocesses run
  in the engine's process group and must die with it.
- `POST /v1/shutdown` → `202`, then graceful exit (preferred path; SIGTERM is the
  app's fallback, SIGKILL the last resort).

App behavior: poll for the handshake file (60 s cap), then poll `GET /healthz` until 200
(10 s cap), then connect `GET /v1/events`.

## 2. Auth

Every request except `GET /healthz` requires `Authorization: Bearer <token>`. Wrong or
missing token → `401 UNAUTHORIZED`. (SSE: the app passes the header on the stream
request; `EventSource` polyfills that can't set headers are not a constraint here.)

## 3. Health & system

- `GET /healthz` (no auth) → `200 {"status":"ok","version":"0.1.0","uptime_s":123}`
- `GET /v1/system` →

  ```json
  {
    "ram_bytes": 68719476736,
    "free_disk_bytes": 512000000000,
    "machine": "Mac16,10",
    "warm_family": "musicgen",
    "warm_model_id": "musicgen-small",
    "transient_model_ids": [],
    "pinned_model_id": null,
    "active_job_id": null,
    "queue_held": false,
    "memory_guard": {"limit_bytes": 61847529062, "worker_bytes": 3221225472},
    "accelerator": {"name": "Apple M1 Max",
                    "backend": "metal",
                    "working_set_bytes": 55662788608},
    "usage": {"gpu_percent": 92,
              "worker_bytes": 11800000000,
              "accelerator_bytes": 9400000000},
    "engine_versions": {"python": "3.11.9", "supervisor": "0.1.0"}
  }
  ```

  `memory_guard.worker_bytes` is the live worker's accelerator memory (null when
  no worker is running); `limit_bytes` is the warning level described above.
  `queue_held` is the job-queue hold of §5.7 — note that it can be `true` while
  `active_job_id` is still set, because a hold stops the queue starting work and
  never interrupts work already running.

  **`accelerator` and `usage` are optional objects, and every field inside them
  is independently nullable.** The app hides a readout it has no number for
  rather than drawing a zero, so an engine must send null — never 0 — for
  anything it cannot measure.

  - `accelerator.name` — the accelerator's marketing name, e.g. `"Apple M1
    Max"`. On Apple Silicon that is the SoC, which is why it reads like a CPU
    name.
  - `accelerator.backend` — `"mlx" | "metal" | "cpu"`, the framework the live
    worker turned out to be using. Null while no worker is alive: the engine
    does not know what the next model will pick, and guessing "Metal" would be
    wrong for the MLX models. A worker running both frameworks reports
    `"metal"`, which is true of both (MLX is itself a Metal backend) and merely
    less specific.
  - `accelerator.working_set_bytes` — Metal's recommended working set, which is
    the real ceiling a model can reach and is always well below `ram_bytes`.
    Only a worker can read it, so it is null until one has run; after that it
    stays reported, because it describes the Mac rather than the process.
  - `usage.gpu_percent` — **device-wide GPU utilisation, 0–100, not this job's
    share.** macOS exposes no per-process figure without root, so the app
    labels it "GPU" and never "this render". Null when the driver publishes no
    counter.
  - `usage.worker_bytes` — physical footprint of the live worker process **and
    every process it has spawned** (what Activity Monitor calls "Memory"). The
    descendants matter: adapters that drive a native runtime (acestep.cpp, YuE,
    whisper.cpp) hold the whole model in a child process, and counting the
    worker alone reported ~0 for them throughout a render. Null when no worker
    is running.
  - `usage.accelerator_bytes` — of that, what the worker holds on the
    accelerator. Null until the worker has reported a reading.

  Both `usage` figures describe whichever worker is doing the work — the
  transient slot's while a small model runs (4.3), the resident one otherwise.
  `memory_guard.worker_bytes` is always the resident slot's, so the two can
  legitimately differ.

- `POST /v1/shutdown` → `202 {}`

## 4. Models

### 4.1 `GET /v1/models` → `{"models": [ModelInfo]}`

```json
ModelInfo = {
  "id": "musicgen-small",
  "family": "musicgen",              // selects adapter + venv
  "featured": true,                  // optional; default false. The curated set the
                                      // Models screen shows before "Show all" — one
                                      // entry per thing the app can do, so every task
                                      // below (generate / analyze / separate /
                                      // transcribe / mix / render / assist) has at
                                      // least one. `plan` needs none of its own — it
                                      // rides the featured generate models that
                                      // declare it.
                                      // A task with no featured model is a feature the
                                      // user cannot discover: the auxiliary models are
                                      // ~200 MB in total and most of Split & Recombine
                                      // is inert without them.
                                      // MUST be set on a BASE entry (variant_of null).
                                      // The app groups variants under their base and
                                      // decides placement from the base's flag alone,
                                      // so featuring a variant does nothing at all.
  "format": "transformers",          // optional; weight/runtime format, e.g.
                                      // transformers | mlx | stable-audio-tools |
                                      // diffusers | acestep. Shown when variants exist.
  "variant_of": null,                // optional; id of the base model this repackages —
                                      // the UI groups variants under their base
  "tags": ["Instrumental & loops"],  // optional; what the model is FOR, in app terms —
                                      // human-readable strings the app renders verbatim
                                      // and offers as filter buttons on the Models
                                      // screen. Open vocabulary: the app never
                                      // hardcodes or maps them, so new tags need no app
                                      // change. Current set: "Songs with vocals",
                                      // "Instrumental & loops", "Melody-guided",
                                      // "Remix & restyle", "Stem separation",
                                      // "Notes & MIDI", "Musical analysis",
                                      // "Mixing & recombining", "Writing help",
                                      // "Hears & describes", "Voice & singing".
                                      // `plan` deliberately adds no tag: planning
                                      // is a step of a generate on a model
                                      // installed for generating, never a reason
                                      // to install one. Distinct from
                                      // size/speed_tier/family/format, which describe
                                      // what a model *is* rather than what it's for.
  "display_name": "MusicGen Small",
  "description": "Fast instrumental clips (Meta)",
  "hf_repos": [{"repo_id": "facebook/musicgen-small", "gated": false}],
                                      // each repo may carry "allow_patterns":
                                      // [glob, ...] — download (and require on
                                      // disk) only matching files. Used for
                                      // multi-quant GGUF stacks and shared
                                      // helper repos (t5-base); every pattern
                                      // must match ≥1 file or the entry stays
                                      // uninstalled.
  "ms_repos": [{"repo_id": "iic/InspireMusic-1.5B-Long"}],
                                      // optional; ModelScope-hosted weights,
                                      // fetched anonymously over HTTPS by the
                                      // engine's own worker into its ms-cache.
                                      // Same download/install/delete lifecycle
                                      // as hf_repos (shared-repo refcounting
                                      // included); may carry "allow_patterns"
                                      // with the same semantics. As of
                                      // 2026-08-25 no shipped entry uses it —
                                      // the formerly ModelScope-only weights
                                      // (InspireMusic, SongBloom, the
                                      // ACE-Step XL LoRA pack) are mirrored
                                      // on the user-owned HF account (see
                                      // models-uploaded-to-my-HF.md) — but
                                      // the route stays supported for future
                                      // ModelScope-only releases. size_bytes
                                      // includes these files.
  "size_bytes": 2420000000,
  "install_state": "not_installed" | "downloading" | "partial" | "installed",
                                      // "partial" means a download of THIS model was
                                      // started and interrupted (cancelled or failed) —
                                      // the app offers "Resume download". It is never
                                      // inferred from bytes on disk: entries share
                                      // repos and even individual files (the GGUF
                                      // stack's common quants), so a model the user
                                      // never touched can already have most of its
                                      // content present and must still read
                                      // "not_installed". A download that failed
                                      // `UNAUTHORIZED` is the one failure that does
                                      // NOT leave "partial": no weights were fetched
                                      // and a retry without access fails the same
                                      // way, so the entry returns to "not_installed"
                                      // rather than offering a resume that cannot
                                      // succeed.
  "installed_bytes": 0,
  "runtime_state": "not_installed" | "installing" | "installed",
                                      // the model's FAMILY runtime — the adapter's
                                      // package environment (torch and friends).
                                      // `install_state` is about weights alone, and
                                      // the two are separate installs: a model can
                                      // have every byte of its weights and still stop
                                      // for four minutes on its first generation to
                                      // build the runtime. Reported per model because
                                      // that is what a user downloads and deletes,
                                      // but it is a property of `family`: two entries
                                      // of one family are ready or not together, and
                                      // the second costs nothing once the first has
                                      // paid. "installing" means a runtime install or
                                      // the provisioning step of any download of the
                                      // same family is running now. Read `installed`
                                      // where absent, so an engine that predates the
                                      // field is not taken to be missing every runtime.
  "pinned": false,                   // kept loaded while idle; see 4.3

  "capabilities": Capabilities,
  "requirements": {"min_ram_bytes": 8589934592, "disk_bytes": 2420000000,
                    "speed_tier": "fast" | "medium" | "slow" | "experimental"},
  "license": {"name": "CC-BY-NC-4.0", "commercial_use": false,
               "requires_hf_token": false, "url": "https://..."},
  "notes": "Instrumental only, clips up to 30 s."
}

Capabilities = {
  "supports_lyrics": false,
  // optional; the model REFUSES a job with no lyrics (SongBloom sings a
  // structured lyric sheet and has nothing to do without one). Distinct
  // from supports_lyrics, which the instrumental-capable singers also set.
  // Absent ⇒ lyrics are optional. A client must gate on this rather than
  // let the adapter load gigabytes and then say no.
  "requires_lyrics": true,
  "instrumental_only": true,
  "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
  "sample_rate": 32000,
  "outputs_per_job_max": 4,
  "est_seconds_per_audio_second": 1.5,
  // optional; job tasks this model accepts (see 5.4). Absent ⇒ ["generate"].
  // Task-only entries still carry the generation-shaped fields above with
  // dummy values; consumers ignore them for non-generate tasks.
  "tasks": ["separate"],
  // optional, task models only: rough processing-time / input-duration ratio,
  // used app-side for pre-submit estimates (ETA on the wire is elapsed-based)
  "est_realtime_factor": 0.3,
  // optional; can this model publish partial audio while it renders (see 5.6)?
  // Absent ⇒ false. Declared per MODEL, not per family: only some adapters can
  // decode audio the model has genuinely produced part-way through, and the MLX
  // and transformers builds of MusicGen differ on it.
  "supports_preview": true,
  // optional, lyric models only — drives the app's structured lyrics editor:
  "lyrics_tags": ["[verse]", "[chorus]", "[bridge]"],  // insertable section tags
  "lyrics_hint": "Section tags on their own lines structure the song.",
  // optional; the stages this model's adapter reports, in the order it reports
  // them (see 5.5). Declared up front so the app can draw the whole pipeline —
  // later stages greyed — before the job reaches them, which a progress event
  // alone could never do. Absent ⇒ the app draws one bar.
  "pipeline": [PipelineStage],
  "params": [ParamSpec]
}

PipelineStage = {
  "id": "diffusion",                  // matches progress.phase (5.5)
  "label": "Diffusion",               // display text; the app renders it verbatim
  "optional": true                    // optional; the stage may be skipped for a
                                       // given job (ACE-Step's LM half is skipped
                                       // by every src-audio task). Drawn dimmed,
                                       // and dropped if the job never reports it.
}

ParamSpec = {
  "key": "guidance_scale",
  "type": "int" | "float" | "bool" | "string" | "enum" | "audio" | "midi" | "json",
  "label": "Guidance",
  "help": "optional short explanation",
  "default": 3.0,                     // JSON value matching type; null iff nullable
  "nullable": false,                  // nullable:true → UI offers an "unset" state
  // numeric only:
  "min": 1.0, "max": 15.0, "step": 0.5,
  // string only:
  "placeholder": "synthwave, 120bpm",
  // enum only:
  "choices": [{"value": "turbo", "label": "Turbo"}],
  // any type, optional:
  "internal": true,                   // the generic form does not render this param;
                                       // clients populate it programmatically
  // json only, optional:
  "resolve_uploads": true,            // engine walks the parsed JSON and replaces
                                       // every "up_…" string value with the resolved
                                       // absolute path (unknown id → 422 VALIDATION)
  // all types, all optional — see "Grouping" below:
  "group": "sampling",                // which named section of the form this belongs in
  "group_label": "Sampling",          // display text for that section
  "applies_when": {"param": "task_type", "values": ["cover", "repaint"]}
}
```

The `params` list fully drives the app's generic parameter form; the app has zero
hardcoded per-model knowledge. `duration_s`, `prompt`, `lyrics`, and `count` are
top-level job fields, never ParamSpecs.

**Grouping.** `group` is a free-form id; the app renders one section per distinct
id, in the order the ids first appear in `params`, so a model controls its own
form layout by the order it lists them. `group_label` names the section and only
needs sending for an id the app does not already know — it recognises
`sampling` ("Sampling"), `musical` ("Musical"), `task` ("Task & source") and
`other` ("Other"), and otherwise title-cases the id. A model may leave `group`
off entirely (every task-only entry does) and the app classifies by key name
instead; a model may also declare it on some params and not others. Grouping is
presentation, never validation: an unknown group is rendered, not rejected.

`applies_when` says **this control only means anything while `param` holds one
of `values`** — ACE-Step's `thinking` is inert on any task with a source,
because the pipeline skips the LM half there. The app dims such a control and
says why rather than hiding it, so declare it only where the adapter really does
ignore the value; a param the engine honours in every mode must not carry one.
`param` names another ParamSpec of the same model and the comparison is against
its current string value, so only `enum` and `string` params can gate.
Conditions that a string cannot express — Stable Audio 3 picking its mode from
*which* audio input you attached — are left undeclared rather than approximated.

> This rule has been broken once, expensively. `audio_cover_strength` declared
> `applies_when: ["cover"]`, but upstream keys the blend on the value alone
> (`if audio_cover_strength < 1.0`) in both the conditioning builder and every
> DiT's step loop, where `cover_steps = int(num_steps * strength)` switches
> conditioning part-way through. The param is non-nullable with a 0.7 default,
> and the app rendered it as an ordinary knob seeded from that default — so
> every repaint, extract, layer and complete job silently asked for a 70 %
> source blend, while the control that caused it was drawn dimmed with "only
> applies to Cover" underneath. A false `applies_when` is worse than none: it
> tells the user a control is inert *and* the app keeps sending it.

`"audio"` and `"midi"` params (e.g. MusicGen Melody's `melody_audio`,
MusicGen-Style's `style_audio`, a render job's note file) carry an **upload id**
as their value: the app first
`POST /v1/uploads?filename=<name>` with the raw file bytes as the request body
(audio: any format soundfile reads; ≤ 256 MB) →
`201 {"upload_id": "up_...", "bytes": N, "filename": "..."}`, then submits the
job with `"params": {"melody_audio": "up_..."}`. An unknown upload id fails the
submit with `422 VALIDATION`. Uploads are transient: the engine purges them at
startup, so ids never outlive the engine process. `"json"` params carry a
JSON-encoded **string** (the params dict itself stays flat scalars on the wire).

- `GET /v1/models/{id}` → `ModelInfo` (404 `NOT_FOUND`)
- `DELETE /v1/models/{id}` → `202 {}`. Refused with `409 MODEL_IN_USE` if a queued or
  running job references it; `409 DOWNLOAD_ACTIVE` while downloading (cancel first).
  **Deletes the family runtime too** once no downloaded model of that family is
  left. The runtime is the larger half of some families — ACE-Step's is 1.4 GB of
  PyTorch — so leaving it behind would keep most of the space the delete was for.
  It is kept, and collected by the next delete, when a job or a download of that
  family is outstanding: a venv removed under a live worker — or under the `uv`
  that is building it — is a crash rather than a saving. Any worker sitting idle
  on the family is stopped first, for the same reason.
- `POST /v1/models/inspect {"repo_id": "org/name"}` → synthesized `ModelInfo` for a
  supported arbitrary model (dry run, nothing persisted), or `422 UNSUPPORTED_MODEL`
  with `message` explaining why (requires `trust_remote_code`, unknown architecture…).
  Supported: MusicGen-architecture repos; diffusers audio pipelines (StableAudio,
  AudioLDM/2, MusicLDM). Only config files are fetched, never weights or code.
- `POST /v1/models/custom {"repo_id": "org/name"}` → `201 ModelInfo` — same
  classification, persisted to the user-model overlay and included in `/v1/models`
  from then on (emits `models.changed`). Deleting a user model also removes the
  overlay entry. The stub returns a canned 422 for both.
- `POST /v1/settings/hf-token {"token": "hf_..."}` → `204`. Held in memory only
  (app owns persistence in the Keychain and re-sends each launch).

### 4.2 Downloads

- `POST /v1/models/{id}/download` → `202 {"download_id": "dl_..."}`
  - Idempotent: re-POST while active/paused returns the same id.
  - `409 INSUFFICIENT_DISK` when free disk < 1.2 × `disk_bytes`.
  - First install of a family also provisions its venv; provisioning progress arrives on
    the same download events with `stage: "provisioning"`. It runs **before** the
    weights, so a family whose runtime cannot be built fails in seconds instead of
    after tens of gigabytes. A family already provisioned is skipped, so this is
    once per family, not once per model. This is what makes a completed download
    mean *ready to render*: the alternative — building the runtime lazily at job
    time — put a silent four-minute install in the middle of the user's first
    generation.
- `POST /v1/models/{id}/runtime` → `202 {"download_id": "dl_..."}`
  - Installs the model's **family runtime alone**, fetching no weights. The repair
    path for a model whose `runtime_state` is `not_installed` while its
    `install_state` is `installed`: one downloaded before the runtime step existed,
    one whose venv was removed with a sibling, or one whose adapter has been updated
    since.
  - Reported on the same download events as everything else, with
    `stage: "provisioning"` and `runtime_only: true`; it takes a slot in the same
    one-at-a-time queue, because it is the same kind of heavy work.
  - Idempotent per **family**: asking for a runtime already being installed — by
    another model of that family, or by the provisioning step of a weights
    download — returns that install's id rather than queueing a second one.
  - Never touches the model's install state: an interrupted runtime install leaves
    `install_state` exactly as it was, and never reports `partial`.
  - `409 NO_RUNTIME` when the family ships no adapter project to install.
- `GET /v1/downloads` → `{"downloads": [DownloadInfo]}` — everything outstanding:
  transferring, provisioning, waiting its turn, or paused (reconciliation after
  app relaunch).

  ```json
  DownloadInfo = {
    "download_id": "dl_...", "model_id": "musicgen-small",
    "state": "queued" | "downloading" | "paused" | "provisioning",
    "bytes_done": 123, "bytes_total": 2420000000, "speed_bps": 52428800,
    "stage": "weights" | "provisioning", "message": "fetching model.safetensors",
    "runtime_only": false            // optional; true ⇒ a runtime install with no
                                      // weights behind it, so it finishes when the
                                      // provisioning does and has no bytes to draw.
                                      // Absent ⇒ false.
  }
  ```

  While `state` is `provisioning` the byte counts describe the weights transfer that
  has not started yet, and `speed_bps` is 0 — the package installer reports no
  progress of its own, so there is nothing to count and none is invented. Draw a
  spinner and `message`, not a bar; the event that first says `provisioning`
  already carries a message, so that spinner is never captionless. `speed_bps` is a raw sample over the last
  ~1 s and is spiky by nature; smoothing and any ETA belong to the client.

  **Downloads transfer one at a time.** Queueing five models starts one and
  leaves four in `state: "queued"` until their turn. They share a link, and —
  the reason this is enforced rather than advised — progress is *measured* from
  the size of a xet staging directory they all write into, so two at once made
  both reported rates wrong. A queued download reports `bytes_done` (whatever is
  already cached, so a resumed one shows its real starting point), `speed_bps: 0`
  and `state: "queued"`; it never claims to be transferring at 0 B/s. Its
  `stage` reads `weights` provisionally — whether it needs to provision at all
  is decided when it starts, since the download ahead of it may have built the
  same family's runtime in the meantime. The concurrency limit is overridable
  with `LOCALMUSIC_MAX_ACTIVE_DOWNLOADS` in the engine's environment.

  A queued download emits `download.progress` **when it is accepted**, not when
  it starts transferring: a client watching the stream has to be able to see
  that the thing it asked for exists and is waiting, and the event that
  announces a dispatch says nothing about the four behind it.

- `POST /v1/downloads/{id}/pause` → `202` · `POST /v1/downloads/{id}/resume` → `202`
  — these stop and restart the weights transfer. Both are accepted while
  `state` is `provisioning` or `queued` and do nothing: the installer is not
  resumable, a download that has not started has no transfer to suspend, and
  reporting `paused` over either would be a lie. **A paused download keeps its
  slot** — the next queued one does not start while it is paused. That is what
  makes "pause everything" hold, and releasing the slot would leave two
  half-fetched repos and put the shared byte counter back where it was.
- `DELETE /v1/downloads/{id}` → `202` — cancel, at any point including while
  queued or provisioning; partial files are kept (HF etag resume makes retry
  cheap). Cancelling a queued download frees no slot, because it held none.

### 4.3 Resident model lifecycle

Running any job loads its model (displacing a different resident model) and
**keeps it resident after the job**, so follow-up generations skip the cold
load. The resident model is freed only by: a job for another family, an
explicit unload, or engine shutdown. Load/unload transitions emit
`worker.state` events (they drive the app's titlebar), and `/v1/system` reports
`warm_model_id`.

**Small models are exempt.** A model at or below `1.5 GB` (`size_bytes`) runs in
a separate *transient* slot: it never displaces the resident model, and is
never kept resident in the sense a big model is. This is what stops an 81 MB
analyzer, auto-submitted after every generation, from evicting a multi-GB
generator that costs minutes to reload.

Small models run in a **warm pool** rather than being killed the moment the
queue empties: their adapters cache loaded checkpoints across jobs, and the
app keeps returning to them (an analyze follows every ingest; every workbench
mix produces a song that is then analyzed). At most `2` stay warm, each dropped
after `600 s` idle, least-recently-used first when the pool is full. A worker
running a job is never evicted.

- The rule is size-based, not family-based: `codec-tokensplice` (76 MB) shares
  family `mlxaudio` with MiniMax (up to 28.5 GB).
- Auxiliary models (any whose `capabilities.tasks` omits `generate`) may report
  `size_bytes: 0` legitimately — pure DSP, or weights bundled with their
  package. A *generation* model reporting `0` is treated as unknown, hence not
  small.
- Transient loads emit **no** `worker.state`, so the titlebar keeps showing the
  resident model throughout. `/v1/system.transient_model_ids` lists what the
  pool currently holds (empty when it is).
- Resident and pooled workers can be loaded at once by design; the warn-only
  memory guard still applies per worker. Env overrides on the engine:
  `LOCALMUSIC_SMALL_MODEL_BYTES` (`0` disables the policy, restoring
  single-slot behaviour), `LOCALMUSIC_SMALL_WARM_SLOTS` and
  `LOCALMUSIC_SMALL_WARM_TTL_S` (either `0` drops small workers as soon as they
  go idle).

`POST /v1/worker/unload` → `202 {}` — free the resident model now. Refusal:
`409 ENGINE_BUSY` while a job is queued or running. Unloading a pinned model
also clears its pin.

`PUT /v1/models/{id}/pin {"enabled": true|false}` → `202 {}`

Pinning strengthens residency: the engine (re)loads the pinned model whenever
the queue is idle — including preloading it before any job, and reloading it
after another family's job displaced it. Unpinning only removes that guarantee;
the model stays resident until unloaded or displaced. Refusals: `404 NOT_FOUND`,
`409 MODEL_NOT_INSTALLED` (enable only). Pin state is not persisted across
engine restarts. A failed pin load emits `engine.warning` and clears the pin.

### 4.4 The model library

Weights live in a Hugging Face cache directory — `HF_HOME`, defaulting to
`~/.cache/huggingface`. That folder is **shared**: other Hugging Face tooling on
the machine reads and writes the same cache, and repositories the app never
asked for are the normal case. Every figure and every action in this section is
therefore scoped through the catalog. A repository is *ours* when some entry in
`GET /v1/models` names it in `hf_repos`; nothing else in the folder is measured,
moved or removed, and an engine implementing this contract must hold that line.

Two states of ours, distinguished because they mean different things to a user:
**installed** (some entry referencing it has completed its download) and
**partial** (bytes from an interrupted download, with no finished model to show
for them). Both are counted, moved and cleared.

Sizes are deduplicated by inode. A cached repo is `blobs/` plus a `snapshots/`
tree of symlinks into it, and catalog entries can share a repo — so a naive sum
of file sizes reports a library substantially larger than the disk holds.

`GET /v1/models/library` →

```jsonc
{
  "path": "/Users/x/.cache/huggingface",
  "is_default": true,           // the shared ~/.cache/huggingface
  "bytes": 33285996544,         // ours: installed + partial
  "installed_bytes": 32000000000,
  "partial_bytes": 1285996544,
  "folder_bytes": 41000000000,  // the whole folder, ours and everyone else's
  "model_count": 6,
  "partial_count": 1,
  "disk_total_bytes": 994662584320,
  "disk_free_bytes": 164622213120,
  "repos": [{"repo_id": "facebook/musicgen-small", "path": "…",
             "bytes": 2371000000, "state": "installed" | "partial",
             "model_ids": ["musicgen-small"]}],
  "operation": LibraryOperation | null   // see below
}
```

`folder_bytes` is reported beside `bytes` deliberately: in the shared default
the two differ by whatever else is cached there, and a client showing only the
app's own figure disagrees with the Finder for reasons the user cannot see.

`GET /v1/models/library/verify` → a check of every completed download against
the files actually present. An install marker is a claim about history; weights
can vanish underneath it (a folder tidied by hand), and the symptom is
otherwise a job failing inside a worker rather than a Download button.

```jsonc
{"checked_at": "…", "problem_count": 1, "partial_repos": [Repo],
 "models": [{"model_id": "…", "display_name": "…",
             "state": "ok" | "missing" | "incomplete" | "shrunk",
             "expected_bytes": 0, "actual_bytes": 0}]}
```

Two long-running operations, at most one at a time. Both return
`202 {"operation_id": "lib_…"}` and report through `library.progress` followed
by exactly one `library.completed` or `library.failed` (§6). Both refuse with
`409 DOWNLOAD_ACTIVE` while any download is running and `409 ENGINE_BUSY` while
any job is queued or running — rearranging weights under a live worker is a
crash.

`POST /v1/models/library/clear {"scope": "all" | "partial"}` → remove models of
ours from the current folder; `partial` takes only the interrupted downloads,
which is a different decision from throwing away working models. Family
runtimes go with the last model that needed them, exactly as a single delete
does (§4.2). `409 LIBRARY_EMPTY` when the chosen scope matches nothing,
`422 VALIDATION` for an unknown scope.

`POST /v1/models/library/relocate {"path": "…", "disposition": "…"}` — point the
library at a new folder. `disposition` says what becomes of the models in the
old one:

| disposition | effect |
|---|---|
| `move`   | moved to the new folder. A rename on the same volume, a copy across volumes — `409 INSUFFICIENT_DISK` if the copy would not fit. Symlink structure is preserved; dereferencing it would double the library's size on arrival. |
| `delete` | removed from the old folder; the new one starts empty |
| `leave`  | untouched; the new folder starts empty and those bytes are orphaned |

Refusals: `422 VALIDATION` for an unknown disposition, an unwritable
destination, the current folder, or a destination inside the current folder.

**The engine reads `HF_HOME` once, at launch.** This endpoint only rearranges
files; the client applies the new path and restarts the engine afterwards.
Every event for a relocate carries `restart_required: true` — including a
failed one, which needs the restart *more*, since some repositories are already
at the destination. Until the restart, models in the new folder read as not
installed.

`POST /v1/models/library/cancel` → `202 {}` — stop after the file in flight.
Not a rollback: a cancelled move leaves whole repositories on one side or the
other, never half of one, and the terminal event names which went.

## 5. Jobs

### 5.1 Submit

`POST /v1/jobs`

```json
{
  "model_ids": ["musicgen-small"],    // exactly one entry; N>1 → 422 VALIDATION
                                       // (multi-model fan-out was removed — submit one
                                       // job per model instead; array kept for wire
                                       // stability)
  "task": "generate",                 // optional; defaults to "generate". See 5.4 for
                                       // the other tasks and their relaxed field rules.
  "prompt": "dreamy synthwave with saxophone",
  "lyrics": null,                     // 422 VALIDATION if the model lacks supports_lyrics
  "duration_s": 20,                   // clamped to the model's capabilities.duration
  "count": 1,                         // takes per job, ≤ outputs_per_job_max
  "params": {"guidance_scale": 3.0, "seed": null},   // validated against the model's
                                       // ParamSpecs; unknown keys dropped with a job.log note
  "force": false,                     // override INSUFFICIENT_RAM refusal
  "preview": false                    // optional; publish partial audio while
                                       // rendering (5.6). Default false — each
                                       // frame costs a real decode. `true` on a
                                       // model whose capabilities.supports_preview
                                       // is false → 422 VALIDATION, never a
                                       // silent no-op.
}
```

→ `202 {"group_id": "grp_...", "jobs": [{"job_id": "job_...", "model_id": "..."}]}`
(one job; `group_id` remains the stable grouping key in responses and events)

Refusals: `409 MODEL_NOT_INSTALLED`, `409 INSUFFICIENT_RAM` (unless `force`),
`422 VALIDATION`.

Jobs run **strictly serially** (one at a time, engine-enforced). The scheduler may
reorder equal-priority queued jobs to run same-family jobs consecutively (warm worker);
`queue_position` events reflect any reordering. What "equal priority" means, and how a
client overrides that reordering, is §5.8.

### 5.2 Read

- `GET /v1/jobs?status=queued|running|succeeded|failed|canceled&group_id=grp_...` →
  `{"jobs": [JobInfo]}` (both filters optional; default returns non-terminal jobs)
- `GET /v1/jobs/{id}` → `JobInfo`

```json
JobInfo = {
  "job_id": "job_...", "group_id": "grp_...", "model_id": "musicgen-small",
  "task": "generate",                 // echo of the submitted task
  "preview": false,                   // echo of the submitted preview flag —
                                       // whether THIS job publishes partial
                                       // audio, which is not the same question
                                       // as whether its model could
  "status": "queued" | "loading" | "generating" | "encoding" |
             "succeeded" | "failed" | "canceled",
  "priority": 0,                      // explicit run order; 0 = no opinion (5.8)
  "queue_position": 0,                // 0 = running/next; null once terminal
  "prompt": "...", "lyrics": null, "duration_s": 20, "count": 1, "params": {},
  "created_at": "2026-08-16T20:00:00Z",
  // null until started; `fraction` may be null (indeterminate) and
  // take/phase/step/steps are optional staged detail — see 5.5
  "progress": {"stage": "generating", "fraction": 0.42, "eta_s": 95,
                "message": "step 25/60", "take": 1,
                "phase": "diffusion", "step": 25, "steps": 60},
  "result": {                                        // null unless succeeded
    "outputs": [{"path": "/abs/.../Outputs/job_x/take-0.wav", "format": "wav",
                  "sample_rate": 32000, "duration_s": 20.0, "seed_used": 1234}],
    "timings": {"total_s": 31.2, "load_s": 8.1, "generate_s": 21.4}
  },
  "error": null                                      // {"code","message"} when failed
}
```

A generate `result` may additionally carry `meta`, and each entry of `outputs`
may carry a `meta` of its own — the job-level object is the takes' merged.
This mirrors the task result's optional `meta` (5.4), and the same rule
applies: both are additive and **absent entirely unless the adapter supplied
something**, so most families never send them and a client must not require
them. Today only ACE-Step does:

```json
"meta": {"lm_metadata": {"bpm": 104, "caption": "…", "duration": 60,
                         "genres": "…", "keyscale": "A minor",
                         "language": "english", "timesignature": "4/4"},
         "audio_codes": "<|audio_code_1|>…", "planner": "acestep-5hz-lm"}
```

— the plan its 5 Hz LM wrote before the render, with the same `metadata` keys
(any subset) a `plan` job returns (5.4). Omitted for src-audio tasks, which
skip the LM.

Output files are written complete (`.part` + rename) under `--output-dir/<job_id>/`
**before** `job.completed` fires. The app moves them into its library (same volume →
atomic rename). As each take of a `count > 1` generate job finishes, the engine
also emits **`job.take_done`** — `{"job_id", "take", "output"}`, where `output`
is the same object that will appear at that index in the completed job's
`outputs` — so a client can land finished takes while later ones still render.
It is an optimization, not a delivery guarantee: `job.completed` re-lists every
output and remains the source of truth, so a client that saw `job.take_done`
dedups by take index, and one that missed it (ring-buffer replay is
best-effort) loses nothing. A take announced this way is final; the engine
never rewrites it. The engine garbage-collects `Outputs/<job_id>/` directories left
untouched for `LOCALMUSIC_OUTPUTS_RETENTION_DAYS` days (default 14; `0` keeps
everything) — swept at startup and daily, never touching a non-terminal job's
directory. Terminal jobs are also evicted from the in-memory history past
`LOCALMUSIC_JOB_HISTORY_CAP` total jobs (default 200; `0` unbounded), oldest
first; a purged job answers `404` like any unknown id.

### 5.3 Cancel

`POST /v1/jobs/{id}/cancel` → `202 {}`. Queued → `canceled` immediately. Running →
cooperative cancel at the next step boundary; if the worker doesn't yield within 10 s it
is SIGKILLed (safe: unload == process exit). Terminal jobs → `409 JOB_NOT_CANCELABLE`.

**`canceled` always means the job produced no output.** Its `result` stays null,
whether or not it had published previews. Streaming previews do not change that:
a preview is a file the client was already handed and told the duration of, so
"keep the partial" is a client-side decision about a file it already has, never
something inferred from a cancel. See 5.6.

### 5.4 Task jobs (separate / transcribe / analyze / render / mix / assist / plan / caption / lyrics / tag / compose / timbre / reamp / convert-voice / sing)

`task` selects the pipeline. `"generate"` (the default) is the classic
prompt→audio flow above and is also how audio-conditioned generation works
(reference/cover/repaint modes are ordinary params on generate models). The
other tasks are promptless transformations whose model must list them in
`capabilities.tasks`:

| task | typical family | consumes | produces (artifact kinds) |
|------|----------------|----------|---------------------------|
| `separate`   | separation    | `source_audio` (audio param) | `stem` per source |
| `transcribe` | transcription | `source_audio` | `midi` per track (+ `audio` previews labeled `preview:<track>`) |
| `analyze`    | analysis      | `source_audio` | `analysis` (json) |
| `render`     | notesynth     | `midi_file` (midi param) | `audio` |
| `mix`        | dsp           | `mix_spec` (json param) | `audio` (+ optional `stem` per track) |
| `assist`     | assistant     | `assist_input` (json param; `kind` selects the helper) | `assist` (json) |
| `plan`       | acestep       | `plan_caption` / `plan_lyrics` (string params) | `plan` (json) |
| `caption`    | captioning, mlxstt | `source_audio` (+ optional `question` string) | `text` (json) |
| `lyrics`     | mlxstt        | `source_audio` | `text` (json, with timed segments) |
| `tag`        | analysis, captioning, mlxstt | `source_audio` | `text` (json, tags array) |
| `compose`    | notation      | `prompt` (string param — see the note below) | `text` (json, ABC) + `midi` |
| `timbre`     | rave          | `source_audio` | `stem` (the re-voiced audio) |
| `reamp`      | nam           | `source_audio` + `nam_file` (audio param carrying an uploaded .nam capture) | `stem` (the re-amped audio) |
| `convert-voice` | seedvc     | `source_audio` + `reference_audio` (the target voice, user-supplied) | `stem` (the converted vocal) |
| `sing`       | yingmusic     | `melody_midi` (midi param) or `melody_audio`, + `lyrics_text` (string) + `reference_audio` (timbre) | `stem` (the sung vocal) |

Validation for non-generate tasks: `prompt` optional (ignored unless the model
declares a param for it); `lyrics` present → `422 VALIDATION`; `duration_s`
ignored and echoed as submitted (or null); `count` must be 1; every
non-nullable `audio`/`midi`/`json` param must be present; `task` outside
`capabilities.tasks` → `422 VALIDATION`. `assist` and `plan` are ordinary
non-generate tasks and every rule above applies to them unchanged — `plan` in
particular runs on a *generate* model (ACE-Step), but a `plan` job still
submits no `lyrics`, keeps `count` at 1, and may omit `prompt` (its inputs are
the `plan_*` params).

`compose` is the first task whose *primary* input is a declared **string
param** (`params.prompt` — a text idea or ABC notation to continue). Submit
validation only presence-checks non-nullable `audio`/`midi`/`json` params, so
an empty or missing prompt passes the gate and the notation worker fails the
job itself. The top-level `prompt` body field is **not** forwarded to task
workers — clients must send the text as `params.prompt`.

Task jobs reuse the generate status flow (`queued → loading → generating →
encoding → terminal`); stage detail rides `progress.message` ("separating:
drums"). Task jobs never carry `progress.phase` (5.5): each runs one opaque
pass, and that holds even on a model whose *generate* flow declares a
`capabilities.pipeline` — ACE-Step's `plan` runs only the LM half and reports
it as an unstaged band, never as phases. `eta_s` is
**elapsed-based** (`elapsed × (1−fraction)/fraction`, null until fraction ≥ 0.05)
because runtime scales with input length.

Result shape (replaces `outputs` for task jobs):

```json
"result": {
  "artifacts": [
    {"kind": "stem", "label": "vocals", "path": "/abs/.../Outputs/job_x/vocals.wav",
     "format": "wav", "sample_rate": 44100, "duration_s": 213.4},
    {"kind": "analysis", "label": "analysis", "path": ".../analysis.json",
     "format": "json", "sample_rate": null, "duration_s": null}
  ],
  "meta": {"tempo_bpm": 128.0, "key": "F#m", "camelot": "11A"},  // optional summary
  "timings": {"total_s": 41.2}
}
```

`kind` is an open set (`stem | midi | analysis | audio | assist | plan | text`
today) — clients ignore unknown kinds. `label` carries the human/slot identity
(stem name, instrument; `preview:<label>` marks an audio audition render paired
with the same-label midi artifact; an `assist` artifact's label is the `kind`
param of the job that made it; a `text` artifact's label is `caption`,
`lyrics`, `tags`, `abc`, or `abc:<track>` for the per-track notation of a
transcribe run). Artifact files obey the 5.2 delivery invariants (complete
before `job.completed`, under `Outputs/<job_id>/`, retention GC per 5.2).

**`assist`** is one round with the assistant family's small local instruct
model: the `kind` enum param selects the helper, `assist_input` (json param)
carries its input, and the answer comes back twice — as the single `assist`
artifact (`assist.json`) and as `result.meta`, so a client that keeps job
results never needs to read the file:

```json
"meta": {"assist": {"kind": "flesh_out", "ok": true, "raw": "…",
                    "value": {"prompt": "…", "added": ["…"]},
                    "repaired": false, "target_family": "acestep",
                    "dialect": "acestep"},
         "elapsed_s": 3.1}
```

`raw` is the model's unparsed text; `repaired` says the JSON needed fixing up
before it parsed; `target_family` / `dialect` say which model family the
writing was tuned toward (null / `"generic"` when none was named). `value` is
the object the app renders, and its shape follows `kind`:

| kind | value |
|------|-------|
| `interview` | `{"questions": [{"question": str, "examples": [str]}], "ready": bool}` |
| `interview_finish`, `brief`, `flesh_out`, `critique_fix` | `{"prompt": str, …}` — `brief` adds `"idea"` + `"title"`, `flesh_out` adds `"added": [str]`, `critique_fix` adds `"changes": [{"from": str, "to": str}]` |
| `lyrics`, `translate_lyrics` | `{"lyrics": str, "title": str}` |
| `pick_model` | `{"best": {"id": str, "why": str, "installed": bool}, "alternatives": [same]}` |
| `plan_song` | `{"sections": [{"tag": str, "seconds": int, "what": str}], "summary": str}` |
| `route_intent` | `{"action": str\|null, "prompt": str\|null, "subject": str\|null, "confidence": float, "reason": str}` |
| `describe_song` | `{"description": str, "prompt": str}` |
| `more_like_this` | `{"variations": [{"prompt": str, "differs": str}]}` |
| `name_and_tag` | `{"title": str, "tags": [str]}` |

**`plan`** runs only ACE-Step's 5 Hz language-model half and returns the plans
it wrote, so the user can choose one before paying for the DiT render.
`plan_caption` / `plan_lyrics` (string params) carry the inputs, `plan_count`
(default 3) how many plans to write, `plan_duration_s` the target length. The
single `plan` artifact (`plans.json`) and `result.meta` both carry:

```json
"meta": {"plans": [{"index": 0,
                    "metadata": {"bpm": 104, "caption": "…", "duration": 60,
                                 "genres": "…", "keyscale": "A minor",
                                 "language": "english",
                                 "timesignature": "4/4"},
                    "audio_codes": "<|audio_code_1|>…"}]}
```

`metadata` is the plan's chain-of-thought YAML parsed into those keys — **any
subset may be present**, so read every key as optional. `audio_codes` is the
token string the chosen plan renders from; the `audio_codes` param on the same
entries exists to hand it back to a follow-up generate.

**Text artifacts** (`caption` / `lyrics` / `tag` / `compose`, plus
transcribe's `emit_abc`) share one json payload, and — like `assist` — the
whole payload also rides `result.meta` under `"text"`, so a client that keeps
job results never needs to read the file:

```json
{"text_version": 1,
 "kind": "caption",                  // "caption" | "lyrics" | "tags" | "abc"
 "text": "A dreamy lo-fi hip hop beat with vinyl crackle.",
 "language": "en",                   // lyrics only (detected or requested)
 "segments": [{"start_s": 0.0, "end_s": 4.2, "text": "…"}],   // lyrics only
 "tags": [{"label": "techno", "score": 0.83, "group": "genre"}], // tag only;
                                     // score may be null (LLM taggers), group
                                     // is "genre" | "mood" | "instrument"
 "question": "What key is this in?", // caption QA echo, when one was asked
 "model": "caption-lpmusiccaps",     // catalog id
 "engine": "lpmusiccaps"}            // the entry's settings.engine
```

**Every field is optional** — text models evolve the way analyzers do. Empty
`text` is legal (an instrumental transcribed for lyrics) and clients treat it
as "the model heard no words", not an error. `result.meta` carries the payload
plus a short summary an app can put on a job row without parsing:
`caption` → `caption_preview` (first ~200 chars) and the echoed `question`;
`lyrics` → `language`, `segments` (count), `lyrics_preview`;
`tag` → `top_tags` ([str]); `compose` → `abc_preview`, `notes` (count).

- `caption` reads `source_audio` and writes prose. The optional `question`
  string param turns it into QA on models that support it; `max_tokens` /
  `temperature` steer LLM captioners.
- `lyrics` reads `source_audio` and writes the sung words with timed
  `segments`; optional `language` pins the language instead of detecting it.
- `tag` reads `source_audio` and writes the `tags` array. Declared by both
  the zero-shot CLAP tagger (analysis family) and LLM captioners.
- `compose` reads `params.prompt` (an idea, or ABC to continue) and returns
  the ABC as its `text` artifact **plus a `midi` artifact** (label
  `"composition"`, converted engine-side) so the `render` task can voice it.
  When the model's ABC fails MIDI conversion the job still succeeds with the
  text artifact alone and `meta.midi_error` explains — the model's notation
  is real even when it does not parse.
- `transcribe` with `emit_abc: true` additionally emits one `text` artifact
  per note track, labeled `abc:<track>`, payload kind `"abc"`.
- The audio-transformation tasks (`timbre` / `reamp` / `convert-voice` /
  `sing`) return their result as **`stem` artifacts** on purpose: the split
  ingest path already files stems as parts of the source song, so a client
  needs no routing of its own for them. Labels name what the audio *is*
  (`timbre:<model>`, `reamped`, `converted`, `sung`). `reamp`'s `nam_file`
  is an ordinary upload-resolved param declared with type `audio` even
  though the payload is a .nam JSON capture — the type governs upload
  resolution, and the engine never inspects the bytes.
- `analyze` on a CLAP-equipped analyzer accepts an optional `prompt_text`
  string param: the analysis payload and `result.meta` gain
  `clap_prompt_score` (cosine of CLAP text vs audio embeddings, −1…1) and
  `clap_prompt` (the echoed text, so a client can tell what the score was
  measured against). Entries without the CLAP embedder never declare the
  param.

The `mix` task's `mix_spec` json param (built by the app from stored analysis;
all beat math is precomputed — the dsp worker performs no analysis):

```json
{
  "target": {"bpm": 124.0, "key": "Am", "sample_rate": 44100,
             "downbeats": [0.48, 2.41],
             "duration_s": 96.0},        // optional; pads the mix to at least
                                         // this length (trailing silence)
  "tracks": [
    {"source": "up_abc123",             // upload id; engine resolves to a path
     "role": "vocals", "gain_db": -1.5, "mute": false,
     "offset_s": 0.0,                    // placement on the target timeline;
                                         // must be >= 0 (negative → job fails)
     "section": {"start_s": 43.2, "end_s": 71.9},    // optional source trim
     "fade_in_s": 0.0, "fade_out_s": 2.0,            // optional, default 0
     "fade_in_curve": "linear" | "scurve" | "log",   // optional, default linear
     "fade_out_curve": "linear" | "scurve" | "log",  // optional, default linear
     "source_bpm": 98.0, "source_downbeats": [0.51, 2.96],
     "stretch": {"mode": "beat" | "uniform" | "none",
                 "transient_mode": "smooth" | "crisp",
                 "preserve_formants": true},
     "pitch_shift_st": 2.0,
     "reverse": false,                    // optional; see below
     "effects": [                         // optional ordered chain; see below
       {"type": "highpass", "cutoff_hz": 80.0},
       {"type": "lowpass", "cutoff_hz": 18000.0},
       {"type": "eq3", "low_db": 2.5, "mid_db": 0.0, "high_db": 1.5},
       {"type": "compressor", "threshold_db": -18.0, "ratio": 3.0,
        "attack_ms": 8.0, "release_ms": 120.0},
       {"type": "gate", "threshold_db": -54.0}
     ]}
  ]
}
```

Placement is sample-accurate: `offset_s` is converted to frames, not rounded to
whole seconds, so a track can sit on any fraction of a beat. `target.downbeats`
is reserved — the dsp worker ignores it today, because every track already
carries its own precomputed grid.

`fade_in_s`/`fade_out_s` are **linear amplitude** ramps in target time, applied
after stretching and before `gain_db`, on top of the 2 ms de-click a `section`
trim already gets. Ramps longer than the track share it proportionally. A
crossfade is expressed as two overlapping tracks with complementary fades —
the worker has no notion of a crossfade itself; linear ramps of the same source
sum back to the original level, which equal-power ones would not.

`fade_in_curve` / `fade_out_curve` (optional) shape each ramp
independently: `linear` (the default, and the only correct choice for the
complementary crossfades above), `scurve` (smoothstep — eases both ends),
`log` (square root — fast early change that tails off, the perceptually
gentle fade). Per-ramp rather than per-track because one track routinely
carries both an audible head fade (curved) and a crossfade tail (linear). An
unknown value fails the job.

`reverse` (optional, default false) plays the track's audio backwards:
sample-for-sample reversal of the `section` trim (or the whole file without
one), applied before resampling and stretching, so every later stage sees the
reversed material exactly as it would forward material.

`effects` (optional) is an **ordered** per-track processor chain, applied after
stretching and before fades and `gain_db` — a fade shapes the *processed*
signal, and a gate applied after a fade-out would chop its tail. Six
processor types exist; every field shown above is required for its type, and
an unknown `type` (or a malformed processor object) fails the job rather than
silently skipping a stage of the sound the caller asked for:

| type | fields | meaning |
|------|--------|---------|
| `highpass` | `cutoff_hz` | 12 dB/oct high-pass |
| `lowpass` | `cutoff_hz` | 12 dB/oct low-pass |
| `eq3` | `low_db`, `mid_db`, `high_db` | three fixed bands: low shelf at 120 Hz, peak at 1.2 kHz, high shelf at 8 kHz |
| `compressor` | `threshold_db`, `ratio`, `attack_ms`, `release_ms` | feed-forward compressor |
| `gate` | `threshold_db` | noise gate |
| `convolve` | `ir` (upload id → path, required), `mix` (0–1, optional, default 1) | impulse-response convolution — rooms, halls, cabinets; the IR is a .wav that rides the spec as an upload and is path-resolved by the same pass that resolves track sources |

Every filter frequency is **bounded below Nyquist** by the worker
(`min(f, 0.98 × sample_rate/2)`), including `eq3`'s three fixed band centres.
A cutoff above Nyquist has no filtering left to do; left unbounded it makes
the biquad coefficients degenerate and the render comes back as noise or
silence from a job that reports success. A non-positive frequency fails the
job.

Dynamics state (compressor envelopes, gate state) starts fresh per track. A
caller that cuts one source into several tracks of a single timeline should
crossfade the joins (as above), which also covers the reset.

Beside `mix_spec`, the `mix` task reads these declared params (all optional;
unknown params are dropped at submit, per §5.1 — so a worker only ever sees
what its model declares):

| param | type | default | meaning |
|-------|------|---------|---------|
| `target_lufs` | float | −14.0 | integrated loudness the mix is normalised to |
| `normalize` | bool | true | false skips loudness normalisation entirely (`target_lufs` is ignored) — an edit render must not change the level of audio the caller only trimmed |
| `limiter` | bool | true | the −1 dBTP true-peak limiter after normalisation |
| `keep_tracks` | bool | false | also emit each aligned track as a `stem` artifact |
| `output_format` | enum `wav` \| `aiff` \| `flac` \| `mp3` | `wav` | container of the `audio` (mixdown) artifact; `stem` artifacts stay 16-bit WAV |
| `bit_depth` | enum `pcm16` \| `pcm24` \| `float32` | `pcm16` | sample format of the mixdown artifact; `float32` is invalid for `flac` and the job fails; ignored for `mp3` |

The mixdown is hard-clipped to ±1.0 before writing **unless** the container can
carry out-of-range floats — i.e. only `wav`/`aiff` at `float32` keep overshoot.
`mp3` is always clipped, which is what "ignored for `mp3`" above means in
practice.

### 5.5 Staged progress

`progress.stage` keeps its three-value vocabulary (`loading | generating |
encoding`), assigned by the engine. Three optional fields describe what the
model is actually doing inside it:

```json
"progress": {"stage": "generating", "fraction": 0.42, "eta_s": 95,
             "message": "step 6/8",
             "take": 1,              // 0-based; which of `count` is rendering
             "phase": "diffusion",   // an id from capabilities.pipeline
             "step": 6,              // position within that phase
             "steps": 8}             // total steps in that phase
```

**`take`** is the index of the take the job has reached, `0 ≤ take < count`. A
`count: 4` submission is one job that renders four takes one after another, and
`fraction` is the average across all of them — so without `take` a client can
only *infer* the position by multiplying, which fails outright whenever
`fraction` is null. It is null before the first take starts (during a cold load)
and for task jobs, which render nothing. During the final `encoding` stage it
stays at the last take rather than dropping to null: every take is finished by
then, and blanking it would flicker the readout out a frame before the job
completes.

**`fraction` is nullable**, and null means the model genuinely does not know —
draw an indeterminate bar. It is null throughout a cold load, and for any phase
an adapter cannot quantify. (It used to be flattened to `0.0`, which drew a bar
frozen at zero for minutes and read as a hang.)

Every one of `phase`, `step` and `steps` may be null or absent, independently,
and **absence is information**:

- no `phase` — the adapter cannot name what it is doing right now. The app keeps
  drawing the declared pipeline, with nothing marked active.
- `phase` but no `step`/`steps` — the phase is known, its progress is not
  counted. This is the honest report for a phase driven by a timer rather than
  by real steps: ACE-Step's Python runtime interpolates its diffusion band from
  a historical per-step estimate on a background thread, so it sends
  `phase: "diffusion"` and no counts. The `acestep.cpp` runtime prints real step
  numbers for the same work and does send them.

Engines must never synthesize these fields. A model whose adapter cannot
decompose its work at all declares no `capabilities.pipeline` and reports no
`phase`; the app then draws a single bar, which is what it did before this
existed.

Phases arrive in the order the model declares them, but no phase is guaranteed
to be reported: a stage marked `optional` may be skipped for a job, and a phase
too brief or too opaque to observe may simply never appear.

### 5.6 Streaming render previews

A job submitted with `"preview": true` publishes partial audio while it renders:
one `job.preview` event per frame, each naming a complete WAV file on disk.

```json
{"job_id": "job_...", "take": 0,
 "path": "/abs/.../Outputs/job_x/preview-2.wav",
 "sample_rate": 44100, "duration_s": 11.0, "step": 6}
```

- `path` is written `.part` + rename, under `Outputs/<job_id>/` like every other
  output, and is validated by the engine exactly as a task artifact is (5.4): a
  worker handing back a path outside the job's own directory has its frame
  dropped with a `job.log` line, never the job failed. There is no HTTP route —
  the app reads the absolute local path.
- `take` is which take of a multi-take job the frame belongs to; `step` is the
  position inside the phase that produced it, null where that phase counts no
  steps (5.5).
- Frames supersede each other, and are collected as soon as they are dead
  weight: **on success** (the finished take is the thing to keep), **on
  failure** (there is nothing to keep), and **between the takes of a multi-take
  job** — otherwise a `count: 4` previewed render holds every frame of every
  take at once. A client that wants a frame must take it before the job ends.
- A **canceled** job is the one case the engine leaves alone, deliberately: the
  client may be copying the last frame out right now, and deleting it under that
  is a race the engine would always win. Those are collected on the next engine
  start, alongside `uploads/`.

**Every frame is real audio.** It is decoded from the state the model is
genuinely in at that step — never an interpolation of the finished take, and
never a synthesised stand-in, because nothing downstream could tell the
difference. What "the state the model is in" sounds like differs by family, and
that is the honest signal, not a defect:

- **Stable Audio Open, Stable Audio 3** — the sampler hands its callback
  `denoised`, the predicted *clean* latent, so each frame is a full-length,
  progressively cleaner version of the whole clip. Both trim the frame to the
  requested duration before publishing it, because the sampler works on a
  padded latent whose tail decodes to garbage — an untrimmed frame would both
  sound wrong at the end and claim a length the take will not have.
- **diffusers pipelines** (StableAudio, AudioLDM, AudioLDM2, MusicLDM) — the
  step callback carries the *noisy* latents; no diffusers scheduler exposes its
  clean prediction to a callback. Early frames therefore sound like noise. That
  is where the render actually is.
- **MusicGen on MLX** — autoregressive, so each frame is a second or two longer
  than the last rather than cleaner. `duration_s` is what says which shape a
  client is looking at; no flag is needed and none is sent.

Families that declare no `supports_preview` cannot produce a real frame at all:
ACE-Step's DiT loop has no callback point and its latents never leave it (one of
its two runtimes is a subprocess besides), the transformers MusicGen path would
have to rebuild the delay-pattern mask from `generate()`'s internals to
interpret its token buffer, and audiocraft / MiniMax / MLX-Audio / YuE each run
one opaque call. Task models (5.4) are out of scope entirely.

**Cost.** Every frame is a full autoencoder or codec decode and measurably slows
the render, which is why previews are off by default and sampled rather than
streamed: adapters take a stride from the phase's step count (about four frames
across a phase, at least one for a short render), so an 8-step render still
shows something and a 200-step one does not pay 200 decodes.

### 5.7 Queue hold

`POST /v1/queue/pause` → `202 {}` · `POST /v1/queue/resume` → `202 {}`

A hold stops the queue **starting** anything. Queued jobs stay queued, keep their
`queue_position`, and are neither cancelled nor reordered. Submitting while held is
accepted and the job simply waits.

**The running job keeps running.** There is no verb here that stops it and no
plan to add one: suspending a worker means SIGSTOP somewhere inside a Metal
command buffer, which is not something that reliably resumes. So a client must
say what is true — "finishing the current render; cancel it to stop now" — and
never imply that the render has paused. `POST /v1/jobs/{id}/cancel` (§5.3) is
the verb that stops the running one.

Both requests are idempotent, and both emit `queue.state` even when nothing
changed: that event is the only push a client's toggle gets, so swallowing the
echo of a repeated request would leave a client that missed the first one wrong
with nothing to correct it. `/v1/system.queue_held` is the same fact on demand,
and can read `true` while `active_job_id` is still set.

The hold covers renders only. Downloads are held by pausing them (§4.2); a
paused download keeps its slot, so nothing queued behind it starts either, and
"pause everything" is the two together.

### 5.8 Job order

`JobInfo.priority` is an integer, `0` by default, **higher runs first**. Within
one priority the queue is FIFO, and that is the only place the scheduler's
warm-worker locality optimisation applies — it may pull a same-family job
forward past its equals, never past a job the user placed above it. So `0`
means "no opinion, optimise freely", and anything a client sets is an
instruction.

- `PATCH /v1/jobs/{id}/priority {"priority": 3}` → `202 {}`. Refusals:
  `404 NOT_FOUND`; `409 JOB_NOT_QUEUED` if the job is already running or
  terminal (its place in the queue is no longer a question); `422 VALIDATION`
  if `priority` is not an integer.
- `POST /v1/queue/order {"job_ids": ["job_c", "job_a"]}` → `202 {}` — one call
  that makes these queued jobs run in this order, **ahead of every queued job
  not named**. This exists because a drag-and-drop expressed as N `PATCH`es
  would emit N reorderings and could interleave with a dequeue halfway through.
  Ids that are no longer queued are skipped rather than refused — the job at the
  top can legitimately start while the pointer is still down. `404 NOT_FOUND`
  for an id that is not a job at all; `422 VALIDATION` if `job_ids` is not a
  list of strings.

Both re-emit `job.queued` for **every** queued job, carrying its new
`queue_position` — positions shift for jobs nobody touched, and a client that
only refreshed the row it dragged would show a stale queue. Note the cost of
using them: an explicit order overrides locality, so reordering across families
can add a model reload the engine would otherwise have avoided.

## 6. Event stream

`GET /v1/events` — `text/event-stream`. Heartbeat comment (`: hb`) every 15 s —
on a clock, not only when the stream falls silent, since `system.telemetry`
ticks at least every 10 s and would otherwise suppress it forever.
Monotonically increasing integer `id:` per event. `Last-Event-ID` replays from a ring
buffer of the last 500 events (best effort); after any reconnect the app also re-fetches
`/v1/models`, `/v1/downloads`, and `/v1/jobs`, so replay gaps are safe.

| event                | data payload |
|----------------------|--------------|
| `download.progress`  | `DownloadInfo` |
| `download.completed` | `{"download_id","model_id","runtime_only"}` — `runtime_only: true` finished a runtime install and fetched no model, so a client must not announce one |
| `download.failed`    | `{"download_id","model_id","error":{...}}` |
| `job.queued`         | `{"job_id","group_id","model_id","queue_position"}` — also re-emitted for every queued job after a reorder (§5.8) |
| `job.started`        | `{"job_id"}` |
| `job.progress`       | `{"job_id","stage","fraction","eta_s","message","take","phase","step","steps"}` — the `JobInfo.progress` object plus `job_id`; see 5.5 |
| `job.preview`        | `{"job_id","take","path","sample_rate","duration_s","step"}` — partial audio for a take still rendering; only for a job submitted with `preview: true`; see 5.6 |
| `job.log`            | `{"job_id","line"}` — worker stderr mirror; see the note below for what is and is not mirrored |
| `job.completed`      | `{"job_id"}` — app then `GET /v1/jobs/{id}` for the result |
| `job.failed`         | `{"job_id","error":{"code","message"}}` |
| `job.canceled`       | `{"job_id"}` |
| `queue.state`        | `{"held": true\|false, "active_job_id"}` — the §5.7 hold; `active_job_id` is the job the hold could not stop, and is normally non-null right after a pause |
| `models.changed`     | `{}` — install-state invalidation → re-fetch `/v1/models` |
| `library.progress`   | `LibraryOperation` — a clear or relocate under way (§4.4) |
| `library.completed`  | `LibraryOperation` with `state: "succeeded"`; carries `removed_model_ids` / `moved_repo_ids` + `skipped_repo_ids`, and `canceled` |
| `library.failed`     | `LibraryOperation` with `state: "failed"` and `error` |
| `worker.state`       | `{"state":"loading"\|"loaded"\|"stopped","model_id","family"}` — what the warm worker holds (drives the app's titlebar) |
| `system.telemetry`   | the `usage` object from `/v1/system` — every 2 s while a worker is alive, every 10 s idle, so the sidebar readout is live without polling. Same nullability rules; skipped entirely while no client is subscribed |
| `engine.warning`     | `{"message"}` (e.g. MPS CPU-fallback, RAM > 85 %) |

### 6.1 What `job.log` mirrors

Every line a worker prints is written to that worker's log file under
`Backend/logs/`. That file is the record and nothing is withheld from it.

`job.log` is a different thing: a summary of that file, one SSE event per
line, feeding a pane about ten lines tall. Two rules apply to it, and an
engine implementing this contract is expected to apply both.

- **Progress-bar redraws are not mirrored.** A tqdm-style bar overwrites
  itself with a carriage return, and a client reading the pipe in text mode
  sees every overwrite as a new line. Mirroring them sends a value that is
  already stale, drawn as bar art. They are recognised by the `NN%|` that
  precedes the bar.
- **The rest is rate limited**, currently to 8 lines per second per job. When
  the limit bites, the next mirrored line is preceded by
  `… N more lines not shown (see the worker log)`. The cap must announce
  itself: a truncated render and a quiet one have to be distinguishable.

Adapters are also expected to echo each `progress` message to stderr, which is
what gives a family with no per-step library output anything to mirror at all.
This is not a separate event — it arrives as an ordinary `job.log` line.

## 7. Storage ownership

Under `~/Library/Application Support/LocalMusic/` (the app passes the concrete dirs):

- App-owned (engine never touches): `Database/`, `Library/`.
- Engine-owned (rooted at `--data-dir` / `--output-dir`): `envs/`, `Outputs/`
  (retention-swept, see 5.2), `Backend/logs/`, `installed/` (markers),
  `uploads/`. `worker-<family>.log` files are bounded: a log past 10 MB starts
  over at the next worker spawn. The daily `backend-YYYY-MM-DD.log` files are
  written by the *app*, which also prunes them on the outputs retention window.
- Model weights live in the **shared system Hugging Face cache**
  (`~/.cache/huggingface`, standard `HF_HOME` semantics; an inherited `HF_HOME`
  env var overrides — the verification suite uses that for isolation). Weights
  there are shared with any other HF tooling on the machine; deleting a model
  in the app removes its repos from the shared cache unless another installed
  catalog entry still references them.

The library database of record is the app's (GRDB). The engine keeps no durable state
besides model weights, venvs, and a transient job queue; it may be killed and restarted
at any time without data loss beyond the in-flight job.
