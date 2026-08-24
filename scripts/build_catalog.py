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


def token() -> str | None:
    path = os.path.expanduser("~/.cache/huggingface/token")
    if os.environ.get("HF_TOKEN"):
        return os.environ["HF_TOKEN"]
    if os.path.exists(path):
        return open(path).read().strip()
    return None


def effective_size(repo_id: str, tok: str | None,
                   patterns: list[str] | None = None) -> int:
    req = urllib.request.Request(
        f"https://huggingface.co/api/models/{repo_id}?blobs=true")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    siblings = data.get("siblings", [])
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


# User-owned HF mirror for checkpoints without stable HF hosting (viperx
# BS-RoFormer from deleted-prone GitHub releases, beat_this final0 from CPJKU
# Nextcloud, SoundFonts). TODO(assets-mirror): create + populate, then move
# the weightless separation/analysis entries onto it for real install-state.
ASSETS_REPO = "rtikw/localmusic-assets"


def seed_param():
    return {"key": "seed", "type": "int", "label": "Seed", "default": None,
            "nullable": True, "min": 0, "max": 4294967295}


def source_audio_param(help_=None):
    return {"key": "source_audio", "type": "audio", "label": "Source audio",
            "default": None, "nullable": False,
            "help": help_ or "The song to process"}


