# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""The listeners: MLX models that take audio and give back words.

Two engines behind one family, switched on the catalog's `settings.engine`
exactly as the transcription family switches between Basic Pitch and MT3:

  whisper     — the sung words, with a timing on every line (task `lyrics`)
  qwen2audio  — descriptions, answers and tags (tasks `caption` and `tag`)

Nothing here generates audio. The family exists beside `mlxaudio` rather than
inside it because that one's mlx-audio pin also feeds MiniMax Music 3, and a
bump to pick up a better speech model must not be able to change how the
flagship music model renders.
"""

from __future__ import annotations

import os

from engine_protocol.adapter import (Artifact, CancelToken, GenerateResult,
                                     ModelAdapter, ProgressCb, TaskResult)

ENGINES = ("whisper", "qwen2audio")

# Which engine answers which task. A model that declares a task its engine
# cannot run is a catalog mistake, and this is where it is caught.
TASKS_BY_ENGINE = {
    "whisper": ("lyrics",),
    "qwen2audio": ("caption", "tag"),
}


class MLXSTTAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None

    def _engine(self) -> str:
        engine = str(self.settings.get("engine") or "whisper")
        if engine not in ENGINES:
            raise RuntimeError(f"unknown mlxstt engine '{engine}'")
        return engine

    def _snapshot(self, match: str | None = None) -> str:
        """The snapshot for a repo whose id contains `match`.

        An entry may declare more than one repo — the Whisper entries pair
        MLX weights with the upstream tokenizer files — so "the snapshot" is
        a question that needs asking by name.
        """
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        if match:
            for repo, path in self.model_paths.items():
                if match in repo.lower():
                    return path
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        # Everything resolves from the local snapshot; make sure nothing
        # reaches for the network mid-job, so a broken install fails fast and
        # legibly instead of hanging (the assistant family's rule).
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        engine = self._engine()
        progress_cb(None, f"loading {engine} (MLX)")
        from mlx_audio.stt.utils import load_model

        self.model = load_model(self._snapshot("mlx-community"))
        if engine == "whisper":
            self._attach_whisper_processor(progress_cb)
        progress_cb(None, "listener ready")

    def _attach_whisper_processor(self, progress_cb: ProgressCb) -> None:
        """Give Whisper its tokenizer and feature extractor.

        The mlx-community conversions ship weights and a config and nothing
        else, so mlx-audio's own post-load hook finds no processor beside
        them and leaves the model unable to decode a single token. The
        catalog entry therefore also fetches the *upstream* repo's tokenizer
        files (a few MB, no weights), and they are attached here.
        """
        if getattr(self.model, "_processor", None) is not None:
            return
        path = self._snapshot("openai")
        progress_cb(None, "loading the tokenizer")
        from transformers import WhisperProcessor

        self.model._processor = WhisperProcessor.from_pretrained(path)

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "these models write words, not audio — submit a caption, "
            "lyrics or tag task instead")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        engine = self._engine()
        if task not in TASKS_BY_ENGINE[engine]:
            raise NotImplementedError(
                f"the {engine} engine does not answer '{task}'")
        assert self.model is not None

        if engine == "whisper":
            from . import whisper
            specs, meta = whisper.transcribe(self.model, self.model_id,
                                             params, out_dir, progress_cb,
                                             cancel)
        else:
            from . import qwen2audio
            specs, meta = qwen2audio.run(self.model, self.model_id, task,
                                         params, out_dir, progress_cb, cancel)

        return TaskResult(
            artifacts=[Artifact(kind=s["kind"], label=s["label"],
                                path=s["path"], format=s["format"])
                       for s in specs],
            meta=meta)

    def unload(self) -> None:
        self.model = None
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:  # noqa: BLE001 — unload must never raise
            pass
