"""MOSS-Music-8B (Thinking, MLX 8-bit): the conversational music brain —
captioning, key/tempo/structure questions, long-form audio QA (task `caption`).

The stock PyTorch path is documented unusable on Macs (<0.3 tok/s); the MLX
community backend is the only viable route, and it lives on a fork branch
(pinned tarball), not in the pip package. Import discipline from triage: pull
`load_pretrained` / `generate` from their submodules DIRECTLY — the package
__init__'s lazy loader recurses forever.

A Thinking model narrates its reasoning inside <think> tags; the adapter
strips them from the answer and keeps the visible text.
"""

from __future__ import annotations

import json
import os
import re
import sys

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, aux_dir)
from engine_protocol.staging import fetch_tarball_tree, staged

REPO_COMMIT = "d87d73aaa640a6d31fe85726562496998879f042"
REPO_TARBALL = (f"https://github.com/dthinkr/MOSS-Music/archive/"
                f"{REPO_COMMIT}.tar.gz")


class MossMusicAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.processor = None
        self._generate = None

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        cache = aux_dir("mossmusic")
        repo = os.path.join(cache, f"MOSS-Music-{REPO_COMMIT}")
        if not staged(repo, "mlx/moss_music_mlx/convert.py",
                      "src/processing_moss_music.py"):
            progress_cb(None, "fetching the MLX backend (pinned fork "
                              "snapshot, first use only)")
            fetch_tarball_tree(REPO_TARBALL, cache,
                               f"MOSS-Music-{REPO_COMMIT}")
        for p in (os.path.join(repo, "mlx"), repo):
            if p not in sys.path:
                sys.path.insert(0, p)
        os.chdir(repo)

        progress_cb(None, "loading MOSS-Music (MLX 8-bit — loads in about "
                          "a second)")
        from moss_music_mlx.convert import load_pretrained
        from moss_music_mlx.generate import stream_generate
        from src.processing_moss_music import MossMusicProcessor
        from transformers import AutoTokenizer

        snapshot = self._snapshot()
        self.model = load_pretrained(snapshot)
        # MOSS's processor drops trust_remote_code before it calls AutoTokenizer,
        # which otherwise prompts on this worker's protocol stdin indefinitely.
        tokenizer = AutoTokenizer.from_pretrained(
            snapshot, use_fast=False, trust_remote_code=True,
            local_files_only=True)
        self.processor = MossMusicProcessor(tokenizer, enable_time_marker=True)
        self._generate = stream_generate
        progress_cb(None, "MOSS-Music ready")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "MOSS-Music writes words about audio — submit a caption task")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task not in ("caption", "lyrics"):
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.model is not None

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")
        question = ""
        if task == "lyrics":
            # A conversational model transcribes on request; the fixed
            # prompt keeps the output a lyric sheet rather than a chat.
            prompt = ("Transcribe the sung lyrics of this track, verbatim, "
                      "with section labels like [Verse] and [Chorus]. "
                      "Output only the lyrics, nothing else.")
        else:
            question = str(params.get("question") or "").strip()
            prompt = question or ("Describe this track in detail: genre, "
                                  "instrumentation, tempo, key, structure, "
                                  "production character.")

        # The fork's default 768 was routinely eaten whole by the <think>
        # phase, shipping raw reasoning as the answer (audit B11).
        max_tokens = max(256, min(8192,
                                  int(params.get("max_new_tokens") or 3072)))
        progress_cb(None, "listening and thinking (a Thinking model spends "
                          "most of its tokens reasoning first)")
        if cancel.cancelled:
            raise CancelledError()

        count = 0

        def on_token(_tok: int) -> None:
            nonlocal count
            count += 1
            if cancel.cancelled:
                raise CancelledError()
            if count % 32 == 0:
                progress_cb(min(0.95, count / max_tokens),
                            f"thinking and writing — {count} tokens",
                            step=count, steps=max_tokens)

        # temp 0.7 / top_p 0.8, never the fork's greedy default: a Thinking
        # model decoded greedily falls into an unclosable repetition loop
        # inside <think> and burns ANY token budget (reproduced on the 4-bit
        # weights, 2026-09-03 — "or a drop, or a build-up, …" forever).
        # 0.8 is the fork's own reference nucleus setting.
        reply = "".join(self._generate(self.model, self.processor, prompt,
                                       audio_path=src,
                                       max_new_tokens=max_tokens,
                                       temp=0.7, top_p=0.8,
                                       on_token=on_token))
        if cancel.cancelled:
            raise CancelledError()

        # `$` alternative: a decode cut off mid-reasoning has no closing
        # tag, and the old closing-tag-only regex shipped the whole
        # chain-of-thought as the answer (audit B11).
        text = re.sub(r"<think>.*?(?:</think>|$)", "", reply,
                      flags=re.DOTALL).strip()
        if reply and not text:
            raise RuntimeError(
                "the model spent its whole token budget reasoning and never "
                "answered — raise Max tokens and try again")
        progress_cb(0.97, "writing it down")
        payload = {"text_version": 1, "kind": task, "text": text,
                   "model": self.model_id, "engine": "mossmusic"}
        if question:
            payload["question"] = question
        path = os.path.join(out_dir, f"{task}.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)

        meta = {"text": payload,
                ("lyrics_preview" if task == "lyrics"
                 else "caption_preview"): text[:200]}
        if question:
            meta["question"] = question
        progress_cb(1.0, "done")
        return TaskResult(
            artifacts=[Artifact(kind="text", label=task, path=path,
                                format="json")],
            meta=meta)

    def unload(self) -> None:
        self.model = None
        self.processor = None
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:  # noqa: BLE001 — unload must never raise
            pass
