#!/usr/bin/env python3
"""Regenerate engine/catalog/models.json's extended (non-featured) entries.

Sizes are computed from the HF API as the engine will actually download them
(duplicate .bin/.msgpack/.h5 weights excluded when safetensors exist). Featured
entries are kept; their sizes are refreshed too. Idempotent.
"""

from __future__ import annotations

import copy
import fnmatch
import json
import os
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "engine", "catalog", "models.json")

GIB = 1 << 30

# Takes ceiling for the generation families. Not a model constraint: the
# supervisor renders a job's takes in a plain sequential loop (jobqueue's
# `for i in range(job.count)`), one worker round-trip each, sweeping previews
# between them — so N takes is N renders back to back, not a batched forward
# pass. The number is a judgment about how long one queued job should hold the
# GPU before you can reorder the queue around it — and since a slow model makes
# that judgment for you by taking longer per take, every generate family gets
# the same ceiling rather than a per-family guess at what "too long" means.
# The long-form singers stay at 1 at their own entry, and task-only models are
# pinned to 1 by `task_caps` — a non-generate job with count != 1 is refused
# outright.
TAKES_MAX = 16

# `duration.unlocked_max_s` — how far "Unlock max length" may push the slider
# past what the model documents about itself. Declared ONLY where the longer
# request actually reaches the model: a family whose runtime clamps for itself
# (acestep.cpp stops at 600 in metadata-fsm.h) or whose latent size is fixed by
# the checkpoint (Stable Audio renders `sample_size` and trims; MAGNeT's span
# pattern fixes the clip) would take the longer number and return the same
# audio, and a toggle that changes nothing is worse than no toggle.
#
# 600 for the families with no ceiling in the code at all — MusicGen counts out
# `duration * 50` tokens and audiocraft strides past its 30 s window by
# windowed continuation, Magenta RT chains 2 s chunks, AudioLDM enforces only a
# minimum. None of them stop on their own; this is where WE stop, so a
# mis-dragged slider cannot queue an overnight render.
UNLOCKED_MAX_S = 600.0

# ACE-Step gets its own, because unlike the above it has a real wall to aim at:
# the DiT's RoPE table (max_position_embeddings=32768) against 25 latent frames
# per second puts it near 1310 s. 1200 keeps a margin under a limit that would
# otherwise be found the hard way, at the end of a very long render.
ACESTEP_UNLOCKED_MAX_S = 1200.0


def token() -> str | None:
    path = os.path.expanduser("~/.cache/huggingface/token")
    if os.environ.get("HF_TOKEN"):
        return os.environ["HF_TOKEN"]
    if os.path.exists(path):
        return open(path).read().strip()
    return None


def ms_effective_size(repo_id: str,
                      patterns: list[str] | None = None) -> int:
    """Total blob bytes of a ModelScope repo (catalog `ms_repos` entries),
    from the same anonymous listing the engine's ms_download_worker uses."""
    url = (f"https://modelscope.cn/api/v1/models/{repo_id}"
           f"/repo/files?Recursive=true")
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.load(resp)
    if data.get("Code") != 200:
        raise RuntimeError(f"ModelScope listing failed: {data.get('Message')}")
    files = [f for f in data["Data"]["Files"] if f.get("Type") == "blob"]
    if patterns is not None:
        empty = [p for p in patterns
                 if not any(fnmatch.fnmatch(f["Path"], p) for f in files)]
        if empty:
            raise SystemExit(
                f"ms:{repo_id}: allow_patterns match no file upstream: "
                f"{empty}")
        files = [f for f in files
                 if any(fnmatch.fnmatch(f["Path"], p) for p in patterns)]
    return sum(int(f.get("Size") or 0) for f in files)


def effective_size(repo_id: str, tok: str | None,
                   patterns: list[str] | None = None) -> int:
    req = urllib.request.Request(
        f"https://huggingface.co/api/models/{repo_id}?blobs=true")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    siblings = data.get("siblings", [])
    names = [s["rfilename"] for s in siblings]
    if patterns is not None:
        # A pattern matching nothing is not a harmless no-op: the downloader
        # skips it silently, and `registry.is_installed` then refuses the
        # model forever because one of its declared patterns has no file on
        # disk. Cheapest place to notice is here, with the listing in hand.
        empty = [p for p in patterns
                 if not any(fnmatch.fnmatch(n, p) for n in names)]
        if empty:
            raise SystemExit(
                f"{repo_id}: allow_patterns match no file upstream: {empty}\n"
                f"  (the repo has: {sorted(names)[:12]})")
    has_st = any(s["rfilename"].endswith(".safetensors") for s in siblings)
    total = 0
    for s in siblings:
        name = s["rfilename"]
        if patterns is not None:
            if not any(fnmatch.fnmatch(name, p) for p in patterns):
                continue
        elif has_st and name.endswith((".bin", ".msgpack", ".h5")):
            continue
        total += s.get("size") or 0
    return total


# User-owned HF mirror for permissive single files without stable HF hosting.
# CREATED AND POPULATED 2026-08-25 (see models-uploaded-to-my-HF.md at the
# repo root): analysis/beat_this-final0.ckpt (MIT, CPJKU) and the two BTC
# chord checkpoints (MIT, ISMIR 2019). Only permissively-licensed files may
# land here — NC-licensed weights stay at origin, and the viperx BS-RoFormer
# ckpt (no formal license) is still pending a decision.
ASSETS_REPO = "rtikw/localmusic-assets"


def seed_param():
    return {"key": "seed", "type": "int", "label": "Seed", "default": None,
            "nullable": True, "min": 0, "max": 4294967295}


def source_audio_param(help_=None):
    return {"key": "source_audio", "type": "audio", "label": "Source audio",
            "default": None, "nullable": False,
            "help": help_ or "The song to process"}


def vr_cleanup_params():
    """The VR architecture's own controls, for the two `.pth` cleanup cards.

    `aggression` is how hard the model pulls the target out of the mix, as a
    percentage handed straight to the separator (`vr_separator.py`:
    `aggression/100`). The other architectures in this family ignore the
    block, which is why only these two cards offer it.
    """
    return [
        {"key": "aggression", "type": "int", "label": "Aggression",
         "default": 5, "nullable": False, "min": -20, "max": 40,
         "help": "How hard to pull the target out. 5 is the value the "
                 "community settled on; raise it when the problem survives "
                 "the pass, lower it when the result sounds hollowed out. "
                 "Negative values pull the other way."},
        {"key": "tta", "type": "bool", "label": "Extra-quality pass",
         "default": False, "nullable": False,
         "help": "Run the separation again on a transformed copy and average "
                 "the two, which cancels some of the artefacts a single pass "
                 "leaves. Roughly doubles the time."},
    ]


def msst_params(extract_instrumental=False):
    """MSST's two inference flags.

    `extract_instrumental` is offered only where it means something: the CLI
    computes it as the mix minus the *vocals* stem (falling back to whichever
    stem is listed first), so on a four-stem model it would return the mix
    minus the bass and call it an instrumental.
    """
    params = [
        {"key": "tta", "type": "bool", "label": "Extra-quality pass",
         "default": False, "nullable": False,
         "help": "Test-time augmentation: separate the track again with its "
                 "polarity and channels inverted and average the results. "
                 "Upstream's own summary is that it triples the runtime, "
                 "reduces noise and slightly improves the split."},
    ]
    if extract_instrumental:
        params.append(
            {"key": "extract_instrumental", "type": "bool",
             "label": "Also return the instrumental", "default": False,
             "nullable": False,
             "help": "Subtract the vocal from the mix to get the backing "
                     "track. Free — no second pass, no second model — and "
                     "exact, because what is removed is exactly what was "
                     "found."})
    return params


def whisper_params():
    """The rest of what Whisper can be told, beyond the language.

    All four ride the decoder's own hooks: `initial_prompt` and `hotwords` bias
    which words it reaches for, `task="translate"` swaps the decoding target,
    and `word_timestamps` runs the extra cross-attention pass that puts a time
    on every word rather than on every line.

    The first is the one worth having in this app: a song the app generated
    already has its lyrics written down, and handing them back to the
    transcriber turns "what did it sing?" from a guess into a check.
    """
    return [
        {"key": "expected_words", "type": "string", "label": "Expected words",
         "default": None, "nullable": True,
         "placeholder": "paste the lyrics you expect to hear",
         "help": "Words you already believe are in the audio — the lyrics you "
                 "generated the song from, say. The model is nudged towards "
                 "them, which sharply improves invented words and proper "
                 "nouns. It is a nudge, not a rule: text that is not in the "
                 "audio makes the transcript worse."},
        {"key": "hotwords", "type": "string", "label": "Names & odd words",
         "default": None, "nullable": True,
         "placeholder": "comma separated",
         "help": "A short list of names, places or made-up words to listen "
                 "for. The same nudge as Expected words, in list form; use "
                 "either or both."},
        {"key": "translate", "type": "bool", "label": "Translate to English",
         "default": False, "nullable": False,
         "help": "Write the words down in English rather than in the language "
                 "they are sung in. The detected language is still reported, "
                 "so you can tell a translation from a transcript."},
        {"key": "word_timestamps", "type": "bool", "label": "Time every word",
         "default": False, "nullable": False,
         "help": "Put a start and end on each individual word, not just on "
                 "each line — what karaoke-style alignment needs. Costs a "
                 "second pass over the audio."},
    ]


def init_audio_params():
    """Audio-to-audio for diffusion models: start from a noised reference
    clip instead of pure noise (the "Reimagine a Loop" recipe)."""
    return [
        {"key": "init_audio", "type": "audio", "label": "Reimagine source",
         "default": None, "nullable": True,
         "help": "Audio to reimagine — diffusion starts from this clip "
                 "instead of noise"},
        # sigma_max semantics in both pinned libraries: 1.0 renoises the
        # source completely ("full noise (no variation)" per the sampler's
        # own docs) and anything above 1.0 leaves the schedule. The old
        # 0.1-10 range put the no-op at the dial's center and made its whole
        # upper half do nothing (audit §2).
        {"key": "init_noise_level", "type": "float", "label": "Reimagine amount",
         "default": 0.9, "nullable": False, "min": 0.05, "max": 1.0,
         "step": 0.05,
         "help": "How far to depart from the source (1.0 = ignore it "
                 "entirely)"},
    ]


# What a model is FOR, in this app's terms — the vocabulary behind the Models
# screen's tag filter. Derived from capabilities so every entry stays
# consistent and new entries get tagged for free; deliberately about *use*
# ("what can I do with this?"), not about size/speed/family, which have their
# own badges. Order here is the order tags appear on an entry, which in turn
# drives the filter bar's button order (first appearance wins).
TAG_SONGS = "Songs with vocals"
TAG_INSTRUMENTAL = "Instrumental & loops"
TAG_MELODY = "Melody-guided"
TAG_REMIX = "Remix & restyle"
TAG_SEPARATION = "Stem separation"
TAG_NOTES = "Notes & MIDI"
TAG_ANALYSIS = "Musical analysis"
TAG_MIXING = "Mixing & recombining"
TAG_WRITING = "Writing help"
TAG_TEXT = "Hears & describes"
TAG_VOICE = "Voice & singing"

# params that mean "this model can take existing audio and rework it".
# `melody_audio` and `style_audio` belong here for the same reason the rest do:
# both take a file the user already has and produce a new performance of it.
# They also carry their own, narrower tag — the Style Transfer screen filters on
# this set, and a melody model missing from it was simply unreachable there.
_REMIX_PARAMS = {"src_audio", "init_audio", "reference_audio", "extend_audio",
                 "inpaint_audio", "task_type", "melody_audio", "style_audio",
                 "accompany_audio", "continue_audio"}


def derive_tags(entry: dict) -> list[str]:
    caps = entry["capabilities"]
    tasks = set(caps.get("tasks") or ["generate"])
    params = {p["key"] for p in caps["params"]}
    tags: list[str] = []
    if "generate" in tasks:
        if caps.get("supports_lyrics"):
            tags.append(TAG_SONGS)
        else:
            tags.append(TAG_INSTRUMENTAL)
        if "melody_audio" in params:
            tags.append(TAG_MELODY)
        if params & _REMIX_PARAMS:
            tags.append(TAG_REMIX)
    if "separate" in tasks:
        tags.append(TAG_SEPARATION)
    if tasks & {"transcribe", "render", "compose"}:
        tags.append(TAG_NOTES)
    if "analyze" in tasks:
        tags.append(TAG_ANALYSIS)
    if "mix" in tasks:
        tags.append(TAG_MIXING)
    if "assist" in tasks:
        tags.append(TAG_WRITING)
    # The models that listen: captioning, lyric transcription, tagging. A
    # different promise from TAG_WRITING's — the assistant writes *for* you
    # from measurements and never hears a thing, and a user picking between
    # them is picking between those two promises.
    if tasks & {"caption", "lyrics", "tag"}:
        tags.append(TAG_TEXT)
    # The audio-transformation quartet. Timbre and re-amp rework existing
    # audio, which is what TAG_REMIX has always meant; the two voice tasks
    # get their own word because "restyle" undersells "this sings".
    if tasks & {"timbre", "reamp"}:
        tags.append(TAG_REMIX)
    if tasks & {"convert-voice", "sing"}:
        tags.append(TAG_VOICE)
    # Deliberately no tag for `plan`: it is never a reason to install a model,
    # only something a generative model you already have happens to offer. A
    # filter button that returned "the ACE-Step variants" under a name like
    # "Planning" would describe the roster, not a use.
    return tags


_STAGE_LABELS = {
    "prompt_encode": "Prompt encode",
    "lm_reasoning": "LM reasoning",
    "lm_decode": "Token decode",
    "diffusion": "Diffusion",
    "vocoder": "Vocoder decode",
    "master": "Master & save",
}


def _stages(*ids, optional=()):
    return [{"id": i, "label": _STAGE_LABELS[i],
             **({"optional": True} if i in optional else {})} for i in ids]


# What each family's adapter genuinely reports, in the order it reports it —
# never the stages a model conceptually has. Families absent from this table
# declare no pipeline and the app draws one bar: yue only scrapes fractions out
# of a subprocess log, and the task-only families (separation, transcription,
# analysis, dsp, notesynth) run one opaque pass. Keep in step with the `phase=`
# arguments in engine/adapters/*/src/adapter_*/adapter.py.
PIPELINES = {
    "musicgen": _stages("prompt_encode", "lm_decode", "master"),
    "audiocraft": _stages("prompt_encode", "lm_decode", "master"),
    "stableaudio": _stages("prompt_encode", "diffusion", "master"),
    "stableaudio3": _stages("prompt_encode", "diffusion", "master"),
    "diffusers": _stages("prompt_encode", "diffusion", "master"),
    # LM before input prep is the real order: ACE-Step runs the whole LM half
    # first, and the five src-audio tasks skip it, hence the optional flag.
    "acestep": _stages("lm_reasoning", "prompt_encode", "diffusion", "vocoder",
                       "master", optional=("lm_reasoning",)),
    "acestepcpp": _stages("lm_reasoning", "diffusion", "vocoder", "master"),
    # DiffSynth's AceStep runtime: no LM half at all (the LoRA pack drives
    # the DiT directly), so the stages are the diffusion path alone.
    "diffsynthace": _stages("prompt_encode", "diffusion", "master"),
    # Streaming token decode straight to audio frames; the style embed is a
    # sub-second un-phased step before it.
    "magentart": _stages("lm_decode", "master"),
    "melodyflow": _stages("prompt_encode", "diffusion", "master"),
    "vampnet": _stages("prompt_encode", "lm_decode", "master"),
    "songgen": _stages("prompt_encode", "lm_decode", "master"),
    # inspiremusic / songbloom / diffrhythm2 deliberately absent: their
    # adapters run one opaque pass (subprocess or callback-free API) and the
    # app draws one bar — declaring stages nobody reports would violate the
    # staged-progress invariant.
    "minimax": _stages("lm_decode", "diffusion", "vocoder", "master"),
    "mlxaudio": _stages("lm_decode", "diffusion", "master"),
}


# The catalog has a source page for every model. Prefer configured Hugging Face
# repositories below: some projects have moved or been mirrored there since the
# original catalog research. These entries either self-download from the named
# provider, ship with a package, or have no catalogued HF repository.
SOURCE_HOMEPAGES = {
    "magenta-rt2-small": "https://huggingface.co/google/magenta-realtime-2",
    "magenta-rt2-base": "https://huggingface.co/google/magenta-realtime-2",
    "separation-htdemucs": "https://github.com/adefossez/demucs",
    "separation-htdemucs-ft": "https://github.com/adefossez/demucs",
    "separation-htdemucs-6s": "https://github.com/adefossez/demucs",
    "separation-hdemucs-mmi": "https://github.com/adefossez/demucs",
    "separation-mdx-extra": "https://github.com/adefossez/demucs",
    "cleanup-uvr-denoise": "https://huggingface.co/Politrees/UVR_resources",
    "cleanup-uvr-deecho-dereverb": "https://huggingface.co/Politrees/UVR_resources",
    "separation-uvr-kimvocal2": "https://huggingface.co/Politrees/UVR_resources",
    "separation-uvr-vocft": "https://huggingface.co/Politrees/UVR_resources",
    "separation-uvr-karaoke": "https://huggingface.co/Politrees/UVR_resources",
    "separation-scnet": "https://github.com/ZFTurbo/Music-Source-Separation-Training/releases",
    "separation-mdx23c-vocals": "https://github.com/ZFTurbo/Music-Source-Separation-Training/releases",
    "separation-scnet-xl": "https://github.com/ZFTurbo/Music-Source-Separation-Training/releases",
    "separation-drumsep": "https://huggingface.co/Sucial/MSST-WebUI",
    "separation-ensemble": "https://github.com/nomadkaraoke/python-audio-separator",
    "analysis-squim": "https://pytorch.org/audio/stable/pipelines.html",
    "timbre-rave-percussion": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-vintage": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-sol_ordinario": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-VCTK": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-nasa": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-musicnet": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-sol_full": "https://acids-ircam.github.io/rave_models_download",
    "timbre-rave-isis": "https://acids-ircam.github.io/rave_models_download",
    "reamp-nam": "https://www.tone3000.com/",
    "convert-voice-seedvc": "https://huggingface.co/Plachtaa/seed-vc",
    "convert-voice-seedvc-v2": "https://huggingface.co/Plachtaa/seed-vc",
    "tag-essentia-discogs": "https://essentia.upf.edu/models.html",
    "tag-essentia-jamendo": "https://essentia.upf.edu/models.html",
    "dsp-mixdown": "https://github.com/spotify/pedalboard",
    "transcribe-basicpitch": "https://github.com/spotify/basic-pitch",
    "transcribe-transkun": "https://github.com/Yujia-Yan/Skipping-The-Frame-Level",
    "transcribe-swiftf0": "https://github.com/lars76/swift-f0",
    "render-soundfont": "https://huggingface.co/rtikw/localmusic-assets",
}


def apply_pipeline(entry: dict) -> None:
    """Set capabilities.pipeline from PIPELINES, or drop it where the family
    reports no stages. Task-only entries never get one even when their family
    has generation models (codec-tokensplice shares mlxaudio with MiniMax).
    Inserted in place, just before `params`: every other key keeps its position
    so re-running this over an existing catalog produces a purely additive diff.
    """
    caps = entry["capabilities"]
    caps.pop("pipeline", None)
    tasks = caps.get("tasks") or ["generate"]
    stages = PIPELINES.get(entry["family"]) if "generate" in tasks else None
    if not stages:
        return
    rebuilt: dict = {}
    for key, value in caps.items():
        if key == "params":
            rebuilt["pipeline"] = copy.deepcopy(stages)
        rebuilt[key] = value
    caps.clear()
    caps.update(rebuilt)


# Which entries can publish partial audio while they render (contract 5.6).
# An entry qualifies only where its adapter can decode audio the model has
# GENUINELY produced by that point: Stable Audio's samplers hand their callback
# the predicted clean latent, the diffusers pipelines hand over their latents
# every step, and the MLX MusicGen decode loop is vendored here so its token
# buffer is in scope.
#
# Absent by design: acestep and acestepcpp (no callback point inside the DiT
# loop — the latents never leave it, and one runtime is a subprocess), the
# transformers MusicGen path (the delay-pattern mask would have to be rebuilt
# from generate()'s internals), audiocraft/minimax/mlxaudio/yue (one opaque
# call), and every task-only entry. None of them could produce a real frame,
# and a preview nobody can distinguish from real audio must never be invented.
def supports_preview(entry: dict) -> bool:
    caps = entry["capabilities"]
    if "generate" not in (caps.get("tasks") or ["generate"]):
        return False
    family = entry["family"]
    if family in ("stableaudio", "stableaudio3", "diffusers"):
        return True
    if family == "musicgen":
        return (entry.get("settings") or {}).get("backend") == "mlx"
    return False


def apply_preview(entry: dict) -> None:
    """Set capabilities.supports_preview, or drop it where the adapter has no
    real partial audio to offer. Inserted just before `pipeline` (or `params`
    where there is none) so re-running this over an existing catalog produces a
    purely additive diff."""
    caps = entry["capabilities"]
    caps.pop("supports_preview", None)
    if not supports_preview(entry):
        return
    anchor = "pipeline" if "pipeline" in caps else "params"
    rebuilt: dict = {}
    for key, value in caps.items():
        if key == anchor:
            rebuilt["supports_preview"] = True
        rebuilt[key] = value
    caps.clear()
    caps.update(rebuilt)


# Which section of the parameters panel each control belongs in (contract 4.1).
# The app already knows the ids "sampling" / "musical" / "task" and the labels
# they draw, so only the id travels. Keyed by param key rather than by family:
# the same knob means the same thing everywhere it appears, and a key missing
# from this table fails the build instead of quietly landing in "Other".
SAMPLING = "sampling"   # how the model draws — sampler knobs, nothing else
MUSICAL = "musical"     # properties of the music itself
TASK = "task"           # what is being transformed, and how

PARAM_GROUPS = {
    "steps": SAMPLING,
    "guidance_scale": SAMPLING,
    "cfg_scale": SAMPLING,
    "temperature": SAMPLING,
    "top_k": SAMPLING,
    "top_p": SAMPLING,
    "seed": SAMPLING,
    # How many takes the model draws internally before one is chosen — a
    # property of the draw, not of the music.
    "candidates": SAMPLING,
    # the negative prompt *is* the classifier-free-guidance branch, so it sits
    # next to the scale that weights it rather than next to the prompt
    "negative_prompt": SAMPLING,
    # ACE-Step's LM plans the arrangement before the DiT draws it: a switch on
    # how generation runs, not a property of the music
    "thinking": SAMPLING,
    # The knobs on that LM. They sit in SAMPLING beside the DiT's own sampler
    # controls because that is what they are — how the planner draws, not what
    # it is planning.
    "lm_temperature": SAMPLING,
    "lm_cfg_scale": SAMPLING,
    "lm_top_p": SAMPLING,
    # Which fields the LM is allowed to invent. A gate on its reasoning, so it
    # belongs with `thinking` rather than with the values themselves.
    "use_cot_metas": SAMPLING,
    "use_cot_caption": SAMPLING,
    "use_cot_language": SAMPLING,
    # A plan the app captured from an earlier take and is handing back. Never
    # rendered; populated in code.
    "audio_codes": SAMPLING,
    "fake_stereo": SAMPLING,
    "plan_caption": SAMPLING,
    "plan_lyrics": SAMPLING,
    "plan_count": SAMPLING,
    "plan_duration_s": SAMPLING,
    "bpm": MUSICAL,
    # InspireMusic's structure conditioning: which section of a song the
    # model believes it is writing, and where on its imagined timeline.
    "chorus": MUSICAL,
    "time_start": MUSICAL,
    "time_end": MUSICAL,
    # The other two facts the LM otherwise guesses at. Pinning one takes it out
    # of the model's hands, which is the whole point of the control.
    "keyscale": MUSICAL,
    "timesignature": MUSICAL,
    "vocal_language": MUSICAL,
    # The window YuE's in-context style reference listens to.
    "prompt_start_s": TASK,
    "prompt_end_s": TASK,
    "task_type": TASK,
    # A LoRA merged into the weights before rendering: it changes what the
    # model IS, which is a property of the music rather than of the sampler.
    "adapter": MUSICAL,
    "adapter_scale": MUSICAL,
    "accompany_audio": TASK,
    "template_scale": TASK,
    "edit_strength": TASK,
    "edit_source_caption": TASK,
    "solver": SAMPLING,
    "cfg_coef": SAMPLING,
    "sampler_type": SAMPLING,
    "periodic_prompt": TASK,
    "upper_codebook_mask": TASK,
    "beat_mask": TASK,
    "time_stretch": TASK,
    "prefix_s": TASK,
    "suffix_s": TASK,
    "ref_voice": TASK,
    "src_audio": TASK,
    "reference_audio": TASK,
    "melody_audio": TASK,
    "continue_audio": TASK,
    # A MIDI part the model plays, and the two guidance scales that weight it.
    # The notes are the material; how hard they are followed is a draw setting.
    "melody_midi": TASK,
    "notes_guidance": SAMPLING,
    "drums": TASK,
    "drums_guidance": SAMPLING,
    "init_audio": TASK,
    "init_noise_level": TASK,
    "extend_audio": TASK,
    "inpaint_audio": TASK,
    "inpaint_start_s": TASK,
    "inpaint_end_s": TASK,
    "audio_cover_strength": TASK,
    # DiffSynth-only strengths (the acestep family's pipeline has no such
    # kwargs); read by adapter_diffsynthace since the pack landed but
    # undeclared until the 2026-09 audit made them reachable.
    "denoising_strength": TASK,
    "repainting_strength": TASK,
    "style_audio": TASK,
    "style_audio_b": TASK,
    "prompt_b": TASK,
    "style_excerpt_s": TASK,
    "flow_edit_morph": TASK,
    "flow_edit_source_caption": TASK,
    "repainting_start": TASK,
    "repainting_end": TASK,
    "track": TASK,
}


