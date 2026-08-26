# Hugging Face music-model survey (2026-08-16)

> **Update 2026-08-17 — new runtimes landed.** The top four "future work" items
> below are now in the app: the **mlx-audio runtime** (MiniMax Music 3 mxfp8 ~14
> GB / mxfp4 ~9 GB, family `mlxaudio`), a **MusicGen-MLX backend** behind the
> musicgen adapter (same facebook snapshots, `settings.backend = "mlx"`, ~14×
> faster decode than fp32 MPS on Medium), **acestep.cpp** (GGUF + Metal, family
> `acestepcpp`, per-file downloads from the Serveurperso stack via
> `allow_patterns`, binaries via `scripts/build_acestep_cpp.sh`), and the
> **audiocraft runtime** (family `audiocraft`: MAGNeT small/medium,
> MusicGen-Style, musicgen-songstarter; xformers stubbed with an SDPA
> emulation). Remaining candidates: Stable Audio 3 family, Magenta RT2, and the
> smaller items under "needing new adapters".

Full machine-readable inventory: [`hf-model-survey.json`](hf-model-survey.json)
(203 entries from a sweep of ~2,350 repos; per-repo configs verified for anything
claimed runnable). This note records what made it into the catalog and why the
rest didn't. Regenerate catalog sizes/entries with `scripts/build_catalog.py`.

## In the catalog (27 entries)

- **Featured (6)** — the original curated set: MusicGen Small/Medium, Stable
  Audio Open Small, ACE-Step 1.5 (Turbo), MiniMax Music 3, YuE.
- **MusicGen roster (9 more)** — Large, Melody, Melody Large, all five stereo
  decoders (grouped as *mono/stereo* variants of their base), and
  micro-musicgen-jungle (tiny, MIT, fun).
- **Stable Audio Open 1.0** — gated; up to 47 s stereo.
- **ACE-Step DiT variants (5)** — Base, SFT, XL Base, XL SFT, XL Turbo, grouped
  under ACE-Step 1.5. Same core package (LM/VAE/encoder) + per-variant DiT repo;
  wired via `settings.dit_repo` / `dit_config` / `shift`.
- **Diffusers audio (6)** — AudioLDM 2 (base/large/music), AudioLDM S/M,
  MusicLDM — all run on the generic diffusers adapter.

## Deliberately not in the catalog

