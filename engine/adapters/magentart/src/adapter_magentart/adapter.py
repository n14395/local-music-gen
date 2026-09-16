"""Magenta RealTime 2 on MLX — the most Mac-native generator of the 2026
triage (4 s of audio in ~6 s including model load, 1.7 GB peak).

Weights are Google's own distribution: the `mrt` CLI that ships with the
package fetches resources (MusicCoCa + SpectroStream, ~1.3 GB) and the
exported .mlxfn model (~450 MB) from GCS into MAGENTA_HOME. The adapter
points MAGENTA_HOME inside the engine cache and runs those exact commands at
first load (route B) — MAGENTA_HOME is read when magenta_rt is imported, so
it is set before any import of the package.

Generation is chunked (the model is a streaming design, 25 frames/s, with
explicit state chaining), which is what gives this adapter real per-chunk
progress and cancel — rare among the generate families.
"""

from __future__ import annotations

import os
import secrets
import subprocess
import sys

import numpy as np
import soundfile as sf

from engine_protocol.adapter import (CancelledError, CancelToken,
                                     GenerateResult, ModelAdapter,
                                     ProgressCb, aux_dir)

FRAMES_PER_S = 25
CHUNK_FRAMES = 50  # 2 s per generate() call: fine-grained cancel + progress
# Conditioning is per call, not per frame, so the chunk length IS the note
# grid's resolution. Sampling costs one step per frame either way — the chunk
# only sets how often the conditioning is refreshed — so a note-conditioned
# render drops to 200 ms chunks and pays almost nothing for it.
NOTE_CHUNK_FRAMES = 5

# `pianoroll_with_onsets_tokens` states, from magenta_rt/config.py:
#   -1 masked (the model chooses)   0 off   1 held   2 onset   3 on, its choice
PITCH_MASKED, PITCH_OFF, PITCH_HELD, PITCH_ONSET = -1, 0, 1, 2
# `drum_pianoroll_tokens`: -1 masked, 0 no drum, 1 play drum
DRUM_MASKED, DRUM_OFF, DRUM_ON = -1, 0, 1


def _roll_from_midi(midi_path: str, total_frames: int):
    """A MIDI file as (frames, 128) pitch states plus a (frames,) drum flag.

    The vocabulary is the model's own: 0 off, 1 held, 2 onset — an onset is
    written at the note's first frame and a hold for the rest, which is what
    distinguishes "the same note again" from "still ringing". Percussion
    tracks do not go in the pianoroll at all: they drive the separate one-bit
    drum channel, which is the only place this model takes them.

    Either channel comes back None when the file says nothing about it, and
    each is *masked* outside the span its own notes cover. Both arrays used to
    be zero-filled for the whole take, and zero is not "nothing said" — it is
    "this pitch is not sounding" and "no drum is playing", enforced at guidance
    3.0. So a piano-only MIDI silenced the drums for the entire render, and a
    6 s melody under a 12 s take conditioned every pitch off for the second
    half. PITCH_MASKED/DRUM_MASKED existed for exactly this and went unused.
    """
    import pretty_midi

    pm = pretty_midi.PrettyMIDI(midi_path)
    roll = np.full((total_frames, 128), PITCH_MASKED, dtype=np.int32)
    drums = np.full(total_frames, DRUM_MASKED, dtype=np.int32)
    # (start, end) spans of what was actually written, per channel.
    pitched: list[tuple[int, int, int]] = []
    hits: list[tuple[int, int]] = []
    for instrument in pm.instruments:
        for note in instrument.notes:
            start = int(round(note.start * FRAMES_PER_S))
            end = int(round(note.end * FRAMES_PER_S))
            if start >= total_frames:
                continue
            start = max(0, start)
            end = min(max(end, start + 1), total_frames)
            if instrument.is_drum:
                hits.append((start, end))
                continue
            pitch = int(note.pitch)
            if not 0 <= pitch < 128:
                continue
            pitched.append((start, end, pitch))
    # Inside a channel's own span, silence is deliberate: a frame with no note
    # is off, a frame with no hit is no drum. Outside it, nothing was said.
    if pitched:
        span_from = min(s for s, _, _ in pitched)
        span_to = max(e for _, e, _ in pitched)
        roll[span_from:span_to, :] = PITCH_OFF
        for start, end, pitch in pitched:
            roll[start:end, pitch] = np.maximum(roll[start:end, pitch],
                                                PITCH_HELD)
            roll[start, pitch] = PITCH_ONSET
    if hits:
        drums[min(s for s, _ in hits):max(e for _, e in hits)] = DRUM_OFF
        for start, end in hits:
            drums[start:end] = DRUM_ON
    return (roll if pitched else None), (drums if hits else None)


