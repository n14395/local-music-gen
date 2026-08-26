"""ACE-Step's music listeners: Qwen2.5-Omni fine-tunes that hear a track.

Two catalog entries share this family — the transcriber (task `lyrics`) and
the captioner (task `caption`). Both are the annotation models ACE-Step used
to label its own training data, so their one prompt each is a fixed trained
string, not a free instruction channel:

    transcriber:  *Task* Transcribe this audio in detail
    captioner:    *Task* Describe this audio in detail

The checkpoints carry the full Omni architecture name in their config but ship
thinker-only weights — loading them with `Qwen2_5OmniForConditionalGeneration`
crashes on the missing talker, so the Thinker class is load-bearing here.

The transcriber's output is plain text with musical structure tags
(`[Verse]`, `[Chorus]`, `[Spoken Word Intro]`) inline; there are no timed
segments, so the lyrics payload deliberately carries none.
"""

from __future__ import annotations

import json
import os

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult)

PROMPTS = {
    "lyrics": "*Task* Transcribe this audio in detail",
    "caption": "*Task* Describe this audio in detail",
}


class QwenOmniAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.processor = None
        self.device = "cpu"

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        import torch
        from transformers import (Qwen2_5OmniProcessor,
                                  Qwen2_5OmniThinkerForConditionalGeneration)

        snapshot = self._snapshot()
        self.device = ("mps" if torch.backends.mps.is_available() else "cpu")
        progress_cb(None, "loading the listener (16 GB of weights, "
                          "memory-mapped)")
        self.model = Qwen2_5OmniThinkerForConditionalGeneration.from_pretrained(
            snapshot, torch_dtype=torch.bfloat16)
        self.model = self.model.to(self.device).eval()
        progress_cb(None, "loading the processor")
        self.processor = Qwen2_5OmniProcessor.from_pretrained(snapshot)
        progress_cb(None, f"listener ready on {self.device}")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "these models write words, not audio — submit a lyrics or "
            "caption task instead")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task not in PROMPTS:
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.model is not None and self.processor is not None
        import librosa
        import torch
        from transformers import StoppingCriteria, StoppingCriteriaList

        src = params.get("source_audio")
        if not src or not os.path.isfile(src):
            raise RuntimeError("source_audio missing")

        prompt = PROMPTS[task]
        question = str(params.get("question") or "").strip()
        if task == "caption" and question:
            # The captioner is an instruct fine-tune, so a typed question
            # rides the same slot its fixed task prompt does.
            prompt = question
        max_tokens = max(32, min(4096, int(params.get("max_tokens") or 512)))

        progress_cb(0.02, "reading the audio")
        sr = self.processor.feature_extractor.sampling_rate
        audio, _sr = librosa.load(src, sr=sr, mono=True)
        max_input_s = float(self.settings.get("max_input_s") or 600.0)
        if len(audio) > int(max_input_s * sr):
            audio = audio[: int(max_input_s * sr)]
            progress_cb(0.03, f"listening to the first {max_input_s:.0f}s")

        conversation = [{"role": "user", "content": [
            {"type": "audio", "audio": src},
            {"type": "text", "text": prompt}]}]
        text = self.processor.apply_chat_template(
            conversation, add_generation_prompt=True, tokenize=False)
        inputs = self.processor(text=text, audio=[audio], return_tensors="pt",
                                padding=True).to(self.device)

        class _CancelOrProgress(StoppingCriteria):
            def __call__(self, input_ids, scores, **kwargs) -> bool:
                done = input_ids.shape[-1] - inputs["input_ids"].shape[-1]
                if done and done % 16 == 0:
                    progress_cb(min(0.95, 0.05 + 0.9 * done / max_tokens),
                                "writing")
                return cancel.cancelled

        progress_cb(0.05, "listening")
        with torch.no_grad():
            out = self.model.generate(
                **inputs, max_new_tokens=max_tokens,
                stopping_criteria=StoppingCriteriaList([_CancelOrProgress()]))
        if cancel.cancelled:
            raise CancelledError()

        prompt_len = inputs["input_ids"].shape[-1]
        reply = self.processor.batch_decode(
            out[:, prompt_len:], skip_special_tokens=True)[0].strip()

        progress_cb(0.97, "writing it down")
        payload = {"text_version": 1, "kind": task, "text": reply,
                   "model": self.model_id, "engine": "qwenomni"}
        if task == "caption" and question:
            payload["question"] = question
        path = os.path.join(out_dir, f"{task}.json")
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(payload, f, ensure_ascii=False)
        os.replace(tmp, path)

        meta: dict = {"text": payload}
        if task == "caption":
            meta["caption_preview"] = reply[:200]
            if question:
                meta["question"] = question
        else:
            meta["lyrics_preview"] = reply[:200]
        progress_cb(1.0, "done")
        return TaskResult(
            artifacts=[Artifact(kind="text", label=task, path=path,
                                format="json")],
            meta=meta)

    def unload(self) -> None:
        self.model = None
        self.processor = None
        try:
            import torch

            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:  # noqa: BLE001 — unload must never raise
            pass
