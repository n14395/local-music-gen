# LocalMusic

A native macOS app for running Hugging Face music-generation models locally on Apple
Silicon and comparing them side by side. Generate from a prompt (and lyrics, where
supported) with MusicGen, Stable Audio Open, ACE-Step 1.5, MiniMax Music 3, and more;
fan one prompt out to several models; keep the results in a searchable library.

## Layout

| Path | What |
|---|---|
| `docs/api-contract.md` | The REST+SSE contract between app and engine — source of truth |
| `app/` | SwiftUI app (macOS 14+, arm64) |
| `engine/` | Python inference sidecar: supervisor + per-model-family adapters in isolated uv venvs |
| `stub-backend/` | FastAPI stub implementing the full contract with simulated downloads/jobs |
| `scripts/` | verification harnesses |
| `packaging/` | distributable-.app tooling (bundled CPython + uv) |

## Dev quickstart

```sh
make verify-stub      # contract checks against the stub (no ML deps needed)
make stub             # run the stub for the app's attach mode
make verify-engine    # full engine checks (real HF downloads, tiny test model)
make smoke            # real generation smoke tests (MusicGen)
make app-test         # SwiftUI app: unit + integration tests against the stub
make package          # dist/LocalMusic.app with the bundled engine
make verify-packaged  # fresh-machine first-run test of the packaged app
```

Model-specific smoke runs: `python3 scripts/smoke_test.py --model acestep-base
--duration 30 --lyrics "..."` (add `--play` to hear it). Stable Audio needs a
Hugging Face token (Settings in the app, gated repo); MiniMax Music 3 is a
57 GB download — start it from Models when you mean it.

The app is five places: **Studio** (ask for music), **Actions** (do something to
audio you already have), **Workbench** (stack and align parts), **Library**
(songs, parts and renders) and **Models**. A transport bar spans the bottom of
every screen, and the card at the foot of the sidebar changes with where you
are — the engine while you generate, the stem legend while you browse parts,
storage while you manage models.

The app resolves its engine in this order: `LOCALMUSIC_BACKEND_HANDSHAKE`
(+`LOCALMUSIC_BACKEND_TOKEN`, attach mode for dev), `LOCALMUSIC_BACKEND_CMD`
(spawn any command, e.g. the stub), then the bundled engine inside the .app.

Only one instance runs at a time: a second launch (a Debug build beside the
packaged app, a second copy of the bundle) activates the running one and exits,
because two instances would fight over the same engine and data directory. Set
`LOCALMUSIC_ALLOW_MULTIPLE_INSTANCES=1` to run one deliberately side by side —
point it at a different engine with the variables above.

Requires: uv, Python 3.11, Xcode (app builds with
`DEVELOPER_DIR=/Applications/Xcode-beta.app`), xcodegen (`app/project.yml` →
`LocalMusic.xcodeproj`). Distribution notes: `packaging/notarize_notes.md`.
