"""The notation composers: text or ABC in, ABC and MIDI out.

Two engines behind one family, switched on the catalog's `settings.engine`:

  text2music    — BART-base fine-tuned on text/ABC pairs; small, fast, and
                  the default (task `compose`)
  chatmusician  — LLaMA-2 tuned on music theory and notation; continues a
                  tune rather than only describing one

`compose` is the one task in the app whose primary input is a *string param*
(`params.prompt`) rather than an uploaded file, because notation is text.
Submit validation only presence-checks audio/midi/json params, so the empty
prompt is caught here.
"""

from __future__ import annotations

import json
import os

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

from . import abc_convert

ENGINES = ("text2music", "chatmusician")


class NotationAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.bundle = None

    def _engine(self) -> str:
        engine = str(self.settings.get("engine") or "text2music")
        if engine not in ENGINES:
            raise RuntimeError(f"unknown notation engine '{engine}'")
        return engine

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        engine = self._engine()
        progress_cb(None, f"loading {engine}")
        if engine == "text2music":
            from . import text2music

            self.bundle = text2music.load(self._snapshot())
        else:
            from . import chatmusician

            self.bundle = chatmusician.load(self._snapshot())
        progress_cb(None, "composer ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "notation models write notation, not audio — submit a compose "
            "task, then render the notes it returns")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "compose":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.bundle is not None

        prompt = str(params.get("prompt") or "").strip()
        if not prompt:
            raise RuntimeError(
                "prompt missing — describe the music you want, or paste the "
                "ABC notation to work from")
        max_tokens = max(64, min(2048, int(params.get("max_tokens") or 1024)))
        temperature = _clamp(params.get("temperature"), 0.7, 0.0, 1.5)
        seed = params.get("seed")
        seed = int(seed) if seed is not None else None

        engine = self._engine()
        progress_cb(0.15, "reading the prompt")
        if engine == "text2music":
            from . import text2music

            raw = text2music.compose(self.bundle, prompt, max_tokens,
                                     temperature, seed, progress_cb, cancel)
        else:
            from . import chatmusician

            raw = chatmusician.compose(self.bundle, prompt, max_tokens,
                                       temperature, seed, progress_cb, cancel)
        if cancel.cancelled:
            raise CancelledError()

        abc = abc_convert.clean(raw)
        if not abc:
            raise RuntimeError("the model wrote nothing that reads as ABC")

        progress_cb(0.92, "writing the notation")
        payload = {"text_version": 1, "kind": "abc", "text": abc,
                   "model": self.model_id, "engine": engine}
        text_path = os.path.join(out_dir, "abc.json")
        tmp = text_path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, text_path)
        artifacts = [Artifact(kind="text", label="abc", path=text_path,
                              format="json")]
        meta = {"text": payload, "abc_preview": abc[:200]}

        # The MIDI is what makes the notation audible, but a tune that will
        # not convert is still a tune: the job succeeds with the text alone
        # and says why the notes are missing.
        progress_cb(0.95, "converting to MIDI")
        midi_path = os.path.join(out_dir, "composition.mid")
        try:
            notes = abc_convert.to_midi(abc, midi_path)
        except Exception as e:  # noqa: BLE001 — documented degradation
            meta["midi_error"] = f"the notation would not convert: {e}"
        else:
            artifacts.append(Artifact(kind="midi", label="composition",
                                      path=midi_path, format="mid"))
            meta["notes"] = notes

        progress_cb(1.0, "done")
        return TaskResult(artifacts=artifacts, meta=meta)

    def unload(self) -> None:
        self.bundle = None


def _clamp(value, default: float, low: float, high: float) -> float:
    try:
        got = float(value)
    except (TypeError, ValueError):
        return default
    return max(low, min(high, got))
