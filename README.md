# LocalMusicGen

Run open music models on your Mac. Generate, separate, transcribe, restyle, arrange,
edit and analyse, all on Apple Silicon, with everything kept in one searchable library.

LocalMusicGen is a native macOS app with a Python engine inside it. It downloads models
from Hugging Face and elsewhere, runs them on the Mac's own GPU and unified memory, and
keeps every result together with the settings that made it. The catalog holds 136
models across 39 model families: models that write songs from a description and lyrics,
models that split a recording into stems, models that listen and write down what they
hear, and the tooling to chain them together. Once a model is downloaded nothing leaves
the machine: no accounts, no API keys, no cloud.

> **Note**
> LocalMusicGen is distributed outside the Mac App Store (Developer ID signed and
> notarized). It provisions a Python runtime at first launch, which App Store rules
> don't permit.

## What it does

The sidebar has seven places in two groups. **Make**: Actions, Generate, Style Transfer,
AI Workbench, Editor. **Browse**: Library, Models.

- **Actions** is where the app opens: a gallery of sixty recipes on six shelves
  (Generate, Help me write, Separate & analyse, Music → words, Recombine, Reimagine).
  Each card says what it needs, what it makes, and whether it is *Exact* (your audio,
  DSP only), *Reimagine* (a model rewrites it) or *Analyse* (measures, no audio out).
  Recipes that need a model you haven't installed still open, and point at the download.
  Drop an audio file on the gallery and it is imported and taken straight to Split
  into instruments.
- **Generate** turns a prompt, and lyrics on the models that sing, into a take. Simple
  mode is one prompt, one length, one button; Full control exposes every parameter the
  model declares. Takes land in the Library. Hold a seed to reproduce one, fan a prompt
  out to several models and audition them side by side, or have the assistant plan the
  song and pick the model first.
- **Style Transfer** transforms audio that already exists, eleven ways: keep the melody
  and words but change the style, sound like a reference, keep the melody, morph the
  description, keep the shape, keep chosen stems, replace a section, complete it,
  continue it, add a part over the top, or extract one. Its settings survive between
  runs.
- **AI Workbench** is a multi-clip timeline. Drag parts from different songs onto lanes
  and the bench tells you what it will stretch or transpose to line them up. Render it
  *Exact* (a DSP mixdown with tempo and key matching) or *Reimagine* (a model plays the
  arrangement). "What mashes with this?" ranks the library by tempo and key fit.
- **Editor** works on one file in detail, non-destructively: trim, split, delete,
  silence, paste, reverse, amplify, fade, normalise to a LUFS target, speed, pitch,
  resample, plus high-pass, low-pass, EQ, compressor, gate and convolution reverb from
  an impulse response. Every apply renders a new file and keeps the original, so Revert
  always works. A selection can be sent on to Generate as a continuation, split on its
  own, or matched against the library.
- **Library** holds every song, part and render: generated, imported, stems and MIDI,
  edited, favourites. Full-text search over titles, prompts, lyrics and notes; ratings,
  tags and notes; A/B compare any two rows. Each row keeps the model, seed and
  parameters that made it, and a mix keeps the parts that went into it. Import anything
  AVFoundation can decode; export wav, aiff, flac or mp3.
- **Models** shows what runs on this Mac and what it costs: download size, memory
  needed, speed tier and licence, before you commit. Variants nest under their base,
  gated repos ask for your Hugging Face token, and any Hugging Face repo one of the
  supported families can load can be added by hand. The model library can live on any
  volume, including an external SSD.

Around those:

- **Music → words.** Models that listen: describe a track, transcribe its lyrics, tag
  its genre and mood, map its sections, read its chords, rate the recording, extract
  ABC notation, score it against its own prompt. Pipelines chain them: isolate the vocal
  then transcribe it; music to text and back to music again.
- **Help me write.** A small local language model drafts a description, lyrics, a
  title or a plan from what you tell it, and nothing commits until you have read it.
- **Notation.** Anything transcribed or composed to notes opens as an engraved score:
  zoom, transpose, hear it through a SoundFont, copy the ABC, export SVG or PNG.
- **Automation.** New audio can be analysed for tempo and key, described, tagged and
  lyric-transcribed as it lands. Notifications when a render finishes, even from
  another part of the app; media keys and Now Playing; a queue with priorities and
  pause; ⌘/ lists every shortcut.

## The models

Roughly by job:

| Job | Models |
| --- | --- |
| Music from a description | MusicGen (Small to Large, Melody, stereo, PyTorch or MLX), MAGNeT, MusicGen Style and Songstarter, Stable Audio Open, Stable Audio 3, MelodyFlow, Magenta RealTime 2, InspireMusic, AudioLDM and MusicLDM |
| Songs with lyrics | ACE-Step 1.5 (PyTorch variants, and GGUF through acestep.cpp), MiniMax Music 3 (PyTorch and MLX quantisations), YuE and YuE2, DiffRhythm2, SongBloom, SongGen, HeartMuLa, LeVo 2, and Vocals → band. 29 models sing. |
| Voice and timbre | YingMusic sings your lyrics in a reference voice; seed-vc changes a voice; eight RAVE models transfer timbre; Neural Amp Modeler re-amps through captured gear, with TONE3000 search built in |
| Variations and edits | VampNet, Token Splice, MelodyFlow editing, Stable Audio 3 inpaint and extend, ACE-Step repaint |
| Separation | Demucs (4-stem, fine-tuned, 6-stem, MMI, MDX Extra), Mel-Band and BS-RoFormer, Kim Vocal 2, Voc FT, UVR Karaoke, De-Noise, De-Echo + De-Reverb and an ensemble; BSRNN, SCNet, MDX23C and DrumSep |
| Notes | Basic Pitch, MT3, Transkun and ByteDance piano, SwiftF0 for a melody line, chord recognition, the Anticipatory Music Transformer to continue notes, text to ABC and ChatMusician to compose, a SoundFont renderer to hear it |
| Listening and analysis | Beats, key, structure and loudness; CLAP timbre and tags; Essentia and Jamendo tags; SQUIM quality scores; Whisper turbo for lyrics; Qwen2-Audio, LP-MusicCaps, MOSS-Music 8B and ACE-Step's own transcriber and captioner as describers |
| Writing | Qwen and Llama 3.2 writing assistants |
| DSP | Mixdown & Align, for exact mixes |

Most are one download from Hugging Face. The rest (the separators, RAVE, seed-vc, the
Essentia taggers, the SoundFont) are fetched by their adapter from wherever upstream
publishes them. The five Stable Audio models are gated and need a Hugging Face token,
which is kept in the Keychain.

## Requirements

- An Apple Silicon Mac running macOS 14 or later
- An internet connection for the first launch and for model downloads
- Disk and memory to match the models you want. The analysers need 4 GB of RAM and a
  few hundred megabytes at most; MusicGen Small is 2.4 GB on disk and wants 8 GB of
  RAM; the largest song models (MiniMax Music 3 at 57 GB, ACE-Step 1.5 XL at 30 GB)
  want 48 GB. Each model family also builds its own Python environment on first
  download, which for the PyTorch families is a few gigabytes more.
- Some model families read audio through torchcodec, which needs ffmpeg from Homebrew
  (`brew install ffmpeg`)

## Install

Download the latest `LocalMusicGen.dmg` from [Releases](../../releases) and drag the app
into `/Applications`.

The first launch fetches a private CPython and the engine's own dependencies into
`~/Library/Application Support/LocalMusicGen/`. That takes a minute or two and is
narrated on the welcome sheet; the Library, playback and importing work while it runs.
The sheet then offers an **Essentials** set of about 275 MB (analysis, chords, quality
scores, Demucs, three transcribers, the SoundFont renderer, mixdown, Essentia tags) and
a few generators sized to your RAM. Skip it and pick your own in **Models**.

Models default to the shared Hugging Face cache (`~/.cache/huggingface`, or `HF_HOME`
if it is set). Settings ▸ Models & Downloads shows the location and can move the whole
library to another folder or volume. Everything else the app makes, the database,
audio, backups, logs and the engine runtime, is under
`~/Library/Application Support/LocalMusicGen/`; Help ▸ Reveal Data Folder in Finder
opens it.

## Getting around

A transport bar spans the bottom of every screen: play/pause, a waveform scrubber, an
A/B switch while comparing, a level meter for the Workbench preview, the engine status
and the queue. The card at the foot of the sidebar follows where you are: a legend on
Actions and Style Transfer, stem colours on Parts, backups on Edited, a parts drawer on
the Workbench, storage on Models, and the engine's phase, loaded model and memory
everywhere.

Settings (⌘,) has eight panes: General, Notifications, Generation, Audio & Output,
Library & Files, Models & Downloads, Queue and Engine. Generation is where the
automatic analysers, describers and taggers are chosen; Engine is where warm workers,
the memory warning level, parallel downloads and render-file retention live.

## Building from source

