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