def init_audio_params():
    """Audio-to-audio for diffusion models: start from a noised reference
    clip instead of pure noise (the "Reimagine a Loop" recipe)."""
    return [
        {"key": "init_audio", "type": "audio", "label": "Reimagine source",
         "default": None, "nullable": True,
         "help": "Audio to reimagine — diffusion starts from this clip "
                 "instead of noise"},
        {"key": "init_noise_level", "type": "float", "label": "Reimagine amount",
         "default": 1.0, "nullable": False, "min": 0.1, "max": 10.0,
         "step": 0.1,
         "help": "How far to depart from the source (higher = freer)"},
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

# params that mean "this model can take existing audio and rework it".
# `melody_audio` and `style_audio` belong here for the same reason the rest do:
# both take a file the user already has and produce a new performance of it.
# They also carry their own, narrower tag — the Style Transfer screen filters on
# this set, and a melody model missing from it was simply unreachable there.
_REMIX_PARAMS = {"src_audio", "init_audio", "reference_audio", "extend_audio",
                 "inpaint_audio", "task_type", "melody_audio", "style_audio"}


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
    "minimax": _stages("lm_decode", "diffusion", "vocoder", "master"),
    "mlxaudio": _stages("lm_decode", "diffusion", "master"),
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
    "plan_caption": SAMPLING,
    "plan_lyrics": SAMPLING,
    "plan_count": SAMPLING,
    "plan_duration_s": SAMPLING,
    "bpm": MUSICAL,
    # The other two facts the LM otherwise guesses at. Pinning one takes it out
    # of the model's hands, which is the whole point of the control.
    "keyscale": MUSICAL,
    "timesignature": MUSICAL,
    "vocal_language": MUSICAL,
    "task_type": TASK,
    "src_audio": TASK,
    "reference_audio": TASK,
    "melody_audio": TASK,
    "init_audio": TASK,
    "init_noise_level": TASK,
    "extend_audio": TASK,
    "inpaint_audio": TASK,
    "inpaint_start_s": TASK,
    "inpaint_end_s": TASK,
    "audio_cover_strength": TASK,
    "style_audio": TASK,
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
    # ---- task models ------------------------------------------------------
    "shifts": "How many times the separator re-runs over a time-shifted copy "
              "of the input, averaging the results to cancel "
              "position-dependent artifacts. Slightly cleaner stems, and "
              "linearly slower.",
    "target_lufs": "How loud the result is normalised to, in LUFS — perceived "
                   "loudness averaged across the whole track, not peak level. "
                   "Streaming services land around -14.",
    "gain_db": "Volume applied to the rendered audio, in decibels. 0 leaves it "
               "exactly as the SoundFont produced it; every 6 dB is roughly a "
               "doubling.",
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
    "src_audio": ("cover", "repaint", "extract", "lego", "complete"),
    "repainting_start": ("repaint", "lego"),
    "repainting_end": ("repaint", "lego"),
    "track": ("extract", "lego", "complete"),
    "flow_edit_morph": ("text2music", "cover"),
    "flow_edit_source_caption": ("text2music", "cover"),
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


def musicgen_caps(max_s=30, est=4.0, melody=False, style=False):
    params = [
        {"key": "guidance_scale", "type": "float", "label": "Guidance",
         "default": 3.0, "nullable": False, "min": 1.0, "max": 15.0, "step": 0.5},
        {"key": "temperature", "type": "float", "label": "Temperature",
         "default": 1.0, "nullable": False, "min": 0.1, "max": 2.0, "step": 0.1},
        {"key": "top_k", "type": "int", "label": "Top-K", "default": 250,
         "nullable": False, "min": 10, "max": 1000},
        seed_param(),
    ]
    if melody:
        params.insert(0, melody_param())
    if style:
        for offset, param in enumerate(style_params()):
            params.insert(offset, param)
    return {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": max_s, "default_s": 10},
        "sample_rate": 32000, "outputs_per_job_max": 4,
        "est_seconds_per_audio_second": est,
        "params": params,
    }


def diffusers_caps(max_s, default_s, steps_default, guidance_default, est=3.0):
    return {
        "supports_lyrics": False, "instrumental_only": True,
        "duration": {"min_s": 1, "max_s": max_s, "default_s": default_s},
        "sample_rate": 16000, "outputs_per_job_max": 4,
        "est_seconds_per_audio_second": est,
        "params": [
            {"key": "steps", "type": "int", "label": "Steps",
             "default": steps_default, "nullable": False, "min": 5, "max": 300},
            {"key": "guidance_scale", "type": "float", "label": "Guidance",
             "default": guidance_default, "nullable": False, "min": 1.0,
             "max": 15.0, "step": 0.5},
            {"key": "negative_prompt", "type": "string", "label": "Negative prompt",
             "default": "low quality, average quality", "nullable": False,
             "placeholder": "low quality"},
            seed_param(),
        ],
    }


def entry(id_, family, repos, name, desc, caps, min_ram_gib, tier, license_,
          notes=None, variant_of=None, format_=None, gated=False,
          settings=None, featured=False):
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


def ace_task_params(full):
    """SR3 task-mode params. full=True (base/sft DiTs) adds extract/lego/
    complete + the track class; turbo DiTs support text2music/cover/repaint
    only (enforced again in the adapter)."""
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
         "help": "What to do with the source audio (if any)"},
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
        {"key": "flow_edit_morph", "type": "bool", "label": "Morph",
         "default": False, "nullable": False,
         "help": "Rewrite the source from one description into another "
                 "(FlowEdit). Needs a source audio file; works on the Turbo "
                 "DiT, unlike extract/layer/complete"},
        {"key": "flow_edit_source_caption", "type": "string",
         "label": "Source description", "default": None, "nullable": True,
         "placeholder": "e.g. upbeat electropop with a female vocal",
         "help": "What the source is now — a morph travels from this "
                 "description to the prompt. Left empty it morphs away from "
                 "nothing in particular, which blurs the result"},
        {"key": "repainting_start", "type": "float",
         "label": "Repaint start (s)", "default": None, "nullable": True,
         "min": 0.0, "max": 600.0, "step": 0.1},
        {"key": "repainting_end", "type": "float", "label": "Repaint end (s)",
         "default": None, "nullable": True, "min": -1.0, "max": 600.0,
         "step": 0.1},
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
        "duration": {"min_s": 10, "max_s": 300, "default_s": 60},
        "sample_rate": 48000, "outputs_per_job_max": 4,
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