# What every knob actually does, in words a musician can act on.
#
# Keyed by param key rather than by family for the same reason PARAM_GROUPS is:
# `temperature` means the same thing wherever it appears, and writing it out at
# each of the dozen call sites that declare it guarantees a dozen slightly
# different explanations. A key that is rendered but explained nowhere fails
# the build (see `apply_help`) — "Full control" existed for months as eight
# unlabelled sliders, which is a feature the target audience cannot use.
#
# The copy may be technical; the reader is expected to look a term up. What it
# must not do is assume the reader already knows what the term means, or state
# a number as universal when models disagree — MAGNeT's temperature runs 0.5…10
# around a default of 3, MusicGen's 0.1…2 around 1, so "1.0 is neutral" would
# be false half the time. Everything here is phrased in relative terms for that
# reason.
PARAM_HELP = {
    # ---- the planning language model, where a model has one ---------------
    "lm_temperature": "How adventurous the planner is when it decides the "
                      "tempo, key and shape of the song. Lower gives you the "
                      "obvious reading of your description; higher takes more "
                      "interesting and less predictable decisions.",
    "lm_cfg_scale": "How closely the planner sticks to your description when "
                    "it writes the plan. Higher follows your words more "
                    "literally; lower lets it fill in more of its own.",
    "lm_top_p": "How much of the planner's vocabulary stays in play at each "
                "step. Below 1.0 it ignores its least likely choices, which "
                "makes the plan safer and more conventional.",
    "use_cot_metas": "Let the planner choose the tempo, key and time "
                     "signature. Turn it off and it uses only what you have "
                     "set, leaving anything blank to the renderer.",
    "use_cot_caption": "Let the planner rewrite your description into its own "
                       "words before rendering. Often an improvement; turn it "
                       "off when you have worded the prompt carefully.",
    "use_cot_language": "Let the planner work out which language the lyrics "
                        "are in, rather than taking the language you set.",
    "keyscale": "The key to write in, such as 'F minor' or 'C major'. Left "
                "blank the model chooses one to suit the description.",
    "timesignature": "The time signature, such as '4' for four-four or '3' "
                     "for waltz time. Left blank the model chooses.",
    # ---- how the model draws ---------------------------------------------
    "steps": "How many passes the model makes refining the audio. More steps "
             "means more detail and a proportionally longer render, with "
             "sharply diminishing returns — most models stop improving well "
             "below their maximum.",
    "guidance_scale": "How hard the model is pushed to match your prompt. Low "
                      "wanders off the brief but tends to sound relaxed and "
                      "natural; high follows the words closely and can turn "
                      "harsh or lifeless. The default is the value this model "
                      "was tuned around.",
    "cfg_scale": "Classifier-free guidance — how hard the model is pushed "
                 "towards your prompt, and away from the negative one. Low is "
                 "loose and natural; high obeys the words and can sound "
                 "brittle.",
    "temperature": "How adventurous the model is at each step. Lower is safer "
                   "and more repetitive; higher is more surprising and more "
                   "likely to wander or fall apart. What counts as high "
                   "differs between models, so move away from the default in "
                   "small steps.",
    "top_k": "At each step the model considers only its K likeliest options. "
             "Small keeps it tight and predictable; large lets rarer, stranger "
             "sounds through. Temperature then chooses among whatever this "
             "leaves.",
    "top_p": "At each step the model considers only its likeliest options, up "
             "to this share of the total probability — 0.9 keeps the top 90%. "
             "A softer Top-K: how many options stay in play rises and falls "
             "with how certain the model is.",
    "seed": "The random starting point. The same seed with the same prompt and "
            "settings reproduces a take exactly, which is how you change one "
            "setting and hear only that change. Leave it on Random for "
            "something different every run.",
    "negative_prompt": "What to steer away from — \"distorted, muffled, live "
                       "recording\". It works through guidance, so it does "
                       "nothing while guidance is at its lowest setting.",
    "thinking": "A language model drafts the arrangement — sections, "
                "instrumentation, where the vocal sits — before the audio "
                "model renders it. Slower, and usually more coherent across a "
                "long track.",
    # ---- properties of the music -----------------------------------------
    "bpm": "Target tempo in beats per minute. Left on Random the model picks "
           "one to suit the prompt. It is a request rather than a guarantee — "
           "nothing locks the output to a click.",
    "vocal_language": "Which language the model should sing in. Write the "
                      "lyrics in that language too: this tells the model how "
                      "to pronounce them, it does not translate.",
    # ---- regions ----------------------------------------------------------
    "repainting_start": "Where the regenerated span starts, in seconds from "
                        "the beginning of the source. Audio outside the span "
                        "is kept exactly as it was.",
    "repainting_end": "Where the regenerated span ends, in seconds. -1 means "
                      "to the end of the track.",
    "inpaint_start_s": "Where the regenerated span starts, in seconds from the "
                       "beginning of the source. Audio outside the span is "
                       "kept exactly as it was.",
    "inpaint_end_s": "Where the regenerated span ends, in seconds.",
    "accompany_audio": "An a-cappella vocal recording. The model writes and "
                       "plays a band around it — the voice is kept, the "
                       "arrangement is generated to fit it. Steady-tempo "
                       "vocals work best.",
    "edit_strength": "How far the edit may move from the source. Low keeps "
                     "the original's structure and timbre with the change "
                     "painted lightly over it; high rewrites almost "
                     "everything except the broad shape.",
    "solver": "The ODE solver stepping the flow. Euler is the fast default; "
              "midpoint doubles the work per step for a slightly smoother "
              "result.",
    "periodic_prompt": "How often a token of the original survives into the "
                       "variation — every Nth token is kept. Low keeps the "
                       "source audible everywhere; high frees the model to "
                       "wander.",
    "upper_codebook_mask": "How many of the coarse codebooks stay pinned to "
                           "the source. More pinned keeps the low-end and "
                           "rhythm intact; fewer lets the variation rebuild "
                           "them too.",
    "ref_voice": "A short recording of the voice the song should be sung "
                 "in — about three seconds is enough. Your own recording, "
                 "or one you have permission to use; leave empty for the "
                 "model's own voice.",
    # ---- task models ------------------------------------------------------
    "shifts": "How many times the separator re-runs over a time-shifted copy "
              "of the input, averaging the results to cancel "
              "position-dependent artifacts. Slightly cleaner stems, and "
              "linearly slower.",
    "target_lufs": "How loud the result is normalised to, in LUFS — perceived "
                   "loudness averaged across the whole track, not peak level. "
                   "Streaming services land around -14.",
    "gain_db": "Volume of the finished render, in decibels. Every render is "
               "levelled to the same peak first, so 0 is that level; turning "
               "up leans into a soft limiter — louder, with the peaks gently "
               "rounded rather than clipped.",
    "sample_rate": "Samples per second in the rendered file. 44.1 kHz is CD "
                   "rate and 48 kHz is the video standard; neither adds detail "
                   "the SoundFont does not already have.",
}


def apply_help(entry: dict) -> None:
    """Fill in `help` for any rendered param that has none, and refuse to build
    a catalog where one is still missing.

    Fill-only, never overwrite: a param whose declaration already carries help
    is saying something PARAM_HELP cannot — "Turbo model: 8 steps is the sweet
    spot" is about one checkpoint, and the generic sentence about steps would
    be the wrong thing to replace it with. Where both are wanted the specific
    text is written out in full at its declaration.

    Internal params (mix_spec, splice_spec) are populated in code and never
    rendered, so they are exempt.
    """
    for param in entry["capabilities"]["params"]:
        if param.get("internal"):
            continue
        if param.get("help"):
            continue
        general = PARAM_HELP.get(param["key"])
        if general is None:
            raise KeyError(
                f"{entry['id']}: param '{param['key']}' is shown to the user "
                f"with no explanation — add one to PARAM_HELP or to the "
                f"param's own declaration")
        param["help"] = general


def normalise_help(entry: dict) -> None:
    """Give every explanation a full stop.

    Cosmetic, and it earns the pass: the panel prints these as a column of
    sentences under a column of controls, and half of them stopping mid-air
    reads as unfinished rather than as terse. Idempotent - a string that
    already ends in punctuation is left alone.
    """
    for param in entry["capabilities"]["params"]:
        help_ = param.get("help")
        if help_ and help_[-1] not in ".!?":
            param["help"] = help_ + "."

# Which ACE-Step tasks each control actually reaches, read out of
# adapter_acestep and the installed ACE-Step pipeline rather than guessed from
# the names. ACE-Step is the only family with a task selector, so it is the only
# one whose controls can be gated on the wire at all.
#
#   thinking       the adapter passes thinking=False for every src-audio task —
#                  the LM half is skipped outright there
#   src_audio      required by all five; text2music logs it and ignores it
#   repaint window builds the chunk mask; upstream shows it for Repaint and
#                  Add-a-layer, which are the two tasks that regenerate a span
#   track          only extract / lego / complete put it in the instruction
#   morph          the FlowEdit overlay rides text2music (and cover); it is the
#                  only restyle a turbo DiT can serve
#
# reference_audio is deliberately absent: the pipeline conditions on it whatever
# the task, so dimming it anywhere would be false.
#
# audio_cover_strength used to be listed here as cover-only. It is not.
# Upstream keys the blend on `audio_cover_strength < 1.0` alone — in
# `handler/conditioning_text.py` and again in every DiT's step loop, where
# `cover_steps = int(num_steps * strength)` swaps in the non-cover conditioning
# for the remaining steps. With the catalog's non-nullable default of 0.7, an
# 8-step repaint was silently switching conditioning at step 5, and the control
# that caused it was drawn dimmed with "only applies to Cover" under it. The
# contract is explicit that `applies_when` may be declared "only where the
# adapter really does ignore the value".
ACE_TASK_SCOPE = {
    "thinking": ("text2music",),
    # Everything that configures the planner shares `thinking`'s scope: the
    # five src-audio tasks skip the LM entirely (the pipeline decides this, not
    # us — see adapter_acestep), so these controls would be dead against any
    # other task.
    "lm_temperature": ("text2music",),
    "lm_cfg_scale": ("text2music",),
    "lm_top_p": ("text2music",),
    "use_cot_metas": ("text2music",),
    "use_cot_caption": ("text2music",),
    "use_cot_language": ("text2music",),
    "keyscale": ("text2music",),
    "timesignature": ("text2music",),
    "audio_codes": ("text2music",),
    # text2music included for the FlowEdit morph, which rides text2music
    # with a source; without it the morph toggle could only fail validation
    # (audit §2).
    "src_audio": ("text2music", "cover", "repaint", "extract", "lego",
                  "complete"),
    "repainting_start": ("repaint", "lego"),
    "repainting_end": ("repaint", "lego"),
    "repainting_strength": ("repaint",),
    "track": ("extract", "lego", "complete"),
    "flow_edit_morph": ("text2music", "cover"),
    "flow_edit_source_caption": ("text2music", "cover"),
    # acestep.cpp's composer LM only runs for text2music, exactly as the
    # Python family's does — so its negative prompt is scoped with the rest of
    # the planner's controls. Harmless on every other family: the scope is
    # intersected with the task values an entry actually offers, and a model
    # with no `task_type` offers none.
    "negative_prompt": ("text2music",),
}


def apply_groups(entry: dict) -> None:
    """Set `group` on every param, and `applies_when` where a task selector
    genuinely gates the control.

    Generation models only. Task-only entries have a handful of controls each,
    render on their own screens, and are left to the app's key-name classifier
    — the design's three group names do not describe a stem separator's form.
    Idempotent: both keys are dropped and rebuilt.
    """
    caps = entry["capabilities"]
    for param in caps["params"]:
        param.pop("group", None)
        param.pop("applies_when", None)
    if "generate" not in (caps.get("tasks") or ["generate"]):
        return
    offered = {choice["value"] for param in caps["params"]
               if param["key"] == "task_type"
               for choice in param["choices"]}
    for param in caps["params"]:
        key = param["key"]
        if key not in PARAM_GROUPS:
            raise KeyError(f"{entry['id']}: no group declared for param '{key}'")
        param["group"] = PARAM_GROUPS[key]
        # intersected with what this variant offers: the turbo DiTs drop the
        # three stem tasks, and gating a control on a task the model cannot run
        # would dim it against a value the user can never select
        scope = [t for t in ACE_TASK_SCOPE.get(key, ()) if t in offered]
        # keyscale/timesignature are scoped because the acestep LM (which
        # reads them) skips outside text2music. DiffSynth embeds them as
        # direct conditioning for every task — dimming them there would
        # claim the adapter ignores a value it honours.
        if entry["family"] == "diffsynthace" and key in ("keyscale",
                                                         "timesignature"):
            scope = []
        if scope:
            param["applies_when"] = {"param": "task_type", "values": scope}


def task_caps(tasks, params, est_realtime_factor=None):
    """Capabilities for task-only models. The generation-shaped fields are
    contract-required but ignored for non-generate tasks (documented in
    api-contract.md §5.4)."""
    caps = {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": 1, "default_s": 1},
        "sample_rate": 44100, "outputs_per_job_max": 1,
        "est_seconds_per_audio_second": 0,
        "tasks": tasks,
        "params": params,
    }
    if est_realtime_factor is not None:
        caps["est_realtime_factor"] = est_realtime_factor
    return caps


def task_entry(id_, family, repos, name, desc, caps, min_ram_gib, tier,
               license_, size_hint_bytes=0, **kwargs):
    """entry() plus a size hint for weightless entries whose weights are
    fetched by the adapter's own tooling at first use (size shown in the UI;
    main() only overrides sizes when HF reports > 0)."""
    e = entry(id_, family, repos, name, desc, caps, min_ram_gib, tier,
              license_, **kwargs)
    if size_hint_bytes and not repos:
        e["size_bytes"] = size_hint_bytes
        e["requirements"]["disk_bytes"] = size_hint_bytes
    return e


def melody_param():
    return {"key": "melody_audio", "type": "audio", "label": "Melody reference",
            "default": None, "nullable": True,
            "help": "Audio clip whose melody guides the generation "
                    "(chroma-based; the mix is used as-is)"}


def style_params():
    """MusicGen-Style's excerpt conditioning.

    The mirror image of the melody reference above, and worth stating plainly
    because they look identical on the wire and ride the same conditioning slot
    upstream: chroma keeps the tune and throws the timbre away, the style
    conditioner keeps the texture and throws the tune away.
    """
    return [
        {"key": "style_audio", "type": "audio", "label": "Style reference",
         "default": None, "nullable": True,
         "help": "Audio clip whose sound and texture the model imitates — the "
                 "melody is not copied"},
        {"key": "style_excerpt_s", "type": "float",
         "label": "Excerpt length (s)", "default": 3.0, "nullable": False,
         "min": 1.5, "max": 4.5, "step": 0.5,
         "help": "How much of the reference the model listens to. Shorter "
                 "excerpts generalise; longer ones copy more closely"},
    ]


def continue_param():
    """Trained continuation: the excerpt becomes the decoder's own prefix.

    This family and audiocraft are the only ones in the catalog with a trained
    audio-prompt path — everything else that "continues" is either diffusion
    inpainting past the end (Stable Audio 3) or a windowed re-decode. Offered
    only where the audio slot means continuation: on the melody checkpoints of
    the *transformers* backend, audio through the processor means chroma
    conditioning instead, which is a different mechanism wearing the same
    shape.
    """
    return {"key": "continue_audio", "type": "audio",
            "label": "Continue from", "default": None, "nullable": True,
            "help": "A track to carry on from. The model listens to its last "
                    "ten seconds and writes what comes next, in the same key, "
                    "tempo and instrumentation — it is continuing the "
                    "recording, not imitating it. The result is the new music "
                    "alone, so it butts straight onto the end of the source."}


def musicgen_caps(max_s=30, est=4.0, melody=False, style=False,
                  continuation=False):
    params = [
        {"key": "guidance_scale", "type": "float", "label": "Guidance",
         "default": 3.0, "nullable": False, "min": 1.0, "max": 15.0, "step": 0.5},
        {"key": "temperature", "type": "float", "label": "Temperature",
         "default": 1.0, "nullable": False, "min": 0.1, "max": 2.0, "step": 0.1},
        {"key": "top_k", "type": "int", "label": "Top-K", "default": 250,
         "nullable": False, "min": 10, "max": 1000},
        seed_param(),
    ]
    if continuation:
        params.insert(0, continue_param())
    if melody:
        params.insert(0, melody_param())
    if style:
        for offset, param in enumerate(style_params()):
            params.insert(offset, param)
    return {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": max_s, "default_s": 10,
                     "unlocked_max_s": UNLOCKED_MAX_S},
        "sample_rate": 32000, "outputs_per_job_max": TAKES_MAX,
        "est_seconds_per_audio_second": est,
        "params": params,
    }


def diffusers_caps(max_s, default_s, steps_default, guidance_default, est=3.0,
                   best_of=False):
    """`best_of` is not a preference — it is whether this checkpoint's text
    encoder has an audio tower to rank with. AudioLDM 2 and MusicLDM carry a
    full CLAP; AudioLDM 1 carries only its text half, so drawing several takes
    there would be drawing several takes and then keeping the first."""
    params = [
        {"key": "steps", "type": "int", "label": "Steps",
         "default": steps_default, "nullable": False, "min": 5, "max": 300},
        {"key": "guidance_scale", "type": "float", "label": "Guidance",
         "default": guidance_default, "nullable": False, "min": 1.0,
         "max": 15.0, "step": 0.5},
        {"key": "negative_prompt", "type": "string", "label": "Negative prompt",
         "default": "low quality, average quality", "nullable": False,
         "placeholder": "low quality"},
        seed_param(),
    ]
    if best_of:
        params.append(
            {"key": "candidates", "type": "int", "label": "Draw and pick best",
             "default": 1, "nullable": False, "min": 1, "max": 8,
             "help": "Draw this many takes in one pass and keep the one that "
                     "best matches your prompt, judged by the model's own "
                     "listener. Far cheaper than rendering them one at a "
                     "time, but memory and time still rise with the number."})
    return {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": max_s, "default_s": default_s,
                     "unlocked_max_s": UNLOCKED_MAX_S},
        "sample_rate": 16000, "outputs_per_job_max": TAKES_MAX,
        "est_seconds_per_audio_second": est,
        "params": params,
    }


def entry(id_, family, repos, name, desc, caps, min_ram_gib, tier, license_,
          notes=None, variant_of=None, format_=None, gated=False,
          settings=None, featured=False, ms_repos=None,
          size_hint_bytes=0):
    e = {
        "id": id_, "family": family, "featured": featured,
        "format": format_, "variant_of": variant_of,
        "display_name": name, "description": desc,
        "hf_repos": [r if isinstance(r, dict)
                     else {"repo_id": r, "gated": gated} for r in repos],
        "size_bytes": 0,  # filled below
        "capabilities": caps,
        "requirements": {"min_ram_bytes": min_ram_gib * GIB, "disk_bytes": 0,
                         "speed_tier": tier},
        "license": license_,
        "notes": notes,
    }
    if ms_repos:
        # ModelScope-hosted weights (engine download route D). Placed right
        # after hf_repos so the two sources read as one block in the JSON.
        rebuilt = {}
        for key, value in e.items():
            rebuilt[key] = value
            if key == "hf_repos":
                rebuilt["ms_repos"] = [r if isinstance(r, dict)
                                       else {"repo_id": r} for r in ms_repos]
        e = rebuilt
    if size_hint_bytes and not repos:
        # Route-B weights the adapter fetches itself: no repo to size, so
        # the shown size is this preset (main() only overwrites when a
        # lookup reports > 0).
        e["size_bytes"] = size_hint_bytes
        e["requirements"]["disk_bytes"] = size_hint_bytes
    if settings:
        e["settings"] = settings
    return e


CC_NC = {"name": "CC-BY-NC-4.0", "commercial_use": False,
         "requires_hf_token": False, "url": None}
CC_NC_SA = {"name": "CC-BY-NC-SA-4.0", "commercial_use": False,
            "requires_hf_token": False, "url": None}
MIT = {"name": "MIT", "commercial_use": True, "requires_hf_token": False,
       "url": None}
APACHE = {"name": "Apache-2.0", "commercial_use": True,
          "requires_hf_token": False, "url": None}
STABILITY = {"name": "Stability AI Community License", "commercial_use": False,
             "requires_hf_token": True, "url": None}
ACE_MIT = {"name": "MIT", "commercial_use": True, "requires_hf_token": False,
           "url": "https://github.com/ace-step/ACE-Step-1.5"}
# The mlx-community Whisper conversions carry no license file of their own.
# Upstream (openai/whisper) is MIT and the conversions are mechanical, so the
# term is inherited rather than asserted from nothing — but the provenance is
# named here rather than left to look like a first-party claim.
# LP-MusicCaps: the repository's own README states CC BY-NC 4.0, while its
# Hugging Face card's metadata says "mit". The stricter, first-party term is
# the one recorded — a non-commercial flag that turns out to be unnecessary
# costs a user nothing, and the reverse mistake costs them a licence breach.
LPMC_NC = {"name": "CC BY-NC 4.0", "commercial_use": False,
           "requires_hf_token": False,
           "url": "https://github.com/seungheondoh/lp-music-caps"}
WHISPER_MIT = {"name": "MIT (OpenAI Whisper)", "commercial_use": True,
               "requires_hf_token": False,
               "url": "https://github.com/openai/whisper/blob/main/LICENSE"}

ACE_CORE = "ACE-Step/Ace-Step1.5"

MINIMAX_LICENSE = {"name": "MiniMax-Music3 Community License",
                   "commercial_use": False, "requires_hf_token": False,
                   "url": "https://huggingface.co/MiniMaxAI/MiniMax-Music3"}


def minimax_mlx_entry(id_, repo, name, fmt, min_ram_gib, est, desc, notes):
    caps = {
        "supports_lyrics": True, "instrumental_only": False,
        "duration": {"min_s": 10, "max_s": 300, "default_s": 90},
        "sample_rate": 44100, "outputs_per_job_max": 1,
        "est_seconds_per_audio_second": est,
        "params": [
            {"key": "steps", "type": "int", "label": "Steps", "default": 30,
             "nullable": False, "min": 1, "max": 30},
            # Nullable and null by default: upstream hard-codes 1.7 at the
            # `denoise_chunk` call site, and leaving this blank keeps exactly
            # that. Set it and the adapter intercepts the call. 1.0 disables
            # the guidance branch entirely, which also halves the DiT stage's
            # work — the one setting here that changes the render time.
            {"key": "cfg_scale", "type": "float", "label": "Guidance",
             "default": None, "nullable": True, "min": 1.0, "max": 6.0,
             "step": 0.1,
             "help": "How hard the model is pushed towards your description "
                     "and lyrics. Left blank it uses the value MiniMax tuned "
                     "the model around (1.7). 1.0 turns guidance off, which "
                     "renders about twice as fast and much less literally."},
            seed_param(),
        ],
        "lyrics_tags": ["[intro]", "[verse]", "[pre-chorus]", "[chorus]",
                        "[post-chorus]", "[bridge]", "[instrumental]",
                        "[solo]", "[outro]"],
        "lyrics_hint": ("Section tags on their own lines shape the song; "
                        "lyrics drive structure and overall length."),
    }
    return entry(id_, "mlxaudio", [repo], name, desc, caps, min_ram_gib,
                 "medium", MINIMAX_LICENSE, notes=notes,
                 variant_of="minimax-music3", format_=fmt)


# Upstream acestep/constants.py TRACK_NAMES — the lego/extract/complete
# track classes (rides the instruction prompt, built adapter-side).
ACE_TRACK_NAMES = ["woodwinds", "brass", "fx", "synth", "strings",
                   "percussion", "keyboard", "guitar", "bass", "drums",
                   "backing_vocals", "vocals"]


ASSIST_KINDS = [
    "interview", "interview_finish", "flesh_out", "lyrics", "pick_model",
    "plan_song", "route_intent", "brief", "translate_lyrics", "describe_song",
    "more_like_this", "critique_fix", "name_and_tag",
]


def assistant_params():
    """Every assist job is (kind, input) — and neither is user-typed.

    The app picks the kind from the card the user opened and builds the input
    from what is on screen, so both are internal. `temperature` is the one
    knob worth exposing: the difference between a safe title and an
    interesting one.
    """
    return [
        {"key": "kind", "type": "enum", "label": "What to write",
         "default": "flesh_out", "nullable": False, "internal": True,
         "choices": [{"value": k, "label": k.replace("_", " ").title()}
                     for k in ASSIST_KINDS]},
        {"key": "assist_input", "type": "json", "label": "Input",
         "default": None, "nullable": False, "internal": True},
        {"key": "target_family", "type": "string", "label": "Writing for",
         "default": None, "nullable": True, "internal": True},
        {"key": "temperature", "type": "float", "label": "Variety",
         "default": 0.7, "nullable": False, "min": 0.0, "max": 1.5,
         "step": 0.05},
        {"key": "max_tokens", "type": "int", "label": "Length limit",
         "default": None, "nullable": True, "min": 64, "max": 2048,
         "internal": True},
    ]


def assistant_entries():
    base = task_entry(
        "assistant-qwen", "assistant",
        ["mlx-community/Qwen2.5-1.5B-Instruct-4bit"],
        "Writing assistant",
        "A small language model that runs on your Mac and helps you write: "
        "it interviews you about the music you want, fleshes out a rough "
        "idea into a full description in the form your chosen model "
        "understands, drafts lyrics with the right section tags, and names "
        "and tags finished songs for your library.",
        task_caps(["assist"], assistant_params(), est_realtime_factor=0.05),
        4, "fast", APACHE, featured=True,
        size_hint_bytes=880_000_000,
        notes="Runs on MLX. Small enough to stay loaded alongside a music "
              "model rather than displacing it.")
    light = task_entry(
        "assistant-llama-1b", "assistant",
        ["mlx-community/Llama-3.2-1B-Instruct-4bit"],
        "Writing assistant (lighter)",
        "A smaller, faster writing assistant for machines where memory is "
        "tight. Quicker to answer and less reliable at long lyrics.",
        task_caps(["assist"], assistant_params(), est_realtime_factor=0.03),
        4, "fast",
        {"name": "Llama 3.2 Community License", "commercial_use": True,
         "requires_hf_token": False,
         "url": "https://github.com/meta-llama/llama-models/blob/main/models/"
                "llama3_2/LICENSE"},
        size_hint_bytes=710_000_000,
        variant_of="assistant-qwen", format_="1B")
    return [base, light]


def ace_plan_params():
    """The planning half of ACE-Step, made visible and steerable.

    ACE-Step renders in two stages: a 5 Hz language model writes a plan — a
    `<think>` block naming tempo, key, time signature, language and a rewritten
    caption, then a stream of coarse audio codes sketching the whole song — and
    the DiT renders that plan into audio. Until now the plan was invisible and
    unsteerable: the app sent a prompt and got back a wav.

    These params open it. `keyscale`/`timesignature` join the existing `bpm` as
    facts you can pin instead of leaving to the model. The `use_cot_*` switches
    say which of the remaining blanks it may fill. The `lm_*` knobs are its
    sampler. And `audio_codes` accepts a plan captured from an earlier take,
    which is what makes "keep this song, change how it sounds" possible at all.

    All of them are scoped to text2music by ACE_TASK_SCOPE, because the five
    src-audio tasks skip the LM.
    """
    return [
        {"key": "keyscale", "type": "string", "label": "Key",
         "default": None, "nullable": True,
         "placeholder": "e.g. F minor"},
        {"key": "timesignature", "type": "string", "label": "Time signature",
         "default": None, "nullable": True, "placeholder": "e.g. 4"},
        {"key": "use_cot_metas", "type": "bool", "label": "Model picks tempo & key",
         "default": True, "nullable": False},
        {"key": "use_cot_caption", "type": "bool",
         "label": "Model rewrites the description", "default": True,
         "nullable": False},
        {"key": "use_cot_language", "type": "bool",
         "label": "Model detects the language", "default": True,
         "nullable": False},
        {"key": "lm_temperature", "type": "float", "label": "Planner variety",
         "default": 0.85, "nullable": False, "min": 0.0, "max": 2.0,
         "step": 0.05},
        {"key": "lm_cfg_scale", "type": "float", "label": "Planner guidance",
         "default": 2.0, "nullable": False, "min": 1.0, "max": 8.0,
         "step": 0.5},
        {"key": "lm_top_p", "type": "float", "label": "Planner nucleus",
         "default": 0.9, "nullable": False, "min": 0.1, "max": 1.0,
         "step": 0.05},
        # Internal: a code string is thousands of opaque tokens, and the only
        # honest way to obtain one is to have kept it from a plan the app
        # already ran.
        {"key": "audio_codes", "type": "string", "label": "Captured plan",
         "default": None, "nullable": True, "internal": True},
    ]


def ace_plan_task_params():
    """Inputs for the promptless `plan` task.

    A `plan` job carries no top-level prompt (the contract reserves that for
    generate), so the caption and lyrics ride params of their own. Internal
    throughout: the app populates them from whatever the user typed on the
    Generate form, and there is no version of this form a person fills in by
    hand.
    """
    return [
        {"key": "plan_caption", "type": "string", "label": "Description",
         "default": None, "nullable": True, "internal": True},
        {"key": "plan_lyrics", "type": "string", "label": "Lyrics",
         "default": None, "nullable": True, "internal": True},
        {"key": "plan_count", "type": "int", "label": "How many plans",
         "default": 3, "nullable": False, "min": 1, "max": 6,
         "internal": True},
        # `duration_s` is a top-level job field the contract reserves for
        # generate jobs, so a promptless plan job cannot use it and needs its
        # own. It bounds how many codes the planner emits (5 per second).
        {"key": "plan_duration_s", "type": "float", "label": "Length",
         "default": None, "nullable": True, "min": 10.0, "max": 300.0,
         "internal": True},
    ]


def ace_task_params(full, flow_edit=True):
    """SR3 task-mode params. full=True (base/sft DiTs) adds extract/lego/
    complete + the track class; turbo DiTs support text2music/cover/repaint
    only (enforced again in the adapter).

    `flow_edit=False` for the acestep.cpp runtime: FlowEdit is a feature of the
    Python pipeline's sampler and has no field in the C++ request schema, so
    offering it there would be a control with nowhere to go."""
    choices = [
        {"value": "text2music", "label": "Generate"},
        {"value": "cover", "label": "Cover / restyle"},
        {"value": "repaint", "label": "Repaint a section"},
    ]
    if full:
        choices += [
            {"value": "extract", "label": "Extract a stem (AI)"},
            {"value": "lego", "label": "Add a layer"},
            {"value": "complete", "label": "Complete the band"},
        ]
    params = [
        {"key": "task_type", "type": "enum", "label": "Task",
         "default": "text2music", "nullable": False, "choices": choices,
         # The stem-task caveat is measured, not hedging. On a clip of piano
         # then drums (2026-09-04, XL SFT): asking for the keyboard track
         # dropped the drums-only half by 5.3 dB while keeping the piano half —
         # it responds to the track class — but nothing came back isolated.
         # Cover and repaint, on the same plumbing, are exact.
         "help": "What to do with the source audio (if any). Cover and "
                 "repaint are precise. The three stem tasks are the model "
                 "re-imagining a part rather than separating one — for a "
                 "clean split, use a separation model instead"},
        {"key": "src_audio", "type": "audio", "label": "Source audio",
         "default": None, "nullable": True,
         "help": "Required for every task except Generate; output length "
                 "locks to this file"},
        {"key": "reference_audio", "type": "audio", "label": "Style reference",
         "default": None, "nullable": True,
         "help": "Optional style reference for Cover"},
        # Nullable, and null by default, which is the other half of the fix.
        # The app's generic parameter form seeds every key from its declared
        # default and submits the lot, so a *non-nullable* 0.7 here meant every
        # ACE-Step job carried a 70 % source blend — including plain
        # text-to-music from Studio, where there is no source to blend against
        # and the DiT still switches conditioning at `int(steps * 0.7)`.
        # Absent, upstream applies its own default of 1.0: honour the source
        # completely. The control still opens at 0.7 wherever it is drawn,
        # because the app reads the slider's home position from these bounds
        # rather than from the wire value.
        {"key": "audio_cover_strength", "type": "float",
         "label": "Source strength", "default": None, "nullable": True,
         "min": 0.0, "max": 1.0, "step": 0.05,
         "help": "How strongly the source shapes the result — lower (0.2) is "
                 "closer to pure style transfer. Applies to every task that "
                 "takes a source, not only Cover"},
        {"key": "repainting_start", "type": "float",
         "label": "Repaint start (s)", "default": None, "nullable": True,
         "min": 0.0, "max": 600.0, "step": 0.1},
        {"key": "repainting_end", "type": "float", "label": "Repaint end (s)",
         "default": None, "nullable": True, "min": -1.0, "max": 600.0,
         "step": 0.1},
    ]
    if flow_edit:
        # Back where they were before the flag existed: after the source
        # strength, before the repaint window.
        params[4:4] = [
            {"key": "flow_edit_morph", "type": "bool", "label": "Morph",
             "default": False, "nullable": False,
             "help": "Rewrite the source from one description into another "
                     "(FlowEdit). Needs a source audio file; works on the "
                     "Turbo DiT, unlike extract/layer/complete"},
            {"key": "flow_edit_source_caption", "type": "string",
             "label": "Source description", "default": None,
             "nullable": True,
             "placeholder": "e.g. upbeat electropop with a female vocal",
             "help": "What the source is now — a morph travels from this "
                     "description to the prompt. Left empty it morphs away "
                     "from nothing in particular, which blurs the result"},
        ]
    if full:
        params.append(
            {"key": "track", "type": "enum", "label": "Track class",
             "default": None, "nullable": True,
             "choices": [{"value": t, "label": t.replace("_", " ").title()}
                         for t in ACE_TRACK_NAMES],
             "help": "Stem to extract / layer to add (Extract, Add a layer, "
                     "Complete)"})
    return params


