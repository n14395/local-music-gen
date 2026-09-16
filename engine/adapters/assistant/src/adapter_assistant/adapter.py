"""The writing assistant: a small instruct LLM that helps compose prompts.

This family answers one task, `assist`, whose `kind` picks the job (see
kinds.py). It generates text, never audio, and it is deliberately small enough
— under a gigabyte — to classify as a small model in the supervisor's job
queue, so it loads into the warm pool beside whatever music model is resident
instead of evicting it. That constraint is the whole design: an assistant that
unloaded ACE-Step every time you asked it for a title would never be used
twice.

Everything it knows about how to write for a given music model comes from the
catalog, via the `target_family` / `lyrics_tags` params the app sends. The
model itself knows nothing about this app.
"""

from __future__ import annotations

import json
import os
import time

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, release_accelerator_memory)

from .dialects import for_family
from .kinds import KINDS, build_messages
from .parsing import extract, satisfies

# Sampling defaults. Warmer than a coding assistant would want — these are
# creative-writing jobs and a temperature of 0 produces the same four adjectives
# every time — but cool enough that the JSON stays well formed.
DEFAULT_TEMPERATURE = 0.7
DEFAULT_TOP_P = 0.9
# The repair pass runs cold: by then the model has already shown it can produce
# the content and the only thing left to fix is the syntax.
REPAIR_TEMPERATURE = 0.0

# Progress is reported per token against this estimate, because the real token
# count is unknowable until the model stops. Overshooting is handled by
# clamping — a bar that sticks at 95% reads better than one that hits 100% and
# then keeps going.
_PROGRESS_CEILING = 0.95


class AssistantAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.tokenizer = None

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("assistant model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        # MLX resolves everything from the local snapshot; make sure nothing
        # reaches for the network mid-job if a file turns out to be missing,
        # so a broken install fails fast and legibly instead of hanging.
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        progress_cb(None, "loading assistant")
        from mlx_lm import load

        self.model, self.tokenizer = load(self._snapshot())
        progress_cb(None, "assistant ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "the assistant family writes text, not audio — submit an "
            "'assist' task instead")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "assist":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.model is not None and self.tokenizer is not None

        kind_id = str(params.get("kind") or "").strip()
        kind = KINDS.get(kind_id)
        if kind is None:
            raise ValueError(
                f"unknown assist kind '{kind_id}' "
                f"(expected one of: {', '.join(sorted(KINDS))})")

        raw_input = params.get("assist_input") or "{}"
        try:
            inp = json.loads(raw_input) if isinstance(raw_input, str) else dict(raw_input)
        except (ValueError, TypeError) as e:
            raise ValueError(f"assist_input is not valid JSON: {e}") from e
        if not isinstance(inp, dict):
            raise ValueError("assist_input must be a JSON object")

        dialect = for_family(params.get("target_family"))
        # Inside the input blob, not a param of its own: the tags belong to the
        # *target* model rather than to this one, and a param would have to be
        # declared on the assistant's own entry to survive the supervisor —
        # which would read as the assistant having lyric tags.
        lyric_tags = inp.get("lyrics_tags")
        if isinstance(lyric_tags, str):
            lyric_tags = [t for t in lyric_tags.split() if t]

        messages = build_messages(kind, inp, dialect, lyric_tags)
        temperature = _clamp(params.get("temperature"), DEFAULT_TEMPERATURE,
                             0.0, 2.0)
        max_tokens = clamp_max_tokens(params.get("max_tokens"),
                                      kind.max_tokens)

        started = time.monotonic()
        text = self._chat(messages, temperature=temperature,
                          max_tokens=max_tokens, progress_cb=progress_cb,
                          cancel=cancel, label="writing")
        value = extract(text)
        repaired = False

        if not satisfies(value, kind.required, kind.may_be_empty):
            # One cold retry, showing the model its own output and the shape it
            # was supposed to fit. Cheaper and far more reliable than asking the
            # app to cope with prose where it expected fields.
            progress_cb(None, "tidying the answer")
            repair = messages + [
                {"role": "assistant", "content": text[:2000]},
                {"role": "user", "content":
                 "That was not valid JSON in the requested shape. Reply again "
                 "with the same content as a single JSON object matching the "
                 "shape exactly. Output only the object."},
            ]
            text2 = self._chat(repair, temperature=REPAIR_TEMPERATURE,
                               max_tokens=max_tokens, progress_cb=progress_cb,
                               cancel=cancel, label="tidying the answer")
            value2 = extract(text2)
            repaired = True
            if satisfies(value2, kind.required, kind.may_be_empty):
                value, text = value2, text2

        ok = satisfies(value, kind.required, kind.may_be_empty)
        payload = {
            "kind": kind.id,
            "ok": ok,
            # Always present, always the model's real words. When `ok` is
            # false this is the only thing the app can show, and it is still
            # worth showing — the user can edit prose by hand.
            "raw": text,
            "value": value if isinstance(value, dict) else {},
            "repaired": repaired,
            "target_family": params.get("target_family"),
            "dialect": dialect.name,
        }
        path = os.path.join(out_dir, "assist.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)

        progress_cb(1.0, "done")
        return TaskResult(
            artifacts=[Artifact(kind="assist", label=kind.id, path=path,
                                format="json")],
            # The whole answer rides meta as well as the file: these payloads
            # are small, and it saves the app a disk read on the path where it
            # wants to show the result immediately.
            meta={"assist": payload,
                  "elapsed_s": round(time.monotonic() - started, 2)})

    def _chat(self, messages: list[dict], *, temperature: float,
              max_tokens: int, progress_cb: ProgressCb, cancel: CancelToken,
              label: str) -> str:
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler

        prompt = self.tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False,
            # Qwen3-class checkpoints emit a <think> block unless told not to.
            # Harmless if the template does not accept it — hence the retry
            # below rather than a version check.
            **_thinking_kwarg(self.tokenizer, messages))
        sampler = make_sampler(temp=temperature, top_p=DEFAULT_TOP_P)

        chunks: list[str] = []
        produced = 0
        for response in stream_generate(self.model, self.tokenizer, prompt,
                                        max_tokens=max_tokens,
                                        sampler=sampler):
            if cancel.cancelled:
                raise CancelledError()
            chunks.append(response.text)
            produced += 1
            if produced % 8 == 0:
                fraction = min(produced / max(1, max_tokens), _PROGRESS_CEILING)
                progress_cb(fraction, label)
        return "".join(chunks)

    def unload(self) -> None:
        # There was no unload at all, so switching between the two assistant
        # entries in a warm worker kept the first model referenced AND its
        # MLX buffers cached while the second loaded.
        self.model = None
        self.tokenizer = None
        release_accelerator_memory()


def _thinking_kwarg(tokenizer, messages: list[dict]) -> dict:
    """`enable_thinking=False` where the chat template understands it.

    Probed rather than assumed: passing an unknown keyword to a Jinja template
    that does not declare it raises, and which checkpoints accept it changes
    with every upstream release. One cheap probe at call time is more durable
    than a table of model names.
    """
    try:
        tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                      tokenize=False, enable_thinking=False)
    except (TypeError, ValueError):
        return {}
    return {"enable_thinking": False}


def clamp_max_tokens(value, default: int) -> int:
    """The token ceiling one assist call may ask for.

    The catalog declares 64…2048 and nothing enforced it: the supervisor does
    no numeric range validation, and mlx_lm reads -1 as "an infinite
    generator" — a job that ran to EOS with no ceiling, with the bar stuck at
    0.95 (produced / max(1, -1)). An absent or zero value means "the kind's
    own", which is what `default` carries.
    """
    return max(64, min(2048, int(value or default)))


def _clamp(value, default: float, lo: float, hi: float) -> float:
    try:
        got = float(value)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, got))
