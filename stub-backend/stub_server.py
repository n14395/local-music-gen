"""LocalMusic stub engine.

Implements docs/api-contract.md completely with simulated downloads and jobs, so the
SwiftUI app can be built and tested before the real inference engine exists. Simulated
generations emit real sine-wave WAV files of the requested duration.

Dependencies: fastapi, uvicorn. Nothing else.
"""

from __future__ import annotations

import argparse
import asyncio
import functools
import json
import math
import os
import random
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid
import wave
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

VERSION = "0.1.0"
CONTRACT = 1
STARTED_AT = time.monotonic()

# Mirrors the engine's closed task set (jobqueue.TASKS)
TASKS = ("generate", "separate", "transcribe", "analyze", "render", "mix",
         "assist", "plan", "caption", "lyrics", "tag", "compose",
         "timbre", "reamp", "convert-voice", "sing")

# Mirrors the assistant family's closed helper set — the `kind` enum on its
# assist task, one value per thing the app can ask the little LLM for.
ASSIST_KINDS = ("interview", "interview_finish", "flesh_out", "lyrics",
                "pick_model", "plan_song", "route_intent", "brief",
                "translate_lyrics", "describe_song", "more_like_this",
                "critique_fix", "name_and_tag")

# ---------------------------------------------------------------- catalog

DOWNLOAD_SECONDS = float(os.environ.get("LOCALMUSIC_STUB_DOWNLOAD_S", "20"))
PROVISION_SECONDS = float(os.environ.get("LOCALMUSIC_STUB_PROVISION_S", "3"))

# LOCALMUSIC_STUB_DOWNLOAD_S=0 means "advance only when told to", via the
# test-only POST /v1/downloads/{id}/_step registered at the bottom of this file.
#
# Every timed transfer is a stopwatch race for the test watching it. The app's
# download test has to see the download appear, see it reach the weights stage,
# pause it, and see the paused state land — all before the simulated transfer
# ends, because a finished download is removed from the store and its id stops
# resolving. Each of those hops crosses a process boundary and an SSE stream,
# and on a loaded machine they lose to the clock: the window was widened once
# (3 s -> 8 s) and it still failed, at three different assertions.
#
# So the clock comes out. In manual mode provisioning takes exactly one step
# and the transfer takes MANUAL_TICKS more, nothing moves in between, and the
# test asserts against a download that cannot finish behind its back.
MANUAL_DOWNLOADS = DOWNLOAD_SECONDS == 0
MANUAL_TICKS = 4
JOB_SPEED = float(os.environ.get("LOCALMUSIC_STUB_JOB_SPEED", "1"))  # >1 = faster

# Mirrors supervisor.jobqueue: small models run in a transient slot, never
# displacing the resident model nor staying resident themselves.
SMALL_MODEL_BYTES = int(os.environ.get("LOCALMUSIC_SMALL_MODEL_BYTES")
                        or 1_500_000_000)

# Mirrors supervisor.downloader: downloads transfer one at a time and the rest
# report `queued`.
MAX_ACTIVE_DOWNLOADS = max(
    1, int(os.environ.get("LOCALMUSIC_MAX_ACTIVE_DOWNLOADS") or 1))


SMALL_WARM_SLOTS = int(os.environ.get("LOCALMUSIC_SMALL_WARM_SLOTS") or 2)
SMALL_WARM_TTL_S = float(os.environ.get("LOCALMUSIC_SMALL_WARM_TTL_S") or 600)


def is_small(model: dict) -> bool:
    if SMALL_MODEL_BYTES <= 0:
        return False
    tasks = model["capabilities"].get("tasks") or ["generate"]
    size = model.get("size_bytes") or 0
    if "generate" not in tasks:
        return size <= SMALL_MODEL_BYTES
    return 0 < size <= SMALL_MODEL_BYTES


def warm_small_models() -> list[str]:
    """Live warm-pool model ids, expiring anything past the TTL first."""
    now = time.monotonic()
    if SMALL_WARM_TTL_S <= 0 or SMALL_WARM_SLOTS <= 0:
        STATE.transient_models = {f: v for f, v in
                                  STATE.transient_models.items()
                                  if v[1] is None}
    else:
        STATE.transient_models = {
            f: v for f, v in STATE.transient_models.items()
            if v[1] is None or now - v[1] < SMALL_WARM_TTL_S}
    return [mid for mid, _ in STATE.transient_models.values()]


