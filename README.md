# LocalMusicGen

Run open music-generation models locally on your Mac and compare them side by side.

LocalMusicGen is a native macOS app that downloads music models from Hugging Face, runs
them on Apple Silicon, and keeps everything they produce in a searchable library. Send
one prompt to several models at once to hear how they differ. Once a model is
downloaded, generation is entirely local — no accounts, no API keys, no audio leaving
the machine.

> **Note**
> LocalMusicGen is distributed outside the Mac App Store (Developer ID signed and
> notarized). It provisions a Python runtime at first launch, which App Store rules
> don't permit.

## Features

- **Generate** — text-to-music with MusicGen, Stable Audio Open, ACE-Step 1.5, MiniMax
  Music 3, YuE, DiffRhythm2, SongBloom and more; lyrics too, on the two dozen models
  that sing.
- **Compare** — fan a single prompt out to several models and audition the results next
  to each other.
- **Transform** — stem separation, style transfer, timbre and voice conversion,
  re-amping, mixdown.
- **Analyze** — transcription to MIDI and notation, tagging, captioning, key and tempo.
- **Arrange** — stack and align parts on the Workbench, trim and tweak in the Editor.
- **Library** — every song, part and render, searchable, alongside the settings that
  produced it.
- **Models** — over 120 models across 36 families, each showing its size, memory
  requirement and speed before you commit to the download.

## Requirements

- An Apple Silicon Mac running macOS 14 or later
- An internet connection for the first launch and for model downloads
- Disk and memory to match the models you want: from 2.4 GB and 8 GB of RAM for
  MusicGen Small, up to 57 GB and 48 GB for MiniMax Music 3

Some models live in gated Hugging Face repos (Stable Audio, for one). Add a token in
Settings.

## Install

Download the latest `LocalMusicGen.dmg` from [Releases](../../releases) and drag the app
into `/Applications`.

The first launch provisions a Python runtime and the engine's dependencies into
`~/Library/Application Support/LocalMusicGen/`. That takes a minute or two and is narrated
in the onboarding sheet. After that, pick a model in **Models**, download it, and
generate.

## Using it

The sidebar has seven places in two groups:

- **Make** — Actions (a gallery of every recipe the app knows, and where it opens),
  Generate, Style Transfer, AI Workbench, Editor
- **Browse** — Library, Models

A transport bar spans the bottom of every screen, and the card at the foot of the
sidebar follows where you are: the engine while you generate, the stem legend while you
browse parts, storage while you manage models.

## Building from source

Needs full Xcode (not just the Command Line Tools), plus
[xcodegen](https://github.com/yonaskolb/XcodeGen), [uv](https://docs.astral.sh/uv/) and
Python 3.11.

```sh
./build.sh                  # build build/LocalMusicGen.app
./build.sh --dmg            # ...and package it into build/LocalMusicGen.dmg
./build.sh --sign           # ...Developer ID sign it, notarize and staple
./build.sh --debug --test   # fast Debug build, then the test suites
```

`./build.sh --help` covers the rest. Signing needs a Developer ID and a `notary-profile`
keychain entry — see [`packaging/notarize_notes.md`](packaging/notarize_notes.md).

## Development

```sh
make stub             # run the contract stub — the app's attach-mode fixture
make verify-stub      # end-to-end contract checks against the stub (no ML deps)
make engine-dev       # run the real supervisor with dev paths
make verify-engine    # contract + engine checks against the real supervisor
make smoke            # real generation through the real engine
make app-test         # SwiftUI unit + integration tests
make verify-packaged  # fresh-machine first-run test of the packaged app
```

One model at a time:

```sh
python3 scripts/smoke_test.py --model acestep-base --duration 30 --lyrics "..." --play
```

The app resolves its engine in this order, so a dev build can be pointed anywhere:

| Variable | Effect |
| --- | --- |
| `LOCALMUSICGEN_BACKEND_HANDSHAKE` (+ `LOCALMUSICGEN_BACKEND_TOKEN`) | attach to an already-running engine |
| `LOCALMUSICGEN_BACKEND_CMD` | spawn an arbitrary command, e.g. the stub |
| *(neither)* | the engine bundled inside the `.app` |

Only one instance runs at a time: a second launch activates the first and exits, since
two would fight over the same engine and data directory. Set
`LOCALMUSICGEN_ALLOW_MULTIPLE_INSTANCES=1` to run one deliberately side by side, and pair
it with the variables above.

## How it works

The SwiftUI app talks to a Python inference sidecar — the engine — over localhost
REST + SSE, authenticated with a token generated fresh each launch and passed through
the environment. The engine is a slim supervisor that spawns one worker per model
family, each in its own uv venv: the families have irreconcilable dependency pins, and
killing a worker is how a model unloads and gives its unified memory back.

[`docs/api-contract.md`](docs/api-contract.md) is the source of truth for that
interface. `stub-backend/` implements it exactly, with simulated downloads and jobs, so
the app can be built and tested with no ML dependencies installed at all.

## Layout

| Path | What |
| --- | --- |
| `app/` | SwiftUI app (macOS 14+, arm64; GRDB is the only dependency) |
| `engine/` | Python engine: supervisor, protocol, per-family adapters, model catalog |
| `stub-backend/` | FastAPI stub implementing the full contract |
| `docs/api-contract.md` | The app ↔ engine contract — source of truth |
| `scripts/` | verification and smoke-test harnesses |
| `packaging/` | entitlements, engine launcher shim, distribution notes |

## Model licenses

Every model carries its own license, shown in **Models** before you download it. They
vary widely, and several of the best-known ones — every MusicGen and MAGNeT variant
(CC-BY-NC-4.0), Stable Audio Open, MiniMax Music 3 — don't permit commercial use. Check
the license of any model whose output you plan to release.
