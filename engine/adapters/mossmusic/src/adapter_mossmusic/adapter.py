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
import tarfile
import urllib.request

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

REPO_COMMIT = "d87d73aaa640a6d31fe85726562496998879f042"
REPO_TARBALL = (f"https://github.com/dthinkr/MOSS-Music/archive/"
                f"{REPO_COMMIT}.tar.gz")


class MossMusicAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.processor = None
        self._generate = None

    def _cache_dir(self) -> str:
        hf_home = os.environ.get("HF_HOME")
        base = (os.path.dirname(hf_home) if hf_home
                else os.path.expanduser("~/.cache"))
        d = os.path.join(base, "mossmusic")
        os.makedirs(d, exist_ok=True)
        return d

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        cache = self._cache_dir()
        repo = os.path.join(cache, f"MOSS-Music-{REPO_COMMIT}")
        if not os.path.isdir(repo):
            progress_cb(None, "fetching the MLX backend (pinned fork "
                              "snapshot, first use only)")
            tar_path = os.path.join(cache, "repo.tar.gz")
            with urllib.request.urlopen(REPO_TARBALL, timeout=300) as resp, \
                    open(tar_path, "wb") as f:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            with tarfile.open(tar_path) as tar:
                tar.extractall(cache, filter="data")
            os.unlink(tar_path)
        for p in (os.path.join(repo, "mlx"), repo):
            if p not in sys.path:
                sys.path.insert(0, p)
        os.chdir(repo)

        progress_cb(None, "loading MOSS-Music (MLX 8-bit — loads in about "
                          "a second)")
        from moss_music_mlx.convert import load_pretrained
        from moss_music_mlx.generate import generate
        from src.processing_moss_music import MossMusicProcessor

        snapshot = self._snapshot()
        self.model = load_pretrained(snapshot)
        self.processor = MossMusicProcessor.from_pretrained(
            snapshot, trust_remote_code=True, enable_time_marker=True)
        self._generate = generate
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

        progress_cb(None, "listening and thinking (the reasoning trace is "
                          "most of the tokens)")
        if cancel.cancelled:
            raise CancelledError()
        reply = str(self._generate(self.model, self.processor, prompt,
                                   audio_path=src))
        if cancel.cancelled:
            raise CancelledError()

        text = re.sub(r"<think>.*?</think>", "", reply,
                      flags=re.DOTALL).strip()
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