def ace_variant(id_, dit_repo, dit_config, name, fmt, steps, shift, est,
                min_ram_gib, tier, desc):
    full_tasks = "turbo" not in dit_config
    if full_tasks:
        desc = desc + (" Supports the full task set: cover, repaint, "
                       "AI stem extract, add-a-layer, complete-the-band.")
    else:
        desc = desc + (" Tasks: cover and repaint (extract/layer/complete "
                       "need a Base or SFT DiT).")
    caps = {
        "supports_lyrics": True, "instrumental_only": False,
        # 10~600 is the range upstream documents for its own `duration`
        # parameter (acestep/inference.py, `generate_music` docstring), and
        # acestep.cpp clamps to exactly 600 in metadata-fsm.h — two
        # independent runtimes agreeing on the same ceiling. Nothing in the
        # adapter clamps, so this number is the whole ceiling.
        "duration": {"min_s": 10, "max_s": 600, "default_s": 60,
                     "unlocked_max_s": ACESTEP_UNLOCKED_MAX_S},
        "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
        "lyrics_tags": ["[intro]", "[verse]", "[pre-chorus]", "[chorus]",
                        "[bridge]", "[instrumental]", "[outro]"],
        "lyrics_hint": ("Section tags on their own lines structure the song; "
                        "leave a blank line between sections."),
        "est_seconds_per_audio_second": est,
        "params": [
            {"key": "steps", "type": "int", "label": "Steps", "default": steps,
             "nullable": False, "min": 4, "max": 200},
            {"key": "guidance_scale", "type": "float", "label": "Guidance",
             "default": 7.0, "nullable": False, "min": 1.0, "max": 15.0,
             "step": 0.5},
            {"key": "thinking", "type": "bool", "label": "LM reasoning",
             "default": True, "nullable": False},
            {"key": "bpm", "type": "int", "label": "BPM", "default": None,
             "nullable": True, "min": 40, "max": 220},
            # The adapter has always read this and always defaulted it to "en";
            # only the hand-written base entry declared it, so on every variant
            # the control was missing and every song was sung in English
            # whatever the prompt asked for.
            {"key": "vocal_language", "type": "enum",
             "label": "Vocal language", "default": "en", "nullable": False,
             "choices": [{"value": "en", "label": "English"},
                         {"value": "de", "label": "German"},
                         {"value": "es", "label": "Spanish"},
                         {"value": "fr", "label": "French"},
                         {"value": "ja", "label": "Japanese"},
                         {"value": "ko", "label": "Korean"},
                         {"value": "zh", "label": "Chinese"}],
             "help": "Which language the model should sing in. Write the "
                     "lyrics in that language too: this tells the model how "
                     "to pronounce them, it does not translate."},
            seed_param(),
            *ace_plan_params(),
            *ace_plan_task_params(),
            *ace_task_params(full=full_tasks),
        ],
        # `plan` runs only the LM half — cheap, and the result is a plan the
        # user can read and choose between before committing to a render.
        "tasks": ["generate", "plan"],
    }
    return entry(id_, "acestep", [ACE_CORE, dit_repo], name, desc, caps,
                 min_ram_gib, tier, ACE_MIT, variant_of="acestep-base",
                 format_=fmt,
                 settings={"dit_config": dit_config, "dit_repo": dit_repo,
                           "shift": shift})


ACESTEP_CPP_CORE = [
    "Qwen3-Embedding-0.6B-Q8_0.gguf",
    "acestep-5Hz-lm-4B-Q8_0.gguf",
    "vae-BF16.gguf",
]


# The XL-SFT LoRA pack, mirrored per-file from the DiffSynth release. Offered
# on the acestep.cpp XL-SFT entry alone: these were trained against the XL SFT
# checkpoint, and the runtime merges them straight into its quantised weights
# (`adapter-merge.h` names Q8_0 and the K-quants). The same four repos feed the
# diffsynthace family, so a user who has both pays for them once.
ACESTEP_CPP_LORAS = {
    "music": "rtikw/acestep15xlsft-lora-music",
    "piano": "rtikw/acestep15xlsft-lora-piano",
    "guitar": "rtikw/acestep15xlsft-lora-guitar",
    "drums": "rtikw/acestep15xlsft-lora-drums",
}


def acestep_cpp_plan_params():
    """The composer LM's own surface, which this runtime had all along.

    Every one of these is a field of the C++ `AceRequest` struct
    (`src/request.h`) that the adapter never filled: the facts the planner
    would otherwise invent, its sampler, and the negative prompt that steers
    the PLAN rather than the render. Scoped to text2music by ACE_TASK_SCOPE,
    because the source-audio tasks skip the LM entirely.
    """
    return [
        {"key": "keyscale", "type": "string", "label": "Key",
         "default": None, "nullable": True, "placeholder": "e.g. F minor"},
        {"key": "timesignature", "type": "string", "label": "Time signature",
         "default": None, "nullable": True, "placeholder": "e.g. 4"},
        {"key": "vocal_language", "type": "enum", "label": "Vocal language",
         "default": None, "nullable": True,
         "choices": [{"value": "en", "label": "English"},
                     {"value": "de", "label": "German"},
                     {"value": "es", "label": "Spanish"},
                     {"value": "fr", "label": "French"},
                     {"value": "ja", "label": "Japanese"},
                     {"value": "ko", "label": "Korean"},
                     {"value": "zh", "label": "Chinese"}]},
        {"key": "negative_prompt", "type": "string",
         "label": "Planner negative prompt", "default": None,
         "nullable": True, "placeholder": "e.g. spoken word, applause",
         "help": "What the composer should steer the PLAN away from — the "
                 "arrangement it writes, not the sound of the render. It "
                 "works through the planner's own guidance, below."},
        {"key": "lm_temperature", "type": "float", "label": "Planner variety",
         "default": None, "nullable": True, "min": 0.0, "max": 2.0,
         "step": 0.05},
        {"key": "lm_cfg_scale", "type": "float", "label": "Planner guidance",
         "default": None, "nullable": True, "min": 1.0, "max": 8.0,
         "step": 0.5},
        {"key": "lm_top_p", "type": "float", "label": "Planner nucleus",
         "default": None, "nullable": True, "min": 0.1, "max": 1.0,
         "step": 0.05},
    ]


def acestep_cpp_entry(id_, dit_file, name, fmt, steps, est, min_ram_gib, tier,
                      desc, notes=None, loras=False):
    # Same rule the Python family follows, from the same place: the three stem
    # tasks need a base or SFT DiT, and the turbo distillations cannot run
    # them.
    full_tasks = "turbo" not in dit_file
    caps = {
        "supports_lyrics": True, "instrumental_only": False,
        # The C++ runtime clamps duration to 600 itself (metadata-fsm.h:
        # `if (aces[i].duration > 600) aces[i].duration = 600.0f`), which is
        # the same ceiling the PyTorch pipeline documents. Asking for more
        # would be silently truncated down there rather than refused here.
        "duration": {"min_s": 10, "max_s": 600, "default_s": 60},
        "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
        "lyrics_tags": ["[intro]", "[verse]", "[pre-chorus]", "[chorus]",
                        "[bridge]", "[instrumental]", "[outro]"],
        "lyrics_hint": ("Section tags on their own lines structure the song; "
                        "leave a blank line between sections. The composer "
                        "LM treats the requested length as a suggestion — "
                        "the song ends where the music does."),
        "est_seconds_per_audio_second": est,
        "params": [
            {"key": "steps", "type": "int", "label": "Steps", "default": steps,
             "nullable": False, "min": 4, "max": 200},
            {"key": "guidance_scale", "type": "float", "label": "Guidance",
             "default": 1.0, "nullable": False, "min": 1.0, "max": 15.0,
             "step": 0.5},
            {"key": "thinking", "type": "bool", "label": "LM reasoning",
             "default": True, "nullable": False},
            {"key": "bpm", "type": "int", "label": "BPM", "default": None,
             "nullable": True, "min": 40, "max": 220},
            seed_param(),
            *acestep_cpp_plan_params(),
            *ace_task_params(full=full_tasks, flow_edit=False),
        ],
    }
    repos = [{"repo_id": "Serveurperso/ACE-Step-1.5-GGUF", "gated": False,
              "allow_patterns": ACESTEP_CPP_CORE + [dit_file]}]
    settings = {"lm_model": "acestep-5Hz-lm-4B-Q8_0.gguf",
                "synth_model": dit_file,
                "vae": "vae-BF16.gguf"}
    if loras:
        caps["params"] += [
            {"key": "adapter", "type": "enum", "label": "Style LoRA",
             "default": "none", "nullable": False,
             "choices": ([{"value": "none", "label": "None"}]
                         + [{"value": k, "label": k.title()}
                            for k in ACESTEP_CPP_LORAS]),
             "help": "A small trained overlay merged into the model before "
                     "it renders. Each one pulls the whole model towards one "
                     "kind of music — the instrument it is named for, played "
                     "front and centre."},
            {"key": "adapter_scale", "type": "float", "label": "LoRA strength",
             "default": 1.0, "nullable": False, "min": 0.0, "max": 2.0,
             "step": 0.05,
             "help": "How much of the overlay is applied. 1.0 is the strength "
                     "it was trained at; below that blends back towards the "
                     "base model, above exaggerates it and can distort."},
        ]
        repos += [{"repo_id": repo, "gated": False}
                  for repo in ACESTEP_CPP_LORAS.values()]
        settings["adapters"] = dict(ACESTEP_CPP_LORAS)
    return entry(
        id_, "acestepcpp", repos,
        name, desc, caps, min_ram_gib, tier, ACE_MIT,
        notes=notes or ("Runs via acestep.cpp (GGML). The text encoder, "
                        "composer LM and VAE are shared between all GGUF "
                        "variants — only the DiT differs."),
        variant_of="acestep-base", format_=fmt,
        settings=settings)


# audiocraft's T5 conditioner loads t5-base by name; listing it as a
# pattern-scoped second repo pre-seeds the cache through our downloader.
# (t5-base ships no tokenizer_config.json; a pattern matching zero repo files
# would leave the entry permanently "not installed")
T5_BASE = {"repo_id": "t5-base", "gated": False,
           "allow_patterns": ["config.json", "generation_config.json",
                              "spiece.model", "tokenizer.json",
                              "model.safetensors"]}

AUDIOCRAFT_FILES = ["state_dict.bin", "compression_state_dict.bin"]

# MusicGen-Style's conditioner builds its own feature extractor at load time,
# from the HF hub, with no offline flag set anywhere — so without this the first
# style generation stops mid-job to download a model the install never
# accounted for, and the size shown before installing is wrong by a third of a
# gigabyte.
#
# Which extractor is not a guess. The shipped checkpoint's own config
# (`xp.cfg.conditioners.self_wav.style.model_name`) reads **`mert`**, so
# `FeatureExtractor.__init__` takes the `AutoModel.from_pretrained(
# "m-a-p/MERT-v1-95M", trust_remote_code=True)` branch and never touches the
# `encodec_checkpoint` field sitting next to it. Listing the EnCodec would
# download 300 MB that is never opened while leaving the real dependency to be
# fetched mid-job. No allow_patterns: `trust_remote_code` needs the repo's own
# modelling code, not just its weights.
STYLE_FEATURE_EXTRACTOR = {"repo_id": "m-a-p/MERT-v1-95M", "gated": False}


def magnet_entry(id_, repo, name, seconds, min_ram_gib, tier, est, desc,
                 variant_of=None, format_=None, notes=None):
    caps = {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": seconds, "max_s": seconds, "default_s": seconds},
        "sample_rate": 32000, "outputs_per_job_max": TAKES_MAX,
        "est_seconds_per_audio_second": est,
        "params": [
            {"key": "temperature", "type": "float", "label": "Temperature",
             "default": 3.0, "nullable": False, "min": 0.5, "max": 10.0,
             "step": 0.5},
            {"key": "top_p", "type": "float", "label": "Top-P", "default": 0.9,
             "nullable": False, "min": 0.1, "max": 1.0, "step": 0.05},
            seed_param(),
        ],
    }
    return entry(
        id_, "audiocraft",
        [{"repo_id": repo, "gated": False, "allow_patterns": AUDIOCRAFT_FILES},
         T5_BASE],
        name, desc, caps, min_ram_gib, tier, CC_NC,
        variant_of=variant_of, format_=format_ or f"{seconds} s clips",
        notes=notes or ("Non-autoregressive decoder — always generates "
                        f"{seconds}-second clips, much faster than MusicGen "
                        "at the same size."),
        settings={"kind": "magnet"})


def audiocraft_musicgen_entry(id_, repo, name, min_ram_gib, tier, est, desc,
                              melody=False, style=False, notes=None,
                              license_=None):
    # Continuation everywhere in this family: audiocraft's own
    # `generate_continuation` lives on the base class, and melody/style ride a
    # different conditioning slot, so a checkpoint can offer both.
    caps = musicgen_caps(est=est, melody=melody, style=style,
                         continuation=True)
    settings = {"kind": "musicgen"}
    if melody:
        settings["melody"] = True
    if style:
        settings["style"] = True
    repos = [{"repo_id": repo, "gated": False,
              "allow_patterns": AUDIOCRAFT_FILES}, T5_BASE]
    if style:
        repos.append(STYLE_FEATURE_EXTRACTOR)
    return entry(
        id_, "audiocraft", repos,
        name, desc, caps, min_ram_gib, tier, license_ or CC_NC, notes=notes,
        settings=settings)