def _catalog() -> dict[str, dict[str, Any]]:
    def spec(key, type_, label, default, **kw):
        return {"key": key, "type": type_, "label": label, "default": default,
                "nullable": kw.pop("nullable", False), **kw}

    common = [
        spec("seed", "int", "Seed", None, nullable=True, min=0, max=2**32 - 1,
             group="sampling"),
    ]
    models = [
        {
            "id": "musicgen-small",
            "family": "musicgen",
            "display_name": "MusicGen Small (stub)",
            "description": "Fast instrumental clips",
            "hf_repos": [{"repo_id": "facebook/musicgen-small", "gated": False}],
            "size_bytes": 2_420_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
                "sample_rate": 32000,
                "outputs_per_job_max": 16,
                "est_seconds_per_audio_second": 1.5,
                # stands in for the MLX MusicGen build, the autoregressive
                # half of the preview fixture (see STUB_PREVIEW_GROWS)
                "supports_preview": True,
                "pipeline": [
                    {"id": "prompt_encode", "label": "Prompt encode"},
                    {"id": "lm_decode", "label": "Token decode"},
                    {"id": "master", "label": "Master & save"},
                ],
                "params": [
                    spec("melody_audio", "audio", "Melody reference", None,
                         nullable=True, group="task"),
                    spec("guidance_scale", "float", "Guidance", 3.0, min=1.0,
                         max=15.0, step=0.5, group="sampling"),
                    spec("temperature", "float", "Temperature", 1.0, min=0.1,
                         max=2.0, step=0.1, group="sampling"),
                    *common,
                ],
            },
            "requirements": {"min_ram_bytes": 8 << 30, "disk_bytes": 2_420_000_000,
                             "speed_tier": "fast"},
            "license": {"name": "CC-BY-NC-4.0", "commercial_use": False,
                        "requires_hf_token": False,
                        "url": "https://huggingface.co/facebook/musicgen-small"},
            "notes": "Instrumental only, clips up to 30 s.",
        },
        {
            "id": "acestep-base",
            "family": "acestep",
            "display_name": "ACE-Step 1.5 Base (stub)",
            "description": "Full songs with vocals and lyrics",
            "hf_repos": [{"repo_id": "ACE-Step/ACE-Step-v1.5-base", "gated": False}],
            "size_bytes": 7_300_000_000,
            "capabilities": {
                "supports_lyrics": True,
                "instrumental_only": False,
                "duration": {"min_s": 10, "max_s": 240, "default_s": 60},
                "sample_rate": 44100,
                "outputs_per_job_max": 2,
                "lyrics_tags": ["[intro]", "[verse]", "[chorus]", "[bridge]",
                                "[outro]"],
                "lyrics_hint": "Section tags on their own lines structure the song.",
                "est_seconds_per_audio_second": 0.6,
                # `plan` runs only the 5 Hz LM half and returns the plans it
                # wrote, so the user can pick one before paying for the DiT
                "tasks": ["generate", "plan"],
                "pipeline": [
                    {"id": "lm_reasoning", "label": "LM reasoning",
                     "optional": True},
                    {"id": "prompt_encode", "label": "Prompt encode"},
                    {"id": "diffusion", "label": "Diffusion"},
                    {"id": "vocoder", "label": "Vocoder decode"},
                    {"id": "master", "label": "Master & save"},
                ],
                # The grouping fixture: three declared groups, controls gated on
                # a task selector, and one param (`variant`) left deliberately
                # ungrouped so the app's key-name fallback is exercised on a
                # model that otherwise declares its groups.
                "params": [
                    spec("steps", "int", "Steps", 60, min=10, max=200,
                         group="sampling"),
                    spec("guidance_scale", "float", "Guidance", 7.5, min=1.0,
                         max=15.0, step=0.5, group="sampling"),
                    spec("variant", "enum", "Variant", "turbo",
                         choices=[{"value": "turbo", "label": "Turbo"},
                                  {"value": "base", "label": "Base"}]),
                    spec("style_tags", "string", "Style tags", "",
                         placeholder="synthwave, 120bpm", group="musical"),
                    spec("bpm", "int", "BPM", None, nullable=True, min=40,
                         max=220, group="musical"),
                    spec("task_type", "enum", "Task", "text2music",
                         group="task",
                         choices=[{"value": "text2music", "label": "Generate"},
                                  {"value": "cover", "label": "Cover / restyle"},
                                  {"value": "repaint",
                                   "label": "Repaint a section"}]),
                    spec("src_audio", "audio", "Source audio", None,
                         nullable=True, group="task",
                         applies_when={"param": "task_type",
                                       "values": ["cover", "repaint"]}),
                    spec("audio_cover_strength", "float", "Cover strength", 0.7,
                         min=0.0, max=1.0, step=0.05, group="task",
                         applies_when={"param": "task_type",
                                       "values": ["cover"]}),
                    spec("repainting_start", "float", "Repaint start (s)", None,
                         nullable=True, min=0.0, max=240.0, step=0.1,
                         group="task",
                         applies_when={"param": "task_type",
                                       "values": ["repaint"]}),
                    spec("repainting_end", "float", "Repaint end (s)", None,
                         nullable=True, min=-1.0, max=240.0, step=0.1,
                         group="task",
                         applies_when={"param": "task_type",
                                       "values": ["repaint"]}),
                    spec("keyscale", "string", "Key / scale", None,
                         nullable=True, placeholder="A minor",
                         group="musical"),
                    spec("timesignature", "string", "Time signature", None,
                         nullable=True, placeholder="4/4", group="musical"),
                    spec("use_cot_metas", "bool", "LM plans musical metas",
                         True, group="sampling"),
                    spec("use_cot_caption", "bool", "LM refines the caption",
                         True, group="sampling"),
                    spec("use_cot_language", "bool", "LM picks the language",
                         True, group="sampling"),
                    spec("lm_temperature", "float", "LM temperature", 0.85,
                         min=0.0, max=2.0, step=0.05, group="sampling"),
                    spec("lm_cfg_scale", "float", "LM guidance", 2.0,
                         min=1.0, max=8.0, step=0.5, group="sampling"),
                    spec("lm_top_p", "float", "LM top-p", 0.9,
                         min=0.1, max=1.0, step=0.05, group="sampling"),
                    spec("audio_codes", "string", "Audio codes", None,
                         nullable=True, internal=True),
                    # plan-task inputs: the plan UI fills these, never the form
                    spec("plan_caption", "string", "Plan caption", None,
                         nullable=True, internal=True),
                    spec("plan_lyrics", "string", "Plan lyrics", None,
                         nullable=True, internal=True),
                    spec("plan_count", "int", "Plan count", 3, min=1, max=6,
                         internal=True),
                    spec("plan_duration_s", "float", "Plan duration (s)", None,
                         nullable=True, internal=True),
                    *common,
                ],
            },
            "requirements": {"min_ram_bytes": 16 << 30, "disk_bytes": 7_300_000_000,
                             "speed_tier": "medium"},
            "license": {"name": "Apache-2.0", "commercial_use": True,
                        "requires_hf_token": False,
                        "url": "https://github.com/ace-step/ACE-Step-1.5"},
            "notes": "Vocals + lyrics, up to 4 minutes.",
        },
        {
            "id": "stableaudio-small",
            "family": "stableaudio",
            "display_name": "Stable Audio Open Small (stub)",
            "description": "Loops, textures and sound effects",
            "hf_repos": [{"repo_id": "stabilityai/stable-audio-open-small", "gated": True}],
            "size_bytes": 4_100_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 11, "default_s": 5},
                "sample_rate": 44100,
                "outputs_per_job_max": 16,
                "est_seconds_per_audio_second": 0.8,
                # the diffusion half of the preview fixture: full-length frames
                "supports_preview": True,
                "pipeline": [
                    {"id": "prompt_encode", "label": "Prompt encode"},
                    {"id": "diffusion", "label": "Diffusion"},
                    {"id": "master", "label": "Master & save"},
                ],
                "params": [
                    spec("steps", "int", "Steps", 8, min=4, max=50,
                         group="sampling"),
                    spec("cfg_scale", "float", "CFG scale", 1.0, min=0.5,
                         max=6.0, step=0.5, group="sampling"),
                    *common,
                ],
            },
            "requirements": {"min_ram_bytes": 8 << 30, "disk_bytes": 4_100_000_000,
                             "speed_tier": "fast"},
            "license": {"name": "Stability Community License", "commercial_use": False,
                        "requires_hf_token": True,
                        "url": "https://huggingface.co/stabilityai/stable-audio-open-small"},
            "notes": "Gated repo — requires a Hugging Face token.",
        },
        {
            # Task-job fixture: promptless separate/analyze, multi-artifact results
            "id": "separation-stub",
            "family": "separation",
            "display_name": "Demucs 4-stem (stub)",
            "description": "Splits a song into vocals / drums / bass / other",
            "hf_repos": [{"repo_id": "stub/separation", "gated": False}],
            "size_bytes": 90_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["separate", "analyze"],
                "est_realtime_factor": 0.1,
                "params": [
                    spec("source_audio", "audio", "Source audio", None,
                         nullable=False),
                ],
            },
            "requirements": {"min_ram_bytes": 4 << 30, "disk_bytes": 90_000_000,
                             "speed_tier": "fast"},
            "license": {"name": "MIT", "commercial_use": True,
                        "requires_hf_token": False,
                        "url": "https://github.com/adefossez/demucs"},
            "notes": "Task model: split & analyze.",
        },
        {
            # Audio-transformation fixture: the timbre/reamp quartet's wire
            # shape (audio in → one stem out) behind one model. Declares all
            # four tasks so every new card can run against the stub without
            # four more fixtures; the real catalog gives each its own family.
            "id": "transform-stub",
            "family": "rave",
            "display_name": "Audio transformer (stub)",
            "description": "Re-voices / re-amps / converts / sings audio",
            "hf_repos": [],
            "size_bytes": 70_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["timbre", "reamp", "convert-voice", "sing"],
                "est_realtime_factor": 0.1,
                "params": [
                    spec("source_audio", "audio", "Source audio", None,
                         nullable=False),
                    spec("nam_file", "audio", "Amp capture (.nam)", None,
                         nullable=True),
                    spec("reference_audio", "audio", "Reference voice", None,
                         nullable=True),
                    spec("lyrics_text", "string", "Lyrics", None,
                         nullable=True),
                ],
            },
            "requirements": {"min_ram_bytes": 4 << 30,
                             "disk_bytes": 70_000_000, "speed_tier": "fast"},
            "license": {"name": "MIT", "commercial_use": True,
                        "requires_hf_token": False, "url": None},
            "notes": "Task model: audio transformations.",
        },
        {
            # Weightless task fixture (hf_repos empty → venv-only install)
            "id": "dsp-stub",
            "family": "dsp",
            "display_name": "Mixdown (stub)",
            "description": "Aligns and mixes parts into a new song",
            "hf_repos": [],
            "size_bytes": 0,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["mix"],
                "est_realtime_factor": 0.05,
                "params": [
                    spec("mix_spec", "json", "Mix spec", None, nullable=False,
                         internal=True, resolve_uploads=True),
                    spec("target_lufs", "float", "Target loudness (LUFS)", -14.0,
                         min=-30.0, max=-6.0, step=0.5),
                    spec("keep_tracks", "bool", "Keep tracks", False),
                    spec("normalize", "bool", "Normalize loudness", True),
                    spec("limiter", "bool", "True-peak limiter", True),
                    spec("output_format", "enum", "Output format", "wav",
                         choices=[{"value": v, "label": v.upper()}
                                  for v in ("wav", "aiff", "flac", "mp3")]),
                    spec("bit_depth", "enum", "Bit depth", "pcm16",
                         choices=[{"value": "pcm16", "label": "16-bit"},
                                  {"value": "pcm24", "label": "24-bit"},
                                  {"value": "float32", "label": "32-bit float"}]),
                ],
            },
            "requirements": {"min_ram_bytes": 2 << 30, "disk_bytes": 0,
                             "speed_tier": "fast"},
            "license": {"name": "GPL-3.0", "commercial_use": True,
                        "requires_hf_token": False,
                        "url": "https://github.com/spotify/pedalboard"},
            "notes": "Task model: literal recombine.",
        },
        {
            # Notes fixture: midi artifacts + preview pairing
            "id": "transcription-stub",
            "family": "transcription",
            "display_name": "Transcription (stub)",
            "description": "Transcribes audio into per-track notes",
            "hf_repos": [],
            "size_bytes": 0,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["transcribe"],
                "est_realtime_factor": 0.1,
                "params": [
                    spec("source_audio", "audio", "Source audio", None,
                         nullable=False),
                    spec("instrument_label", "string", "Instrument name", None,
                         nullable=True),
                ],
            },
            "requirements": {"min_ram_bytes": 4 << 30, "disk_bytes": 0,
                             "speed_tier": "fast"},
            "license": {"name": "Apache-2.0", "commercial_use": True,
                        "requires_hf_token": False, "url": None},
            "notes": "Task model: notes.",
        },
        {
            # Render fixture: midi-param input → audio artifact
            "id": "render-stub",
            "family": "notesynth",
            "display_name": "Note renderer (stub)",
            "description": "Renders a notes part back into audio",
            "hf_repos": [],
            "size_bytes": 0,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["render"],
                "est_realtime_factor": 0.05,
                "params": [
                    spec("midi_file", "midi", "Notes", None, nullable=False),
                    spec("gain_db", "float", "Gain", 0.0,
                         min=-12.0, max=12.0, step=0.5),
                ],
            },
            "requirements": {"min_ram_bytes": 2 << 30, "disk_bytes": 0,
                             "speed_tier": "fast"},
            "license": {"name": "MIT", "commercial_use": True,
                        "requires_hf_token": False, "url": None},
            "notes": "Task model: render.",
        },
        {
            # Assist fixture: the small local instruct LLM behind the app's
            # writing helpers (interview, lyrics, plan_song, ...)
            "id": "assistant-stub",
            "family": "assistant",
            "display_name": "Assistant (stub)",
            "description": "Writing help for prompts, lyrics and plans",
            "hf_repos": [{"repo_id": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                          "gated": False}],
            "size_bytes": 880_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["assist"],
                "params": [
                    spec("kind", "enum", "Assist kind", "interview",
                         internal=True,
                         choices=[{"value": k, "label": k.replace("_", " ")}
                                  for k in ASSIST_KINDS]),
                    spec("assist_input", "json", "Assist input", None,
                         nullable=False, internal=True),
                    spec("target_family", "string", "Target family", None,
                         nullable=True, internal=True),
                    spec("temperature", "float", "Temperature", 0.7,
                         min=0.0, max=1.5, step=0.1),
                    spec("max_tokens", "int", "Max tokens", None,
                         nullable=True, internal=True),
                ],
            },
            "requirements": {"min_ram_bytes": 4 << 30,
                             "disk_bytes": 880_000_000, "speed_tier": "fast"},
            "license": {"name": "Apache-2.0", "commercial_use": True,
                        "requires_hf_token": False,
                        "url": "https://huggingface.co/mlx-community/"
                               "Qwen2.5-1.5B-Instruct-4bit"},
            "notes": "Task model: writing help.",
        },
        {
            # Caption fixture: audio in, prose out. Dual-task on purpose —
            # the text-model analogue of separation-stub's separate+analyze,
            # so the app's task filtering is exercised against a model that
            # declares more than one text verb.
            "id": "caption-stub",
            "family": "captioning",
            "display_name": "Describer (stub)",
            "description": "Listens to audio and writes prose about it",
            "hf_repos": [],
            "size_bytes": 500_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["caption", "tag"],
                "est_realtime_factor": 0.05,
                "params": [
                    spec("source_audio", "audio", "Audio", None,
                         nullable=False),
                    spec("question", "string", "Question", None,
                         nullable=True),
                    spec("max_tokens", "int", "Length limit", 256,
                         min=32, max=1024, internal=True),
                    spec("temperature", "float", "Variety", 0.7,
                         min=0.1, max=1.5, step=0.05),
                ],
            },
            "requirements": {"min_ram_bytes": 4 << 30,
                             "disk_bytes": 500_000_000, "speed_tier": "fast"},
            "license": {"name": "Apache-2.0", "commercial_use": True,
                        "requires_hf_token": False, "url": None},
            "notes": "Task model: captions.",
        },
        {
            # Lyrics fixture: whisper-class transcriber with timed segments.
            "id": "lyrics-stub",
            "family": "mlxstt",
            "display_name": "Lyric transcriber (stub)",
            "description": "Writes down the sung words with timings",
            "hf_repos": [],
            "size_bytes": 800_000_000,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["lyrics"],
                "est_realtime_factor": 0.1,
                "params": [
                    spec("source_audio", "audio", "Audio", None,
                         nullable=False),
                    spec("language", "string", "Language", None,
                         nullable=True),
                ],
            },
            "requirements": {"min_ram_bytes": 4 << 30,
                             "disk_bytes": 800_000_000, "speed_tier": "fast"},
            "license": {"name": "MIT", "commercial_use": True,
                        "requires_hf_token": False, "url": None},
            "notes": "Task model: lyrics.",
        },
        {
            # Compose fixture: text/ABC in, ABC + midi out. Weightless, and
            # its primary input is a string param — which submit validation
            # does not presence-check, so the "adapter" (this stub) fails the
            # job on an empty prompt exactly as the real notation worker does.
            "id": "notation-stub",
            "family": "notation",
            "display_name": "Notation composer (stub)",
            "description": "Writes ABC notation from a text idea",
            "hf_repos": [],
            "size_bytes": 0,
            "capabilities": {
                "supports_lyrics": False,
                "instrumental_only": True,
                "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
                "sample_rate": 44100,
                "outputs_per_job_max": 1,
                "est_seconds_per_audio_second": 0,
                "tasks": ["compose"],
                "est_realtime_factor": 0.05,
                "params": [
                    spec("prompt", "string", "Idea or ABC", None,
                         nullable=True),
                    spec("max_tokens", "int", "Length limit", 1024,
                         min=64, max=2048, internal=True),
                    spec("temperature", "float", "Variety", 0.7,
                         min=0.1, max=1.5, step=0.05),
                    *common,
                ],
            },
            "requirements": {"min_ram_bytes": 2 << 30, "disk_bytes": 0,
                             "speed_tier": "fast"},
            "license": {"name": "MIT", "commercial_use": True,
                        "requires_hf_token": False, "url": None},
            "notes": "Task model: composes notation.",
        },
    ]
    for m in models:
        m["tags"] = _derive_tags(m)
    return {m["id"]: m for m in models}


# How each generation fixture spends its "generating" band: (phase id, share of
# the band, step count). A None step count is the point of the fixture, not an
# omission — it is what a real adapter reports for a phase it cannot count, and
# the stub must exercise that shape as faithfully as the counted one. The
# splits below match what the real families can honestly say (contract 5.5):
# MusicGen counts tokens but not its encode or its file write; ACE-Step's Python
# runtime counts nothing at all, because its diffusion band comes from a timer
# thread; Stable Audio counts sampler steps.
#
# Task fixtures are deliberately absent: they declare no pipeline and fall back
# to a single unstaged band, which is the other case the app has to draw.
STUB_PHASES: dict[str, list[tuple[str, float, int | None]]] = {
    "musicgen-small": [("prompt_encode", 0.1, None),
                       ("lm_decode", 0.8, 500),
                       ("master", 0.1, None)],
    "acestep-base": [("lm_reasoning", 0.25, None),
                     ("prompt_encode", 0.05, None),
                     ("diffusion", 0.5, None),
                     ("vocoder", 0.1, None),
                     ("master", 0.1, None)],
    "stableaudio-small": [("prompt_encode", 0.1, None),
                          ("diffusion", 0.8, 8),
                          ("master", 0.1, None)],
}

