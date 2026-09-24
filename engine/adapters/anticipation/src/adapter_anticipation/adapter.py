# Copyright 2026 Nick Fay
# SPDX-License-Identifier: Apache-2.0

"""Anticipatory Music Transformer (Stanford CRFM): symbolic music generation
as a `compose` task — MIDI out, voiced later by the SoundFont renderer.

The prompt is unused by the model (unconditional generation over MIDI events);
`duration_s` sets the span. Contract shape: a `midi` artifact labeled
"composition" plus, when music21 manages the conversion, a `text` artifact of
kind "abc" — the exact pair the notation composers emit, so every downstream
card works unchanged.

Speed honesty: 10 s of music took 23 minutes of CPU in triage (token-by-token
GPT-2). The adapter tries MPS first — the ~10× that should recover is the
difference between a curiosity and a tool — and falls back to CPU.
"""

from __future__ import annotations

import json
import os
import secrets

from engine_protocol.adapter import (Artifact, CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter, ProgressCb,
                                     TaskResult, release_accelerator_memory)


class AnticipationAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.model = None
        self.device = "cpu"

    def _snapshot(self) -> str:
        if not self.model_paths:
            raise RuntimeError("model has no downloaded snapshot")
        return next(iter(self.model_paths.values()))

    def load(self, progress_cb: ProgressCb) -> None:
        import torch
        from transformers import AutoModelForCausalLM

        progress_cb(None, "loading the music transformer")
        self.model = AutoModelForCausalLM.from_pretrained(self._snapshot())
        if torch.backends.mps.is_available():
            try:
                self.model = self.model.to("mps")
                self.device = "mps"
            except Exception:  # noqa: BLE001 — CPU is the proven fallback
                self.device = "cpu"
        self.model.eval()
        progress_cb(None, f"composer ready on {self.device}")

    def generate(self, prompt, lyrics, params, out_path, progress_cb,
                 cancel) -> GenerateResult:
        raise NotImplementedError(
            "this model writes notes, not audio — submit a compose task, "
            "then voice the MIDI with the note renderer")

    def run_task(self, task: str, params: dict, out_dir: str,
                 progress_cb: ProgressCb, cancel: CancelToken) -> TaskResult:
        if task != "compose":
            return super().run_task(task, params, out_dir, progress_cb, cancel)
        assert self.model is not None
        import torch
        from anticipation.convert import events_to_midi
        from anticipation.sample import generate as amt_generate

        span_s = max(5.0, min(60.0, float(params.get("span_s") or 15.0)))
        top_p = float(params.get("top_p") or 0.98)
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. Reported back in `meta`.
        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        torch.manual_seed(seed)

        # The model's actual specialty (it is the Anticipatory Music
        # Transformer): events before start_time are history, events after
        # it become anticipated controls — so continuation and infilling
        # are the same call with different windows, and the result always
        # includes the input, making the part playable standalone.
        mode = str(params.get("compose_mode") or "generate").strip()
        inputs: list[int] = []
        controls: list[int] = []
        if mode in ("continue", "infill", "accompany"):
            midi_in = params.get("melody_midi")
            if not midi_in or not os.path.isfile(midi_in):
                raise RuntimeError(
                    "melody_midi missing — continue, infill and accompany "
                    "need the notes to work from")
            from anticipation.convert import midi_to_events

            inputs = midi_to_events(midi_in)
            if not inputs:
                raise RuntimeError("the MIDI file contains no usable notes")
        if mode == "continue":
            from anticipation import ops

            start = float(ops.max_time(inputs, seconds=True))
            # The time vocabulary ends at 100 s (config.MAX_TIME_IN_SECONDS):
            # a longer history — exactly what the SwiftF0 → continue flow
            # produces — feeds out-of-vocab time tokens (audit §3). Keep the
            # trailing window and shift it to start at zero.
            keep_s = max(20.0, 95.0 - span_s)
            if start > keep_s:
                cut = start - keep_s
                inputs = ops.sort(ops.translate(
                    ops.clip(inputs, cut, start + 1.0, clip_duration=False),
                    -cut, seconds=True))
                start = float(ops.max_time(inputs, seconds=True))
            end = start + span_s
        elif mode == "infill":
            start = float(params.get("gap_start_s") or 0.0)
            end = float(params.get("gap_end_s") or 0.0)
            if end <= start:
                raise RuntimeError("infill needs a window: set the gap's "
                                   "end after its start")
            if end > 95.0:
                # Same 100 s time-vocabulary wall as continuation, surfaced
                # instead of corrupting the render (audit §3).
                raise RuntimeError(
                    "the model's timeline ends at ~95 s — trim the piece "
                    "or move the gap earlier")
            # generate() keeps every input event — the window's own notes
            # would ride through as anticipated controls and leave the model
            # nothing to write (verified in the smoke). Clip them out: what
            # remains before the gap is history, after it the future the
            # model writes toward.
            from anticipation import ops

            span_end = float(ops.max_time(inputs, seconds=True)) + 1.0
            inputs = ops.sort(
                ops.clip(inputs, 0, start, clip_duration=False)
                + ops.clip(inputs, end, span_end, clip_duration=False))
        elif mode == "accompany":
            # The model's namesake mode, and the one the app could not reach.
            #
            # Continue and infill hand the melody over as *history* — notes
            # already played, which the model writes after or between. This
            # hands it over as **controls**: notes it can see coming but has
            # not written, so it plays a second voice alongside them for the
            # whole span. That is what "anticipatory" means in Anticipatory
            # Music Transformer, and it is the difference between a model that
            # finishes your idea and one that accompanies it.
            #
            # Controls carry their own offset in this vocabulary (the model
            # has to tell "a note I am hearing" from "a note I am writing"),
            # which the caller applies — `generate` only offsets the events it
            # derives from `inputs` itself.
            from anticipation import ops

            melody = inputs
            inputs = []
            controls = [ops.CONTROL_OFFSET + token for token in melody]
            start = 0.0
            # Same 100 s time-vocabulary wall as the other two modes: play
            # along with as much as fits rather than feeding out-of-vocab
            # times, and say so in the meta below.
            end = min(95.0, float(ops.max_time(melody, seconds=True)))
            if end <= 0.0:
                raise RuntimeError("the MIDI file has no notes to play along "
                                   "with")
        else:
            start, end = 0.0, span_s

        verb = {"continue": "continuing", "infill": "filling the gap in",
                "accompany": "playing along with"}
        progress_cb(None, f"{verb.get(mode, 'composing')} "
                          f"{end - start:.0f} s of music "
                          f"({'MPS' if self.device == 'mps' else 'CPU — slow'})")
        if cancel.cancelled:
            raise CancelledError()
        # sample.generate advances a tqdm bar by time-units toward
        # (end-start): hooking update() gives the engine's slowest
        # generation real progress and a cooperative cancel that keeps the
        # warm weights, instead of a 10 s kill (audit §5).
        import tqdm as _tqdm

        orig_update = _tqdm.tqdm.update

        def patched_update(bar, n=1):
            result = orig_update(bar, n)
            if cancel.cancelled:
                raise CancelledError()
            total = getattr(bar, "total", None)
            if total:
                progress_cb(min(0.98, bar.n / total),
                            f"composing — {bar.n}/{total}",
                            step=int(bar.n), steps=int(total))
            return result

        _tqdm.tqdm.update = patched_update
        try:
            events = amt_generate(self.model, start_time=start, end_time=end,
                                  inputs=inputs or None,
                                  controls=controls or None, top_p=top_p)
        finally:
            _tqdm.tqdm.update = orig_update
        if cancel.cancelled:
            raise CancelledError()
        if not events:
            raise RuntimeError("the model produced no events")
        if controls:
            # `generate` returns only what it wrote — the anticipated notes are
            # stripped back out. Put the melody back so the part is playable on
            # its own, which is what every other mode of this card returns.
            from anticipation import ops

            events = ops.combine(events, controls)

        progress_cb(0.9, "writing the MIDI")
        mid = events_to_midi(events)
        midi_path = os.path.join(out_dir, "composition.mid")
        mid.save(midi_path + ".part")
        os.replace(midi_path + ".part", midi_path)
        artifacts = [Artifact(kind="midi", label="composition",
                              path=midi_path, format="mid")]
        meta: dict = {"engine": "anticipation", "notes": len(events) // 3,
                      "seed_used": seed}

        abc = self._to_abc(midi_path)
        if abc:
            payload = {"text_version": 1, "kind": "abc", "text": abc,
                       "model": self.model_id, "engine": "anticipation"}
            text_path = os.path.join(out_dir, "abc.json")
            tmp = text_path + ".part"
            with open(tmp, "w") as f:
                json.dump(payload, f, ensure_ascii=False)
            os.replace(tmp, text_path)
            artifacts.append(Artifact(kind="text", label="abc",
                                      path=text_path, format="json"))
            meta["text"] = payload
            meta["abc_preview"] = abc[:200]
        else:
            meta["midi_error"] = "notation conversion produced nothing"
        progress_cb(1.0, "done")
        return TaskResult(artifacts=artifacts, meta=meta)

    @staticmethod
    def _to_abc(midi_path: str) -> str | None:
        # music21 has no ABC writer; the serialiser is the transcription
        # family's own, vendored (see abc_out.py's docstring).
        from .abc_out import midi_to_abc

        abc = midi_to_abc(midi_path, title="composition")
        return abc or None

    def unload(self) -> None:
        self.model = None
        # load() puts the LM on MPS when it is available; dropping the
        # reference does not hand its Metal blocks back.
        release_accelerator_memory()