class MagentaRTAdapter(ModelAdapter):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.mrt = None
        self.size = str(self.settings.get("size") or "mrt2_small")

    def _ensure_assets(self, progress_cb: ProgressCb) -> None:
        root = os.path.join(aux_dir("magenta-home"), "magenta-rt-v2")
        resources = os.path.join(root, "resources")
        model_dir = os.path.join(root, "models", self.size)
        resource_files = (
            os.path.join(resources, "musiccoca", filename)
            for filename in (
                "text_encoder.tflite",
                "audio_preprocessor.tflite",
                "music_encoder.tflite",
                "pretrained_vector_quantizer.tflite",
            )
        )
        spectrostream_files = (
            os.path.join(resources, "spectrostream", filename)
            for filename in (
                "decoder.safetensors",
                "encoder.safetensors",
                "quantizer.safetensors",
                "spectrostream_encoder.mlxfn",
            )
        )
        model_files = (
            os.path.join(model_dir, f"{self.size}.mlxfn"),
            os.path.join(model_dir, f"{self.size}_state.safetensors"),
        )
        mrt_cli = os.path.join(os.path.dirname(sys.executable), "mrt")
        env = {**os.environ, "MAGENTA_HOME": aux_dir("magenta-home")}
        # `mrt models init` has two independent resource directories. A
        # partially interrupted fetch leaves the parent nonempty but cannot
        # embed text or decode generated audio.
        if not all(os.path.isfile(path) and os.path.getsize(path) > 0
                   for path in (*resource_files, *spectrostream_files)):
            progress_cb(None, "fetching Magenta RT resources "
                              "(~1.3 GB, first use only)")
            subprocess.run([mrt_cli, "models", "init"], env=env, check=True,
                           capture_output=True)
        # The MLX export needs its separate recurrent state file. An older
        # downloader left only the .mlxfn behind, so a nonempty directory is
        # not sufficient evidence that this model is usable.
        if not all(os.path.isfile(path) and os.path.getsize(path) > 0
                   for path in model_files):
            progress_cb(None, f"fetching the {self.size} model "
                               "(first use only)")
            subprocess.run([mrt_cli, "models", "download", self.size],
                           env=env, check=True, capture_output=True)

    def load(self, progress_cb: ProgressCb) -> None:
        # Read at magenta_rt import time — must be set before the import.
        os.environ["MAGENTA_HOME"] = aux_dir("magenta-home")
        self._ensure_assets(progress_cb)

        progress_cb(None, "loading Magenta RT 2 (MLX)")
        from magenta_rt import MagentaRT2StdMlxfn

        self.mrt = MagentaRT2StdMlxfn(size=self.size)
        progress_cb(None, "realtime engine ready")

    def _require_conditioning(self, key: str) -> None:
        """Fail loudly if this export does not take the channel being driven.

        `_build_conditioning` walks the model's own input configs and reads
        only the keys it finds there, so a conditioning key the export does not
        declare is *silently ignored* — the render would come back with the
        notes politely disregarded and nothing to say why. The two sizes this
        catalog ships both declare all three channels; a future export might
        not.
        """
        model = getattr(self.mrt, "_model", None)
        configs = getattr(model, "input_configs", None)
        if not configs:
            return   # can't tell — let the render proceed rather than guess
        if not any(getattr(c, "key", None) == key for c in configs):
            raise RuntimeError(
                f"this Magenta export does not take '{key}' conditioning — "
                f"the notes and drums controls need a model that declares it")

    def generate(self, prompt: str, lyrics: str | None, params: dict,
                 out_path: str, progress_cb: ProgressCb,
                 cancel: CancelToken) -> GenerateResult:
        assert self.mrt is not None
        from magenta_rt.config import (DRUM_PIANOROLL, MUSICCOCA,
                                       PIANOROLL_WITH_ONSETS)

        duration_s = float(params.get("duration_s") or 10.0)
        # Drawn rather than left to chance when the job did not pin one:
        # an unreproducible take is one you cannot come back to after
        # changing a single other setting. `seed_used` reports it back.
        # MLX's default RNG key is thread-local (the ACE-Step lesson), so this
        # has to be set on the thread that runs the sampler — which is this
        # one: `mrt.generate` is a plain call, not a worker thread.
        import mlx.core as mx

        seed = params.get("seed")
        seed = int(seed) if seed is not None else secrets.randbelow(2 ** 32)
        mx.random.seed(seed)
        temperature = float(params.get("temperature") or 1.3)
        top_k = int(params.get("top_k") or 40)
        # Three independent guidance scales, one per conditioning channel.
        # Notes and drums were pinned at 1.0 because nothing was driving them;
        # now that both channels can carry real conditioning, each gets the
        # dial the exported graph already had.
        cfg_scales = {
            "musiccoca": float(params.get("guidance_scale") or 3.0),
            "notes": float(params.get("notes_guidance") or 3.0),
            "drums": float(params.get("drums_guidance") or 3.0)}

        def style_input(path_key: str, text: str | None):
            """A Waveform for an audio param, else the text, else None."""
            path = params.get(path_key)
            if path and os.path.isfile(path):
                from magenta_rt import audio as mrt_audio

                wav, sr = sf.read(path, dtype="float32", always_2d=True)
                return mrt_audio.Waveform(wav, sr)
            return text if text and text.strip() else None

        progress_cb(None, "embedding the style")
        style = style_input("style_audio", prompt) or "instrumental music"
        embedding = self.mrt.embed_style(style, use_mapper=True)
        # A second style makes this a morph: MusicCoCa embeddings are plain
        # vectors that interpolate linearly, so each 2 s chunk is conditioned
        # a step further along the line from A to B.
        style_b = style_input("style_audio_b",
                              str(params.get("prompt_b") or ""))
        embedding_b = (self.mrt.embed_style(style_b, use_mapper=True)
                       if style_b is not None else None)
        conditioning = {MUSICCOCA.key: embedding}

        total_frames = max(FRAMES_PER_S, int(duration_s * FRAMES_PER_S))

        # Notes and drums: the two conditioning channels the exported graph
        # takes beside the style embedding, and the reason this family pairs
        # with the app's MIDI half at all. A pianoroll says which pitches are
        # sounding; the drum channel is one bit saying whether percussion is
        # playing. Both are read per call, so the chunk shrinks below.
        notes_path = params.get("melody_midi")
        roll = drum_track = None
        if notes_path and os.path.isfile(notes_path):
            self._require_conditioning(PIANOROLL_WITH_ONSETS.key)
            progress_cb(None, "reading the notes")
            roll, drum_track = _roll_from_midi(notes_path, total_frames)
            if roll is None and drum_track is None:
                # Nothing to condition on. Silently rendering an unconditioned
                # take would look exactly like the MIDI being ignored.
                raise RuntimeError(
                    "that MIDI has no notes to condition on — it is empty, or "
                    "every note starts after the end of the take")
        drums_mode = str(params.get("drums") or "auto")
        drum_override = {"play": DRUM_ON, "silent": DRUM_OFF}.get(drums_mode)
        # `drum_track` is only ever set when the MIDI really has percussion in
        # it, so on automatic a piano-only MIDI now leaves the channel alone —
        # which is what drums_guidance's catalog help has always claimed.
        if drum_override is not None or drum_track is not None:
            self._require_conditioning(DRUM_PIANOROLL.key)

        conditioned = roll is not None or drum_track is not None
        chunk_frames = NOTE_CHUNK_FRAMES if conditioned else CHUNK_FRAMES
        n_chunks = max(1, -(-total_frames // chunk_frames))
        pieces: list[np.ndarray] = []
        state = None
        sample_rate = 48000
        done = 0
        index = 0
        while done < total_frames:
            if cancel.cancelled:
                raise CancelledError()
            if embedding_b is not None:
                t = index / (n_chunks - 1) if n_chunks > 1 else 1.0
                conditioning = {
                    MUSICCOCA.key: (1.0 - t) * embedding + t * embedding_b}
            chunk = min(chunk_frames, total_frames - done)
            if roll is not None:
                # One vector for the whole chunk, so a note that starts
                # anywhere inside it reads as an onset: `max` over the window
                # keeps 2 (onset) above 1 (held) above 0 (off) above -1
                # (masked), so a window that straddles the end of the MIDI
                # still reads as the notes it does carry.
                window = roll[done:done + chunk]
                conditioning[PIANOROLL_WITH_ONSETS.key] = [
                    int(v) for v in window.max(axis=0)]
            if drum_override is not None:
                conditioning[DRUM_PIANOROLL.key] = [drum_override]
            elif drum_track is not None:
                conditioning[DRUM_PIANOROLL.key] = [
                    int(drum_track[done:done + chunk].max())]
            waveform, state = self.mrt.generate(
                conditioning=conditioning, cfg_scales=cfg_scales,
                temperature=temperature, top_k=top_k,
                frames=chunk, state=state)
            sample_rate = int(waveform.sample_rate)
            pieces.append(np.asarray(waveform.samples, dtype=np.float32))
            done += chunk
            index += 1
            progress_cb(done / total_frames,
                        "morphing" if embedding_b is not None
                        else "streaming",
                        phase="lm_decode", step=done, steps=total_frames)

        progress_cb(None, "saving", phase="master")
        samples = np.concatenate(pieces, axis=0)
        tmp = out_path + ".part"
        sf.write(tmp, samples, sample_rate, format="WAV", subtype="PCM_16")
        os.replace(tmp, out_path)
        return GenerateResult(
            wav_path=out_path,
            duration_s=round(samples.shape[0] / sample_rate, 3),
            sample_rate=sample_rate,
            seed_used=seed)

    def unload(self) -> None:
        self.mrt = None
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:  # noqa: BLE001 — unload must never raise
            pass