# Which phase a preview-capable fixture publishes partial audio from, and
# whether its frames GROW. The two real shapes differ and the app has to draw
# both: a diffusion model decodes the whole clip from its first frame and only
# gets cleaner, while an autoregressive one has a second more of audio each
# time. Nothing else in the suite produces the growing case.
STUB_PREVIEW = {
    "musicgen-small": ("lm_decode", True),
    "stableaudio-small": ("diffusion", False),
}


def is_stream_preview(name: str) -> bool:
    """A streaming render preview, `preview-<n>.wav` — NOT a transcribe job's
    audition render, which is `preview-<track>.wav` in a directory of its own.
    Matching the whole name on digits is what keeps the sweep off those."""
    stem = name[len("preview-"):-len(".wav")] if (
        name.startswith("preview-") and name.endswith(".wav")) else ""
    return stem.isdigit()


# Mirrors scripts/build_catalog.py's derive_tags: usage-kind tags the Models
# screen offers as filter buttons. Derived rather than hardcoded so the stub
# stays faithful to how the real catalog is built.
_REMIX_PARAMS = {"src_audio", "init_audio", "reference_audio", "extend_audio",
                 "inpaint_audio", "task_type"}


def _derive_tags(entry: dict) -> list[str]:
    caps = entry["capabilities"]
    tasks = set(caps.get("tasks") or ["generate"])
    params = {p["key"] for p in caps["params"]}
    tags: list[str] = []
    if "generate" in tasks:
        tags.append("Songs with vocals" if caps.get("supports_lyrics")
                    else "Instrumental & loops")
        if "melody_audio" in params:
            tags.append("Melody-guided")
        if params & _REMIX_PARAMS:
            tags.append("Remix & restyle")
    if "separate" in tasks:
        tags.append("Stem separation")
    if tasks & {"transcribe", "render", "compose"}:
        tags.append("Notes & MIDI")
    if "analyze" in tasks:
        tags.append("Musical analysis")
    if "mix" in tasks:
        tags.append("Mixing & recombining")
    if "assist" in tasks:
        tags.append("Writing help")
    if tasks & {"caption", "lyrics", "tag"}:
        tags.append("Hears & describes")
    # The audio-transformation quartet, mirroring build_catalog: timbre and
    # re-amp rework existing audio; the voice tasks get their own word.
    if tasks & {"timbre", "reamp"}:
        tags.append("Remix & restyle")
    if tasks & {"convert-voice", "sing"}:
        tags.append("Voice & singing")
    # "plan" adds no tag, deliberately: planning is a step of a generate on a
    # model installed for generating, never a reason to install one.
    return tags


# ---------------------------------------------------------------- state


class EventBus:
    def __init__(self) -> None:
        self.next_id = 1
        self.ring: list[tuple[int, str, dict]] = []
        self.subscribers: set[asyncio.Queue] = set()

    def emit(self, event: str, data: dict) -> None:
        eid = self.next_id
        self.next_id += 1
        self.ring.append((eid, event, data))
        del self.ring[:-500]
        for q in list(self.subscribers):
            q.put_nowait((eid, event, data))


class Download:
    def __init__(self, model_id: str, total: int,
                 runtime_only: bool = False) -> None:
        self.id = f"dl_{uuid.uuid4().hex[:12]}"
        self.model_id = model_id
        self.total = total
        self.done = 0
        # promoted out of "queued" by pump_downloads once a slot is free
        self.state = "queued"
        # a runtime install has no weights to fetch, so it says so from the
        # moment it is accepted rather than deciding at dispatch
        self.runtime_only = runtime_only
        self.stage = "provisioning" if runtime_only else "weights"
        self.message = ""
        self.paused = asyncio.Event()
        self.paused.set()  # set = not paused
        self.task: asyncio.Task | None = None
        # Manual mode only: how many ticks have been granted but not yet
        # consumed. A counter rather than a bare Event because a test that
        # wants the transfer finished asks for all the remaining ticks at
        # once, and an Event cannot carry a number.
        self.steps_pending = 0
        self.step = asyncio.Event()

    async def await_step(self) -> None:
        """Block until a tick has been granted, then spend it."""
        while self.steps_pending <= 0:
            self.step.clear()
            await self.step.wait()
        self.steps_pending -= 1

    def info(self) -> dict:
        # nothing is transferring while provisioning or still waiting its turn,
        # so no rate is reported — the engine has none either (contract 4.2)
        moving = (self.paused.is_set() and self.stage != "provisioning"
                  and self.state != "queued")
        return {"download_id": self.id, "model_id": self.model_id,
                "state": "paused" if not self.paused.is_set() else self.state,
                "bytes_done": self.done, "bytes_total": self.total,
                # No wall clock in manual mode, so no rate to report — which
                # is also true of it: nothing is transferring between steps.
                "speed_bps": (0 if MANUAL_DOWNLOADS or not moving
                              else int(self.total / DOWNLOAD_SECONDS)),
                "stage": self.stage, "message": self.message,
                "runtime_only": self.runtime_only}


class Job:
    def __init__(self, group_id: str, model_id: str, body: dict,
                 duration_s: float | None, params: dict,
                 task: str = "generate", preview: bool = False) -> None:
        self.id = f"job_{uuid.uuid4().hex[:12]}"
        self.group_id = group_id
        self.model_id = model_id
        self.task = task
        self.preview = preview
        # explicit user run order; 0 = "no opinion" (contract 5.8)
        self.priority = 0
        self.prompt = (body.get("prompt") or "").strip()
        self.lyrics = body.get("lyrics")
        self.duration_s = duration_s
        self.count = int(body.get("count", 1))
        self.params = params
        self.status = "queued"
        self.progress: dict | None = None
        self.result: dict | None = None
        self.error: dict | None = None
        self.created_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.cancel_requested = False
        self.started_monotonic: float | None = None

    def info(self, queue_position: int | None) -> dict:
        return {"job_id": self.id, "group_id": self.group_id, "model_id": self.model_id,
                "task": self.task, "preview": self.preview,
                "priority": self.priority,
                "status": self.status, "queue_position": queue_position,
                "prompt": self.prompt, "lyrics": self.lyrics,
                "duration_s": self.duration_s, "count": self.count, "params": self.params,
                "created_at": self.created_at, "progress": self.progress,
                "result": self.result, "error": self.error}


class State:
    def __init__(self, output_dir: str) -> None:
        self.output_dir = output_dir
        self.models = _catalog()
        self.install: dict[str, dict] = {
            m: {"install_state": "not_installed", "installed_bytes": 0}
            for m in self.models
        }
        self.provisioned_families: set[str] = set()
        self.downloads: dict[str, Download] = {}
        self.download_pending: list[str] = []   # waiting for a slot, in order
        self.download_active: set[str] = set()
        self.jobs: dict[str, Job] = {}
        self.job_order: list[str] = []      # queued job ids, submission order
        self.queue_held = False
        # Contract 4.4: at most one library operation at a time.
        self.library_operation: dict | None = None
        self.library_cancel = False
        self.active_job: str | None = None
        self.hf_token: str | None = None
        self.pinned_model_id: str | None = None
        self.warm_model_id: str | None = None
        # warm pool, mirroring supervisor.jobqueue: family -> (model_id,
        # idle_since|None). None means "running right now".
        self.transient_models: dict[str, tuple[str, float | None]] = {}
        self.uploads: dict[str, int] = {}  # upload_id -> bytes
        self.bus = EventBus()
        self.runner: asyncio.Task | None = None
        self.telemetry: asyncio.Task | None = None
        self.wake = asyncio.Event()

    def model_info(self, mid: str) -> dict:
        return {**self.models[mid], **self.install[mid],
                "pinned": mid == self.pinned_model_id,
                "runtime_state": self.runtime_state(self.models[mid]["family"])}

    def runtime_state(self, family: str) -> str:
        """Contract 4.1: the family's adapter packages, reported per model.
        `installing` covers both a runtime install of its own and the
        provisioning step of a weights download — from the app's side they are
        the same wait."""
        if family in self.provisioned_families:
            return "installed"
        if any(d.stage == "provisioning"
               and self.models[d.model_id]["family"] == family
               for d in self.downloads.values()):
            return "installing"
        return "not_installed"

    def run_order(self) -> list[str]:
        """Queued jobs in the order they will run: highest explicit priority
        first, submission order within one priority (sorted() is stable)."""
        return sorted(self.job_order, key=lambda jid: -self.jobs[jid].priority)

    def queue_position(self, job_id: str) -> int | None:
        job = self.jobs[job_id]
        if job.status in ("succeeded", "failed", "canceled"):
            return None
        if job_id == self.active_job:
            return 0
        if job_id in self.job_order:
            return self.run_order().index(job_id) + (1 if self.active_job else 0)
        return None

    def announce_queue(self) -> None:
        """Re-publish every queued job's position after a reorder."""
        for jid in self.run_order():
            job = self.jobs[jid]
            self.bus.emit("job.queued",
                          {"job_id": job.id, "group_id": job.group_id,
                           "model_id": job.model_id,
                           "queue_position": self.queue_position(jid)})


STATE: State = None  # type: ignore[assignment]


def err(status: int, code: str, message: str, detail: dict | None = None) -> JSONResponse:
    return JSONResponse(status_code=status,
                        content={"error": {"code": code, "message": message,
                                           "detail": detail or {}}})


# ---------------------------------------------------------------- telemetry

# The figures the design draws its sidebar card with — 2.2 GB resident when
# idle, 11.8 GB and a busy GPU while rendering — so the app can be built
# against the numbers it was designed around.
IDLE_WORKER_BYTES = 2_200_000_000
BUSY_WORKER_BYTES = 11_800_000_000


@functools.lru_cache(maxsize=None)
def sysctl(name: str) -> str:
    """Cached: these cannot change while the process runs, and /v1/system is
    polled every few seconds."""
    return subprocess.check_output(["sysctl", "-n", name]).decode().strip()


def accelerator() -> dict:
    """Plausible rather than measured. The real machine's chip name, and a 75%
    working set, which is what macOS actually defaults to on Apple Silicon.

    Reported even with nothing loaded, where the real engine sends nulls (it
    cannot know the backend until a worker picks one) — the app must handle
    both, and the stub is the fixture that keeps the populated case on screen."""
    name = sysctl("machdep.cpu.brand_string")
    return {"name": name if name.startswith("Apple") else None,
            "backend": "metal",
            "working_set_bytes": int(int(sysctl("hw.memsize")) * 0.75)}


def usage() -> dict:
    """Nullable exactly where the engine's is: with no model loaded there is no
    worker to measure, and the app must draw no memory readout at all. GPU
    utilisation is device-wide, so it is reported either way."""
    busy = STATE.active_job is not None
    gpu = random.randint(86, 96) if busy else random.randint(0, 6)
    if not busy and STATE.warm_model_id is None and not warm_small_models():
        return {"gpu_percent": gpu, "worker_bytes": None,
                "accelerator_bytes": None}
    total = BUSY_WORKER_BYTES if busy else IDLE_WORKER_BYTES
    return {"gpu_percent": gpu, "worker_bytes": total,
            # weights dominate a worker's footprint but never account for all
            # of it, so the accelerator figure sits just under
            "accelerator_bytes": int(total * 0.86)}


async def telemetry_forever() -> None:
    """Contract 6: `system.telemetry` every 2 s while a job runs, every 10 s
    when idle, and nothing when no client is listening."""
    while True:
        await asyncio.sleep(2.0 if STATE.active_job else 10.0)
        if STATE.bus.subscribers:
            STATE.bus.emit("system.telemetry", usage())


