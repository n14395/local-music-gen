"""Diff each app adapter venv against the triage env that proved it.

An adapter's pyproject is written from a stack that was proven once, in
`new-model-testing/envs/<stack>` (on the model SSD; override the root with
LOCALMUSICGEN_TRIAGE_ENVS). When a dependency is left floating (or
pinned to what upstream's requirements.txt asks for rather than to what
actually ran), uv resolves something else into the app's venv and the model
fails on its FIRST in-app run — long after every test passed. Two live
examples, both 2026-08-26:

  * MelodyFlow pinned torch 2.1 but let torchvision float; uv chose 0.28 (a
    torch-2.8 build) whose `torch.library.register_fake` killed the whole
    transformers import chain.
  * InspireMusic pinned `peft==0.13.2` from upstream's requirements while the
    proven env ran 0.20.0; diffusers refuses anything under 0.17.

Only packages present in BOTH environments are compared, and only ones whose
version genuinely breaks an import chain (see CRITICAL). Run after touching
any adapter's dependencies:

    python3 scripts/check_pin_drift.py

A family with no app venv yet is reported as SKIP — it has never been
provisioned, so there is nothing to compare until the model is first used.
Exits 1 when anything drifted or is missing, so a caller can gate on it.
"""
import json
import os
import subprocess
import sys

APP = ("/Users/nwf/Library/Application Support/LocalMusicGen/engine-src/"
       "adapters/{}/.venv/bin/python")
# The triage envs moved to the SSD with the rest of the model library; the
# old project-relative path made every family SKIP, silently.
TRIAGE = os.path.join(
    os.environ.get("LOCALMUSICGEN_TRIAGE_ENVS",
                   "/Volumes/SSK-4TB/new-model-testing/envs"),
    "{}", "bin", "python")

# adapter family -> triage env that proved it
PAIRS = {
    "inspiremusic": "inspiremusic",
    "melodyflow": "audiocraft-mf",
    "songbloom": "songbloom",
    "songgen": "songgen",
    "vampnet": "vampnet",
    "seedvc": "seedvc",
    "yingmusic": "yingmusic",
    "diffrhythm2": "diffrhythm2",
    "essentia": "essentia",
    "msst": "msst",
    "mossmusic": "moss",
    "anticipation": "anticipation",
    "magentart": "magenta-rt",
    "qwenomni": "qwen-omni",
    "diffsynthace": "diffsynth",
}

# What actually breaks an import chain when it drifts. Everything else is
# noise (packaging, typing-extensions, pure-python helpers).
CRITICAL = {
    "torch", "torchaudio", "torchvision", "torchtext", "transformers",
    "peft", "diffusers", "accelerate", "numpy", "tokenizers", "safetensors",
    "huggingface-hub", "librosa", "soundfile", "lightning", "omegaconf",
    "hydra-core", "einops", "mlx", "essentia", "essentia-tensorflow",
    "onnxruntime", "protobuf", "scipy",
}


# Present in a triage env for reasons unrelated to the model running: the
# harness itself, dev tooling, and the gradio demo stack that adapters
# deliberately override out.
IGNORE_MISSING = {
    "pip", "setuptools", "wheel", "uv", "ipython", "jupyter", "notebook",
    "pytest", "black", "ruff", "flake8", "mypy", "ipykernel", "debugpy",
    "psutil", "gradio", "gradio-client", "hf-gradio", "tensorboard", "wandb",
    "fastapi", "uvicorn", "starlette", "python-multipart", "safehttpx",
    "groovy", "orjson", "brotli", "cython", "pandas", "pytz", "ruff",
    "python-dateutil", "tzdata", "pydub", "aiofiles", "ffmpy",
    # cannot load here anyway (its ffmpeg dylibs do not resolve in a worker);
    # adapters route torchaudio I/O through soundfile instead
    "torchcodec",
}


# Runs inside each env, so it has to travel as a string. Two things it has to
# survive. The triage envs live on an ExFAT volume, which carries an AppleDouble
# sidecar next to every file: each `*.dist-info` has a `._*.dist-info` twin
# whose METADATA is a binary resource fork, and reading one raises
# UnicodeDecodeError. That killed the whole dict comprehension, so `versions()`
# returned None and every family with a triage env on the SSD printed
# `SKIP (app=y triage=n)` — the guard reporting nothing at all, which is the
# state it was fixed out of once already. Skip the twins by name, and keep a
# per-distribution try/except for whatever else a package's metadata does.
PROBE = """
import importlib.metadata as md, json, os
out = {}
for dist in md.distributions():
    path = getattr(dist, '_path', None)
    if path is not None and os.path.basename(str(path)).startswith('._'):
        continue
    try:
        name, version = dist.metadata['Name'], dist.version
    except Exception:
        continue
    if name:
        out[name.lower().replace('_', '-')] = version
print(json.dumps(out))
"""


def versions(python):
    """This env's installed versions, or None if there is no such env.

    A probe that RUNS and fails is reported rather than folded into None: a
    broken probe and a missing env both printed SKIP, which is how the
    AppleDouble bug above went unnoticed.
    """
    if not os.path.exists(python):
        return None
    try:
        out = subprocess.run([python, "-c", PROBE],
                             capture_output=True, text=True, timeout=60)
    except Exception as e:  # noqa: BLE001 — a dead interpreter is a report
        print(f"  probe failed ({python}): {e!r}")
        return None
    if out.returncode != 0 or not out.stdout.strip():
        tail = (out.stderr or "").strip().splitlines()
        print(f"  probe failed ({python}): "
              f"{tail[-1] if tail else 'no output'}")
        return None
    try:
        return json.loads(out.stdout)
    except ValueError as e:
        print(f"  probe returned no JSON ({python}): {e}")
        return None


problems = False
for family, env in sorted(PAIRS.items()):
    app, triage = versions(APP.format(family)), versions(TRIAGE.format(env))
    if app is None or triage is None:
        print(f"{family:15s} SKIP (app={'y' if app else 'n'} "
              f"triage={'y' if triage else 'n'})")
        continue
    drift = [(p, triage[p], app[p]) for p in sorted(set(app) & set(triage))
             if p in CRITICAL and app[p] != triage[p]]
    # A dependency missing OUTRIGHT is invisible to the version diff — which
    # is how SongBloom shipped without vector_quantize_pytorch and only found
    # out three imports into its first in-app render.
    missing = sorted(p for p in set(triage) - set(app)
                     if p not in IGNORE_MISSING)
    if drift or missing:
        problems = True
        print(f"{family:15s} vs envs/{env}")
        for p, t, a in drift:
            print(f"                  DRIFT   {p:20s} triage {t:12s} -> app {a}")
        for p in missing:
            print(f"                  MISSING {p:20s} triage {triage[p]}")
    else:
        print(f"{family:15s} ok ({len(set(app) & set(triage))} shared)")

print("\nPROBLEMS FOUND" if problems else "\nno critical drift, nothing missing")
sys.exit(1 if problems else 0)