def acestep_cpp_entry(id_, dit_file, name, fmt, steps, est, min_ram_gib, tier,
                      desc, notes=None):
    caps = {
        "supports_lyrics": True, "instrumental_only": False,
        "duration": {"min_s": 10, "max_s": 300, "default_s": 60},
        "sample_rate": 48000, "outputs_per_job_max": 4,
        "lyrics_tags": ["[intro]", "[verse]", "[pre-chorus]", "[chorus]",
                        "[bridge]", "[instrumental]", "[outro]"],
        "lyrics_hint": ("Section tags on their own lines structure the song; "
                        "leave a blank line between sections."),
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
        ],
    }
    return entry(
        id_, "acestepcpp",
        [{"repo_id": "Serveurperso/ACE-Step-1.5-GGUF", "gated": False,
          "allow_patterns": ACESTEP_CPP_CORE + [dit_file]}],
        name, desc, caps, min_ram_gib, tier, ACE_MIT,
        notes=notes or ("Runs via acestep.cpp (GGML). The text encoder, "
                        "composer LM and VAE are shared between all GGUF "
                        "variants — only the DiT differs."),
        variant_of="acestep-base", format_=fmt,
        settings={"lm_model": "acestep-5Hz-lm-4B-Q8_0.gguf",
                  "synth_model": dit_file,
                  "vae": "vae-BF16.gguf"})


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
        "sample_rate": 32000, "outputs_per_job_max": 4,
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
    caps = musicgen_caps(est=est, melody=melody, style=style)
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
        "8-bit."),
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
          musicgen_caps(est=8.0), 24, "slow", CC_NC, format_="mono"),
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
          musicgen_caps(est=2.0), 8, "fast", CC_NC,
          variant_of="musicgen-small", format_="stereo"),
    entry("musicgen-stereo-medium", "musicgen", ["facebook/musicgen-stereo-medium"],
          "MusicGen Medium (stereo)", "Stereo decoder variant of MusicGen Medium.",
          musicgen_caps(est=4.5), 16, "medium", CC_NC,
          variant_of="musicgen-medium", format_="stereo"),
    entry("musicgen-stereo-large", "musicgen", ["facebook/musicgen-stereo-large"],
          "MusicGen Large (stereo)", "Stereo decoder variant of MusicGen Large.",
          musicgen_caps(est=8.5), 24, "slow", CC_NC,
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
          musicgen_caps(est=0.8), 4, "fast", MIT,
          notes="Community model by Aaron Abebe; niche by design."),
    # ---- Stable Audio -----------------------------------------------------
    entry("stableaudio-open-10", "stableaudio",
          ["stabilityai/stable-audio-open-1.0"],
          "Stable Audio Open 1.0",
          "Longer stereo loops and textures than Small — up to 47 s. Gated repo.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 1, "max_s": 47, "default_s": 20},
              "sample_rate": 44100, "outputs_per_job_max": 4,
              "est_seconds_per_audio_second": 2.0,
              "params": [
                  {"key": "steps", "type": "int", "label": "Steps", "default": 100,
                   "nullable": False, "min": 20, "max": 250},
                  {"key": "cfg_scale", "type": "float", "label": "CFG scale",
                   "default": 7.0, "nullable": False, "min": 0.5, "max": 15.0,
                   "step": 0.5},
                  seed_param(),
                  *init_audio_params(),
              ],
          },
          16, "medium", STABILITY, gated=True,
          notes="Accept the license on huggingface.co and add your token in Settings."),
    # ---- Stable Audio 3 ---------------------------------------------------
    entry("stableaudio3-small-music", "stableaudio3",
          ["stabilityai/stable-audio-3-small-music"],
          "Stable Audio 3 Small (Music)",
          "Up to 120 s of stereo music on the CPU in seconds — and the only "
          "local model that can CONTINUE a song past its end. Also restyles "
          "(audio-to-audio) and repaints regions. Gated repo.",
          {
              "supports_lyrics": False, "instrumental_only": True,
              "duration": {"min_s": 1, "max_s": 120, "default_s": 30},
              "sample_rate": 44100, "outputs_per_job_max": 4,
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
    # ---- diffusers audio pipelines ---------------------------------------
    entry("audioldm2-music", "diffusers", ["cvssp/audioldm2-music"],
          "AudioLDM 2 Music",
          "Music-specialised AudioLDM 2 — text-to-music at 16 kHz.",
          diffusers_caps(30, 10, 100, 3.5), 12, "medium", CC_NC_SA),
    entry("audioldm2", "diffusers", ["cvssp/audioldm2"],
          "AudioLDM 2", "General text-to-audio; handles musical prompts.",
          diffusers_caps(30, 10, 100, 3.5), 12, "medium", CC_NC_SA),
    entry("audioldm2-large", "diffusers", ["cvssp/audioldm2-large"],
          "AudioLDM 2 Large", "Larger AudioLDM 2 — better quality, slower.",
          diffusers_caps(30, 10, 100, 3.5, est=5.0), 16, "slow", CC_NC_SA),
    entry("audioldm-s", "diffusers", ["cvssp/audioldm-s-full-v2"],
          "AudioLDM Small", "The original AudioLDM, small and quick.",
          diffusers_caps(20, 10, 50, 2.5, est=1.5), 8, "fast", CC_NC_SA),
    entry("audioldm-m", "diffusers", ["cvssp/audioldm-m-full"],
          "AudioLDM Medium", "Mid-size AudioLDM.",
          diffusers_caps(20, 10, 50, 2.5, est=2.0), 8, "fast", CC_NC_SA),
    entry("musicldm", "diffusers", ["ucsd-reach/musicldm"],
          "MusicLDM", "AudioLDM retrained on music (beat-synchronous mixup).",
          diffusers_caps(20, 10, 100, 2.0, est=2.5), 8, "medium", CC_NC_SA),
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
        ], est_realtime_factor=0.05),
        4, "fast", APACHE, featured=True,
        settings={"embed": "clap", "tagger": "zeroshot"},
        notes="Zero-shot: the vocabulary is the model. Labels it has never "
              "been trained on still score, and niche genres score poorly."),
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
          "allow_patterns": ["config.json", "tokenizer.json",
                             "tokenizer_config.json", "vocab.json",
                             "merges.txt", "special_tokens_map.json"]}],
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
          "allow_patterns": ["*.safetensors", "*.json", "*.model", "*.txt"]}],
        "ChatMusician (notation)",
        "A LLaMA-2 tuned on music theory and ABC notation: give it a tune "
        "and it writes a new piece in the same key and metre, rather than "
        "only composing from a description.",
        task_caps(["compose"], [
            {"key": "prompt", "type": "string", "label": "Description or ABC",
             "default": None, "nullable": True,
             "placeholder": "X:1\nT:My tune\nM:4/4\nK:D\n…",
             "help": "Paste ABC notation to continue in its style, or "
                     "describe the piece you want"},
            {"key": "max_tokens", "type": "int", "label": "Length limit",
             "default": 1024, "nullable": False, "min": 64, "max": 2048,
             "help": "How long the notation may run before it is cut off"},
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
        "transcribe-swiftf0", "transcription", [],
        "SwiftF0 (vocal melody)",
        "Instant monophonic melody extraction — run it on a vocals stem to "
        "get the tune as notes. Tiny model ships with the package.",
        task_caps(["transcribe"], [
            source_audio_param("Monophonic audio — a vocals stem or a "
                               "single-instrument line"),
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
    for m in kept:
        if m["id"] == "musicgen-small" or m["id"] == "musicgen-medium":
            m["format"] = "mono"
        if m["id"] == "acestep-base":
            m["format"] = "turbo · 8 steps"
            # acestep-base is hand-written rather than generated, so the plan
            # surface every other ACE-Step variant gets from `ace_variant` has
            # to be grafted on here. Keyed by param key so re-running is a
            # no-op rather than a duplication.
            have = {p["key"] for p in m["capabilities"]["params"]}
            m["capabilities"]["params"] += [
                p for p in ace_plan_params() + ace_plan_task_params()
                if p["key"] not in have]
            m["capabilities"]["tasks"] = ["generate", "plan"]

    # Order is load-bearing: several features resolve "the first installed
    # model that can do X" against /v1/models order, which is this order.
    models = kept + [copy.deepcopy(e) for e in NEW_ENTRIES]
    for m in models:
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