NEW_ENTRIES = [
    # ---- audiocraft runtime (MAGNeT + audiocraft-format checkpoints) ------
    magnet_entry("magnet-small-10s", "facebook/magnet-small-10secs",
                 "MAGNeT Small", 10, 8, "fast", 0.8,
                 "Meta's non-autoregressive model — 10-second clips in a "
                 "couple of seconds of compute."),
    magnet_entry("magnet-small-30s", "facebook/magnet-small-30secs",
                 "MAGNeT Small (30 s)", 30, 8, "fast", 0.8,
                 "MAGNeT Small trained for 30-second clips.",
                 variant_of="magnet-small-10s"),
    magnet_entry("hybrid-magnet-small", "facebook/hybrid-magnet-small",
                 "MAGNeT Small (hybrid)", 30, 8, "fast", 1.0,
                 "Hybrid MAGNeT: an autoregressive first stage for better "
                 "structure, non-AR refinement for speed. 30-second clips.",
                 variant_of="magnet-small-10s", format_="hybrid · 30 s"),
    magnet_entry("magnet-medium-30s", "facebook/magnet-medium-30secs",
                 "MAGNeT Medium", 30, 16, "fast", 0.8,
                 "Bigger MAGNeT generating 30-second clips, still far faster "
                 "than autoregressive models."),
    magnet_entry("magnet-medium-10s", "facebook/magnet-medium-10secs",
                 "MAGNeT Medium (10 s)", 10, 16, "fast", 0.8,
                 "MAGNeT Medium trained for 10-second clips.",
                 variant_of="magnet-medium-30s"),
    magnet_entry("hybrid-magnet-medium", "facebook/hybrid-magnet-medium",
                 "MAGNeT Medium (hybrid)", 30, 16, "fast", 1.0,
                 "Hybrid MAGNeT Medium: AR first stage for structure, non-AR "
                 "refinement for speed. 30-second clips.",
                 variant_of="magnet-medium-30s", format_="hybrid · 30 s"),
    # (micro-musicgen-acid deliberately omitted: its audiocraft checkpoint is
    # fully unconditional — conditioners: None — and audiocraft's loader
    # crashes on it without checkpoint-specific surgery)
    audiocraft_musicgen_entry(
        "musicgen-style", "facebook/musicgen-style", "MusicGen Style",
        16, "medium", 5.0,
        "Give it a few seconds of audio and it writes new music that sounds "
        "like it — texture and production, not the tune.",
        style=True,
        notes="audiocraft-format checkpoint (no transformers port). The style "
              "excerpt is imitated, never reproduced: for the melody instead, "
              "use a MusicGen Melody build. Ships with MERT, which the style "
              "conditioner loads to read the excerpt."),
    audiocraft_musicgen_entry(
        "musicgen-songstarter", "nateraw/musicgen-songstarter-v0.2",
        "MusicGen Songstarter", 16, "medium", 5.5,
        "The best-known community MusicGen finetune — stereo samples aimed "
        "at song ideas; supports a melody reference.",
        melody=True,
        notes="Community finetune of MusicGen Stereo Melody by nateraw; "
              "audiocraft-format only."),
    # ---- ACE-Step 1.5 on acestep.cpp (GGUF + Metal) -----------------------
    # Standard 2B DiT (Q8, ~2.4 GB each; core stack shared between variants)
    acestep_cpp_entry(
        "acestep-cpp-turbo", "acestep-v15-turbo-Q8_0.gguf",
        "ACE-Step 1.5 (GGUF)", "GGUF · turbo", 8, 1.0, 12, "fast",
        "ACE-Step 1.5 Turbo on the native C++ Metal runtime (acestep.cpp) — "
        "quantized 8-bit stack with the 4B composer LM.",
        notes="Runs via acestep.cpp (GGML). Binaries build once with "
              "scripts/build_acestep_cpp.sh."),
    acestep_cpp_entry(
        "acestep-cpp-sftturbo50", "acestep-v15-sftturbo50-Q8_0.gguf",
        "ACE-Step 1.5 SFT-Turbo (GGUF)", "GGUF · sft-turbo merge", 8, 1.0,
        12, "fast",
        "Community SFT/Turbo weight merge — Turbo's 8-step speed with some of "
        "the SFT model's richness. Only available on the GGUF runtime."),
    acestep_cpp_entry(
        "acestep-cpp-base", "acestep-v15-base-Q8_0.gguf",
        "ACE-Step 1.5 Base (GGUF)", "GGUF · base", 50, 3.0, 12, "medium",
        "Non-distilled DiT on the C++ runtime: slower, often richer detail "
        "than Turbo."),
    acestep_cpp_entry(
        "acestep-cpp-sft", "acestep-v15-sft-Q8_0.gguf",
        "ACE-Step 1.5 SFT (GGUF)", "GGUF · sft", 50, 3.0, 12, "medium",
        "Supervised-finetuned DiT on the C++ runtime."),
    # XL 4B DiT (Q8, ~5 GB each) — the quantized route to XL quality on Macs
    # that can't fit the 48 GB Python XL variants
    acestep_cpp_entry(
        "acestep-cpp-xl-turbo", "acestep-v15-xl-turbo-Q8_0.gguf",
        "ACE-Step 1.5 XL Turbo (GGUF)", "GGUF · XL turbo", 8, 1.5, 16, "fast",
        "The big 4B DiT, distilled for 8 steps and quantized to 8-bit — XL "
        "quality without the 48 GB requirement of the Python XL variants."),
    acestep_cpp_entry(
        "acestep-cpp-xl-sftturbo50", "acestep-v15-xl-sftturbo50-Q8_0.gguf",
        "ACE-Step 1.5 XL SFT-Turbo (GGUF)", "GGUF · XL sft-turbo merge", 8,
        1.5, 16, "fast",
        "Community SFT/Turbo merge of the big 4B DiT — 8-step speed with "
        "extra richness. Only available on the GGUF runtime."),
    acestep_cpp_entry(
        "acestep-cpp-xl-sft", "acestep-v15-xl-sft-Q8_0.gguf",
        "ACE-Step 1.5 XL SFT (GGUF)", "GGUF · XL sft", 50, 5.0, 16, "slow",
        "The big supervised-finetuned DiT at full step count, quantized to "
        "8-bit — and the only GGUF entry that takes the XL LoRA pack, which "
        "was trained against exactly this checkpoint.",
        loras=True),
    acestep_cpp_entry(
        "acestep-cpp-xl-base", "acestep-v15-xl-base-Q8_0.gguf",
        "ACE-Step 1.5 XL Base (GGUF)", "GGUF · XL base", 50, 5.0, 16, "slow",
        "The big non-distilled DiT, quantized to 8-bit."),
    # ---- MiniMax Music 3 on MLX (mlx-audio runtime) -----------------------
    minimax_mlx_entry(
        "minimax-music3-mlx", "mlx-community/MiniMax-Music3-mxfp8",
        "MiniMax Music 3 (MLX)", "MLX mxfp8", 24, 1.5,
        "Native Apple Silicon build of MiniMax Music 3 — a quarter of the "
        "memory of the full model, and faster.",
        "mlx-community conversion running on the mlx-audio runtime. "
        "Same community license as the full model."),
    minimax_mlx_entry(
        "minimax-music3-mlx-small", "mlx-community/MiniMax-Music3-mxfp4",
        "MiniMax Music 3 (MLX small)", "MLX mxfp4", 16, 1.5,
        "Smallest MiniMax Music 3 build (~9 GB) — fits 16 GB Macs.",
        "Experimental mxfp4 quantization: may alter or omit sung words more "
        "often than the mxfp8 build. Same community license as the full "
        "model."),
    minimax_mlx_entry(
        "minimax-music3-mlx-bf16", "mlx-community/MiniMax-Music3-bf16",
        "MiniMax Music 3 (MLX bf16)", "MLX bf16", 48, 2.0,
        "Full-precision MLX build (~29 GB) — the highest-quality MiniMax "
        "option that still halves the memory of the torch pipeline.",
        "Dense bf16 conversion on the mlx-audio runtime. Same community "
        "license as the full model."),
    # ---- MusicGen on MLX (same snapshots, faster runtime) -----------------
    entry("musicgen-small-mlx", "musicgen", ["facebook/musicgen-small"],
          "MusicGen Small (MLX)",
          "MusicGen Small on the native Apple Silicon MLX runtime — same "
          "weights, much faster.",
          musicgen_caps(est=1.0), 8, "fast", CC_NC,
          variant_of="musicgen-small", format_="MLX",
          settings={"backend": "mlx"}),
    entry("musicgen-medium-mlx", "musicgen", ["facebook/musicgen-medium"],
          "MusicGen Medium (MLX)",
          "MusicGen Medium on the native Apple Silicon MLX runtime — same "
          "weights, much faster.",
          musicgen_caps(est=2.0), 16, "medium", CC_NC,
          variant_of="musicgen-medium", format_="MLX",
          settings={"backend": "mlx"}),
    entry("musicgen-large-mlx", "musicgen", ["facebook/musicgen-large"],
          "MusicGen Large (MLX)",
          "MusicGen Large on the native Apple Silicon MLX runtime — same "
          "weights, much faster.",
          musicgen_caps(est=4.0), 24, "medium", CC_NC,
          variant_of="musicgen-large", format_="MLX",
          settings={"backend": "mlx"}),
    # ---- MusicGen roster --------------------------------------------------
    entry("musicgen-large", "musicgen", ["facebook/musicgen-large"],
          "MusicGen Large", "Meta's biggest instrumental model — best quality, slowest.",
          musicgen_caps(est=8.0, continuation=True), 24, "slow", CC_NC,
          format_="mono"),
    entry("musicgen-melody", "musicgen", ["facebook/musicgen-melody"],
          "MusicGen Melody",
          "Melody-conditioned MusicGen; also generates from text alone.",
          musicgen_caps(est=4.5, melody=True), 16, "medium", CC_NC, format_="mono"),
    entry("musicgen-melody-large", "musicgen", ["facebook/musicgen-melody-large"],
          "MusicGen Melody Large",
          "Large melody-conditioned MusicGen; text-only generation works too.",
          musicgen_caps(est=8.0, melody=True), 32, "slow", CC_NC, format_="mono"),
    entry("musicgen-stereo-small", "musicgen", ["facebook/musicgen-stereo-small"],
          "MusicGen Small (stereo)", "Stereo decoder variant of MusicGen Small.",
          musicgen_caps(est=2.0, continuation=True), 8, "fast", CC_NC,
          variant_of="musicgen-small", format_="stereo"),
    entry("musicgen-stereo-medium", "musicgen", ["facebook/musicgen-stereo-medium"],
          "MusicGen Medium (stereo)", "Stereo decoder variant of MusicGen Medium.",
          musicgen_caps(est=4.5, continuation=True), 16, "medium", CC_NC,
          variant_of="musicgen-medium", format_="stereo"),
    entry("musicgen-stereo-large", "musicgen", ["facebook/musicgen-stereo-large"],
          "MusicGen Large (stereo)", "Stereo decoder variant of MusicGen Large.",
          musicgen_caps(est=8.5, continuation=True), 24, "slow", CC_NC,
          variant_of="musicgen-large", format_="stereo"),
    entry("musicgen-stereo-melody", "musicgen", ["facebook/musicgen-stereo-melody"],
          "MusicGen Melody (stereo)", "Stereo variant of MusicGen Melody.",
          musicgen_caps(est=5.0, melody=True), 16, "medium", CC_NC,
          variant_of="musicgen-melody", format_="stereo"),
    entry("musicgen-stereo-melody-large", "musicgen",
          ["facebook/musicgen-stereo-melody-large"],
          "MusicGen Melody Large (stereo)",
          "Stereo variant of MusicGen Melody Large.",
          musicgen_caps(est=8.5, melody=True), 32, "slow", CC_NC,
          variant_of="musicgen-melody-large", format_="stereo"),
    entry("micro-musicgen-jungle", "musicgen",
          ["pharoAIsanders420/micro-musicgen-jungle"],
          "Micro MusicGen Jungle",
          "Tiny community model for weird fast jungle textures — seconds per clip.",
          musicgen_caps(est=0.8, continuation=True), 4, "fast", MIT,
          notes="Community model by Aaron Abebe; niche by design."),
    # ---- Stable Audio -----------------------------------------------------
    entry("stableaudio-open-10", "stableaudio",
          ["stabilityai/stable-audio-open-1.0"],
          "Stable Audio Open 1.0",
          "Longer stereo loops and textures than Small — up to 47 s. Gated repo.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              # sample_size 2097152 @ 44.1 kHz in the checkpoint's
              # model_config.json is 47.55 s, and the adapter renders that
              # fixed size and trims — so 47.5 is the real ceiling, not a
              # rounded-down 47. Asking for more returns the same audio.
              "duration": {"min_s": 1, "max_s": 47.5, "default_s": 20},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 2.0,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps", "default": 100,
                   "nullable": False, "min": 20, "max": 250},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 7.0, "nullable": False, "min": 0.5, "max": 15.0,
                   "step": 0.5},
                  # Worth having on this entry in particular: it is the one
                  # Stable Audio that defaults to a guidance scale above 1, so
                  # the negative branch is actually running here. On Open Small
                  # (cfg 1.0) the DiT skips it entirely.
                  {"key": "negative_prompt", "type": "string",
                   "label": "Negative prompt", "default": None,
                   "nullable": True, "placeholder": "low quality, distorted"},
                  # Null keeps the tool's default (v-DDIM here — acceptable
                  # per the 2026-09 audit); the choices are the v-objective
                  # samplers the pinned tool implements.
                  {"key": "sampler_type", "type": "enum", "label": "Sampler",
                   "default": None, "nullable": True,
                   "choices": [
                       {"value": "dpmpp-3m-sde", "label": "DPM++ 3M SDE"},
                       {"value": "dpmpp-2m-sde", "label": "DPM++ 2M SDE"},
                       {"value": "v-ddim", "label": "DDIM"},
                       {"value": "k-heun", "label": "Heun"},
                       {"value": "k-lms", "label": "LMS"}],
                   "help": "Which numerical sampler draws the audio — leave "
                           "unset for the tool's default"},
                  seed_param(),
                  *init_audio_params(),
              ],
          },
          16, "medium", STABILITY, gated=True,
          # The adapter's own fallback for a caller that omits `cfg_scale`.
          # Without it that caller got 1.0 — where this DiT skips guidance
          # entirely, taking the negative prompt with it — while the entry
          # above advertises 7.0.
          settings={"cfg_scale_default": 7.0},
          notes="Accept the license on huggingface.co and add your token in Settings."),
    # ---- Stable Audio 3 ---------------------------------------------------
    # Decision recorded 2026-09-03 (audit §7): the fifth sibling checkpoint,
    # `stabilityai/stable-audio-3-optimized`, stays out of the catalog. It is
    # not a new model — it is the same four DiTs re-exported for other runtimes
    # (MLX f16 .npz, CPU-AMX .so, ONNX/TFLite), and the pinned stable-audio-3
    # library has no loader for any of them (zero .npz/mlx references in the
    # installed package). Adding it means writing a second inference path, not
    # a catalog entry, and its pitch is speed on hardware we already serve.
    # Worth revisiting only as a deliberate MLX port of the SA3 DiT — track it
    # there, not here.
    entry("stableaudio3-small-music", "stableaudio3",
          ["stabilityai/stable-audio-3-small-music"],
          "Stable Audio 3 Small (Music)",
          "Up to 120 s of stereo music on the CPU in seconds — and the only "
          "local model that can CONTINUE a song past its end. Also restyles "
          "(audio-to-audio) and repaints regions. Gated repo.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 1, "max_s": 120, "default_s": 30},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 0.15,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps", "default": 8,
                   "nullable": False, "min": 1, "max": 50},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 1.0, "nullable": False, "min": 0.5, "max": 15.0,
                   "step": 0.5},
                  {"key": "negative_prompt", "type": "string",
                   "label": "Negative prompt", "default": None, "nullable": True,
                   "placeholder": "low quality"},
                  seed_param(),
                  *init_audio_params(),
                  {"key": "extend_audio", "type": "audio",
                   "label": "Continue source",
                   "default": None, "nullable": True,
                   "help": "Song to continue — the output starts with it and "
                           "keeps going (120 s total cap)"},
                  {"key": "inpaint_audio", "type": "audio",
                   "label": "Repaint source", "default": None, "nullable": True,
                   "help": "Audio to partially regenerate (with the region "
                           "below); output keeps its length"},
                  {"key": "inpaint_start_s", "type": "float",
                   "label": "Repaint from (s)", "default": None,
                   "nullable": True, "min": 0.0, "max": 120.0, "step": 0.5},
                  {"key": "inpaint_end_s", "type": "float",
                   "label": "Repaint to (s)", "default": None, "nullable": True,
                   "min": 0.0, "max": 120.0, "step": 0.5},
              ],
          },
          8, "fast",
          {"name": "Stability AI Community License (+ Gemma terms for the "
                   "text encoder)", "commercial_use": True,
           "requires_hf_token": True,
           "url": "https://stability.ai/community-license-agreement"},
          gated=True,
          notes="Accept the Stable Audio 3 license on huggingface.co and add "
                "your token in Settings. One audio input per job: repaint > "
                "continue > reimagine."),
    entry("stableaudio3-medium", "stableaudio3",
          ["stabilityai/stable-audio-3-medium"],
          "Stable Audio 3 Medium",
          "The 2B Stable Audio 3 — up to 6:20 of stereo music, seconds per "
          "clip on Apple Silicon. Continues, restyles and repaints like the "
          "Small model, with the quality of the bigger DiT. Trained on "
          "licensed major-label data. Gated repo.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 1, "max_s": 380, "default_s": 30},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 0.8,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps", "default": 8,
                   "nullable": False, "min": 1, "max": 50},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 1.0, "nullable": False, "min": 0.5, "max": 15.0,
                   "step": 0.5},
                  {"key": "negative_prompt", "type": "string",
                   "label": "Negative prompt", "default": None, "nullable": True,
                   "placeholder": "low quality"},
                  seed_param(),
                  *init_audio_params(),
                  {"key": "extend_audio", "type": "audio",
                   "label": "Continue source",
                   "default": None, "nullable": True,
                   "help": "Song to continue — the output starts with it and "
                           "keeps going (6:20 total cap)"},
                  {"key": "inpaint_audio", "type": "audio",
                   "label": "Repaint source", "default": None, "nullable": True,
                   "help": "Audio to partially regenerate (with the region "
                           "below); output keeps its length"},
                  {"key": "inpaint_start_s", "type": "float",
                   "label": "Repaint from (s)", "default": None,
                   "nullable": True, "min": 0.0, "max": 380.0, "step": 0.5},
                  {"key": "inpaint_end_s", "type": "float",
                   "label": "Repaint to (s)", "default": None, "nullable": True,
                   "min": 0.0, "max": 380.0, "step": 0.5},
              ],
          },
          24, "fast",
          {"name": "Stability AI Community License (+ Gemma terms for the "
                   "text encoder)", "commercial_use": True,
           "requires_hf_token": True,
           "url": "https://stability.ai/community-license-agreement"},
          gated=True,
          # device: the Small entry stays on CPU (its design point); Medium
          # was measured at 7.9 s for 10 s of audio on MPS fp32 and is too
          # slow to enjoy on CPU. max_duration_s lifts the adapter's 120 s cap.
          settings={"device": "mps", "max_duration_s": 380.0},
          notes="Accept the Stable Audio 3 license on huggingface.co and add "
                "your token in Settings. One audio input per job: repaint > "
                "continue > reimagine. Runs on the GPU (MPS); ~19 GB peak "
                "memory while rendering."),
    entry("stableaudio3-medium-base", "stableaudio3",
          ["stabilityai/stable-audio-3-medium-base"],
          "Stable Audio 3 Medium Base",
          "The non-distilled Medium: the same 2B DiT before its few-step "
          "distillation — more sampling steps, often finer texture, and "
          "(unusually) an UNGATED repo: no license click, no token.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 1, "max_s": 380, "default_s": 30},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 2.5,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 50, "nullable": False, "min": 8, "max": 150},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 7.0, "nullable": False, "min": 0.5, "max": 15.0,
                   "step": 0.5},
                  {"key": "negative_prompt", "type": "string",
                   "label": "Negative prompt", "default": None, "nullable": True,
                   "placeholder": "low quality"},
                  seed_param(),
                  *init_audio_params(),
                  {"key": "extend_audio", "type": "audio",
                   "label": "Continue source",
                   "default": None, "nullable": True,
                   "help": "Song to continue — the output starts with it and "
                           "keeps going (6:20 total cap)"},
                  {"key": "inpaint_audio", "type": "audio",
                   "label": "Repaint source", "default": None, "nullable": True,
                   "help": "Audio to partially regenerate (with the region "
                           "below); output keeps its length"},
                  {"key": "inpaint_start_s", "type": "float",
                   "label": "Repaint from (s)", "default": None,
                   "nullable": True, "min": 0.0, "max": 380.0, "step": 0.5},
                  {"key": "inpaint_end_s", "type": "float",
                   "label": "Repaint to (s)", "default": None, "nullable": True,
                   "min": 0.0, "max": 380.0, "step": 0.5},
              ],
          },
          24, "medium",
          {"name": "Stability AI Community License (+ Gemma terms for the "
                   "text encoder)", "commercial_use": True,
           "requires_hf_token": False,
           "url": "https://stability.ai/community-license-agreement"},
          variant_of="stableaudio3-medium", format_="base · 50 steps",
          settings={"device": "mps", "max_duration_s": 380.0},
          notes="Speed on this hardware is unmeasured — the est scales the "
                "distilled Medium's by the step count. Same one-audio-input "
                "rule: repaint > continue > reimagine."),
    entry("stableaudio3-small-sfx", "stableaudio3",
          ["stabilityai/stable-audio-3-small-sfx"],
          "Stable Audio 3 Small SFX",
          "The small Stable Audio 3 tuned for sound effects and design "
          "material — hits, risers, textures, foley — rather than songs. "
          "The natural engine for the sound-design cards.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              # Same sample_size as small-music (5292032 @ 44.1 kHz = 120 s)
              # in the checkpoint's model_config.json — the sfx and music
              # Smalls are the same size of model. This entry read 47 for
              # no reason the weights give.
              "duration": {"min_s": 1, "max_s": 120, "default_s": 6},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 0.6,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 8, "nullable": False, "min": 1, "max": 50},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 1.0, "nullable": False, "min": 0.5, "max": 15.0,
                   "step": 0.5},
                  {"key": "negative_prompt", "type": "string",
                   "label": "Negative prompt", "default": None, "nullable": True,
                   "placeholder": "low quality"},
                  seed_param(),
                  *init_audio_params(),
                  # The adapter serves extend/inpaint for every SA3 entry;
                  # omitting them here made both unreachable on sfx only —
                  # the engine drops undeclared params (audit §2).
                  {"key": "extend_audio", "type": "audio",
                   "label": "Continue source",
                   "default": None, "nullable": True,
                   "help": "Audio to continue — the output starts with it "
                           "and keeps going (120 s total cap)"},
                  {"key": "inpaint_audio", "type": "audio",
                   "label": "Repaint source", "default": None, "nullable": True,
                   "help": "Audio to partially regenerate (with the region "
                           "below); output keeps its length"},
                  {"key": "inpaint_start_s", "type": "float",
                   "label": "Repaint from (s)", "default": None,
                   "nullable": True, "min": 0.0, "max": 120.0, "step": 0.5},
                  {"key": "inpaint_end_s", "type": "float",
                   "label": "Repaint to (s)", "default": None, "nullable": True,
                   "min": 0.0, "max": 120.0, "step": 0.5},
              ],
          },
          12, "fast",
          {"name": "Stability AI Community License (+ Gemma terms for the "
                   "text encoder)", "commercial_use": True,
           "requires_hf_token": True,
           "url": "https://stability.ai/community-license-agreement"},
          gated=True,
          variant_of="stableaudio3-medium", format_="small · sfx",
          settings={"device": "mps"},
          notes="Untested on this hardware — est is a guess from the small "
                "architecture. Gated repo (auto-approval): accept the "
                "license on huggingface.co and add your token in Settings."),
    # ---- ACE-Step DiT variants -------------------------------------------
    ace_variant("acestep-15-dit-base", "ACE-Step/acestep-v15-base",
                "acestep-v15-base", "ACE-Step 1.5 Base", "base · 50 steps",
                50, 1.0, 2.5, 16, "medium",
                "Non-distilled DiT: slower, often richer detail than Turbo."),
    ace_variant("acestep-15-dit-sft", "ACE-Step/acestep-v15-sft",
                "acestep-v15-sft", "ACE-Step 1.5 SFT", "sft · 50 steps",
                50, 1.0, 2.5, 16, "medium",
                "Supervised-finetuned DiT: different flavour than Base."),
    ace_variant("acestep-15-dit-xl-turbo", "ACE-Step/acestep-v15-xl-turbo",
                "acestep-v15-xl-turbo", "ACE-Step 1.5 XL Turbo", "XL turbo",
                8, 3.0, 2.0, 48, "slow",
                "The big DiT, distilled for 8-step sampling. Needs 48 GB+."),
    ace_variant("acestep-15-dit-xl-sft", "ACE-Step/acestep-v15-xl-sft",
                "acestep-v15-xl-sft", "ACE-Step 1.5 XL SFT", "XL sft",
                50, 1.0, 6.0, 48, "slow",
                "The big DiT at full step count — highest quality tier. Needs 48 GB+."),
    ace_variant("acestep-15-dit-xl-base", "ACE-Step/acestep-v15-xl-base",
                "acestep-v15-xl-base", "ACE-Step 1.5 XL Base", "XL base",
                50, 1.0, 6.0, 48, "slow",
                "Big non-distilled DiT. Needs 48 GB+."),
    # ---- ACE-Step 1.5 XL LoRA pack (DiffSynth runtime) --------------------
    #
    # A separate family from `acestep`: these LoRAs were built against
    # DiffSynth-Studio's own AceStep implementation, which drives the XL SFT
    # DiT directly (no LM half). The base weights are the same HF repos the
    # acestep entries use (shared-repo refcounting applies); the LoRAs were
    # ModelScope-exclusive and are now mirrored (unmodified, Apache-2.0) on
    # the user-owned HF account — see rtikw/acestep15xlsft-* and
    # ~/build/local-music/models-uploaded-to-my-HF.md.
    entry("acestep-xl-vocals2music", "diffsynthace",
          [{"repo_id": ACE_CORE, "gated": False,
            "allow_patterns": ["Qwen3-Embedding-0.6B/*", "vae/*"]},
           "ACE-Step/acestep-v15-xl-sft",
           # The template ControlNet (model.py + weights; the demo wavs in
           # assets/ are deliberately excluded) and the music LoRA it rides
           # with — unmodified mirrors on the user-owned account.
           {"repo_id": "rtikw/acestep15xlsft-vocals2music", "gated": False,
            "allow_patterns": ["model.safetensors", "model.py",
                               "configuration.json"]},
           {"repo_id": "rtikw/acestep15xlsft-lora-music", "gated": False,
            "allow_patterns": ["model.safetensors"]}],
          "Vocals → band (ACE-Step XL)",
          "Sing a cappella, get a band: conditions ACE-Step 1.5 XL on your "
          "vocal recording and generates the full arrangement around it — "
          "the voice is kept, the music is written to fit. 30 s of "
          "accompaniment in about 30 s on Apple Silicon.",
          {
              "supports_lyrics": True, "instrumental_only": False,
              # Same unclamped DiffSynth path as the LoRA entries below, so
              # the same 600 s ceiling. In practice this one rarely reaches it:
              # the adapter locks the render to the vocal recording's own
              # length, so max_s is the ceiling and the singer is the bound.
              "duration": {"min_s": 5, "max_s": 600, "default_s": 60,
                           "unlocked_max_s": ACESTEP_UNLOCKED_MAX_S},
              "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 1.0,
              "lyrics_hint": ("Paste the words you sang — they help the "
                              "model follow the vocal. Structure tags like "
                              "[Verse 1] are understood."),
              "params": [
                  {"key": "accompany_audio", "type": "audio",
                   "label": "Your vocal", "default": None, "nullable": False},
                  {"key": "template_scale", "type": "float",
                   "label": "Vocal conditioning", "default": 1.0,
                   "nullable": False, "min": 0.2, "max": 1.5, "step": 0.05,
                   "help": "How strongly the ControlNet holds the band to "
                           "the vocal — 1.0 follows it closely; lower "
                           "loosens the arrangement around it"},
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 12, "nullable": False, "min": 4, "max": 50,
                   "help": "Diffusion passes. 12 is already musical; more "
                           "adds detail and time"},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 1.0, "nullable": False, "min": 0.5, "max": 10.0,
                   "step": 0.5},
                  seed_param(),
                  {"key": "bpm", "type": "int", "label": "Tempo (BPM)",
                   "default": None, "nullable": True, "min": 40, "max": 220},
                  {"key": "keyscale", "type": "string", "label": "Key",
                   "default": None, "nullable": True,
                   "placeholder": "B minor"},
                  {"key": "timesignature", "type": "string",
                   "label": "Time signature", "default": None,
                   "nullable": True, "placeholder": "4"},
                  {"key": "vocal_language", "type": "enum",
                   "label": "Vocal language", "default": "en",
                   "nullable": False,
                   "choices": [{"value": "en", "label": "English"},
                               {"value": "de", "label": "German"},
                               {"value": "es", "label": "Spanish"},
                               {"value": "fr", "label": "French"},
                               {"value": "ja", "label": "Japanese"},
                               {"value": "ko", "label": "Korean"},
                               {"value": "zh", "label": "Chinese"}]},
              ],
          },
          48, "medium", APACHE,
          notes="Works best on steady-tempo vocals (upstream's own caveat). "
                "The render is capped at the vocal's length. ~21 GB peak "
                "memory while rendering. LoRA weights are unmodified "
                "mirrors of DiffSynth-Studio's ModelScope originals "
                "(Apache-2.0).",
          settings={"template_repo": "rtikw/acestep15xlsft-vocals2music",
                    "lora_repo": "rtikw/acestep15xlsft-lora-music",
                    "shift": 6.0}),
] + [
    entry(f"acestep-xl-{lora}", "diffsynthace",
          [{"repo_id": ACE_CORE, "gated": False,
            "allow_patterns": ["Qwen3-Embedding-0.6B/*", "vae/*"]},
           "ACE-Step/acestep-v15-xl-sft",
           {"repo_id": f"rtikw/acestep15xlsft-{lora}", "gated": False,
            "allow_patterns": ["model.safetensors"]}],
          name,
          desc,
          {
              "supports_lyrics": False, "instrumental_only": True,
              # This path does NOT go through the pipeline whose docstring
              # documents 10~600 — DiffSynth drives the DiT directly, no LM
              # half — so the ceiling is its own: `max_latent_length =
              # round(duration * 48000 / 1920)` (25 latent frames/s) with no
              # clamp anywhere in pipelines/ace_step.py, and the silence
              # latent it slices from TILES rather than running out. The wall
              # is the DiT's RoPE at max_position_embeddings=32768, which 600 s
              # (15k frames, fewer after patchify) sits under half of. 600 is
              # kept because it is where both reference ACE-Step runtimes stop;
              # past it is untrained extrapolation nobody upstream sanctions.
              "duration": {"min_s": 5, "max_s": 600, "default_s": 30,
                           "unlocked_max_s": ACESTEP_UNLOCKED_MAX_S},
              "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 1.3,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 12, "nullable": False, "min": 4, "max": 50,
                   "help": "Diffusion passes. 12 is already musical; more "
                           "adds detail and time"},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 1.0, "nullable": False, "min": 0.5, "max": 10.0,
                   "step": 0.5},
                  seed_param(),
                  {"key": "bpm", "type": "int", "label": "Tempo (BPM)",
                   "default": None, "nullable": True, "min": 40, "max": 220},
                  {"key": "keyscale", "type": "string", "label": "Key",
                   "default": None, "nullable": True,
                   "placeholder": "B minor"},
                  {"key": "timesignature", "type": "string",
                   "label": "Time signature", "default": None,
                   "nullable": True, "placeholder": "4"},
              # DiffSynth's AceStepPipeline takes the same task vocabulary as
              # upstream ACE-Step (minus FlowEdit, which it does not
              # implement), so the LoRA pack serves the Cover and Repaint
              # style-transfer cards with the shared param set.
              ] + [p for p in ace_task_params(False)
                   if not p["key"].startswith("flow_edit")] + [
                  # DiffSynth's own strengths, read by the adapter since the
                  # pack landed but undeclared (and therefore dropped by the
                  # engine) until the 2026-09 audit.
                  {"key": "denoising_strength", "type": "float",
                   "label": "Denoise depth", "default": None,
                   "nullable": True, "min": 0.05, "max": 1.0, "step": 0.05,
                   "help": "How much of the diffusion schedule runs — "
                           "below 1.0 keeps more of the source's fabric "
                           "(mainly useful with Cover)"},
                  {"key": "repainting_strength", "type": "float",
                   "label": "Repaint strength", "default": None,
                   "nullable": True, "min": 0.05, "max": 1.0, "step": 0.05,
                   "help": "How completely the repainted span is "
                           "re-imagined — 1.0 rewrites it outright"},
                  {"key": "audio_codes", "type": "string",
                   "label": "Captured plan", "default": None,
                   "nullable": True, "internal": True},
              ],
          },
          48, "medium", APACHE,
          variant_of="acestep-xl-vocals2music", format_=fmt,
          notes="~21 GB peak memory while rendering. Supports cover and "
                "repaint over a source file, an optional style reference, "
                "and re-rendering a captured ACE-Step plan (same token "
                "vocabulary). LoRA weights are an unmodified mirror of "
                "DiffSynth-Studio's ModelScope original (Apache-2.0).",
          settings={"lora_repo": f"rtikw/acestep15xlsft-{lora}",
                    "shift": 6.0})
    for lora, fmt, name, desc in [
        ("lora-music", "LoRA · music",
         "ACE-Step XL (music LoRA)",
         "The general-music finetune of the XL SFT DiT on the DiffSynth "
         "runtime — instrumental text-to-music with the LoRA pack's "
         "cleaner sound."),
        ("lora-piano", "LoRA · piano",
         "ACE-Step XL (piano LoRA)",
         "Solo piano specialist: the XL DiT finetuned toward piano "
         "performance. Describe the piece; it plays it."),
        ("lora-drums", "LoRA · drums",
         "ACE-Step XL (drums LoRA)",
         "Drum-kit specialist — grooves and fills without the rest of the "
         "band. A loop machine for rhythm sections."),
        ("lora-guitar", "LoRA · guitar",
         "ACE-Step XL (guitar LoRA)",
         "Guitar specialist — acoustic and electric parts on their own, "
         "from fingerpicked folk to riffs."),
    ]
] + [
    # ---- Magenta RealTime 2 (MLX) ----------------------------------------
    entry("magenta-rt2-small", "magentart", [],
          "Magenta RealTime 2",
          "Google's streaming music engine, running natively on MLX — "
          "audio decodes faster than it plays (4 s of music in under 2 s "
          "once loaded, in 1.7 GB of memory). Prompt with words or with a "
          "reference clip whose vibe it should hold.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 2, "max_s": 300, "default_s": 12,
                           "unlocked_max_s": UNLOCKED_MAX_S},
              "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 0.5,
              "params": [
                  {"key": "style_audio", "type": "audio",
                   "label": "Style reference", "default": None,
                   "nullable": True,
                   "help": "Audio whose character the stream holds — used "
                           "instead of the text prompt when set (MusicCoCa "
                           "embeds either)"},
                  {"key": "style_audio_b", "type": "audio",
                   "label": "Morph target (audio)", "default": None,
                   "nullable": True,
                   "help": "Set a second style and the stream MORPHS: it "
                           "starts as the first style and arrives at this "
                           "one, interpolated chunk by chunk"},
                  {"key": "prompt_b", "type": "string",
                   "label": "Morph target (words)", "default": None,
                   "nullable": True,
                   "placeholder": "e.g. ambient choral drone",
                   "help": "Morph target described in words instead of "
                           "audio — ignored when a morph-target file is "
                           "set"},
                  {"key": "temperature", "type": "float",
                   "label": "Temperature", "default": 1.3, "nullable": False,
                   "min": 0.5, "max": 2.0, "step": 0.05},
                  {"key": "top_k", "type": "int", "label": "Top-K",
                   "default": 40, "nullable": False, "min": 10, "max": 400},
                  {"key": "guidance_scale", "type": "float",
                   "label": "Style strength", "default": 3.0,
                   "nullable": False, "min": 0.5, "max": 10.0, "step": 0.5,
                   "help": "How hard the stream is held to the style "
                           "embedding. Higher sticks to the prompt's "
                           "character; lower drifts more freely"},
                  # The exported graph takes three conditioning channels and
                  # only the style one was ever driven. These are the other
                  # two — and the reason this model pairs with the MIDI half
                  # of the app: hand it a part and it plays that part.
                  {"key": "melody_midi", "type": "midi",
                   "label": "Notes to play", "default": None,
                   "nullable": True,
                   "help": "A MIDI part the model should actually play. It "
                           "follows the pitches and where they start; the "
                           "style prompt still decides what it sounds like. "
                           "Percussion tracks drive the drum switch below "
                           "rather than the pitches."},
                  {"key": "notes_guidance", "type": "float",
                   "label": "Note strength", "default": 3.0,
                   "nullable": False, "min": -1.0, "max": 7.0, "step": 0.5,
                   "help": "How closely the notes are followed. High plays "
                           "them almost literally; low treats them as a "
                           "suggestion and keeps more of the style's own "
                           "phrasing. Does nothing without a MIDI part."},
                  {"key": "drums", "type": "enum", "label": "Drums",
                   "default": "auto", "nullable": False,
                   "choices": [
                       {"value": "auto", "label": "Model decides"},
                       {"value": "play", "label": "Keep drums playing"},
                       {"value": "silent", "label": "No drums"}],
                   "help": "A switch the model was trained with: whether "
                           "percussion is playing at all. Left on automatic "
                           "it follows the MIDI's own drum track if there is "
                           "one, and is otherwise the model's choice."},
                  {"key": "drums_guidance", "type": "float",
                   "label": "Drum strength", "default": 3.0,
                   "nullable": False, "min": -1.0, "max": 7.0, "step": 0.5,
                   "help": "How firmly the drum switch is enforced. Does "
                           "nothing while Drums is on automatic with no MIDI "
                           "drum track."},
                  seed_param(),
              ],
          },
          8, "fast",
          {"name": "Apache-2.0 (code) / CC BY 4.0 (weights)",
           "commercial_use": True, "requires_hf_token": False,
           "url": "https://github.com/magenta/magenta-realtime"},
          notes="Weights (~1.75 GB: MusicCoCa + SpectroStream resources and "
                "the exported MLX model) fetch from Google's own hosting on "
                "first run. A streaming design (~200 ms control latency) — "
                "the natural engine for a live-jam surface later. Python "
                "3.12 runtime; mlx pinned below 0.32 (the exported model "
                "fails to deserialise there).",
          settings={"size": "mrt2_small"},
          # Route-B weights (Google's own CLI fetches them), so HF cannot
          # size this entry — preset what the CLI downloads.
          size_hint_bytes=1_750_000_000),
    entry("magenta-rt2-base", "magentart", [],
          "Magenta RealTime 2 (base)",
          "The larger Magenta RT 2 model: the same streaming engine with "
          "more capacity — richer texture at a slower (unmeasured on this "
          "hardware) decode. The small model is the proven fast one; try "
          "this when its sound feels thin.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 2, "max_s": 300, "default_s": 12,
                           "unlocked_max_s": UNLOCKED_MAX_S},
              "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 1.5,
              "params": [
                  {"key": "style_audio", "type": "audio",
                   "label": "Style reference", "default": None,
                   "nullable": True,
                   "help": "Audio whose character the stream holds — used "
                           "instead of the text prompt when set (MusicCoCa "
                           "embeds either)"},
                  {"key": "style_audio_b", "type": "audio",
                   "label": "Morph target (audio)", "default": None,
                   "nullable": True,
                   "help": "Set a second style and the stream MORPHS: it "
                           "starts as the first style and arrives at this "
                           "one, interpolated chunk by chunk"},
                  {"key": "prompt_b", "type": "string",
                   "label": "Morph target (words)", "default": None,
                   "nullable": True,
                   "placeholder": "e.g. ambient choral drone",
                   "help": "Morph target described in words instead of "
                           "audio — ignored when a morph-target file is "
                           "set"},
                  {"key": "temperature", "type": "float",
                   "label": "Temperature", "default": 1.3, "nullable": False,
                   "min": 0.5, "max": 2.0, "step": 0.05},
                  {"key": "top_k", "type": "int", "label": "Top-K",
                   "default": 40, "nullable": False, "min": 10, "max": 400},
                  {"key": "guidance_scale", "type": "float",
                   "label": "Style strength", "default": 3.0,
                   "nullable": False, "min": 0.5, "max": 10.0, "step": 0.5,
                   "help": "How hard the stream is held to the style "
                           "embedding. Higher sticks to the prompt's "
                           "character; lower drifts more freely"},
                  # The exported graph takes three conditioning channels and
                  # only the style one was ever driven. These are the other
                  # two — and the reason this model pairs with the MIDI half
                  # of the app: hand it a part and it plays that part.
                  {"key": "melody_midi", "type": "midi",
                   "label": "Notes to play", "default": None,
                   "nullable": True,
                   "help": "A MIDI part the model should actually play. It "
                           "follows the pitches and where they start; the "
                           "style prompt still decides what it sounds like. "
                           "Percussion tracks drive the drum switch below "
                           "rather than the pitches."},
                  {"key": "notes_guidance", "type": "float",
                   "label": "Note strength", "default": 3.0,
                   "nullable": False, "min": -1.0, "max": 7.0, "step": 0.5,
                   "help": "How closely the notes are followed. High plays "
                           "them almost literally; low treats them as a "
                           "suggestion and keeps more of the style's own "
                           "phrasing. Does nothing without a MIDI part."},
                  {"key": "drums", "type": "enum", "label": "Drums",
                   "default": "auto", "nullable": False,
                   "choices": [
                       {"value": "auto", "label": "Model decides"},
                       {"value": "play", "label": "Keep drums playing"},
                       {"value": "silent", "label": "No drums"}],
                   "help": "A switch the model was trained with: whether "
                           "percussion is playing at all. Left on automatic "
                           "it follows the MIDI's own drum track if there is "
                           "one, and is otherwise the model's choice."},
                  {"key": "drums_guidance", "type": "float",
                   "label": "Drum strength", "default": 3.0,
                   "nullable": False, "min": -1.0, "max": 7.0, "step": 0.5,
                   "help": "How firmly the drum switch is enforced. Does "
                           "nothing while Drums is on automatic with no MIDI "
                           "drum track."},
                  seed_param(),
              ],
          },
          12, "medium",
          {"name": "Apache-2.0 (code) / CC BY 4.0 (weights)",
           "commercial_use": True, "requires_hf_token": False,
           "url": "https://github.com/magenta/magenta-realtime"},
          variant_of="magenta-rt2-small", format_="base",
          notes="Speed on Apple Silicon is unmeasured — the est is a "
                "conservative guess, the small model the safe default. "
                "Weights fetch from Google's hosting on first run "
                "(mrt models download mrt2_base).",
          settings={"size": "mrt2_base"},
          size_hint_bytes=3_700_000_000),
    # ---- The song-generation spikes (CPU-honest estimates) ---------------
    #
    # Decision recorded 2026-09-03 (audit §7): SongGen's reference-CODE
    # conditioning (melody / drum / vocal / acc token prompts) stays out, and
    # not as a preference — it does not exist at inference at this pin. The
    # processor really does build it: `processing_songgen.py` takes
    # `refaudio_path` + `refaudio_type`, encodes the clip, applies the
    # codebook delay and returns `model_inputs['ref_audio_ids']`. Nothing then
    # reads it. Grepping the whole package, `ref_audio_ids` appears in exactly
    # one file — the processor — and in `training/`; neither
    # `modeling_songgen_mixed.py` nor `modeling_songgen_dual_track.py`
    # mentions it, so the tensor would be built at real cost and dropped on
    # the floor of `generate(**kwargs)`. It is a training-time label, exposed
    # by a processor shared with the trainer. Revisit only if upstream wires
    # it into the model's forward pass.
    entry("songgen-mixed-pro", "songgen",
          ["LiuZH-19/SongGen_mixed_pro",
           {"repo_id": "ZhenYe234/xcodec", "gated": False,
            "allow_patterns": ["xcodec_hubert_general_audio_v2.pth",
                               "config_hubert_general.yaml"]}],
          "SongGen (text + lyrics → song)",
          "Single-stage autoregressive song generation (ICML 2025): text "
          "and lyrics in, a sung mixed track out — with optional "
          "three-second reference-voice conditioning from a recording you "
          "supply. English-centric; runs on the CPU at roughly realtime "
          "token rate.",
          {
              "supports_lyrics": True, "instrumental_only": False,
              "duration": {"min_s": 5, "max_s": 120, "default_s": 20},
              "sample_rate": 16000, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 5.0,
              "lyrics_hint": ("Plain lyric lines; keep them short and "
                              "singable. English works best."),
              "params": [
                  {"key": "ref_voice", "type": "audio",
                   "label": "Reference voice", "default": None,
                   "nullable": True},
                  {"key": "temperature", "type": "float",
                   "label": "Temperature", "default": 1.0, "nullable": False,
                   "min": 0.3, "max": 1.5, "step": 0.05},
                  {"key": "top_k", "type": "int", "label": "Top-K",
                   "default": 250, "nullable": False, "min": 10, "max": 500},
                  {"key": "top_p", "type": "float", "label": "Top-P",
                   "default": 1.0, "nullable": False, "min": 0.1, "max": 1.0,
                   "step": 0.05},
                  seed_param(),
              ],
          },
          16, "slow",
          {"name": "Apache-2.0 (code); research checkpoint",
           "commercial_use": False, "requires_hf_token": False,
           "url": "https://github.com/LiuZH-19/SongGen"},
          settings={"device": "mps"},
          notes="The mixed-mode checkpoint (one combined track). A "
                "dual-track variant (separate vocal + accompaniment) exists "
                "upstream and is a natural follow-up. The 2026-08-26 MPS "
                "port is unmeasured — the est still carries the CPU "
                "baseline, so the estimate is worst-case until a render "
                "lands."),
    entry("diffrhythm2", "diffrhythm2",
          ["ASLP-lab/DiffRhythm2"],
          "DiffRhythm2 (full songs)",
          "Full-song lyrics-to-song via block-cache flow matching — "
          "structured songs up to 3½ minutes, style set by a text prompt "
          "or a reference clip, lyrics shaped by structure tags. Runs on "
          "the GPU (MPS) as of 2026-08-26; the estimate still shows the "
          "measured CPU worst case.",
          {
              "supports_lyrics": True, "instrumental_only": False,
              "duration": {"min_s": 10, "max_s": 210, "default_s": 60},
              # 48 kHz is what the pinned inference actually writes — caught
              # by the 2026-09 revalidation's file-vs-catalog assert.
              "sample_rate": 48000, "outputs_per_job_max": 1,
              "est_seconds_per_audio_second": 11.0,
              # No [mm:ss.xx] timestamps: the model never parses them —
              # timestamped lines go through the phonemizer verbatim and
              # the junk gets sung (audit §3). Structure tags are the real
              # control surface.
              "lyrics_tags": ["[verse]", "[chorus]", "[bridge]", "[inst]",
                              "[intro]", "[outro]"],
              "lyrics_hint": ("Plain lyric lines, with structure tags like "
                              "[verse], [chorus] or [inst] on their own "
                              "lines to shape the song. No timestamps — "
                              "they would be sung as words."),
              "params": [
                  {"key": "style_audio", "type": "audio",
                   "label": "Style reference", "default": None,
                   "nullable": True,
                   "help": "A clip whose sound the song copies — used "
                           "instead of the text prompt when set"},
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 8, "nullable": False, "min": 4, "max": 32,
                   "help": "Flow-matching passes. 8 is the proven fast "
                           "setting; upstream's default is 16"},
                  {"key": "guidance_scale", "type": "float",
                   "label": "Guidance", "default": 2.0, "nullable": False,
                   "min": 1.0, "max": 6.0, "step": 0.5},
                  {"key": "fake_stereo", "type": "bool",
                   "label": "Widen to stereo", "default": True,
                   "nullable": False,
                   "help": "The model renders mono; on, the file is "
                           "widened to a centred stereo pair (upstream's "
                           "default). Off keeps the honest mono at half "
                           "the size"},
                  seed_param(),
              ],
          },
          16, "slow", APACHE,
          settings={"device": "mps"},
          notes="Needs espeak-ng (`brew install espeak-ng`) for the lyrics "
                "front-end — the adapter says so if it is missing. Chinese "
                "and English lyrics are strongest; Japanese supported. The "
                "2026-08-26 MPS port is unmeasured — the est still carries "
                "the CPU baseline (11 s per song-second), so treat the "
                "estimate as worst-case until a render lands."),
    # Decision recorded 2026-09-03 (audit §7): InspireMusic's `instruct` flag
    # stays unexposed permanently. It is a DEAD PARAMETER upstream — accepted
    # by inference() (cli/inference.py:108) and never read anywhere in the
    # pinned tree. There is nothing behind the knob, so this is not a "someday"
    # item; do not re-litigate. (Quality mode / 48 kHz flow-matching remains a
    # separate, still-open hold — that one is real, just unmeasured.)
    entry("inspiremusic-15b-long", "inspiremusic",
          ["rtikw/InspireMusic-1.5B-Long"],
          "InspireMusic 1.5B Long",
          "Alibaba's long-form model: 3+ minutes of coherent instrumental "
          "structure, and true CONTINUATION of existing audio. Runs on "
          "the GPU at about 3.5× the clip length — a coffee, not an "
          "afternoon.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 10, "max_s": 180, "default_s": 30},
              # 24 kHz is what the fast (no-flow) mode actually writes —
              # the 48 kHz upsampler belongs to the skipped quality mode
              # (audit §3).
              "sample_rate": 24000, "outputs_per_job_max": 1,
              "est_seconds_per_audio_second": 3.5,
              "params": [
                  {"key": "extend_audio", "type": "audio",
                   "label": "Continue source", "default": None,
                   "nullable": True,
                   "help": "Audio to continue — the model picks up where "
                           "the clip ends and keeps going"},
                  {"key": "chorus", "type": "enum", "label": "Section",
                   "default": "verse", "nullable": False,
                   "choices": [{"value": "intro", "label": "Intro"},
                               {"value": "verse", "label": "Verse"},
                               {"value": "chorus", "label": "Chorus"},
                               {"value": "outro", "label": "Outro"},
                               {"value": "random", "label": "Model's choice"}],
                   "help": "Which part of a song the model believes it is "
                           "writing — an intro builds, a chorus peaks, an "
                           "outro winds down"},
                  {"key": "time_start", "type": "float",
                   "label": "Timeline start (s)", "default": 0.0,
                   "nullable": False, "min": 0.0, "max": 300.0, "step": 5.0,
                   "help": "Where on the song's imagined timeline this "
                           "piece sits — starting at 60 writes music that "
                           "believes a minute came before it"},
                  {"key": "time_end", "type": "float",
                   "label": "Timeline end (s)", "default": 30.0,
                   "nullable": False, "min": 5.0, "max": 300.0, "step": 5.0,
                   "help": "The imagined end point on that timeline — "
                           "paired with the start, it frames the section's "
                           "place in the song"},
                  seed_param(),
              ],
          },
          16, "medium", APACHE,
          settings={"device": "mps"},
          notes="Fast mode (no flow-matching refinement) — the proven "
                "configuration. Upstream is effectively abandoned; the "
                "code rides a pinned snapshot. Weights are an unmodified "
                "mirror of Alibaba's ModelScope original (Apache-2.0; the "
                "official HF repos were delisted). The device-unification "
                "MPS port landed 2026-08-26: 10 s in 33 s measured (8.6× "
                "the CPU baseline); CPU remains the fallback when MPS is "
                "absent."),
    entry("songbloom-150s-dpo", "songbloom",
          # Patterns keep the sibling non-DPO checkpoint (7.8 GB) out of the
          # download; the yaml resolves the rest of these by name.
          [{"repo_id": "rtikw/SongBloom", "gated": False,
            "allow_patterns": ["songbloom_full_150s_dpo.*",
                               "autoencoder_music_dsp1920.ckpt",
                               "stable_audio_1920_vae.json",
                               "vocab_g2p.yaml",
                               "configuration.json"]}],
          "SongBloom (lyrics + style clip)",
          "A full song from structured lyrics and ten seconds of any "
          "reference audio — coherent vocals and band via interleaved "
          "sketching + diffusion, DPO-tuned checkpoint. Very slow on CPU "
          "(about 22× the song's length); queue it and walk away.",
          {
              "supports_lyrics": True, "instrumental_only": False,
              # Not merely supported: the adapter refuses without them, so
              # the app must gate rather than let the engine load 8 GB and
              # then say no.
              "requires_lyrics": True,
              "duration": {"min_s": 10, "max_s": 150, "default_s": 60},
              "sample_rate": 48000, "outputs_per_job_max": 1,
              "est_seconds_per_audio_second": 22.0,
              "lyrics_hint": ("SongBloom's structure tokens: sections like "
                              "[intro] [verse] [chorus] [inst] [outro], "
                              "lyric lines separated by '.', sections by "
                              "' , '. Repeat a tag to lengthen its "
                              "section."),
              "params": [
                  {"key": "style_audio", "type": "audio",
                   "label": "Style reference (10 s)", "default": None,
                   "nullable": False,
                   "help": "Ten seconds of any audio whose sound the song "
                           "should live in — genre, production, voice "
                           "colour all follow it"},
                  seed_param(),
              ],
          },
          32, "slow", APACHE,
          settings={"device": "mps"},
          notes="Upstream deleted their repos; the code rides a pinned "
                "fork snapshot and the weights are an unmodified mirror "
                "of the last surviving host, ModelScope (Apache-2.0 — as "
                "much archival as practical). ~24 GB peak memory. Listen "
                "against YuE before reaching for it — it earns its place "
                "on style-clip fidelity. The 2026-08-26 MPS port is "
                "unmeasured — the est still carries the CPU baseline "
                "(22 s per song-second), so the estimate is worst-case "
                "until a render lands."),
    entry("songbloom-150s", "songbloom",
          # Same mirror, the pre-DPO checkpoint set instead.
          [{"repo_id": "rtikw/SongBloom", "gated": False,
            "allow_patterns": ["songbloom_full_150s.pt",
                               "songbloom_full_150s.yaml",
                               "autoencoder_music_dsp1920.ckpt",
                               "stable_audio_1920_vae.json",
                               "vocab_g2p.yaml",
                               "configuration.json"]}],
          "SongBloom (pre-DPO)",
          "The same model before its preference tuning: rawer and less "
          "polished than the DPO checkpoint, and occasionally more "
          "varied for exactly that reason. Same inputs, same speed.",
          {
              "supports_lyrics": True, "instrumental_only": False,
              # Not merely supported: the adapter refuses without them, so
              # the app must gate rather than let the engine load 8 GB and
              # then say no.
              "requires_lyrics": True,
              "duration": {"min_s": 10, "max_s": 150, "default_s": 60},
              "sample_rate": 48000, "outputs_per_job_max": 1,
              "est_seconds_per_audio_second": 22.0,
              "lyrics_hint": ("SongBloom's structure tokens: sections like "
                              "[intro] [verse] [chorus] [inst] [outro], "
                              "lyric lines separated by '.', sections by "
                              "' , '. Repeat a tag to lengthen its "
                              "section."),
              "params": [
                  {"key": "style_audio", "type": "audio",
                   "label": "Style reference (10 s)", "default": None,
                   "nullable": False,
                   "help": "Ten seconds of any audio whose sound the song "
                           "should live in — genre, production, voice "
                           "colour all follow it"},
                  seed_param(),
              ],
          },
          32, "slow", APACHE,
          variant_of="songbloom-150s-dpo", format_="pre-DPO",
          notes="The DPO checkpoint is the better default; this one is "
                "for A/B curiosity. Shares the autoencoder files with it, "
                "so installing both costs only the second 7.8 GB .pt.",
          settings={"variant": "songbloom_full_150s", "device": "mps"}),
    # ---- VampNet (masked-token variation) --------------------------------
    entry("vampnet-vamp", "vampnet",
          [{"repo_id": "hugggof/vampnet", "gated": False,
            "allow_patterns": ["coarse.pth", "c2f.pth", "codec.pth",
                               "wavebeat.pth"]}],
          "VampNet (loop variations)",
          "Feed it a loop and it plays the idea back differently — masked "
          "tokens are re-imagined while the rest stays yours. The knobs set "
          "how much survives: from a light shuffle to a re-write that only "
          "keeps the groove. Nothing else here does this.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 2, "max_s": 20, "default_s": 10},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 3.0,
              "params": [
                  {"key": "src_audio", "type": "audio",
                   "label": "Loop to vary", "default": None,
                   "nullable": False,
                   "help": "The material the variations are made of — a "
                           "bar-or-few loop works best"},
                  {"key": "periodic_prompt", "type": "int",
                   "label": "Keep every Nth token", "default": 7,
                   "nullable": False, "min": 1, "max": 30},
                  {"key": "upper_codebook_mask", "type": "int",
                   "label": "Pinned codebooks", "default": 3,
                   "nullable": False, "min": 0, "max": 14},
                  # Was a bool meaning "onsets"; the adapter still accepts
                  # that value, so presets written before the beat tracker
                  # was wired up keep doing what they did.
                  {"key": "beat_mask", "type": "enum",
                   "label": "Keep in time with", "default": "off",
                   "nullable": False,
                   "choices": [
                       {"value": "off", "label": "Nothing — vamp freely"},
                       {"value": "onsets", "label": "Every note attack"},
                       {"value": "beats", "label": "The beat"},
                       {"value": "downbeats", "label": "The downbeat only"}],
                   "help": "Which moments survive the vamp untouched. Note "
                           "attacks keep every transient, which holds the "
                           "rhythm tightly. The beat keeps the pulse and "
                           "re-imagines everything between it — the groove "
                           "stays, the playing changes. Downbeats keep only "
                           "the top of each bar, which is the loosest of the "
                           "three."},
                  {"key": "time_stretch", "type": "int",
                   "label": "Stretch", "default": 1, "nullable": False,
                   "min": 1, "max": 4,
                   "help": "Make the result this many times longer than the "
                           "loop, by writing new material into the gaps "
                           "rather than by slowing anything down. Pitch and "
                           "timbre are untouched; the playing is invented. "
                           "2 turns a bar into two bars of the same idea."},
                  {"key": "prefix_s", "type": "float",
                   "label": "Keep the start (s)", "default": 0.0,
                   "nullable": False, "min": 0.0, "max": 10.0, "step": 0.5,
                   "help": "Leave this many opening seconds untouched and "
                           "vamp only what follows — set both ends to "
                           "in-fill the middle"},
                  {"key": "suffix_s", "type": "float",
                   "label": "Keep the end (s)", "default": 0.0,
                   "nullable": False, "min": 0.0, "max": 10.0, "step": 0.5,
                   "help": "Leave this many closing seconds untouched — "
                           "with a kept start too, the model writes only "
                           "the gap between them"},
                  {"key": "temperature", "type": "float",
                   "label": "Temperature", "default": 1.0, "nullable": False,
                   "min": 0.5, "max": 2.0, "step": 0.05},
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 8, "nullable": False, "min": 2, "max": 36,
                   "help": "Sampling passes per stage. 8 coarse (and half "
                           "that to refine) is the proven fast setting"},
                  seed_param(),
              ],
          },
          8, "medium", CC_NC_SA,
          notes="CC BY-NC-SA weights (Hugo Flores García / Descript). The "
                "prompt box is unused: the audio is the prompt. Runs on CPU: "
                "the PyTorch MPS codec path is unstable. A 6 s vamp took "
                "about 18 s there.",
          settings={"device": "cpu"}),
] + [
    # VampNet finetunes: full coarse/c2f checkpoint pairs under loras/ in
    # the same repo, swapped in whole (they are not adapter deltas). The
    # codec and beat tracker are shared with the base entry, so installing
    # a second voice costs only the pair (~1.4 GB).
    entry(f"vampnet-{name}", "vampnet",
          [{"repo_id": "hugggof/vampnet", "gated": False,
            "allow_patterns": [f"loras/{name}/coarse.pth",
                               f"loras/{name}/c2f.pth",
                               "codec.pth", "wavebeat.pth"]}],
          display,
          desc,
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 2, "max_s": 20, "default_s": 10},
              "sample_rate": 44100, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 3.0,
              "params": [
                  {"key": "src_audio", "type": "audio",
                   "label": "Loop to vary", "default": None,
                   "nullable": False,
                   "help": "The material the variations are made of — a "
                           "bar-or-few loop works best"},
                  {"key": "periodic_prompt", "type": "int",
                   "label": "Keep every Nth token", "default": 7,
                   "nullable": False, "min": 1, "max": 30},
                  {"key": "upper_codebook_mask", "type": "int",
                   "label": "Pinned codebooks", "default": 3,
                   "nullable": False, "min": 0, "max": 14},
                  # Was a bool meaning "onsets"; the adapter still accepts
                  # that value, so presets written before the beat tracker
                  # was wired up keep doing what they did.
                  {"key": "beat_mask", "type": "enum",
                   "label": "Keep in time with", "default": "off",
                   "nullable": False,
                   "choices": [
                       {"value": "off", "label": "Nothing — vamp freely"},
                       {"value": "onsets", "label": "Every note attack"},
                       {"value": "beats", "label": "The beat"},
                       {"value": "downbeats", "label": "The downbeat only"}],
                   "help": "Which moments survive the vamp untouched. Note "
                           "attacks keep every transient, which holds the "
                           "rhythm tightly. The beat keeps the pulse and "
                           "re-imagines everything between it — the groove "
                           "stays, the playing changes. Downbeats keep only "
                           "the top of each bar, which is the loosest of the "
                           "three."},
                  {"key": "time_stretch", "type": "int",
                   "label": "Stretch", "default": 1, "nullable": False,
                   "min": 1, "max": 4,
                   "help": "Make the result this many times longer than the "
                           "loop, by writing new material into the gaps "
                           "rather than by slowing anything down. Pitch and "
                           "timbre are untouched; the playing is invented. "
                           "2 turns a bar into two bars of the same idea."},
                  # Same in-fill controls as the base entry: the adapter
                  # serves them for every voice, and omitting them here made
                  # in-fill unreachable on the finetunes only (audit §2).
                  {"key": "prefix_s", "type": "float",
                   "label": "Keep the start (s)", "default": 0.0,
                   "nullable": False, "min": 0.0, "max": 10.0, "step": 0.5,
                   "help": "Leave this many opening seconds untouched and "
                           "vamp only what follows — set both ends to "
                           "in-fill the middle"},
                  {"key": "suffix_s", "type": "float",
                   "label": "Keep the end (s)", "default": 0.0,
                   "nullable": False, "min": 0.0, "max": 10.0, "step": 0.5,
                   "help": "Leave this many closing seconds untouched — "
                           "with a kept start too, the model writes only "
                           "the gap between them"},
                  {"key": "temperature", "type": "float",
                   "label": "Temperature", "default": 1.0, "nullable": False,
                   "min": 0.5, "max": 2.0, "step": 0.05},
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 8, "nullable": False, "min": 2, "max": 36,
                   "help": "Sampling passes per stage. 8 coarse (and half "
                           "that to refine) is the proven fast setting"},
                  seed_param(),
              ],
          },
          8, "medium", CC_NC_SA,
          variant_of="vampnet-vamp", format_=f"finetune · {name}",
          notes="CC BY-NC-SA weights (Hugo Flores García / Descript). The "
                "prompt box is unused: the audio is the prompt. Runs on CPU: "
                "the PyTorch MPS codec path is unstable.",
          settings={"lora": name, "device": "cpu"})
    for name, display, desc in [
        ("choir", "VampNet (choir)",
         "The vamp re-voiced by a model finetuned on choral singing — "
         "whatever loop goes in comes back sung by a phantom choir."),
        ("n64", "VampNet (N64)",
         "Finetuned on Nintendo 64-era game scores: variations arrive "
         "as chiptune-adjacent, cartridge-soundtrack material."),
        ("machines", "VampNet (machines)",
         "Finetuned on machine and industrial recordings — loops come "
         "back as clanking, whirring mechanical texture."),
        ("orchestral", "VampNet (orchestral)",
         "Finetuned on orchestral recordings: the vamp re-plays your "
         "loop with sections of a phantom orchestra."),
    ]
] + [
    # ---- MelodyFlow (vendored Space tree) --------------------------------
    entry("melodyflow-t24", "melodyflow",
          ["facebook/melodyflow-t24-30secs"],
          "MelodyFlow",
          "Meta's flow-matching model with a party trick nothing else here "
          "has: text-guided EDITING. Drop in a clip, describe the change "
          "('make it orchestral', 'swap the drums for congas') and it "
          "rewrites the audio toward the words. Also a fast text-to-music "
          "model in its own right — about 3.5× faster than realtime on "
          "the GPU.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
              "sample_rate": 48000, "outputs_per_job_max": TAKES_MAX,
              "est_seconds_per_audio_second": 0.3,
              "params": [
                  {"key": "src_audio", "type": "audio",
                   "label": "Audio to edit", "default": None, "nullable": True,
                   "help": "A clip to rewrite toward the prompt. Left empty "
                           "the model generates from the prompt alone"},
                  {"key": "edit_strength", "type": "float",
                   "label": "Edit strength", "default": 0.8,
                   "nullable": False, "min": 0.1, "max": 1.0, "step": 0.05},
                  {"key": "edit_source_caption", "type": "string",
                   "label": "Source description", "default": None,
                   "nullable": True,
                   "placeholder": "e.g. sparse piano ballad",
                   "help": "What the source IS — naming it helps the "
                           "inversion hold onto the material while the "
                           "prompt pulls it elsewhere. Only used when "
                           "editing"},
                  {"key": "steps", "type": "int", "label": "Steps",
                   "default": 10, "nullable": False, "min": 4, "max": 125,
                   "help": "Solver steps. 8–10 is already musical for "
                           "generation; edits use at least 25"},
                  {"key": "solver", "type": "enum", "label": "Solver",
                   "default": "euler", "nullable": False,
                   "choices": [{"value": "euler", "label": "Euler (fast)"},
                               {"value": "midpoint", "label": "Midpoint"}]},
                  # Guidance lives on the flow model as a field rather than a
                  # generation parameter, which is why it was never reachable.
                  # Null keeps whatever the checkpoint was released with.
                  {"key": "cfg_coef", "type": "float", "label": "Guidance",
                   "default": None, "nullable": True, "min": 0.0, "max": 10.0,
                   "step": 0.5,
                   "help": "How hard the model is pushed towards your words. "
                           "Left blank it uses the checkpoint's own value. On "
                           "an edit it only steers the pass that travels "
                           "towards the new description — the pass that "
                           "reads the source is unguided by design."},
                  seed_param(),
              ],
          },
          8, "fast", CC_NC,
          notes="Code exists only in the Hugging Face Space's audiocraft "
                "tree (pinned as this family's runtime); weights are "
                "CC-BY-NC. 48 kHz stereo, up to 30 s per pass. Runs on "
                "MPS (proven 2026-08-26: 10 s in 2.8 s steady-state, no "
                "artifacts; the very first run on a machine pays a "
                "one-off ~2 min Metal shader warm-up).",
          settings={"device": "mps"}),
    # ---- diffusers audio pipelines ---------------------------------------
    entry("audioldm2-music", "diffusers", ["cvssp/audioldm2-music"],
          "AudioLDM 2 Music",
          "Music-specialised AudioLDM 2 — text-to-music at 16 kHz.",
          diffusers_caps(30, 10, 100, 3.5, best_of=True), 12, "medium",
          CC_NC_SA),
    entry("audioldm2", "diffusers", ["cvssp/audioldm2"],
          "AudioLDM 2", "General text-to-audio; handles musical prompts.",
          diffusers_caps(30, 10, 100, 3.5, best_of=True), 12, "medium",
          CC_NC_SA),
    entry("audioldm2-large", "diffusers", ["cvssp/audioldm2-large"],
          "AudioLDM 2 Large", "Larger AudioLDM 2 — better quality, slower.",
          diffusers_caps(30, 10, 100, 3.5, est=5.0, best_of=True), 16, "slow",
          CC_NC_SA),
    entry("audioldm-s", "diffusers", ["cvssp/audioldm-s-full-v2"],
          "AudioLDM Small", "The original AudioLDM, small and quick.",
          diffusers_caps(20, 10, 50, 2.5, est=1.5), 8, "fast", CC_NC_SA),
    entry("audioldm-m", "diffusers", ["cvssp/audioldm-m-full"],
          "AudioLDM Medium", "Mid-size AudioLDM.",
          diffusers_caps(20, 10, 50, 2.5, est=2.0), 8, "fast", CC_NC_SA),
    entry("musicldm", "diffusers", ["ucsd-reach/musicldm"],
          "MusicLDM", "AudioLDM retrained on music (beat-synchronous mixup).",
          diffusers_caps(20, 10, 100, 2.0, est=2.5, best_of=True), 8, "medium",
          CC_NC_SA),
    # ---- Split & Recombine: stem separation ------------------------------
    task_entry(
        "separation-htdemucs", "separation", [],
        "Demucs 4-stem",
        "Split a song into vocals, drums, bass and other — Meta's Demucs, "
        "the fast default. Weights (~84 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            {"key": "shifts", "type": "int", "label": "Quality shifts",
             "default": 1, "nullable": False, "min": 1, "max": 5},
        ], est_realtime_factor=0.15),
        8, "fast", MIT, size_hint_bytes=84_000_000, featured=True,
        settings={"engine": "demucs", "model": "htdemucs"}),
    task_entry(
        "separation-htdemucs-ft", "separation", [],
        "Demucs 4-stem (fine-tuned)",
        "The fine-tuned Demucs bag — best 4-stem quality, four models run "
        "in sequence (~4× slower). Weights (~330 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            {"key": "shifts", "type": "int", "label": "Quality shifts",
             "default": 1, "nullable": False, "min": 1, "max": 5},
        ], est_realtime_factor=0.6),
        8, "medium", MIT, size_hint_bytes=330_000_000,
        variant_of="separation-htdemucs", format_="ft · bag of 4",
        settings={"engine": "demucs", "model": "htdemucs_ft"}),
    task_entry(
        "separation-htdemucs-6s", "separation", [],
        "Demucs 6-stem",
        "Adds guitar and piano stems to the classic four. The piano (and to "
        "a degree guitar) stem is experimental — expect artifacts. Weights "
        "(~55 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            {"key": "shifts", "type": "int", "label": "Quality shifts",
             "default": 1, "nullable": False, "min": 1, "max": 5},
        ], est_realtime_factor=0.2),
        8, "fast", MIT, size_hint_bytes=55_000_000,
        variant_of="separation-htdemucs", format_="6-stem · experimental",
        settings={"engine": "demucs", "model": "htdemucs_6s"}),
    task_entry(
        "separation-melband-vocals", "separation",
        # The checkpoint rides the engine's resumable HF downloader (the
        # GitHub-releases host audio-separator uses itself proved flaky at
        # ~900 MB); the adapter stages it under audio-separator's registry
        # name via settings.stage_as. Only the tiny .yaml still comes from
        # audio-separator's own registry at first run.
        [{"repo_id": "KimberleyJSN/melbandroformer", "gated": False,
          "allow_patterns": ["MelBandRoformer.ckpt"]}],
        "Mel-Band RoFormer vocals",
        "The quality pick for vocals: Kim's Mel-Band RoFormer (MIT) splits "
        "a song into vocals and instrumental — several minutes per song.",
        task_caps(["separate"], [
            source_audio_param("The song to split into "
                               "vocals + instrumental"),
        ], est_realtime_factor=2.0),
        8, "slow", MIT,
        settings={"engine": "roformer",
                  "checkpoint": "vocals_mel_band_roformer.ckpt",
                  "stage_as": {"MelBandRoformer.ckpt":
                               "vocals_mel_band_roformer.ckpt"}}),
    task_entry(
        "separation-bsroformer-viperx", "separation",
        [{"repo_id": ASSETS_REPO, "gated": False,
          "allow_patterns": [
              "separation/model_bs_roformer_ep_317_sdr_12.9755.ckpt"]}],
        "BS-RoFormer vocals (viperx)",
        "The highest-SDR vocal separator (UVR/viperx ep 317). Opt-in: the "
        "checkpoint is treated as MIT by the UVR project but carries no "
        "per-file license text.",
        task_caps(["separate"], [
            source_audio_param("The song to split into "
                               "vocals + instrumental"),
        ], est_realtime_factor=2.0),
        8, "slow",
        {"name": "UVR (MIT-asserted)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/Anjok07/ultimatevocalremovergui"},
        variant_of="separation-melband-vocals", format_="viperx ep 317",
        notes="Credit: Ultimate Vocal Remover (Anjok07 & aufr33) and viperx.",
        settings={"engine": "roformer",
                  "checkpoint": "model_bs_roformer_ep_317_sdr_12.9755.ckpt"}),
    task_entry(
        "separation-hdemucs-mmi", "separation", [],
        "Demucs MMI 4-stem",
        "Hybrid Demucs v3 retrained on extra data (MMI) — a different "
        "flavour of the classic four stems, sometimes cleaner on dense "
        "mixes. Weights (~160 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            {"key": "shifts", "type": "int", "label": "Quality shifts",
             "default": 1, "nullable": False, "min": 1, "max": 5},
        ], est_realtime_factor=0.2),
        8, "fast", MIT, size_hint_bytes=160_000_000,
        variant_of="separation-htdemucs", format_="v3 hybrid · MMI",
        settings={"engine": "demucs", "model": "hdemucs_mmi"}),
    task_entry(
        "separation-mdx-extra", "separation", [],
        "Demucs MDX Extra",
        "The bag that won MDX 2021 track B — four v3 models trained with "
        "extra data, run in sequence. Slower than Demucs 4-stem; a second "
        "opinion when a stem comes out muddy. Weights fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            {"key": "shifts", "type": "int", "label": "Quality shifts",
             "default": 1, "nullable": False, "min": 1, "max": 5},
        ], est_realtime_factor=0.6),
        8, "medium", MIT, size_hint_bytes=1_300_000_000,
        variant_of="separation-htdemucs", format_="v3 bag · mdx_extra",
        settings={"engine": "demucs", "model": "mdx_extra"}),
    # ---- Split & Recombine: cleanup (UVR community models) ---------------
    # The same audio-separator path the RoFormer entries ride; what changes is
    # the checkpoint and what the two output stems mean. De-noise/de-echo/
    # de-reverb are repair tools rather than splitters — the "stem" the user
    # wants is the cleaned one.
    task_entry(
        "cleanup-uvr-denoise", "separation", [],
        "UVR De-Noise",
        "Strip broadband noise from a recording — hiss, hum, room rumble. "
        "Returns the cleaned audio and the removed noise as separate files. "
        "Weights (~127 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The recording to clean up"),
            *vr_cleanup_params(),
        ], est_realtime_factor=1.3),
        8, "medium",
        {"name": "UVR community (no formal license)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/Anjok07/ultimatevocalremovergui"},
        size_hint_bytes=127_000_000,
        notes="Credit: Ultimate Vocal Remover (Anjok07 & aufr33) / FoxJoy.",
        settings={"engine": "roformer", "checkpoint": "UVR-DeNoise.pth"}),
    task_entry(
        "cleanup-uvr-deecho-dereverb", "separation", [],
        "UVR De-Echo + De-Reverb",
        "Pull the room out of a recording: removes echo and reverb, "
        "returning the dry signal and the removed ambience separately. The "
        "standard fix before re-mixing a vocal recorded in a live room. "
        "Weights (~224 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The recording to dry out"),
            *vr_cleanup_params(),
        ], est_realtime_factor=10.0),
        8, "slow",
        {"name": "UVR community (no formal license)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/Anjok07/ultimatevocalremovergui"},
        size_hint_bytes=224_000_000,
        variant_of="cleanup-uvr-denoise", format_="echo + reverb",
        notes="Credit: Ultimate Vocal Remover (Anjok07 & aufr33) / FoxJoy.",
        settings={"engine": "roformer",
                  "checkpoint": "UVR-DeEcho-DeReverb.pth"}),
    task_entry(
        "separation-uvr-kimvocal2", "separation", [],
        "Kim Vocal 2 (MDX-Net)",
        "One of the two community-consensus vocal models: MDX-Net trained "
        "by Kim, known for clean vocal edges. Vocals + instrumental. "
        "Weights (~67 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into "
                               "vocals + instrumental"),
        ], est_realtime_factor=4.5),
        8, "slow",
        {"name": "UVR community (no formal license)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/Anjok07/ultimatevocalremovergui"},
        size_hint_bytes=67_000_000,
        variant_of="separation-melband-vocals", format_="MDX · Kim Vocal 2",
        notes="Credit: Ultimate Vocal Remover (Anjok07 & aufr33) and Kim.",
        settings={"engine": "roformer", "checkpoint": "Kim_Vocal_2.onnx"}),
    task_entry(
        "separation-uvr-vocft", "separation", [],
        "Voc FT (MDX-Net)",
        "The other community-consensus vocal model: UVR's fine-tuned "
        "MDX-Net. Vocals + instrumental, noticeably faster than Kim Vocal 2. "
        "Weights (~67 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into "
                               "vocals + instrumental"),
        ], est_realtime_factor=1.4),
        8, "medium",
        {"name": "UVR community (no formal license)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/Anjok07/ultimatevocalremovergui"},
        size_hint_bytes=67_000_000,
        variant_of="separation-melband-vocals", format_="MDX · Voc FT",
        notes="Credit: Ultimate Vocal Remover (Anjok07 & aufr33).",
        settings={"engine": "roformer",
                  "checkpoint": "UVR-MDX-NET-Voc_FT.onnx"}),
    task_entry(
        "separation-uvr-karaoke", "separation", [],
        "UVR Karaoke 2 (MDX-Net)",
        "The karaoke split: lead vocal out, backing vocals kept with the "
        "band — different from a full vocal split, which takes the choir "
        "too. Weights (~53 MB) fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to make a karaoke mix from"),
        ], est_realtime_factor=1.0),
        8, "medium",
        {"name": "UVR community (no formal license)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/Anjok07/ultimatevocalremovergui"},
        size_hint_bytes=53_000_000,
        notes="Credit: Ultimate Vocal Remover (Anjok07 & aufr33).",
        settings={"engine": "roformer",
                  "checkpoint": "UVR_MDXNET_KARA_2.onnx"}),
    # ---- Split & Recombine: ensembles -------------------------------------
    #
    # The biggest quality lever in separation, and the one thing every serious
    # UVR workflow does that this app could not: run several models over the
    # same track and combine their stems. audio-separator ships the presets
    # (models + combining algorithm, chosen together — `min_fft` keeps only
    # what every model agreed on, `max_spec` keeps anything any of them
    # found), so the card is a chooser rather than a pile of knobs.
    #
    # One card rather than nine: they share a runtime and differ only in which
    # models run, which is what a parameter is for. The models download on
    # first use, as everything else in this family does.
    task_entry(
        "separation-ensemble", "separation", [],
        "Ensemble separation (UVR)",
        "Runs several separators over the same track and combines their "
        "stems — consistently cleaner than any single model, and several "
        "times slower. Each preset picks both the models and how their "
        "answers are combined: 'clean' keeps only what they all agreed on, "
        "'full' keeps anything any of them found. Models fetch on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to separate"),
            {"key": "ensemble_preset", "type": "enum", "label": "Preset",
             "default": "vocal_balanced", "nullable": False,
             "choices": [
                 {"value": "vocal_balanced", "label": "Vocals — balanced"},
                 {"value": "vocal_clean",
                  "label": "Vocals — clean (fewest artefacts)"},
                 {"value": "vocal_full",
                  "label": "Vocals — full (keeps every breath)"},
                 {"value": "vocal_rvc", "label": "Vocals — for voice cloning"},
                 {"value": "instrumental_balanced",
                  "label": "Instrumental — balanced"},
                 {"value": "instrumental_clean",
                  "label": "Instrumental — clean"},
                 {"value": "instrumental_full",
                  "label": "Instrumental — full"},
                 {"value": "instrumental_low_resource",
                  "label": "Instrumental — light on memory"},
                 {"value": "karaoke",
                  "label": "Karaoke (three models, keeps backing vocals)"}],
             "help": "Which models run and how their stems are combined. "
                     "'Clean' presets keep only what the models agreed on, "
                     "so bleed is rare and quiet detail can go missing; "
                     "'full' presets keep anything any model found, so "
                     "nothing is lost and a little bleed survives."},
        ], est_realtime_factor=6.0),
        12, "slow",
        {"name": "UVR community (no formal license)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://github.com/nomadkaraoke/python-audio-separator"},
        size_hint_bytes=400_000_000,
        variant_of="separation-melband-vocals", format_="ensemble · 2–3 models",
        notes="Every preset downloads two or three separators the first time "
              "it runs, so the first render of a preset is slow and the "
              "figure above is an estimate. Credit: Ultimate Vocal Remover "
              "(Anjok07 & aufr33) for the models, python-audio-separator for "
              "the ensembling.",
        settings={"engine": "roformer"}),
    # ---- Split & Recombine: research separation (msst family) ------------
    task_entry(
        "separation-bsrnn", "msst", ["rtikw/bsrnn-large"],
        "BSRNN 4-stem (Inria)",
        "The commercially-clean separator: Inria's Band-Split RNN with "
        "CC-BY-4.0 weights — the only separation model here whose license "
        "asks nothing but credit. Four stems, one model per stem.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            {"key": "targets", "type": "enum", "label": "Stems to extract",
             "default": "all", "nullable": False,
             "choices": [{"value": "all", "label": "All four"},
                         {"value": "vocals", "label": "Vocals only"},
                         {"value": "drums", "label": "Drums only"},
                         {"value": "bass", "label": "Bass only"},
                         {"value": "other", "label": "Other only"}],
             "help": "Each BSRNN stem is its own checkpoint and its own "
                     "pass — one stem costs a quarter of a full split"},
        ], est_realtime_factor=2.0),
        8, "slow",
        {"name": "CC BY 4.0 (Inria)", "commercial_use": True,
         "requires_hf_token": False,
         "url": "https://zenodo.org/records/17516442"},
        notes="Below the best community models on raw SDR, but the license "
              "may matter more than the last decibel. Weights are an "
              "unmodified per-file mirror of Inria's Zenodo record "
              "(CC BY 4.0, credit Magron et al.).",
        settings={"engine": "bsrnn", "device": "mps"}),
    task_entry(
        "separation-scnet", "msst", [],
        "SCNet 4-stem (research)",
        "The research frontier's efficient 4-stem model, run through the "
        "MSST training repo's own inference. Trained on MUSDB18 "
        "(research-only data) — for listening and experiments, not "
        "commercial release. Weights fetch from GitHub on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            *msst_params(),
        ], est_realtime_factor=2.5),
        8, "slow",
        {"name": "MIT (code) / MUSDB18-trained weights",
         "commercial_use": False, "requires_hf_token": False,
         "url": "https://github.com/ZFTurbo/"
                "Music-Source-Separation-Training"},
        size_hint_bytes=40_000_000,
        variant_of="separation-bsrnn", format_="SCNet · musdb18",
        settings={"engine": "msst", "model_type": "scnet",
                  "config_url": "https://github.com/ZFTurbo/"
                                "Music-Source-Separation-Training/releases/"
                                "download/v.1.0.6/config_musdb18_scnet.yaml",
                  "ckpt_url": "https://github.com/ZFTurbo/"
                              "Music-Source-Separation-Training/releases/"
                              "download/v.1.0.6/"
                              "scnet_checkpoint_musdb18.ckpt",
                  "device": "mps"}),
    task_entry(
        "separation-mdx23c-vocals", "msst", [],
        "MDX23C vocals (research)",
        "ZFTurbo's MDX23C vocal separator from the MSST zoo — a different "
        "architecture from the RoFormers, worth an A/B when a vocal split "
        "sounds off. Weights fetch from GitHub on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into "
                               "vocals + instrumental"),
            *msst_params(extract_instrumental=True),
        ], est_realtime_factor=7.0),
        8, "slow",
        {"name": "MIT (code); checkpoint license unstated",
         "commercial_use": False, "requires_hf_token": False,
         "url": "https://github.com/ZFTurbo/"
                "Music-Source-Separation-Training"},
        size_hint_bytes=170_000_000,
        variant_of="separation-bsrnn", format_="MDX23C · vocals",
        settings={"engine": "msst", "model_type": "mdx23c",
                  "config_url": "https://github.com/ZFTurbo/"
                                "Music-Source-Separation-Training/releases/"
                                "download/v1.0.0/config_vocals_mdx23c.yaml",
                  "ckpt_url": "https://github.com/ZFTurbo/"
                              "Music-Source-Separation-Training/releases/"
                              "download/v1.0.0/"
                              "model_vocals_mdx23c_sdr_10.17.ckpt",
                  "device": "mps"}),
    task_entry(
        "separation-scnet-xl", "msst", [],
        "SCNet XL 4-stem (research)",
        "The strongest 4-stem checkpoint in the MSST zoo (SDR 10.08 on "
        "MUSDB test — a full decibel over the base SCNet). Same "
        "research-only training data caveat; noticeably slower. Weights "
        "fetch from GitHub on first run.",
        task_caps(["separate"], [
            source_audio_param("The song to split into stems"),
            *msst_params(),
        ], est_realtime_factor=5.0),
        12, "slow",
        {"name": "MIT (code) / MUSDB18-trained weights",
         "commercial_use": False, "requires_hf_token": False,
         "url": "https://github.com/ZFTurbo/"
                "Music-Source-Separation-Training"},
        size_hint_bytes=800_000_000,
        variant_of="separation-scnet", format_="SCNet XL · IHF",
        settings={"engine": "msst", "model_type": "scnet",
                  "config_url": "https://github.com/ZFTurbo/"
                                "Music-Source-Separation-Training/releases/"
                                "download/v1.0.15/"
                                "config_musdb18_scnet_xl_more_wide_v5.yaml",
                  "ckpt_url": "https://github.com/ZFTurbo/"
                              "Music-Source-Separation-Training/releases/"
                              "download/v1.0.15/"
                              "model_scnet_ep_36_sdr_10.0891.ckpt",
                  "device": "mps"}),
    task_entry(
        "separation-drumsep", "msst", [],
        "Drum-kit split (DrumSep)",
        "Splits a DRUM track into its pieces — kick, snare, toms, hi-hat, "
        "ride and crash as separate parts. Feed it the drum stem from a "
        "4-stem split; nothing else in the catalog does this.",
        task_caps(["separate"], [
            source_audio_param("A drum stem — run a 4-stem split first "
                               "and feed the drums in"),
            *msst_params(),
        ], est_realtime_factor=7.0),
        8, "slow",
        {"name": "MIT (code); community checkpoint (aufr33 + jarredou)",
         "commercial_use": False, "requires_hf_token": False,
         "url": "https://github.com/ZFTurbo/"
                "Music-Source-Separation-Training"},
        size_hint_bytes=438_000_000,
        variant_of="separation-bsrnn", format_="MDX23C · drum kit",
        notes="Community-trained checkpoint (ep 141, SDR 10.81). Expects "
              "drums in, not a full mix. The original jarredou GitHub "
              "release vanished (2026-09 audit); these URLs are the "
              "MSST-WebUI mirror of the same files.",
        settings={"engine": "msst", "model_type": "mdx23c",
                  "config_url": "https://raw.githubusercontent.com/"
                                "SUC-DriverOld/MSST-WebUI/main/"
                                "configs_backup/multi_stem_models/"
                                "aufr33-jarredou_DrumSep_model_mdx23c_"
                                "ep_141_sdr_10.8059.ckpt.yaml",
                  "ckpt_url": "https://huggingface.co/Sucial/MSST-WebUI/"
                              "resolve/main/All_Models/multi_stem_models/"
                              "aufr33-jarredou_DrumSep_model_mdx23c_"
                              "ep_141_sdr_10.8059.ckpt",
                  "device": "mps"}),
    # ---- Split & Recombine: analysis -------------------------------------
    task_entry(
        "analysis-basic", "analysis",
        [{"repo_id": ASSETS_REPO, "gated": False,
          "allow_patterns": ["analysis/beat_this-final0.ckpt"]}],
        "Musical analysis",
        "Beats, downbeats, tempo, key (Camelot), structure sections and "
        "loudness — the metadata that powers alignment and compatibility "
        "badges.",
        task_caps(["analyze"], [
            source_audio_param("The audio to analyze"),
            {"key": "deep", "type": "bool", "label": "Structure analysis",
             "default": True, "nullable": False,
             "help": "Also segment the song into sections (a little slower)"},
        ], est_realtime_factor=0.1),
        4, "fast", MIT, size_hint_bytes=78_000_000, featured=True),
    task_entry(
        "analysis-clap", "analysis",
        ["laion/larger_clap_music",
         {"repo_id": ASSETS_REPO, "gated": False,
          "allow_patterns": ["analysis/beat_this-final0.ckpt"]}],
        "Musical analysis + timbre (CLAP)",
        "Everything Musical analysis does, plus a CLAP timbre embedding — "
        "adds a timbral-similarity signal to compatibility ranking "
        "(\"What mashes with this?\"), and can score a render against the "
        "prompt that asked for it.",
        task_caps(["analyze"], [
            source_audio_param("The audio to analyze"),
            {"key": "deep", "type": "bool", "label": "Structure analysis",
             "default": True, "nullable": False,
             "help": "Also segment the song into sections (a little slower)"},
            {"key": "prompt_text", "type": "string", "label": "Score vs prompt",
             "default": None, "nullable": True,
             "placeholder": "dreamy synthwave with saxophone",
             "help": "Also measure how closely the audio matches this "
                     "description (CLAP similarity, stored with the "
                     "analysis)"},
        ], est_realtime_factor=0.15),
        6, "fast", APACHE, variant_of="analysis-basic", format_="+ CLAP",
        settings={"embed": "clap"}),
    task_entry(
        "analysis-chords-btc", "analysis",
        [{"repo_id": ASSETS_REPO, "gated": False,
          "allow_patterns": ["analysis/btc_model.pt",
                             "analysis/btc_model_large_voca.pt"]}],
        "Chord recognition (BTC)",
        "Reads the chord track: a transformer trained for chord "
        "recognition writes timed segments over 170 chord types — the "
        "harmony layer the beat grid and key estimate don't give you. "
        "Run it as a transcription and the same chords come back as a "
        "playable MIDI part instead.",
        task_caps(["analyze", "transcribe"], [
            source_audio_param("The song to read chords from"),
        ], est_realtime_factor=0.8),
        4, "fast", MIT,
        notes="BTC (Park & Choi, ISMIR 2019), vendored and modernised in "
              "the analysis adapter. Pairs with the beat grid for a song "
              "map; N = no chord, X = unclear. The transcribe route "
              "renders root-position triads/tetrads — a chord bed to "
              "stack under the Workbench, not a performance.",
        settings={"mode": "chords", "voca": "large"}),
    task_entry(
        "analysis-squim", "analysis", [],
        "Quality scores (SQUIM)",
        "Reference-free audio-quality estimates (STOI, PESQ, SI-SDR "
        "proxies) — rank separation takes, flag artifacted renders, A/B "
        "seeds. Speech-trained, so treat the numbers as relative, not as "
        "grades. Weights (~30 MB) fetch on first run.",
        task_caps(["analyze"], [
            source_audio_param("The audio to score"),
            # SQUIM's subjective half predicts a listening-test score, and it
            # cannot do it from the audio alone: the model was trained to
            # compare against a *non-matching* reference — any clean recording
            # of the same broad kind, not the same performance. No reference,
            # no MOS, which is why this is nullable and why the card still
            # works untouched.
            {"key": "reference_audio", "type": "audio",
             "label": "Reference recording", "default": None, "nullable": True,
             "help": "Optional. A recording you consider good — it does not "
                     "have to be the same music, only the same kind of thing "
                     "recorded well. Adding one unlocks a predicted listening "
                     "score (MOS, 1–5) alongside the technical numbers, and "
                     "fetches a second 360 MB model the first time you use "
                     "it."},
        ], est_realtime_factor=0.3),
        4, "fast",
        {"name": "BSD-2-Clause (torchaudio)", "commercial_use": True,
         "requires_hf_token": False,
         "url": "https://pytorch.org/audio/stable/pipelines.html"},
        size_hint_bytes=30_000_000,
        notes="The sleeper use is scoring the app's own outputs: compare "
              "two takes of the same material and keep the cleaner one.",
        settings={"mode": "squim"}),
    # ---- Timbre & FX: RAVE (task `timbre`) --------------------------------
    #
    # One TorchScript file per model, fetched from IRCAM's own API at first
    # use (CC-BY-NC — download from origin, never re-host). The model IS the
    # effect: whatever goes in comes out played by the model's instrument.
] + [
    task_entry(
        f"timbre-rave-{name}", "rave", [],
        display,
        desc,
        task_caps(["timbre"], [
            source_audio_param("The audio to re-voice — rhythmic material "
                               "keeps its groove; the timbre changes"),
            {"key": "source_audio_b", "type": "audio",
             "label": "Second source (morph)", "default": None,
             "nullable": True,
             "help": "Add a second recording and the two are blended in "
                     "the model's latent space — a morph in its own "
                     "instrument, not a crossfade"},
            {"key": "blend", "type": "float", "label": "Blend",
             "default": 0.5, "nullable": False, "min": 0.0, "max": 1.0,
             "step": 0.05,
             "help": "Only with a second source: 0 is all the first "
                     "recording, 1 all the second"},
        ], est_realtime_factor=0.15),
        4, "fast",
        {"name": "CC BY-NC 4.0 (IRCAM)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://acids-ircam.github.io/rave_models_download"},
        size_hint_bytes=80_000_000,
        settings={"rave_model": name},
        notes="Genuinely realtime on CPU. Model fetches from IRCAM's API on "
              "first run.",
        **({"variant_of": "timbre-rave-percussion", "format_": name}
           if name != "percussion" else {"featured": False}))
    for name, display, desc in [
        ("percussion", "RAVE Percussion (timbre)",
         "Replays any audio as percussion — hum a rhythm and it comes back "
         "as drums. The proven, instant introduction to neural timbre "
         "transfer."),
        ("vintage", "RAVE Vintage (timbre)",
         "The vintage-music RAVE: audio comes back with old-record "
         "instrumentation and colour."),
        ("sol_ordinario", "RAVE Strings & Winds (timbre)",
         "Trained on orchestral instrument recordings (SOL): melodies come "
         "back bowed and blown."),
        ("VCTK", "RAVE Voice (timbre)",
         "Trained on speech (VCTK): anything you feed it comes back as an "
         "eerie choir of talking voices."),
        # The 2026-08 roster extension — each name verified downloadable
        # from IRCAM's API before shipping (the API serves full files).
        ("nasa", "RAVE NASA (timbre)",
         "Trained on NASA mission recordings: radio chatter, telemetry "
         "and launch rumble — everything comes back as space-program "
         "atmosphere."),
        ("musicnet", "RAVE Chamber Music (timbre)",
         "Trained on MusicNet's classical chamber recordings: audio "
         "returns as an ensemble of strings, winds and piano."),
        ("sol_full", "RAVE Orchestra Full (timbre)",
         "The full SOL orchestral set, extended techniques included — "
         "wilder and woodier than the ordinario model."),
        ("isis", "RAVE Singing (timbre)",
         "Trained on solo singing (ISiS): melodies come back as a wordless "
         "sung voice."),
    ]
] + [
    # ---- Timbre & FX: NAM re-amping (task `reamp`) ------------------------
    task_entry(
        "reamp-nam", "nam", [],
        "Re-amp (Neural Amp Modeler)",
        "Run any track through a captured amp, pedal or full rig. Captures "
        "come from tone3000.com — hundreds of thousands of them, free — and "
        "the ones you download are kept in your library, so the rig you used "
        "last time is one click away. The render is 26× faster than realtime. "
        "The de-facto standard for amp capture.",
        task_caps(["reamp"], [
            source_audio_param("The track to re-amp — a DI guitar or a "
                               "separated stem responds best"),
            {"key": "nam_file", "type": "audio", "label": "Amp capture (.nam)",
             "default": None, "nullable": False,
             "help": "The captured rig to play through. Choose one you have "
                     "already downloaded, search TONE3000 for a new one, or "
                     "add a .nam file of your own — including a capture you "
                     "made yourself with NAM's trainer"},
            # The two controls every re-amp rig has and this one did not.
            {"key": "mix", "type": "float", "label": "Amp mix",
             "default": 1.0, "nullable": False, "min": 0.0, "max": 1.0,
             "step": 0.05,
             "help": "How much of the amp you hear against the untouched "
                     "track. 1 is the amp alone; blending some dry signal "
                     "back in is how a heavily distorted guitar or a parallel "
                     "bass channel keeps its attack and its low end."},
            {"key": "loudness_match", "type": "bool",
             "label": "Match capture loudness", "default": False,
             "nullable": False,
             "help": "Level the result to the same reference every capture is "
                     "measured against, so two rigs can be compared on tone "
                     "instead of on how hot they happened to be recorded. "
                     "Uses the loudness the capture's own author stored in "
                     "the file; a capture that carries none is left alone."},
        ], est_realtime_factor=0.05),
        4, "fast", MIT, size_hint_bytes=5_000_000,
        notes="The NAM runtime is MIT; each capture carries its own terms on "
              "the site it came from, and the app keeps the author and "
              "licence beside every capture it stores. Captures are tiny "
              "(KB–MB) and are kept in the model library's auxiliary folder — "
              "counted with your models and moved with them, but never "
              "removed by a clear."),
    # ---- Voice: seed-vc zero-shot conversion (task `convert-voice`) -------
    task_entry(
        "convert-voice-seedvc", "seedvc", [],
        "Voice changer (seed-vc)",
        "Re-sings a vocal in the timbre of a short reference recording YOU "
        "supply — record ten seconds of yourself and any vocal becomes your "
        "voice. Speaks and sings (singing mode follows the melody). "
        "Zero-shot: no training, no stored voices.",
        task_caps(["convert-voice"], [
            source_audio_param("The vocal to convert — a separated vocal "
                               "stem converts far more cleanly than a mix"),
            {"key": "reference_audio", "type": "audio",
             "label": "Target voice", "default": None, "nullable": False,
             "help": "A short recording of the voice this should become — "
                     "your own, or one you have permission to use. Ten "
                     "clean seconds is plenty"},
            {"key": "diffusion_steps", "type": "int", "label": "Steps",
             "default": 10, "nullable": False, "min": 4, "max": 50,
             "help": "Diffusion passes. 10 is the proven fast setting; more "
                     "refines the timbre and takes proportionally longer"},
            {"key": "sing_mode", "type": "bool", "label": "Singing mode",
             "default": False, "nullable": False,
             "help": "Track the melody's pitch (F0 conditioning) — turn on "
                     "for sung material, leave off for speech"},
            {"key": "pitch_shift_st", "type": "int",
             "label": "Pitch shift (semitones)", "default": 0,
             "nullable": False, "min": -12, "max": 12,
             "help": "Transpose the output. 0 with singing mode on lets the "
                     "model auto-fit the reference's range"},
            {"key": "length_adjust", "type": "float",
             "label": "Length stretch", "default": 1.0, "nullable": False,
             "min": 0.5, "max": 2.0, "step": 0.05,
             "help": "Stretch factor of the converted performance — below "
                     "1 speeds the delivery up, above 1 slows it down"},
            {"key": "cfg_rate", "type": "float",
             "label": "Voice guidance", "default": 0.7, "nullable": False,
             "min": 0.0, "max": 1.0, "step": 0.05,
             "help": "How hard the conversion is pushed toward the "
                     "reference voice — higher is a closer imitation, "
                     "lower keeps more of the source delivery"},
            seed_param(),
        ], est_realtime_factor=4.5),
        8, "slow",
        {"name": "GPL-3.0 (code); weights via Hugging Face",
         "commercial_use": True, "requires_hf_token": False,
         "url": "https://github.com/Plachtaa/seed-vc"},
        size_hint_bytes=2_000_000_000,
        notes="Runs on CPU (about 4–5× the clip length). The reference "
              "voice is supplied per job and never stored — this app ships "
              "no voice library, deliberately. Weights (~2 GB) auto-fetch "
              "on the first conversion."),
    task_entry(
        "convert-voice-seedvc-v2", "seedvc", [],
        "Voice changer V2 (seed-vc)",
        "The second-generation seed-vc: converts SPEECH into the timbre of "
        "a short reference recording you supply, and can also carry the "
        "reference's style over — emotion, accent, delivery — or strip a "
        "voice's identity entirely (anonymize). Speech only: for singing, "
        "use the original Voice changer's singing mode.",
        task_caps(["convert-voice"], [
            source_audio_param("The speech to convert — a clean, dry "
                               "recording converts best"),
            {"key": "reference_audio", "type": "audio",
             "label": "Target voice", "default": None, "nullable": False,
             "help": "A short recording of the voice this should become — "
                     "your own, or one you have permission to use. Ten "
                     "clean seconds is plenty"},
            {"key": "diffusion_steps", "type": "int", "label": "Steps",
             "default": 30, "nullable": False, "min": 4, "max": 100,
             "help": "Diffusion passes. 30 is the upstream default; more "
                     "refines the timbre and takes proportionally longer"},
            # The wrapper has two conversion paths and only one was wired up.
            {"key": "mode", "type": "enum", "label": "What to convert",
             "default": "full", "nullable": False,
             "choices": [
                 {"value": "full", "label": "Voice and delivery"},
                 {"value": "timbre", "label": "Voice only (keep the timing)"}],
             "help": "'Voice and delivery' re-speaks the line in the target "
                     "voice and may re-phrase it. 'Voice only' skips that "
                     "stage entirely: the timing, phrasing and expression of "
                     "your recording are kept exactly, and only the timbre "
                     "changes. Faster, and the right choice for anything "
                     "that has to stay in time."},
            {"key": "convert_style", "type": "bool", "label": "Copy style",
             "default": False, "nullable": False,
             "help": "Also carry the reference's emotion, accent and "
                     "delivery — not just the timbre. Part of the stage "
                     "'Voice only' skips, so it does nothing there"},
            {"key": "anonymize", "type": "bool", "label": "Anonymize only",
             "default": False, "nullable": False,
             "help": "Strip the speaker's identity instead of imitating "
                     "the reference — the output is a neutral voice. Part of "
                     "the stage 'Voice only' skips, so it does nothing "
                     "there"},
            {"key": "similarity_cfg_rate", "type": "float",
             "label": "Voice similarity", "default": 0.7, "nullable": False,
             "min": 0.0, "max": 1.0, "step": 0.05,
             "help": "How hard the conversion is pushed toward the "
                     "reference voice — higher is a closer imitation"},
            {"key": "intelligibility_cfg_rate", "type": "float",
             "label": "Clarity", "default": 0.7, "nullable": False,
             "min": 0.0, "max": 1.0, "step": 0.05,
             "help": "How hard the words are held onto — raise it if the "
                     "conversion mumbles, lower it for a looser read. Part of "
                     "the stage 'Voice only' skips, so it does nothing "
                     "there"},
            {"key": "length_adjust", "type": "float",
             "label": "Length stretch", "default": 1.0, "nullable": False,
             "min": 0.5, "max": 2.0, "step": 0.05,
             "help": "Stretch factor of the converted performance — below "
                     "1 speeds the delivery up, above 1 slows it down"},
            seed_param(),
        ], est_realtime_factor=6.0),
        8, "slow",
        {"name": "GPL-3.0 (code); weights via Hugging Face",
         "commercial_use": True, "requires_hf_token": False,
         "url": "https://github.com/Plachtaa/seed-vc"},
        size_hint_bytes=3_000_000_000,
        settings={"version": 2},
        notes="Runs on CPU, about 6× the clip length at 30 steps "
              "(measured). The reference voice is supplied per job and "
              "never stored. The V2 stack (AR + CFM, ~3 GB with its "
              "content extractors) auto-fetches on the first conversion."),
    # ---- Voice: YingMusic zero-shot singing (task `sing`) -----------------
    task_entry(
        "sing-yingmusic", "yingmusic",
        [{"repo_id": "GiantAILab/YingMusic-Singer", "gated": False,
          "allow_patterns": ["autoencoder_music_dsp1920.ckpt", "rmvpe.pt",
                             "singer.v1.pt", "some.pt",
                             "stable_audio_1920_vae.json"]}],
        "Singer (YingMusic)",
        "Types words, sings them: zero-shot singing voice synthesis. Give "
        "it a melody (a sung or played line, or a MIDI file), the lyrics, "
        "and a few seconds of the voice that should perform them — your "
        "own recording works. Bilingual Chinese/English.",
        # sample_rate overridden: the model writes 48 kHz, not task_caps's
        # 44.1 default (audit B10).
        {**task_caps(["sing"], [
            # Nullable, unlike most source_audio: a MIDI melody is a full
            # substitute, and requiring audio forced a throwaway attachment
            # onto MIDI-only jobs (audit B10). The adapter checks that at
            # least one of the two is present.
            {"key": "source_audio", "type": "audio", "label": "Source audio",
             "default": None, "nullable": True,
             "help": "The melody to sing — a vocal or single-line "
                     "instrumental recording the singer follows. Optional "
                     "when a MIDI melody is set"},
            {"key": "melody_midi", "type": "midi", "label": "Melody (MIDI)",
             "default": None, "nullable": True,
             "help": "A MIDI melody instead of the recording — wins when "
                     "both are set"},
            {"key": "reference_audio", "type": "audio",
             "label": "Voice reference", "default": None, "nullable": False,
             "help": "A short clean recording of the voice that should "
                     "sing — yours, or one you have permission to use"},
            # reference_text/lyrics_text are hard-required by the adapter;
            # declaring them nullable turned a submit-time 422 into a late
            # in-worker failure (audit B10).
            {"key": "reference_text", "type": "string",
             "label": "Reference words", "default": None, "nullable": False,
             "placeholder": "the words spoken/sung in the reference clip",
             "help": "What the reference recording actually says or sings "
                     "— the model needs the text to read the voice"},
            {"key": "lyrics_text", "type": "string", "label": "Lyrics",
             "default": None, "nullable": False,
             "placeholder": "the words to sing",
             "help": "The words to perform to the melody"},
            seed_param(),
            {"key": "nfe_steps", "type": "int", "label": "Steps",
             "default": 8, "nullable": False, "min": 4, "max": 64,
             "help": "Diffusion passes. 8 is the proven fast setting; 32 "
                     "is upstream's quality default"},
            {"key": "cfg_strength", "type": "float", "label": "Guidance",
             "default": 4.0, "nullable": False, "min": 1.0, "max": 8.0,
             "step": 0.5,
             "help": "How hard the singer is held to the lyrics and "
                     "melody. Higher is more literal and can strain; "
                     "lower is looser and more natural"},
            {"key": "pitch_shift_st", "type": "int",
             "label": "Pitch shift (semitones)", "default": 0,
             "nullable": False, "min": -12, "max": 12,
             "help": "Transpose the melody into the reference voice's "
                     "comfortable range"},
        ], est_realtime_factor=3.0), "sample_rate": 48000},
        16, "slow", APACHE,
        notes="The voice is supplied per job and never stored — no voice "
              "library ships with this app, deliberately. Chinese-centric "
              "training; English works, judge it by ear. The SDPA "
              "attention substitute ignores their sliding window — "
              "restoring it is the known quality follow-up.",
        settings={}),
    # ---- Music to words: zero-shot tagging --------------------------------
    #
    # A base entry rather than a variant of analysis-basic, deliberately: it
    # answers a different task (`tag`), and the featured-model check wants a
    # base per task — a featured variant is invisible in the Models list,
    # which places groups by their base.
    task_entry(
        "tag-clap", "analysis",
        ["laion/larger_clap_music"],
        "Genre & mood tags (CLAP)",
        "Scores a track against vocabularies of genres, moods and "
        "instruments and keeps the labels that fit. No tagging model is "
        "trained or downloaded — it is the same CLAP encoder that powers "
        "timbre matching, asked a different question.",
        task_caps(["tag"], [
            source_audio_param("The audio to tag"),
            {"key": "top_k", "type": "int", "label": "Tags per group",
             "default": 5, "nullable": False, "min": 1, "max": 15,
             "help": "How many labels to keep for each of genre, mood and "
                     "instrumentation"},
            # The model has no vocabulary of its own — every tag it returns is
            # a cosine against a sentence — so the three curated lists are a
            # default, not a limit. This is the way out of them.
            {"key": "labels", "type": "string", "label": "Your own labels",
             "default": None, "nullable": True,
             "placeholder": "comma separated, e.g. bagpipes, recorded in a "
                            "garage, 1970s",
             "help": "Score labels you write instead of the built-in genre, "
                     "mood and instrument lists. Anything can be a label — an "
                     "instrument, a decade, a production style — and every one "
                     "comes back with its score, best first. Phrases beat "
                     "single words."},
        ], est_realtime_factor=0.05),
        4, "fast", APACHE, featured=True,
        settings={"embed": "clap", "tagger": "zeroshot"},
        notes="Zero-shot: the vocabulary is the model. Labels it has never "
              "been trained on still score, and niche genres score poorly."),
    task_entry(
        "tag-essentia-discogs", "essentia", [],
        "Genre & mood tags (Essentia)",
        "TRAINED tags rather than zero-shot: MTG's Discogs-EffNet embeds "
        "the track once, then tiny heads score 400 Discogs genre styles, "
        "a dozen mood-and-character axes (happy/sad/party/aggressive/"
        "relaxed, acoustic/electronic, bright or dark timbre, tonal/atonal, "
        "approachability, engagement), danceability and voice/instrumental. "
        "Seconds per song — the embedding is cached, so re-tagging and "
        "library sweeps cost almost nothing. Weights (~25 MB) fetch from "
        "UPF on first run.",
        task_caps(["tag"], [
            source_audio_param("The audio to tag"),
            {"key": "top_n", "type": "int", "label": "Genres to keep",
             "default": 5, "nullable": False, "min": 1, "max": 15,
             "help": "How many of the 400 genre styles to keep, best "
                     "first; moods and danceability report on their own "
                     "thresholds"},
        ], est_realtime_factor=0.15),
        4, "fast",
        {"name": "CC BY-NC-SA 4.0 (MTG/UPF)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://essentia.upf.edu/models.html"},
        size_hint_bytes=20_000_000,
        notes="Non-commercial: MTG licenses the models CC BY-NC-SA and "
              "offers commercial terms on request. The 400-style genre "
              "vocabulary is Discogs's own taxonomy — expect precise "
              "electronic-music subgenres in particular.",
        # Named explicitly since the Jamendo heads joined the adapter's table:
        # an entry with no list loads every head there is, and this card is
        # the Discogs one.
        settings={"heads": ["genre", "mood_happy", "mood_sad", "mood_party",
                            "mood_aggressive", "mood_relaxed", "danceability",
                            "voice_instrumental", "mood_acoustic",
                            "mood_electronic", "timbre", "tonal_atonal",
                            "approachability", "engagement"]}),
    task_entry(
        "tag-essentia-jamendo", "essentia", [],
        "Mood, theme & instrument tags (Jamendo)",
        "The same one-pass embedding read by MTG's Jamendo heads instead of "
        "the Discogs one — a library's vocabulary rather than a record "
        "shop's. 56 moods and themes (melancholic, epic, film, "
        "documentary), 40 instruments heard in the mix, 87 genres and "
        "Jamendo's own top-50 tags. Multi-label: a track is allowed to be "
        "several things at once. Weights (~25 MB) fetch from UPF on first "
        "run.",
        task_caps(["tag"], [
            source_audio_param("The audio to tag"),
            {"key": "top_n", "type": "int", "label": "Tags per set",
             "default": 5, "nullable": False, "min": 1, "max": 15,
             "help": "How many labels to keep from each of the four sets, "
                     "best first. Anything the model is less than 10% "
                     "confident of is dropped whatever this is set to"},
        ], est_realtime_factor=0.15),
        4, "fast",
        {"name": "CC BY-NC-SA 4.0 (MTG/UPF)", "commercial_use": False,
         "requires_hf_token": False,
         "url": "https://essentia.upf.edu/models.html"},
        size_hint_bytes=22_000_000,
        variant_of="tag-essentia-discogs", format_="Jamendo taxonomy",
        notes="Shares the Discogs-EffNet embedding with the card above, and "
              "the embedding cache with it — tagging a track both ways costs "
              "one pass over the audio, not two. Same non-commercial MTG "
              "licence.",
        settings={"heads": ["jamendo_moodtheme", "jamendo_instrument",
                            "jamendo_genre", "jamendo_top50"]}),
    # ---- Music to words: the listeners (MLX) -----------------------------
    #
    # Whisper for the sung words, Qwen2-Audio for everything you would ask a
    # person who had just heard the track. Both run on MLX in a venv of their
    # own — see the family's pyproject for why it is not the `mlxaudio` one.
    task_entry(
        "lyrics-whisper-turbo", "mlxstt",
        ["mlx-community/whisper-large-v3-turbo-q4",
         {"repo_id": "openai/whisper-large-v3-turbo", "gated": False,
          # Tokenizer and feature-extractor only — a few MB of JSON. The
          # mlx-community conversions ship weights and a config and nothing
          # else, and Whisper cannot decode a token without these.
          "allow_patterns": ["preprocessor_config.json", "tokenizer.json",
                             "tokenizer_config.json", "vocab.json",
                             "merges.txt", "normalizer.json",
                             "added_tokens.json", "special_tokens_map.json",
                             "generation_config.json"]}],
        "Lyric transcriber (Whisper turbo)",
        "Writes down the words as sung, with a timing on every line. "
        "Quantised small enough to stay loaded alongside a music model "
        "rather than displacing it — run it on a separated vocal for a "
        "transcript rather than a guess.",
        task_caps(["lyrics"], [
            source_audio_param("The audio to transcribe — a vocals stem "
                               "reads far more cleanly than a full mix"),
            {"key": "language", "type": "string", "label": "Language",
             "default": None, "nullable": True, "placeholder": "auto",
             "help": "Two-letter code (en, fr, ja). Left blank the model "
                     "detects it, which is usually right and occasionally "
                     "confident and wrong"},
            *whisper_params(),
        ], est_realtime_factor=0.08),
        4, "fast", WHISPER_MIT, featured=True,
        settings={"engine": "whisper"},
        notes="Whisper is a speech model: given music with no words in it, "
              "it invents some. Lines it had no confidence in are dropped, "
              "so an instrumental usually comes back empty rather than "
              "wrong — but run it on a vocal and it is a transcript."),
    task_entry(
        "lyrics-whisper-turbo-fp16", "mlxstt",
        ["mlx-community/whisper-large-v3-turbo",
         {"repo_id": "openai/whisper-large-v3-turbo", "gated": False,
          # Tokenizer and feature-extractor only — a few MB of JSON. The
          # mlx-community conversions ship weights and a config and nothing
          # else, and Whisper cannot decode a token without these.
          "allow_patterns": ["preprocessor_config.json", "tokenizer.json",
                             "tokenizer_config.json", "vocab.json",
                             "merges.txt", "normalizer.json",
                             "added_tokens.json", "special_tokens_map.json",
                             "generation_config.json"]}],
        "Lyric transcriber (Whisper turbo, full precision)",
        "The same model unquantised: a little more accurate on quiet or "
        "crowded vocals, and large enough that loading it unloads whatever "
        "music model was resident.",
        task_caps(["lyrics"], [
            source_audio_param("The audio to transcribe — a vocals stem "
                               "reads far more cleanly than a full mix"),
            {"key": "language", "type": "string", "label": "Language",
             "default": None, "nullable": True, "placeholder": "auto",
             "help": "Two-letter code (en, fr, ja); blank to detect"},
            *whisper_params(),
        ], est_realtime_factor=0.12),
        6, "fast", WHISPER_MIT,
        variant_of="lyrics-whisper-turbo", format_="fp16",
        settings={"engine": "whisper"},
        notes="Over the small-model line, so it takes the resident slot."),
    task_entry(
        "caption-qwen2audio", "mlxstt",
        ["mlx-community/Qwen2-Audio-7B-Instruct-4bit"],
        "Qwen2-Audio (listener)",
        "An audio-language model that listens and writes: descriptions of "
        "what it hears, answers to questions you type, and genre/mood/"
        "instrument labels. The most capable listener here, and the "
        "heaviest — it unloads the resident music model to run.",
        task_caps(["caption", "tag"], [
            source_audio_param("The audio to listen to"),
            {"key": "question", "type": "string", "label": "Question",
             "default": None, "nullable": True,
             "placeholder": "What instruments carry the chorus?",
             "help": "Ask something specific about the audio. Left blank it "
                     "writes a general description"},
            {"key": "max_tokens", "type": "int", "label": "Length limit",
             "default": 256, "nullable": False, "min": 32, "max": 1024,
             "help": "How long the answer may run before it is cut off"},
            {"key": "temperature", "type": "float", "label": "Variety",
             "default": 0.7, "nullable": False, "min": 0.0, "max": 1.5,
             "step": 0.05,
             "help": "Lower is literal and repetitive; higher is more "
                     "evocative and less reliable"},
        ], est_realtime_factor=0.5),
        16, "medium", APACHE,
        settings={"engine": "qwen2audio"},
        notes="4-bit MLX conversion of Qwen2-Audio-7B-Instruct."),
    # ---- Music to words: captioning --------------------------------------
    task_entry(
        "caption-lpmusiccaps", "captioning",
        [{"repo_id": "seungheondoh/lp-music-caps", "gated": False,
          # One checkpoint of the three (they are 1.8 GB each) plus its
          # config; the demo audio in the same repo is not wanted.
          "allow_patterns": ["transfer.pth", "transfer.yaml"]},
         {"repo_id": "facebook/bart-base", "gated": False,
          # Config and tokenizer only — the checkpoint above overwrites every
          # weight, so none of BART's own are needed.
          # Exactly the files this repo has — `registry.is_installed`
          # requires every pattern to match something on disk, so naming a
          # file that does not exist upstream makes the model permanently
          # "not installed" *after* a successful download.
          "allow_patterns": ["config.json", "tokenizer.json",
                             "vocab.json", "merges.txt"]}],
        "LP-MusicCaps (describer)",
        "A music captioner: it listens in ten-second windows across the "
        "track and writes what it hears — instruments, mood, genre, feel. "
        "Purpose-built for music rather than adapted from speech.",
        task_caps(["caption"], [
            source_audio_param("The audio to describe"),
            {"key": "num_beams", "type": "int", "label": "Search width",
             "default": 5, "nullable": False, "min": 1, "max": 8,
             "help": "Higher writes steadier, more conventional sentences "
                     "and takes a little longer"},
        ], est_realtime_factor=0.1),
        6, "fast", LPMC_NC, featured=True,
        settings={"engine": "lpmusiccaps", "checkpoint": "transfer"},
        notes="Describes; it cannot answer questions — for that use an "
              "audio-language model. Non-commercial: the project's licence "
              "is CC BY-NC 4.0, despite the Hugging Face card saying MIT."),
    task_entry(
        "lyrics-acestep-transcriber", "qwenomni",
        ["ACE-Step/acestep-transcriber"],
        "ACE-Step transcriber (sung words + structure)",
        "The annotation model behind ACE-Step 1.5's training data: a "
        "Qwen2.5-Omni fine-tune that transcribes SUNG words — 50+ languages "
        "— and marks the song's structure inline ([Verse], [Chorus], "
        "[Spoken Word Intro]). Where Whisper guesses at singing, this was "
        "trained on it.",
        task_caps(["lyrics"], [
            source_audio_param("The audio to transcribe — full mixes are "
                               "fine; this model was trained on them"),
            {"key": "max_tokens", "type": "int", "label": "Length limit",
             "default": 1024, "nullable": False, "min": 32, "max": 4096,
             "help": "How long the transcript may run before it is cut "
                     "off — long songs need headroom"},
        ], est_realtime_factor=1.0),
        24, "medium", ACE_MIT,
        notes="16 GB of weights; loading it unloads the resident music "
              "model. No per-line timings — structure tags ride inline in "
              "the text."),
    task_entry(
        "caption-acestep-captioner", "qwenomni",
        ["ACE-Step/acestep-captioner"],
        "ACE-Step captioner (describer)",
        "The other half of ACE-Step's annotation pair: listens to a track "
        "and writes an unusually precise production-level description — "
        "genre, groove, instrumentation, mix character. Also answers a "
        "typed question about the audio.",
        task_caps(["caption"], [
            source_audio_param("The audio to describe"),
            {"key": "question", "type": "string", "label": "Question",
             "default": None, "nullable": True,
             "placeholder": "What is driving the low end?",
             "help": "Ask something specific about the audio. Left blank it "
                     "writes its full trained description"},
            {"key": "max_tokens", "type": "int", "label": "Length limit",
             "default": 512, "nullable": False, "min": 32, "max": 4096,
             "help": "How long the description may run before it is cut "
                     "off"},
        ], est_realtime_factor=0.8),
        24, "medium", ACE_MIT,
        variant_of="lyrics-acestep-transcriber", format_="captioner",
        notes="16 GB of weights; loading it unloads the resident music "
              "model. The most precise describer tested here — feeds "
              "prompt-from-reference and library annotation."),
    # Experimental captioners, kept out of the catalog until each is proven
    # on this machine. Every one needs vendored inference code rather than a
    # plain transformers class, which is why LP-MusicCaps and Qwen2-Audio
    # ship first; each arrives as another `settings.engine` branch in the
    # captioning family, not as a family of its own.
    #
    #   MusiLingo   (m-a-p/MusiLingo-long-v1 + m-a-p/MERT-v1-330M) — double
    #     vendoring: MERT is itself remote-code, and the adapter joins it to
    #     a Vicuna-7B decoder. The most promising of the five.
    #   MU-LLaMA    (LLaMA-2 + an audio branch) — multi-part research
    #     checkpoint with no single HF snapshot; needs a staged downloader
    #     like `_stage_yourmt3` in the transcription family.
    #   SALMONN     (BEATs + Whisper encoders into Vicuna) — same shape of
    #     problem, three checkpoints to assemble.
    #   Pengi       (microsoft/Pengi) — research code, its own checkpoint
    #     format.
    #   Audio Flamingo 2 (nvidia/audio-flamingo-2) — strong on music, but
    #     NVIDIA's licence is non-commercial AND its redistribution terms
    #     need reading before it is catalogued at all. `commercial_use`
    #     would be False.
    #
    # Deliberately excluded, not merely unbuilt:
    #   LLark (Spotify) — the paper is public, the weights never were.
    #   Gemini / GPT-4o audio — cloud only; this app runs on your machine.
    task_entry(
        "caption-moss-music", "mossmusic",
        ["mlx-community/MOSS-Music-8B-Thinking-8bit"],
        "MOSS-Music 8B (music brain)",
        "The conversational music expert: an 8B audio-language model that "
        "answers real musicology questions — key, tempo, chord movement, "
        "arrangement, production choices — with visible reasoning behind "
        "them. Also transcribes sung lyrics on request. MLX-native: loads "
        "in a second.",
        task_caps(["caption", "lyrics"], [
            source_audio_param("The audio to discuss"),
            {"key": "question", "type": "string", "label": "Question",
             "default": None, "nullable": True,
             "placeholder": "What is the chord progression in the chorus?",
             "help": "Caption task only — the lyrics task always "
                     "transcribes. Ask something specific; left blank it "
                     "writes a full analysis: genre, instrumentation, "
                     "tempo, key, structure"},
            {"key": "max_new_tokens", "type": "int", "label": "Max tokens",
             "default": 6144, "nullable": False, "min": 256, "max": 8192,
             "help": "Token budget for reasoning plus answer. A Thinking "
                     "model spends most of it reasoning — raise this if "
                     "the answer arrives cut off"},
        ], est_realtime_factor=1.5),
        16, "medium", APACHE,
        variant_of="caption-qwen2audio", format_="MOSS 8B · MLX 8-bit",
        notes="A Thinking model — most of its tokens are reasoning, "
              "stripped from the answer. Lyric transcription quality vs "
              "the Whisper/ACE transcribers is unmeasured — the picker "
              "offers all of them. The MLX backend rides a pinned "
              "community fork; the stock PyTorch path is unusable on Macs "
              "(<0.3 tok/s) and is not shipped."),
    task_entry(
        "caption-moss-music-4bit", "mossmusic",
        ["mlx-community/MOSS-Music-8B-Thinking-4bit"],
        "MOSS-Music 8B (4-bit)",
        "The same music brain at 4-bit — roughly half the memory and "
        "disk, a little faster, a little blunter in its judgements.",
        task_caps(["caption", "lyrics"], [
            source_audio_param("The audio to discuss"),
            {"key": "question", "type": "string", "label": "Question",
             "default": None, "nullable": True,
             "placeholder": "What is the chord progression in the chorus?",
             "help": "Caption task only — the lyrics task always "
                     "transcribes. Ask something specific; left blank it "
                     "writes a full analysis: genre, instrumentation, "
                     "tempo, key, structure"},
            {"key": "max_new_tokens", "type": "int", "label": "Max tokens",
             "default": 6144, "nullable": False, "min": 256, "max": 8192,
             "help": "Token budget for reasoning plus answer. A Thinking "
                     "model spends most of it reasoning — raise this if "
                     "the answer arrives cut off"},
        ], est_realtime_factor=1.2),
        10, "medium", APACHE,
        variant_of="caption-moss-music", format_="MOSS 8B · MLX 4-bit",
        notes="Same adapter and prompts as the 8-bit entry; quantisation "
              "quality difference is unmeasured here."),
    task_entry(
        "caption-moss-music-instruct", "mossmusic",
        ["rtikw/MOSS-Music-8B-Instruct-4bit"],
        "MOSS-Music 8B Instruct (4-bit)",
        "The direct-answer edition of the music brain: the same 8B "
        "audio-language model tuned to answer without the visible "
        "reasoning pass — much faster to the first word of its reply, "
        "and its captions read cleaner. The lyric transcriber and "
        "library describer of choice when you don't need to watch it "
        "think.",
        task_caps(["caption", "lyrics"], [
            source_audio_param("The audio to discuss"),
            {"key": "question", "type": "string", "label": "Question",
             "default": None, "nullable": True,
             "placeholder": "What is the chord progression in the chorus?",
             "help": "Caption task only — the lyrics task always "
                     "transcribes. Ask something specific; left blank it "
                     "writes a full analysis: genre, instrumentation, "
                     "tempo, key, structure"},
            {"key": "max_new_tokens", "type": "int", "label": "Max tokens",
             "default": 6144, "nullable": False, "min": 256, "max": 8192,
             "help": "Token budget for the answer (this edition answers "
                     "directly, without a visible reasoning pass)"},
        ], est_realtime_factor=1.0),
        10, "medium", APACHE,
        variant_of="caption-moss-music",
        format_="MOSS 8B Instruct · MLX 4-bit",
        notes="No public MLX quant of the Instruct weights exists, so this "
              "is a first-party 4-bit conversion (moss_music_mlx "
              "converter, group 64, audio encoder kept bf16) of "
              "OpenMOSS-Team/MOSS-Music-8B-Instruct, hosted unmodified on "
              "the user-owned mirror (Apache-2.0). Verified against the "
              "Thinking entries' adapter — same prompts, same output "
              "shape."),
    # ---- Music to words: notation composers ------------------------------
    #
    # ABC notation is text, so these are language models: a description (or a
    # tune) goes in and notation comes out, which the adapter converts to
    # MIDI so the SoundFont renderer can voice it.
    task_entry(
        "compose-text2music", "notation",
        ["sander-wood/text-to-music"],
        "Text to notation (BART)",
        "Writes a tune in ABC notation from a description — BART-base "
        "fine-tuned on 283,000 text-and-score pairs. Small enough to stay "
        "loaded beside a music model; writes one stave, in a wide range of "
        "styles.",
        task_caps(["compose"], [
            {"key": "prompt", "type": "string", "label": "Description or ABC",
             "default": None, "nullable": True,
             "placeholder": "a traditional Irish dance tune in D",
             "help": "What to write. The ABC cards send the notation they "
                     "extracted; typed by hand, a plain description works "
                     "best"},
            {"key": "max_tokens", "type": "int", "label": "Length limit",
             "default": 1024, "nullable": False, "min": 64, "max": 2048,
             "help": "How long the notation may run before it is cut off"},
            {"key": "temperature", "type": "float", "label": "Variety",
             "default": 0.7, "nullable": False, "min": 0.0, "max": 1.5,
             "step": 0.05,
             "help": "Lower writes conventional, predictable tunes; higher "
                     "takes more chances and parses less often"},
            seed_param(),
        ], est_realtime_factor=0.1),
        4, "fast", MIT, featured=True,
        settings={"engine": "text2music"},
        notes="One stave, classical notation. Its own authors note it is "
              "input-sensitive and not built for high creativity."),
    task_entry(
        "compose-chatmusician", "notation",
        [{"repo_id": "m-a-p/ChatMusician", "gated": False,
          # The repo ships the same weights twice (safetensors and the older
          # .bin shards); fetching both would double a 13 GB download.
          # Every pattern must match a real file upstream — see the guard in
          # `effective_size`. This repo has no .txt at all.
          "allow_patterns": ["*.safetensors", "*.json", "*.model"]}],
        "ChatMusician (notation)",
        "A LLaMA-2 tuned on music theory and ABC notation: give it a tune "
        "and it writes a new piece in the same key and metre, rather than "
        "only composing from a description.",
        task_caps(["compose"], [
            {"key": "prompt", "type": "string", "label": "Description or ABC",
             "default": None, "nullable": True,
             "placeholder": "X:1\nT:My tune\nM:4/4\nK:D\n…",
             "help": "Paste ABC notation to continue in its style, describe "
                     "the piece you want, or ask a question about music"},
            # This checkpoint is a music-THEORY model as well as a notation
            # one, and both of the adapter's prompt templates ended with
            # "reply with ABC notation only" — so the half of it that answers
            # questions was suppressed and then discarded by the ABC cleaner.
            # `auto` keeps the old guess-from-the-prompt behaviour.
            {"key": "mode", "type": "enum", "label": "What to do",
             "default": "auto", "nullable": False,
             "choices": [
                 {"value": "auto", "label": "Work it out from what I typed"},
                 {"value": "compose", "label": "Write a tune from a "
                                               "description"},
                 {"value": "continue", "label": "Write another like this one"},
                 {"value": "ask", "label": "Answer a question about music"}],
             "help": "Left on automatic, notation you paste is continued and "
                     "anything else is read as a description. Ask-a-question "
                     "is the model's other half: music theory, harmony, form, "
                     "and analysis of a tune you paste under the question. It "
                     "answers in words and returns no notes."},
            {"key": "max_tokens", "type": "int", "label": "Length limit",
             "default": 1024, "nullable": False, "min": 64, "max": 2048,
             "help": "How long the reply may run before it is cut off"},
            {"key": "temperature", "type": "float", "label": "Variety",
             "default": 0.7, "nullable": False, "min": 0.0, "max": 1.5,
             "step": 0.05,
             "help": "Lower is conventional; higher is more adventurous and "
                     "parses less often"},
            seed_param(),
        ], est_realtime_factor=1.2),
        24, "slow", MIT,
        variant_of="compose-text2music", format_="7B",
        settings={"engine": "chatmusician"},
        notes="13 GB of weights; loading it unloads the resident music "
              "model."),
    task_entry(
        "compose-anticipation", "anticipation",
        ["stanford-crfm/music-small-800k"],
        "Anticipatory Music Transformer",
        "Stanford's symbolic composer: writes MIDI note events directly "
        "(no audio model in the loop), which the note renderer then "
        "voices. Its actual specialty is working WITH existing notes: "
        "continue a part from where it stops, or fill a gap in the middle "
        "while respecting what comes after.",
        task_caps(["compose"], [
            {"key": "compose_mode", "type": "enum", "label": "Mode",
             "default": "generate", "nullable": False,
             "choices": [{"value": "generate", "label": "From nothing"},
                         {"value": "continue", "label": "Continue the notes"},
                         {"value": "infill", "label": "Fill a gap"},
                         {"value": "accompany", "label": "Play along with it"}],
             "help": "Continue picks up where the MIDI part stops; "
                     "fill-a-gap rewrites only the window below, keeping "
                     "the notes on both sides; play-along writes a second "
                     "part underneath the whole melody, hearing it as it "
                     "goes. All three need a MIDI file; the result always "
                     "includes the input notes"},
            {"key": "melody_midi", "type": "midi", "label": "Notes to extend",
             "default": None, "nullable": True,
             "help": "The MIDI part to continue, fill or play along with — a "
                     "transcription or an earlier composition both work"},
            {"key": "gap_start_s", "type": "float", "label": "Gap start (s)",
             "default": None, "nullable": True, "min": 0.0, "max": 600.0,
             "step": 0.5,
             "help": "Fill-a-gap only: where the rewritten window begins"},
            {"key": "gap_end_s", "type": "float", "label": "Gap end (s)",
             "default": None, "nullable": True, "min": 0.0, "max": 600.0,
             "step": 0.5,
             "help": "Fill-a-gap only: where the window ends — the notes "
                     "after it are kept and respected"},
            {"key": "span_s", "type": "float", "label": "Length (s)",
             "default": 15.0, "nullable": False, "min": 5.0, "max": 60.0,
             "step": 5.0,
             "help": "How many seconds of music to compose (from-nothing "
                     "and continue). Play-along takes its length from the "
                     "melody instead. Time is musical output length, not "
                     "render time"},
            {"key": "top_p", "type": "float", "label": "Top-P",
             "default": 0.98, "nullable": False, "min": 0.8, "max": 1.0,
             "step": 0.01},
            seed_param(),
        ], est_realtime_factor=15.0),
        8, "slow", APACHE,
        variant_of="compose-text2music", format_="MIDI events · AMT",
        notes="Ignores the prompt — generation is unconditional over MIDI "
              "events. Token-by-token and slow on CPU (~23 min for 10 s in "
              "triage); the adapter tries MPS first, which should recover "
              "~10×."),
    task_entry(
        "compose-anticipation-medium", "anticipation",
        ["stanford-crfm/music-medium-800k"],
        "Anticipatory Music Transformer (medium)",
        "The 360M checkpoint — the documented quality sweet spot of the "
        "AMT line. Same modes: compose, continue a part, fill a gap.",
        task_caps(["compose"], [
            {"key": "compose_mode", "type": "enum", "label": "Mode",
             "default": "generate", "nullable": False,
             "choices": [{"value": "generate", "label": "From nothing"},
                         {"value": "continue", "label": "Continue the notes"},
                         {"value": "infill", "label": "Fill a gap"},
                         {"value": "accompany", "label": "Play along with it"}],
             "help": "Continue picks up where the MIDI part stops; "
                     "fill-a-gap rewrites only the window below, keeping "
                     "the notes on both sides; play-along writes a second "
                     "part underneath the whole melody, hearing it as it "
                     "goes. All three need a MIDI file; the result always "
                     "includes the input notes"},
            {"key": "melody_midi", "type": "midi", "label": "Notes to extend",
             "default": None, "nullable": True,
             "help": "The MIDI part to continue, fill or play along with — a "
                     "transcription or an earlier composition both work"},
            {"key": "gap_start_s", "type": "float", "label": "Gap start (s)",
             "default": None, "nullable": True, "min": 0.0, "max": 600.0,
             "step": 0.5,
             "help": "Fill-a-gap only: where the rewritten window begins"},
            {"key": "gap_end_s", "type": "float", "label": "Gap end (s)",
             "default": None, "nullable": True, "min": 0.0, "max": 600.0,
             "step": 0.5,
             "help": "Fill-a-gap only: where the window ends — the notes "
                     "after it are kept and respected"},
            {"key": "span_s", "type": "float", "label": "Length (s)",
             "default": 15.0, "nullable": False, "min": 5.0, "max": 60.0,
             "step": 5.0,
             "help": "How many seconds of music to compose (from-nothing "
                     "and continue). Play-along takes its length from the "
                     "melody instead. Time is musical output length, not "
                     "render time"},
            {"key": "top_p", "type": "float", "label": "Top-P",
             "default": 0.98, "nullable": False, "min": 0.8, "max": 1.0,
             "step": 0.01},
            seed_param(),
        ], est_realtime_factor=40.0),
        12, "slow", APACHE,
        variant_of="compose-anticipation", format_="MIDI events · medium",
        notes="Roughly 3× the small model's cost per note — unmeasured "
              "here; the est is scaled from the small model's triage "
              "numbers. Same adapter, same modes."),
    # Experimental notation models, kept out of the catalog until their
    # decoding is proven here — both need vendored inference code rather
    # than a plain transformers class, which is the whole reason the two
    # above ship first:
    #   NotaGen (ElectricAlexis/NotaGen, MIT) — bespoke patch-level +
    #     character-level transformer stack, checkpoint-only repo (.pth, no
    #     config.json), so the architecture has to be vendored to load it.
    #   TunesFormer (sander-wood/tunesformer, MIT) — GPT-2 config, but the
    #     bar-patching input pipeline is not what AutoModel builds.
    # ---- Split & Recombine: token splice (experimental) ------------------
    task_entry(
        "codec-tokensplice", "mlxaudio",
        ["mlx-community/encodec-24khz-float32"],
        "Token Splice (experimental)",
        "Glitch-art playground: encodes two songs into EnCodec tokens, "
        "splices song A's coarse codebooks with song B's fine ones, and "
        "decodes the hybrid. Deliberately weird — expect artifacts.",
        task_caps(["mix"], [
            {"key": "splice_spec", "type": "json", "label": "Splice spec",
             "default": None, "nullable": False,
             "internal": True, "resolve_uploads": True},
        ], est_realtime_factor=0.2),
        4, "fast", MIT, format_="mono 24 kHz", featured=True,
        settings={"engine": "tokensplice"},
        notes="Experimental by design; output is mono 24 kHz."),
    # ---- The writing assistant -------------------------------------------
    #
    # Both entries are small on purpose rather than by accident. The job queue
    # treats a task-only model under 1.5 GB as a *small* model: it loads into
    # the warm pool beside whatever music model is resident instead of evicting
    # it. An assistant that unloaded a 10 GB ACE-Step every time you asked it
    # for a title would be used exactly once, so anything larger than the
    # threshold would be a worse product even if it wrote better prompts.
    *assistant_entries(),
    # ---- Split & Recombine: literal mixdown ------------------------------
    task_entry(
        "dsp-mixdown", "dsp", [],
        "Mixdown & Align (DSP)",
        "Literal recombination: beat-aligned time-stretch and pitch-shift "
        "(Rubber Band R3), loudness normalization (LUFS) and true-peak "
        "limiting. No AI model — deterministic and fast.",
        task_caps(["mix"], [
            {"key": "mix_spec", "type": "json", "label": "Mix spec",
             "default": None, "nullable": False,
             "internal": True, "resolve_uploads": True},
            {"key": "target_lufs", "type": "float", "label": "Loudness",
             "default": -14.0, "nullable": False,
             "min": -30.0, "max": -6.0, "step": 0.5,
             "help": "Integrated loudness of the final mix"},
            {"key": "keep_tracks", "type": "bool", "label": "Keep tracks",
             "default": False, "nullable": False,
             "help": "Also save each aligned track as a part of the result"},
            # These four were live in models.json and read by adapter_dsp, but
            # had never been written back here — so regenerating the catalog
            # would have silently deleted them, and the mixdown would have
            # fallen back to its internal defaults with no way to say
            # otherwise. Copied from the shipped catalog verbatim: the export
            # formats in particular are load-bearing, and a paraphrase of this
            # block dropped AIFF and MP3 without anything failing.
            {"key": "normalize", "type": "bool", "label": "Normalize loudness",
             "default": True, "nullable": False,
             "help": "Off renders at the summed level of the tracks "
                     "themselves — an edit that only cuts must not change how "
                     "loud the audio is."},
            {"key": "limiter", "type": "bool", "label": "True-peak limiter",
             "default": True, "nullable": False,
             "help": "−1 dBTP limiter after normalization."},
            {"key": "output_format", "type": "enum", "label": "Output format",
             "default": "wav", "nullable": False,
             "choices": [{"value": "wav", "label": "WAV"},
                         {"value": "aiff", "label": "AIFF"},
                         {"value": "flac", "label": "FLAC"},
                         {"value": "mp3", "label": "MP3"}],
             "help": "Container of the rendered mixdown. Stems stay 16-bit "
                     "WAV."},
            {"key": "bit_depth", "type": "enum", "label": "Bit depth",
             "default": "pcm16", "nullable": False,
             "choices": [{"value": "pcm16", "label": "16-bit"},
                         {"value": "pcm24", "label": "24-bit"},
                         {"value": "float32", "label": "32-bit float"}],
             "help": "Sample format of the mixdown. 32-bit float is not valid "
                     "for FLAC; ignored for MP3."},
        ], est_realtime_factor=0.3),
        2, "fast",
        {"name": "GPL-3.0", "commercial_use": True,
         "requires_hf_token": False,
         "url": "https://github.com/spotify/pedalboard"},
        featured=True,
        notes="Uses Spotify pedalboard (bundled Rubber Band Library) under "
              "GPL-3.0; the engine's Python source ships in the app."),
    # ---- Split & Recombine: notes (transcription + rendering) -------------
    task_entry(
        "transcribe-basicpitch", "transcription", [],
        "Basic Pitch (Spotify)",
        "General-purpose note transcription with pitch bends — best on a "
        "single separated stem (vocals, bass, guitar, piano). Tiny model "
        "ships with the app; runs via CoreML.",
        task_caps(["transcribe"], [
            source_audio_param("The audio to transcribe — a separated stem "
                               "works much better than a full mix"),
            {"key": "instrument_label", "type": "string",
             "label": "Instrument name", "default": None, "nullable": True,
             "placeholder": "guitar",
             "help": "Names the resulting notes part"},
            # The model's two decision thresholds, at its own defaults. They
            # fail in opposite directions, which is why both are offered
            # rather than one "sensitivity" dial standing in for both.
            {"key": "onset_threshold", "type": "float",
             "label": "Note sensitivity", "default": 0.5, "nullable": False,
             "min": 0.05, "max": 0.95, "step": 0.05,
             "help": "How sure the model must be that a note STARTED. Lower "
                     "it to catch quiet or legato playing it is missing; "
                     "raise it when the transcript is full of notes nobody "
                     "played."},
            {"key": "frame_threshold", "type": "float",
             "label": "Note sustain", "default": 0.3, "nullable": False,
             "min": 0.05, "max": 0.95, "step": 0.05,
             "help": "How sure it must be that a note is still SOUNDING. "
                     "Lower gives longer, more joined-up notes and can smear "
                     "fast passages; higher gives shorter, cleaner ones and "
                     "can chop a held note into several."},
            {"key": "emit_abc", "type": "bool", "label": "Also write ABC",
             "default": False, "nullable": False,
             "help": "Also write each note track as ABC notation text — a "
                     "readable sketch, and the input the notation composers "
                     "take"},
], est_realtime_factor=0.15),
        4, "fast", APACHE, featured=True,
        notes="Model weights are bundled in the Python package "
              "(Apache-2.0); the ~40 MB preview SoundFont (MuseScore "
              "General, MIT) fetches on first run.",
        settings={"engine": "basicpitch"}),
    task_entry(
        "transcribe-mt3", "transcription",
        [{"repo_id": "gudgud1014/MR-MT3", "gated": False,
          "allow_patterns": ["mt3.pth"]}],
        "MT3 multi-instrument (MR-MT3)",
        "Transcribes a full mix into separate instrument-labeled note "
        "tracks, drums included.",
        task_caps(["transcribe"], [
            source_audio_param("The song to transcribe into per-instrument "
                               "note tracks"),
                    {"key": "emit_abc", "type": "bool", "label": "Also write ABC",
             "default": False, "nullable": False,
             "help": "Also write each note track as ABC notation text — a "
                     "readable sketch, and the input the notation composers "
                     "take"},
], est_realtime_factor=0.8),
        8, "medium", MIT,
        settings={"engine": "mt3", "backend": "mr_mt3"}),
    # transcribe-yourmt3 GATED OUT (2026-08-17): mt3-infer 0.2.0's vendored
    # YourMT3 fails at inference on this stack ("'NoneType' object is not
    # subscriptable", both MPS and CPU) even with transformers<4.50 pinned
    # and the checkpoint HTTPS-staged (adapter support for backend "yourmt3"
    # is wired and kept). Re-add the entry when upstream fixes inference:
    #   task_entry("transcribe-yourmt3", "transcription", [], ...,
    #              variant_of="transcribe-mt3",
    #              settings={"engine": "mt3", "backend": "yourmt3"})
    task_entry(
        "transcribe-transkun", "transcription", [],
        "Transkun (piano)",
        "State-of-the-art expressive piano transcription: onsets, offsets, "
        "velocities and pedal. Weights ship with the Python package.",
        task_caps(["transcribe"], [
            source_audio_param("Piano audio — solo recordings or a "
                               "separated piano stem"),
                    {"key": "emit_abc", "type": "bool", "label": "Also write ABC",
             "default": False, "nullable": False,
             "help": "Also write each note track as ABC notation text — a "
                     "readable sketch, and the input the notation composers "
                     "take"},
], est_realtime_factor=1.0),
        4, "medium", MIT, featured=True,
        settings={"engine": "transkun"}),
    task_entry(
        "transcribe-bytedance-piano", "transcription",
        ["rtikw/piano-transcription-crnn"],
        "ByteDance piano (with pedal)",
        "The pedal specialist: piano notes AND sustain-pedal events in the "
        "MIDI, which no other transcriber here writes. Judge it on real "
        "piano recordings — synthetic tones over-transcribe.",
        task_caps(["transcribe"], [
            source_audio_param("Piano audio — solo recordings or a "
                               "separated piano stem"),
            {"key": "emit_abc", "type": "bool", "label": "Also write ABC",
             "default": False, "nullable": False,
             "help": "Also write each note track as ABC notation text — a "
                     "readable sketch, and the input the notation composers "
                     "take"},
        ], est_realtime_factor=0.5),
        4, "fast",
        {"name": "CC BY 4.0", "commercial_use": True,
         "requires_hf_token": False,
         "url": "https://zenodo.org/record/4034264"},
        variant_of="transcribe-transkun", format_="CRNN · pedal-aware",
        notes="The checkpoint is an unmodified mirror of the paper's "
              "Zenodo record (CC BY 4.0, credit Kong et al.).",
        settings={"engine": "bytedance_piano"}),
    task_entry(
        "transcribe-swiftf0", "transcription", [],
        "SwiftF0 (vocal melody)",
        "Instant monophonic melody extraction — run it on a vocals stem to "
        "get the tune as notes. Tiny model ships with the package.",
        task_caps(["transcribe"], [
            source_audio_param("Monophonic audio — a vocals stem or a "
                               "single-instrument line"),
            # 0.9 was hardcoded in the adapter. Strict is right for a full
            # mix and wrong for a quiet line, and there was no way to say so.
            {"key": "confidence", "type": "float",
             "label": "Pitch confidence", "default": 0.9, "nullable": False,
             "min": 0.1, "max": 0.99, "step": 0.05,
             "help": "How certain the tracker must be before it calls "
                     "something a pitch. High ignores breath, room and "
                     "bleed — and quiet singing with them; lower it when a "
                     "soft or breathy line is coming back empty."},
            {"key": "min_note_s", "type": "float",
             "label": "Shortest note (s)", "default": 0.05, "nullable": False,
             "min": 0.02, "max": 0.5, "step": 0.01,
             "help": "Anything shorter than this is not a note. Raise it to "
                     "drop the flickers a slide or a vibrato leaves behind; "
                     "lower it for fast, deliberately short phrasing."},
            {"key": "emit_abc", "type": "bool", "label": "Also write ABC",
             "default": False, "nullable": False,
             "help": "Also write each note track as ABC notation text — a "
                     "readable sketch, and the input the notation composers "
                     "take"},
], est_realtime_factor=0.02),
        2, "fast", MIT, featured=True,
        settings={"engine": "swiftf0"}),
    task_entry(
        "render-soundfont", "notesynth", [],
        "Note renderer (SoundFont)",
        "Turns any notes part back into audio with General MIDI "
        "instruments (MuseScore General, MIT). The ~40 MB SoundFont "
        "fetches on first run.",
        task_caps(["render"], [
            {"key": "midi_file", "type": "midi", "label": "Notes",
             "default": None, "nullable": False,
             "help": "The MIDI part to render"},
            # Every transcriber in the app writes its notes as program 0, so
            # until now everything played back as a piano whatever it had
            # been. Left blank the file plays as written, which is what a
            # multi-instrument MT3 transcription wants.
            {"key": "instrument", "type": "enum", "label": "Instrument",
             "default": None, "nullable": True,
             "choices": [
                 {"value": "grand_piano", "label": "Grand piano"},
                 {"value": "electric_piano", "label": "Electric piano"},
                 {"value": "harpsichord", "label": "Harpsichord"},
                 {"value": "music_box", "label": "Music box"},
                 {"value": "vibraphone", "label": "Vibraphone"},
                 {"value": "marimba", "label": "Marimba"},
                 {"value": "drawbar_organ", "label": "Organ (drawbar)"},
                 {"value": "church_organ", "label": "Organ (church)"},
                 {"value": "accordion", "label": "Accordion"},
                 {"value": "nylon_guitar", "label": "Nylon guitar"},
                 {"value": "steel_guitar", "label": "Steel guitar"},
                 {"value": "jazz_guitar", "label": "Jazz guitar"},
                 {"value": "clean_electric_guitar",
                  "label": "Electric guitar (clean)"},
                 {"value": "overdriven_guitar",
                  "label": "Electric guitar (overdriven)"},
                 {"value": "acoustic_bass", "label": "Upright bass"},
                 {"value": "electric_bass", "label": "Electric bass"},
                 {"value": "synth_bass", "label": "Synth bass"},
                 {"value": "violin", "label": "Violin"},
                 {"value": "cello", "label": "Cello"},
                 {"value": "string_ensemble", "label": "String section"},
                 {"value": "choir", "label": "Choir"},
                 {"value": "trumpet", "label": "Trumpet"},
                 {"value": "trombone", "label": "Trombone"},
                 {"value": "alto_sax", "label": "Saxophone"},
                 {"value": "flute", "label": "Flute"},
                 {"value": "square_lead", "label": "Synth lead (square)"},
                 {"value": "saw_lead", "label": "Synth lead (saw)"},
                 {"value": "warm_pad", "label": "Synth pad"},
                 {"value": "sitar", "label": "Sitar"},
                 {"value": "steel_drums", "label": "Steel drums"}],
             "help": "Play every part with this instrument instead of "
                     "whatever the file asks for. Left blank the file plays "
                     "as written — which for anything the app transcribed "
                     "means a piano. Drum tracks are never substituted."},
            {"key": "gain_db", "type": "float", "label": "Gain",
             "default": 0.0, "nullable": False, "min": -12.0, "max": 12.0,
             "step": 0.5},
            {"key": "sample_rate", "type": "enum", "label": "Sample rate",
             "default": "44100", "nullable": False,
             "choices": [{"value": "44100", "label": "44.1 kHz"},
                         {"value": "48000", "label": "48 kHz"}]},
        ], est_realtime_factor=0.05),
        2, "fast", MIT, size_hint_bytes=40_000_000, featured=True,
        settings={}),
]