# ---------------------------------------------------------------- wav synthesis


def write_wav(path: str, duration_s: float, sample_rate: int, base_freq: float) -> None:
    """A pleasant-ish deterministic test tone: sine + fifth with an envelope."""
    tmp = path + ".part"
    n = int(duration_s * sample_rate)
    with wave.open(tmp, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        frames = bytearray()
        for i in range(n):
            t = i / sample_rate
            env = min(1.0, t * 8) * min(1.0, (duration_s - t) * 8)
            beat = 0.6 + 0.4 * math.sin(2 * math.pi * 2.0 * t)
            s = env * beat * (0.5 * math.sin(2 * math.pi * base_freq * t)
                              + 0.3 * math.sin(2 * math.pi * base_freq * 1.5 * t))
            frames += struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32000))
        w.writeframes(bytes(frames))
    os.replace(tmp, path)


# ---------------------------------------------------------------- download simulation


def pump_downloads() -> None:
    """Start as many waiting downloads as the budget allows, oldest first
    (contract 4.2). Mirrors supervisor.downloader._pump, including deciding
    provisioning at dispatch — the download ahead may have already built the
    family's runtime."""
    st = STATE
    while len(st.download_active) < MAX_ACTIVE_DOWNLOADS and st.download_pending:
        dl = st.downloads.get(st.download_pending.pop(0))
        if dl is None:
            continue
        st.download_active.add(dl.id)
        family = st.models[dl.model_id]["family"]
        provisioning = dl.runtime_only or family not in st.provisioned_families
        dl.state = "provisioning" if provisioning else "downloading"
        dl.stage = "provisioning" if provisioning else "weights"
        # the message belongs to the dispatch event, not to the first progress
        # tick half a second later — a provisioning row draws message, not a bar
        dl.message = (f"Installing {family} runtime (stub)" if provisioning
                      else "fetching model.safetensors")
        st.bus.emit("download.progress", dl.info())
        dl.task = asyncio.create_task(run_download(dl))


