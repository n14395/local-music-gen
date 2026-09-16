"""Music captioning: a model listens to a track and writes about it.

One engine today — LP-MusicCaps, switched on `settings.engine` the way the
transcription family switches between its four. The switch exists ahead of a
second engine on purpose: the experimental captioners (MusiLingo, MU-LLaMA,
SALMONN, Pengi, Audio Flamingo) each need their own vendored inference code,
and each will arrive as another branch here rather than as another family.
"""

from __future__ import annotations

import json
import os

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, release_accelerator_memory)

ENGINES = ("lpmusiccaps",)

# Engines that are wired but not yet proven on this stack. Named here so the
# failure is a sentence rather than a KeyError if a catalog entry ships early.
PLANNED = ("musilingo", "mullama", "salmonn", "pengi", "audioflamingo2")


class CaptioningAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.bundle = None

    def _engine(self) -> str:
        engine = str(self.settings.get("engine") or "lpmusiccaps")
        if engine in PLANNED:
            raise RuntimeError(
                f"the {engine} captioner is not wired up yet — see the "
                f"commented catalog entries")
        if engine not in ENGINES:
            raise RuntimeError(f"unknown captioning engine '{engine}'")
        return engine

    def _find(self, *needles: str) -> str | None:
        """The snapshot for whichever repo id contains one of `needles`."""
        for repo, path in self.model_paths.items():
            lowered = repo.lower()
            if any(needle in lowered for needle in needles):
                return path
        return None

    def load(self, progress_cb: ProgressCb) -> None:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        engine = self._engine()
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")

        snapshot = self._find("lp-music-caps") or next(
            iter(self.model_paths.values()))
        # The checkpoint the entry asked for: `transfer` is the one the
        # project's own demo uses, and the catalog picks between the three
        # by name rather than by guessing at the directory's contents.
        wanted = str(self.settings.get("checkpoint") or "transfer") + ".pth"
        checkpoint = os.path.join(snapshot, wanted)
        if not os.path.exists(checkpoint):
            found = sorted(f for f in os.listdir(snapshot)
                           if f.endswith(".pth"))
            if not found:
                raise RuntimeError(f"no checkpoint (.pth) in {snapshot}")
            checkpoint = os.path.join(snapshot, found[0])

        # BART's config and tokenizer — shape and vocabulary only, since the
        # checkpoint overwrites every weight. Fetched as its own repo so this
        # never reaches for the network mid-job.
        bart = self._find("bart-base")
        if not bart:
            raise RuntimeError("the BART tokenizer snapshot is missing")

        progress_cb(None, f"loading {engine}")
        from . import lpmusiccaps

        self.bundle = lpmusiccaps.load(checkpoint, bart)
        progress_cb(None, "captioner ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "captioning models write words, not audio — submit a caption "
            "task instead")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "caption":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.bundle is not None

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        # This model was trained to describe, not to answer: it has no
        # instruction channel at all. A question is refused rather than
        # silently ignored, so "Ask about this song" cannot look as though
        # it answered something it never read.
        if str(params.get("question") or "").strip():
            raise RuntimeError(
                "this captioner cannot answer questions — it only describes. "
                "Use an audio-language model (Qwen2-Audio) to ask something.")
        beams = max(1, min(8, int(params.get("num_beams") or 5)))

        from . import lpmusiccaps

        text, sentences = lpmusiccaps.caption(self.bundle, src, beams,
                                              progress_cb, cancel)
        if cancel.cancelled:
            raise CancelledError()

        progress_cb(0.97, "writing it down")
        payload = {"text_version": 1, "kind": "caption", "text": text,
                   "model": self.model_id, "engine": self._engine()}
        path = os.path.join(out_dir, "caption.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)

        progress_cb(1.0, "done")
        return TaskResult(
            artifacts=[Artifact(kind="text", label="caption", path=path,
                                format="json")],
            meta={"text": payload, "caption_preview": text[:200],
                  "windows": len(sentences)})

    def unload(self) -> None:
        self.bundle = None
        # The caption model goes to MPS when it is there; the allocator keeps
        # its blocks until it is told, however few references are left.
        release_accelerator_memory()