- **Ungated mirrors / re-uploads of gated Stability weights** (ModelsLab,
  ford442, audo, AEmotionStudio's diffusers copy, Nekochu finetune). Users
  should accept Stability's license upstream; the gated originals are listed
  instead and work with an HF token.
- **Repackaged formats without a runtime in the app** — MLX ports (mlx-community
  MiniMax quants at 9–14 GB!, ACE-Step MLX, jasonvassallo's MusicGen ports),
  GGUF stacks (Serveurperso's acestep.cpp set — 257k downloads, Metal backend;
  audio-cpp MiniMax), ComfyUI repacks, ONNX, CoreML. Listing them would offer
  downloads the engine can't generate with. They're the highest-value future
  work — see below.
- **Models needing new adapters (65 in the survey)** — most promising by
  traction and macOS fit:
  1. **mlx-audio runtime** → MiniMax Music 3 in 8-bit/mxfp4 (9–14 GB instead of
     57 GB) and Stable Audio 3 small — biggest practical win for Apple Silicon.
  2. **Stable Audio 3 family** (medium/small-music; ungated "-base" variants
     exist) — stable-audio-tools format with a Gemma encoder; likely a modest
     stableaudio-adapter update.
  3. **acestep.cpp (GGUF + Metal)** — native C++ ACE-Step stack, huge community
     use; alternative runtime choice next to the Python package.
  4. **google/magenta-realtime-2** — ships official MLX artifacts; real-time.
  5. **audiocraft runtime** — unlocks MAGNeT, MusicGen-Style, stems, JASCO, and
     the popular songstarter finetune (audiocraft-format weights, not
     transformers-loadable).
  6. DiffRhythm 2, SongGeneration/LeVo (MLX ports exist), HeartMuLa, TangoFlux,
     riffusion (needs spectrogram decode), symbolic/MIDI cluster.

## Gotchas recorded by the sweep

- nateraw/musicgen-songstarter-v0.2 (best-known MusicGen finetune) is
  audiocraft-format only — it does NOT load via transformers.
- There is no official ACE-Step 1.7B LM repo on HF; the 1.7B ships inside the
  core Ace-Step1.5 package (mirrors/GGUFs exist for the standalone).
- Several sweep sizes are whole-repo totals across dtypes/quants; the catalog
  uses effective sizes (duplicate .bin/.h5/.msgpack excluded when safetensors
  exist — the downloader skips them too).
- InspireMusic, tencent/SongGeneration, and SongBloom originals have vanished
  from HF; only mirrors/GGUFs remain.

## The off-Hub integration wave (2026-08-25)

The "Beyond Hugging Face" triage (53 verdicts, evidence in
`~/build/local-music/new-model-testing/`, handoff in
`~/build/local-music/new-models-test-results.md`) landed as **38 new catalog
entries across 17 new adapter families**, four new task strings
(`timbre`, `reamp`, `convert-voice`, `sing`) and one piece of new engine
plumbing — the ModelScope download route (`ms_repos`, anonymous HTTPS via
`supervisor/ms_download_worker.py`).

**Mirror update (2026-08-25, same day):** the permissively-licensed off-Hub
weights were re-hosted unmodified on the user's HF account and the catalog
repointed at the mirrors — `rtikw/acestep15xlsft-*` (5, Apache-2.0),
`rtikw/InspireMusic-1.5B-Long` (Apache-2.0), `rtikw/SongBloom` (Apache-2.0),
`rtikw/bsrnn-large` (CC-BY-4.0), `rtikw/piano-transcription-crnn`
(CC-BY-4.0), and `rtikw/localmusic-assets` (beat_this final0 + both BTC
checkpoints, MIT — this makes install-state real for `analysis-basic`/`-clap`
too). Full record: `~/build/local-music/models-uploaded-to-my-HF.md`. The
`ms_repos` engine route remains supported but currently has no catalog users.
NC-licensed weights (RAVE, Essentia, VampNet zips, OpenVPI) deliberately stay
at origin; UVR/SCNet/MDX23C checkpoints have no redistribution grant and were
not mirrored in this wave (the viperx BS-RoFormer file was already on
`localmusic-assets` — the user mirrored it 2026-08-17, with its
"MIT-asserted, no per-file license" status stated in the repo README).

New families: `diffsynthace` (ACE-Step XL LoRA pack incl. vocals2music),
`magentart` (Magenta RT 2, MLX), `melodyflow` (vendored Space tree),
`qwenomni` (ACE-Step transcriber + captioner), `essentia` (Discogs-EffNet
tagging), `rave` (timbre), `nam` (re-amping), `seedvc` (voice conversion),
`yingmusic` (singing synthesis), `msst` (SCNet/MDX23C/BSRNN separation),
`vampnet`, `songgen`, `diffrhythm2`, `inspiremusic`, `songbloom`,
`mossmusic`, `anticipation` — plus new engines inside existing families
(BTC chords + SQUIM in `analysis`, ByteDance piano in `transcription`,
UVR cleanup + demucs variants as `separation` entries, SA3 Medium on
`stableaudio3`).

**Deliberately not integrated** (and why, so nobody re-litigates):

- **Jukebox** — closed question: mechanically alive (VQVAE decodes, prior
  loads) but hours-per-minute on CPU and superseded end to end.
- **Dance Diffusion** — superseded by the Stable Audio lineage; keep only if
  a "glitch sample generator" novelty card is ever wanted.
- **PaddleSpeech SVS** — installs on arm64 (recorded so nobody re-checks)
  but everything it does, the OpenVPI/ONNX stack does better.
- **OpenL3 / PaSST / YAMNet** — embedding and tagging roles already filled
  by CLAP and Essentia; YAMNet's CoreML story is the only reason to revisit.
- **madmom** — NC-licensed and its unique value (cheap key/chords) is
  covered by the analysis family + BTC.
- **PESTO / torchcrepe** — overlap SwiftF0; torchcrepe additionally peaks
  ~20 GB RSS. Comparison entries only if ever wanted.
- **Neutone .nm** — the format loads (probe proven) but there is no public
  catalog API; watch, don't build.
- **Dead on arm64, forever**: Spleeter, DDSP, the Magenta TF1 line
  (MusicVAE/GrooVAE/Music Transformer/E-GMD drums — E-GMD's drum
  transcription has no current replacement), Omnizart, allin1 (natten
  uncompilable; SongFormer is the untested modern alternative for section
  labels).
- **Deferred, not rejected**: the DiffSinger/LUNAI voicebank stack (all 8
  ONNX graphs load; what's missing is a phonemizer/timing front-end — a
  multi-day project, or drive OpenUtau headless), the OpenVPI vocoder that
  only matters as its building block, and MPS ports for the CPU-bound
  spikes (InspireMusic device unification is the highest-value one).

## The capability-exposure wave (2026-08-25, same day)

The "missing functionality" plan
(`~/build/local-music/plan-to-add-missing-fuctionality-for-new-models.md`)
was implemented in full: the catalog grew from 111 to **127 entries**, ten
new Actions cards landed (vocals2music, edit-with-words, vamp-loop,
dereverb, denoise, read-chords, rate-quality, gen-my-voice, style-morph,
tag-library, continue-notes), and the adapters now expose cover/repaint/
reference on the DiffSynth LoRA pack, VampNet onset-masks + prefix/suffix
infill + four finetune voices, MelodyFlow source captions, seed-vc
length/guidance knobs, Magenta RT2 style morphing (+ the base model),
Anticipation continuation/infilling (**smoke-verified on MPS — ~100 tok/s,
far faster than the CPU triage number**; infilling requires clipping the
gap's own events out of the inputs, which the adapter does), Essentia's
wider head roster + an embedding cache, BSRNN per-stem targets, SCNet XL
and DrumSep from the msst zoo, DiffRhythm2 fake-stereo, the SongBloom
pre-DPO variant, SA3 Medium-Base (ungated!) and Small-SFX, MOSS lyric
transcription + a 4-bit variant, the RAVE roster (nasa/musicnet/sol_full/
isis, each download-verified) + latent morphing, TONE3000 in-app browse
(key in Settings › Models), and IR convolution as a sixth mix-spec effect.
BTC chords now also render as a MIDI chord-bed part (transcribe route),
and chord/quality payloads merge into the stored analysis instead of
clobbering it (the §1.1 fix).

**New deliberate skips from that wave** (recorded so nobody re-litigates):

- **BS-Mamba2** (msst zoo) — mamba-ssm kernels are CUDA-only; unbuildable
  here. Revisit only if a Metal mamba kernel appears.
- **seed-vc V2 entry** — the CLI differs; add only after a local CPU smoke
  of `inference_v2.py` against the pinned repo.
- **MelodyFlow MPS spike** — the entry stays on CPU until someone flips
  `settings.device` to `mps` in a local run and listens (ask before GPU
  tests).
- **SongGen dual-track stems** — deferred per the plan's own decision:
  the mixed_pro checkpoint stays the shipped one; revisit only if the
  dual model's summed mix beats it on listening.
- **MOSS Instruct conversions** — no public mlx-community repos (401);
  only the Thinking quants exist.
- **magenta-rt2-base / SA3 small-sfx / anticipation-medium speeds are
  unmeasured** — their ests are scaled guesses and their notes say so.

## The deferred-items wave (2026-08-26)

Four of the deliberate skips above were revisited, all four resolved
(catalog now **129 entries**):

- **seed-vc V2 landed** (`convert-voice-seedvc-v2`, settings.version = 2,
  same pinned tarball). The V2 CLI hardcodes fp16, which CPU linears
  reject (Half×Float crash in `style_in`) — and a global
  `torch.float16 = torch.float32` alias is NOT the fix (pickled dtype
  references resolve through that attribute; it corrupts `torch.load` of
  the hubert checkpoint). The adapter drives the wrapper directly in
  float32: 12.5 s converted in 71.6 s on CPU at 30 steps (~6×). Speech
  only (style copy / anonymize); V1 keeps singing. hydra-core + omegaconf
  added to the family venv.
- **MelodyFlow flipped to MPS** (settings.device = "mps"). The scare
  number was warm-up: the machine's first MPS run pays ~2 min of Metal
  shader compilation, after which load is 7 s and 10 s of audio renders
  in 2.8 s (CPU: 12.7 s load, 7.2 s render). No NaNs — the tree's "T5
  has no autocast" warning is moot in fp32. est 0.7 → 0.3.
- **InspireMusic device-unification port landed** (settings.device =
  "mps", est 29.0 → 3.5, tier slow → medium). Exactly two seams, both
  patched in the adapter without touching the vendored tree:
  `frontend.py`'s device ladder only knows cuda/cpu, and `llm_job`
  forwards the chorus/time embeddings tuple unmoved AND in float64
  (unsupported on MPS). 10 s of music in 33.4 s measured (CPU baseline
  288.3 s). Bonus find: torchaudio ≥ 2.9 delegates I/O to torchcodec,
  whose ffmpeg dylibs don't load in the worker — the save at the END of a
  render was latently broken in the app venv on ANY device; the adapter
  now shims torchaudio.save/load through soundfile.
- **MOSS-Music Instruct landed** (`caption-moss-music-instruct`). The
  triage's 401 was a wrong-org probe — the originals live under
  **OpenMOSS-Team**/. No public MLX quant exists, so this is a
  first-party 4-bit conversion (moss_music_mlx converter, group 64,
  audio encoder bf16, 6.02 GB) mirrored with attribution at
  rtikw/MOSS-Music-8B-Instruct-4bit (Apache-2.0). Verified end-to-end:
  direct, clean captions with no thinking preamble.
- **SongGen dual-track: rendered, awaiting the listen.** interleaving_A_V
  (5.4 GB) renders vocal + accompaniment stems at the same token cost as
  mixed_pro but yields half the audio per token (two streams share the
  frames). A/B files in `~/build/local-music/listen-2026-08-26/`;
  entry only if it wins on listening.

Still genuinely blocked, unchanged: BS-Mamba2 (CUDA-only kernels), the
arm64-dead five, and the superseded rejections.

## Watch items (probed 2026-08-26)

- **Qwen-Music** — tech report only (arXiv 2607.11699, July 2026): 25 Hz
  single-codebook music-semantic tokenizer + AR LLM initialized from
  Qwen3.5-Omni (melody-token chain-of-thought) + generative stereo
  renderer; full songs with sung vocals, text-to-music and cover tasks,
  5M-hours training claim. **No weights released anywhere as of
  2026-08-26**: the HF paper page links zero models/spaces, the Qwen HF
  org has no music repo, ModelScope 404s, and the QwenLM GitHub org has
  no repo. Aggregator posts claiming "weights on Hugging Face" were
  churn — their own links only reach the paper. Product surface appears
  to be Qwen Studio (API). Re-probe occasionally; this would be a
  headline entry if weights ever land.
- **MuScriptor** (Mirelo × Kyutai) — multi-instrument audio→MIDI
  transcription (AMT), the first credible fill for the recorded
  drums/multi-instrument transcription gap (E-GMD line dead on arm64).
  Three sizes on HF: small 0.41 GB / medium 1.23 GB / large 5.47 GB,
  single safetensors each, `muscriptor` pip library, real traction
  (large: 3.5k downloads). CC-BY-NC-4.0 behind an auto-approve
  click-gate (rights-warranty + indemnification boilerplate) — the
  USER must accept it on the repo page with their HF account before
  anything can download (same stance as Stability gating; NC also
  means no mirroring, per policy). Triage pending that acceptance.