def main() -> None:
    tok = token()
    with open(CATALOG) as f:
        catalog = json.load(f)
    # NEW_ENTRIES is the generated half of the catalog; everything else in the
    # file is hand-written and survives regeneration untouched. Keying that on
    # id rather than on `featured` matters in both directions: a hand-written
    # entry that is *not* featured must not be dropped (demoting YuE would
    # delete it), and a generated entry that *is* featured must not be emitted
    # twice (the auxiliary models). Generated entries win on collision.
    generated = {e["id"] for e in NEW_ENTRIES}
    kept = [m for m in catalog["models"] if m["id"] not in generated]

    # hand-written entries pick up format/variant grouping tweaks
    #
    # …and any controls added to the generated half that they should share.
    # The six hand-written entries survive regeneration untouched by design,
    # which also means a param added to a shared `*_caps` helper never reaches
    # them. Grafting is keyed by param key throughout, so re-running is a
    # no-op rather than a duplication.
    def graft(model: dict, *params: dict) -> None:
        have = {p["key"] for p in model["capabilities"]["params"]}
        model["capabilities"]["params"] += [
            copy.deepcopy(p) for p in params if p["key"] not in have]

    for m in kept:
        if m["id"] == "musicgen-small" or m["id"] == "musicgen-medium":
            m["format"] = "mono"
            # Trained continuation, same as the generated MusicGen entries.
            # Both are plain (non-melody) transformers checkpoints, which is
            # exactly where the audio slot means "continue this".
            graft(m, continue_param())
        if m["id"] == "stableaudio-small":
            # Inert at this entry's default guidance of 1.0 — the DiT skips
            # the guided branch entirely there — and live the moment guidance
            # is raised, which is the whole reason it is worth having.
            graft(m, {"key": "negative_prompt", "type": "string",
                      "label": "Negative prompt", "default": None,
                      "nullable": True,
                      "placeholder": "low quality, distorted",
                      "help": "What to steer away from. This model defaults "
                              "to guidance 1.0, where the model ignores both "
                              "prompts equally — raise CFG scale above 1 for "
                              "this to do anything."})
        if m["id"] == "yue":
            # In-context learning: YuE's own style-reference route, the same
            # shape as SongBloom's style_audio.
            graft(m,
                  {"key": "style_audio", "type": "audio",
                   "label": "Sound like this", "default": None,
                   "nullable": True,
                   "help": "A recording whose style the song should take on. "
                           "The model listens to the window below before it "
                           "writes, so the take comes out in that idiom — "
                           "voice, production and all. Use music you have "
                           "the right to learn from."},
                  {"key": "prompt_start_s", "type": "float",
                   "label": "Reference from (s)", "default": 0.0,
                   "nullable": False, "min": 0.0, "max": 600.0, "step": 1.0,
                   "help": "Where in the reference to start listening. Pick a "
                           "passage that represents the whole track — a "
                           "chorus rather than an intro."},
                  {"key": "prompt_end_s", "type": "float",
                   "label": "Reference to (s)", "default": 30.0,
                   "nullable": False, "min": 1.0, "max": 600.0, "step": 1.0,
                   "help": "Where to stop listening. Thirty seconds is "
                           "upstream's own figure; much more is mostly "
                           "slower, not better."})
        if m["id"] == "acestep-base":
            m["format"] = "turbo · 8 steps"
            # acestep-base is hand-written rather than generated, so the plan
            # surface every other ACE-Step variant gets from `ace_variant` has
            # to be grafted on here. Keyed by param key so re-running is a
            # no-op rather than a duplication.
            graft(m, *(ace_plan_params() + ace_plan_task_params()))
            m["capabilities"]["tasks"] = ["generate", "plan"]

    # Order is load-bearing: several features resolve "the first installed
    # model that can do X" against /v1/models order, which is this order.
    models = kept + [copy.deepcopy(e) for e in NEW_ENTRIES]
    for m in models:
        # A configured Hub repository is the preferred source, even where the
        # original publisher also hosts the same weights elsewhere.
        if m["hf_repos"]:
            m["homepage"] = "https://huggingface.co/" + m["hf_repos"][0]["repo_id"]
        else:
            m["homepage"] = SOURCE_HOMEPAGES.get(m["id"])
        if not m["homepage"]:
            raise ValueError(f"{m['id']}: no source homepage")
        m["tags"] = derive_tags(m)
        apply_pipeline(m)
        apply_preview(m)
        # Before apply_groups, which rebuilds `group` by popping and re-adding
        # it: filling `help` afterwards would land the two keys in a different
        # order on a first run than on every run after, so the file would not
        # settle until it had been regenerated twice.
        apply_help(m)
        normalise_help(m)
        apply_groups(m)
    # What the shipped catalog already knows, so a failed lookup falls back to
    # the last good answer rather than to the generator's placeholder.
    #
    # `if total > 0` below looks like it protects this, and it does not: a
    # generated entry's preset size is 0, so one timed-out HF request rewrote a
    # real 184 MB as 0 with nothing failing. Sizes drive the download UI and the
    # small-model threshold, and "unknown" is not a size worth writing down.
    previous = {m["id"]: m.get("size_bytes") or 0
                for m in catalog["models"]}
    for m in models:
        if not m.get("size_bytes") and previous.get(m["id"]):
            m["size_bytes"] = previous[m["id"]]
            m["requirements"]["disk_bytes"] = previous[m["id"]]

    cache: dict[tuple, int] = {}
    for m in models:
        total = 0
        for repo in m["hf_repos"]:
            rid = repo["repo_id"]
            pats = repo.get("allow_patterns")
            key = (rid, tuple(pats) if pats else None)
            if key not in cache:
                try:
                    cache[key] = effective_size(rid, tok, pats)
                except Exception as e:  # noqa: BLE001 — mirror repos may not exist yet
                    print(f"  {rid}: size unavailable ({e}); keeping preset")
                    cache[key] = 0
                else:
                    print(f"  {rid}: {cache[key] / 1e9:.2f} GB"
                          + (f" ({len(pats)} files)" if pats else ""))
            total += cache[key]
        for repo in m.get("ms_repos") or []:
            pats = repo.get("allow_patterns")
            key = ("ms", repo["repo_id"], tuple(pats) if pats else None)
            if key not in cache:
                try:
                    cache[key] = ms_effective_size(repo["repo_id"], pats)
                except Exception as e:  # noqa: BLE001 — same best-effort as HF
                    print(f"  ms:{repo['repo_id']}: size unavailable ({e}); "
                          f"keeping preset")
                    cache[key] = 0
                else:
                    print(f"  ms:{repo['repo_id']}: {cache[key] / 1e9:.2f} GB")
            total += cache[key]
        if total > 0:
            m["size_bytes"] = total
            m["requirements"]["disk_bytes"] = total

    with open(CATALOG, "w") as f:
        json.dump({"models": models}, f, indent=2, ensure_ascii=False)
    n_featured = sum(1 for m in models if m.get("featured"))
    print(f"wrote {len(models)} models ({n_featured} featured, "
          f"{len(kept)} hand-written)")


if __name__ == "__main__":
    main()