Needs full Xcode (not just the Command Line Tools), plus
[xcodegen](https://github.com/yonaskolb/XcodeGen) and [uv](https://docs.astral.sh/uv/).
uv fetches the Python versions the engine needs (3.11, and 3.12 for four families).

```sh
./build.sh                  # build build/LocalMusicGen.app
./build.sh --dmg            # …and package it into build/LocalMusicGen.dmg
./build.sh --sign           # …Developer ID sign it, notarize and staple
./build.sh --publish v1.2   # tag, push and cut a GitHub release from the .dmg
./build.sh --debug --test   # fast Debug build, then the test suites
./build.sh --adapters       # also sync every adapter venv (first run pulls torch)
./build.sh --reset          # wipe app state first, keeping every downloaded model
```

`./build.sh --help` covers the rest. Signing needs a Developer ID and a `notary-profile`
keychain entry; see [`packaging/notarize_notes.md`](packaging/notarize_notes.md). The
app bundle carries the engine's sources, lockfiles and catalog plus a static `uv`, and
no Python at all: the shim in `packaging/engine-shim.sh` provisions the runtime on the
user's machine, which keeps the app around 50 MB with two things to sign.

New Swift files need `cd app && xcodegen generate` before Xcode sees them.

## Development

```sh
make stub             # run the contract stub — the app's attach-mode fixture
make verify-stub      # end-to-end contract checks against the stub (no ML deps)
make engine-dev       # run the real supervisor with dev paths
make verify-engine    # contract + engine checks against the real supervisor
make smoke            # real generation through the real engine
make app-test         # SwiftUI unit + integration tests
make verify-packaged  # fresh-machine first-run test of the packaged app
make check            # everything that runs without an engine or a GPU (~25 s)
```

`make check` is `check-supervisor` (the supervisor's pure logic), `check-engine` (the
Python tests under `engine/tests/`, each group run in the venv that owns its imports)
and `check-locks` (every `uv.lock` still matches its `pyproject`). `make check-pins`
compares the adapter venvs against the environments that proved them. Run `make check`
after any engine change; it needs no model weights.

One model at a time:

```sh
python3 scripts/smoke_test.py --model acestep-base --duration 30 --lyrics "…" --play
python3 scripts/task_driver.py --help     # any non-generate task
```

The app resolves its engine in this order, so a dev build can be pointed anywhere:

| Variable | Effect |
| --- | --- |
| `LOCALMUSICGEN_BACKEND_HANDSHAKE` (+ `LOCALMUSICGEN_BACKEND_TOKEN`) | attach to an already-running engine |
| `LOCALMUSICGEN_BACKEND_CMD` | spawn an arbitrary command, e.g. the stub |
| *(neither)* | the engine bundled inside the `.app` |

The engine's own knobs (memory warning level, warm slots, download parallelism, log
level, output retention) are Settings ▸ Engine; the app passes them to the engine as
environment variables at launch.

Only one instance runs at a time: a second launch activates the first and exits, since
two would fight over the same engine and data directory. Set
`LOCALMUSICGEN_ALLOW_MULTIPLE_INSTANCES=1` to run one deliberately side by side, and pair
it with the variables above.

## How it works

The SwiftUI app talks to a Python sidecar, the engine, over localhost REST + SSE,
authenticated with a token generated fresh each launch and passed through the
environment. The engine is a slim FastAPI supervisor that spawns one worker per model
family, each in its own uv venv: the families have irreconcilable dependency pins, and
killing a worker is how a model unloads and gives its unified memory back.

Big models take the single resident slot; small ones (the analysers, taggers,
transcribers) share a warm pool so a tagger doesn't reload for every track. Workers
report accelerator memory every two seconds, and when usage crosses the warning level
the engine evicts whatever nothing is using before it warns, but never stops the job.
Jobs run one at a time from a serial queue; finished audio is written to `Outputs/` and
the app moves it into the library it owns, a SQLite database with FTS5 search that
survives anything the engine does.

[`docs/api-contract.md`](docs/api-contract.md) is the source of truth for that
interface (contract version 1). `stub-backend/` implements it exactly, with simulated
downloads and jobs, so the app can be built and tested with no ML dependencies
installed at all. [`docs/model-survey.md`](docs/model-survey.md) records which models
made it into the catalog and why the rest didn't.

## Layout

| Path | What |
| --- | --- |
| `app/` | SwiftUI app (macOS 14+, arm64, Swift 6; GRDB is the only dependency) and its XCTest suite |
| `engine/supervisor/` | the FastAPI engine: registry, downloads, job queue, workers, events |
| `engine/protocol/` | stdlib-only adapter interface shared by every worker |
| `engine/adapters/` | one uv project per model family, 39 of them |
| `engine/catalog/models.json` | the model catalog: capabilities, parameters, requirements, licences |
| `engine/tests/` | the engine's Python tests, grouped by the interpreter that runs them |
| `stub-backend/` | FastAPI stub implementing the full contract |
| `docs/api-contract.md` | the app ↔ engine contract, the source of truth |
| `scripts/` | verification, smoke-test and catalog tooling |
| `packaging/` | entitlements, the engine launcher shim, distribution notes |

## Known limits

A few families run on the CPU because their Metal path is unstable or untested:
VampNet, seed-vc, YingMusic, MelodyFlow and the Anticipatory Music Transformer. YuE is
in the catalog for completeness and takes hours on Apple Silicon; YuE2 is the one to
use. The newest song models, HeartMuLa and LeVo 2, are the least exercised. Anything
that needs CUDA kernels (BS-Mamba2, the vllm fast paths) is left out rather than
shipped broken.

## Model licenses

Every model carries its own license, shown in **Models** before you download it. They
vary widely, and 66 of the 136 don't permit commercial use, among them Meta's MusicGen
and MAGNeT models (CC-BY-NC-4.0), MiniMax Music 3, YuE2, LeVo 2, SongGen and the RAVE
timbre models (IRCAM). The UVR separators have no formal license at all, and every amp
capture from TONE3000 carries its author's terms, which travel with the file. Check the
license of any model whose output you plan to release.