async def run_download(dl: Download) -> None:
    st = STATE
    model = st.models[dl.model_id]
    try:
        if dl.stage == "provisioning":
            dl.message = f"Installing {model['family']} runtime (stub)"
            if MANUAL_DOWNLOADS:
                await dl.await_step()
                st.bus.emit("download.progress", dl.info())
            else:
                steps = int(PROVISION_SECONDS / 0.5)
                for _ in range(steps):
                    await dl.paused.wait()
                    await asyncio.sleep(0.5)
                    st.bus.emit("download.progress", dl.info())
            st.provisioned_families.add(model["family"])
            if dl.runtime_only:
                # no weights to fetch and no install marker to write: only the
                # family's runtime changed (contract 4.2)
                st.bus.emit("download.completed",
                            {"download_id": dl.id, "model_id": dl.model_id,
                             "runtime_only": True})
                st.bus.emit("models.changed", {})
                return
            dl.stage = "weights"
            dl.state = "downloading"
        # A gated repo with no token is the one failure that leaves nothing to
        # resume: the hub serves a README and refuses the weights, so the entry
        # stays "not_installed" rather than becoming "partial" (contract 4.1).
        if any(r.get("gated") for r in model["hf_repos"]) and not st.hf_token:
            st.install[dl.model_id] = {"install_state": "not_installed",
                                       "installed_bytes": 0}
            st.bus.emit("download.failed",
                        {"download_id": dl.id, "model_id": dl.model_id,
                         "error": {"code": "UNAUTHORIZED",
                                   "message": f"{model['hf_repos'][0]['repo_id']}"
                                              " is gated — add a Hugging Face"
                                              " token with access"}})
            st.bus.emit("models.changed", {})
            return
        dl.message = "fetching model.safetensors"
        tick = 0.5
        per_tick = (max(1, -(-dl.total // MANUAL_TICKS)) if MANUAL_DOWNLOADS
                    else int(dl.total / (DOWNLOAD_SECONDS / tick)))
        while dl.done < dl.total:
            # Paused first, in both modes: a granted tick is not spent while
            # the transfer is held, which is what makes "paused" mean the same
            # thing whether a clock or a test is driving it.
            await dl.paused.wait()
            if MANUAL_DOWNLOADS:
                await dl.await_step()
                # Held again after the grant, never mind the gate above: by the
                # time a pause arrives this coroutine is already sitting in
                # await_step, past that first check. Without this a tick granted
                # while paused would be spent by it, and "paused" would mean
                # nothing to anyone driving the transfer by hand. The tick is
                # not lost — it is banked and spent on resume, exactly as an
                # elapsed second is in the timed path.
                await dl.paused.wait()
            else:
                await asyncio.sleep(tick)
            dl.done = min(dl.total, dl.done + per_tick)
            st.install[dl.model_id]["installed_bytes"] = dl.done
            st.bus.emit("download.progress", dl.info())
        st.install[dl.model_id] = {"install_state": "installed",
                                   "installed_bytes": dl.total}
        st.bus.emit("download.completed",
                    {"download_id": dl.id, "model_id": dl.model_id,
                     "runtime_only": False})
        st.bus.emit("models.changed", {})
    except asyncio.CancelledError:
        # A cancelled runtime install leaves the weights exactly as they were —
        # calling that "partial" would offer "Resume download" for a transfer
        # nobody started.
        if not dl.runtime_only:
            st.install[dl.model_id] = {"install_state": "partial",
                                       "installed_bytes": dl.done}
        st.bus.emit("models.changed", {})
        raise
    finally:
        STATE.downloads.pop(dl.id, None)
        STATE.download_active.discard(dl.id)
        pump_downloads()


# ---------------------------------------------------------------- job runner


async def run_jobs_forever() -> None:
    st = STATE
    while True:
        # a hold stops the queue *starting* anything; the running job below is
        # never interrupted by it (contract 5.7)
        while not st.job_order or st.queue_held:
            st.wake.clear()
            await st.wake.wait()
        job_id = st.run_order()[0]
        st.job_order.remove(job_id)
        job = st.jobs[job_id]
        if job.status == "canceled":
            continue
        st.active_job = job_id
        model = st.models[job.model_id]
        try:
            await run_one_job(job, model)
        except asyncio.CancelledError:
            job.status = "canceled"
            st.bus.emit("job.canceled", {"job_id": job.id})
            st.active_job = None
            raise
        except Exception as e:  # noqa: BLE001 — stub: surface anything as job failure
            job.status = "failed"
            job.error = {"code": "INTERNAL", "message": str(e)}
            st.bus.emit("job.failed", {"job_id": job.id, "error": job.error})
        st.active_job = None
        # the small worker that just ran starts its idle clock; the pool keeps
        # it until the TTL runs out
        family = model["family"]
        if family in st.transient_models:
            mid, _ = st.transient_models[family]
            st.transient_models[family] = (mid, time.monotonic())
        warm_small_models()


async def run_one_job(job: Job, model: dict) -> None:
    st = STATE
    started = time.monotonic()
    job.started_monotonic = started
    st.bus.emit("job.started", {"job_id": job.id})

    # Index of the take being rendered, or None before the first one — the
    # engine reports it and the app counts takes with it, so the fixture has to
    # produce it or nothing exercises that path.
    take_index: int | None = None

    def emit(stage: str, fraction: float | None, message: str,
             phase: str | None = None, step: int | None = None,
             steps: int | None = None) -> None:
        if fraction is None:
            eta = None
        elif job.task != "generate":
            # contract 5.4: task ETA is elapsed-based, null below 5% progress
            eta = None
            if fraction >= 0.05:
                elapsed = time.monotonic() - started
                eta = round(max(0.0, elapsed * (1 - fraction) / fraction), 1)
        else:
            eta = round(max(0.0, (started + total_s) - time.monotonic()), 1)
        job.progress = {"stage": stage,
                        "fraction": None if fraction is None else round(fraction, 3),
                        "eta_s": eta, "message": message,
                        "phase": phase, "step": step, "steps": steps,
                        # which take is running, read from the loop below
                        # (contract 5.5) — null until the first one starts
                        "take": take_index}
        st.bus.emit("job.progress", {"job_id": job.id, **job.progress})

    out_dir = os.path.join(st.output_dir, job.id)
    os.makedirs(out_dir, exist_ok=True)
    sr = model["capabilities"]["sample_rate"]
    base_freq = 220.0 + (hash(job.model_id) % 5) * 55.0
    preview_phase, preview_grows = STUB_PREVIEW.get(job.model_id, (None, False))
    preview_n = 0

    async def write_preview(fraction: float, step_n: int | None) -> None:
        """One frame of partial audio, written as a real wav under the job's own
        output directory exactly as a worker's is (contract 5.6). `take` is the
        one being rendered, so a multi-take job's frames are attributable."""
        nonlocal preview_n
        full = float(job.duration_s or 4.0)
        dur = max(0.5, full * fraction) if preview_grows else full
        path = os.path.join(out_dir, f"preview-{preview_n}.wav")
        preview_n += 1
        await asyncio.to_thread(write_wav, path, dur, sr, base_freq)
        st.bus.emit("job.preview",
                    {"job_id": job.id, "take": take_index or 0, "path": path,
                     "sample_rate": sr, "duration_s": round(dur, 3),
                     "step": step_n})

    async def step(stage: str, seconds: float, f0: float, f1: float,
                   phase: str | None = None, steps: int | None = None) -> bool:
        ticks = max(1, int(seconds / 0.25))
        # sampled, not streamed: a preview costs a real decode in the engine,
        # so the fixture must not produce one per tick either
        preview_every = (max(1, ticks // 3)
                         if job.preview and phase == preview_phase else 0)
        for i in range(ticks):
            if job.cancel_requested:
                job.status = "canceled"
                st.bus.emit("job.canceled", {"job_id": job.id})
                return False
            frac = f0 + (f1 - f0) * (i + 1) / ticks
            # `steps` is None for a phase the real adapter cannot count, and
            # then no step number is invented either (contract 5.5)
            n = (i + 1) * steps // ticks if steps else None
            if steps:
                label = f"{phase} {n}/{steps}"
            elif phase:
                label = f"{phase} (no step count)"
            else:
                label = f"{stage} {i + 1}/{ticks}"
            emit(stage, frac, label, phase=phase, step=n, steps=steps)
            if preview_every and (i + 1) % preview_every == 0:
                await write_preview((i + 1) / ticks, n)
            await asyncio.sleep(0.25)
        return True

    sim_duration = job.duration_s if job.duration_s else 4.0
    gen_s = min(15.0, max(4.0, sim_duration * 0.4)) / JOB_SPEED
    total_s = 2.0 / JOB_SPEED + gen_s + 1.0

    job.status = "loading"
    st.bus.emit("job.log", {"job_id": job.id,
                            "line": f"loading {model['display_name']} (stub)"})
    # mirrors the engine's first event: a cold load has no fraction to report
    emit("loading", None, "preparing runtime")
    # Small models run in the transient slot: they never displace the resident
    # model and are never kept resident, so they emit no worker.state at all.
    small = is_small(model)
    if not small and st.warm_model_id != job.model_id:
        st.bus.emit("worker.state", {"state": "loading",
                                     "model_id": job.model_id,
                                     "family": model["family"]})
    if not await step("loading", 2.0 / JOB_SPEED, 0.0, 0.15):
        return
    if small:
        family = model["family"]
        if family not in st.transient_models:
            # make room, evicting the least recently used idle entry
            idle = [(v[1], f) for f, v in st.transient_models.items()
                    if v[1] is not None]
            while len(st.transient_models) >= max(0, SMALL_WARM_SLOTS) and idle:
                st.transient_models.pop(min(idle)[1], None)
                idle = [(v[1], f) for f, v in st.transient_models.items()
                        if v[1] is not None]
        st.transient_models[family] = (job.model_id, None)
    elif st.warm_model_id != job.model_id:
        # the model stays resident after the job (until unloaded or displaced)
        st.warm_model_id = job.model_id
        st.bus.emit("worker.state", {"state": "loaded",
                                     "model_id": job.model_id,
                                     "family": model["family"]})
    job.status = "generating"
    # Generate only: a task pass is opaque even on a model that stages its
    # generate flow (contract 5.4). acestep-base is in STUB_PHASES and now
    # also takes `plan` jobs, which must not report diffusion phases the
    # task will never run.
    plan = STUB_PHASES.get(job.model_id) if job.task == "generate" else None
    # One pass per take, as the engine does: `count` takes render one after
    # another and `fraction` is the average over all of them. The stub used to
    # run a single pass however many takes were asked for, so nothing here or
    # in the app ever saw a take boundary.
    takes = max(1, job.count)
    span = 0.75 / takes
    for take_index in range(takes):
        base = 0.15 + span * take_index
        if plan:
            # Five of the nine real generation families open every take with
            # `progress_cb(None, "encoding prompt", phase="prompt_encode")` — so
            # "generating, no fraction, but a named phase" is the state the
            # engine spends the first moment of each take in. The stub used to
            # jump straight to a real fraction, which meant neither suite nor
            # any UI work against the stub ever saw it.
            emit("generating", None, "encoding prompt", phase=plan[0][0])
            await asyncio.sleep(0.25)
            lo = base
            for phase, share, phase_steps in plan:
                hi = lo + span * share
                if not await step("generating", gen_s * share / takes, lo, hi,
                                  phase=phase, steps=phase_steps):
                    return
                lo = hi
        elif not await step("generating", gen_s / takes, base, base + span):
            return
    job.status = "encoding"
    if not await step("encoding", 1.0 / JOB_SPEED, 0.9, 1.0):
        return

    if job.task != "generate":
        artifacts, meta = await make_task_artifacts(job, out_dir, sr)
        job.result = {"artifacts": artifacts, "meta": meta,
                      "timings": {"total_s": round(time.monotonic() - started, 2)}}
    else:
        # ACE-Step's generate runs its 5 Hz LM half before the DiT, and what
        # the LM decided rides the result as `meta` — job-level and per-output,
        # the same keys a `plan` job returns. Omitted for src-audio tasks,
        # which skip the LM, and for every other family, whose adapters supply
        # no meta at all — absence is the normal case (contract 5.2).
        gen_meta = None
        if (model["family"] == "acestep"
                and str(job.params.get("task_type") or "text2music")
                == "text2music"):
            gen_meta = {
                "lm_metadata": {
                    "bpm": 104,
                    "caption": job.prompt,
                    "duration": int(job.duration_s or 60),
                    "genres": "synthwave, electronic",
                    "keyscale": str(job.params.get("keyscale") or "A minor"),
                    "language": "english",
                    "timesignature": str(job.params.get("timesignature")
                                         or "4/4"),
                },
                # a reused plan's codes come back as submitted, so a client
                # can see its chosen plan flow through
                "audio_codes": str(job.params.get("audio_codes")
                                   or canned_audio_codes()),
                "planner": "acestep-5hz-lm",
            }
        outputs = []
        for i in range(job.count):
            path = os.path.join(out_dir, f"take-{i}.wav")
            await asyncio.to_thread(write_wav, path, job.duration_s, sr,
                                    base_freq * (1 + 0.25 * i))
            seed = job.params.get("seed")
            output = {"path": path, "format": "wav", "sample_rate": sr,
                      "duration_s": float(job.duration_s),
                      "seed_used": seed if seed is not None
                      else secrets.randbelow(2**31)}
            if gen_meta is not None:
                output["meta"] = gen_meta
            outputs.append(output)
        job.result = {"outputs": outputs,
                      "timings": {"total_s": round(time.monotonic() - started, 2),
                                  "load_s": 2.0, "generate_s": gen_s}}
        if gen_meta is not None:
            job.result["meta"] = gen_meta
        # a succeeded take makes its previews dead weight; only a cancel the
        # user asked to keep ever wants them (contract 5.6)
        for name in os.listdir(out_dir):
            if is_stream_preview(name):
                os.unlink(os.path.join(out_dir, name))
    job.status = "succeeded"
    job.progress = {"stage": "encoding", "fraction": 1.0, "eta_s": 0.0,
                    "message": "done", "phase": None, "step": None,
                    "steps": None}
    st.bus.emit("job.completed", {"job_id": job.id})


CANNED_ANALYSIS = {
    "tempo_bpm": 120.0,
    "beats": [round(i * 0.5, 2) for i in range(8)],
    "downbeats": [0.0, 2.0],
    "key": "C major",
    "camelot": "8B",
    "lufs": -14.0,
    "sections": [{"start_s": 0.0, "end_s": 2.0, "group": "A"},
                 {"start_s": 2.0, "end_s": 4.0, "group": "B"}],
}


# One plausible `value` per assist kind, in exactly the shapes the app reads —
# the shapes are the engine's contract, the words are canned.
CANNED_ASSIST: dict[str, dict[str, Any]] = {
    "interview": {
        "questions": [
            {"question": "What mood are you after?",
             "examples": ["dreamy", "driving", "melancholy"]},
            {"question": "Any instrument that has to be there?",
             "examples": ["saxophone", "analog synths", "brushed drums"]},
        ],
        "ready": False,
    },
    "interview_finish": {
        "prompt": "dreamy synthwave with breathy saxophone, 100 BPM"},
    "flesh_out": {
        "prompt": "dreamy synthwave with breathy saxophone, tape saturation,"
                  " slow chorus pads, 100 BPM",
        "added": ["tape saturation", "slow chorus pads"]},
    "lyrics": {
        "lyrics": "[verse]\nNeon rain on the boulevard\nEvery light a falling"
                  " star\n[chorus]\nDrive on, drive on through the glow",
        "title": "Neon Rain"},
    "pick_model": {
        "best": {"id": "acestep-base",
                 "why": "vocals and full-song structure", "installed": True},
        "alternatives": [{"id": "musicgen-small",
                          "why": "fast instrumental sketches",
                          "installed": False}]},
    "plan_song": {
        "sections": [
            {"tag": "[intro]", "seconds": 8, "what": "pads fade in"},
            {"tag": "[verse]", "seconds": 24, "what": "main theme, light"
                                                      " drums"},
            {"tag": "[chorus]", "seconds": 16, "what": "full band, hook"},
            {"tag": "[outro]", "seconds": 12, "what": "pads fade out"},
        ],
        "summary": "60 s arc from pads to a full-band hook and back"},
    "route_intent": {
        "action": "generate", "prompt": "dreamy synthwave with saxophone",
        "subject": None, "confidence": 0.92,
        "reason": "the request names a new song to make"},
    "brief": {
        "prompt": "dreamy synthwave with breathy saxophone, 100 BPM",
        "idea": "a night drive that slowly turns hopeful",
        "title": "Night Drive"},
    "translate_lyrics": {
        "lyrics": "[verse]\nLluvia de neón en el bulevar\nCada luz una"
                  " estrella fugaz",
        "title": "Lluvia de Neón"},
    "describe_song": {
        "description": "A mid-tempo synthwave piece led by a breathy"
                       " saxophone over analog pads.",
        "prompt": "mid-tempo synthwave, lead saxophone, analog pads"},
    "more_like_this": {
        "variations": [
            {"prompt": "dreamy synthwave with muted trumpet",
             "differs": "trumpet takes the saxophone's place"},
            {"prompt": "driving synthwave with saxophone, 120 BPM",
             "differs": "faster and more insistent"},
            {"prompt": "dreamy synthwave with saxophone and rain foley",
             "differs": "adds a rain texture under the pads"},
        ]},
    "critique_fix": {
        "prompt": "dreamy synthwave with breathy saxophone, tighter low end,"
                  " wider stereo pads",
        "changes": [{"from": "muddy low end", "to": "tighter low end"},
                    {"from": "narrow pads", "to": "wider stereo pads"}]},
    "name_and_tag": {
        "title": "Neon Rain",
        "tags": ["synthwave", "saxophone", "dreamy", "retro"]},
}


def canned_audio_codes(offset: int = 0) -> str:
    """A plausible 5 Hz token string; `offset` keeps sibling plans distinct."""
    start = 1 + offset * 8
    return "".join(f"<|audio_code_{n}|>" for n in range(start, start + 8))


async def make_task_artifacts(job: Job, out_dir: str,
                              sr: int) -> tuple[list[dict], dict]:
    """Artifacts per contract 5.4, written complete before job.completed."""
    dur = 4.0
    if job.task == "separate":
        stems = [("vocals", 440.0), ("drums", 110.0),
                 ("bass", 55.0), ("other", 330.0)]
        artifacts = []
        for name, freq in stems:
            path = os.path.join(out_dir, f"{name}.wav")
            await asyncio.to_thread(write_wav, path, dur, sr, freq)
            artifacts.append({"kind": "stem", "label": name, "path": path,
                              "format": "wav", "sample_rate": sr,
                              "duration_s": dur})
        return artifacts, {}
    if job.task in ("timbre", "reamp", "convert-voice", "sing"):
        # Contract 5.4: the audio-transformation quartet returns ONE stem
        # artifact — the transformed audio — which the app's split ingest
        # files as a part of the source song.
        label = {"timbre": "timbre", "reamp": "reamped",
                 "convert-voice": "converted", "sing": "sung"}[job.task]
        path = os.path.join(out_dir, f"{label}.wav")
        await asyncio.to_thread(write_wav, path, dur, sr, 392.0)
        return [{"kind": "stem", "label": label, "path": path,
                 "format": "wav", "sample_rate": sr, "duration_s": dur}], {}
    if job.task == "analyze":
        path = os.path.join(out_dir, "analysis.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(CANNED_ANALYSIS, f)
        os.replace(tmp, path)
        artifacts = [{"kind": "analysis", "label": "analysis", "path": path,
                      "format": "json", "sample_rate": None, "duration_s": None}]
        meta = {"tempo_bpm": CANNED_ANALYSIS["tempo_bpm"],
                "key": CANNED_ANALYSIS["key"],
                "camelot": CANNED_ANALYSIS["camelot"]}
        return artifacts, meta
    if job.task == "mix":
        # The container/bit-depth choice changes the artifact's declared format
        # and extension (contract 5.4). The payload stays a WAV sine — the stub
        # simulates the wire shape, not the codec — but a float32 FLAC is
        # refused exactly as the real worker refuses it, so clients can test
        # their validation against the same failure.
        fmt = str(job.params.get("output_format") or "wav")
        depth = str(job.params.get("bit_depth") or "pcm16")
        if fmt == "flac" and depth == "float32":
            raise RuntimeError("flac cannot hold 32-bit float samples")
        path = os.path.join(out_dir, f"mixdown.{fmt}")
        await asyncio.to_thread(write_wav, path, dur, sr, 262.0)
        artifacts = [{"kind": "audio", "label": "mixdown", "path": path,
                      "format": fmt, "sample_rate": sr, "duration_s": dur}]
        if job.params.get("keep_tracks"):
            spec_tracks = json.loads(job.params["mix_spec"]).get("tracks") or []
            for i, track in enumerate(spec_tracks):
                role = str(track.get("role") or f"track-{i}")
                stem_path = os.path.join(out_dir, f"{role}.wav")
                await asyncio.to_thread(write_wav, stem_path, dur, sr, 330.0)
                artifacts.append({"kind": "stem", "label": role,
                                  "path": stem_path, "format": "wav",
                                  "sample_rate": sr, "duration_s": dur})
        meta = {}
        if job.params.get("normalize", True):
            meta["lufs"] = float(job.params.get("target_lufs") or -14.0)
        return artifacts, meta
    if job.task == "transcribe":
        artifacts = []
        counts = {}
        for label, freq in (("melody", 523.0), ("drums", 98.0)):
            midi_path = os.path.join(out_dir, f"{label}.mid")
            with open(midi_path + ".part", "wb") as f:
                f.write(minimal_smf())
            os.replace(midi_path + ".part", midi_path)
            artifacts.append({"kind": "midi", "label": label,
                              "path": midi_path, "format": "mid",
                              "sample_rate": None, "duration_s": None})
            wav_path = os.path.join(out_dir, f"preview-{label}.wav")
            await asyncio.to_thread(write_wav, wav_path, dur, sr, freq)
            artifacts.append({"kind": "audio", "label": f"preview:{label}",
                              "path": wav_path, "format": "wav",
                              "sample_rate": sr, "duration_s": dur})
            counts[label] = 4
        return artifacts, {"tracks": counts}
    if job.task == "render":
        path = os.path.join(out_dir, "render.wav")
        await asyncio.to_thread(write_wav, path, dur, sr, 349.0)
        return [{"kind": "audio", "label": "render", "path": path,
                 "format": "wav", "sample_rate": sr, "duration_s": dur}], {}
    if job.task == "assist":
        kind = str(job.params.get("kind") or "interview")
        canned = CANNED_ASSIST.get(kind)
        if canned is None:
            raise RuntimeError(f"stub has no canned assist for kind '{kind}'")
        value = json.loads(json.dumps(canned))  # per-job copy, never shared
        # `assist_input` is a json param: a JSON-encoded string on the wire.
        # A malformed one fails the job here, as the real worker's parse would.
        assist_input = json.loads(job.params["assist_input"])
        asked = (str(assist_input.get("prompt") or "").strip()
                 if isinstance(assist_input, dict) else "")
        if asked and isinstance(value.get("prompt"), str):
            # the canned answer stays canned, but opens with what it was asked
            # about, so app work against the stub sees its input flow through
            value["prompt"] = f"{asked}, {value['prompt']}"
        target_family = job.params.get("target_family")
        payload = {"kind": kind, "ok": True, "raw": json.dumps(value),
                   "value": value, "repaired": False,
                   "target_family": target_family,
                   "dialect": str(target_family) if target_family
                   else "generic"}
        path = os.path.join(out_dir, "assist.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
        artifacts = [{"kind": "assist", "label": kind, "path": path,
                      "format": "json", "sample_rate": None,
                      "duration_s": None}]
        elapsed = time.monotonic() - (job.started_monotonic
                                      or time.monotonic())
        return artifacts, {"assist": payload, "elapsed_s": round(elapsed, 2)}
    if job.task == "plan":
        count = max(1, min(6, int(job.params.get("plan_count") or 3)))
        caption = str(job.params.get("plan_caption") or job.prompt
                      or "dreamy synthwave with saxophone")
        plan_dur = job.params.get("plan_duration_s")
        duration = int(float(plan_dur)) if plan_dur is not None else 60
        plans = []
        for i in range(count):
            # every metadata key present, varied per plan — the real LM's
            # chain-of-thought may omit any subset of them
            metadata = {"bpm": 96 + 8 * i,
                        "caption": caption,
                        "duration": duration,
                        "genres": "synthwave, electronic",
                        "keyscale": str(job.params.get("keyscale")
                                        or "A minor"),
                        "language": "english",
                        "timesignature": str(job.params.get("timesignature")
                                             or "4/4")}
            plans.append({"index": i, "metadata": metadata,
                          "audio_codes": canned_audio_codes(i)})
        path = os.path.join(out_dir, "plans.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump({"plans": plans}, f)
        os.replace(tmp, path)
        artifacts = [{"kind": "plan", "label": "plans", "path": path,
                      "format": "json", "sample_rate": None,
                      "duration_s": None}]
        return artifacts, {"plans": plans}
    if job.task == "caption":
        question = job.params.get("question")
        text = ("It sits in A minor with the hats pushed forward."
                if question else
                "A dreamy lo-fi hip hop beat with vinyl crackle, dusty "
                "Rhodes chords and a lazy swung drum loop.")
        payload = {"text_version": 1, "kind": "caption", "text": text,
                   "question": question, "model": job.model_id,
                   "engine": "stub"}
        artifacts = [write_text_artifact(out_dir, "caption", payload)]
        meta = {"text": payload, "caption_preview": text[:200]}
        if question:
            meta["question"] = question
        return artifacts, meta
    if job.task == "lyrics":
        segments = [{"start_s": 0.0, "end_s": 2.0, "text": "la la la"},
                    {"start_s": 2.0, "end_s": 4.0, "text": "ooh ooh"}]
        text = "\n".join(s["text"] for s in segments)
        payload = {"text_version": 1, "kind": "lyrics", "text": text,
                   "language": str(job.params.get("language") or "en"),
                   "segments": segments, "model": job.model_id,
                   "engine": "stub"}
        artifacts = [write_text_artifact(out_dir, "lyrics", payload)]
        return artifacts, {"text": payload, "language": payload["language"],
                           "segments": len(segments),
                           "lyrics_preview": text[:200]}
    if job.task == "tag":
        tags = [{"label": "techno", "score": 0.83, "group": "genre"},
                {"label": "dark", "score": 0.71, "group": "mood"},
                {"label": "synthesizer", "score": 0.66,
                 "group": "instrument"}]
        payload = {"text_version": 1, "kind": "tags", "tags": tags,
                   "model": job.model_id, "engine": "stub"}
        artifacts = [write_text_artifact(out_dir, "tags", payload)]
        return artifacts, {"text": payload,
                           "top_tags": [t["label"] for t in tags]}
    if job.task == "compose":
        # The prompt is a string param, which submit validation does not
        # presence-check — so the "adapter" fails the job on emptiness, as
        # the real notation worker does.
        idea = str(job.params.get("prompt") or "").strip()
        if not idea:
            raise RuntimeError("prompt missing — nothing to compose from")
        abc = ("X:1\nT:Stub Tune\nM:4/4\nL:1/8\nK:C\n"
               "CDEF GABc | c2 G2 E2 C2 |\n")
        payload = {"text_version": 1, "kind": "abc", "text": abc,
                   "model": job.model_id, "engine": "stub"}
        artifacts = [write_text_artifact(out_dir, "abc", payload)]
        midi_path = os.path.join(out_dir, "composition.mid")
        with open(midi_path + ".part", "wb") as f:
            f.write(minimal_smf())
        os.replace(midi_path + ".part", midi_path)
        artifacts.append({"kind": "midi", "label": "composition",
                          "path": midi_path, "format": "mid",
                          "sample_rate": None, "duration_s": None})
        return artifacts, {"text": payload, "notes": 8,
                           "abc_preview": abc[:200]}
    raise RuntimeError(f"stub has no simulation for task '{job.task}'")


def write_text_artifact(out_dir: str, label: str, payload: dict) -> dict:
    """One `text` artifact per contract 5.4, written complete (tmp+rename)."""
    path = os.path.join(out_dir, f"{label}.json")
    tmp = path + ".part"
    with open(tmp, "w") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp, path)
    return {"kind": "text", "label": label, "path": path, "format": "json",
            "sample_rate": None, "duration_s": None}


def minimal_smf() -> bytes:
    """A valid single-track SMF: 4 quarter notes of middle C at 120 BPM."""
    events = b""
    for _ in range(4):
        events += bytes([0x00, 0x90, 60, 90])        # noteon, delta 0
        events += bytes([0x60, 0x80, 60, 0])         # noteoff, delta 96
    track = events + bytes([0x00, 0xFF, 0x2F, 0x00])  # end of track
    header = b"MThd" + (6).to_bytes(4, "big") + \
        (0).to_bytes(2, "big") + (1).to_bytes(2, "big") + (96).to_bytes(2, "big")
    return header + b"MTrk" + len(track).to_bytes(4, "big") + track


# ---------------------------------------------------------------- app


@asynccontextmanager
async def lifespan(app: FastAPI):
    STATE.runner = asyncio.create_task(run_jobs_forever())
    STATE.telemetry = asyncio.create_task(telemetry_forever())
    yield
    STATE.runner.cancel()
    STATE.telemetry.cancel()


app = FastAPI(lifespan=lifespan)
AUTH_TOKEN = ""


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    if request.url.path != "/healthz":
        if request.headers.get("authorization") != f"Bearer {AUTH_TOKEN}":
            return err(401, "UNAUTHORIZED", "missing or invalid bearer token")
    return await call_next(request)


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "version": VERSION,
            "uptime_s": round(time.monotonic() - STARTED_AT, 1)}


@app.get("/v1/system")
async def system():
    ram = int(sysctl("hw.memsize"))
    active = STATE.active_job
    warm = STATE.models[STATE.jobs[active].model_id]["family"] if active else None
    return {"ram_bytes": ram,
            "free_disk_bytes": shutil.disk_usage(STATE.output_dir).free,
            "machine": sysctl("hw.model"), "warm_family": warm,
            "warm_model_id": STATE.warm_model_id,
            "transient_model_ids": warm_small_models(),
            "pinned_model_id": STATE.pinned_model_id,
            "active_job_id": active,
            "queue_held": STATE.queue_held,
            "memory_guard": {"limit_bytes": int(ram * 0.9),
                             "worker_bytes": 1 << 30 if active else None},
            "accelerator": accelerator(),
            "usage": usage(),
            "engine_versions": {"python": sys.version.split()[0],
                                "supervisor": VERSION + "+stub"}}


@app.post("/v1/shutdown", status_code=202)
async def shutdown():
    asyncio.get_running_loop().call_later(0.2, lambda: os.kill(os.getpid(), signal.SIGTERM))
    return {}


# ----- model library (contract 4.4)
#
# Simulated, like the downloads are: the stub has no cache directory and no
# bytes to move. It answers from the same install state the rest of the stub
# keeps, so the Settings group draws real numbers that respond to a simulated
# download — and the two long operations run on a timer rather than on files.


LIBRARY_ROOT = os.path.expanduser("~/.cache/huggingface")


def _library_repos():
    """Our repos with simulated bytes, from the stub's own install state."""
    out = []
    for mid, model in STATE.models.items():
        install = STATE.install[mid]
        if install["install_state"] not in ("installed", "partial"):
            continue
        for repo in model["hf_repos"]:
            out.append({
                "repo_id": repo["repo_id"],
                "path": os.path.join(LIBRARY_ROOT, "hub",
                                     "models--" + repo["repo_id"].replace("/", "--")),
                "bytes": install["installed_bytes"] or model["size_bytes"],
                "state": ("installed"
                          if install["install_state"] == "installed"
                          else "partial"),
                "model_ids": [mid],
            })
    return out


@app.get("/v1/models/library")
async def library_info():
    repos = _library_repos()
    ours = sum(r["bytes"] for r in repos)
    installed = sum(r["bytes"] for r in repos if r["state"] == "installed")
    usage = shutil.disk_usage(os.path.expanduser("~"))
    return {
        "path": LIBRARY_ROOT,
        "is_default": True,
        "bytes": ours,
        "installed_bytes": installed,
        "partial_bytes": ours - installed,
        # Deliberately larger than ours: the shared cache is the default, and a
        # client that only ever sees the two figures equal will not have drawn
        # the "other tools" row it is supposed to.
        "folder_bytes": ours + 4_000_000_000,
        "model_count": sum(1 for r in repos if r["state"] == "installed"),
        "partial_count": sum(1 for r in repos if r["state"] == "partial"),
        "disk_total_bytes": usage.total,
        "disk_free_bytes": usage.free,
        "repos": repos,
        "operation": STATE.library_operation,
    }


@app.get("/v1/models/library/verify")
async def library_verify():
    models = [{"model_id": mid, "display_name": m["display_name"],
               "state": "ok",
               "expected_bytes": STATE.install[mid]["installed_bytes"],
               "actual_bytes": STATE.install[mid]["installed_bytes"]}
              for mid, m in STATE.models.items()
              if STATE.install[mid]["install_state"] == "installed"]
    return {"checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "models": models, "problem_count": 0,
            "partial_repos": [r for r in _library_repos()
                              if r["state"] == "partial"]}


async def _run_library_operation(op: dict) -> None:
    """Six ticks of simulated work, so a client's progress bar is exercised."""
    total = op["bytes_total"]
    for step in range(1, 7):
        await asyncio.sleep(0.25)
        if STATE.library_cancel:
            op["canceled"] = True
            break
        op["bytes_done"] = int(total * step / 6)
        op["fraction"] = step / 6
        STATE.bus.emit("library.progress", dict(op))
    op["state"] = "succeeded"
    op["fraction"] = 1.0
    op["message"] = "done"
    if op["mode"] == "clear":
        wanted = ("partial",) if op.get("scope") == "partial" else (
            "installed", "partial")
        for mid in list(STATE.models):
            if STATE.install[mid]["install_state"] in wanted:
                STATE.install[mid] = {"install_state": "not_installed",
                                      "installed_bytes": 0}
        op["removed_model_ids"] = []
    STATE.bus.emit("library.completed", dict(op))
    STATE.bus.emit("models.changed", {})


def _start_library_operation(mode: str, **plan):
    if STATE.library_operation and STATE.library_operation["state"] == "running":
        return None
    if any(d["state"] in ("queued", "downloading") for d in STATE.downloads.values()):
        return err(409, "DOWNLOAD_ACTIVE", "finish or cancel the downloads first")
    if any(j["status"] not in ("succeeded", "failed", "canceled")
           for j in STATE.jobs.values()):
        return err(409, "ENGINE_BUSY", "finish or cancel the queued renders first")
    STATE.library_cancel = False
    op = {"operation_id": f"lib_{uuid.uuid4().hex[:12]}", "mode": mode,
          "state": "running", "fraction": 0.0, "bytes_done": 0,
          "error": None, "canceled": False, **plan}
    STATE.library_operation = op
    asyncio.create_task(_run_library_operation(op))
    return {"operation_id": op["operation_id"]}


@app.post("/v1/models/library/clear", status_code=202)
async def library_clear(body: dict | None = None):
    scope = (body or {}).get("scope") or "all"
    if scope not in ("all", "partial"):
        return err(422, "VALIDATION", 'scope must be "all" or "partial"')
    repos = [r for r in _library_repos()
             if scope == "all" or r["state"] == "partial"]
    if not repos:
        return err(409, "LIBRARY_EMPTY",
                   "there are no unfinished downloads in this folder"
                   if scope == "partial"
                   else "there is nothing of ours in this folder")
    started = _start_library_operation(
        "clear", bytes_total=sum(r["bytes"] for r in repos), scope=scope,
        message=f"removing {len(repos)} repositories", repo_count=len(repos))
    if started is None:
        return err(409, "LIBRARY_BUSY", "a library operation is already running")
    return started


@app.post("/v1/models/library/relocate", status_code=202)
async def library_relocate(body: dict):
    path = (body.get("path") or "").strip()
    disposition = body.get("disposition") or "move"
    if not path:
        return err(422, "VALIDATION", "path is required")
    if disposition not in ("move", "delete", "leave"):
        return err(422, "VALIDATION", "unknown disposition")
    # expanduser on both sides: a client sending "~/.cache/huggingface" means
    # the same folder the engine reports, and the real engine treats it so.
    if (os.path.abspath(os.path.expanduser(path))
            == os.path.abspath(os.path.expanduser(LIBRARY_ROOT))):
        return err(422, "VALIDATION", "that is already the library folder")
    repos = [] if disposition == "leave" else _library_repos()
    started = _start_library_operation(
        "relocate", bytes_total=sum(r["bytes"] for r in repos),
        message="moving models", destination=os.path.abspath(path),
        disposition=disposition, repo_count=len(repos),
        restart_required=True)
    if started is None:
        return err(409, "LIBRARY_BUSY", "a library operation is already running")
    return started


@app.post("/v1/models/library/cancel", status_code=202)
async def library_cancel():
    STATE.library_cancel = True
    return {}


# ----- models


@app.get("/v1/models")
async def models_list():
    return {"models": [STATE.model_info(m) for m in STATE.models]}


@app.get("/v1/models/{mid}")
async def models_get(mid: str):
    if mid not in STATE.models:
        return err(404, "NOT_FOUND", f"unknown model {mid}")
    return STATE.model_info(mid)


@app.put("/v1/models/{mid}/pin", status_code=202)
async def models_pin(mid: str, body: dict):
    if mid not in STATE.models:
        return err(404, "NOT_FOUND", f"unknown model {mid}")
    enabled = bool(body.get("enabled"))
    if enabled and STATE.install[mid]["install_state"] != "installed":
        return err(409, "MODEL_NOT_INSTALLED", f"{mid} is not installed")
    family = STATE.models[mid]["family"]
    if enabled:
        STATE.pinned_model_id = mid
        STATE.bus.emit("worker.state", {"state": "loading", "model_id": mid,
                                        "family": family})
        STATE.warm_model_id = mid
        STATE.bus.emit("worker.state", {"state": "loaded", "model_id": mid,
                                        "family": family})
    elif STATE.pinned_model_id == mid:
        # unpin removes the guarantee only; the model stays resident
        STATE.pinned_model_id = None
    STATE.bus.emit("models.changed", {})
    return {}


@app.post("/v1/worker/unload", status_code=202)
async def worker_unload():
    if STATE.active_job is not None or STATE.job_order:
        return err(409, "ENGINE_BUSY", "a job is queued or running")
    mid = STATE.warm_model_id
    STATE.pinned_model_id = None if STATE.pinned_model_id == mid else STATE.pinned_model_id
    STATE.warm_model_id = None
    STATE.transient_models.clear()
    if mid:
        STATE.bus.emit("worker.state", {
            "state": "stopped", "model_id": mid,
            "family": STATE.models[mid]["family"] if mid in STATE.models else None})
    return {}


@app.delete("/v1/models/{mid}", status_code=202)
async def models_delete(mid: str):
    if mid not in STATE.models:
        return err(404, "NOT_FOUND", f"unknown model {mid}")
    if any(d.model_id == mid for d in STATE.downloads.values()):
        return err(409, "DOWNLOAD_ACTIVE", "cancel the download first")
    used = any(j.model_id == mid and j.status not in ("succeeded", "failed", "canceled")
               for j in STATE.jobs.values())
    if used:
        return err(409, "MODEL_IN_USE", "a queued or running job uses this model")
    STATE.install[mid] = {"install_state": "not_installed", "installed_bytes": 0}
    # The runtime goes with the last model of its family (contract 4.1): it is
    # the larger half of some families, so leaving it behind would keep most of
    # the space the delete was for.
    family = STATE.models[mid]["family"]
    if not any(STATE.models[other]["family"] == family
               and STATE.install[other]["install_state"] == "installed"
               for other in STATE.models):
        STATE.provisioned_families.discard(family)
    STATE.bus.emit("models.changed", {})
    return {}


@app.post("/v1/models/inspect")
async def models_inspect(body: dict):
    repo = body.get("repo_id", "")
    return err(422, "UNSUPPORTED_MODEL",
               f"stub cannot inspect '{repo}' — arbitrary models arrive post-MVP")


@app.post("/v1/settings/hf-token", status_code=204)
async def hf_token(body: dict):
    STATE.hf_token = body.get("token")
    return None


# ----- downloads


@app.post("/v1/models/{mid}/download", status_code=202)
async def download_start(mid: str):
    if mid not in STATE.models:
        return err(404, "NOT_FOUND", f"unknown model {mid}")
    for d in STATE.downloads.values():
        if d.model_id == mid:
            return {"download_id": d.id}
    model = STATE.models[mid]
    need = model["requirements"]["disk_bytes"] * 1.2
    if shutil.disk_usage(STATE.output_dir).free < need:
        return err(409, "INSUFFICIENT_DISK", "not enough free disk space",
                   {"needed_bytes": int(need)})
    dl = Download(mid, model["size_bytes"])
    dl.done = STATE.install[mid]["installed_bytes"]  # resume from partial
    STATE.downloads[dl.id] = dl
    STATE.download_pending.append(dl.id)
    STATE.install[mid]["install_state"] = "downloading"
    STATE.bus.emit("models.changed", {})
    # announced on arrival: pump_downloads only emits for what it starts, so a
    # download waiting its turn would otherwise be invisible to the stream
    STATE.bus.emit("download.progress", dl.info())
    # synchronous, so a GET issued straight after this POST already sees the
    # right state
    pump_downloads()
    return {"download_id": dl.id}


# Test-only, and registered ONLY in manual mode — the contract has no such
# endpoint and the real engine will never grow one. Keeping the decorator
# inside the `if` is what makes that enforceable rather than a promise:
# scripts/verify_stub.py asserts it 404s in an ordinary run, so this surface
# cannot quietly become part of the fixture everything else is verified against.
if MANUAL_DOWNLOADS:
    @app.post("/v1/downloads/{did}/_step", status_code=202)
    async def download_step(did: str, ticks: int = 1):
        """Grant `ticks` units of progress to a download that is waiting.

        Returns the download's info so a caller can drive the transfer without
        a round-trip to GET /v1/downloads between every step.
        """
        d = STATE.downloads.get(did)
        if not d:
            return err(404, "NOT_FOUND", "unknown download")
        d.steps_pending += max(1, ticks)
        d.step.set()
        return d.info()


@app.post("/v1/models/{mid}/runtime", status_code=202)
async def runtime_install(mid: str):
    """Install the family runtime alone, for a model whose weights are already
    here (contract 4.2)."""
    if mid not in STATE.models:
        return err(404, "NOT_FOUND", f"unknown model {mid}")
    family = STATE.models[mid]["family"]
    # one install per family: a second model of the same family joins the one
    # already running rather than queueing a duplicate behind it
    for d in STATE.downloads.values():
        if d.stage == "provisioning" and STATE.models[d.model_id]["family"] == family:
            return {"download_id": d.id}
        if d.model_id == mid:
            return {"download_id": d.id}
    dl = Download(mid, 0, runtime_only=True)
    STATE.downloads[dl.id] = dl
    STATE.download_pending.append(dl.id)
    STATE.bus.emit("models.changed", {})
    STATE.bus.emit("download.progress", dl.info())
    pump_downloads()
    return {"download_id": dl.id}


@app.get("/v1/downloads")
async def downloads_list():
    return {"downloads": [d.info() for d in STATE.downloads.values()]}


@app.post("/v1/downloads/{did}/pause", status_code=202)
async def download_pause(did: str):
    d = STATE.downloads.get(did)
    if not d:
        return err(404, "NOT_FOUND", "unknown download")
    # accepted and ignored while provisioning or still queued, as in the
    # engine: `uv sync` cannot be suspended, and a download that has not
    # started has no transfer to stop (contract 4.2)
    if d.stage == "provisioning" or d.state == "queued":
        return {}
    d.paused.clear()
    STATE.bus.emit("download.progress", d.info())
    return {}


@app.post("/v1/downloads/{did}/resume", status_code=202)
async def download_resume(did: str):
    d = STATE.downloads.get(did)
    if not d:
        return err(404, "NOT_FOUND", "unknown download")
    if d.stage == "provisioning" or d.state == "queued":
        return {}
    d.paused.set()
    STATE.bus.emit("download.progress", d.info())
    return {}


@app.delete("/v1/downloads/{did}", status_code=202)
async def download_cancel(did: str):
    d = STATE.downloads.get(did)
    if not d:
        return err(404, "NOT_FOUND", "unknown download")
    if did in STATE.download_pending:
        # never started, so no task exists to cancel and run_download's
        # bookkeeping will never run for it
        STATE.download_pending.remove(did)
        STATE.downloads.pop(did, None)
        if not d.runtime_only:
            STATE.install[d.model_id] = {"install_state": "partial",
                                         "installed_bytes": d.done}
        STATE.bus.emit("models.changed", {})
        return {}
    d.paused.set()
    if d.task:
        d.task.cancel()
    return {}


# ----- uploads


@app.post("/v1/uploads", status_code=201)
async def uploads_create(request: Request, filename: str = "audio"):
    data = await request.body()
    if not data:
        return err(422, "VALIDATION", "empty upload body")
    if len(data) > 256 * 1024 * 1024:
        return err(422, "VALIDATION", "upload exceeds 256 MB")
    upload_id = f"up_{uuid.uuid4().hex[:12]}"
    STATE.uploads[upload_id] = len(data)
    return {"upload_id": upload_id, "bytes": len(data),
            "filename": os.path.basename(filename) or "audio"}


# ----- jobs


@app.post("/v1/jobs", status_code=202)
async def jobs_submit(body: dict):
    st = STATE
    model_ids = body.get("model_ids") or []
    task = body.get("task") or "generate"
    prompt = (body.get("prompt") or "").strip()
    if task not in TASKS:
        return err(422, "VALIDATION", f"unknown task '{task}'")
    if not model_ids or (task == "generate" and not prompt):
        return err(422, "VALIDATION", "model_ids and prompt are required")
    if len(model_ids) != 1:
        return err(422, "VALIDATION",
                   "exactly one model per job; submit one job per model")
    mid = model_ids[0]
    if mid not in st.models:
        return err(404, "NOT_FOUND", f"unknown model {mid}")
    if st.install[mid]["install_state"] != "installed":
        return err(409, "MODEL_NOT_INSTALLED", f"{mid} is not installed",
                   {"model_id": mid})
    caps = st.models[mid]["capabilities"]
    if task not in (caps.get("tasks") or ["generate"]):
        return err(422, "VALIDATION", f"{mid} does not support task '{task}'")
    if task != "generate":
        if body.get("lyrics"):
            return err(422, "VALIDATION", f"task '{task}' does not accept lyrics")
        if int(body.get("count", 1)) != 1:
            return err(422, "VALIDATION",
                       f"task '{task}' jobs run exactly one take")
    if body.get("lyrics") and not caps["supports_lyrics"]:
        return err(422, "VALIDATION", f"{mid} does not support lyrics",
                   {"model_id": mid})
    preview = bool(body.get("preview"))
    # refused rather than ignored, so a client never waits for frames that are
    # not coming (contract 5.6)
    if preview and not caps.get("supports_preview"):
        return err(422, "VALIDATION", f"{mid} cannot preview while it renders",
                   {"model_id": mid})
    if int(body.get("count", 1)) > caps["outputs_per_job_max"]:
        return err(422, "VALIDATION", f"count exceeds max for {mid}")

    group_id = f"grp_{uuid.uuid4().hex[:12]}"
    if task == "generate":
        dur = float(body.get("duration_s", caps["duration"]["default_s"]))
        dur = max(caps["duration"]["min_s"], min(caps["duration"]["max_s"], dur))
    else:
        raw_dur = body.get("duration_s")
        dur = float(raw_dur) if raw_dur is not None else None
    known = {p["key"] for p in caps["params"]}
    raw = body.get("params") or {}
    params = {k: v for k, v in raw.items() if k in known}
    dropped = set(raw) - known
    for p in caps["params"]:
        if p["type"] in ("audio", "midi") and params.get(p["key"]) is not None:
            if params[p["key"]] not in STATE.uploads:
                return err(422, "VALIDATION", f"unknown upload for '{p['key']}'")
    for p in caps["params"]:
        if p["type"] != "json" or not p.get("resolve_uploads"):
            continue
        value = params.get(p["key"])
        if value is None:
            continue
        try:
            parsed = json.loads(value)
        except (TypeError, ValueError):
            return err(422, "VALIDATION", f"'{p['key']}' is not valid JSON")
        bad: list[str] = []

        def walk(node):
            if isinstance(node, dict):
                return {k: walk(v) for k, v in node.items()}
            if isinstance(node, list):
                return [walk(v) for v in node]
            if isinstance(node, str) and node.startswith("up_"):
                if node not in STATE.uploads:
                    bad.append(node)
                    return node
                return f"/stub/uploads/{node}"
            return node

        resolved = walk(parsed)
        if bad:
            return err(422, "VALIDATION",
                       f"unknown upload '{bad[0]}' in '{p['key']}'")
        params[p["key"]] = json.dumps(resolved)
    if task != "generate":
        for p in caps["params"]:
            if (p["type"] in ("audio", "midi", "json")
                    and not p.get("nullable", True)
                    and params.get(p["key"]) is None):
                return err(422, "VALIDATION",
                           f"missing required input '{p['key']}'")
    job = Job(group_id, mid, body, dur, params, task=task, preview=preview)
    st.jobs[job.id] = job
    st.job_order.append(job.id)
    st.bus.emit("job.queued", {"job_id": job.id, "group_id": group_id,
                               "model_id": mid,
                               "queue_position": st.queue_position(job.id)})
    for k in dropped:
        st.bus.emit("job.log", {"job_id": job.id,
                                "line": f"dropped unknown param '{k}' for {mid}"})
    st.wake.set()
    return {"group_id": group_id, "jobs": [{"job_id": job.id, "model_id": mid}]}


@app.get("/v1/jobs")
async def jobs_list(status: str | None = None, group_id: str | None = None):
    out = []
    for j in STATE.jobs.values():
        if group_id and j.group_id != group_id:
            continue
        if status:
            if j.status != status and not (status == "running" and j.status in
                                           ("loading", "generating", "encoding")):
                continue
        elif group_id is None and j.status in ("succeeded", "failed", "canceled"):
            continue
        out.append(j.info(STATE.queue_position(j.id)))
    return {"jobs": out}


@app.get("/v1/jobs/{jid}")
async def jobs_get(jid: str):
    j = STATE.jobs.get(jid)
    if not j:
        return err(404, "NOT_FOUND", "unknown job")
    return j.info(STATE.queue_position(jid))


@app.post("/v1/jobs/{jid}/cancel", status_code=202)
async def jobs_cancel(jid: str):
    j = STATE.jobs.get(jid)
    if not j:
        return err(404, "NOT_FOUND", "unknown job")
    if j.status in ("succeeded", "failed", "canceled"):
        return err(409, "JOB_NOT_CANCELABLE", "job already terminal")
    if j.status == "queued":
        j.status = "canceled"
        if jid in STATE.job_order:
            STATE.job_order.remove(jid)
        STATE.bus.emit("job.canceled", {"job_id": jid})
    else:
        j.cancel_requested = True
    return {}


@app.patch("/v1/jobs/{jid}/priority", status_code=202)
async def jobs_priority(jid: str, body: dict):
    j = STATE.jobs.get(jid)
    if not j:
        return err(404, "NOT_FOUND", "unknown job")
    raw = body.get("priority")
    # bool is an int in Python and would silently become 1/0
    if not isinstance(raw, int) or isinstance(raw, bool):
        return err(422, "VALIDATION", "priority must be an integer")
    if jid not in STATE.job_order:
        return err(409, "JOB_NOT_QUEUED", "job is already running or terminal")
    j.priority = raw
    STATE.announce_queue()
    return {}


@app.post("/v1/queue/pause", status_code=202)
async def queue_pause():
    # the running job is deliberately untouched: nothing here can suspend a
    # take mid-flight, and pretending otherwise is the lie (contract 5.7)
    STATE.queue_held = True
    STATE.bus.emit("queue.state", {"held": True,
                                   "active_job_id": STATE.active_job})
    return {}


@app.post("/v1/queue/resume", status_code=202)
async def queue_resume():
    STATE.queue_held = False
    STATE.wake.set()
    STATE.bus.emit("queue.state", {"held": False,
                                   "active_job_id": STATE.active_job})
    return {}


@app.post("/v1/queue/order", status_code=202)
async def queue_order(body: dict):
    ids = body.get("job_ids")
    if not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
        return err(422, "VALIDATION", "job_ids must be a list of job ids")
    for jid in ids:
        if jid not in STATE.jobs:
            return err(404, "NOT_FOUND", f"unknown job {jid}")
    # ids that stopped being queued mid-drag are skipped, not refused
    queued = [jid for jid in ids if jid in STATE.job_order]
    listed = set(queued)
    base = max((STATE.jobs[jid].priority for jid in STATE.job_order
                if jid not in listed), default=0)
    for i, jid in enumerate(queued):
        STATE.jobs[jid].priority = base + len(queued) - i
    STATE.announce_queue()
    return {}


# ----- events


@app.get("/v1/events")
async def events(request: Request):
    st = STATE
    q: asyncio.Queue = asyncio.Queue()

    async def gen():
        st.bus.subscribers.add(q)
        try:
            last = request.headers.get("last-event-id")
            if last is not None and last.isdigit():
                for eid, event, data in st.bus.ring:
                    if eid > int(last):
                        yield f"id: {eid}\nevent: {event}\ndata: {json.dumps(data)}\n\n"
            # on a clock, not on silence: telemetry ticks every 10 s even when
            # idle, so a heartbeat waiting for a quiet stream would never fire
            next_beat = time.monotonic() + 15.0
            while True:
                try:
                    eid, event, data = await asyncio.wait_for(
                        q.get(), timeout=max(0.0, next_beat - time.monotonic()))
                    yield f"id: {eid}\nevent: {event}\ndata: {json.dumps(data)}\n\n"
                except asyncio.TimeoutError:
                    next_beat = time.monotonic() + 15.0
                    yield ": hb\n\n"
        finally:
            st.bus.subscribers.discard(q)

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


# ---------------------------------------------------------------- bootstrap


async def watch_parent(ppid: int) -> None:
    while True:
        await asyncio.sleep(2)
        try:
            os.kill(ppid, 0)
        except OSError:
            # stderr is a pipe held by the dead parent — even print() raises
            # here, and an uncaught exception would kill this task instead of
            # the process
            try:
                print("parent died; exiting", file=sys.stderr)
            except Exception:
                pass
            finally:
                os._exit(0)


async def main() -> None:
    global STATE, AUTH_TOKEN

    ap = argparse.ArgumentParser()
    ap.add_argument("--handshake-file", required=True)
    ap.add_argument("--parent-pid", type=int, default=None)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--log-level", default="info")
    args = ap.parse_args()

    AUTH_TOKEN = os.environ.get("LOCALMUSIC_AUTH_TOKEN") or ""
    if not AUTH_TOKEN:
        AUTH_TOKEN = secrets.token_hex(16)
        print(f"LOCALMUSIC_AUTH_TOKEN not set; using {AUTH_TOKEN}", file=sys.stderr)

    os.makedirs(args.data_dir, exist_ok=True)
    os.makedirs(args.output_dir, exist_ok=True)
    STATE = State(args.output_dir)

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

    # timeout_graceful_shutdown: open SSE streams never end on their own; without a
    # bound, uvicorn would wait forever and violate the 10 s shutdown contract.
    config = uvicorn.Config(app, log_level=args.log_level, access_log=False,
                            lifespan="on", timeout_graceful_shutdown=3)
    server = uvicorn.Server(config)

    # keep strong refs: the loop only weak-refs tasks, and a GC'd watchdog
    # means an orphaned process
    background_tasks = []
    if args.parent_pid:
        background_tasks.append(asyncio.create_task(watch_parent(args.parent_pid)))

    async def write_handshake():
        while not server.started:
            await asyncio.sleep(0.05)
        tmp = args.handshake_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"port": port, "pid": os.getpid(), "version": VERSION,
                       "contract": CONTRACT}, f)
        os.replace(tmp, args.handshake_file)
        print(f"stub engine ready on 127.0.0.1:{port}", file=sys.stderr)

    background_tasks.append(asyncio.create_task(write_handshake()))
    await server.serve(sockets=[sock])  # uvicorn installs SIGTERM/SIGINT handlers


if __name__ == "__main__":
    asyncio.run(main())
